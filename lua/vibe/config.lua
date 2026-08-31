---@brief [[
--- Manages configuration for the Vibe Neovim integration.
--- Provides default settings, validation, and application of user-defined configurations.
---@brief ]]
---@module 'vibe.config'

local M = {}

---@type VibeConfig
M.defaults = {
  -- Command used to launch the Vibe CLI. nil => use "vibe" from PATH.
  -- For a local install you can set this to the absolute path, e.g. "~/.local/bin/vibe".
  terminal_cmd = nil,
  -- Custom environment variables for the Vibe terminal process.
  env = {},
  log_level = "info", -- "trace", "debug", "info", "warn", "error"

  -- When true, a successful "send" focuses the in-editor Vibe terminal if it is
  -- already running. Only meaningful for the in-editor providers ("native"/"snacks").
  focus_after_send = false,

  -- How long (ms) to keep retrying a send while the Vibe terminal is still
  -- booting up (no job channel yet). Prevents lost @-mentions when you trigger
  -- a send on a fresh launch.
  startup_send_timeout = 15000,
  -- Delay (ms) between send retries while waiting for the terminal channel.
  send_retry_interval = 300,

  -- Keep a minimal terminal config here instead of requiring vibe.terminal
  -- during config.apply(). Loading the terminal module pulls in the provider
  -- modules and makes coverage-enabled config validation unexpectedly slow.
  terminal = {
    provider = "auto", -- "auto", "snacks", "native", "external", "none", or custom provider table
    provider_opts = {
      external_terminal_cmd = nil,
    },
  },

  -- Directory where the Vibe CLI stores plan files (<timestamp>-<slug>.md).
  -- nil => defaults to ~/.vibe/plans at runtime. Override only if you pointed
  -- the CLI at a different plans directory.
  plans_dir = nil,
}

---Validates the provided configuration table.
---Throws an error if any validation fails.
---@param config table The configuration table to validate.
---@return boolean true if the configuration is valid.
function M.validate(config)
  assert(config.terminal_cmd == nil or type(config.terminal_cmd) == "string", "terminal_cmd must be nil or a string")

  -- Validate terminal config
  assert(type(config.terminal) == "table", "terminal must be a table")

  -- Validate provider_opts if present
  if config.terminal.provider_opts then
    assert(type(config.terminal.provider_opts) == "table", "terminal.provider_opts must be a table")

    -- Validate external_terminal_cmd in provider_opts
    if config.terminal.provider_opts.external_terminal_cmd then
      local cmd_type = type(config.terminal.provider_opts.external_terminal_cmd)
      assert(
        cmd_type == "string" or cmd_type == "function",
        "terminal.provider_opts.external_terminal_cmd must be a string or function"
      )
      -- Only validate %s placeholder for strings
      if cmd_type == "string" and config.terminal.provider_opts.external_terminal_cmd ~= "" then
        assert(
          config.terminal.provider_opts.external_terminal_cmd:find("%%s"),
          "terminal.provider_opts.external_terminal_cmd must contain '%s' placeholder for the Vibe command"
        )
      end
    end
  end

  local valid_log_levels = { "trace", "debug", "info", "warn", "error" }
  local is_valid_log_level = false
  for _, level in ipairs(valid_log_levels) do
    if config.log_level == level then
      is_valid_log_level = true
      break
    end
  end
  assert(is_valid_log_level, "log_level must be one of: " .. table.concat(valid_log_levels, ", "))

  -- Allow absence in direct validate() calls; apply() supplies default
  if config.focus_after_send ~= nil then
    assert(type(config.focus_after_send) == "boolean", "focus_after_send must be a boolean")
  end

  assert(
    type(config.startup_send_timeout) == "number" and config.startup_send_timeout >= 0,
    "startup_send_timeout must be a non-negative number"
  )
  assert(
    type(config.send_retry_interval) == "number" and config.send_retry_interval >= 0,
    "send_retry_interval must be a non-negative number"
  )

  -- Validate env
  assert(type(config.env) == "table", "env must be a table")
  for key, value in pairs(config.env) do
    assert(type(key) == "string", "env keys must be strings")
    assert(type(value) == "string", "env values must be strings")
  end

  assert(config.plans_dir == nil or type(config.plans_dir) == "string", "plans_dir must be nil or a string")

  return true
end

---Applies user configuration on top of default settings and validates the result.
---@param user_config table|nil The user-provided configuration table.
---@return VibeConfig config The final, validated configuration table.
function M.apply(user_config)
  local config = vim.deepcopy(M.defaults)

  if user_config then
    -- Use vim.tbl_deep_extend if available, otherwise simple merge
    if vim.tbl_deep_extend then
      config = vim.tbl_deep_extend("force", config, user_config)
    else
      -- Simple fallback for testing environment
      for k, v in pairs(user_config) do
        config[k] = v
      end
    end
  end

  M.validate(config)

  return config
end

return M
