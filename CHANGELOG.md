# Changelog

All notable changes to this config are documented here.

## [Unreleased]

### Added
- Assessment and plan for the next phase, "macros and dependencies": measured what rust-analyzer and this config do with derive and attribute macros, new dependencies, missing crate features and ambiguous imports (seven gaps), and a four-phase plan with acceptance criteria. README section "Next phase", `docs/PLAN_MACROS_DEPS.md`, the probe scripts in `docs/assessment/`. Nothing implemented yet.
- README rewritten as a showcase: screenshots and videos of every major feature (`docs/media/`, 25 screenshots, 10 GIFs, 10 MP4s), a keys and commands cheat sheet, the test suite up front. The previous long README is split into `docs/DETAILS.md` (engineering notes), `docs/TESTING.md` (the suite), `docs/KNOWN_ISSUES.md` (decided limitations) and `docs/HISTORY.md` (the old roadmap, archived).
- `demo/netwatch`, a small realistic crate (trait, CLI, unit and integration tests, features) as the target of the recordings. `docs/media/record.sh` regenerates every screenshot and video from the vhs tapes in `docs/media/tapes/` on a fresh copy of the crate.
- `scripts/provision.lua`, step 3 of `scripts/bootstrap.sh`: downloads the treesitter parsers and the Mason packages (bacon-ls, taplo, codelldb, marksman, ...) that LazyVim would otherwise fetch lazily, so a fresh clone is ready to run the suite.
- `H.docs_text()` in the test helpers: the specs that verify documentation claims read the README and the `docs/` pages.

### Fixed
- CI on a clean machine (it had been failing since the suite was added: 15 specs failed on a fresh Ubuntu runner, 3 after the first round of fixes). Treesitter parsers and Mason tools are provisioned by the bootstrap; specs wait for noice through `H.very_lazy()` (a raw `doautocmd User VeryLazy` raced it, and a hit-enter prompt spun nvim at 100 % CPU on an empty stdin); the lazygit keys spec skips without lazygit; the broken-crate spec accepts rust-analyzer's other wording of E0308; SSR retries while rust-analyzer answers "content modified"; the harness spec counts a tmux-less skip; the CI startup log is written outside the checkout; `scripts/test.sh` passes `shellcheck`. Verified: a full run in a fresh XDG environment (empty data dir, bootstrapped) had one failure (Mason's `tree-sitter-cli`, now provisioned and green); the final fixes were checked on the development machine (full suite 1069 passed, 23 skipped, 0 failed). The GitHub Actions run of these fixes passed on a clean Ubuntu runner (run 38516203382, 10m48s: bootstrap, lockfile check, startup smoke test, full spec suite), the first green run since the suite was added.

