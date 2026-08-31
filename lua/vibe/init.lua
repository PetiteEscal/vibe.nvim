---@brief [[
--- Vibe Neovim Integration
--- A terminal-wrapper plugin that runs the Mistral Vibe CLI inside Neovim and
--- wires up commands/keymaps to send files and selections as `@`-mentions,
--- start sessions, and navigate resumes — all by driving Vibe's own TUI.
---@brief ]]

---@module 'vibe'
local M = {}

local logger = require("vibe.logger")

--- Current plugin version
---@type VibeVersion
M.version = {
  major = 0, -- x-release-please-major
  minor = 1, -- x-release-please-minor
  patch = 0, -- x-release-please-patch
  prerelease = nil,
  string = function(self)
    local version = string.format("%d.%d.%d", self.major, self.minor, self.patch)
    if self.prerelease then
      version = version .. "-" .. self.prerelease
    end
    return version
  end,
}

-- Module state
---@type VibeState
M.state = {
  config = require("vibe.config").defaults,
  initialized = false,
  send_timer = nil,
}

--------------------------------------------------------------------------------
-- Internal helpers
--------------------------------------------------------------------------------

---Fire the `User VibeSendComplete` autocmd so integrations can react after a
---send (e.g. focus an externally-managed Vibe session). Fires once per file,
---synchronously on the same tick, right after the (optional) focus action.
---@param file_path string Path Vibe received (formatted/relative)
---@param start_line number|nil Start line, or nil
---@param end_line number|nil End line, or nil
---@param context string|nil Internal logging context tag
local function fire_send_complete(file_path, start_line, end_line, context)
  if not (vim.api and vim.api.nvim_exec_autocmds) then
    return
  end
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "VibeSendComplete",
    modeline = false,
    data = {
      file_path = file_path,
      start_line = start_line,
      end_line = end_line,
      context = context,
    },
  })
end

---True when the configured provider runs Vibe outside Neovim (no in-editor
---channel to write to).
---@return boolean
local function provider_is_external()
  local provider = M.state.config.terminal and M.state.config.terminal.provider
  return provider == "none" or provider == "external"
end

---Format a file path as a Vibe `@`-mention. Paths inside the cwd are made
---relative for readability. An optional line range is appended as a textual
---hint (Vibe's `@`-mention reads the whole file; the hint is just guidance).
---@param file_path string
---@param start_line number|nil
---@param end_line number|nil
---@return string mention
local function format_mention(file_path, start_line, end_line)
  local utils = require("vibe.utils")
  local path = utils.relative_path(file_path)
  local mention = "@" .. path
  if start_line and end_line and start_line > 0 and end_line > 0 then
    mention = mention .. string.format(" (lines %d-%d)", start_line, end_line)
  end
  return mention
end

---Stop the pending send-retry timer if any.
local function stop_send_timer()
  if M.state.send_timer then
    M.state.send_timer:stop()
    M.state.send_timer:close()
    M.state.send_timer = nil
  end
end

---Send text to the Vibe terminal, launching Vibe first if needed, and retrying
---until the terminal's job channel is ready (Vibe's TUI takes a moment to
---boot). `opts` is forwarded to terminal.send_to_terminal (submit, paste,
---focus). When `launch` is true (default), the terminal is opened if no
---channel exists yet.
---
---Returns true when the text was actually written to a channel. When Vibe is
---still booting, this schedules retries and returns true optimistically
---(delivery happens on the next ready tick). For external/none providers it
---warns and returns false (no in-editor pane to write to).
---@param text string Text to send.
---@param opts table? { submit?, paste?, focus?, launch?, context? }
---@return boolean dispatched
function M._send_with_retry(text, opts)
  opts = opts or {}
  local context = opts.context or "send"
  local terminal = require("vibe.terminal")

  -- Channel already ready: send synchronously.
  if terminal.is_channel_ready() then
    local ok = terminal.send_to_terminal(text, opts)
    if ok and opts.focus and M.state.config.focus_after_send then
      terminal.open()
    end
    return ok
  end

  -- No channel. For external/none there is never an in-editor pane.
  if provider_is_external() then
    logger.warn(
      context,
      string.format(
        "Cannot send: terminal.provider=%q runs Vibe outside Neovim, so there is no pane to write to. "
          .. "Use the 'native' or 'snacks' provider, or hook the `User VibeSendComplete` event.",
        M.state.config.terminal.provider
      )
    )
    return false
  end

  -- Launch Vibe if requested, then retry until the channel is ready.
  if opts.launch ~= false then
    terminal.open()
  end

  local cfg = M.state.config
  local deadline = vim.loop.now() + (cfg.startup_send_timeout or 15000)
  local interval = math.max(50, cfg.send_retry_interval or 300)

  stop_send_timer()
  M.state.send_timer = vim.loop.new_timer()
  M.state.send_timer:start(interval, interval, function()
    vim.schedule(function()
      if vim.loop.now() > deadline then
        stop_send_timer()
        logger.warn(context, "Timed out waiting for the Vibe terminal to be ready; send was dropped.")
        return
      end
      if terminal.is_channel_ready() then
        stop_send_timer()
        terminal.send_to_terminal(text, opts)
        if opts.focus and M.state.config.focus_after_send then
          terminal.open()
        end
        logger.debug(context, "Delivered queued send after Vibe became ready.")
      end
    end)
  end)

  logger.debug(context, "Vibe terminal not ready yet; queued send and launched Vibe.")
  return true
