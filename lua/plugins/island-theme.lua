-- Island Dark is the permanent theme (colors/island-dark.lua, lua/island/). The
-- config directory is on the runtimepath, so the colorscheme needs no plugin.
-- Omarchy's theme spec (lua/plugins/theme.lua) is neutralised in
-- config/lazy.lua; set `vim.g.xynovim_follow_omarchy = true` in
-- lua/config/options.lua to follow Omarchy again.
local function island()
  return not vim.g.xynovim_follow_omarchy
end

return {
  {
    "LazyVim/LazyVim",
    opts = function(_, opts)
      if island() then
        opts.colorscheme = "island-dark"
      end
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      if island() then
        opts.options = opts.options or {}
        opts.options.theme = "island-dark"
      end
    end,
  },
}
