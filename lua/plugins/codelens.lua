-- rust-analyzer's run/debug/references lenses (virtual text above fns).
-- LazyVim ships codelens off; <leader>cc runs the lens, <leader>cC refreshes.
--
-- LazyVim (the pinned commit) still calls vim.lsp.codelens.refresh(), deprecated in Neovim 0.12 (removed in
-- 0.13): every code-lens attach printed a vim.deprecate notice (tests/warnings-guard_spec.lua found it).
-- The replacement is what Neovim's own wrapper forwards to. It is installed from this opts function, which
-- runs when nvim-lspconfig loads (first file), not at startup: touching vim.lsp.codelens from lazy.lua loaded
-- vim.lsp and its submodules before the first screen and cost 2 to 3 ms of every start (paired benchmark,
-- docs/bench/final-2026-11d.md). LazyVim's own opts have already captured the deprecated function in the
-- <leader>cC key by then, so the key is replaced too. Delete this when LazyVim moves to enable().
return {
  "neovim/nvim-lspconfig",
  opts = function(_, opts)
    opts.codelens = vim.tbl_deep_extend("force", opts.codelens or {}, { enabled = true })
    local lens = vim.lsp.codelens
    if lens and type(lens.enable) == "function" and not vim.g.xynovim_codelens_shimmed then
      vim.g.xynovim_codelens_shimmed = true
      local original = lens.refresh
      local function refresh(o)
        lens.enable(true, { bufnr = type(o) == "table" and o.bufnr or nil })
      end
      lens.refresh = refresh
      local star = opts.servers and opts.servers["*"]
      for _, key in ipairs(star and star.keys or {}) do
        if type(key) == "table" and key[2] == original then
          key[2] = refresh
        end
      end
    end
  end,
}