end

---Get the text of the last visual selection (line granularity), using the `'<`/`'>`
---marks. Returns nil when there is no valid selection.
---@return string? text
local function get_visual_text()
  local mark_start = vim.fn.getpos("'<")
  local mark_end = vim.fn.getpos("'>")
  local sl = mark_start[2]
  local el = mark_end[2]
  if sl == 0 or el == 0 then
    return nil
  end
  if el < sl then
    sl, el = el, sl
  end
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, sl - 1, el, false)
  if not lines or #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---Send a file to Vibe as an `@`-mention, adding it to the agent's context.
---By default the mention is inserted into Vibe's prompt WITHOUT submitting,
---so you can follow it with a question. Pass `{ submit = true }` to submit it.
---@param file_path string The file path to mention.
---@param start_line number|nil Optional start line (1-indexed).
---@param end_line number|nil Optional end line (1-indexed).
---@param opts table? { submit?: boolean, context?: string }
---@return boolean success
function M.send_file(file_path, start_line, end_line, opts)
  opts = opts or {}
  local context = opts.context or "add"
  if not file_path or file_path == "" then
    logger.warn(context, "send_file: no file path provided")
    return false
  end

  local mention = format_mention(file_path, start_line, end_line)
  local sent_path = require("vibe.utils").relative_path(file_path)

  local dispatched = M._send_with_retry(mention, {
    submit = opts.submit == true, -- default: insert only
    paste = true, -- literal insert so Vibe doesn't open its interactive @ picker
    focus = false,
    context = context,
  })

  if dispatched then
    fire_send_complete(sent_path, start_line, end_line, context)
  end
  return dispatched
end

---Send arbitrary text to the Vibe terminal's prompt. By default the text is
---submitted (a trailing Enter). Pass `{ submit = false }` to insert only.
---@param text string The text to send.
---@param opts table? { submit?: boolean, focus?: boolean, paste?: boolean, context?: string }
---@return boolean success
function M.send_text(text, opts)
  opts = opts or {}
  return M._send_with_retry(text, {
    submit = opts.submit ~= false,
    paste = opts.paste,
    focus = opts.focus == true,
    context = opts.context or "send_text",
  })
end

