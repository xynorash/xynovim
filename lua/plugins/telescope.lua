-- telescope.nvim is only a dependency of 99 (model/provider pickers). With no
-- event/keys/cmd of its own lazy.nvim classifies it as a start plugin and loads
-- it at startup; lazy = true makes it load on first require (from 99's
-- telescope extension) instead.
return {
  { "nvim-telescope/telescope.nvim", lazy = true },
}
