# Changelog

All notable changes to this config are documented here.

## [Unreleased]

### Changed
- `<leader>rM` (extract module) is visual-mode only: rust-analyzer offers the
  assist only for a selection, so the normal-mode map just reported "No code
  actions available". README and which-key say so. Not re-run in nvim.

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
