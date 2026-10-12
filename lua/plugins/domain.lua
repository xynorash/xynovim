-- Domain-specific extras (roadmap step 10): treesitter parsers for the SQL
-- injection and the HTTP/shader files, and wgsl-analyzer for Bevy shaders.
-- util.rest (kulala.nvim) is enabled through lazyvim.json.
return {
  {
    -- Pinned to the last 5.x release. From v6.0.0 kulala.nvim needs a separate
    -- kulala-core binary (v6.32+ behind a license token, and the public
    -- GitHub release it used to fetch is gone, 404), so v6 cannot send a
    -- request without an account. 5.x talks to curl directly.
    -- submodules = false: the repo has a v6 submodule (fmt/); lazy's
    -- `--recurse-submodules` checkout of the pinned tag failed on a fresh
    -- install ("gitfile does not point to a valid repository") and left
    -- v6 checked out.
    "mistweaverco/kulala.nvim",
    tag = "v5.3.4",
    submodules = false,
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "sql", "wgsl" } },
  },
  {
    "mason-org/mason.nvim",
    opts = { ensure_installed = { "wgsl-analyzer" } },
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