### Added
- Test infrastructure. `scripts/test.sh` (`make test`) runs every `tests/*_spec.lua` in its own `nvim --headless` with a hard timeout (default 120 s), an isolated state/cache/tmp and the real plugin install; per-file and total summary with skip reasons, `[pattern]`, `--list`, `--coverage`, `--timeout`, `-v`; exit 1 on a failure, timeout or crash. `tests/harness.lua` is a small describe/it framework (plenary's busted spawns a nested nvim without this config), `tests/helpers.lua` the utilities (assertions, `wait_for`/`wait_lsp`, `feed`, fixture copies, git, sandbox wrapper, tmux, cleanup), `tests/fixtures/` the crates (`basic`, `workspace`, `broken`, `standalone.rs`, `sql_and_routes.rs`). Specs: smoke, harness, routes, rust. `tests/coverage_hook.lua` + `scripts/coverage.lua`: `debug.sethook` line coverage of the repo's Lua (denominator estimated from the source text). CI runs the suite after bootstrap. README section "Tests".
- Verified: whole suite headless as the user (18 passed on this machine with rust-analyzer 1.99, bwrap and a clean tmp), `--coverage` (total about 54 % estimated lines), `XYNO_TEST_SKIP_RUST=1` (3 skipped with reason), a failing, a skipping, a load-error, a skip-at-load and a hanging (busy loop, killed after the timeout, exit 137) throwaway spec each reported correctly, no leftover process or temp dir, `actionlint` and `zizmor` clean on the workflow, `stylua --check`. Not verified: the new CI job itself (needs a push to run; runners that forbid user namespaces should skip the sandbox spec through the probe, not tried), the tmux helper (written, no spec uses it yet), a fresh machine after `scripts/bootstrap.sh`, `shellcheck` (not installed).
- Test suite completed: 24 spec files, one per feature area (startup/options, theme, global and Rust keymaps, `:RustContext`, `:RustRoutes`, task and tool commands, rust-analyzer and bacon-ls config, server supervision and statusline, DAP/neotest/coverage, auto-save and disk guard, 99 agent, sandbox, local history, git/lint/supply chain, snippets and completion, UX/menu/diagnostics, health/bootstrap/CI, test infrastructure and README claims). `tests/COVERAGE.md` is the feature-to-test matrix with the untested features and their reasons. 1011 tests: 977 passed, 0 failed, 34 skipped, three consecutive full runs identical (default timeouts, 328-376 s); `--coverage` 968 passed, 43 skipped, 86.4 % estimated line coverage (3626/4199).
- `scripts/test.sh`: a spec may raise its own timeout with a `-- xyno-timeout: N` line near the top (`keymaps-global`), a spec whose nvim does not exit within 30 s of its result line is killed and its result counts (with a note), tmux socket files of the specs are removed. `tests/runner.lua` prints the result line before the cleanup. `tests/helpers.lua`: `H.very_lazy()` waits for noice to replace `vim.notify` (flaky notification assertions), `H.cleanup()` drops the tabline and wipes the buffers (without autocmds) before waiting for the LSP clients: bufferline's quadratic tabline redraw made nvim spin for minutes at exit after `keymaps-global`, which timed out the file at 120 s in 2 of 5 full runs.
- Not verified: a full run on a loaded machine (specs were flaky only under a load average of 60-120 from parallel writers, not re-checked), the CI job, `shellcheck`, the network fresh-install test (`XYNO_TEST_NETWORK=1`, passed once in the writer's run, not in the default suite). The bugs the new specs found were skipped tests at first; all are fixed below (final loop round 1), list in `tests/COVERAGE.md`.

### Fixed (final loop round 5: remaining confirmed field test bugs)
- `<Space>r` showed no which-key popup at normal typing speed (the global `<leader>r` leaf blocked in `getcharstr()`): replaced by hidden per-key stubs (`which_key_ignore`); an unbound key says "not bound" in a Rust buffer.
- Auto-save re-emits `BufWritePost` for nvim-lint's group (non-Rust buffers): the `Cargo.toml` cargo-deny / cargo-machete diagnostics were stale until a manual `:w`.
- `<leader>dP` requests the threads when codelldb has not reported any (it did nothing on a running process).
- bacon-ls: a save restarts it when `target/bacon-ls-live` was recreated (`cargo clean` under a running nvim) or, while clippy has failed, when `Cargo.lock` changed (`lsp_status.bacon_failed`).
- 99 sandbox: `--chdir` is the cwd only inside the project (else the project root); `wrap` asserts `tmp_dir`.
- Local history: a save during a running snapshot no longer arms the timer before `last` is set (a second commit about 1 s later); `finish()` arms it.
- `<leader>rw` / `rW` search the first word; `:RustTools` timings and bloat get the context flags; `rust-context.json` with wrong types is sanitised; SIGCONT to the Rust servers on `VimLeavePre`; `~/.cargo/bin` appended to `PATH` when absent; kulala `disable_news_popup`; fixture `target/` and `.rustc_info.json` git-ignored; README: Mason list, bootstrap and prerequisites, known-and-not-fixed list (see README "round 5").
- The 15 spec-writer bugs of the b2fee5c list were already fixed in rounds 1 to 4 (re-checked: suite green).
- Suite: 1068 passed, 0 failed, 24 skipped (1092 tests, 369 s); 11 new tests. Tests changed for the new stubs (`keymaps-global`, `keymaps-rust`, `rust-routes`) and the README Mason names (`health-bootstrap-ci`).
- Not verified: `<leader>dP` on a real codelldb process, a real `cargo clean` restart (identity of the directory measured in a TUI, the restart by fake-client specs), the 1 MB typing stall, `<CR>` preselect, noice float, 80-column statusline, `<leader>ghB` in an empty repo, `<leader>cn` stub type (not changed).

### Fixed (final loop round 4: field test leftovers)
- The spec-writer bugs of the b2fee5c list (empty `goto_super` list, nested `target` in the route scan, `RustContext` for a second workspace, sandbox rename and missing `~/.claude`, cargo-deny lockfile line and `null` line, `b:xynovim_bacon`, `:edit!` counter, `--timeout` exit status, plugin count, non-numeric byte cap, `gc`, `lazy.manage`, `::1`) were already fixed in rounds 1 to 3 and are asserted by the suite; this round checked each one again (`scripts/test.sh --timeout` without a value exits 2). The medium bug of the report (auto-save writing the readonly 99 select buffers) is round 3's `can_save` fix, covered by `auto-save-disk-guard`.
- `<leader>rl`: a declaration without a `kind` is labelled `[W]` (it was `[T]`); `rd` / `rE` descriptions say what they do (local rustup docs, else docs.rs).
- Rust buffers: `"` behind an odd number of backslashes is inserted plainly (mini.pairs overtyped the auto-inserted closer: `"a\"b"` ended as `"a\"b";"`); Rust words (`Vec`, `tokio`, `impl`, `usize`, ...) are in `spell/en.utf-8.add` (compiled to a git-ignored `.spl` on the first Rust buffer; `zg` still writes to the user's own list); `.http` buffers get `conceallevel=0` (JSON quotes were hidden).
- Completion: no snippets in call arguments, struct literals and macro token trees (also while the call is still unclosed), but in a block inside them.
- Pickers: `/target` is excluded from the file and grep pickers (a crate without `.gitignore` listed 313 of 318 items from `target/`); the rust document outline keeps `impl` blocks (SymbolKind Object added to the rust `kind_filter`).
- `:RustTools` "deny: check all" without a `deny.toml` runs `advisories bans sources` (every dependency failed the empty licence list); cargo-deny: one `deny-failed` warning per run and one diagnostic per label of a multi-dependency wildcard finding.
- `:RustContext bogus` warns with the usage instead of opening the picker; `:RustContext show` outside a crate warns "no Cargo.toml found" instead of printing the default.
- SSR: a query that matches nothing says "SSR: no matches".
- A save (`BufWritePost`, auto-save's `AutoSaveWritePost`) sweeps bacon-ls clients whose project directory moved or lost its `Cargo.toml` (it waited for FocusGained, which tmux does not send without `focus-events on`).
- `config.lazy`: an unwritable `XDG_CACHE_HOME` turns lazy's module cache off instead of aborting `init.lua` with E739.
- Local history: a snapshot is limited to 200 MB (`vim.g.xynovim_lochist_max_total_bytes`, 0 disables): the largest files that pass the per-file cap are left out with one notice each (thirty 9.5 MB files added about 285 MB to `.git`; computed from the code, not measured).
- Suite after round 4: 1057 passed, 0 failed, 24 skipped (24 files; one full run, then the two files I fixed afterwards re-run alone: 54 and 86 passed); 15 new tests.
- README: doc-tests get no live diagnostics, no F-key maps exist, submodule edits and local history, 18 theme-only plugins.
- Not changed (reported, see README "Field test 2026-10-14"): neotest feedback (neotest itself prints "No tests found"; not reproduced), `rm` / `rh` / `cc` cursor-position quirks, extract-then-rename, treesj/`gc` quirks, Trouble first-line formatter, flattening the right-click menu, DAP attach configuration, local-history `positionEncodings` warning, `bootstrap.sh` waiting for Mason downloads, `:RenameUndo`.

### Fixed (final loop round 1: field test and spec findings)
- 99 sandbox: `~/.claude/security` is read-only (the security-guidance hook imports from `security/agent-sdk-venv` outside the sandbox; a `.pth` planted there ran with the user's privileges) and masked when absent; `~/.claude/projects` is bound read-only with only this project's own directory writable (a bind mount point cannot be renamed, so `mv projects/<name> ...; mkdir -p projects/<name>/memory; echo x > .../MEMORY.md` no longer works); `wrap` creates `~/.claude` when it is missing (bwrap aborted with "Can't mkdir parents"); the env scrub also hits `PASSPHRASE`, `ASKPASS`, `OPENAI_*`, `STRIPE_*`, `MYSQL_PWD`, `SSHPASS`. Both former skipped "known bug" tests now assert the correct behaviour.
- 99 guard: the agent starts from the "before 99 request" snapshot's `done` callback (15 s fallback, a cancel before that never starts it, no repository starts it at once). A stub agent that rewrote `src/main.rs` immediately used to end up inside the checkpoint.
- Keys: `<leader>rM` / `<leader>rk` in normal mode notify "select code first" (they were `l` plus `r M`: one character replaced, then auto-saved); `<leader>rw` / `rW` work from the quickfix list (RustLsp ran in the current buffer: "Command not found"); `<leader>ru` shows "trait definition not found" for an empty answer (`islist and res[1] or res` returned the empty list) and skips doc comments mentioning `fn name`; `<leader>rs` refuses a query without `==>>`; `<leader>gq` runs `silent! wall` first (raw E445).
- Module rename: `workspace.fileOperations.willRename` (LazyVim's `*` config) is turned off for rust-analyzer. With it the rename answer held the file rename alone (1 documentChange, 0 text edits) and `pub mod util;` / `util::helper()` stayed stale; now it carries the edits too. `workspace/willRenameFiles` (what `<leader>cR` sends) still returns the `mod` edit. Verified with a real rust-analyzer in `rust-analyzer-config`.
- `vim.g.trouble_lualine = false`: the navic breadcrumb (with `impl` blocks) replaces Trouble's symbols component (it also left a stale symbol in the quickfix/terminal statuslines). `update_in_insert = true`.
- `config.rust_context`: the root comes from `cargo locate-project --workspace` (cached per directory and manifest mtimes), so a crate in `exclude` or with its own `[workspace]` is its own root (fallback: the text walk); `apply` reaches a client that serves the workspace as an added workspace folder (rustaceanvim keeps one client with the first `root_dir`); `rust-context.json` is written to a temp file and renamed.
- `plugins/supply-chain.lua`: cargo-deny `log` ERROR lines become a line-0 `deny-failed` warning; `Cargo.lock` diagnostics sit on the `name = "..."` line of the package (name and version from the graph); a wildcard label beyond the buffer is clamped; a JSON `null` line no longer crashes the parser.
- `config.local_history`: modified tracked files over the cap are left out of the snapshot (a 40 MB `data.db` took `.git` from 41 to 162 MB in three snapshots); `:LocalHistoryPrune!` runs `git gc --prune=now` when nothing is left to drop; a non-numeric `vim.g.xynovim_lochist_max_bytes` keeps the 10 MB default.
- `config.rust_restart`: `:RustRestart` SIGKILLs a rust-analyzer / bacon-ls still alive 3 s after the graceful restart (SIGSTOPped servers kept their pids for 20 s; verified live: new clients with new pids); `sweep` marks the clients it stops so their SIGTERM exit gives no "exited, restarting" warning.
- `config.lsp_status`: "clippy ok" shows "clippy 2E" while clippy errors are on screen; "Failed to discover workspace" (a standalone script) is "RA detached"; the `TextChanged` redraw tests for a bacon-ls client (it tested `b:xynovim_bacon`, which nothing sets); the edit counter never restarts (after `:edit!` the first edits did not show "clippy stale").
- `config.rust_nav`, `config.rust_routes`: see Keys; the route scan now skips `target`, `.git`, `node_modules`, `bacon-ls-live` in nested directories too (the callback gets the path relative to the root).
- Smaller: `NEXTEST_HIDE_PROGRESS_BAR=1` (neotest's output panel held nextest's redraw sequences, not the failure text); `gsd` with the Rust surroundings `S`/`O`/`N`/`D`/`U` uses balanced patterns (`gsdO` on `Ok(vec![f(1), g(2)])` left `vec![f(1, g(2)])`); `.arcmutex` requires `Arc` and `Mutex`; `:RustTools` coverage gets `--ignore-run-fail`; `:RustTargets`/`:RustTools` close the previous terminal; `:RustNew -x` is refused; Harpoon's menu is rounded; dap-ui is not closed on terminated/exited; colourblind Error `#E06A0E` (4.89:1, was 4.26:1); bacon-ls says once that cargo is missing; `:checkhealth xynovim` checks gzip, wgsl-analyzer, cargo-expand and the wasm32 target; `scripts/test.sh --timeout` without a value exits 2; the specs remove the `~/.claude/projects/<tmp dir>` directories the sandbox leaves behind (about 1000 had piled up).
- README: plugin counts (4 of 61 loaded at startup), `rd`/`rE` wording, doctests shown as skipped in neotest, `lazy.manage` is loaded by lazy.nvim at startup, `::1` is reachable in the sandbox, ghost text is off, `gc` warning, prerequisites (gzip), Mason's `bacon`, test code without live E0425/E0599, the layout list, and a "Field test 2026-10-13" section with what stays open.
- Verified: the full suite headless as the user (numbers below), each fix with a spec that fails without it where that was cheap to check (module rename, `:RustRestart` on SIGSTOPped servers). Not verified: the changed UI in a TUI, a real claude request, the CI job, `shellcheck`, the network fresh-install test.
- Suite after the fixes: 1014 passed, 0 failed, 24 skipped (1038 tests in 24 files, 355 s); before: 977 / 0 / 34. 27 new tests; the ten former known-bug skips now pass.

### Fixed (final loop round 2: remaining field test bugs)
- Auto-save no longer splits the insert-mode undo block (`:undojoin` in the `AutoSaveWritePost` hook while in insert mode); sqlx `query!` SQL is no longer overpainted by a nested Rust layer (`queries/rust/injections.scm` shadows nvim-treesitter's file minus the sqlx macros); `VimLeavePre` kills a rust-analyzer / bacon-ls that has not initialised yet; `<leader>ru` skips `///` lines without needing a parser; `unsafe_op_in_unsafe_fn` and `E0133` are one diagnostic; an unparsable SSR query gives a notice instead of a traceback; `<leader>t` / `<leader>a` which-key groups; preview-less picker layout under 30 lines; local history stats untracked files 2000 per tick; `H.cleanup()` removes the sandbox specs' `~/.claude/projects` leftovers; `bootstrap.sh` checks gzip and health warns about the `tree-sitter` CLI; a dead bacon-ls is restarted with `enable` off and on, `sweep` also stops a client whose root lost its `Cargo.toml`, FocusGained restarts bacon-ls when `Cargo.toml` changed; `rust-context.json` is updated under a lock file; taplo is not started for `Cargo.lock`; `~/.claude/history.jsonl` is hidden in the 99 sandbox; snippets `tmod` / `tfn` renamed `testmod` / `testfn`.
- Verified: the full suite headless as the user: 1029 passed, 0 failed, 24 skipped (1053 tests in 24 files, 352 s); 15 new tests, each failing without its fix where that was cheap to check (the undo block in a tmux nvim, the 8-nvim `rust-context.json` race). Not verified: the quit-during-start race itself (needs a loaded machine), the which-key popup and the picker layout in a TUI, the `kill -9` restart in a TUI, the `.claude` hardening against a real claude, 100k-file local history timing.
- Spec fixes: the `:RustContext` bacon-ls test picks the client of its own root (a supervision restart of an earlier test's buffer may start another one); the layout/health/bootstrap counts follow the new entries.

### Fixed (final loop round 3: confirmed field test bugs)
- `<A-j>` / `<A-k>`: own `experimental/moveItem` request applied as plain text (the snippet expansion of `:RustLsp moveItem` emptied `$e` in `macro_rules!` items and auto-save wrote it). `<leader>cR` refuses an existing destination (also bound through LazyVim's LSP keys, which re-applied Snacks' overwriting rename on every capability registration). Global `<leader>r` catch-all: an unbound `<leader>r<key>` notifies "Rust buffers only" instead of replacing a character. `ri` asks before "Inline into all callers".
- Auto-save: `can_save` is false for buffers with a `buftype` and readonly ones (99's select windows raised a blocking confirm); a Rust autosave triggers neotest's own rediscovery (`<leader>tr` on a new test ran another one).
- Trouble call hierarchies `auto_refresh=false`; dap-ui Console re-scrolled when its topline is stale; breakpoint signs use the theme's `DapBreakpoint*` groups; `<leader>gV` outside a repository says so.
- Local history: `/target/` anchored (plus members'), the old `target/` line migrated (`src/target/mod.rs` was hidden from snapshots).
- bacon-ls: no client for virtual buffers or non-absolute roots (a second `root=.` client after Diffview); `--keep-going` in the args; FocusGained starts it again when the manifest is back after a sweep.
- which-key: the extras' no-op `keys` stubs for `<leader>t`, `<leader>a`, `<leader>R` are switched off (they shadowed which-key's trigger); groups come from the which-key spec, plus a global `<leader>r` group.
- 99 sandbox: absent `project/.git` masked, `/run/tailscale`, `/run/seatd.sock` and five more unlisted secret paths hidden, hidden files are empty regular files (no EACCES), project = `$HOME` gets no project-relative locks.
- `rust-context.json` directory creation tolerates a concurrent `mkdir` (E739 seen once in the full suite).
- README: round 3 section. Tests: new or changed tests in `keymaps-rust`, `keymaps-global`, `auto-save-disk-guard`, `local-history`, `bacon-ls-config`, `server-supervision-statusline`, `agent-sandbox`, `dap-neotest-coverage`, `git-lint-supply-chain`, `rust-context`.
- Not verified: the changed UI in a TUI (which-key popup, `ri` confirm, dap-ui console in a real session), a real claude in the sandbox, `<A-j>` through the key in a TUI (the function was run against a real rust-analyzer headless).

### Removed
- All Omarchy support. Deleted `lua/plugins/omarchy-theme-hotreload.lua`, the
  `lua/plugins/theme.lua` symlink, `lua/plugins/all-themes.lua` (18 colourscheme
  plugins that only Omarchy themes used) and the `theme.lua` loadfile guard in
  `lua/config/lazy.lua`; `vim.g.xynovim_follow_omarchy` is gone and Island Dark
  is set unconditionally. The 18 plugins are dropped from `lazy-lock.json`
  (tokyonight and catppuccin stay: LazyVim specs them). The remote clipboard
  provider is now `XynovimRemoteClipboard` and its OSC 52 opt-out is
  `vim.g.xynovim_remote_clipboard_osc52` (was `omarchy_remote_clipboard_osc52`).
  Older entries below keep their Omarchy wording as history.

## [1.8.0] — 2026-10-13

### Fixed (field test batch 5: fresh install, CI and docs)
- Fresh install did not reproduce `lazy-lock.json` (bug 28). Reproduced with
  empty XDG dirs and a clone: after `Lazy! restore` 6 of 79 plugins sat on newer
  commits and the lockfile was rewritten. Cause (lazy's code read, behaviour
  confirmed by experiments): the first install round only knows the plugins of
  the user spec and writes the lockfile with those, dropping the pins of the
  ones found in later rounds (LazyVim's extras). `Lazy! install`, original
  lockfile back, `Lazy! restore` ended with an identical lockfile (twice);
  restoring a second time without putting the lockfile back did not help.
- New `scripts/bootstrap.sh`: checks git, curl, tar, unzip, gcc, npm, node,
  cargo, rustup and rust-analyzer (prints what is missing, exit 1), refuses a
  config dir that is not the checkout, runs the two steps above and fails with
  a diff if the lockfile still changes. CI runs it (after
  `rustup component add rust-analyzer`) and then `git diff --exit-code
  lazy-lock.json`; `actionlint` and `zizmor` are clean. Verified locally with
  fresh XDG dirs (exit 0, lockfile unchanged; the missing-prerequisite and
  wrong-config-dir cases exit 1). Not verified: a GitHub run.
- kulala v5.3.4 pin never checked out on a fresh install (bug 29): lazy's
  `--recurse-submodules` failed on the `fmt/` submodule and left v6 with a dirty
  tree. `submodules = false` in `lua/plugins/domain.lua`; verified with fresh
  XDG dirs that kulala ends on `6656c9d` (v5.3.4).
- `:checkhealth xynovim` also checks git, curl, tar, unzip, gcc, node and cargo;
  a binary that is found but fails `--version` (rustup's rust-analyzer proxy
  without the component) is an error with the fix instead of OK; the
  rust-analyzer hint names `rustup component add`. Run on a PATH holding only
  nvim and git, with a failing rust-analyzer stub, and on the normal PATH.

### Docs
- README: new Install section (prerequisites, bootstrap, why two steps). Stale
  statements corrected: the `~/.config/bacon/prefs.toml` fallback (neither the
  file nor `bacon` is used), "manual `:w` still formats" (format-on-save is
  off, `<leader>cf` formats), "taplo absent" (Mason has it), the which-key
  overlap count (0 in a batch 5 run, the field test's 5 were not reproduced),
  the startup figure (~25 ms with its load conditions), the CI description and
  the kulala "not verified" note. `:LocalHistoryRestore`'s Restore/Cancel step
  is documented. The `options.lua` and `bacon-ls.lua` comments no longer
  describe the old bacon-process design.
- CHANGELOG: the long `[Unreleased]` section is cut into 1.5.0 to 1.8.0, each
  with a git tag.

## [1.7.0] — 2026-10-13

### Changed
- `<leader>rM` (extract module) is visual-mode only: rust-analyzer offers the
  assist only for a selection, so the normal-mode map just reported "No code
  actions available". README and which-key say so. Not re-run in nvim.

### Fixed (field test batch 4: editing and UI)
- Rust: typing a lifetime no longer leaves a stray quote (`after/ftplugin/rust.lua`);
  comments are spell checked (treesitter `@spell`, `camel`).
- Diagnostic virtual text: first line plus `[source]`, identical problems from
  rust-analyzer and clippy shown once. blink snippets hidden after `.` and in
  strings and comments. `winborder = rounded`, noice hover border, `pumblend = 0`,
  opaque and smaller coverage summary, dashboard fits 80x24, showcmd clears,
  `<leader>9` which-key group, 99 model picker lists `claude-sonnet-5`.
- taplo: Cargo.toml schema association and a `Cargo.toml` root marker. sqlx
  injection for multi-line strings and more keywords. cargo-machete findings no
  longer doubled; cargo-deny `wildcard` on the right line; lazy `rocks` off.
- Verified headless (`:checkhealth lazy` luarocks OK, options, spell, `'` mapping, injections via the language
  tree, format and dedupe function, snippet guard cases, taplo schema error on
  `edtion`, deny parser fed a fake wildcard record, colourscheme cycle) and in
  tmux (insert-mode typing of `&'a str` and `'z'`, completion menu with `.if`
  and no `if` snippet, hover border, virtual text dedupe, showcmd clearing,
  dashboard at 80x24, coverage summary from a hand-written lcov, `:popup PopUp`).
  Not verified: the right-click menu with a real mouse, `pumblend` blending
  on a terminal (only the option value), the machete duplicate (no
  cargo-machete run), a cargo-deny run against a real advisory DB, wgsl-analyzer
  (unchanged), taplo's catalog line in `lsp.log` (still logged).

### Fixed (field test batch 3: data safety)
- Local history: with several nvims saving at once the ref tip could hold an
  older tree than another instance's latest snapshot; the tree is now built
  after the parent is read and rebuilt on every compare-and-swap retry. Verified
  headless: 4 concurrent nvims x 3 forced snapshots, tip equals the disk, and no
  file ever goes back to an older value along the history (9 commits, unchanged
  trees skipped). Not verified: more than 4 racers.
- Local history: a save followed by a quick quit no longer loses the snapshot
  (in-flight jobs are redone synchronously at exit); one index per nvim process
  (`.git/lochist-index.<pid>`, stale ones cleaned, the newest seeds the next),
  the ref moves by compare-and-swap with retries, the throttle starts only
  after a success, lock errors notify once; untracked files over 10 MB
  (`vim.g.xynovim_lochist_max_bytes`) are skipped; the git child is killed
  after the 30 s timeout; new `:LocalHistoryPrune [N | Nd]` (`!` collects
  everything unreachable); `:LocalHistory` no longer lists the deletion commit;
  the user's global gitignore is honoured (`target/` goes into
  `.git/info/exclude` instead of replacing `core.excludesFile`).
- Auto-save (`lua/config/disk_guard.lua`): skips a buffer whose file changed on
  disk (checked at the event and again before the write; one warning), never
  writes dependency/std buffers (`nomodifiable`), `FileChangedShell` never
  prompts; modified buffers touched by a multi-file rename, file rename or any
  workspace edit are written afterwards; `BufWritePost` is re-emitted while a
  neotest watcher exists, so `<leader>tw` reruns (README contradiction fixed).
- `<leader>gV` falls back to `origin/main` / `origin/master` and explains when
  there is no remote branch.
- Agent sandbox: the project's `~/.claude/projects/<name>/memory` is read-only
  also while it does not exist yet.
- Verified headless as the user and in tmux (concurrent nvims, SIGKILL during
  `git add`, 300/400/600 MB untracked blobs, an external write while typing:
  no prompt, typed text kept, disk untouched, saving resumes after `:w!`),
  a fixture crate (neotest watch reran after an autosave, not after stopping
  the watcher; multi-file rename and Snacks file rename left no modified
  buffers), the sandbox with bash stand-ins and a stub provider through the
  real guard. Not verified: a real `99` request, the 30 s watchdog, stale ref locks, submodules, `stylua` formatting (not installed).

### Fixed (field test batch 2: keys and commands that did nothing)
- `:RustTargets`, `:RustTools`, `:ActJob` and the new `<leader>tD` keep their
  terminal (and the output) after exit 0 (`auto_close = false`); a rerun
  replaces the previous terminal instead of toggling the finished one.
- `<leader>rs` (normal and visual): own prompt, then `:RustLsp ssr <query>`
  (rustaceanvim read the query before Snacks' async input answered); the
  visual range is captured first. `<leader>rw` / `rW`: `vim.npcall` shim, plus
  a single own prompt (rustaceanvim asks twice); `rW` lists std/dependency
  symbols. `<leader>re`: takes the `E0000` code from any diagnostic on the line
  and shows `rustc --explain` in a float (works for bacon-ls/clippy messages);
  `rD` and `rr` removed (rustaceanvim only accepts cargo-check diagnostics,
  which are off). `rM` matches "Extract Module"; `ri` no longer inlines
  macros silently; `rS` pretty-prints the JSON syntax tree; `rd` / `rE` show a
  notice for an undocumented item instead of throwing.
- `<leader>tc`: `--ignore-run-fail` (a failing test no longer yields no
  report), lcov written to `target/lcov.info`, warning when tests failed.
  `<leader>tD`: `cargo test --doc` in a terminal (neotest doctests stay
  unreliable, documented). Verified headless with the real mapped keys on a
  fixture crate (rM, ri variable and macro, rs normal and visual, rS, rd/rE
  on an undocumented item, rw, rW, re with a bacon-style and an rust-analyzer
  diagnostic text, tD incl. rerun, `:RustTools` exit-0 terminal, `<leader>tc`
  with a failing test: signs placed, warning shown) and in tmux (rs, rS, rW).
  Not verified: `rd` / `rE` on a documented item (would launch a browser),
  `:ActJob`, `:RustTargets` picker items (same helper as `:RustTools`),
  coverage without cargo-nextest installed, visual `rs` in tmux.

## [1.6.0] — 2026-10-12

### Changed
- Theme: Island Dark (the user's RustRover "Dark" scheme, parent Darcula) is now
  the permanent colourscheme. `tools/icls2nvim.py` converts `tools/Dark.icls` to
  `lua/island/palette.lua`; `lua/island/init.lua`, `colors/island-dark.lua` and a
  lualine theme map it to UI, Treesitter, LSP semantic (`org.rust.*`) and plugin
  groups. Omarchy's theme spec and hot-reload no longer override it (set
  `vim.g.xynovim_follow_omarchy = true` to follow Omarchy again). Transparency
  stays the default; new `<leader>uO` toggle. Verified headless (49 colour checks
  against an independent parse of the `.icls`, real rust-analyzer tokens) and in
  tmux (24-bit SGR); not verified with a live Omarchy theme switch.

- Theme legibility (review of the Island Dark commit): floats, the completion
  menu and `Pmenu` stay solid when transparency is on (only the editor surface
  is transparent; `<leader>uO` toggles that); blink.cmp secondary text and
  inactive statusline use the `sub` grey; git "modified" uses
  `FILESTATUS_MODIFIED`; comments, doc comments and error text are lifted to
  4.5:1, line numbers to 3.5:1 (documented in README, Theme); cursorline is
  `#242d42` and `CursorLineNr` keeps its background; lualine follows other
  colourschemes. Verified by computing WCAG ratios from the loaded highlight
  groups (headless, both transparency modes) and in tmux at 200x55.

### Fixed (field test batch 1: Rust workflow robustness)
- bacon-ls (clippy tier) roots at the Cargo workspace instead of the nearest
  member `Cargo.toml` and no longer attaches to `~/.cargo/registry`, `~/.cargo/git`
  and `~/.rustup` files: live clippy now works in workspaces (before: no
  diagnostics, one client and `target/` per member). `:RustContext reset`
  rebuilds the bacon-ls settings from the defaults (it kept the old
  `--no-default-features --features ...`), and warns outside a crate.
  Verified headless with real servers on a 2-member workspace opened from a
  member (one client at the workspace root, a clippy warning arrives, context
  apply/reset change the bacon-ls args, no member `target/`), and on a single
  crate. Not verified: `exclude`d members, nested workspaces.
- Statusline: `clippy stale` no longer sticks after an auto-save while typing
  (edits are counted with `nvim_buf_attach`, not `changedtick`, which a write
  bumps); `clippy failed` when cargo cannot run (broken manifest) instead of
  `clippy ok`; `RA stopped` / `clippy stopped` for a dead server.
- New `lua/config/rust_restart.lua`: a killed rust-analyzer / bacon-ls is
  restarted automatically (3 per minute, then it gives up); `:RustRestart`;
  bacon-ls is restarted on `FocusGained` when an open Rust/Cargo file was
  reloaded from disk or the git HEAD moved (external `sed -i` / `git checkout`
  left clippy checking old content); bacon-ls clients whose workspace
  directory was deleted are stopped. Verified headless (`kill -9` of both
  servers in a single crate and in the workspace, crash-loop guard, broken
  manifest, `sed -i` + `FocusGained`, commit + `FocusGained`, deleted
  workspace). Not verified: a real terminal focus event (`:doautocmd`
  stand-in), changes to files that are not open in nvim without a HEAD move.
- Debugger: configs 1-3, `<leader>dr` and `<leader>dR` get rust's lldb
  formatters (`lldb_lookup.py`) and `breakpoint set -n rust_panic` through an
  nvim-dap `on_config` listener (Strings, Vecs and enums showed as `{...}`
  via `<leader>dc`; a panic ended the session with exit 101); `<leader>dR`
  keeps per-test entries (dedupe key now includes `executableArgs`);
  `dap.autoload_configurations = false` (an upstream `cargo test --no-run
  --all-targets` ran on every rust-analyzer attach) with `<leader>dr/dR`
  re-checked; nvim-dap is a rustaceanvim dependency so the "Debug" codelens
  exists (+5ms on the first Rust buffer). Verified against codelldb on a
  panicking crate through all four launch paths. Not verified: a click on a
  lens in a UI, `lldb-dap`.
- `:RustTargets`, flamegraph, `:RustTools` llvm-cov and `<leader>tc` use the
  default all-features context (they passed no flags before, so they built
  with default features while both diagnostic tiers used all of them).
- rust-analyzer `diagnostics.experimental` decision: left OFF. Measured on a
  copy of a real 196-file axum/sqlx workspace: 0 rust-analyzer diagnostics off,
  82 false errors on (E0282, E0277 `Handler`); README line 13 corrected
  (unresolved names/methods/imports come from the clippy tier).
- Not fixed: wgsl-analyzer's `Project discovery failed: no wgsl-analyzer table`
  in a Cargo crate. A custom `root_dir` changes nothing (the server walks up
  to `Cargo.toml` itself); documented, harmless.

### Fixed (field test 2026-10-12, 4 of 16 angles)
- 99 sandbox hardening: pid/ipc/uts/cgroup/user namespaces, no capabilities,
  `--new-session`; whole `.git` (plus resolved gitdirs, nested repos to 2
  levels) and `project/.claude` read-only, plus project config files that
  run code later (`.envrc`, `.vscode/tasks.json`, `.cargo/config`, `.mcp.json`
  ...); `~/.claude` settings/hooks/plugins/skills read-only, `daemon` and
  `sessions` hidden, `~/.claude.json` a private copy; `~/.local/share/claude`
  and `~/.config/claude` no longer writable; docker/dbus/containerd sockets
  and more credential paths hidden; pattern-based env scrub. The agent can no
  longer `git commit` inside the sandbox. Verified with 49 attack probes
  headless; a real claude request was not run.
- 99 guard: idempotent release (counter drops once), cancel (`<leader>9x`)
  restores auto-save without `on_complete`, user toggles are not overridden.
  13 unit checks.
- Local history: nested commit-less repos no longer break snapshots; refs
  percent-encoded (`refs/lochist/<branch>`, `/` -> `%2F`) with automatic
  migration of old refs; detached HEAD keyed by sha; trailing-edge snapshot
  after the 60s throttle window and a bounded snapshot on exit; new
  `:LocalHistoryRestore`. gitsigns attaches to untracked files.
- blink.cmp "snippets -> search_paths Unexpected field" warning removed
  (snippets load from the default config path). Harpoon add moved from
  `<leader>a` to `<leader>H` so the claudecode `<leader>a*` keys do not wait on
  a prefix. telescope.nvim no longer loads at startup.
- bacon-ls no longer attaches to standalone `.rs` files (root marker
  `Cargo.toml`, workspace required).
- Debugging: `profile.dev.debug = true` in `~/.cargo/config.toml` (only full
  debuginfo without split-debuginfo shows locals in codelldb; clean build
  about +14%, target about +28%); new `lua/plugins/dap.lua` with Rust launch
  configs defaulting to the target dir binary, "Rust: run current package
  binary (args prompt)", a wider wrapping dap-ui sidebar and `<leader>dR`
  (workspace-wide debuggables).
- README drift: plugin count (80) and startup (~35ms, 10 runs), harpoon key,
  debug-info advice, restore command, lochist namespace note, sandbox
  description, telescope claim.

### Fixed
- blink.cmp ghost text disabled everywhere (it was on for the cmdline menu), per the no-inline-completion decision.
- 99 sandbox second hardening pass: whole-directory read-only locks for `.cargo`/`.vscode`, absent-dir masks, member crates, `~/.claude` rules/chrome/memory, ephemeral shell-snapshots.

## [1.5.0] — 2026-10-09

### Fixed
- Review findings: agent sandbox now keeps `.git/hooks`, `.git/config` and
  `~/.claude` settings/hooks read-only and hides more credential paths and
  variables; local history retries forced snapshots, times out hung git and
  reports `update-ref` failures; 99 guard restores auto-save on a synchronous
  throw; npm installed and checked by `:checkhealth xynovim` (markdownlint
  ENOENT); README startup time, log path, `:ClaudeCode`, kulala keys and
  layout corrected.

### Added
- Roadmap step 11: LazyVim extra `ai.claudecode`, a lualine rust-analyzer /
  bacon-ls readiness component, a right-click Rust menu, a Neovide block, an
  opt-in Okabe-Ito diagnostic palette (`<leader>uB`), `:checkhealth xynovim`,
  and a CI smoke test (actionlint/zizmor clean). Verified headless except
  Neovide, real mouse clicks, `claude` itself and a GitHub run. README gained
  an "Optional / revisit" list.

- Roadmap step 2: LazyVim extras `dap.core`, `test.core`, `editor.overseer`,
  `lang.toml/yaml/json/markdown/git`; rust-analyzer codelens on; installed
  lazygit, git-delta, difftastic, cargo-nextest. Keymaps and module loading
  verified headless; lockfile updated (restore also dropped the dead
  monokai-pro.nvim entry).

- Roadmap step 3: `<leader>r*` rust-analyzer keymaps (extract/inline, SSR,
  expand macro, view HIR/MIR, explain/render error, workspace symbol incl.
  dependencies, move item) in `lua/config/keymaps.lua`; `<leader>cR` file
  rename restored in Rust buffers. Verified headless (extract variable
  end-to-end).

- Roadmap step 4: rust-analyzer settings (find-usages excludes + `<leader>rT`
  toggle, thread caps, term search, extra postfix snippets). Verified
  headless against the live server.

- Roadmap step 5: git-ref Local History (`refs/lochist/*`, `:LocalHistory`,
  `<leader>gH`), `<leader>uu` undotree, and a guard around `99` (pre-request
  snapshot, auto-save paused during requests, bubblewrap sandbox, log moved to
  the state dir). Everything verified except a live `99` request.

- Roadmap step 6: diffview.nvim keys, mergiraf merge driver for Rust,
  zdiff3 + rerere + autosquash/updateRefs git defaults, difftastic aliases,
  delta in lazygit, git-absorb and gitleaks installed. Merge driver verified
  on a scratch repo.

- Roadmap step 7: sticky context, breadcrumbs, error-stripe scrollbar, call
  hierarchy trees, Rust surroundings, treesj, doc stubs, rename preview,
  personal Rust snippets, super-method and per-file R/W usage helpers.
  Helpers and surround verified headless.

- Roadmap step 8: `:RustContext` (per-project features/target kept in sync
  across rust-analyzer and bacon-ls), `:RustTargets`, `:RustNew`. Verified
  headless including persistence across restarts.

- Roadmap step 10: `util.rest` (kulala.nvim, pinned to v5.3.4 because v6 needs a
  license-gated backend), `:RustRoutes` axum/actix/rocket route picker, sqlx SQL
  injections, wgsl-analyzer, unsafe underline that survives `ColorScheme`;
  installed trunk, wasm-pack, wasm-bindgen, probe-rs, cargo-expand and the
  wasm32 target. Verified headless except hardware and visual output.

- Roadmap step 9: supply-chain diagnostics (cargo-deny, cargo-machete,
  actionlint, zizmor as nvim-lint sources), coverage signs via cargo-llvm-cov
  (`<leader>tc/tg/tG`), `:RustTools` (`<leader>rZ`), `:ActJob`, samply and
  flamegraph actions in `:RustTargets`. Verified headless except samply (needs
  `kernel.perf_event_paranoid=1`, documented), act and the flamegraph run.

### Fixed
- Dead `monokai-pro.nvim` spec now points at `loctvl842/monokai-pro.nvim`
  (ends "Too many rounds of missing plugins"); a dangling Omarchy
  `plugins/theme.lua` symlink no longer errors at startup; removed the unused
  `.neoconf.json`.
- **Clippy tier was silently dead**: the `bacon_ls` `cmd` override pointed at
  `~/.cargo/bin/bacon-ls`, which does not exist. Removed it; Mason's bacon-ls
  0.31.0 already contains the upstreamed fixes (crisidev/bacon-ls#139).
  Verified headless: bacon_ls attaches and publishes diagnostics.
- Created `~/.cargo/config.toml` (outside this repo) and installed `mold`, as
  the README already described. Verified a fresh crate links with mold.

### Docs
- README: added a "Roadmap: closing the gap with RustRover" section with the
  11-step, ordered plan from a researched gap analysis against RustRover 2026.2
  (research only; no config changes). Items not tested on this machine are
  marked *(unverified)*.

## [1.4.1] — 2026-09-04

### Changed
- The three bacon-ls fixes were **upstreamed as
  [crisidev/bacon-ls#139](https://github.com/crisidev/bacon-ls/pull/139)**.
  The local binary now builds from upstream 0.30.0 + that branch
  (`~/.local/src/bacon-ls-upstream`) instead of the 0.29.0 fork. The
  run-abort fix was reworked to add no struct field (the debounce task drops
  its own handle after its sleep rather than tracking a generation counter),
  keeping the `BackendRuntime` `large_enum_variant` size lint quiet — upstream
  CI runs `cargo clippy --all-targets`. Behaviour is identical; the full
  35-check E2E suite passes against the field-free build, and upstream's own
  124 tests (incl. a new `restore_copy` test) pass. Drop the `cmd` override
  once #139 merges.

### Docs
- README "Requires" corrected: `bacon-ls` comes from the local patched build
  (`cargo install --path ~/.local/src/bacon-ls-upstream`), not Mason; the
  `bacon` binary is not needed by the cargo backend (only the unused
  `backend = "bacon"` fallback uses it).

## [1.4.0] — 2026-09-04

### Fixed
- **bacon_ls stuck on "checking…" with stale diagnostics — root-caused to an
  upstream bacon-ls 0.29.0 bug and fixed in a locally patched build**
  (`~/.local/src/bacon-ls-0.29.0-patched`, installed at `~/.cargo/bin/bacon-ls`,
  wired via `cmd` override in `lua/plugins/bacon-ls.lua`). Upstream `abort()`s
  its debounce task even after the sleep has elapsed — at that point the task
  IS the in-flight cargo run, so any keystroke or auto-save `didSave` killed
  the run silently: progress tokens leaked (begin, never end → the immortal
  stacked "checking" rows), the cargo child died mid-check, and the last run
  of every typing burst was murdered ~200ms in by auto-save (debounce 1000ms
  vs run start at 800ms) leaving diagnostics stale. Patch 1: generation
  counter — a run becomes un-abortable once started; superseded runs go
  through `CancelRunning`, which closes tokens properly.
- **Save inside the debounce window skipped the check entirely** (e.g.
  auto-save's immediate BufLeave/FocusLost saves right after an edit): with
  `checkOnSave` off, `didSave` cancelled the still-pending live trigger and
  nothing replaced it. Patch 2: only cancel when a save-run will replace it.
- **Closing a dirty buffer left orphaned diagnostics** (computed for content
  that no longer exists; could even crash Neovim 0.12's underline handler on
  reopen via out-of-range lines) **and cargo replayed stale warnings** (the
  hardlink restore moved the shadow file's mtime backwards, so cargo deemed
  the crate fresh and replayed the dirty build's cached warnings). Patch 3:
  on dirty close, clear the file's diagnostics, restore the shadow entry by
  copy (fresh mtime → real re-check), and schedule a re-truthing live run.

### Changed
- `updateOnInsertDebounceMillis` 800 → **500**. Measured on a warm 3-crate
  workspace: edit-to-clippy-diagnostic = debounce + ~60ms, and 500ms coalesces
  an 18-keystroke burst into exactly 1 cargo spawn, same as 800 (300ms spawned
  18 — churn). The 800ms choice was compensating for the now-fixed abort bug.
  Median edit→diagnostic: 0.56s warm.

### Verified
- 35-check headless E2E suite (`~/.bacon-e2e/`: harness + tiny-crate,
  3-crate-workspace, and randomized 120-op soak batteries): lint/syntax/type
  errors appear and clear unsaved; cfg(test) exclusion documented; cross-crate
  errors propagate (1.0s) and clear; serde derive + macro-expansion errors map
  to the right file; Cargo.toml dep edits flow through the shadow; dirty
  close/reopen cycles; cancellation storms and hostile didSave timings — zero
  leaked progress tokens everywhere, bacon-ls RSS 9.5MB after 120-op soak, no
  stray cargo processes. Full-stack integration on the real LazyVim config
  (real auto-save): clippy tier 0.71s, error tier 0.68s.

## [1.3.0] — 2026-09-03

### Fixed
- **Slow, churning diagnostics ("checking (0%)" rows stacked for minutes).**
  Root cause: two clippy pipelines — `checkOnSave` runs (triggered by the ~1s
  auto-save) racing `updateOnInsert` shadow runs — cancelling each other and
  serializing on cargo's build-dir file lock, with `--all-targets` doubling
  every run's scope. Fixed: `checkOnSave = false` (single pipeline),
  `--all-targets` dropped, debounce 500→800ms. Measured 5.6s → 0.8–0.9s
  edit-to-diagnostic on a warmed project. A/B testing also proved
  `updateOnInsert` must stay on: without it bacon-ls advertises no document
  sync (Neovim ignores its late dynamic registration) and diagnostics never
  refresh at all.
- **auto-save's `vim.cmd` monkey-patch replaced with the plugin's supported
  `User AutoSaveWritePost` event** for re-sending `textDocument/didSave`. The
  proxy pattern-matched auto-save.nvim's internal command string (silent
  breakage on upstream rename) and added a metatable indirection to every
  `vim.cmd` call session-wide. Verified: didSave still reaches both LSP
  clients, BufWritePre (format-on-save skip) still suppressed.
- **Transparency now survives manual `:colorscheme` changes** — re-applied on
  every `ColorScheme` event in a cleared augroup (previously startup-only;
  only the Omarchy hot-reload path re-sourced it).
- Theme hot-reload: `vim.fn.exists("syntax_on")` compared `== 1` (0 is truthy
  in Lua — the branch always ran); `walkmods` wrapped in pcall for
  pure-vimscript colorschemes.
- 99's tmp dir (`~/.cache/nvim/99`) grew forever; files older than 7 days are
  now pruned when 99 loads.

### Changed
- **Startup 28.7ms → ~18ms.** harpoon's `keys` function required the plugin
  at spec-build time (force-loading it + plenary every startup — fixed to a
  static keys table); 99 + telescope + blink.compat now lazy-load on the
  `<leader>9*` keymaps; stock `example.lua` deleted; the remote-clipboard
  `/proc` ancestry walk short-circuits behind env-var checks.
- **Zero background activity**: lazy.nvim's periodic update checker off (it
  re-fetched every plugin repo on a timer and pulled `lazy.manage` +
  `lazy.view.commands` into each startup); python3/ruby/perl/node providers
  disabled (nothing uses remote plugins).

### Added
- **Instant diagnostics tier**: rust-analyzer's native in-memory diagnostics
  re-enabled alongside bacon-ls clippy — type errors while typing with no
  cargo run, measured 155–235ms warm (real keystrokes, clean-state probes).
  Overlap with clippy is visual only (`checkOnSave` remains off).
- `rust-analyzer.cargo.targetDir = true`: rust-analyzer's build-script runs
  use their own target subdir — no more build-dir lock contention with
  terminal `cargo run`/`cargo test`.
- clippy `--no-deps` (skip re-linting dependency crates).
- **`~/.cargo/config.toml`** (outside this repo, documented in README): mold
  linker via clang (verified linking via `readelf`) and
  `profile.dev.debug = "line-tables-only"` — faster link/compile for every
  clippy, test, and run cycle. Note: existing projects full-rebuild once
  after the debuginfo change.
- Verified blink.cmp is on its native Rust fuzzy matcher (the Lua fallback
  downgrade is silent).
- README: performance-choices section; Rust section rewritten around the
  two-tier diagnostics design with the measured numbers.

## [1.2.0] — 2026-09-03

### Fixed
- **99 responses were always empty — root cause: relative `tmp_dir` resolved
  differently by each side of the pipeline.** 99 resolves `tmp_dir` against
  nvim's cwd, but claude (agentic, working on project files) resolves the same
  relative `TEMP_FILE` path against the project directory. Launching
  `nvim Projects/foo/` from `~` meant claude faithfully wrote every answer to
  `Projects/foo/tmp/99-*` while 99 read the empty placeholder in `~/tmp/99-*`
  — generation worked the whole time; the completed responses were found
  sitting unread on disk. Fixed by making `tmp_dir` absolute
  (`~/.cache/nvim/99`), unambiguous for both sides and cwd-independent; safe
  outside claude's cwd because ClaudeCodeProvider passes
  `--dangerously-skip-permissions`. This supersedes an earlier same-day
  `./tmp` attempt (never pushed), which fixed the system-temp case but still
  broke whenever nvim's cwd wasn't the project root (the plugin README's own
  warning).
  Verified end-to-end twice: a real visual-mode request rewrote the buffer
  correctly with cwd inside the project AND with cwd at `~` mimicking the
  real launch shape.
- **99's logger silently discarded everything**: `Logger:configure` requires
  `type = "file"` for `path` to take effect (the plugin README example omits
  it; anything else falls through to a void sink). With it set, requests
  trace to `/tmp/<dirname>.99.debug` — this log was what exposed the tmp_dir
  mismatch.

### Added
- 99 brought up to the plugin's current recommended shape
  (`lua/plugins/ninety-nine.lua`): `display_errors`, DEBUG file logger with
  `print_on_error`, prompt-buffer completion (`#rules` / `@files`) wired to
  blink.cmp via new `saghen/blink.compat` dependency, and keymaps for the
  newer API — `<leader>9v` vibe, `9o` open last interaction, `9l` view logs,
  `9c` clear previous, `9w`/`9W` Worker search/set-work — alongside the
  existing search/visual/stop/model/provider bindings. All mapped functions
  verified to exist after setup.
- README rewritten to describe this config (Rust setup, bacon-ls, 99 notes,
  keymaps, layout) instead of the stock LazyVim starter blurb.

## [1.1.0] — 2026-09-03

### Added
- **Live-as-you-type Rust diagnostics via bacon-ls** — the RustRover-style
  always-on inspections. `vim.g.lazyvim_rust_diagnostics = "bacon-ls"` in
  `options.lua` hands the diagnostics role to bacon-ls (LazyVim's rust extra
  disables rust-analyzer's own checkOnSave/diagnostics to avoid duplicates);
  rust-analyzer keeps completion, goto/references, hover, inlay hints, and
  code actions. New `lua/plugins/bacon-ls.lua` configures bacon-ls 0.29's
  native **cargo backend**: clippy (`--workspace --all-targets
  --all-features`) run by the server itself, with `updateOnInsert = true` —
  it mirrors the workspace into a hardlinked shadow under
  `target/bacon-ls-live/`, writes dirty (unsaved) buffers into it on every
  didChange, and re-runs clippy against the shadow, so diagnostics update
  while typing, before any save. `updateOnInsert` must live in
  `init_options`: the server needs it at initialize-time to advertise Full
  didChange sync. Verified headless end-to-end: a clippy-only lint
  (`needless_return`) published on open, and a type error typed into a
  modified, unsaved buffer surfaced as `mismatched types` with zero saves.
- Global bacon prefs (`~/.config/bacon/prefs.toml`, outside this repo) with
  the `[jobs.bacon-ls]` clippy job + `.bacon-locations` export — unused by
  the cargo backend but kept as a verified-working fallback for
  `backend = "bacon"`. bacon 3.25 installed via pacman (Mason's bacon
  package failed to produce a binary; bacon-ls 0.29.0 installed via Mason).

### Changed
- `lua/plugins/rustaceanvim.lua`: dropped the `check` (clippy-on-save) and
  `diagnostics` blocks — superseded by bacon-ls, and they would fight the
  extra's disables. Inlay hints, completion, and import settings remain.
- The `didSave` proxy in `auto-save.lua` is no longer load-bearing for
  diagnostics (bacon-ls listens to didChange, not didSave); kept because
  conform's format-on-save skip still relies on the same mechanism.

## [1.0.0] — 2026-09-02

### Changed
- **Migrated the whole config from the from-scratch Windows setup to a
  LazyVim-based config on Linux (Omarchy/Arch).** This is a platform lineage
  switch, not an incremental edit — the previous tree (everything under
  `lua/config/plugins/`, the nvim-cmp/mason wiring in `lsp.lua`, and the
  Windows-specific `bootstrap-device.ps1`) is replaced by the LazyVim starter
  (v8) layout with custom specs under `lua/plugins/`. The old Windows config
  remains untouched on the `master` branch.
- **Rust tooling: hand-rolled `lsp.lua` → LazyVim's `lang.rust` extra**
  (rustaceanvim + rust-analyzer + crates.nvim + codelldb via Mason), plus a new
  `lua/plugins/rustaceanvim.lua` override: clippy (`--no-deps`) as the on-save
  check command, native push diagnostics with style lints, inlay hints (closure
  return types, elided lifetimes), fill-arguments completion snippets, full
  function signatures, and module-grouped auto-imports.
- **99 (`ninety-nine.lua`): same settings, different source.** Provider
  (`ClaudeCodeProvider`), model (`claude-sonnet-5`), `--effort medium`, and all
  five keymaps (`9s`/`9vv`/`9x`/`9m`/`9P`) are identical to the Windows config,
  but the plugin now loads from GitHub (`ThePrimeagen/99` with a telescope
  dependency) instead of a local `~/personal/99` clone, which doesn't exist on
  this machine. Keymaps gained `desc` labels for which-key.
- `auto-save.lua` carried over intact (okuuva fork, `noautocmd` +
  `TextChangedI` triggers, and the `vim.cmd` proxy that re-sends
  `textDocument/didSave` after autosaves), now living at `lua/plugins/`.
- `harpoon` carried over as a normal GitHub-sourced spec.
- `README.md` replaced by the LazyVim starter README; `LICENSE` (Apache-2.0,
  from the starter), `lazyvim.json` (extras: `neo-tree`, `lang.rust`),
  `.neoconf.json`, and `stylua.toml` added.

### Added
- Omarchy desktop integration: `omarchy-theme-hotreload.lua` (live theme
  switching), `all-themes.lua`, `plugin/after/transparency.lua`, and
  `lua/config/remote_clipboard.lua`.
- `disable-news-alert.lua` and `snacks-animated-scrolling-off.lua` LazyVim
  tweaks.

### Removed
- Config no longer provides its own `islands-dark` colorscheme, `lualine`,
  `conform`, `telescope`, `treesitter`, `autopairs`, `toggleterm`, `lightbulb`,
  or `misc` specs — LazyVim ships equivalents (or Omarchy theming supersedes
  them, in the colorscheme's case).
- `flutter-tools.lua` and the PowerShell/ESLint LSP wiring — this machine's
  config is currently scoped to Rust.
- `bootstrap-device.ps1` and the OneDrive junction workflow (Windows-only).

## [Unreleased — Windows lineage, superseded by 1.0.0 on this branch]

### Changed
- **`setup-onedrive-link.ps1` replaced by `bootstrap-device.ps1` — a full autonomous
  device bootstrap, not just a link script.** Meant to be run from an elevated shell
  directly off GitHub (`irm .../bootstrap-device.ps1 | iex`) on a clean machine, or one
  with an existing config to replace. Every dependency this config actually needs is
  installed if missing (checked against this real dev machine's actual installed state,
  not guessed): Git, ripgrep, Node.js, Rust (rustup), a C compiler (`BrechtSanders.WinLibs`
  — the actual gcc this machine uses for Treesitter parser builds, not MSVC), Neovim, and
  the Claude Code CLI, all via `winget`; the Flutter SDK via direct download (no winget
  package exists for it — fetched from Flutter's own `releases_windows.json` manifest,
  extracted to `C:\flutter-sdk`, matching how it's actually installed here); the
  `harpoon`/`99` local plugin clones; the PATH entries winget/rustup don't register
  automatically (`.cargo\bin`, the WinLibs `mingw64\bin`, `flutter-sdk\bin`); winget itself
  if even that's missing; and finally the OneDrive link, followed by a headless
  `Lazy! sync` so plugins are ready before the first real launch. Every step is
  independently idempotent (checked via `Get-Command`/`Test-Path` before acting) so
  re-running after a partial failure only does the remaining work.

  **Now prompts before touching an existing local config** instead of silently linking
  over it — detects a non-matching `%LOCALAPPDATA%\nvim`, asks `[y/N]`, and backs it up to
  `nvim.bak.<timestamp>` before creating the junction if confirmed; aborts with no changes
  if declined.

  Two steps are deliberately left manual since they're credential/GUI flows that
  shouldn't be scripted: signing in to OneDrive, and `claude auth login`.

  Verified: syntax-checked via `[System.Management.Automation.Language.Parser]::ParseFile`
  before ever running it; ran the full script end-to-end on this real machine (every
  prerequisite already present, so every step correctly took its idempotent skip path,
  down to the exact existing PATH entries and the already-correct junction) with zero
  prompts and zero errors; separately tested the new overwrite-confirmation logic in
  isolation against throwaway fake paths for both the decline path (aborts, no changes)
  and the confirm path (backs up with the original file content verified intact, then
  links correctly) — did not exercise this against the real config to avoid any risk to
  it.

### Changed
- **Config now lives on OneDrive for cross-device sync**, not directly at
  `%LOCALAPPDATA%\nvim`. Moved the whole repo to
  `<OneDrive>\cross_device_configs\neovim` and replaced the original location with a
  directory junction pointing at it (junctions over symlinks: no admin rights or
  Developer Mode needed). Neovim needs zero config changes since it still finds
  everything at the default path it always checks — the junction is transparent to it,
  to git, and to every tool that touched this repo throughout this whole log. `nvim-data`
  (installed plugins, Mason tools, undo history) deliberately stays local and unsynced —
  it's machine-specific and `lazy.nvim` rebuilds it automatically on first launch anyway.
  Added `setup-onedrive-link.ps1` (idempotent) for creating the matching junction on
  additional devices once OneDrive has synced the folder there; documented in the README.
  Verified: `Move-Item` initially failed with the folder in use — root-caused to two
  live `nvim.exe` processes plus this very session's own shell having its working
  directory inside the folder (Windows locks a directory while any process's cwd points
  into it, unlike Linux) — closed both and confirmed the move, junction creation, a
  headless Neovim boot through the junction (`colors_name`/`stdpath('config')` both
  resolve correctly), and `git status`/`git log` all working unchanged from the new
  physical location.

### Changed
- **Colorscheme: `rose-pine` → `islands-dark`, ported directly from the user's real
  RustRover "Islands Dark" scheme.** "Islands" itself is JetBrains' 2025 UI-chrome
  redesign (rounded corners, panel spacing) — not a distinct syntax palette — confirmed
  by checking JetBrains' own announcement post, which describes only layout changes and
  publishes no color values. The actual editor colors are still Darcula-derived
  (`parent_scheme="Darcula"` in the exported file). Rather than guess at hex values, the
  user exported their scheme from RustRover (Settings → Editor → Color Scheme →
  Export → `.icls`) and every color in `lua/config/colors/islands-dark.lua` is read
  directly from that file's real hex values — background `#191a1c`, foreground `#bcbec4`,
  keywords `#cf8e6d`, strings `#6aab73`, numbers `#2aacb8`, functions `#56a8f5`,
  constants/fields `#c77dbb`, etc. Replaces `rose-pine/neovim` entirely (dropped from
  `lazy-lock.json`); loaded as a local, non-cloned `lazy.nvim` spec (`dir =
  vim.fn.stdpath("config")`) rather than an external plugin, since it's a one-off port
  specific to this exported theme, not a general-purpose published colorscheme. Verified:
  confirmed `Normal`'s fg/bg resolve to the exact source hex values byte-for-byte, and
  re-ran the same lualine per-mode color-differentiation check from the earlier
  statusline work against the new palette (still passes — `lualine_a_normal` /
  `_insert` / `_visual` all resolve to distinct backgrounds under the new colors).
  `DiagnosticVirtualText*` groups explicitly link to their base `Diagnostic*` groups from
  the start, avoiding the fg==bg invisibility bug rose-pine had.

### Added
- `lualine.nvim` for a real statusline mode indicator. Previously there was no statusline
  plugin at all — the "mode name at the bottom" the user was seeing was Neovim's own
  `showmode` echo-area message (`-- INSERT --`), which isn't colored and only redraws on
  certain events, reading as "stuck." Configured with `theme = "auto"` (derives colors
  from the active colorscheme's highlight groups, so it follows rose-pine without a
  dedicated theme) and `globalstatus = true` (one statusline for the whole editor, not one
  per split). `showmode` turned off since the statusline now covers it. Verified with real
  evidence: confirmed lualine's per-mode highlight groups (`lualine_a_normal`,
  `lualine_a_insert`, `lualine_a_visual`) resolve to genuinely different background colors,
  and confirmed the rendered statusline text switches from `NORMAL` to `VISUAL` on an
  actual mode change (`normal! v`) evaluated via `nvim_eval_statusline`. Insert-mode text
  couldn't be verified the same way — `startinsert` doesn't perform a real mode transition
  in headless Neovim without an attached UI (confirmed separately: `vim.fn.mode()` stays
  `"n"` after it), the same category of headless-simulation limitation noted elsewhere in
  this log — but the underlying mechanism (lualine's `mode` component reads
  `vim.fn.mode()` on every redraw) is identical for all modes, so this isn't a gap in the
  fix, just in what headless automation can simulate.

### Fixed
- **Regression from the previous release: `vim.cmd.helptags(...)` (and any other
  dot-call form of `vim.cmd`, e.g. `vim.cmd.write()`) threw `attempt to index field
  'cmd' (a function value)`.** The `didSave` fix in `auto-save.lua` replaced
  `vim.cmd` outright with a plain function to intercept its string-call form -
  but `vim.cmd` is a callable *table* that also supports dot-access
  (`vim.cmd.write()`, `vim.cmd.help()`, etc.), and a plain function has no fields
  to index. This broke lazy.nvim's own periodic doc-update routine
  (`lazy/help.lua:43: vim.cmd.helptags(...)`) in practice, visibly, in a live
  session. Fixed with a proper `setmetatable` proxy: `__index` forwards dot-access
  to the untouched original `vim.cmd`, `__call` intercepts only the plain
  string-call form. Verified against the exact failing call
  (`vim.cmd.helptags(...)`) plus a couple other dot-call forms, and re-verified
  both the `didSave` notification and the format-on-save skip still work
  unchanged - no regression on the fix this was fixing.

### Added
- `<Tab>` now confirms the selected completion item, same as `<C-y>` - but only
  when the completion menu is actually open; otherwise it falls through to
  normal `Tab` behavior. Standard `cmp.mapping()` + `fallback()` pattern.

### Fixed
- **Still needed to leave insert mode for the didSave fix (above) to kick in.**
  `auto-save.nvim`'s `defer_save` trigger events were `{"InsertLeave", "TextChanged"}` -
  but `TextChanged` only fires for edits made *outside* insert mode; its insert-mode
  counterpart is `TextChangedI`, which was missing. So the debounced save (and the
  `didSave` notify riding on it) never fired while actively typing, only once `Esc` was
  pressed. Added `TextChangedI` to both the plugin's lazy-load `event` and
  `defer_save`. The debounce implementation cancels and reschedules its timer on every
  trigger (confirmed by reading `auto-save.nvim`'s own source), so this doesn't cause a
  save flood while typing - it still only fires ~1s after you *stop*, just without
  needing a mode switch first. Verified end-to-end with `InsertLeave` never fired at
  all in the test: diagnostic appeared in ~1.5s from `TextChangedI` alone.

- **Diagnostics never refreshed without a manual `:w`, even after `update_in_insert`.**
  Root-caused with hard evidence, not guessed: `auto-save.nvim`'s `noautocmd = true`
  (added specifically so autosaves wouldn't trigger format-on-save) suppresses *all*
  autocmds during the write — including the LSP client's own `BufWritePost`-triggered
  `textDocument/didSave`, which rust-analyzer's on-save diagnostic refresh
  (`check.command = "clippy"`) depends on. Confirmed directly: a `noautocmd write` sends
  zero LSP notifications; a normal `write` sends `didSave`. Also confirmed the rest of
  the pipeline was fine along the way - `didChange` fires correctly on every edit,
  document sync is correct (verified via `hover` reflecting brand-new code within
  seconds), and Neovim's own pull-diagnostic auto-refresh is wired automatically on
  attach - the gap was specifically the missing `didSave`.

  Fixed in `auto-save.lua` by wrapping `vim.cmd` narrowly: only for the exact command
  string `auto-save.nvim` builds internally, manually send `textDocument/didSave` right
  after the real (synchronous) write completes - correctly ordered, no vendored plugin
  patched, format-on-save still correctly skipped for autosaves. Verified end-to-end
  with zero manual saves involved: typed an error, waited for autosave's own debounce
  cycle, diagnostic appeared in ~1.5s.

- **Diagnostic virtual text was rendering invisible.** rose-pine's own
  `DiagnosticVirtualText{Error,Warn,Info,Hint,Ok}` groups set `fg == bg` (with a blend),
  so the inline error/warning message text was the same color as its own background —
  the extmark was genuinely being drawn (confirmed via `nvim_buf_get_extmarks`), it just
  couldn't be seen. Its `DiagnosticSign*` groups already correctly link to the fg-only
  `Diagnostic*` groups; extended that same pattern to the virtual text groups in
  `misc.lua`, after the colorscheme loads.
- **Diagnostics appeared to require `:w` to update.** Neovim's `update_in_insert`
  defaults to `false` (diagnostics only redraw on `InsertLeave`, not while still typing)
  — since `Esc` always precedes `:w`, it read as "only updates on save" when it was
  really "only updates on leaving insert mode." Set `update_in_insert = true` in
  `lsp.lua` for RustRover-style continuous feedback while actively typing. Confirmed
  correct against Neovim's own documented semantics for this option; the live
  while-still-in-insert-mode behavior itself couldn't be synthetically verified in
  headless automation (same category of limitation as simulated keypresses elsewhere in
  this project), so this one is verified by mechanism/docs rather than a headless repro.

### Added
- `nvim-lightbulb` — shows a 💡 sign in the gutter whenever a code action (quick fix,
  suggestion, auto-import, etc.) is available at the cursor, same idea as JetBrains'
  lightbulb icon. `<leader>vca` already triggered code actions; this makes it visible
  *when* one exists instead of needing to check manually. Verified end-to-end: set up a
  real local ESLint install + flat config in a test project, confirmed the LSP itself
  flags a real lint violation (`source=eslint code=eqeqeq`), confirmed a code action is
  genuinely offered for it, and confirmed the lightbulb sign gets placed on that exact
  line.

### Verified (no code change)
- ESLint (`vscode-eslint-language-server` via Mason) resolves ESLint from the **project's
  own** `node_modules` — it does nothing without a real local ESLint install and a config
  file (flat config or legacy). This wasn't previously tested end-to-end; confirmed now
  with a real violation caught through the LSP, not just via the CLI.

## [0.2.0]

### Added
- `auto-save.nvim` (`okuuva` fork — the original `Pocco81/auto-save.nvim` has been
  unmaintained since 2024-05) for RustRover-style background auto-save. Configured with
  `noautocmd = true` so debounced autosaves don't also trigger format-on-save; only a
  manual `:w`/`<leader>f` formats. Verified: an intentionally mis-formatted file survives
  an autosave untouched, then reformats correctly on manual save.
- Inline diagnostics styling: virtual text with gutter sign icons (``/``/``/``),
  underline, severity-sorted — matches the inline error-message style from JetBrains IDEs.
- Inlay type hints, auto-enabled on any LSP client that supports `textDocument/inlayHint`.
- Real-time clippy for Rust: `rust-analyzer.check.command = "clippy"`. Verified with a
  clippy-only lint (`needless_return`) that plain `cargo check` never flags.
- `--effort medium` for all 99/Claude Code requests, via 99's own `provider_extra_args`
  setup option (not a source patch, so it isn't lost on plugin updates).

### Changed
- `model` in `ninety-nine.lua`: `claude-sonnet-4-5` → `claude-sonnet-5`.
- `lua/config/plugins/lsp.lua` rewritten to use the native `vim.lsp.config()` /
  automatic `vim.lsp.enable()` flow instead of `mason-lspconfig`'s `handlers` option.

### Fixed
- **`mason-lspconfig`'s `handlers` API no longer exists in the installed version** — the
  custom `rust_analyzer`/`powershell_es` handlers from the original setup were silently
  never called; `mason-lspconfig` now installs servers and calls `vim.lsp.enable()`
  automatically on its own. Found by inspecting the actual installed plugin source, not
  assumed from older docs. Rewired capabilities/settings through `vim.lsp.config()`,
  which deep-merges with nvim-lspconfig's own per-server defaults instead of replacing
  them.

## [0.1.0] — initial commit

First push. Bootstrapped from scratch (inspired by, not cloned from, ThePrimeagen's
init.lua), scoped to Rust / Node+TypeScript / PowerShell / Flutter+Dart plus 99 on
Claude Code.

- lazy.nvim, Telescope, Treesitter + treesitter-context (lua, vim, vimdoc, query, rust,
  javascript, typescript, tsx, dart, powershell, json, markdown, bash)
- nvim-lspconfig + mason.nvim + mason-lspconfig, nvim-cmp stack, LuaSnip +
  friendly-snippets, conform.nvim
- Harpoon (`harpoon2` branch, local clone) and 99 (local clone), both from
  ThePrimeagen's repos
- undotree, vim-fugitive, trouble.nvim, fidget.nvim, zen-mode.nvim, cloak.nvim,
  rose-pine (single colorscheme)
- nvim-autopairs, toggleterm.nvim
- netrw tuned to match ThePrimeagen's own settings (`browse_split`, `banner`, `winsize`)
- Explicitly excluded: Go tooling, php.nvim, jai.vim, refactoring.nvim,
  cellular-automaton.nvim, brightburn.vim, golf, supermaven-nvim, nvim-dap
