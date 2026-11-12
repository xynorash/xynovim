-- Island Light: the light variant of Island Dark (lua/island/light.lua). It is derived from the dark
-- scheme by a lightness flip and a per-group contrast check; it is not a JetBrains scheme.
vim.g.colors_name = nil -- (so that changing 'background' below does not re-source a colorscheme)
vim.cmd("highlight clear")
if vim.fn.exists("syntax_on") == 1 then
  vim.cmd("syntax reset")
end
vim.o.background = "light"
vim.o.termguicolors = true
-- Neovim's own groups (OkMsg, Nvim*, ...) are already light-appropriate defaults now; island.light must not
-- flip those a second time, so it gets the list of what is still untouched after island.setup().
local defaults = vim.api.nvim_get_hl(0, {})
require("island").setup()
require("island.light").apply(defaults)
vim.g.colors_name = "island-light"
vim.schedule(function()
  if vim.g.colors_name == "island-light" then
    require("island.light").late()
  end
end)
