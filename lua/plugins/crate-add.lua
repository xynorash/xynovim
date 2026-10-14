-- :CrateAdd, <leader>rA and the unknown-crate hint (config/crate_add.lua).
-- Setup waits for VeryLazy so LazyVim's own keymaps and autocmds are in place
-- (a lazy.nvim virtual plugin would be one more entry in the plugin count).
vim.api.nvim_create_autocmd("User", {
  group = vim.api.nvim_create_augroup("xynovim_crate_add_load", { clear = true }),
  pattern = "VeryLazy",
  once = true,
  callback = function()
    require("config.crate_add").setup()
  end,
})
return {}
