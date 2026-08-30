--- Module to manage a dedicated vertical split terminal for Vibe.
--- Supports Snacks.nvim or a native Neovim terminal fallback.
--- @module 'vibe.terminal'

local M = {}

---@type VibeTerminalConfig
local defaults = {
  split_side = "right", -- "left" or "right"
  split_width_percentage = 0.30,
  provider = "auto", -- "auto", "snacks", "native", "external", "none", or custom provider table
  show_native_term_exit_tip = true,
  terminal_cmd = nil,
  provider_opts = {
    external_terminal_cmd = nil,
  },
  auto_close = true,
  auto_insert = true,
  env = {},
  snacks_win_opts = {},
  -- Working directory control
  cwd = nil, -- static cwd override
  git_repo_cwd = false, -- resolve to git root when spawning
  cwd_provider = nil, -- function(ctx) -> cwd string
}

M.defaults = defaults

-- Lazy load providers
local providers = {}

---Loads a terminal provider module
---@param provider_name string The name of the provider to load
---@return VibeTerminalProvider? provider The provider module, or nil if loading failed
local function load_provider(provider_name)
  if not providers[provider_name] then
    local ok, provider = pcall(require, "vibe.terminal." .. provider_name)
    if ok then
      providers[provider_name] = provider
    else
      return nil
    end
  end
  return providers[provider_name]
end

---Validates and enhances a custom table provider with smart defaults
---@param provider VibeTerminalProvider The custom provider table to validate
---@return VibeTerminalProvider? provider The enhanced provider, or nil if invalid
---@return string? error Error message if validation failed
local function validate_and_enhance_provider(provider)
  if type(provider) ~= "table" then
    return nil, "Custom provider must be a table"
  end

  -- Required functions that must be implemented
  local required_functions = {
    "setup",
    "open",
    "close",
    "simple_toggle",
    "focus_toggle",
    "get_active_bufnr",
    "is_available",
  }

  for _, func_name in ipairs(required_functions) do
    local func = provider[func_name]
    if not func then
      return nil, "Custom provider missing required function: " .. func_name
    end
    local is_callable = type(func) == "function"
      or (type(func) == "table" and getmetatable(func) and getmetatable(func).__call)
    if not is_callable then
      return nil, "Custom provider field '" .. func_name .. "' must be callable, got: " .. type(func)
    end
  end

  local enhanced_provider = provider

  if not enhanced_provider.toggle then
    enhanced_provider.toggle = function(cmd_string, env_table, effective_config)
      return enhanced_provider.simple_toggle(cmd_string, env_table, effective_config)
    end
  end

  if not enhanced_provider._get_terminal_for_test then
    enhanced_provider._get_terminal_for_test = function()
      return nil
    end
  end

  return enhanced_provider, nil
end

