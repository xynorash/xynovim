-- Missing-feature code action ("Enable feature `derive` of `serde`"), <leader>rG
-- and :CrateFeatures (lua/config/crate_features.lua). Loaded from a plugin spec
-- (init runs at startup) so the module owns its commands and keys.
return {
  "neovim/nvim-lspconfig",
  optional = true,
  init = function()
    require("config.crate_features").setup()
  end,
}