---Send the current visual selection as text to Vibe's prompt (submitted).
---In a tree/explorer buffer, instead adds the selected file(s) as @-mentions.
---@return boolean success
function M.send_selection()
  local current_ft = (vim.bo and vim.bo.filetype) or ""
  local is_tree_buffer = current_ft == "NvimTree"
    or current_ft == "neo-tree"
    or current_ft == "oil"
    or current_ft == "minifiles"
    or current_ft == "netrw"
    or current_ft == "snacks_picker_list"

  if is_tree_buffer then
    local integrations = require("vibe.integrations")
    local files, err = integrations.get_selected_files_from_tree()
    if err and (not files or #files == 0) then
      logger.error("send", "VibeSend->tree: " .. err)
      return false
    end
    local any = false
    for _, f in ipairs(files) do
      if M.send_file(f, nil, nil, { context = "VibeSend" }) then
        any = true
      end
    end
    return any
  end

  local text = get_visual_text()
  if not text or text == "" then
    logger.warn("send", "VibeSend: no visual selection found")
    return false
  end
  return M._send_with_retry(text, {
    submit = true,
    paste = true,
    focus = false,
    context = "VibeSend",
  })
end

---Send a Vibe slash command (e.g. "/resume", "/model", "/clear") to the prompt
---and submit it. Launches Vibe first if needed.
---@param slash string The command, including the leading "/".
---@return boolean success
function M.send_slash(slash)
  if not slash or slash == "" then
    return false
  end
  return M._send_with_retry(slash, {
    submit = true,
    paste = false,
    focus = false,
    context = "slash",
  })
end

---Send the diagnostic(s) on the current line to Vibe's prompt (submitted).
---Mirrors the `<leader>ae` Claude keymap: formats the line diagnostics as
---`file:line: message` and sends them so the agent can see the error without
---you copy-pasting it.
---@return boolean success
function M.send_diagnostic()
  local diags = vim.diagnostic.get(0, { lnum = vim.api.nvim_win_get_cursor(0)[1] - 1 })
  if #diags == 0 then
    vim.notify("Aucun diagnostic sur cette ligne", vim.log.levels.WARN)
    return false
  end
  local file = vim.fn.expand("%")
  local lines = {}
  for _, d in ipairs(diags) do
    lines[#lines + 1] = ("%s:%d: %s"):format(file, d.lnum + 1, d.message)
  end
  return M._send_with_retry(table.concat(lines, "\n"), {
    submit = true,
    paste = true,
    focus = false,
    context = "diagnostic",
  })
end

---Resolve the plans directory, defaulting to ~/.vibe/plans when not configured.
---@return string dir Absolute path to the plans directory
local function plans_dir()
  local configured = M.state.config.plans_dir
  return vim.fn.expand(configured and configured ~= "" and configured or "~/.vibe/plans")
end

---List and open a Vibe plan file. Vibe stores each validated plan in
---~/.vibe/plans/<timestamp>-<slug>.md; slugs are generated, so we sort by
---modification time (most recent first) and let vim.ui.select (snacks.picker
---when available) handle the rest. The chosen plan opens in a new tab.
function M.open_plan()
  local dir = plans_dir()
  if vim.fn.isdirectory(dir) == 0 then
    vim.notify("Aucun plan dans " .. dir, vim.log.levels.WARN)
    return
  end
  local files = vim.fn.glob(dir .. "/*.md", false, true)
  if #files == 0 then
    vim.notify("Aucun plan dans " .. dir, vim.log.levels.WARN)
    return
  end
  local function mtime(path)
    local st = vim.uv.fs_stat(path)
    return st and st.mtime.sec or 0
  end
  table.sort(files, function(a, b)
    return mtime(a) > mtime(b)
  end)
  vim.ui.select(files, {
    prompt = "Plan Vibe",
    format_item = function(path)
      return os.date("%d/%m %H:%M", mtime(path)) .. "  " .. vim.fs.basename(path)
    end,
  }, function(choice)
    if choice then
      vim.cmd.tabedit(vim.fn.fnameescape(choice))
    end
  end)
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

---Set up the plugin with user configuration
---@param opts PartialVibeConfig|nil Optional configuration table to override defaults.
---@return table module The plugin module
function M.setup(opts)
  opts = opts or {}

  local config = require("vibe.config")
  M.state.config = config.apply(opts)

  logger.setup(M.state.config)

  -- Map top-level cwd-related aliases into terminal config for convenience
  do
    local t = opts.terminal or {}
    local had_alias = false
    if opts.git_repo_cwd ~= nil then
      t.git_repo_cwd = opts.git_repo_cwd
      had_alias = true
    end
    if opts.cwd ~= nil then
      t.cwd = opts.cwd
      had_alias = true
    end
    if opts.cwd_provider ~= nil then
      t.cwd_provider = opts.cwd_provider
      had_alias = true
    end
    if had_alias then
      opts.terminal = t
    end
  end

  local terminal_setup_ok, terminal_module = pcall(require, "vibe.terminal")
  if terminal_setup_ok then
    if type(terminal_module.setup) == "function" then
      terminal_module.setup(opts.terminal, M.state.config.terminal_cmd, M.state.config.env)
    end
  else
    logger.error("init", "Failed to load vibe.terminal module for setup.")
  end

  M._create_commands()

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("VibeShutdown", { clear = true }),
    callback = function()
      stop_send_timer()
    end,
    desc = "Clean up vibe.nvim pending sends when exiting Neovim",
  })

  M.state.initialized = true
  return M
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

