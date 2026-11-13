# Changelog

All notable changes to this config are documented here.

## [Unreleased]

- Warnings and errors sweep 1, 2026-11-13 (branch `dev`, not pushed; spec `tests/warnings-guard_spec.lua`, 12 checks, 46 s). Method: a copy of the data directory, EMPTY state and cache, the real config in tmux (93 x 46 and 140 x 40) and in Ghostty on X11 (its default window, 93 columns; `--window-width/--window-height` were ignored on this machine, so the wide Ghostty runs used `--font-size=8.9`, about 133 columns), once with the pinned plugins and once with `XYNOVIM_DEV_PLUGINS`; every `:messages` line, notification (snacks history), E-code, `vim.deprecate` and highlighted error was recorded during start, the first `.rs` file of `demo/netwatch` (a copy), an edit with a type error, one with a clippy warning, save, test run (`<leader>tt`, results panel), debug start and stop, the sandbox policy, local history, run configurations, macro and rainbow commands, yank and paste; `:checkhealth` ran for every provider after `:Lazy! load all` (blink.cmp, conform, dap, lazy, lspconfig, mason, noice, nvim-treesitter, rustaceanvim, snacks, telescope, vim.*, which-key, every `xyno_*` module and more); the vim.lsp, nvim, dap, mason and rust-analyzer logs were read afterwards. Found and fixed: (1) **a frozen editor on the first Rust file of an untrusted workspace with the plugin clones** (three nested `vim.wait` calls, the innermost `pgrep lspmux` of rustaceanvim never returned; the editor stayed frozen for minutes): the statusline (`workspace_trust.status`), the `FileType` attach of xyno-crates (`features/action.lua`, clone commit `a64cc57`) and the settings callback of rustaceanvim now ask `rust_context.root(path, { nowait = true })` (xyno-rust `crate_meta.root` takes the option, clone commit `351a1e9`); (2) the trust restart stopped rust-analyzer with SIGTERM and rust_restart reported `rust-analyzer exited (code 0, signal 15); restarting` as a warning: graceful stop, forced only after 2 s; (3) `:checkhealth vim.lsp` warned about mixed position encodings (rust-analyzer utf-8, bacon-ls and the in-process clients utf-16): rust-analyzer is asked for utf-16; (4) `:checkhealth which-key` listed `<leader>r` as duplicated (a buffer-local copy of the global group): removed; (5) `:checkhealth render-markdown` warned about LaTeX (no parser, no converter): latex rendering is on only when `utftex` or `latex2text` exists; (6) `:checkhealth xyno_clipboard` said "yanks never reach any clipboard" (an ERROR) for tmux with `set-clipboard external` although wl-copy copies to the Wayland clipboard (tested): a WARNING with the same advice then (clone commit `a6a6cce`), still an ERROR without a native tool; (7) LazyVim calls `vim.lsp.codelens.refresh`, which Neovim 0.12 deprecates (removed in 0.13) and printed a `vim.deprecate` notice at every code-lens attach: a shim to `vim.lsp.codelens.enable` in `lua/config/lazy.lua` until LazyVim moves; (8) `v:errmsg` held `E1237: No such user-defined command in current buffer: RustRun` after every `.rs` open (rust.vim's `undo_ftplugin` after the `silent!` patch of `after/ftplugin/rust.lua`; `silent!` hides the message but sets `v:errmsg`): `try|...|catch|endtry`. The guard spec starts nvim in both modes with empty state, opens the `basic` fixture, runs `:checkhealth` for all providers and fails on any unexpected `:messages` line, E-code, `vim.deprecate`, WARN/ERROR notification or health WARNING/ERROR that is not on its commented allowlist (`ENV_LIMITS`: missing optional tools, terminal capabilities, headless-child artefacts, upstream health checks of features this config switches off); its first run failed on exactly the code-lens deprecation (7) and the `v:errmsg` E1237 (8), which is how they were found, and on health lines that went to the allowlist (headless-child artefacts) or were fixed. NOT fixed and why: the pinned plugins of `lazy-lock.json` predate `:XynoSandboxPolicy`, `:LocalHistoryPanel` and `:RustRun` (lazy.nvim says `Command ... not found after loading` or E492 until the lock is bumped; that needs the plugin commits pushed, a decision for the owner); optional tools (`cargo-nextest`, `prettier`, `fish_indent`, `gs`, `mmdc`, `tectonic`, `hg`, `ast-grep`, `gRPCurl`, `websocat`, Ruby/PHP/Java toolchains for Mason, the `wasm32-unknown-unknown` target) are reported by their health checks as they should be; `which-key` overlap notes of `gc`, `gr`, `gs*`, `i`, `a` are Neovim 0.12 and mini.* defaults; `:checkhealth vim.pack` creates an empty `site/pack/core/opt` and `:checkhealth lazy` then warns about it; the lsp.log lines `-32801 content modified` and rust-analyzer's `notify error: No path was found` are upstream. Notes for whoever drives Neovim by script: in normal mode `q` starts which-key's macro-register prompt and blocks until a key arrives (an automation that sends `q` to close a popup freezes until the next key); wrapping `vim.notify` before LazyVim's 500 ms collector is replayed loops for ever when a notification was collected (a spec-side hazard, see `tests/helpers.lua` `settle_notify`).
- Failure paths R3, 2026-11-13 (branch `dev`, not pushed; specs `tests/agent-failure-reason_spec.lua`, `tests/layout-narrow_spec.lua`, `tests/test-failure-paths_spec.lua`, plus `tests/manifest-explain_spec.lua` and `tests/ra-missing_spec.lua` in xyno-rust.nvim `dev`): a failed 99 agent run (non-zero exit) no longer raises an unhandled Lua error with a stack trace (99's base provider calls `logger:fatal`, which is `assert(false)`; it is downgraded to an error entry) and shows ONE message with Claude's real reason ("Not logged in - Please run /login" is on stdout, bwrap's own text on stderr) plus a hint for login, missing `claude`, blocked user namespaces, network and a killed agent; stdout/stderr are kept capped (8 KB), a 3 MB output no longer lands in the message; a failed spawn (`claude` missing without the sandbox) is the same one message; `print_on_error` is off (it printed a JSON line). **Layouts below 120 columns** (`lua/config/narrow.lua`, `vim.g.xynovim_narrow_columns`): the neotest summary opens as a float over the right edge (`q` or leaving it closes it) and dap-ui is one bottom strip instead of a sidebar plus strip; before/after captures at 93 columns in `docs/comparison/screenshots/narrow/` (the code window was 21 columns, now 93). `<leader>tP` says nextest is not installed instead of offering profiles that change nothing; a test run still going after 60 s says `<leader>tS` stops it. A workspace that fails to load (broken `Cargo.toml`, bad feature) shows cargo's own error with file and line (`xyno_rust.lsp_status.explain`, needs the xyno-rust.nvim `dev` commit; rustaceanvim's "Failed to load workspaces" toast is switched off only where it exists); the statusline says `RA missing` for a Rust buffer without a rust-analyzer binary; a missing codelldb is one message with `:MasonInstall codelldb`. Checked by hand and not changed: crates.io search and `cargo add` through an unreachable proxy (already say offline), local history in a repository whose loose objects are empty (writes, snapshots and the browser still work), a read-only project (bacon-ls reports the failed Cargo.lock write). Not done: a watchdog for a SIGSTOPped rust-analyzer (the statusline keeps saying ready), real-pixel tmux captures of these paths.
- UX R4, 2026-11-13 (branch `dev`, not pushed; specs `tests/diag-long-line_spec.lua`, `tests/diag-dedup_spec.lua`, `tests/blink-binary_spec.lua`): **cursor-line diagnostics on a long line** (`lua/config/ui.lua`): when fewer than 20 columns are left beside the line (inline inlay hints and end-of-line hints now count towards the line's width) and the message does not fit whole, it is drawn under the line in a `virt_lines` block, wrapped at words to the window, indented like the code, at most 6 lines, instead of `× expecte` at the end of the line; it follows the cursor and goes away when the cursor leaves the row (checked on the real screen grid at 80 columns; hints that arrive after the diagnostic are noticed on the next cursor move or diagnostic update, not at once). **bacon-ls duplicates**: bacon-ls publishes one identical diagnostic per span; `lua/config/diag_dedup.lua` is the server's `publishDiagnostics` handler and drops exact duplicates (same range, severity, code, source, message; a fake LSP client in the spec counts 1, not 3), so the glyphs and the statusline count are right. **blink.cmp fuzzy library**: once-only across processes: an exclusive lock file and the attempt stamp now live in the plugin directory (the stamp used to be in the per-run state directory, which every spec instance starts empty, and a Neovim that exits mid-download left `v0.0.0` behind for the next one to download again), a dead or 5-minute-old lock is taken over, `v0.0.0` means "downloading" only while a live process holds the lock (otherwise "interrupted", under the 6 hour back-off), `:checkhealth` names the process and how long it has been downloading, and the spec runner sets `vim.g.xynovim_blink_download = false` (specs never download into the shared plugin directory; `XYNO_TEST_BLINK_DOWNLOAD=1` lifts it). The README claim that the suite runs after a clone is unchanged (`test-infra-readme-claims` spec passes). Not verified: a real download racing a second real Neovim (the race is specced with a live child process holding the lock; no download was started), the long-line block against a live rust-analyzer.
- Trust fingerprint R2, 2026-11-13 (`lua/xynovim/trust_fallback.lua` and xyno-rust.nvim `dev` `trust.lua`, same code in both; specs `tests/trust-fingerprint_spec.lua` here and `tests/trust_fingerprint_spec.lua` in the plugin, 19 each): the fingerprint also covers a build script at a custom path (`package.build = "x/gen.rs"`) and the modules it declares (`mod x;`, `#[path]`, `include!`), path dependencies (followed through their manifests, 64 manifests at most) and workspace members outside the root (including `dir/*` globs) with their manifests and build scripts, and every `.rs` file of a proc-macro crate (200 at most); files are hashed whole up to 32 MiB in 1 MiB chunks (before: the first MiB only), beyond that the first 32 MiB, the last MiB and the size. The list comes from `cargo metadata --no-deps --offline` read in the background (`trust.prime`, started after `trust`; `--no-deps` ran neither `build.rustc`, a wrapper nor a build script in the canary spec; `RUSTUP_AUTO_INSTALL=0`) plus a bounded manifest scan for the synchronous calls and when cargo fails; an entry compared before this session's metadata is there also watches the names it recorded, so there is no false drift. Entries recorded by the earlier version ask once more for a workspace with such files. Not verified: a very large real workspace (the bounds are specced with a 150-path-dependency chain), Windows. The new specs were written together with the code, not run against the old fingerprint first.
- Rainbow review fixes R1, 2026-11-13 (branch `dev`, not pushed): `:XynoRainbow mouse off|toggle` and `set scope.mouse false` now unmap / remap `<C-RightMouse>` and `<A-RightMouse>` (`R.set` calls the scope setup; the handler checks the option); `:XynoRainbow set custom #ff0000 #00ff00` takes space-separated lists as well as JSON, `set disable`, `set disable []` and `set disable none` clear the list; every successful action was shown as a WARNING (Lua `ok and nil or WARN`), now INFO, refusals WARN; `restrain_strength` is the fraction of the way down to the 4.5:1 floor, so 0.3 / 0.65 / 0.9 are different greys; hosts the parser could not parse (ERROR nodes and nodes holding one) are scanned in full up to 5000 children (flat brackets in the middle of a big ERROR node were never coloured: 1204 of 1803 brackets before, all after), levels around an invalid line `{[<x]}` are asserted, the limit is documented (docs/RAINBOW.md, "Parser error recovery"); the words rules are data (`parts`, `add_rule`), rules for Ruby, C++ and Kotlin exist but have never been run against a parser (grammars not installed, nothing may be downloaded: needs `:TSInstall ruby cpp kotlin`, `:XynoRainbow status` lists the waiting parsers); `scope.box = "outline"` (default) draws virtual-line borders, side edges and inverted brackets, and the tint skips nvim-dap's stopped line. Not verified: the outline on real Ghostty pixels, the Execution Point rule against a live debug session (asserted with a placed `dap_pos` sign), the three dormant rules. The new specs were written together with the code; the ERROR-node one was checked to fail with the old bound (1204 of 1803 marks).

- Integration round 3, 2026-11-13 (branch `dev`, not pushed): whole-suite runs in one piece, pinned plugins 57 files 1287 passed, 0 failed, 49 skipped (568 s), plugin clones 1304 passed, 0 failed, 32 skipped (580 s); the README, TESTING, PROGRESS, DEV-PLUGINS and comparison pages carry those numbers. The lockfile-drift check passes now (the installed plugins are at the pinned commits; I did not run `Lazy restore`). Plugin suites on their `dev` branches: clipboard 42, crates 114, guard 63 (7 skipped), history 158 (6), imports 67, macros 283 (2), new 230, rust 414 (1), sandbox 1102 (1 expected failure), all 0 failed. StyLua over the five sandbox spec files that were out of format, `.stylua.toml` added to xyno-history (same settings as the other plugins); `stylua --check .` is clean in xynovim and in all nine clones. xyno-sandbox `dev` (not pinned): git write mode bypasses closed (`.git`, `modules/` and submodule git dirs are mount points, `commondir` pinned, rebase / sequencer / worktrees state locked; rebase, `am`, `worktree add` and `submodule add` fail inside the sandbox in that mode), the demonstrated mutation survivors have specs, the test runner no longer leaves directories behind; the sandbox's own CHANGELOG lists what was not fixed. Comparison MATRIX and ONE-PAGE: rainbow rows RB1 to RB6, sandbox git row ST1, trust fallback row ST2, the commands to run yourself.
- Rainbow keywords and tags, 2026-11-12 (`lua/config/rainbow_words.lua`, options `words.keywords` / `words.tags`, `:XynoRainbow keywords|tags`): Python keywords, C `#if` family, HTML / XML / JSX tags and YAML keys coloured by depth, off by default, asserted in `tests/rainbow_spec.lua` and captured on real Ghostty pixels. Also: `:XynoRainbow colors abc` names the rejected value; the effect of a switched-off kind on unmatched marking is documented and specced. Not built: Ruby keywords, C++ `#if` as its own rule, Kotlin arrows and labels (grammars not installed).
- Rainbow brackets, 2026-11-12 (branch `dev`, not pushed; [docs/RAINBOW.md](docs/RAINBOW.md), spec `tests/rainbow_spec.lua`, 87 checks on the real grid, the main features at 60 / 120 / 200 columns): the JetBrains plugin Rainbow Brackets as the baseline, implemented natively on tree-sitter (`lua/config/rainbow.lua`, `rainbow_palette.lua`, `rainbow_scope.lua`, `rainbow_vars.lua`, `rainbow_cmd.lua`; started from `options.lua` by a small boot module (a command and a VeryLazy autocmd; no lazy spec, which would be a plugin without a lock entry), no new dependency; rainbow-delimiters.nvim was not used: no scope highlight, no unmatched marking, no contrast guarantee, not installed). Brackets coloured by nesting depth for any language with tree-sitter highlighting (Rust: `()` `[]` `{}`, generics and turbofish, closure pipes, macro bodies, attributes; strings, comments, char literals, lifetimes and a comparison `<` are not touched), switches per kind, cycle over all kinds or per kind, skip the first level, number of colours, island / colour-blind / custom (per kind) / generated palettes (hue, luminosity), contrast lifted to 3:1 (7:1 with `:IslandContrast high`) against the editor and the caret row in Island Dark and Island Light, unmatched-bracket marking, a disable list (filetype, language, extension), `max_lines` and large-file handling (only visible lines are processed), scope highlighting and restrain (`Ctrl` / `Alt` + right-click, `<leader>uj` / `uJ`, ESC or any key, tint alpha, keep colours, suppress while debugging or diffing), rainbow variables (off by default), `:XynoRainbow` with every switch, `palette next`, `colors show|freeze|save`, `set`, `save`, `reload`, a validated `vim.g.xynovim_rainbow`, a `:checkhealth xynovim` section. Not built then (see the later entries: Python keywords, C `#if` and HTML / XML / JSX / YAML tags were built the next day, the scope outline and the Execution Point rule in the review round below, Ruby / C++ / Kotlin rules are written but never run): rainbow indent guides were excluded by request and the indent guides are untouched. Found by the new latency probe (`scripts/bench/rainbow.sh`): a synchronous `parse()` from the decoration provider forced a 900 ms reparse after typing an unbalanced `{` in a 38 000-line file (nvim 0.12's highlighter parses asynchronously); the provider never parses now. Measured 2026-11-12 under load (redraw +1 to 2.4 ms, typing +1.7 to 1.8 ms; startup: no change measurable, 0.1-0.4 ms boot plus 1.0-1.7 ms engine setup in-process): [docs/RAINBOW.md](docs/RAINBOW.md#measured).

- Review round U1-U11 + sandbox F1, 2026-11-12 (branch `dev`, not pushed; specs written to fail first where testable). **U1** rust.vim's buffer-local `:RustRun` shadowed the run-configuration picker in every `.rs` buffer: `after/ftplugin/rust.lua` removes it (kept as `:RustVimRun`), `tests/rust-buffer-commands_spec.lua` opens a real buffer. **U2** the trust prompt is a wrapped, sized float (`xyno_rust.trust_prompt`, copy in `lua/xynovim/trust_prompt.lua`), mode restored; captured in tmux at 60/80/120 columns (whole question visible, normal mode after the answer). **U3** no permanent `clip: tmux drops OSC52` on a local Wayland session with wl-copy (`lua/xynovim/clip.lua`; xyno-clipboard `dev` does the same). **U4** `cargo add` / feature switches of xyno-crates re-record the trust (and the pinned plugin is wrapped by `workspace_trust.wrap_crates`); "run this once" now ends when a manifest changes; the fingerprint walk is capped (2500 directories) and memoised on stat stamps (not a thread: the FocusGained re-check stats instead of walking). **U5** vendored `lua/xynovim/trust_fallback.lua` (same API and file as `xyno_rust.trust`) is used only when the plugin has no trust module, so the pinned set works; `tests/trust-fallback_spec.lua` runs in both modes, and the test runner no longer switches the gate off in default mode. **U6** organize-on-save's `BufUnload` autocmd is grouped per buffer; the Nerd Font cache key sees font subdirectories, "no Nerd Font" expires after 10 minutes and `:XynoIcons` / `:checkhealth` ask afresh. **U7** lifetime hints off by default (rust-analyzer's own default), parameter hints skip self-explanatory arguments. **U8** the scopes pane lists locals only (`vim.g.xynovim_dap_scopes = "all"` restores the rest), dap-ui closes after `dap.terminate()`. **U9** overseer's neotest tasks drop their `on_complete_notify`: one popup per run. **U10** the startup binary download is blink.cmp's prebuilt fuzzy library from `github.com/saghen/blink.cmp/releases` (`lua/config/blink_binary.lua`): none when present, one when missing, never concurrent, 6 h back-off, `vim.g.xynovim_blink_download = false`, reported by `:checkhealth xynovim`. **U11** README says the agent cannot commit by default (the spec title claimed it could); xyno-sandbox `policy.git_write`. **F1** growth of the walk inside `target/` is INFO, no longer a refused next launch. Not verified here: pixel captures in Ghostty (the prompt was checked on the tmux grid), the pinned plugin set with an updated `lazy-lock.json`.

- Integration round 2, 2026-11-12 (branch `dev`, not pushed): StyLua applied to the Lua of the last builders in xynovim and all nine plugin clones (`stylua --check .` clean everywhere; each plugin uses its own `.stylua.toml`). Full suites: `scripts/test.sh` 1137 passed, 1 failed (installed plugins off `lazy-lock.json`, the owner's `Lazy! restore`), 67 skipped; with the plugin clones 1185 passed, 1 failed (same), 32 skipped; 49 spec files (the README, badge and site said 43). Spec fixes: `agent-99-guard` accepts the absolute `/usr/bin/env` and `bwrap` the newer xyno-sandbox starts, `debug-values` no longer takes a Noice notice for the message it waits for. Benchmark harness: `hook.lua` switches the workspace trust gate off for its temp crate (otherwise the pinned plugins measure restricted mode without bacon-ls); `docs/bench/final-2026-11b.md` has a paired old/new check under load, no regression found.

- UI round 3, 2026-11-12 (branch `dev`, not pushed): **end-of-line inlay hints** (`:Hints eol` / `:Hints inline`, `vim.g.xynovim_hints_style`, `lua/config/eolhints.lua`; shortlist item 16; the code does not move, hint text is a summary, long lines get none), **hand-tuned `island-light`** (`lua/island/light_palette.lua`: one chosen light colour per Island Dark colour, designed after JetBrains Light / Islands Light, GitHub Light, catppuccin-latte, tokyonight-day; `Normal` #ffffff, text 15.9:1, syntax >= 5:1, comments 5.3:1; per-key-group minimums in `tests/ui-community_spec.lua`; plugin tints still fall back to the old flip), plugin popups wrap at words with a hanging indent, proc-macro report wraps its first line (xyno-macros.nvim `dev`), real Ghostty captures of the sandbox policy, local-history panel, results panel, proc-macro report and diagnostic float at 80 / 120 / 200 columns (`docs/comparison/screenshots/ui3/`), competitor pictures from official pages (`docs/comparison/screenshots/competitors/`), rewritten `docs/comparison/ui-assessment.md` (per aspect, with what is worse). Not captured: macros signature popup and run-configuration picker (see the assessment).

- Rust IDE round 2, 2026-11-12 (branch `dev`, not pushed; needs the xyno-rust.nvim and xyno-new.nvim `dev` commits, `lazy-lock.json` does not pin them yet; run with `XYNOVIM_DEV_PLUGINS`; evidence and honest status per item in [docs/comparison/gaps-and-plan.md](docs/comparison/gaps-and-plan.md)): clickable Run / Debug lenses (a mouse click on the lens line; checked with real mouse escape sequences in a tmux terminal against the real config), `:RustRename` with a per-file diff preview (`<leader>rn`), shared run configurations in an opt-in, trust-gated `.xynovim/run.toml` (`:RustRunShare`; the trust fingerprint covers the file), `:RustProfile` hot-function and call-tree view of `perf script` / folded stacks / `perf.data` plus a `perf` run-configuration profiler (**not verified against a profile recorded here**: `perf record` is blocked on this machine), `:TokioConsole` project check and launcher with a one-time debug hint (a debugger still shows threads, not tasks), `:RustUsages` grouped usages (`<leader>rU`), `:RustNewFrom` template picker over a pinned list (copy only, no scripts). Startup: the new modules load on first use (about 0.1 ms at setup, measured in-process).

- Correctness and performance review fixes C1-C10, 2026-11-12 (branch `dev`, not pushed; each with a spec written to fail first). Plugins (clones on `dev`): **xyno-clipboard** - the Wayland copy no longer runs `wl-copy` synchronously on every yank (a hung `wl-copy` froze the editor: a fake one sleeping 30 s blocked a yank for the whole 60 s test timeout); it is a queued background job (in order, killed after 3 s, one notice per failure) and paste / `VimLeavePre` wait for the queue; passthrough chunks no longer cut an `ESC ESC` pair; the tmux "dropped" re-check is asynchronous and shares its queries with `query_tmux()`. **xyno-rust** - `cargo locate-project` timeouts / transient errors are no longer cached as "no workspace" (only cargo's "could not find Cargo.toml", for 30 s); `trust.ask` survives a raising or never-answering `vim.ui.select` (pcall, 5 min timeout, `VimLeavePre`); the state-file lock records an owner token and is reaped / released only by the verified owner. This config: `organize_on_save` always clears its per-buffer flag (pcall, 20 s timeout, `BufUnload`); `config/rendered.lua` uses one cleared augroup per float instead of three new ungrouped autocmds per open; cursor-mode diagnostics redraw only the lines around the cursor in place (wrapped `virtual_text` handler; 2400 diagnostics: a full `vim.diagnostic.show` took 184 ms, the incremental refresh 0.11 ms median, same extmarks as the full redraw checked over 44 cursor paths); `fc-list` and the `:checkhealth` terminal probes (`infocmp`, `tmux show-options`) no longer block the main thread (they run concurrently in the background) and the Nerd Font answer is cached in `stdpath("cache")/xynovim-fonts.json`, keyed on fontconfig's directories. New specs: `diag-cursor-incremental`, `organize-guard`, `rendered-float-autocmds`, `fonts-cache` here; `async_spec` (clipboard) and `robustness_spec` (xyno-rust) in the plugins. Startup (`scripts/bench`, `--only startup -n 10`): no change beyond noise (no file, ready: 69.4 / 65.7 ms before, 69.3 default / 71.7 dev-plugins after; none of these paths runs at startup). The totals of spec files and checks quoted elsewhere are from the earlier run and not updated here.

- Security review fixes S1-S3, 2026-11-12 (branch `dev`, not pushed; spec `tests/trust-gate-commands_spec.lua`, written to fail first). **S1**: every command of this config that runs project code now goes through one helper, `lua/config/workspace_trust.lua` (`allowed` / `require` / `system` / `install` / `guard_neotest`): coverage (`<leader>tc`), the doc-tests panel run, the debug build before a launch (`dap.lua`; inside nvim-dap's coroutine it asks, outside one it aborts with the `:RustTrust add` hint), rustaceanvim's runnables / testables / debuggables (its executors and `dap.start` are wrapped), every neotest run (`Client:run_tree`), and the cargo-deny / cargo-machete linters (their `cargo metadata` honours the project's rustc wrapper; skipped in an untrusted workspace). The run configurations (`:RustRun`), `:RustTargets`, profiling and `:MacroExpand` (cargo-expand) were already behind `xyno_rust.trust.require` inside their plugins. A source scan in the spec fails on any spawn of `cargo` / `rustc` / a variable command in `lua/` that is neither near a `workspace_trust` call nor annotated `-- trust: read-only <reason>`. **S3**: without a trust store (the xyno-rust.nvim that `lazy-lock.json` still pins has none) a workspace with a `Cargo.toml` up the tree is now restricted instead of trusted, with one notice and a `:checkhealth` error naming the fix (update the pin, or `vim.g.xynovim_workspace_trust = false`); a path without a Cargo.toml stays allowed. With xyno-rust.nvim api 1.3 (`dev`, commits `8ef2047`, `7ef3b7a`) a trust entry stores a fingerprint of every Cargo.toml and build.rs below the root and the `.cargo/config(.toml)` / `rust-toolchain(.toml)` files of the tree and its parents: when one differs (a pull, another branch) the workspace is untrusted again and the prompt names the changed files; saving such a file inside Neovim re-records it unless another of them changed too; FocusGained re-checks. Limit: rust-analyzer may already have reloaded the workspace between a `git pull` and the next focus. **S2** (xyno-crates.nvim `dev`, `96f1bb7`): text from the registry (newest version, repository URL, feature names and descriptions, advisory titles) is sanitised (escape sequences, control and bidi characters, newlines, length) and shown in a labelled block of its own in the `cargo add` confirmation; the plugin's own `WARNING:` lines never contain it.

- Debugger and test UX, 2026-11-12 (branch `dev`, not pushed; details and evidence in [docs/comparison/debug-test-ux.md](docs/comparison/debug-test-ux.md)): lldb summaries that show container contents (`scripts/lldb/xyno_rust_preview.py`), short type names, `<leader>dv` / `K` value float, one-line inline values, runtime frames hidden in the stack, closure / async frame names, logpoint / hit-count / exception-breakpoint keys, a warning when the Rust formatters did not load (+ `:checkhealth xynovim` section); `lua/plugins/neotest.lua` (output panel and summary placement, no per-run float or Trouble popup) and the results panel `lua/config/test_ui.lua` (`<leader>tp`: failure summary, per-test folds, assert_eq diff, rerun failed, doc-tests, nextest profile, coverage total, wall time). New specs `debug-values_spec.lua` (real codelldb, 21 checks), `test-ui_spec.lua`, `test-ui-neotest_spec.lua` (real neotest run). Not verified: nextest runs (cargo-nextest is not installed here), debugging under nextest, a tokio program, RustRover / Zed / VS Code (not run).

- Integration and hygiene, 2026-11-12 (branch `dev`, not pushed): `stylua --check .` is clean. **Fixed a regression of the UI shortlist**: `lua/plugins/ui-icons.lua` replaced the dashboard's responsive sections of `editing-ui.lua` with the stock three, so the entries and the footer were cut off at 80x24 again; the sections are back and the startup line's icon follows `:XynoIcons`. **Fixed a startup break of an earlier perf edit**: `island.lift` used `//`, which LuaJIT does not have, so `island-dark` failed to load (88 failing checks); it bisects with `math.floor` now, and `nvim-dap-virtual-text` is `lazy = true` (nvim-dap, mason-nvim-dap and mason were loaded at every start). `rust-ide-features` skips with a reason when the pinned xyno-rust.nvim lacks `run_configs` / `action_menu`. The 11 live-server checks of `server-supervision-statusline` were skipped as "bacon-ls not found" because Mason's bin directory is not on PATH in a spec; they find it now and pass. The lockfile-drift spec's message names the restore command. Re-measured: 43 spec files; 1104 passed, 1 failed (the drift), 46 skipped with the pinned plugins; 1131 / 1 / 32 with the plugin clones; the nine plugin suites pass (33, 107, 63, 158, 67, 283, 220, 339, 799). Benchmarks against the baseline: no regression ([docs/bench/final-2026-11.md](docs/bench/final-2026-11.md)). The README, `docs/TESTING.md`, `docs/DEV-PLUGINS.md`, `SECURITY.md` and the site say that only the AI agent is sandboxed and that the pinned sandbox plugin leaves the network open (its `dev` branch filters it). The bench harness README warns that a set `XDG_CONFIG_HOME` makes it measure that config instead of the checkout. Overview of the whole round and what is left: [docs/PROGRESS.md](docs/PROGRESS.md).

- Rust IDE features, 2026-11-12 (branch `dev`, not pushed; needs the xyno-rust.nvim `dev` commits `e85d9cb` and `00ce14e`, `lazy-lock.json` does not pin them yet; run with `XYNOVIM_DEV_PLUGINS`): run configurations saved per project (`:RustRun`, `<leader>rb` / `rB`: args, env, cargo command, profiler), the profiling profile defined on the command line instead of in `~/.cargo/config.toml`, code actions and refactorings with a diff preview (`<leader>ca`, `<leader>ra`), `:RustFixAll` (`<leader>rQ`), Problems panel filters (`e` / `w` / `S` / `a`, `<leader>xe`), opt-in organize imports on save (`vim.g.xynovim_organize_on_save`). Spec: `tests/rust-ide-features_spec.lua` plus the plugin's `run-configs_spec.lua` and `action-menu_spec.lua`. Status of every item in [docs/comparison/gaps-and-plan.md](docs/comparison/gaps-and-plan.md).

- UI round 2, 2026-11-12 (branch `dev`, not pushed): `island-light` (derived light variant, per-group contrast check), `:IslandContrast high` now covers every visible group (7:1, frames 4.5:1), rustc-style coloured diagnostic float `<leader>cD` (#13), error colour on tree names (#14), opt-in winbar breadcrumbs (#15), `:XynoIcons` rebuilds statusline / tabs / dashboard / file icons / dap-ui / code lens at run time and mini.icons now starts in ascii style, `WinBarNC` lifted to 4.5:1, bufferline tab counts floored at 4.5:1, plugin popup groups (`XynoHistory*`, `XynoMacrosDim`, `XynoGuard*`) defined by the theme after real panels measured below 4.5:1, dashboard tagline now says "Rust in Neovim, AI agent sandboxed" (only the agent is sandboxed). Tests: `tests/ui-community_spec.lua` (real popups need `XYNOVIM_DEV_PLUGINS`, otherwise they SKIP). Captures: `docs/comparison/screenshots/ui2/`. Assessment: `docs/comparison/ui-assessment.md`.

- UI shortlist, 2026-11-12 (branch `dev`, not pushed; items of [docs/comparison/ui-community.md](docs/comparison/ui-community.md)): per-kind inlay hints `:Hints` (#1), inlay hint text lifted from 3.2:1 to 6.0:1 on a darker chip (#3), cursor-line-first diagnostics with severity filter, width-aware `…` truncation and a typing debounce, `:DiagnosticsView` (#2, #10, #11), severity as shape (glyphs `✗ ▲ ● ◆`, curly / dashed / dotted / plain underlines; #4), `:checkhealth xynovim` terminal section (#5), `vim.g.xynovim_contrast = "high"` / `:IslandContrast` (#6), a spec for transparency and float borders (#7), narrow-window statusline priority collapse that keeps the file name (#8), `:XynoIcons ascii|nerd|auto` (#9), an xynovim dashboard header (#12), `Xyno*` highlight groups for the sandbox / history / guard / macros popups and statusline components for hints, sandbox, guard and history. New code: `lua/config/ui.lua`, `lua/xynovim/term.lua`, `lua/plugins/ui-icons.lua`; spec `ui-community` (55 checks, asserted on the real UI grid with WCAG ratios). Captures (tmux plus a Nerd Font renderer, and one real Ghostty X11 window) in `docs/comparison/screenshots/ui/`. Not done from the shortlist: #13, #14, #15, #16 (and no light variant: the shortlist has no item for one). Changes of behaviour: diagnostics outside the cursor line are compact by default (`vim.g.xynovim_diagnostics = "all"` restores the old view), signs are plain shapes instead of Nerd Font icons, `DiagnosticUnderlineWarn/Info/Hint` changed style.

- Restricted mode for untrusted Rust workspaces, 2026-11-12 (branch `dev`, not pushed; needs the xyno-rust.nvim `dev` commit with `lsp_status.add_part`, `lazy-lock.json` does not pin it yet): `lua/config/workspace_trust.lua`. In a workspace that is not in the `:RustTrust` list rust-analyzer starts with `procMacro.enable = false`, `cargo.buildScripts.enable = false`, `checkOnSave = false`, `cargo.loadOutDirsFromCheck = false` and cleared rustc wrappers, and bacon-ls (clippy) is not started; one prompt per workspace and session (trust / trust everything under the parent / run once / stay restricted), `RESTRICTED` in the status line, a `:checkhealth xynovim` section, rust-analyzer restarts with the full settings and bacon-ls starts when you trust (also from another Neovim instance), revoking restricts again. Trusted workspaces get the settings they always had. `vim.g.xynovim_workspace_trust = false` turns it off. `tests/workspace-trust_spec.lua` (14 specs, two with a real rust-analyzer and a canary `build.rs`). Spec hang fixed: `rust-context_spec` hung with the dev plugins because a stub of `vim.notify` saved LazyVim's 500 ms `lazy_notify` collector as the original and restored it, so the replay appended to the table it was iterating over for ever; `H.settle_notify()` (tests/helpers.lua) waits the window out first.

- Performance, 2026-11-12 (branch `dev`, not pushed; numbers in [docs/bench/perf-2026-11.md](docs/bench/perf-2026-11.md)): `lua/config/largefile.lua` sheds folds, treesitter indent, semantic tokens, inlay hints, code lens, spell, guides, illuminate, the breadcrumb and nested-language injections for buffers from 20 000 lines / 512 KB / 300-byte average lines (`:LargeFile`, `vim.g.xynovim_largefile`); a 40 013-line Rust file: stall after opening 617 -> 123 ms, edit 333 -> 24 ms. rust-analyzer starts with `MALLOC_ARENA_MAX=2` (idle RSS on the demo crate 825 -> 702 MB). `rustaceanvim` no longer depends on `nvim-dap` (the `dap` module is required with it, the plugin loads on VeryLazy): UIEnter with a .rs file -6 ms. bacon-ls `root_dir` uses `root_async` when xyno-rust.nvim has it (the pinned commit does not; no effect until the lock is bumped). `vim.g.xynovim_clippy_debounce_ms` (default 500). `scripts/bench`: `--type-gaps` typing metric, `BENCH_PRE` / `BENCH_EARLY` hooks, per-process RSS in the large probe. New spec `largefile`; `bacon-ls-config`, `rust-context` and `rust-analyzer-config` follow the asynchronous root and the dap change.

- Dev-plugin mode and spec hygiene, 2026-11-12 (branch `dev`, not pushed): `XYNOVIM_DEV_PLUGINS=<dir>` (or `scripts/dev-plugins.sh`) loads the `xyno-*` plugins from local clones instead of the commits in `lazy-lock.json` ([docs/DEV-PLUGINS.md](docs/DEV-PLUGINS.md)); the new `clipboard-e2e` spec drives real Neovim and tmux processes with fake `wl-copy`/`wl-paste` (OSC 52 fallback, one hint, tmux paste buffer); README section "Clipboard: tmux, SSH, Ghostty" with the Ghostty `clipboard-write` setting; the colourscheme-picker test runs in a child with a hard timeout; the `keymaps-global` key scanner no longer reads an rhs on its own line as a lhs; `bacon-ls-config` skips instead of failing without Mason's tree-sitter CLI; specs adapted to the plugin dev branches (workspace trust for the temp dir, async root/tools/doctests, the `cargo add` confirmation, the `env -i` bwrap command line, `$HOME` as an empty view). Counts: 949 passing, 48 skipped, 2 failing in 36 spec files.
- Supply chain, lint and known issues, 2026-11-12 (branch `dev`, not pushed): `ci.yml` downloads the exact Neovim v0.12.5 and checks its sha256 (it followed `stable` before), has a `lint` job (StyLua v2.6.0 and lua-language-server 3.19.2, both pinned by sha256; the Lua code is formatted with StyLua, `lua/plugins/ninety-nine.lua` excepted for now); `.github/dependabot.yml` (Actions, `demo/netwatch`); `SECURITY.md` (the sandbox is a seatbelt, not a jail); the Mason registry is pinned to a release tag (`lua/plugins/mason-pin.lua`); `docs/plugin-ci-templates/` has ready-to-copy lint and security files for the nine plugin repositories (not applied or pushed). Five entries of `docs/KNOWN_ISSUES.md` were worked on: a multi-file LSP edit is undone by one `u` (`lua/config/rename_undo.lua`), a panic stop selects the first non-runtime frame (`lua/config/dap_panic.lua`), the three naming lints of both diagnostic tiers show once, a quote after a backslash leaves no stray `"` (`lua/plugins/mini-pairs.lua`), crates.nvim's diagnostics are published once (`lua/plugins/crates.lua`); taplo next to crates.nvim stays (two different hovers). The lockfile spec failure of 10 plugins was drift of the local install (cloned at their newest commit on 2026-11-10 22:27, never checked out to the lock; the repo's lock did not change) and now says how to restore. macOS: `scripts/provision.lua` clears stale tree-sitter lock files before a parser retry round. Specs: `known-issues` and `supply-chain-lint` (new), the CI spec follows the new job. Counts (README, docs/TESTING.md): 34 spec files, 850 passing, 45 skipped, 3 failing because of the state of the machine of the run (details in the README).
- Sandbox policy preview and logged exceptions, 2026-11-12 (branch `dev`; needs the xyno-sandbox.nvim commit `3a93997` or later from `~/projects/xyno-plugins/xyno-sandbox.nvim`, not pushed, `lazy-lock.json` unchanged): `lua/plugins/xyno-sandbox.lua` now registers `:XynoSandboxStatus`, `:XynoSandboxPolicy`, `:XynoSandboxApprovals` and `:XynoSandboxRun` (lazy on those commands) and passes the two `vim.g` switches as functions (the old config proxy stays as a fallback for the pinned plugin); `plugins/ninety-nine.lua` shows the policy before the first request of each project, runs the confirmed plan, releases the sandbox handle when the request ends or is cancelled, and a cancelled preview completes the request as cancelled; lualine shows the sandbox state. New specs in `agent-99-guard` (they skip with a message while the pinned plugin has no preview). The README test counts were not re-measured.
- Own plugins, 2026-10-22 (branch `use-xyno-plugins`): xynovim now uses `xyno-history.nvim`, `xyno-sandbox.nvim` (v0.1.1), `xyno-clipboard.nvim` and `xyno-guard.nvim` instead of its local copies (`lua/config/{local_history,agent_sandbox,remote_clipboard,disk_guard}.lua` are gone; the specs are `lua/plugins/xyno-*.lua`, pinned by `lazy-lock.json`). Commands, keymaps (`<leader>gH`), the `refs/lochist/*` layout and the variables `vim.g.xynovim_lochist_max_bytes`, `vim.g.xynovim_lochist_max_total_bytes`, `vim.g.xynovim_99_sandbox`, `vim.g.xynovim_99_allow_unsandboxed` and `vim.g.xynovim_remote_clipboard_osc52` are honoured as before (mapped onto the plugins' options). Differences: the clipboard provider is now named `XynoClipboard` and starts when the plugin loads (still before the first yank) instead of from `options.lua`; the augroups are `xyno_history` and `xyno_guard`; the buffer variables `b:xynovim_disk_*` are `b:xyno_guard_*`; `:XynoSandbox*` and `:XynoClipboardStatus` are not registered (`commands = false`). Specs: the module specs that were ported to the plugin repositories are removed here (local-history 64 -> 11, agent-sandbox 59 -> 0, the clipboard describe of startup-and-options 8 -> 3, auto-save-disk-guard 52 -> 21), what xynovim promises on top stays; `:checkhealth xynovim` lists the four plugins.
- Own plugins, 2026-10-22 (branch `use-xyno-plugins`), `xyno-rust.nvim`: the Cargo context, targets, tools, routes, navigation, restart handling, statusline indicator, crate metadata and code-action helpers (`lua/config/{fsutil,rust_context,code_actions,crate_meta,lsp_status,rust_restart,rust_tasks,rust_routes,rust_nav}.lua`) are the plugin now (`lua/plugins/xyno-rust.lua`, not lazy, `keymaps = false`; the `<leader>r` keys stay in `config/keymaps.lua`). The local modules that still need them (crate add / features / import, import engine, macros, new-project helpers, lualine, the rustaceanvim and bacon-ls specs) require `xyno_rust.*` instead of `config.*`. No xynovim variable fed these modules. Differences: the augroups are `xyno_rust_lsp_status` and `xyno_rust_restart`, the buffer variable `b:xynovim_stopped` is `b:xyno_rust_stopped`, and the crates.io cache directory and user agent carry the plugin's name (`stdpath("cache")/xyno-rust/crates`; the old `xynovim/crates` cache is not read any more). Specs: the cases that were ported to the plugin repository are removed here (crate-meta 44 -> 0, rust-context 53 -> 9, rust-routes 27 -> 1, rust-tasks-tools 51 -> 15, server-supervision-statusline 57 -> 12, the rust_nav block of keymaps-rust 13 -> 2; the coverage cases and the live bacon-ls cases stay); `routes` stays as the small sample spec of the runner specs; `:checkhealth xynovim` lists five plugins.
- Own plugins, 2026-10-22 (branch `use-xyno-plugins`), `xyno-new.nvim`: `:RustNewBin`, `:RustNewLib`, `:RustNewWorkspace`, `:RustNewMember` and `:EguiNew` and the dashboard entries (`b`, `i`, `w`, `e`) are the plugin now (`lua/plugins/xyno-new.lua`; `lua/config/{rust_new,egui_new}.lua` and `lua/plugins/{rust-new,egui}.lua` are gone). The dashboard entries come from `require("xyno_new").dashboard_keys()` in the snacks spec, so the plugin is loaded at startup, as the two modules were (`cmd` is also listed). `vim.g.xynovim_projects_dir`, `vim.g.xynovim_egui_template` and `vim.g.xynovim_egui_build_after_new` are honoured, mapped onto the plugin's options when it loads at startup (set them in `options.lua` or with `--cmd`; unlike before, a value set later in a running session is ignored). Differences: the ETag cache of the egui ZIP is `stdpath("cache")/xyno-new` (the old `xynovim` one is not read, so the first `:EguiNew` downloads again), the notification ids and user agent carry the plugin's name, and the "next steps" hint names `:RustTargets` instead of `<leader>rX`. Specs: the module specs that were ported to the plugin repository are removed here (rust-new 55 -> 0, egui-new 66 -> 0); what xynovim promises on top is the new `xyno-new` spec (the glue, and the dashboard entries rendered in tmux at six sizes, moved from the two old specs); `:checkhealth xynovim` lists six plugins.
- Own plugins, 2026-10-22 (branch `use-xyno-plugins`), `xyno-imports.nvim`: auto-import, ranked choice with the per-project memory and organize imports (`lua/config/import_engine.lua`) are the plugin now (`lua/plugins/xyno-imports.lua`, loaded at `VeryLazy` as before, `keymaps = true`: `<leader>rI` and `<leader>rO`, buffer-local in Rust files). `config/crate_import.lua` and `config/macro_attrs.lua` (and the specs that use the engine) require `xyno_imports.engine`; the crates.io source of `crate_import` is registered on the engine right after the plugin's `setup()`. `vim.g.xynovim_auto_import` still decides the mode (read at every call, the plugin's own `vim.g.xyno_auto_import` wins when both are set) and the remembered choices stay in `stdpath("state")/xynovim/imports.json`. Differences: the autocommand group is `xyno_imports` and the namespace `xyno_imports`; a real map on `<leader>rI` / `<leader>rO` is no longer left alone (the old code skipped a key that was already mapped; the hidden which-key stubs never counted). Specs: the module spec that was ported to the plugin repository is removed here (import-engine 46 -> 0); the new `xyno-imports` spec holds the glue (9); `:checkhealth xynovim` lists seven plugins.
- Own plugins, 2026-10-22 (branch `use-xyno-plugins`), `xyno-crates.nvim`: `:CrateAdd`, the unknown-crate hint with "Add crate X", the missing-feature action with `:CrateFeatures` and the crates.io source of "Add crate X and import" (`lua/config/{crate_add,crate_features,crate_import}.lua`) are the plugin now (`lua/plugins/xyno-crates.lua`, loaded at `VeryLazy` like the old setup, `keymaps = true`: `<leader>rA` buffer-local in Rust and `Cargo.toml` files, `<leader>rG` in Rust files). `vim.g.xynovim_crate_check = false` still switches the hint off (copied to the plugin's `vim.g.xyno_crate_check` when the plugin loads, so it has to be set before `VeryLazy`). Differences: the in-process clients are `xyno-crates` and `xyno-features`, the diagnostic source `xyno-crates`, the autocommand groups `xyno-crates-add` and `xyno_crates_features`; the crate-feature module starts at `VeryLazy` and not at startup. Specs: the module specs that were ported to the plugin repository are removed here (crate-add 35 -> 0, crate-features 42 -> 0, crate-import 14 -> 0, the same cases are in the plugin's specs); the new `xyno-crates` spec holds the glue (7); the crate-import source test moved from `xyno-imports` to it; `macros-deps-flows` requires the plugin's modules; `:checkhealth xynovim` lists eight plugins.
- Own plugins, 2026-10-22 (branch `use-xyno-plugins`), `xyno-macros.nvim`: the completion inside helper attributes and derives, `:MacroAttrs`, `:MacroExpand`, `:MacroFormatFix`, `:MacroSignature`, `:ProcMacroStatus`, `<leader>rx`, `<leader>rq` and the insert mode `<C-k>` (`lua/config/{macro_attrs,macro_tools}.lua`) are the plugin now (`lua/plugins/xyno-macros.lua`, loaded at `VeryLazy`, `keymaps = true`, buffer-local as before). The two blink.cmp sources are registered by the plugin's `blink_opts()` with the same names, order and `score_offset`; blink.cmp keeps its version. The attribute schemas moved to the plugin (`data/` is gone from this repository, the README and the site link to the plugin's `data/macro_attrs`). Kept on top: the snippets still follow `config/ux.lua`'s `snippets_allowed()` (the plugin's own default guard has no expression-node check), and project schemas still come from `.xynovim/macro_attrs/*.json` (`attrs.user_dir`). Differences: the namespaces and the diagnostic source are `xyno_macros_hints` and `xyno-macros`, the autocommand group `xyno_macros`; `:MacroAttrs` and the attribute source exist once the plugin is loaded (at `VeryLazy` or when blink.cmp starts) and not from startup; `:ProcMacroStatus` shows a notice instead of an error when `:RustLsp` does not exist. Specs: the module specs that were ported to the plugin repository are removed here (macro-attrs 39 -> 0 and macro-tools 53 -> 0, the plugin has 40 and 58 for the same describes, 1 and 5 more); the new `xyno-macros` spec holds the glue (7); `macros-deps-flows` requires the plugin's modules; `:checkhealth xynovim` lists nine plugins.
- Counts, 2026-10-22, after `xyno-crates.nvim` and `xyno-macros.nvim` (and the earlier moves): 906 passing, 35 skipped, 0 failing in 32 spec files (README, docs/TESTING.md), the whole suite on my Linux machine in about six minutes. The figures of the entry below (1659 passing in 37 files) were not re-measured after `xyno-new` and `xyno-imports` took their module specs with them. The unused `lua/config/disk_guard.lua` (replaced by `xyno-guard.nvim` earlier) is removed; `lua/config` now holds `options`, `keymaps`, `autocmds`, `lazy`, `ux` and `rust_assist`.
- Counts, 2026-10-22, after the move to the xyno plugins: 1659 passing, 25 skipped, 0 failing in 37 spec files (README, docs/TESTING.md), the whole suite on my Linux machine (the earlier 38 files and 1805 passing included the module specs that now live in the plugin repositories). Startup: 7 of 68 plugins loaded, about 1 ms more than before (docs/DETAILS.md).
- Site, 2026-10-22: xyno-sandbox is now `v0.1.1` (home card, plugins page release link and JSON-LD version); the tag includes the CI fix that pins the Neovim download, with no functional change. The other eight plugins stay at `v0.1.0`.
- Plugins page, 2026-10-22: the nine published xyno plugins (history, sandbox, clipboard, guard, rust, new, imports, crates, macros; MIT, `v0.1.0`) are on the website: a Plugins section on the home page (nine cards, a dependency diagram, a copyable lazy.nvim snippet and the platform status of each) and `plugins/` (table, install order, one complete lazy.nvim spec for the Rust toolkit, a section per plugin, a FAQ, JSON-LD, share card `assets/og-plugins.png`). README has a Plugins section, `docs/DETAILS.md` a note. The wording is taken from the plugin READMEs: Linux tested, the sandbox and the clipboard provider Linux only, Windows and macOS not verified. The test figures were measured again with the whole suite on my Linux machine afterwards (1805 passing, 32 skipped, 0 failing, 38 spec files). Verified by `tests/site_spec.lua` (structure, JSON-LD, links, snippets are valid Lua and list their dependencies, wording); not verified: the plugin READMEs are not fetched by the spec, and xynovim still uses its own in-tree copies of the code.
- Counts, 2026-10-22: the test figures in the README and docs/TESTING.md (1795 passing, 31 skipped, 0 failing, 38 spec files) were measured by the whole suite on my Linux machine; the Ubuntu CI figures stay as they were.
- Voice, 2026-10-22: the README, the site and its guides, the docs, the tape comments, code comments and the launch-kit drafts now speak in the first person, as Xynorash ("my own colour-scheme export", "I still use JetBrains tools"), instead of "the author"; the historical entries below keep their facts and switch to "I" where the subject was me. Wording only: no behaviour, no data and no number changed. `tests/site_spec.lua` checks the new Acknowledgements wording and that no page or the README says "the author" in the third person.
- Website discoverability, 2026-10-22 (commits b989c1f, ca84675, 1578d94, 9808b95, 2a66abd, fd6f6b2, 09bc3ea): technical SEO (canonical and Open Graph URLs, JSON-LD, sitemap.xml, robots.txt), per-page share images (1200x630 PNG), six guides under `/guides/`, an IndexNow key file, and a README with clearer discoverability. No competitor keywords are targeted. Checked live after the push of 09bc3ea (pages run 39701795193, pages-build-deployment 39701821871): every page returns 200, the served HTML equals the local build, and the IndexNow ping to api.indexnow.org returned 202. CI on that commit passed (run 39701794138); the `platforms` run 39701794116 passed on Windows and failed on macOS, as documented in the README.
- Removed `tools/Dark.icls`: my scheme export is no longer distributed, only the palette generated from it (`lua/island/palette.lua`, same content). `tools/icls2nvim.py` stays as a converter for a scheme file you supply (without an input it prints a message and exits 1). The specs use a small synthetic `.icls` rebuilt from the palette.
- Acknowledgements, aligned with the positioning: JetBrains' products are thanked as the whole suite, RustRover named as the one IDE that inspired xynovim, I still use them, and xynovim is an independent personal project (no affiliation, no competition, no alternative). Text only.
- Positioning: xynovim is a personal project inspired by JetBrains' tools, which I still use; it is not a competitor to them. The pitch, page title, meta descriptions, history headings and code comments no longer read as a comparison or a race ("goes after", "closing the gap", "matches or beats", "poor man's", "clone"); the facts and the history stay as they were.
- Acknowledgements: README section and a website footer paragraph thanking JetBrains (RustRover as the inspiration, Island Dark derived from the Islands Dark scheme, no affiliation). Text only.
- Platforms, wording: README (Install, Platforms), the website (install section, limitations) and the repository description now say only what the `platforms` and `ci` runs show. Windows: run 39673715062 green (bootstrap.ps1, headless start, 1077 passed, 0 failed, 87 skipped; 10 of 38 spec files skipped whole), green in 3 of the last 4 runs (39660597368, 39663956677, 39673715062; 39668277143 failed on spec path assertions, fixed). macOS: not reliably green, green once (39663956677: 1431 passed, 0 failed, 73 skipped), red in 39660597368, 39668277143 and 39673715062 (a treesitter parser failed to compile during the plugin restore). Linux: `ci` run 39673715029, 1724 passed, 0 failed, 76 skipped. Still unverified: Local History, startup options, project creation and live rust-analyzer flows on Windows, codelldb on both, everything the 99 sandbox does off Linux (it refuses to start).
- Windows and macOS, last iteration of the first pass: `crate_meta.member_of` compares one path spelling (drive-letter case, slashes) so members are found on Windows; the specs that fail on `windows-latest` / `macos-latest` in run 39647013043 for causes not found yet skip with a printed reason (`H.known_issue`) and are listed in docs/KNOWN_ISSUES.md.
- Windows and macOS (in progress, nothing here is claimed as working until a `platforms` run shows it, see the run ids below when they exist). Code: PATH separator and `CARGO_HOME` in `options.lua`; bacon-ls accepts drive-letter roots; `disk_guard` compares normalized, case-folded paths; `.exe` for the debugger binary and the profiling run; `rust_restart` strips `.exe` and skips SIGCONT on Windows; `remote_clipboard` is Linux only; EguiNew unpacks with `tar` when `unzip` is missing on Windows; the manifest writers read and write binary (CRLF kept); `fsutil.rename` retries on Windows; `rust_context` canonicalizes roots; `health` skips unzip/gzip/mold/clang/bwrap on Windows and accepts any C compiler; lazy bootstrap does not wait for a key without a UI. Scripts: `scripts/bootstrap.ps1`, `scripts/test.lua` (`nvim --clean -l`, the runner of `test.sh` without bash) and `scripts/test.ps1`. Tests: `-- xyno-os:` header and `H.need_os` / `H.need_posix` skips with a printed reason, portable fixture copy, specs `agent-failclosed` and `scripts-portable`. CI: `.github/workflows/platforms.yml` (windows-latest, macos-latest; Neovim v0.12.5 pinned by URL and sha256).

- The 99 provider picker (`<leader>9P`) could swap in a stock provider (OpenCode, Cursor, Kiro, Gemini) that runs its CLI with no sandbox, checkpoint or auto-save guard. `_99.set_provider` and the picker now refuse anything but the guarded provider unless `vim.g.xynovim_99_sandbox = false` or `vim.g.xynovim_99_allow_unsandboxed = true`. `provision.lua` retries Mason packages whose install was aborted (codelldb failed the `ci` run 39635190559). The undiagnosed macOS/Windows skips and the whole-file macOS skips are listed in docs/TESTING.md.
- Agent sandbox fails closed. Without a working sandbox backend (Windows, macOS, Linux without `bwrap`) `agent_sandbox.wrap` returned the command unchanged, so `claude --dangerously-skip-permissions` ran with the user's full privileges and no message. Now `agent_sandbox.status()` gives `bwrap` / `unsandboxed` / `refused`, `wrap()` returns `nil, reason` when refused, and `Guarded.make_request` refuses before the snapshot, the auto-save toggle and the spawn (error notification, `on_complete("failed")`). `vim.g.xynovim_99_sandbox = false` stays the deliberate off switch, the new `vim.g.xynovim_99_allow_unsandboxed = true` permits an unsandboxed run only when there is no backend; only booleans count; every unsandboxed request warns. The module no longer needs a uid at load (`os_get_passwd` may fail off Linux). Specs `agent-sandbox` and `agent-99-guard` cover the matrix (the no-backend case runs on Linux by stripping PATH and by stubbing `has("linux")`); README, DETAILS, KNOWN_ISSUES and the site say Linux-only. Known: the other 99 providers (`<leader>9P`) are not wrapped.

- Website: deployed on 2026-10-16. The `gh-pages` branch (one orphan commit `dc7f645`, built from `23a5114` by `pages.yml` run 38891227340) holds only the built site; GitHub Pages was enabled from `gh-pages` / root (legacy branch build, `pages-build-deployment` run 38893239214) and serves https://xynorash.github.io/xynovim/, which is also the repository's website field.
- Website: the official site of the project, https://xynorash.github.io/xynovim/ (`site/`: one static page, no external requests, system fonts, dark Island Dark palette and a deliberate light one, reduced motion respected, CSS-only mobile menu, JavaScript only for copy buttons, the active nav link and playing recordings while they are visible). `scripts/build-site.py` assembles `_site/` (the site plus only the media it references from `docs/media/`, the numbers taken from the README so they cannot drift, `--check` verifies links and anchors). `.github/workflows/pages.yml` publishes it on pushes to `main` that touch the site as one orphan commit to the dedicated `gh-pages` branch (plain git, no third-party action, `contents: write` only in that job, a forced push to that one branch only). Spec `site`; README and `docs/DETAILS.md` describe it, the README layout block lists `site/`.

- README: recording of the new Rust project flows (`docs/media/record.sh 15-rust-new`: the dashboard, the workspace flow with the generated tree and manifests, a binary), 13 screenshots, a GIF (1.6 MB) and an MP4; the tape uses a temp parent directory (`support/rustnew.sh`), which `record.sh` removes.
- New Rust projects: three dashboard entries, **New Rust Binary** (`b`), **New Rust Library** (`i`) and **New Rust Workspace** (`w`), and the commands `:RustNewBin [name]`, `:RustNewLib [name]`, `:RustNewWorkspace [name]` and `:RustNewMember [name]` (`config/rust_new.lua`, `plugins/rust-new.lua`). A binary or library is `cargo new --vcs git` in a chosen parent directory (prompts as in the egui flow: name, parent with confirm-to-create; existing target refused; cancel is silent). The workspace is built here: a root `Cargo.toml` with `members = ["crates/*"]`, `[workspace.package]` (version and the edition the installed cargo uses, read from a throwaway `cargo new`) and an empty `[workspace.dependencies]`, resolver 3 for edition 2024 and newer else 2, `.gitignore`, a first member whose version and edition inherit, `git init -b main`. `:RustNewMember` adds a member to the workspace of the current buffer (glob or explicit list, layout kept). Failures show cargo's first stderr line and leave nothing behind. Spec `rust-new`.
- Dashboard: with 14 entries the layouts were too short. The thresholds now follow the number of entries (tall `2n + 11` rows, header `n + 12`, no header below), so every entry and key is visible at 80x24, 100x30 and 190x50 (and down to 80x18). `config/egui_new.lua` exports `cargo_name`, `ask`, `default_parent`, `run_async` and `sys` for the new flows; the egui flow itself is unchanged.

- egui: `:EguiNew` no longer enforces a Rust toolchain. The template's `rust-toolchain` pin (channel `1.95.0`) made rustup install exactly that toolchain, so it is now always deleted from the generated project; the `rust-version` field of `Cargo.toml` (the minimum, `1.95`) is kept as is. At the end of the flow `rustc --version` (run in the new project) is compared with it and an older Rust gets one warning (`this project needs Rust >= 1.95 (you have 1.94.1): run rustup update stable`); nothing is installed or downloaded, a missing or unreadable `rustc` is only mentioned.
- egui: removed what existed only to cope with the pin: `prepare_toolchain`, the pin parser and install plan, the rustup runner, the in-flight guard, the `VimLeavePre` killer, the "preparing toolchain" notifications and the options `vim.g.xynovim_egui_prepare_toolchain` and `vim.g.xynovim_egui_keep_toolchain_pin` (the file is simply always removed). The generated README has no Toolchain section any more. The entries below about the toolchain preparation are history.

### Added (egui projects)
- `config/egui_new.lua`, `plugins/egui.lua`: a "New egui Project" entry (`e`) on the dashboard and `:EguiNew [name]`. It downloads the current `emilk/eframe_template` ZIP (never a stored copy; ETag cache, cached copy with a warning offline), asks for the project name, author name and e-mail (prefilled from git) and the parent directory (`vim.g.xynovim_projects_dir`), and personalises the template like its README and `fill_template.sh` do: crate name in `Cargo.toml`, `Cargo.lock`, `src/main.rs`, `assets/sw.js` (links to the template are kept), page / window title, authors, a generated README, `git init -b main`. Options `vim.g.xynovim_egui_template`, `xynovim_egui_keep_toolchain_pin`, `xynovim_egui_build_after_new`. Spec `egui-new`. README section "New egui project".
- `:EguiNew` prepares the pinned toolchain: the template's `rust-toolchain` made rustup install 1.95.0 without the `rust-analyzer` component, so the new project had no LSP. After creating it, in the background and after a notification (about 200 MB, once), it runs `rustup toolchain install <channel> --profile minimal --component rust-analyzer --component clippy --component rustfmt` plus the file's targets, then restarts the Rust servers; offline or without rustup it warns once with the command. Option `vim.g.xynovim_egui_prepare_toolchain` (default `true`); `xynovim_egui_keep_toolchain_pin = false` still drops the pin. Specs in `egui-new` (pin parser, argv, failure paths).

### Added (macros and dependencies)
- Dependency freshness: saving `Cargo.toml` / `Cargo.lock` from nvim restarts bacon-ls 500 ms after the last save (it kept a stale `cannot find crate` error for minutes) and the statusline shows `deps resolving` until rust-analyzer has reloaded (6 s when it never went busy, 120 s ceiling). `config/rust_restart.lua`, `config/lsp_status.lua`.
- `config/crate_meta.lua` (cached `cargo metadata`, registry sources, a small crates.io client with sparse index and search, all argv lists, names validated) and `config/code_actions.lua` (find and apply one rust-analyzer code action without a menu).
- `config/crate_add.lua`: a hint on a path whose first segment is no dependency with the action "Add crate `x`", `:CrateAdd [query]` / `<leader>rA` (crates.io search with features and their descriptions, target package / `--dev` / `--build`, then `cargo add` and the import that triggered it).
- `config/crate_features.lua`: the action "Enable feature `derive` of `serde`" / `<leader>rG` for `cannot find derive macro / attribute / macro / function X`, found from the crate's own source and `[features]`; `:CrateFeatures [crate]` feature explorer with toggling.
- `config/import_engine.lua`: `vim.g.xynovim_auto_import` (`ask` default, `single`, `off`), ranked disambiguation with reasons and a per-project memory (`:ImportName` / `<leader>rI`, `:ImportForget`), `:ImportOrganize` / `<leader>rO`, import on paste. New: `register_source(fn, {async = true})` and `resolve(..., {sources = false})`.
- `config/crate_import.lua` (new): import from crates that are not dependencies yet (exact crate name from the sparse index, other names as "(guess)" from a crates.io search, top 3 by downloads), "add crate and import" waits up to 60 s for rust-analyzer; crate-add's "Add crate" action uses the same path. Accepting a derive from `#[derive(` completion imports it through the import engine.
- `config/macro_attrs.lua` and `data/macro_attrs/*.json`: completion inside `#[serde(`, `#[arg(`, `#[command(`, `#[error(`, `#[tokio::main(` and `#[derive(` from per-crate schemas (serde, clap, thiserror, tokio, strum, derive_more, sqlx, utoipa, schemars, bon), project overrides in `.xynovim/macro_attrs/`, learn-from-usage for crates without a schema, `:MacroAttrs`.
- `config/macro_tools.lua`: macro call help (`<C-k>`, `:MacroSignature`, format-string and `sqlx::query!` hints, `:MacroFormatFix`), `:MacroExpand` / `<leader>rx` lens, `:ProcMacroStatus` / `<leader>rq`.
- Specs: `crate-meta`, `deps-freshness`, `crate-add`, `crate-features`, `import-engine`, `crate-import`, `macro-attrs`, `macro-tools`, `macros-deps-flows` (four cross-module flows on temp copies of the fixtures, real `cargo`, crates.io and rust-analyzer; skip with a message without them), fixture `tests/fixtures/no-deps-lab`. README section "Macros and dependencies".

### Fixed (macros and dependencies, review)
- `cargo add` / feature edits done from nvim (`:CrateAdd`, the add-crate and missing-feature code actions, `:CrateFeatures`) now restart bacon-ls and show `deps resolving` like a saved `Cargo.toml` (stale E0433 / `cannot find derive macro` errors stayed).
- Auto-import 'ask' is a yes/no dialog that stays until answered (the echo prompt vanished after 3 s while keys were swallowed), keeps a yes given while typing, and never blocks a headless nvim (it hung `macro-attrs_spec`). `:ImportName` keeps the ranked order behind a remembered choice.
- `:MacroExpand` on a literal or name inside a call's arguments expands that call; `:ProcMacroStatus` no longer says 0 crates above a non-empty list; `rust-analyzer.toml` edits accept a commented header, replace multi-line arrays whole, and are written atomically.
- Cargo.toml feature edits skip comments, keep single-quoted features and write through a symlinked manifest; file reads of dependency sources and schemas are bounded (regular files, 2 MB / 1 MB / 400 KB); the `:CrateFeatures` dependency picker has no broken preview; `[cached, offline?]` only for stale results.

### Fixed (macros and dependencies, field test)
- The unknown-crate hint no longer fires in a file with a glob import from a dependency (`use predicates::prelude::*` brings the `predicate` module: a false "crate 'predicate' is not a dependency" on every open of `tests/cli.rs`). `crate_add.scan` and the import engine's `scan_syntax` skip buffers above 20000 lines (`config.max_lines`): both read or walk the whole buffer per edit, 0.4 s each in a 45000-line file.
- The in-process LSP clients (`xynovim-crates`, the feature fixer) report `on_exit` once from `terminate` / `exit`; they stayed in `vim.lsp.get_clients()` as stopped entries, two more per restart.
- cargo-machete and cargo-deny findings on dotted or quoted dependency keys (`itoa.workspace = true`, `"time".workspace = true`) land on their own line, not line 1.
- Media: the recordings commit added screenshots, GIFs and MP4s beyond the counts of the showcase entry below (now 77 PNG, 15 GIF, 15 MP4 in `docs/media/`, with the recording of the new Rust project flows, tape `15-rust-new`).
- Test counts in README and `docs/TESTING.md` agree with the suite.

### Changed (macros and dependencies)
- CI job timeout 15 to 40 minutes: the suite now has 33 spec files (about 12 minutes on a runner after a 3 minute bootstrap) and the first run of this work was cancelled at 15. The import engine's Lua fallback for the `use` index (no ripgrep, as on the runner) never descended into directories (`vim.fs.dir`'s `skip` returns false to stop, the predicate was inverted); fixed, found by the CI run.
- `.gitignore` ships `data/macro_attrs/` (it ignored `data/`). The README layout block lists `data/` (17 entries).
- `<leader>rA rG rI rO rx rq` are buffer-local (Rust buffers, `rA` also `Cargo.toml`): the global `<leader>r` keys are hidden stubs. `crate_add` and `macro_tools` start from `User VeryLazy` autocmds, not virtual lazy specs (the plugin count stays 61).
- Derive acceptance in `macro_attrs` resolves through the import engine (`derive = true, sources = false`): the remembered or only candidate, otherwise the one from the derive's own crate.
- Verified: whole suite and the cross-module flows (see TESTING for the counts), headless startup median 26.03 ms (24.0 to 25.2 ms before), 4 of 61 plugins at startup. Not verified: pickers and key presses in a real terminal, the `ask` prompt, the live 120 s ceiling, `stylua --check` (drift in 61 files, not reformatted). Known limits: guesses match by crate name only, `#[serde(` keys appear while `derive` is off, `Import X` and `Import X as Y` count as one candidate.

### Added
- Assessment and plan for the next phase, "macros and dependencies": measured what rust-analyzer and this config do with derive and attribute macros, new dependencies, missing crate features and ambiguous imports (seven gaps), and a four-phase plan with acceptance criteria. `docs/PLAN_MACROS_DEPS.md`, the probe scripts in `docs/assessment/` (implemented below; the plan page now carries a status table).
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
- Theme: Island Dark (my own "Dark" scheme, parent Darcula) is now
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
- README: added a "Roadmap" section with the 11-step, ordered plan from the
  my wish list of features missed from the JetBrains workflow (researched
  while using RustRover 2026.2)
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
- **Live-as-you-type Rust diagnostics via bacon-ls** — the always-on
  inspections known from the JetBrains IDEs. `vim.g.lazyvim_rust_diagnostics = "bacon-ls"` in
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
- **Colorscheme: `rose-pine` → `islands-dark`, ported directly from my real
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
  plugin at all — the "mode name at the bottom" I was seeing was Neovim's own
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
  `lsp.lua` for continuous feedback while actively typing. Confirmed
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
  unmaintained since 2024-05) for background auto-save, as in the JetBrains IDEs. Configured with
  `noautocmd = true` so debounced autosaves don't also trigger format-on-save; only a
  manual `:w`/`<leader>f` formats. Verified: an intentionally mis-formatted file survives
  an autosave untouched, then reformats correctly on manual save.
- Inline diagnostics styling: virtual text with gutter sign icons (``/``/``/``),
  underline, severity-sorted — same idea as the inline error-message style of the JetBrains IDEs.
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
