# xynovim (formerly xyno-neovim)

Personal Neovim config, built on [LazyVim](https://github.com/LazyVim/LazyVim), running on Linux (Omarchy/Arch). The previous from-scratch Windows config lives on the [`windows-legacy`](../../tree/windows-legacy) branch.

Every notable change is documented in [CHANGELOG.md](CHANGELOG.md), including what was verified and how.

## What's here beyond stock LazyVim

### Rust

- **LazyVim `lang.rust` extra**: rustaceanvim + rust-analyzer, crates.nvim for Cargo.toml, codelldb for debugging, neotest adapter.
- **Two-tier diagnostics** for instant feedback with clippy depth:
  - *Instant tier (~0.15–0.25s measured, warm)*: rust-analyzer's native in-memory diagnostics — type errors, unresolved names, as you type, no cargo run involved.
  - *Depth tier (~0.56s median, warm)*: clippy via [bacon-ls](https://github.com/crisidev/bacon-ls)'s native cargo backend (`lua/plugins/bacon-ls.lua`) with `updateOnInsert` — it mirrors the workspace into a hardlinked shadow under `target/bacon-ls-live/` and re-runs clippy (`--workspace --all-features --no-deps`, 500ms debounce) on every buffer change, before any save. `checkOnSave` is deliberately **off**: with ~1s auto-save it was a second cargo pipeline racing the live one — runs cancelled each other and serialized on cargo's build-dir lock (measured 5.6s edit-to-diagnostic with both pipelines vs single-pipeline sub-second). `updateOnInsert` must stay **on**: without it bacon-ls advertises no document sync and diagnostics never refresh.
  - The only overlap is visual: a type error can briefly show from both sources.
- **bacon-ls fixes are upstream** (Mason's bacon-ls >= 0.31.0; the earlier local patched build and its `cmd` override are gone). The three fixes behind the previous patch landed as [crisidev/bacon-ls#139](https://github.com/crisidev/bacon-ls/pull/139): (1) the debounce task drops its own handle once its sleep is over, so a later `abort()` can only cancel a still-sleeping trigger and in-flight runs are superseded via `CancelRunning` (progress tokens close properly); (2) with `checkOnSave` off, `didSave` no longer cancels a still-pending live trigger; (3) closing a dirty buffer clears its orphaned diagnostics and restores the shadow file by *copy* (fresh mtime), so cargo re-checks instead of replaying cached warnings.
- **rustaceanvim tuning** (`lua/plugins/rustaceanvim.lua`): inlay hints (closure return types, elided lifetimes), fill-arguments completion snippets, full function signatures, module-grouped auto-imports, and `cargo.targetDir = true` so rust-analyzer's build-script runs never contend for the build-dir lock with terminal `cargo run`/`cargo test`.
- **System-level build speed** (`~/.cargo/config.toml`, outside this repo): mold linker via clang (links several times faster — every clippy/test/run cycle benefits) and `profile.dev.debug = "line-tables-only"` (backtraces kept, debuginfo cost dropped; set full debug per-project when using the debugger).

Requires: `rust-analyzer` on PATH; `bacon-ls` >= 0.31.0 from Mason (`:Mason`); `mold` + `clang` (pacman). The `bacon` binary is **not** needed by the cargo backend (it runs cargo/clippy directly); it's only used by the unused `backend = "bacon"` fallback in `~/.config/bacon/prefs.toml`.

### 99 (AI assistant)

[ThePrimeagen/99](https://github.com/ThePrimeagen/99) on the Claude Code provider (`lua/plugins/ninety-nine.lua`), model `claude-sonnet-5` with `--effort medium`.

Hard-won configuration notes:

- `tmp_dir` **must be an absolute path** (here: `~/.cache/nvim/99`). 99 resolves a relative tmp_dir against nvim's cwd, but claude resolves the same relative TEMP_FILE against the project it's working in — launch nvim from outside the project and every response comes back empty because the answer lands where 99 never reads.
- The logger needs `type = "file"` for `path` to take effect; the plugin README's example omits it and logs silently go nowhere. Logs land at `/tmp/<dirname>.99.debug`.
- The blink completion source (`#rules` / `@files` in the prompt buffer) needs `saghen/blink.compat`.

| Keymap | Action |
| --- | --- |
| `<leader>9s` | Search (results → quickfix) |
| `<leader>9v` / `<leader>9vv` (visual) | Vibe / replace selection |
| `<leader>9o` | Open last interaction |
| `<leader>9l` | View logs |
| `<leader>9c` / `<leader>9x` | Clear previous / stop all requests |
| `<leader>9w` / `<leader>9W` | Worker search / set work |
| `<leader>9m` / `<leader>9P` | Select model / provider (telescope) |

### Editor behavior

- **auto-save** (`lua/plugins/auto-save.lua`): okuuva/auto-save.nvim, ~1s debounce including while typing (`TextChangedI`). Autosaves skip format-on-save via `noautocmd`; a `User AutoSaveWritePost` hook re-sends `textDocument/didSave` so LSP save-triggered behavior survives. Manual `:w` still formats.
- **harpoon**, and Omarchy desktop integration: live theme hot-reload, transparency (re-applied on every `ColorScheme` change), remote clipboard (OSC52, activates only under tmux/SSH/herdr).
- Format-on-save off globally (`vim.g.autoformat = false`), relative numbers off.

### Performance choices

- ~18ms startup (from 29ms): 99 + telescope + blink.compat and harpoon lazy-load on their keymaps; the herdr `/proc` ancestry walk short-circuits behind env checks.
- lazy.nvim's periodic update checker is **off** (it re-fetched all plugin repos in the background and dragged `lazy.manage` into every startup) — update with `:Lazy sync`.
- Remote-plugin providers (python3/ruby/perl/node) disabled — nothing uses them.
- 99's request cache (`~/.cache/nvim/99`) is pruned of week-old files on load.

## Roadmap: closing the gap with RustRover

Result of a gap analysis against RustRover 2026.2 (researched 2026-10-08: 15 dimensions, each adversarially verified). xynovim already matches or beats RustRover on diagnostics latency, startup/footprint, raw rust-analyzer access and scriptability; the gaps below are mostly **tooling that is installed but inert** or unbound. Steps are in recommended order; each is verifiable (`:checkhealth`, a headless `nvim --headless` smoke run, or one real crate). Items marked *(unverified)* come from research that was not tested on this machine; test them before building on them.

### 1. Reality check: done 2026-10-09
Findings on this machine and what was done:
- `~/.cargo/bin/bacon-ls` and `~/.local/src/bacon-ls-upstream` did not exist, so the `cmd` override pointed at nothing and the clippy tier was dead. #139 is merged (2026-09-10) and shipped in 0.31.0 (2026-09-20); Mason has 0.31.0 (0.32.0 is the latest upstream). **Fixed:** removed the override in `lua/plugins/bacon-ls.lua`. Verified headless on a scratch crate: `bacon_ls` attaches with Mason's binary and publishes diagnostics.
- `~/.cargo/config.toml` was missing and `mold` was not installed. **Fixed:** installed `mold` 3.0.0 and created the config (clang + mold linker, `profile.dev.debug = "line-tables-only"`). Verified: a fresh crate links with mold (`.comment` section shows it).
- Toolchain: only `stable` (rustc 1.99.0) is installed, so nightly-only tooling (`cargo miri`, `-Z` flags) needs `rustup toolchain install nightly`.
- Not installed (needed by later steps): `lazygit`, `git-delta`, `difftastic`, `perf` (all in pacman `extra`), `cargo-nextest`, `rr` (not in the pacman repos). `cargo-audit`, `cargo-watch` and Mason's `codelldb` are present.
- Unrelated config finding: nvim logs `Too many rounds of missing plugins` because `monokai-pro.nvim` is cloned from `gthelding/monokai-pro.nvim`, which 404s, and a missing `lua/plugins/theme.lua` is reported (see step 11 hygiene).

### 2. Extras and packages: done 2026-10-09
- LazyVim extras: `dap.core` (debugger front end: breakpoints, stepping, dap-ui; codelldb is already in Mason), `test.core` (neotest with rustaceanvim's adapter), `editor.overseer` (task runner), `lang.toml` / `lang.yaml` / `lang.json` / `lang.markdown` / `lang.git` (taplo for `Cargo.toml`, yamlls + SchemaStore for CI workflows). Verify names in `:LazyExtras`.
- Enable LazyVim codelens (`opts.codelens.enabled = true`) for run/debug lenses.
- `pacman -S lazygit git-delta difftastic`; `cargo install cargo-nextest` (rustaceanvim detects it at config load, so restart nvim).
- Known interactions: auto-save uses `noautocmd`, so neotest's watch mode (`<leader>tw`) must be hooked to `User AutoSaveWritePost`; nextest cannot run doctests (keep `cargo test --doc`); in Rust buffers `<leader>dr` (debuggables) shadows the REPL toggle.
- **Done:** all extras above enabled in `lazyvim.json`, codelens enabled (`lua/plugins/codelens.lua`), `lazygit` / `git-delta` / `difftastic` installed via pacman, `cargo-nextest` 0.9.148 via cargo. Verified headless on a scratch crate: `<leader>db/dc` (dap), `<leader>tt/tr/to` (neotest), `<leader>cc` (codelens), `<leader>dr` (debuggables), `<leader>gg` (lazygit) are all mapped and the dap/neotest/overseer modules load. A real interactive debug session and test run are still untested.
- `<leader>tw` (neotest watch) rides on `BufWritePost`, which auto-save's `noautocmd` writes skip; use manual `:w` while watching.

### 3. rust-analyzer command keymaps: done 2026-10-09
`lua/config/keymaps.lua` binds the previously unbound rustaceanvim commands, buffer-local on rust-analyzer attach (scheduled so they also win over the `lang.rust` extra's own maps), under a which-key group `<leader>r` "rust":
- Refactor: `ra` refactor actions, `rv` extract variable, `rf` extract function, `rc` extract constant, `rM` extract module, `ri` inline (assists applied by title, no menu), `rs` structural search & replace (also visual), `rj` semantic join lines (also visual), `<A-j>` / `<A-k>` move item down/up.
- Inspect: `rm` expand macro, `rh` / `rH` view HIR / MIR, `rS` syntax tree, `rp` parent module, `rt` related tests, `rC` open Cargo.toml, `rd` docs.rs, `rE` external docs, visual `rk` hover range.
- Diagnostics: `re` explain error, `rD` render diagnostic, `rr` related diagnostics (these only work on rust-analyzer diagnostics, not bacon-ls/clippy).
- Symbols: `rw` workspace symbol, `rW` workspace + dependencies, all kinds (RustRover's "include non-project items").
- Server: `rR` reload workspace, `rP` rebuild proc macros.
- `<leader>cR` is restored to LazyVim's Snacks file rename in Rust buffers (the extra had shadowed it with code actions; use `<leader>ca`).
Verified headless: all maps present and buffer-local; `<leader>rv` on `1 + 2` produced `let var_name = 1 + 2 + 3;`; `:RustLsp view hir` opens. Not exercised: the other assists, `rW` interactively, move item.

### 4. rust-analyzer settings pass: done 2026-10-09
In `lua/plugins/rustaceanvim.lua` (all keys checked against `rust-analyzer --print-config-schema` of the installed 1.99.0 binary):
- `references.excludeImports` and `references.excludeTests` on, so `gr` / call hierarchy skip `use` lines and test code. `<leader>rT` flips tests back in live (`workspace/didChangeConfiguration` answered from `client.settings`). Verified: a fn used in `main`, an import and a test returned 2 references (decl + `main` call), 3 after the toggle (test included; the import stays excluded).
- Resource budget for this 16-core / 15 GiB machine: `numThreads = 8`, `cachePriming.numThreads = 4`. `procMacro.attributes.enable` deliberately left on (off breaks `tokio::main` / axum). `fs.inotify.max_user_watches` is already 524288, so no change. Not set: `check.workspace` (flycheck is off anyway), `lru.capacity` (default 128 until memory is actually a problem).
- `completion.termSearch.enable = true`.
- Custom postfix snippets: `.ok/.err/.some/.arc/.rc/.pinbox` plus new `.refcell`, `.mutex`, `.arcmutex`. The setting replaces rust-analyzer's default map rather than merging, so the defaults are repeated in the config. Config accepted by the server; snippet expansion itself not tried interactively.
- Skipped on purpose: the optional `systemd-run` memory cap and `ra-multiplex` (see "Optional / revisit" below) until memory pressure shows up.

### 5. Safety net: done 2026-10-09
RustRover's Local History covers deleted files, `reset --hard` and AI edits; xynovim had only `undofile`, and `99` runs `claude --dangerously-skip-permissions` on top of 1s auto-save. Now:
- **Local history** (`lua/config/local_history.lua`): every save (auto-save's `User AutoSaveWritePost` and manual `BufWritePost`, throttled to once a minute per repo) snapshots the whole worktree, untracked files included, as a commit on `refs/lochist/<branch>`. It uses a private index (`.git/lochist-index`), so the real index, stash and branches are untouched; `.gitignore` is respected and `target/` is always excluded (via an extra excludes file, because a pathspec exclude makes `git add` fail when `target/` is already ignored). Unchanged trees are skipped. `:LocalHistory` / `<leader>gH` lists snapshots of the current file and opens a diff against the chosen one. Restore a whole snapshot with `git checkout refs/lochist/<branch> -- <path>`. Verified headless: untracked file captured and recoverable after deletion, `target/` excluded, no-change run creates nothing, real `git status` unchanged. Known limit: snapshots accumulate (no pruning yet); `git update-ref -d refs/lochist/<branch>` resets a branch's history.
- **Undotree**: `<leader>uu` opens Neovim 0.12's built-in `nvim.undotree`.
- **`99` guard** (`lua/plugins/ninety-nine.lua`): a wrapper around the Claude provider takes a forced snapshot ("before 99 request") before every request, turns auto-save off while any request is in flight (so the agent's edits can be reviewed/undone before they hit disk; restored when the last request finishes), and runs claude inside **bubblewrap** (`lua/config/agent_sandbox.lua`): filesystem read-only except the project root, 99's tmp dir, claude's own state and cargo's registry/git caches; `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gh` and similar are hidden; network stays open; if nvim was started in `$HOME` or `/`, the project is not made writable. Opt out with `vim.g.xynovim_99_sandbox = false`. Verified: writes to the project succeed, writes to `$HOME` and `~/.config` fail with "Read-only file system", the network works, `claude --version` runs inside the sandbox, and the guarded provider builds the expected `bwrap ... claude` command. **Not verified:** a real `99` request end to end (a live `claude --dangerously-skip-permissions` run was blocked in this session). Try `<leader>9v` once; if claude complains about a path, add it to `WRITABLE` in `agent_sandbox.lua`.
- 99's log moved from `/tmp/<dir>.99.debug` to `~/.local/state/nvim/99.log` at INFO level (flip `level` back to `_99.DEBUG` in `ninety-nine.lua` when debugging).
- Deliberately not done: gating auto-save on ERROR diagnostics (it would stall `didSave` and bacon-ls); snapper on btrfs `/home` as an extra OS-level layer is optional and not configured.

### 6. Git depth: done 2026-10-09
- **diffview.nvim** (`lua/plugins/diffview.lua`): `<leader>gv` working tree / merge conflicts (3-way), `<leader>gV` branch vs `origin/HEAD`, `<leader>gF` file history (visual: selection history), `<leader>gq` close. Verified it opens a file panel tab on a scratch repo; the conflict resolution flow itself was not exercised by hand.
- **mergiraf** (pacman) as a syntax-aware merge driver for `*.rs` (registered in global git config, attributes in `~/.config/git/attributes`). Verified: two branches adding different `use` lines at the same spot merged cleanly into a sorted-by-intent result with no conflict markers. `Cargo.lock` conflicts are not handled (a regenerate-on-conflict driver was only a sketch; untested).
- Global git config (user `xynorash`, `~/.gitconfig`): `merge.conflictstyle = zdiff3`, `rerere.enabled` + `rerere.autoUpdate`, `rebase.autoSquash`, `rebase.updateRefs`; aliases `git dft` / `git dlog` (difftastic, structural diff that ignores rustfmt-only churn; deliberately an alias, not a global `diff.external`, so lazygit/gitsigns keep parsing plain diffs).
- lazygit uses `delta` as its pager (`~/.config/lazygit/config.yml`, only created because none existed).
- `git-absorb` and `gitleaks` installed (pacman). Use `git absorb --and-rebase` to fold fixups into the right earlier commits.
- **Per-repo opt-ins, not applied automatically:**
  - Ignore formatter-only commits in blame: list the commit hashes in `.git-blame-ignore-revs` and run `git config blame.ignoreRevsFile .git-blame-ignore-revs` (gitsigns blame honours it).
  - Pre-commit hooks (lefthook is not in the official Arch repos: install it with `go install github.com/evilmartians/lefthook@latest`, or use a plain `.githooks/pre-commit` script). Example `lefthook.yml`; keep a separate `CARGO_TARGET_DIR` so hooks never contend with the editor's builds, and never make hooks depend on a running LSP:
    ```yaml
    pre-commit:
      parallel: true
      commands:
        fmt:      { glob: "*.rs", run: "cargo fmt --check" }
        clippy:   { glob: "*.rs", run: "CARGO_TARGET_DIR=target/hooks cargo clippy --workspace --no-deps -- -D warnings" }
        gitleaks: { run: "gitleaks protect --staged --redact" }
    ```

### 7. Navigation and orientation: done 2026-10-09
- Extras enabled: `ui.treesitter-context` (sticky scope, 3 lines), `editor.navic` (breadcrumbs in lualine; chosen over dropbar and aerial, which would collide with Trouble symbols on `<leader>cs`), `coding.mini-surround` (`gsa/gsd/gsr`), `coding.neogen` (`<leader>cn` doc stubs), `editor.inc-rename` (live rename preview).
- `lua/plugins/navigation.lua`: `satellite.nvim` error stripe (diagnostics, git hunks, search, marks); Trouble call-hierarchy trees on `<leader>cI` / `<leader>cO` (persistent, unlike the flat `gai` / `gao`); Rust surroundings for mini.surround (`S` = `Some()`, `O` = `Ok()`, `N` = `Box::new()`, `D` = `dbg!()`, `U` = `unsafe { }`, e.g. `gsaiwS`); `treesj` split/join on `<leader>cj`; personal snippets directory `snippets/<filetype>.json` registered with blink (`snippets/rust.json`: `tmod`, `tfn`, `ttest`, `tmain`, `impldisp`, `implfrom`, `dcommon`).
- `lua/config/rust_nav.lua` (keys in the `<leader>r` group): `<leader>ru` go to super method (from a method in `impl Trait for T` to the trait's own item, via treesitter + `textDocument/definition`), `<leader>rl` usages of the symbol in this file labelled `[R]` / `[W]` in the quickfix list (from `documentHighlight`).
- Verified headless: `<leader>ru` from `impl Shape for Sq { fn area }` lands on `fn area(&self) -> f64;` in the trait; `<leader>rl` listed one `[W]` declaration, one `[W]` and one `[R]`; `gsaiwS` produced `Some(foo)`; satellite, treesitter-context, navic, treesj load; the keys and the blink search path are registered. Not exercised visually: the scrollbar, sticky context, breadcrumbs, the snippets themselves, treesj, `gsd`/`gsr` with the custom surroundings, the call-hierarchy trees.
- Type hierarchy: rust-analyzer's support is unconfirmed (`gI` remains the one-level substitute).

### 8. Context switcher (features / target / profile)
`lang.rust` sets `allFeatures = true` and bacon-ls hardcodes `--all-features`, so mutually exclusive features (ssr/csr, std/no_std) give bogus errors, and there is no `cargo.target`/cfg switcher (wasm32, thumbv7).
- Per-project `rust-analyzer.json` (loaded by rustaceanvim) with `allFeatures = false`; bacon-ls does not read it.
- `:RustContext` picker over `cargo metadata --format-version 1 --no-deps`, pushing the choice to rust-analyzer (`didChangeConfiguration` + `:RustLsp reloadWorkspace`) **and** restarting bacon-ls with matching `--features`/`--target` so both diagnostic tiers agree *(live reconfiguration untested; restarting is the safe route)*. Persist per project; `cargo-hack` for feature-powerset checks.
- `:RustNew` / scratch crate (`Snacks.scratch({ft='rust'})` + `rust-script`) and a Cargo-targets picker for run/test/debug; `.cargo/config.toml` `[env]`/`[alias]` as the shared run-configuration format; `direnv.nvim`.

### 9. Supply chain, coverage, profiling
- nvim-lint sources: actionlint (path-restricted to `.github/workflows/`), cargo-deny `--format json`, cargo-machete, gitleaks. `cargo audit --json` has no line numbers, so use quickfix. Verify JSON keys with one real run each. zizmor for workflow security; `act -j <job>` for local CI.
- Coverage: `cargo-llvm-cov` + `llvm-tools-preview` (check rustup owns the toolchain) + `andythigpen/nvim-coverage`; refresh on demand (`cargo llvm-cov nextest --no-report` then `report --lcov --no-run`), not on every autosave.
- Profiling: `perf` + `samply`/`flamegraph`, `[profile.profiling] inherits = "release" debug = true` with a dedicated target dir (`kernel.perf_event_paranoid` is 2 here); `cargo-bloat`, `cargo --timings`, tokio-console, `cargo-geiger`.
- Diagnostics UX: code-action preview (`actions-preview.nvim` / `tiny-code-action.nvim`), `[lints.clippy]` / `[workspace.lints]` tuning (`undocumented_unsafe_blocks`, `dbg_macro`, `unsafe_op_in_unsafe_fn`), tier de-duplication via a `bacon_ls` handler wrapper, a treesitter "suppress with `#[allow]`" helper. Clippy deliberately skips `--all-targets` in the live tier; run it on demand for tests.

### 10. Domain-specific, as needed
- HTTP/backend: `util.rest` (kulala.nvim), treesitter endpoint picker over axum `.route(...)` / `#[get]`, sqlx SQL injections (`after/queries/rust/injections.scm`), `lang.sql`.
- WASM/web: `trunk`, `wasm-pack`, `leptosfmt`, per-project target (ignore `target/bacon-ls-live/` in `Trunk.toml` to avoid rebuild storms under auto-save).
- Bevy: mold, `dynamic_linking` per project, `wgsl-analyzer`, `ron-lsp`, BRP *(verify port/params on docs.rs)*.
- Embedded: `probe-rs-tools`, per-project `cargo.target`. Containers: `nvim-dev-container` or distrobox.
- Also useful: `cargo-expand` (nightly flags need nightly), `rustup component add rust-docs` for offline docs, unsafe underline (`@lsp.mod.unsafe.rust`, re-applied on `ColorScheme`).

### 11. Optional: AI, UX, hygiene
- Inline AI: `ai.copilot-native` (0.12 `vim.lsp.inline_completion`, don't combine with `vim.g.ai_cmp`), `ai.sidekick` (next-edit suggestions), or a free local fill-in-the-middle model via `minuet-ai.nvim` / `llama.vim` + Qwen2.5-Coder.
- Agent grounding: `claudecode.nvim` (live diagnostics/selection over MCP), a project `CLAUDE.md`, git worktree per agent run.
- Status: fidget.nvim or a lualine component for rust-analyzer indexing/quiescent and bacon-ls staleness; right-click Refactor submenu via `MenuPopup`; Neovide config; colourblind-safe diagnostic palette.
- Hygiene: `lua/xynovim/health.lua` (`:checkhealth xynovim` for bacon-ls, mold, nextest, taplo, codelldb), CI running `nvim --headless '+Lazy! restore' +qa`, prune unused theme specs, remove dead `.neoconf.json`, guard Omarchy/remote-clipboard modules by capability for non-Arch machines.

### Not worth chasing
Type Hierarchy over LSP (unsupported), a tabbed Search Everywhere clone (`Snacks.picker.smart()` suffices), a full Cargo tool-window clone (a `cargo metadata` picker gets ~80%), RustRover's `macro_rules!` tester (use `expandMacro` + `cargo-expand`), Aquascope-style ownership visualisation, a `Cargo.toml` `BufWritePost` reload autocmd (rust-analyzer already reloads; harmful with auto-save), global `--all-targets` in live clippy, a second rust-analyzer instance.

## Layout

```
lua/config/    options, keymaps, autocmds, remote clipboard
lua/plugins/   one spec per concern (bacon-ls, rustaceanvim, ninety-nine, auto-save, …)
plugin/after/  transparency
```

LazyVim extras enabled (`lazyvim.json`): `editor.neo-tree`, `editor.overseer`, `lang.rust`, `lang.toml`, `lang.yaml`, `lang.json`, `lang.markdown`, `lang.git`, `dap.core`, `test.core`, `ui.treesitter-context`, `editor.navic`, `coding.mini-surround`, `coding.neogen`, `editor.inc-rename`.
