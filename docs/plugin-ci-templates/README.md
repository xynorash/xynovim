# CI templates for the nine xyno-*.nvim repositories

Ready-to-copy files for xyno-history, xyno-sandbox, xyno-clipboard, xyno-guard, xyno-rust, xyno-new, xyno-imports, xyno-crates and xyno-macros. **Nothing here has been applied to or pushed to those repositories**; copying and committing is yours.

| File | Goes to | What it does |
| --- | --- | --- |
| `lint.yml` | `.github/workflows/lint.yml` | `stylua --check .` and `lua-language-server --check` (StyLua v2.6.0 and lua-language-server 3.19.2, each downloaded with a sha256 check, the checkout action pinned by SHA) |
| `stylua.toml` | `.stylua.toml` | the same formatting rules as xynovim (2 spaces, 120 columns); all nine plugins have an equivalent `.stylua.toml` already |
| `luarc.json` | `.luarc.json` | lua-language-server settings: LuaJIT, global `vim`, no third-party library scan, the noisy type checks off (they need Neovim's type stubs, which CI does not have) |
| `dependabot.yml` | `.github/dependabot.yml` | weekly GitHub Actions updates, 7-day cooldown. The plugins are Lua only, there is no other ecosystem to list |
| `SECURITY.md` | `SECURITY.md` | scope and reporting; xyno-sandbox has an alternative paragraph (a seatbelt, not a jail) in a comment |
| `apply.sh` | - | `apply.sh <plugin checkout>` copies the five files above, keeps existing ones (`FORCE=1` overwrites), writes files only and runs no git command |

The plugins' existing `ci.yml` already pins Neovim v0.12.5 with the sha256 `bce0f56e...c6875` (xyno-guard names its variable `NVIM_TAG`), so it needs no change here.

## State of the nine repositories against these templates (measured 2026-11-13, local clones on `dev`)

`stylua --check .` (StyLua 2.6.0, each clone's own `.stylua.toml`, which has the same rules as `stylua.toml` here) passes in all nine. `lua-language-server --check . --checklevel=Warning --configpath docs/plugin-ci-templates/luarc.json` (3.19.2, the exact flags and settings of `lint.yml`) reports nothing in all nine. Before the fixes of that day it reported one finding in each of five clones: xyno-crates `tests/init_spec.lua` (`package.loaders` flagged deprecated; LuaJIT has no `package.searchers`, so a precise `---@diagnostic disable-next-line: deprecated` with that reason), xyno-history `panel.lua` (`M.open` returns nothing outside a git worktree: annotated `table?`), xyno-macros `init.lua` and xyno-sandbox `ui.lua` (a one-line `@param` table type that LuaLS cannot parse: now an `@class`), xyno-new `egui.lua` (ambiguous `or` / `..` mix: parenthesised). `vim.diff`, deprecated in Neovim 0.12, is `vim.text.diff` in xyno-rust, xyno-history and xyno-sandbox.

None of the clones has `.github/workflows/lint.yml` or `.luarc.json` yet: copy them with `apply.sh` (the clones' `.stylua.toml` already exist). A real GitHub Actions run of `lint.yml` has not happened (nothing was pushed). `luacheck` is not used: it is not installed here and the workflows do not run it, so what is documented is what was run.

A stricter local run (not part of the CI: the main repo's `.luarc.json` with Neovim's own `lua/` and `lua/vim/_meta` as `workspace.library` and none of the type checks disabled) reports 309 findings in the main repository, mostly `param-type-mismatch` (81), `need-check-nil` (80), `duplicate-set-field` (40) and `different-requires` (38): I did not triage them one by one; the other categories (about 40 findings) I read: `deprecated` was the real `vim.diff` (fixed), the rest are stub or test-double mismatches. They are the reason those checks are off in `luarc.json`.

## What the lint does not do

It does not run the specs (that is `ci.yml`), does not type-check against Neovim's API (no `vim.*` stubs are loaded, so `undefined-field` and friends are off), and does not look for unused locals. It catches syntax slips, undefined globals, malformed annotations and formatting drift.