---Gets the effective terminal provider, guaranteed to return a valid provider
---Falls back to native provider if configured provider is unavailable
---@return VibeTerminalProvider provider The terminal provider module (never nil)
local function get_provider()
  local logger = require("vibe.logger")

  if type(defaults.provider) == "table" then
    local custom_provider = defaults.provider --[[@as VibeTerminalProvider]]
    local enhanced_provider, error_msg = validate_and_enhance_provider(custom_provider)
    if enhanced_provider then
      local is_available_ok, is_available = pcall(enhanced_provider.is_available)
      if is_available_ok and is_available then
        logger.debug("terminal", "Using custom table provider")
        return enhanced_provider
      else
        local availability_msg = is_available_ok and "provider reports not available" or "error checking availability"
        logger.warn("terminal", "Custom table provider configured but " .. availability_msg .. ". Falling back to 'native'.")
      end
    else
      logger.warn("terminal", "Invalid custom table provider: " .. error_msg .. ". Falling back to 'native'.")
    end
  elseif defaults.provider == "auto" then
    local snacks_provider = load_provider("snacks")
    if snacks_provider and snacks_provider.is_available() then
      return snacks_provider
    end
  elseif defaults.provider == "snacks" then
    local snacks_provider = load_provider("snacks")
    if snacks_provider and snacks_provider.is_available() then
      return snacks_provider
    else
      logger.warn("terminal", "'snacks' provider configured, but Snacks.nvim not available. Falling back to 'native'.")
    end
  elseif defaults.provider == "external" then
    local external_provider = load_provider("external")
    if external_provider then
      local external_cmd = defaults.provider_opts and defaults.provider_opts.external_terminal_cmd

      local has_external_cmd = false
      if type(external_cmd) == "function" then
        has_external_cmd = true
      elseif type(external_cmd) == "string" and external_cmd ~= "" and external_cmd:find("%%s") then
        has_external_cmd = true
      end

      if has_external_cmd then
        return external_provider
      else
        logger.warn(
          "terminal",
          "'external' provider configured, but provider_opts.external_terminal_cmd not properly set. Falling back to 'native'."
        )
      end
    end
  elseif defaults.provider == "native" then
    logger.debug("terminal", "Using native terminal provider")
  elseif defaults.provider == "none" then
    local none_provider = load_provider("none")
    if none_provider then
      logger.debug("terminal", "Using no-op terminal provider ('none')")
      return none_provider
    else
      logger.warn("terminal", "'none' provider configured but failed to load. Falling back to 'native'.")
    end
  elseif type(defaults.provider) == "string" then
    logger.warn("terminal", "Invalid provider configured: " .. tostring(defaults.provider) .. ". Defaulting to 'native'.")
  else
    logger.warn(
      "terminal",
      "Invalid provider type: " .. type(defaults.provider) .. ". Must be string or table. Defaulting to 'native'."
    )
  end

  local native_provider = load_provider("native")
  if not native_provider then
    error("Vibe: Critical error - native terminal provider failed to load")
  end
  return native_provider
end

---Resolve the git root for a given directory (best-effort), used by git_repo_cwd.
---@param start_dir string|nil Directory to search from.
---@return string|nil root The git toplevel, or nil.
local function git_root(start_dir)
  local dir = start_dir or vim.fn.getcwd()
  local found = vim.fn.finddir(".git", dir .. ";")
  if found and found ~= "" then
    local root = vim.fn.fnamemodify(found, ":h")
    if root and root ~= "" and vim.fn.isdirectory(root) == 1 then
      return root
    end
  end
  return nil
end

---Builds the effective terminal configuration by merging defaults with overrides
---@param opts_override table? Optional overrides for terminal appearance
---@return table config The effective terminal configuration
local function build_config(opts_override)
  local effective_config = vim.deepcopy(defaults)
  if type(opts_override) == "table" then
    local validators = {
      split_side = function(val)
        return val == "left" or val == "right"
      end,
      split_width_percentage = function(val)
        return type(val) == "number" and val > 0 and val < 1
      end,
      snacks_win_opts = function(val)
        return type(val) == "table"
      end,
      cwd = function(val)
        return val == nil or type(val) == "string"
      end,
      git_repo_cwd = function(val)
        return type(val) == "boolean"
      end,
      cwd_provider = function(val)
        local t = type(val)
        if t == "function" then
          return true
        end
        if t == "table" then
          local mt = getmetatable(val)
          return mt and mt.__call ~= nil
        end
        return false
      end,
    }
    for key, val in pairs(opts_override) do
      if effective_config[key] ~= nil and validators[key] and validators[key](val) then
        effective_config[key] = val
      end
    end
  end
  -- Resolve cwd at config-build time so providers receive it directly
  local cwd_ctx = {
    file = (function()
      local path = vim.fn.expand("%:p")
      if type(path) == "string" and path ~= "" then
        return path
      end
      return nil
    end)(),
    cwd = vim.fn.getcwd(),
  }
  cwd_ctx.file_dir = cwd_ctx.file and vim.fn.fnamemodify(cwd_ctx.file, ":h") or nil

  local resolved_cwd = nil
  if effective_config.cwd_provider then
    local ok_p, res = pcall(effective_config.cwd_provider, cwd_ctx)
    if ok_p and type(res) == "string" and res ~= "" then
      resolved_cwd = vim.fn.expand(res)
    end
  end
  if not resolved_cwd and type(effective_config.cwd) == "string" and effective_config.cwd ~= "" then
    resolved_cwd = vim.fn.expand(effective_config.cwd)
  end
  if not resolved_cwd and effective_config.git_repo_cwd then
    resolved_cwd = git_root(cwd_ctx.file_dir or cwd_ctx.cwd)
  end

  return {
    split_side = effective_config.split_side,
    split_width_percentage = effective_config.split_width_percentage,
    auto_close = effective_config.auto_close,
    auto_insert = effective_config.auto_insert,
    snacks_win_opts = effective_config.snacks_win_opts,
    cwd = resolved_cwd,
  }
