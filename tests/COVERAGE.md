# Feature coverage matrix

Which spec exercises which feature of the config, and what is not tested (with the reason).
Line coverage is a different measure (`scripts/test.sh --coverage`); this table is about features.
Counts are from the last full run: 977 passed, 0 failed, 34 skipped (24 spec files). Skips are
either `pending` entries (not testable here) or known bugs written as assertions of the correct
behaviour (they start passing when the bug is fixed; listed at the end).

| Area (files) | Spec | Notes |
|---|---|---|
| Startup, options, lazy.nvim setup, lockfile, extras, small plugin specs (news, scrolling, telescope, ghost text, codelens, harpoon, navigation), remote clipboard (`config/{options,lazy,remote_clipboard}.lua`, `lazyvim.json`) | `startup-and-options` | fresh-startup facts come from child nvims |
| Clean startup, harness proof | `smoke` | |
| Test helpers | `harness` | |
| Island Dark theme (`colors/`, `lua/island/*`, `plugin/after/*`, `tools/icls2nvim.py`, lualine theme) | `theme-island` | colours written out literally; load time printed, not asserted |
| Global keymaps (`config/keymaps.lua`, diffview/coverage/99/harpoon/dap keys, which-key groups, key uniqueness) | `keymaps-global` | |
| Rust keymaps (`<leader>r*`, `rust_assist.lua`, `rust_nav.lua`, `after/ftplugin/rust.lua`) | `keymaps-rust` | real rust-analyzer for rv, rh, rw, rT, ru, rl; the rest stubbed |
| `:RustContext` (`rust_context.lua`) and its two consumers | `rust-context` | live apply on one workspace |
| `:RustRoutes` (`rust_routes.lua`) | `routes`, `rust-routes` | picker is stubbed |
| `:RustTargets`, `:RustTools`, `:ActJob`, `:RustNew`, doctests, coverage (`rust_tasks.lua`, `plugins/coverage.lua`) | `rust-tasks-tools` | one real `<leader>tc` run with llvm-cov |
| rust-analyzer settings, codelens, inlay hints, taplo, wgsl-analyzer, kulala (`plugins/{rustaceanvim,editing-ui,domain}.lua`) | `rust-analyzer-config`, `rust_spec` | |
| bacon-ls tier (`plugins/bacon-ls.lua`) | `bacon-ls-config` | |
| Server supervision and statusline (`rust_restart.lua`, `lsp_status.lua`, lualine component) | `server-supervision-statusline` | real kill -9 / SIGTERM / loop guard |
| DAP, neotest, overseer, dap-ui (`plugins/dap.lua`, `plugins/rustaceanvim.lua`) | `dap-neotest-coverage` | real codelldb sessions |
| Auto-save and disk guard (`plugins/auto-save.lua`, `disk_guard.lua`) | `auto-save-disk-guard` | typing test runs in tmux |
| 99 agent plugin and Guarded provider (`plugins/ninety-nine.lua`) | `agent-99-guard` | no real claude request |
| Agent sandbox (`agent_sandbox.lua`) | `agent-sandbox` | real bwrap |
| Local history (`local_history.lua`) | `local-history` | fake git wrapper, shimmed timers |
| Diffview, gitsigns, supply-chain linters (`plugins/{diffview,gitsigns,supply-chain}.lua`) | `git-lint-supply-chain` | real cargo-deny, machete, actionlint, zizmor |
| Snippets, completion guard, SQL injections, ghost text off (`snippets/`, `ux.lua`, `after/queries`) | `snippets-completion-injections` | |
| UX menu, diagnostics text, colourblind palette, Neovide, noice, dashboard (`ux.lua`, `editing-ui.lua`) | `ux-menu-diagnostics-colourblind` | |
| `:checkhealth xynovim`, `bootstrap.sh`, CI, Makefile, stylua, `.gitignore`, LICENSE, README prerequisites | `health-bootstrap-ci` | |
| `scripts/test.sh`, `scripts/coverage.lua`, runner/harness/helpers/coverage hook, README/CHANGELOG claims | `test-infra-readme-claims` | |

## Features without a test, or only partly tested