---Set up user commands
---@private
function M._create_commands()
  vim.api.nvim_create_user_command("Vibe", function(opts)
    require("vibe.terminal").simple_toggle(nil, opts.args)
  end, {
    desc = "Toggle the Vibe terminal (launches `vibe` on first open)",
    nargs = "*",
  })

  vim.api.nvim_create_user_command("VibeFocus", function()
    require("vibe.terminal").focus_toggle()
  end, {
    desc = "Smart focus/toggle the Vibe terminal",
  })

  vim.api.nvim_create_user_command("VibeAdd", function(opts)
    local fargs = opts.fargs or {}
    local file = fargs[1]
    if not file or file == "" then
      file = vim.fn.expand("%:p")
    end
    if not file or file == "" then
      vim.notify("VibeAdd: no file to add (save the buffer first).", vim.log.levels.WARN)
      return
    end
    file = vim.fn.expand(file)
    local s = tonumber(fargs[2])
    local e = tonumber(fargs[3])
    M.send_file(file, s, e, { context = "VibeAdd" })
  end, {
    desc = "Add a file (or current buffer) to Vibe context as an @-mention",
    nargs = "*",
    complete = "file",
  })

  vim.api.nvim_create_user_command("VibeSend", function()
    M.send_selection()
  end, {
    desc = "Send visual selection to Vibe (or add file(s) from a tree buffer)",
    range = true,
  })

  vim.api.nvim_create_user_command("VibeSendText", function(opts)
    local text = opts.args
    if not text or text == "" then
      vim.notify("VibeSendText: provide text to send, e.g. :VibeSendText explain this", vim.log.levels.WARN)
      return
    end
    M.send_text(text, { submit = not opts.bang, context = "VibeSendText" })
  end, {
    desc = "Type text into the Vibe prompt and submit (bang inserts without submitting)",
    nargs = "*",
    bang = true,
  })

  vim.api.nvim_create_user_command("VibeTreeAdd", function()
    local integrations = require("vibe.integrations")
    local files, err = integrations.get_selected_files_from_tree()
    if err and (not files or #files == 0) then
      vim.notify("VibeTreeAdd: " .. err, vim.log.levels.WARN)
      return
    end
    for _, f in ipairs(files) do
      M.send_file(f, nil, nil, { context = "VibeTreeAdd" })
    end
  end, {
    desc = "Add the file under the cursor (or selection) in a tree explorer to Vibe",
  })

  vim.api.nvim_create_user_command("VibeNew", function()
    M.send_slash("/clear")
  end, {
    desc = "Start a fresh Vibe session (/clear)",
  })

  ---Relaunch the Vibe terminal: kill the current process, then open a fresh
  ---`vibe` with the given args. Uses kill() (not close()) so the old process is
  ---actually stopped — close() only hides the window and simple_toggle() would
  ---reuse the existing terminal, ignoring any args (same gotcha as claudecode's
  ---<leader>ar needing <leader>aq first). Defined here so VibeResume/Continue/
  ---Restart/Quit all share one restart primitive.
  local function relaunch(cmd_args)
    local terminal = require("vibe.terminal")
    stop_send_timer()
    terminal.kill()
    vim.defer_fn(function()
      terminal.open(nil, cmd_args)
    end, 200)
  end

  vim.api.nvim_create_user_command("VibeResume", function()
    relaunch("--resume")
  end, {
    desc = "Relaunch Vibe with the resume session picker (vibe --resume)",
  })

  vim.api.nvim_create_user_command("VibeModel", function()
    M.send_slash("/model")
  end, {
    desc = "Open Vibe's model picker (/model)",
  })

  vim.api.nvim_create_user_command("VibeCompact", function()
    M.send_slash("/compact")
  end, {
    desc = "Compact the Vibe session context (/compact)",
  })

  vim.api.nvim_create_user_command("VibeStatus", function()
    local terminal = require("vibe.terminal")
    local bufnr = terminal.get_active_terminal_bufnr()
    local provider = M.state.config.terminal and M.state.config.terminal.provider or "auto"
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      logger.info(
        "command",
        "Vibe terminal is running (buffer " .. tostring(bufnr) .. ", provider=" .. tostring(provider) .. ")"
      )
    else
      logger.info("command", "Vibe terminal is not running (provider=" .. tostring(provider) .. ")")
    end
  end, {
    desc = "Show vibe.nvim status",
  })

  vim.api.nvim_create_user_command("VibeContinue", function()
    relaunch("-c")
  end, {
    desc = "Relaunch Vibe resuming the last session (vibe -c)",
  })

  vim.api.nvim_create_user_command("VibeRestart", function(opts)
    relaunch(opts.args)
  end, {
    desc = "Restart the Vibe terminal (optionally with extra args)",
    nargs = "*",
  })

  vim.api.nvim_create_user_command("VibeQuit", function()
    stop_send_timer()
    require("vibe.terminal").kill()
  end, {
    desc = "Kill the Vibe terminal process (force)",
  })

  vim.api.nvim_create_user_command("VibeDiagnostic", function()
    M.send_diagnostic()
  end, {
    desc = "Send the current line's diagnostics to Vibe",
  })

  vim.api.nvim_create_user_command("VibePlans", function()
    M.open_plan()
  end, {
    desc = "List and open a Vibe plan file (~/.vibe/plans/*.md)",
  })
end

return M