end

---Gets the vibe command string and environment variables
---@param cmd_args string? Optional arguments to append to the command
---@return string cmd_string The command string
---@return table env_table The environment variables table
local function get_vibe_command_and_env(cmd_args)
  local cmd_from_config = defaults.terminal_cmd
  local base_cmd
  if not cmd_from_config or cmd_from_config == "" then
    base_cmd = "vibe" -- Default if not configured
  else
    base_cmd = cmd_from_config
  end

  local cmd_string
  if cmd_args and cmd_args ~= "" then
    cmd_string = base_cmd .. " " .. cmd_args
  else
    cmd_string = base_cmd
  end

  local env_table = {}
  -- Merge custom environment variables from config
  for key, value in pairs(defaults.env) do
    env_table[key] = value
  end

  return cmd_string, env_table
end

---Common helper to open terminal without focus if not already visible
---@param opts_override table? Optional config overrides
---@param cmd_args string? Optional command arguments
---@return boolean visible True if terminal was opened or already visible
local function ensure_terminal_visible_no_focus(opts_override, cmd_args)
  local provider = get_provider()

  if provider.ensure_visible then
    provider.ensure_visible()
    return true
  end

  local active_bufnr = provider.get_active_bufnr()

  if active_bufnr and vim.api.nvim_buf_is_valid(active_bufnr) then
    -- Check whether it is actually shown in a window.
    local bufinfo = vim.fn.getbufinfo(active_bufnr)
    if bufinfo and #bufinfo > 0 then
      for _, win in ipairs(bufinfo[1].windows or {}) do
        if vim.api.nvim_win_is_valid(win) then
          local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
          if not (ok and cfg and cfg.hide == true) then
            return true
          end
        end
      end
    end
  end

  local effective_config = build_config(opts_override)
  local cmd_string, env_table = get_vibe_command_and_env(cmd_args)
  provider.open(cmd_string, env_table, effective_config, false) -- false = don't focus
  return true
end

