-- Minimal Neovim init used to run the vibe.nvim test suite headlessly.
-- Loaded via: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec"
--
-- It wires plenary.nvim and the plugin itself onto the runtimepath so that
-- `require("vibe")` resolves without a full user config.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

-- plenary.nvim is cloned by CI (or git-submodule / local install) into the
-- tests/.deps directory; fall back to a standard data path if present.
local plenary_path = plugin_root .. "/tests/.deps/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 0 then
  plenary_path = vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim"
end

for _, p in ipairs({ plenary_path, plugin_root }) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end

-- Keep a minimal setup so specs that touch `vibe.config`/`vibe.logger` work.
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
