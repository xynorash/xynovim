-- Completion inside helper-attribute arguments (#[serde(...)], #[arg(...)],
-- #[tokio::main(...)], ...) and #[derive(...)], see config/macro_attrs.lua.
-- A blink.cmp source for Rust buffers; the default sources stay (rust-analyzer's own
-- completion is not replaced, this adds what it does not offer).
return {
  "saghen/blink.cmp",
  init = function()
    require("config.macro_attrs").setup()
  end,
  opts = {
    sources = {
      per_filetype = {
        rust = { "macro_attrs", inherit_defaults = true },
      },
      providers = {
        macro_attrs = {
          name = "MacroAttrs",
          module = "config.macro_attrs",
          -- above rust-analyzer's generic path items (core::, std::, ...) inside attributes
          score_offset = 100,
        },
      },
    },
  },
}