---Configures the terminal module.
---@param user_term_config VibeTerminalConfig? Configuration options for the terminal.
---@param p_terminal_cmd string? The command to run in the terminal (from main config).
---@param p_env table? Custom environment variables to pass to the terminal (from main config).
function M.setup(user_term_config, p_terminal_cmd, p_env)
  if user_term_config == nil then
    user_term_config = {}
  elseif type(user_term_config) ~= "table" then
    vim.notify("vibe.terminal.setup expects a table or nil for user_term_config", vim.log.levels.WARN)
    user_term_config = {}
  end

  if p_terminal_cmd == nil or type(p_terminal_cmd) == "string" then
    defaults.terminal_cmd = p_terminal_cmd
  else
    vim.notify(
      "vibe.terminal.setup: Invalid terminal_cmd provided: " .. tostring(p_terminal_cmd) .. ". Using default.",
      vim.log.levels.WARN
    )
    defaults.terminal_cmd = nil
  end

  if p_env == nil or type(p_env) == "table" then
    defaults.env = p_env or {}
  else
    vim.notify("vibe.terminal.setup: Invalid env provided: " .. tostring(p_env) .. ". Using empty table.", vim.log.levels.WARN)
    defaults.env = {}
  end

  for k, v in pairs(user_term_config) do
    if k == "split_side" then
      if v == "left" or v == "right" then
        defaults.split_side = v
      else
        vim.notify("vibe.terminal.setup: Invalid value for split_side: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "split_width_percentage" then
      if type(v) == "number" and v > 0 and v < 1 then
        defaults.split_width_percentage = v
      else
        vim.notify("vibe.terminal.setup: Invalid value for split_width_percentage: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "provider" then
      if type(v) == "table" or v == "snacks" or v == "native" or v == "external" or v == "auto" or v == "none" then
        defaults.provider = v
      else
        vim.notify("vibe.terminal.setup: Invalid value for provider: " .. tostring(v) .. ". Defaulting to 'auto'.", vim.log.levels.WARN)
      end
    elseif k == "provider_opts" then
      if type(v) == "table" then
        defaults[k] = defaults[k] or {}
        for opt_k, opt_v in pairs(v) do
          if opt_k == "external_terminal_cmd" then
            if opt_v == nil or type(opt_v) == "string" or type(opt_v) == "function" then
              defaults[k][opt_k] = opt_v
            else
              vim.notify("vibe.terminal.setup: Invalid value for provider_opts.external_terminal_cmd: " .. tostring(opt_v), vim.log.levels.WARN)
            end
          else
            defaults[k][opt_k] = opt_v
          end
        end
      else
        vim.notify("vibe.terminal.setup: Invalid value for provider_opts: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "show_native_term_exit_tip" then
      if type(v) == "boolean" then
        defaults.show_native_term_exit_tip = v
      else
        vim.notify("vibe.terminal.setup: Invalid value for show_native_term_exit_tip: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "auto_close" then
      if type(v) == "boolean" then
        defaults.auto_close = v
      else
        vim.notify("vibe.terminal.setup: Invalid value for auto_close: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "auto_insert" then
      if type(v) == "boolean" then
        defaults.auto_insert = v
      else
        vim.notify("vibe.terminal.setup: Invalid value for auto_insert: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "snacks_win_opts" then
      if type(v) == "table" then
        defaults.snacks_win_opts = v
      else
        vim.notify("vibe.terminal.setup: Invalid value for snacks_win_opts", vim.log.levels.WARN)
      end
    elseif k == "cwd" then
      if v == nil or type(v) == "string" then
        defaults.cwd = v
      else
        vim.notify("vibe.terminal.setup: Invalid value for cwd: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "git_repo_cwd" then
      if type(v) == "boolean" then
        defaults.git_repo_cwd = v
      else
        vim.notify("vibe.terminal.setup: Invalid value for git_repo_cwd: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "cwd_provider" then
      local t = type(v)
      if t == "function" then
        defaults.cwd_provider = v
      elseif t == "table" then
        local mt = getmetatable(v)
        if mt and mt.__call then
          defaults.cwd_provider = v
        else
          vim.notify("vibe.terminal.setup: cwd_provider table is not callable (missing __call)", vim.log.levels.WARN)
        end
      else
        vim.notify("vibe.terminal.setup: Invalid cwd_provider type: " .. tostring(t), vim.log.levels.WARN)
      end
    else
      if k ~= "terminal_cmd" then
        vim.notify("vibe.terminal.setup: Unknown configuration key: " .. k, vim.log.levels.WARN)
      end
    end
  end

  get_provider().setup(defaults)
end

---Opens or focuses the Vibe terminal.
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the vibe command.
function M.open(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local cmd_string, env_table = get_vibe_command_and_env(cmd_args)
  get_provider().open(cmd_string, env_table, effective_config)
end

---Closes the managed Vibe terminal if it's open and valid.
function M.close()
  get_provider().close()
end

---Kill the Vibe terminal process and force-delete its buffer. Unlike `close()`
---which just hides the window (native) or closes the Snacks instance cleanly
---(leaving the job a moment to exit), this stops the job and wipes the buffer
---immediately — the equivalent of `<leader>aq` for claudecode.nvim. Safe to call
---when no terminal is running (no-op). Also stops any pending send-retry timer
---so a queued send does not respawn a terminal against the dead process.
---@return boolean killed True if a terminal process was actually stopped.
function M.kill()
  local logger = require("vibe.logger")
  local bufnr = M.get_active_terminal_bufnr()
  local stopped = false

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    -- Mark the buffer as voluntarily killed BEFORE stopping the job. The Snacks
    -- TermClose handler (and any TermClose autocmd) sees status = -1 on a killed
    -- process and would otherwise log a spurious "Vibe exited with code -1"
    -- ERROR. Setting this flag first lets the handler suppress that one toast
    -- while still surfacing genuine non-zero exits (crashes).
    pcall(function()
      vim.b[bufnr].vibe_voluntary_kill = true
    end)

    -- Stop the underlying job first (graceful), then wipe the buffer. For native
    -- the job id lives on the buffer; deleting the buffer with force terminates
    -- the process. For snacks, terminal:close() hides the window; wiping the
    -- buffer after is what actually ends the job.
    local chan = vim.b[bufnr] and vim.b[bufnr].terminal_job_id
    if not chan or chan == 0 then
      chan = vim.bo[bufnr].channel
    end
    if chan and chan ~= 0 then
      pcall(vim.fn.jobstop, chan)
      stopped = true
    end
    -- bwipeout! fires on_exit via the TermClose path and clears provider state.
    pcall(vim.cmd, "bwipeout! " .. bufnr)
  end

  -- Always call provider.close() so window/buffer tracking is reset even when
  -- the buffer was already gone (e.g. exited on its own).
  pcall(get_provider().close)

  if stopped then
    logger.debug("terminal", "kill: stopped Vibe terminal process and wiped buffer " .. tostring(bufnr))
  else
    logger.debug("terminal", "kill: no running Vibe terminal to kill")
  end
  return stopped
end

---Simple toggle: always show/hide the Vibe terminal regardless of focus.
---@param opts_override table? Overrides for terminal appearance.
---@param cmd_args string? Arguments to append to the vibe command.
function M.simple_toggle(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local cmd_string, env_table = get_vibe_command_and_env(cmd_args)
  get_provider().simple_toggle(cmd_string, env_table, effective_config)
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused.
---@param opts_override table? Overrides for terminal appearance.
---@param cmd_args string|nil? Arguments to append to the vibe command.
function M.focus_toggle(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local cmd_string, env_table = get_vibe_command_and_env(cmd_args)
  get_provider().focus_toggle(cmd_string, env_table, effective_config)
end

---Ensures terminal is visible without changing focus. Creates if necessary, shows if hidden.
---@param opts_override table? Overrides for terminal appearance.
---@param cmd_args string? Arguments to append to the vibe command.
function M.ensure_visible(opts_override, cmd_args)
  ensure_terminal_visible_no_focus(opts_override, cmd_args)
end

---Toggle open terminal without focus if not already visible, otherwise do nothing.
---@param opts_override table? Overrides for terminal appearance.
---@param cmd_args string? Arguments to append to the vibe command.
function M.toggle_open_no_focus(opts_override, cmd_args)
  ensure_terminal_visible_no_focus(opts_override, cmd_args)
end

---Toggles the Vibe terminal open or closed (legacy - use simple_toggle or focus_toggle).
---@param opts_override table? Overrides for terminal appearance.
---@param cmd_args string? Arguments to append to the vibe command.
function M.toggle(opts_override, cmd_args)
  M.simple_toggle(opts_override, cmd_args)
end

---Gets the buffer number of the currently active Vibe terminal.
---@return number|nil The buffer number if an active terminal is found, otherwise nil.
function M.get_active_terminal_bufnr()
  return get_provider().get_active_bufnr()
end

---Sends raw text to the running Vibe terminal's job channel, as if it were
---typed at the prompt. By default a trailing carriage return submits the input.
---
---Only works for the in-editor providers ("native"/"snacks"). The "external"
---and "none" providers run Vibe outside Neovim and expose no buffer, so this
---warns and returns false. This function is synchronous and does NOT open the
---terminal: it requires one to already be running, otherwise it warns and
---returns false.
---
---Multi-line text is wrapped in bracketed-paste markers (ESC[200~ ... ESC[201~)
---so embedded newlines arrive as one literal pasted block rather than several
---premature submits; the submit carriage return is sent after the closing
---marker so it still triggers submission. Pass `paste = true` to force
---bracketed-paste wrapping even for single-line text (useful for `@`-mentions,
---so Vibe inserts the path literally instead of opening its interactive
---`@`-mention picker). `chansend` writes straight to the PTY and bypasses
---`vim.paste`.
---@param text string The text to send. Must be a non-empty string.
---@param opts { submit?: boolean, focus?: boolean, paste?: boolean }? `submit` (default true) appends a carriage return; `focus` (default false) focuses the terminal after a successful send; `paste` (default false) forces bracketed-paste wrapping.
---@return boolean success Whether the text was written to a terminal channel.
function M.send_to_terminal(text, opts)
  local logger = require("vibe.logger")

  if type(text) ~= "string" or text == "" then
    logger.warn("terminal", "send_to_terminal: no text provided")
    return false
  end

  opts = opts or {}
  local submit = opts.submit ~= false
  local force_paste = opts.paste == true

  local bufnr = M.get_active_terminal_bufnr()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    local provider_name = type(defaults.provider) == "string" and defaults.provider or "custom"
    if provider_name == "none" or provider_name == "external" then
      logger.warn(
        "terminal",
        string.format(
          "Cannot send text: terminal.provider=%q runs Vibe outside Neovim, so there is no pane to "
            .. "write to. Use the 'native' or 'snacks' provider to send text programmatically.",
          provider_name
        )
      )
    else
      logger.warn("terminal", "Cannot send text: no Vibe terminal is currently running.")
    end
    return false
  end

  local chan = vim.b[bufnr] and vim.b[bufnr].terminal_job_id
  if not chan or chan == 0 then
    chan = vim.bo[bufnr].channel
  end
  if not chan or chan == 0 then
    logger.warn("terminal", "Cannot send text: no terminal job channel for buffer " .. tostring(bufnr))
    return false
  end

  -- Normalize line endings so the ONLY submit byte is the trailing CR added below.
  local normalized = (text:gsub("\r\n", "\n"):gsub("\r", "\n"))

  local payload = normalized
  if force_paste or string.find(normalized, "\n", 1, true) then
    -- Bracketed paste so the text arrives as one literal block (and, for
    -- @-mentions, so Vibe inserts the path instead of opening its picker).
    payload = "\27[200~" .. normalized .. "\27[201~"
  end
  if submit then
    payload = payload .. "\r"
  end

  local ok_send, written = pcall(vim.fn.chansend, chan, payload)
  if not ok_send or written == 0 then
    logger.warn("terminal", "Cannot send text: the Vibe terminal channel is closed (the process may have exited).")
    return false
  end
  logger.debug(
    "terminal",
    string.format("send_to_terminal: wrote %d byte(s) to channel %s (submit=%s)", #payload, tostring(chan), tostring(submit))
  )

  if opts.focus then
    M.open()
  end

  return true
end

---Returns true when the terminal process is running AND its job channel is
---ready to accept input (i.e. a send would not be dropped). Used by the send
---retry loop in init.lua to wait for Vibe to finish booting.
---@return boolean ready
function M.is_channel_ready()
  local bufnr = M.get_active_terminal_bufnr()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local chan = vim.b[bufnr] and vim.b[bufnr].terminal_job_id
  if not chan or chan == 0 then
    chan = vim.bo[bufnr].channel
  end
  return chan ~= nil and chan ~= 0
end

---Gets the managed terminal instance for testing purposes.
---@return table|nil terminal The managed terminal instance, or nil.
function M._get_managed_terminal_for_test()
  local provider = get_provider()
  if provider and provider._get_terminal_for_test then
    return provider._get_terminal_for_test()
  end
  return nil
end

return M
