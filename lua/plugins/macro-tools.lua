-- Macro call help, macro lens and proc-macro status (config/macro_tools.lua):
-- :MacroExpand, :MacroFormatFix, :MacroSignature, :ProcMacroStatus, the insert
-- mode <C-k> and the blink source for select!/matches!/vec![x; n]. Setup
-- waits for VeryLazy so the buffer-local maps win over LazyVim's.
vim.api.nvim_create_autocmd("User", {
  group = vim.api.nvim_create_augroup("xynovim_macro_tools_load", { clear = true }),
  pattern = "VeryLazy",
  once = true,
  callback = function()
    require("config.macro_tools").setup()
  end,
})
return {
  {
    "saghen/blink.cmp",
    opts = function(_, opts)
      return require("config.macro_tools").blink_opts(_, opts)
    end,
  },
}
