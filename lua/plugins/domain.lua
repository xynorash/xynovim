-- Domain-specific extras (roadmap step 10): treesitter parsers for the SQL
-- injection and the HTTP/shader files, and wgsl-analyzer for Bevy shaders.
-- util.rest (kulala.nvim) is enabled through lazyvim.json.
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "sql", "wgsl" } },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        -- prebuilt binary from Mason; filetype `wgsl` is built into Neovim.
        -- ron-lsp is not in Mason (see README), RON only gets its parser.
        wgsl_analyzer = {},
      },
    },
  },
}
