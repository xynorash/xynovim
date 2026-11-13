-- Mason registry pin. Mason resolves every tool (bacon-ls, codelldb, taplo,
-- stylua, ...) through its registry, and the registry names the exact version
-- of each. Following the moving "latest" registry would let any upstream
-- release land on the next `:MasonUpdate`; a release tag of the registry fixes
-- all of them at once. LazyVim's `ensure_installed` takes plain names (no
-- `name@version`), so the registry tag is the pin that is available here.
--
-- Bump: pick a tag from https://github.com/mason-org/mason-registry/releases
-- (or `gh api repos/mason-org/mason-registry/releases/latest --jq .tag_name`),
-- change the string below, run `:MasonUpdate`, then the spec suite
-- (tests/startup-and-options_spec.lua checks the shape of this value).
--
-- Versions this tag resolves to (2026-11-11): bacon 3.26.0, bacon-ls 0.31.0,
-- codelldb 1.12.3, taplo 0.10.0, stylua 2.6.0, shfmt 3.14.1,
-- lua-language-server 3.19.2, marksman 2026-02-08, tree-sitter-cli 0.27.2,
-- wgsl-analyzer 2026-11-02, json-lsp 4.10.0, yaml-language-server 2.0.0,
-- markdownlint-cli2 0.24.0, markdown-toc 1.2.0.
return {
  "mason-org/mason.nvim",
  opts = {
    registries = { "github:mason-org/mason-registry@2026-11-11-roomy-sink" },
  },
}
