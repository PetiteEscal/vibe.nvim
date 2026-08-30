--- Health check for vibe.nvim, run via :checkhealth vibe
--- Verifies prerequisites (Neovim version, Vibe CLI, terminal provider) and
--- reports whether setup() was called and whether a Vibe terminal is running.
---@module 'vibe.health'
local M = {}

-- vim.health gained start/ok/warn/error in Neovim 0.10; older versions use report_* variants.
local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local error_ = health.error or health.report_error
local info = health.info or health.report_info or ok

---Extracts the executable (first token) from a command string.
---@param cmd string
---@return string executable
local function executable_of(cmd)
  assert(type(cmd) == "string" and cmd ~= "", "cmd must be a non-empty string")
  return cmd:match("^(%S+)") or cmd
end

local function check_neovim()
  if vim.fn.has("nvim-0.8.0") == 1 then
    ok("Neovim >= 0.8.0")
  else
    error_("Neovim >= 0.8.0 is required")
  end
end

---@param vibe table The main plugin module
local function check_setup(vibe)
  if vibe.state.initialized then
    ok("vibe.nvim " .. vibe.version:string() .. " is set up")
    return true
  end
  error_("setup() has not been called", { 'Call require("vibe").setup() (or use your plugin manager\'s opts)' })
  return false
end

---@param config table The merged plugin config
local function check_cli(config)
  local terminal_cmd = config.terminal_cmd
  local cmd = (terminal_cmd and terminal_cmd ~= "") and terminal_cmd or "vibe"
  local exe = executable_of(cmd)

  if vim.fn.executable(exe) ~= 1 then
    error_(("Vibe CLI not found: '%s' is not executable"):format(exe), {
      "Install Mistral Vibe: https://docs.mistral.ai/vibe/code/cli/install-setup",
      "Or set `terminal_cmd` in setup() to the full path of the `vibe` binary",
    })
    return
  end

  ok(("Vibe CLI found: %s (%s)"):format(exe, vim.fn.exepath(exe)))

  local version_ok, output = pcall(vim.fn.system, { exe, "--version" })
  if version_ok and vim.v.shell_error == 0 then
    info("CLI version: " .. vim.trim(output))
  else
    warn(("'%s --version' failed; the configured command may not be the Vibe CLI"):format(exe))
  end
end

---@param config table The merged plugin config
local function check_terminal_provider(config)
  local provider = config.terminal and config.terminal.provider or "auto"
  if type(provider) == "table" then
    info("Terminal provider: custom (table)")
    return
  end

  if provider == "auto" or provider == "snacks" then
    local has_snacks = pcall(require, "snacks")
    if has_snacks then
      ok(("Terminal provider '%s': snacks.nvim available"):format(provider))
    elseif provider == "snacks" then
      error_("Terminal provider 'snacks' configured but snacks.nvim is not installed")
    else
      ok("Terminal provider 'auto': snacks.nvim not installed, will fall back to native terminal")
    end
  elseif provider == "external" then
    local cmd = config.terminal.provider_opts and config.terminal.provider_opts.external_terminal_cmd
    if cmd and (type(cmd) == "function" or cmd:find("%%s")) then
      ok("Terminal provider 'external' configured")
    else
      error_("Terminal provider 'external' requires provider_opts.external_terminal_cmd containing '%s'")
    end
  elseif provider == "none" then
    warn("Terminal provider 'none': Vibe runs outside Neovim; send commands have no pane to write to")
  else
    ok(("Terminal provider: %s"):format(provider))
  end
end

---@param vibe table The main plugin module
local function check_terminal_state(vibe)
  local terminal = require("vibe.terminal")
  local bufnr = terminal.get_active_terminal_bufnr()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    ok(("Vibe terminal is running (buffer %d)"):format(bufnr))
  else
    info("No Vibe terminal running yet (launch one with :Vibe)")
  end
end

function M.check()
  start("vibe.nvim")

  check_neovim()

  local loaded, vibe = pcall(require, "vibe")
  if not loaded then
    error_("Could not load vibe module: " .. tostring(vibe))
    return
  end

  if not check_setup(vibe) then
    return
  end

  check_cli(vibe.state.config)
  check_terminal_provider(vibe.state.config)
  check_terminal_state(vibe)
end

return M