| Feature | Reason |
|---|---|
| A real 99 request to claude | needs a real claude session and network (`agent-99-guard`, pending) |
| lazy.nvim bootstrap clone when missing | needs network and an empty data dir (the script text is checked) |
| Fresh install through `bootstrap.sh` | only with `XYNO_TEST_NETWORK=1` (passed once there, not in the default suite) |
| A real GitHub Actions run | needs a push; the workflow is checked by text, actionlint and zizmor |
| `shellcheck` on the scripts, `stylua --check` | shellcheck not installed; stylua reports drift in 16 files (informational) |
| Global git config (mergiraf, delta, zdiff3, rerere, `dft`/`dlog`), lazygit, README per-repo opt-ins | live in `~/.gitconfig` or are documentation only |
| `[profile.profiling]`, real samply/flamegraph/act runs | `~/.cargo/config.toml` is outside the repo, tools not run |
| Interactive pickers (Snacks/telescope UI), mouse clicks on codelens, narrow terminals, threads that panic, lldb-dap, multi-bin debug launches | need a pty/mouse session or are untested in the README |
| `:RustTargets` / `:RustTools` real terminal behaviour, `<leader>rF/rX/rZ/rN` execution | pickers and terminals are stubbed |
| `<leader>rm rM rj rp rt rC rR rP rk`, `<A-j>/<A-k>`, `rd`, `rE` server effects | only the `RustLsp` call and desc are asserted |
| Second-workspace live updates through rustaceanvim | blocked by the known bug below |
| `vim.v.exiting` branch of `rust_restart.on_exit`, real rustaceanvim handler under the status wrap | cannot be set / only a stand-in is used |
| Local history: real picker, interactive undo, a real 30 s watchdog wait, a lock aged exactly 60 s, submodules, thousands of snapshots | see the pending entries in the spec |
| README timing claims (2.3 ms colourscheme load, 0.56 s edit-to-diagnostic) | printed, only bounded |
| Light-theme background leak, E31 undo_ftplugin message | documented README limitations, informational |
| `scripts/test.sh` under a CI runner without user namespaces | not run there |

## Known bugs found by the specs (skipped, assertions of the correct behaviour)

Repro in the spec named in brackets; each is a `skip("known bug: ...")` or `pending` entry that will start passing once fixed.

1. `rust_nav.goto_super`: an empty definition list is treated as a location, no WARN (`keymaps-rust`). Repro: stub `textDocument/definition` to answer `{}`, press `<leader>ru` in an `impl Shape for Square` method.
2. `rust_routes.collect`: `target`, `.git`, `node_modules`, `bacon-ls-live` are skipped only at the root, not in nested dirs (`rust-routes`). Repro: `crates/a/src/lib.rs` plus `crates/a/target/x.rs` with a route, `collect(root)` lists both.
3. `rust_context.apply` for a second workspace matches no client, the live rust-analyzer is not updated although the state file and notice say it was (`rust-context`). Repro: open `tests/fixtures/workspace/core/src/lib.rs`, then `tests/fixtures/basic/src/lib.rs`, `rc.apply(<basic dir>, {all=false, features={"zzz"}})`: `cargo.allFeatures` stays true.
4. `agent_sandbox`: renaming the parent of the masked memory dir lets an agent plant `MEMORY.md`; `wrap` aborts when `~/.claude` does not exist (`agent-sandbox`). Repro: `d=~/.claude/projects/<p>; mv $d $d-moved; mkdir -p $d/memory; echo x > $d/memory/MEMORY.md` inside the sandbox succeeds.
5. cargo-deny diagnostics on `Cargo.lock` land on the wrong line (`git-lint-supply-chain`). Repro: crate with `time =0.1.45`, `deny.toml`, open `Cargo.lock`, `:lua require('lint').try_lint('cargo_deny')`: line 5 instead of the `time` package.
6. `lsp_status`: the `TextChanged` redraw tests `b:xynovim_bacon`, which nothing sets; the edit counter restarts at 0 after `:edit!` (`server-supervision-statusline`). Repro for the counter: two edits, a clippy run, `:edit!`, LspAttach, one edit: status stays 'clippy ok'.
7. `scripts/test.sh --timeout` without a value exits 1, not 2 (`test-infra-readme-claims`).
8. README says "5 of 80 plugins loaded"; this install has 61 plugins (`test-infra-readme-claims`).
