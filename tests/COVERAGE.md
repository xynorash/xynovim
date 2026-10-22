# Feature coverage matrix

Which spec exercises which feature of the config, and what is not tested (with the reason).
Line coverage is a different measure (`scripts/test.sh --coverage`); this table is about features.
Counts are from the last full run: 1744 passed, 0 failed, 23 skipped (36 spec files). Skips are
`pending` entries or tests that need something this machine lacks (not testable here). A bug a spec
finds is written as an assertion of the correct behaviour (skipped while it reproduces); the ones
found so far are fixed (listed at the end).

| Area (files) | Spec | Notes |
|---|---|---|
| Startup, options, lazy.nvim setup, lockfile, extras, small plugin specs (news, scrolling, telescope, ghost text, codelens, harpoon, navigation), the clipboard glue of `xyno-clipboard.nvim` (`config/{options,lazy}.lua`, `plugins/xyno-clipboard.lua`, `lazyvim.json`; the provider itself is covered in the plugin repository) | `startup-and-options` | fresh-startup facts come from child nvims |
| Clean startup, harness proof | `smoke` | |
| Test helpers | `harness` | |
| Island Dark theme (`colors/`, `lua/island/*`, `plugin/after/*`, `tools/icls2nvim.py`, lualine theme) | `theme-island` | colours written out literally; converter tested on a synthetic `.icls` rebuilt from the palette; load time printed, not asserted |
| Global keymaps (`config/keymaps.lua`, diffview/coverage/99/harpoon/dap keys, which-key groups, key uniqueness) | `keymaps-global` | |
| Rust keymaps (`<leader>r*`, `rust_assist.lua`, the `rust_nav` keys, `after/ftplugin/rust.lua`) | `keymaps-rust` | real rust-analyzer for rv, rh, rw, rT; the rest stubbed; the rust_nav module itself is covered in the xyno-rust.nvim repository |
| `:RustContext` consumers (`plugins/rustaceanvim.lua` server.settings, `plugins/bacon-ls.lua`) and the live bacon-ls half; the module itself is covered in the xyno-rust.nvim repository | `rust-context` | live apply on one workspace |
| The `<leader>rN` map of `:RustRoutes`; `routes` is the small hermetic sample spec of the runner specs (the route module is covered in the xyno-rust.nvim repository) | `routes`, `rust-routes` | |
| `:RustTargets`, `:RustTools`, `:ActJob`, `:RustNew`, doctests, coverage (`plugins/coverage.lua`; the `xyno_rust.rust_tasks` module and its other cases are covered in the xyno-rust.nvim repository) | `rust-tasks-tools` | one real `<leader>tc` run with llvm-cov |
| rust-analyzer settings, codelens, inlay hints, taplo, wgsl-analyzer, kulala (`plugins/{rustaceanvim,editing-ui,domain}.lua`) | `rust-analyzer-config`, `rust_spec` | |
| bacon-ls tier (`plugins/bacon-ls.lua`) | `bacon-ls-config` | |
| Server supervision and statusline (`xyno_rust.rust_restart`, `xyno_rust.lsp_status`, lualine component; the fake-client cases are in the xyno-rust.nvim repository, here the live bacon-ls cases) | `server-supervision-statusline` | real kill -9 / SIGTERM / loop guard |
| DAP, neotest, overseer, dap-ui (`plugins/dap.lua`, `plugins/rustaceanvim.lua`) | `dap-neotest-coverage` | real codelldb sessions |
| Auto-save and its guard (`plugins/auto-save.lua`, `plugins/xyno-guard.lua`; the guard itself is covered in the xyno-guard.nvim repository) | `auto-save-disk-guard` | typing test runs in tmux |
| 99 agent plugin and Guarded provider (`plugins/ninety-nine.lua`) | `agent-99-guard` | no real claude request |
| Agent sandbox through `xyno-sandbox.nvim` (`plugins/xyno-sandbox.lua`; the bwrap command itself is covered in the plugin repository) | `agent-99-guard`, `agent-failclosed` | real bwrap |
| Agent sandbox fails closed, the guarded provider refuses without a backend, on every OS | `agent-failclosed` | |
| Provider picker `<leader>9P` cannot leave the guarded provider | `agent-99-guard` | no real provider CLI |
| Portable runner (`scripts/test.lua`, `scripts/test.ps1`), `xyno-os` headers, `scripts/bootstrap.ps1`, `platforms.yml` | `scripts-portable` | the PowerShell scripts and the workflow only run in the platforms workflow (Windows, macOS) |
| Local history through `xyno-history.nvim` (`plugins/xyno-history.lua`: wiring, old `vim.g` caps, pre-split snapshots, integrations; the module itself is covered in the plugin repository) | `local-history` | |
| Diffview, gitsigns, supply-chain linters (`plugins/{diffview,gitsigns,supply-chain}.lua`) | `git-lint-supply-chain` | real cargo-deny, machete, actionlint, zizmor |
| Snippets, completion guard, SQL injections, ghost text off (`snippets/`, `ux.lua`, `after/queries`) | `snippets-completion-injections` | |
| UX menu, diagnostics text, colourblind palette, Neovide, noice, dashboard (`ux.lua`, `editing-ui.lua`) | `ux-menu-diagnostics-colourblind` | |
| `:checkhealth xynovim`, `bootstrap.sh`, CI, Makefile, stylua, `.gitignore`, LICENSE, README prerequisites | `health-bootstrap-ci` | |
| Website: `site/`, `scripts/build-site.py`, `.github/workflows/pages.yml` (built into a temp dir: head tags, links, anchors, CSP, alt texts, README numbers, budgets, contrast, workflow pins and permissions) | `site` | no browser: the screenshots were checked by hand; the deployment itself is only observable on GitHub |
| `scripts/test.sh`, `scripts/coverage.lua`, runner/harness/helpers/coverage hook, README/CHANGELOG claims | `test-infra-readme-claims` | |
| Dependency freshness: `deps resolving` status, bacon-ls restart on a saved `Cargo.toml` / `Cargo.lock` (`xyno_rust.rust_restart`, `xyno_rust.lsp_status`) | `deps-freshness`, `server-supervision-statusline` | real rust-analyzer; the 120 s ceiling is a shimmed timer |
| Crate metadata, crates.io client, registry sources (`xyno_rust.crate_meta`, `xyno_rust.code_actions`) | covered in the xyno-rust.nvim repository; xynovim's crate_add, crate_features, import_engine, macro specs use them | network parts skip offline |
| Unknown-crate hint, "Add crate" action, `:CrateAdd`, `<leader>rA` (`crate_add.lua`) | `crate-add` | real `cargo add` on temp crates; picker stubbed |
| Missing-feature fix, `:CrateFeatures`, `<leader>rG` (`crate_features.lua`) | `crate-features` | real `cargo check --offline`; diagnostic is hand-made |
| Import engine: auto-import modes, ranking, per-project memory, organize, paste, `:ImportName/:ImportForget/:ImportOrganize`, `<leader>rI/rO` (`import_engine.lua`) | `import-engine` | real rust-analyzer; picker stubbed |
| Import from crates that are not dependencies, add-and-import (`crate_import.lua`) | `crate-import` | one real `Uuid` run (needs crates.io, skips offline) |
| Attribute and derive completion, schemas, project overrides, `:MacroAttrs` (`macro_attrs.lua`, `data/macro_attrs/`) | `macro-attrs` | pure core driven table-wise; blink menu not on screen |
| Macro signature / format / sqlx hints, `:MacroExpand` lens, `:ProcMacroStatus`, `<leader>rx/rq` (`macro_tools.lua`) | `macro-tools` | lens and status windows asserted, not looked at in a terminal |
| Cross-module flows: no-deps crate to import, missing feature fix, `#[serde(` after the fix, ambiguous `Error` remembered | `macros-deps-flows` | on temp fixture copies; skips without network, cargo or rust-analyzer |
| New Rust projects: `:RustNewBin`, `:RustNewLib`, `:RustNewWorkspace`, `:RustNewMember`, the three dashboard entries and their layouts at 80x24 / 100x30 / 190x50 and more (`rust_new.lua`, `plugins/rust-new.lua`, the dashboard override in `plugins/editing-ui.lua`) | `rust-new` | pure functions table-wise; the flows run the real `cargo` offline in temp directories (`cargo metadata`, `cargo check`); failure paths with a stub `cargo`, an empty PATH and a read-only parent (skips as root); the dashboard rendered in tmux; the prompts are stubbed, the three flows were also driven by hand in tmux at 80x24 |
| New egui project: `:EguiNew`, the dashboard entry, name / author rules, replacement rules, ETag cache, archive checks, toolchain pin removal and the minimum Rust version check (`egui_new.lua`, `plugins/egui.lua`) | `egui-new` | fake template over `file://` and a local HTTP server; one real-network test (skips offline); no `cargo` build in the suite; the version check runs against a stub `rustc` on PATH (older / equal / newer / missing / garbage), and a stub `rustup` proves it is never called; the real template was generated and checked once by hand |

