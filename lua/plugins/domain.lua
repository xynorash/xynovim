-- Domain-specific extras (roadmap step 10): treesitter parsers for the SQL
-- injection and the HTTP/shader files, and wgsl-analyzer for Bevy shaders.
-- util.rest (kulala.nvim) is enabled through lazyvim.json.
return {
  {
    -- Pinned: from v6.32.0 on, kulala.nvim downloads its kulala-core backend
    -- behind a license token (inputsecret prompt on first use, which also
    -- hangs headless runs). v6.31.1 is the last release that fetches it from
    -- public GitHub releases. Unpin only if you hold a token
    -- (KULALA_CORE_LICENSE_TOKEN).
    "mistweaverco/kulala.nvim",
    tag = "v6.31.1",
  },
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
