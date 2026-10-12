-- Island Dark is the permanent theme (colors/island-dark.lua, lua/island/). The
-- config directory is on the runtimepath, so the colorscheme needs no plugin.

return {
  {
    "LazyVim/LazyVim",
    opts = function(_, opts)
      opts.colorscheme = "island-dark"
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      opts.options = opts.options or {}
      opts.options.theme = "island-dark"
    end,
  },
}
