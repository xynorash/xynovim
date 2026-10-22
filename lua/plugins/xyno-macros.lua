-- Macro help for Rust, from the xyno-macros.nvim plugin: completion inside helper attributes and derives
-- (#[serde(...)], #[arg(...)], #[tokio::main(...)], #[derive(...)], from the schemas the plugin ships),
-- :MacroAttrs, :MacroExpand, :MacroFormatFix, :MacroSignature, :ProcMacroStatus and, with keymaps = true,
-- the buffer-local <leader>rx, <leader>rq and the insert mode <C-k> (the macro popup first, then
-- vim.lsp.buf.signature_help) in Rust buffers with rust-analyzer.
-- Loaded at VeryLazy, as the old setup was (the buffer-local maps have to win over LazyVim's); the
-- blink.cmp spec below calls the plugin when blink.cmp starts, which loads it from there if it was not
-- loaded yet. The two blink sources are registered by blink_opts() exactly as the old specs did
-- (macro_attrs with score_offset 100 for Rust buffers next to the default sources, macro_tools in
-- sources.default); blink.cmp keeps the version it had (the plugin's README pins 1.* for people who
-- do not use LazyVim's blink extra, which already does).
-- The old behaviour stays, as a thin layer over the plugin:
--   * the snippets select! / matches! / vec![x; n] are offered where config/ux.lua's snippets_allowed()
--     says so (the plugin's own default guard is less strict: no expression-node check);
--   * a project overrides or adds attribute schemas in <workspace>/.xynovim/macro_attrs/*.json as
--     before (the plugin's own directory .xyno-macros/attrs is replaced by it via attrs.user_dir).
return {
  {
    "xynorash/xyno-macros.nvim",
    dependencies = { "xynorash/xyno-rust.nvim", "xynorash/xyno-imports.nvim" },
    event = "VeryLazy",
    config = function()
      require("xyno_macros").setup({
        commands = true,
        keymaps = true,
        snippets_allowed = function(ctx)
          local ok, ux = pcall(require, "config.ux")
          return not (ok and ux.snippets_allowed and not ux.snippets_allowed(ctx))
        end,
        attrs = { user_dir = ".xynovim/macro_attrs" },
      })
    end,
  },
  {
    "saghen/blink.cmp",
    opts = function(_, opts)
      return require("xyno_macros").blink_opts(opts)
    end,
  },
}