## Features without a test, or only partly tested

| Feature | Reason |
|---|---|
| A real 99 request to claude | needs a real claude session and network (`agent-99-guard`, pending) |
| lazy.nvim bootstrap clone when missing | needs network and an empty data dir (the script text is checked) |
| Fresh install through `bootstrap.sh` | only with `XYNO_TEST_NETWORK=1` (passed once there, not in the default suite) |
| A real GitHub Actions run | needs a push; the workflow is checked by text, actionlint and zizmor |
| `shellcheck` on the scripts, `stylua --check` | shellcheck passes on `scripts/*.sh` and `docs/media/*.sh`; stylua reports drift in 61 files since the macros and dependencies work, 16 before (informational) |
| Global git config (mergiraf, delta, zdiff3, rerere, `dft`/`dlog`), lazygit, README per-repo opt-ins | live in `~/.gitconfig` or are documentation only |
| Snacks pickers and key presses of the macro and dependency features in a real TUI, the `ask` prompt, `<leader>rI` / `<leader>rG` interactively | pickers and `vim.ui.select` are stubbed; no pty driving |
| Crate guesses that do not match by name (`Rng` does not find `rand`) | crates.io is searched by crate name; documented limit, the import step times out after 60 s with a message |
| `#[serde(` keys while serde's `derive` feature is off | known: schemas are chosen by dependency and derive, not by features |
| `[profile.profiling]`, real samply/flamegraph/act runs | `~/.cargo/config.toml` is outside the repo, tools not run |
| Interactive pickers (Snacks/telescope UI), mouse clicks on codelens, narrow terminals, threads that panic, lldb-dap, multi-bin debug launches | need a pty/mouse session or are untested in the README |
| `:RustTargets` / `:RustTools` real terminal behaviour, `<leader>rF/rX/rZ/rN` execution | pickers and terminals are stubbed |
| `<leader>rm rM rj rp rt rC rR rP rk`, `<A-j>/<A-k>`, `rd`, `rE` server effects | only the `RustLsp` call and desc are asserted |
| Second-workspace live updates through rustaceanvim | covered with a stand-in client (the shared client keeps the first root_dir); not with two real workspaces |
| `vim.v.exiting` branch of `rust_restart.on_exit`, real rustaceanvim handler under the status wrap | cannot be set / only a stand-in is used |
| Local history: real picker, interactive undo, a real 30 s watchdog wait, a lock aged exactly 60 s, submodules, thousands of snapshots | see the pending entries in the spec |
| README timing claims (2.3 ms colourscheme load, 0.56 s edit-to-diagnostic) | printed, only bounded |
| Light-theme background leak, E31 undo_ftplugin message | documented README limitations, informational |
| `scripts/test.sh` under a CI runner without user namespaces | not run there |

## Bugs found by the specs

All of them are fixed (final loop round 1) and their specs assert the correct behaviour; none is skipped as a known bug any more.

| # | Bug | Spec that now covers it |
| --- | --- | --- |
| 1 | `rust_nav.goto_super`: an empty definition list gave no WARN | `keymaps-rust` |
| 2 | `rust_routes.collect` skipped `target`, `.git`, ... only at the root | `rust-routes` |
| 3 | `rust_context.apply` for a second workspace reached no client | `rust-context` |
| 4 | `xyno_sandbox`: renaming the parent of the masked memory dir; `wrap` without `~/.claude` | `sandbox` (xyno-sandbox.nvim repository) |
| 5 | cargo-deny diagnostics on `Cargo.lock` on the wrong line | `git-lint-supply-chain` |
| 6 | `lsp_status`: dead `b:xynovim_bacon` test; the edit counter restarted after `:edit!` | `server-supervision-statusline` |
| 7 | `scripts/test.sh --timeout` without a value exited 1, not 2 | `test-infra-readme-claims` |
| 8 | README plugin count | `test-infra-readme-claims` |
