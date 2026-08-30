if vim.fn.has("nvim-0.8.0") ~= 1 then
  vim.api.nvim_err_writeln("vibe.nvim requires Neovim >= 0.8.0")
  return
end

if vim.g.loaded_vibe then
  return
end
vim.g.loaded_vibe = 1

--- Example: In your `init.lua`, set `vim.g.vibe_auto_setup = { terminal = { provider = "auto" } }`
--- to automatically set up vibe.nvim when Neovim loads.
if vim.g.vibe_auto_setup then
  vim.defer_fn(function()
    require("vibe").setup(vim.g.vibe_auto_setup)
  end, 0)
end

-- Commands are registered in lua/vibe/init.lua's _create_commands function
-- when require("vibe").setup() is called.
-- This file (plugin/vibe.lua) is primarily for the load guard and the
-- optional auto-setup mechanism.

local main_module_ok, _ = pcall(require, "vibe")
if not main_module_ok then
  vim.notify("vibe: Failed to load main module. Plugin may not function correctly.", vim.log.levels.ERROR)
end
