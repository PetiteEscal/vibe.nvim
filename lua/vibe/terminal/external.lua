--- External terminal provider for Vibe.
---Launches Vibe in an external terminal application using a user-specified command.
---@module 'vibe.terminal.external'

---@type VibeTerminalProvider
local M = {}

local logger = require("vibe.logger")
local utils = require("vibe.utils")

local jobid = nil
---@type VibeTerminalConfig
local config

local function cleanup_state()
  jobid = nil
end

local function is_valid()
  return jobid and jobid > 0
end

---@param term_config VibeTerminalConfig
function M.setup(term_config)
  config = term_config or {}
end

---@param cmd_string string
---@param env_table table
function M.open(cmd_string, env_table)
  if is_valid() then
    logger.debug("terminal", "External Vibe terminal is already running")
    return
  end

  local external_cmd = config.provider_opts and config.provider_opts.external_terminal_cmd

  if not external_cmd then
    vim.notify(
      "external_terminal_cmd not configured. Please set terminal.provider_opts.external_terminal_cmd in your config.",
      vim.log.levels.ERROR
    )
    return
  end

  local cmd_parts
  local full_command
  local cwd_for_jobstart = nil

  if type(external_cmd) == "function" then
    local result = external_cmd(cmd_string, env_table)
    if not result then
      vim.notify("external_terminal_cmd function returned nil or false", vim.log.levels.ERROR)
      return
    end

    if type(result) == "string" then
      cmd_parts = utils.parse_command(result)
      full_command = result
    elseif type(result) == "table" then
      cmd_parts = result
      full_command = table.concat(result, " ")
    else
      vim.notify(
        "external_terminal_cmd function must return a string or table, got: " .. type(result),
        vim.log.levels.ERROR
      )
      return
    end
  elseif type(external_cmd) == "string" then
    if external_cmd == "" then
      vim.notify("external_terminal_cmd string cannot be empty", vim.log.levels.ERROR)
      return
    end

    local _, placeholder_count = external_cmd:gsub("%%s", "")

    if placeholder_count == 0 then
      vim.notify("external_terminal_cmd must contain '%s' placeholder(s) for the command.", vim.log.levels.ERROR)
      return
    elseif placeholder_count == 1 then
      full_command = string.format(external_cmd, cmd_string)
    elseif placeholder_count == 2 then
      local cwd = vim.fn.getcwd()
      cwd_for_jobstart = cwd
      full_command = string.format(external_cmd, cwd, cmd_string)
    else
      vim.notify(
        string.format(
          "external_terminal_cmd must use 1 '%%s' (command) or 2 '%%s' placeholders (cwd, command); got %d",
          placeholder_count
        ),
        vim.log.levels.ERROR
      )
      return
    end

    cmd_parts = utils.parse_command(full_command)
  else
    vim.notify("external_terminal_cmd must be a string or function, got: " .. type(external_cmd), vim.log.levels.ERROR)
    return
  end

  cwd_for_jobstart = cwd_for_jobstart or (vim.fn.getcwd and vim.fn.getcwd() or nil)

  -- jobstart (like termopen) rejects an empty `env = {}`; only set it when non-empty.
  local job_opts = {
    detach = true,
    cwd = cwd_for_jobstart,
    on_exit = function(job_id, exit_code, _)
      vim.schedule(function()
        if job_id == jobid then
          cleanup_state()
        end
      end)
    end,
  }
  if env_table and next(env_table) ~= nil then
    job_opts.env = env_table
  end

  jobid = vim.fn.jobstart(cmd_parts, job_opts)

  if not jobid or jobid <= 0 then
    vim.notify("Failed to start external terminal with command: " .. full_command, vim.log.levels.ERROR)
    cleanup_state()
    return
  end
end

function M.close()
  if is_valid() then
    vim.fn.jobstop(jobid)
    cleanup_state()
  end
end

--- Simple toggle: always start external terminal (can't hide external terminals)
---@param cmd_string string
---@param env_table table
---@param effective_config table
function M.simple_toggle(cmd_string, env_table, effective_config)
  if is_valid() then
    M.close()
  else
    M.open(cmd_string, env_table, effective_config, true)
  end
end

--- Smart focus toggle: same as simple toggle for external terminals
---@param cmd_string string
---@param env_table table
---@param effective_config table
function M.focus_toggle(cmd_string, env_table, effective_config)
  M.simple_toggle(cmd_string, env_table, effective_config)
end

--- Legacy toggle function for backward compatibility
---@param cmd_string string
---@param env_table table
---@param effective_config table
function M.toggle(cmd_string, env_table, effective_config)
  M.simple_toggle(cmd_string, env_table, effective_config)
end

---@return number?
function M.get_active_bufnr()
  -- External terminals don't have associated Neovim buffers
  return nil
end

--- No-op function for external terminals since we can't ensure visibility of external windows
function M.ensure_visible() end

---@return boolean
function M.is_available()
  return true
end

---@return table?
function M._get_terminal_for_test()
  if is_valid() then
    return { jobid = jobid }
  end
  return nil
end

return M
