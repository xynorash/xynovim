-- Cargo dependencies, from the xyno-crates.nvim plugin: :CrateAdd (crates.io search, features, target),
-- the unknown-crate hint with "Add crate X", the missing-feature code action and :CrateFeatures, and the
-- crates.io candidates of "Add crate X and import". keymaps = true: <leader>rA (:CrateAdd, buffer-local
-- in Rust and Cargo.toml files) and <leader>rG (fix the missing feature on the cursor line, Rust files).
-- Loaded at VeryLazy, as the old setup was (LazyVim's own keymaps and autocmds have to be in place);
-- xyno-rust.nvim and xyno-imports.nvim are its dependencies (the import source is registered on the
-- engine of xyno-imports.nvim).
-- The old global still works, mapped here when the plugin loads:
--   vim.g.xynovim_crate_check = false  -> vim.g.xyno_crate_check = false (the unknown-crate hint off)
return {
  "xynorash/xyno-crates.nvim",
  dependencies = { "xynorash/xyno-rust.nvim", "xynorash/xyno-imports.nvim" },
  event = "VeryLazy",
  config = function()
    if vim.g.xynovim_crate_check == false and vim.g.xyno_crate_check == nil then
      vim.g.xyno_crate_check = false
    end
    require("xyno_crates").setup({ commands = true, keymaps = true })
  end,
}
