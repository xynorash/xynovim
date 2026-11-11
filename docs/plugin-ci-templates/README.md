# CI templates for the nine xyno-*.nvim repositories

Ready-to-copy files for xyno-history, xyno-sandbox, xyno-clipboard, xyno-guard, xyno-rust, xyno-new, xyno-imports, xyno-crates and xyno-macros. **Nothing here has been applied to or pushed to those repositories**; copying and committing is yours.

| File | Goes to | What it does |
| --- | --- | --- |
| `lint.yml` | `.github/workflows/lint.yml` | `stylua --check .` and `lua-language-server --check` (StyLua v2.6.0 and lua-language-server 3.19.2, each downloaded with a sha256 check, the checkout action pinned by SHA) |
| `stylua.toml` | `.stylua.toml` | the same formatting rules as xynovim (2 spaces, 120 columns); the plugins already have an identical file except xyno-history, which has none |
| `luarc.json` | `.luarc.json` | lua-language-server settings: LuaJIT, global `vim`, no third-party library scan, the noisy type checks off (they need Neovim's type stubs, which CI does not have) |
| `dependabot.yml` | `.github/dependabot.yml` | weekly GitHub Actions updates, 7-day cooldown. The plugins are Lua only, there is no other ecosystem to list |
| `SECURITY.md` | `SECURITY.md` | scope and reporting; xyno-sandbox has an alternative paragraph (a seatbelt, not a jail) in a comment |
| `apply.sh` | - | `apply.sh <plugin checkout>` copies the five files above, keeps existing ones (`FORCE=1` overwrites), writes files only and runs no git command |

The plugins' existing `ci.yml` already pins Neovim v0.12.5 with the sha256 `bce0f56e...c6875` (xyno-guard names its variable `NVIM_TAG`), so it needs no change here.

## State of the nine repositories against these templates (measured 2026-11-12, local clones on `dev`)

`lint.yml` fails on the first run of every repository until the formatting is applied once (`stylua .`, commit it separately), and in four of them until one finding is fixed:

| Repository | Lua files StyLua would change | lua-language-server (Warning level) |
| --- | --- | --- |
| xyno-clipboard | 3 of 6 | clean |
| xyno-crates | 12 of 18 | 1: `tests/init_spec.lua:19` `package.loaders or package.searchers` flagged as deprecated |
| xyno-guard | 2 of 5 | clean |
| xyno-history | 11 of 15 | clean |
| xyno-imports | 7 of 10 | clean |
| xyno-macros | 11 of 14 | 1: `lua/xyno_macros/init.lua:26` malformed `---@` annotation (`}` expected) |
| xyno-new | 9 of 13 | 1: `lua/xyno_new/egui.lua:357` ambiguous string concatenation (`ambiguity-1`, add brackets) |
| xyno-rust | 18 of 25 | clean |
| xyno-sandbox | 16 of 21 | 1: `lua/xyno_sandbox/ui.lua:199` malformed annotation (`}` expected) |

The check was run on a copy of each repository's `lua/` and `tests/` with `luarc.json`; on a clone of xyno-clipboard the whole sequence (apply, `stylua .`, `stylua --check .`, `lua-language-server --check`) passed, and `actionlint` and `zizmor` report nothing for `lint.yml`. A real GitHub Actions run of `lint.yml` has not happened (nothing was pushed).

## What the lint does not do

It does not run the specs (that is `ci.yml`), does not type-check against Neovim's API (no `vim.*` stubs are loaded, so `undefined-field` and friends are off), and does not look for unused locals. It catches syntax slips, undefined globals, malformed annotations and formatting drift.
