-- Auto-import, ranked disambiguation, organize imports (config/import_engine.lua).
-- Setup waits for VeryLazy, like the rest of the UI layer: keys and commands
-- need LazyVim's own maps in place to leave them alone.
vim.api.nvim_create_autocmd("User", {
  group = vim.api.nvim_create_augroup("xynovim_import_engine_load", { clear = true }),
  pattern = "VeryLazy",
  once = true,
  callback = function()
    require("config.import_engine").setup()
    -- crates.io candidates for names no dependency offers (Add crate X and import)
    require("config.crate_import").setup()
  end,
})
return {}
