-- rust-analyzer's run/debug/references lenses (virtual text above fns).
-- LazyVim ships codelens off; <leader>cc runs the lens, <leader>cC refreshes.
return {
  "neovim/nvim-lspconfig",
  opts = { codelens = { enabled = true } },
}
