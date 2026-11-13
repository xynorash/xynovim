# Remaining warnings, errors and skips

Everything that still prints a warning or an error, or is skipped, after the warnings sweep and the integration run of 2026-11-13 (branch `dev`, nothing pushed). Each row has the reason it is still there and who decides. Source of the rows: the whole-suite runs (pinned plugins: 1368 passed, 1 failed, 43 skipped, then 1370 passed, 0 failed, 43 skipped after the README count and the start-up fix; plugin clones: 1386 passed, 1 failed, 25 skipped, the failure being the same README count), `tests/warnings-guard_spec.lua` and its allowlist, and the sweep's own notes ([CHANGELOG](../CHANGELOG.md), "Warnings and errors sweep 1"). The older list of behaviours that are decided and left alone is [KNOWN_ISSUES.md](KNOWN_ISSUES.md).

"You" is the owner of the machine and the repositories. "Upstream" is the project that owns the behaviour (Neovim, rust-analyzer, which-key, lspconfig, mini.nvim, snacks.nvim).

## Warnings and errors in a running editor

`tests/warnings-guard_spec.lua` starts the editor with an empty state in both plugin modes and fails on anything outside the allowlist in the spec; every allowlist entry has a comment with its reason. These are the entries and what stays outside the spec.

| Where | Message | Why it is still there | Who decides |
|---|---|---|---|
| Pinned plugin mode: `:XynoSandboxPolicy`, `:LocalHistoryPanel`, `:RustRun` | `Command XynoSandboxPolicy not found after loading xyno-sandbox.nvim`, `E492: Not an editor command` | `lazy-lock.json` pins plugin commits older than those commands; the clones are 2 to 55 commits ahead. The dev mode has them. Fixed only by pushing the plugin `dev` branches and bumping the lock. | You (push order and lock bump in [PROGRESS.md](PROGRESS.md), section 5) |
| `:checkhealth xynovim` | `blink.cmp fuzzy matcher: backoff - an earlier download was interrupted (version file v0.0.0)` | The real data directory has a `v0.0.0` marker and a `.tmp` library from an interrupted download at 04:58 on 2026-11-13. I did not touch real state. The backoff clears after 6 hours, or delete `~/.local/share/nvim/lazy/blink.cmp/target/release/version`. | You |
| `:checkhealth` snacks, kulala, overseer, mason, conform, diffview, grug-far | missing optional tools: `gs`, `mmdc`, `tectonic` / `pdflatex`, `grpcurl`, `websocat`, `prettier`, `fish_indent`, `hg`, `ast-grep`, `just` / `task` / `mise` / `cargo-make` / `deno` / `composer`, Ruby / PHP / Java / Julia / `wget` / `luarocks` for Mason | Tools that are not installed; nothing may be installed in these runs. Each is optional and its feature is off or falls back. | You, per tool |
| `:checkhealth xynovim` | `cargo-nextest not found`; stable lacks the `wasm32-unknown-unknown` target | Optional. neotest falls back to `cargo test`; the health line gives the install command. | You (`cargo install cargo-nextest --locked`, `rustup target add wasm32-unknown-unknown`) |
| `:checkhealth` under tmux | truecolor not told to tmux, no Smulx / Setulc, `set-clipboard external` (xyno-clipboard WARNING), focus-events off, snacks `terminal does not support kitty graphics` | The tmux settings of this machine; each line carries the setting to add. In Ghostty none of them appear. | You (tmux.conf) |
| `:checkhealth` which-key, vim.lsp, snacks, vim.pack, lazy | overlap notes for `gc` / `gr` / `gs*` / `i` / `a`; `Unknown filetype 'yaml.docker-compose'`, `yaml.gitlab`, `yaml.helm-values`, `markdown.mdx`; snacks `setup {disabled}` x4; an empty `site/pack/core` created by `:checkhealth vim.pack` and then reported by `:checkhealth lazy` | Neovim 0.12, mini.* and lspconfig defaults, or snacks features that are switched off on purpose. On the allowlist with reasons. | Upstream; the config would have to drop the feature |
| vim.lsp log | `-32801 content modified` for codelens and semantic tokens, logged at ERROR by Neovim | Normal while typing or rebuilding; no notification reaches the user. | Upstream (Neovim) |
| rust-analyzer log | `WARN notify error: No path was found`, one `Propagating panic for cycle head` | rust-analyzer's own behaviour on rebuilds; no notification. | Upstream (rust-analyzer) |
| Headless Neovim started with a cleared environment and no display, with the dev plugins | a startup notification (xyno-clipboard `no clipboard tool found`) is parked by LazyVim's `lazy_notify`; code that wraps `vim.notify` before its 500 ms replay makes the replay loop forever (8 GB) | The cause was a test child's own `vim.notify` wrapper, not the config; the guard hooks after `VeryLazy`. It stays a hazard for scripts that wrap `vim.notify` early. Noted in the CHANGELOG and `H.settle_notify()`. | Nobody; scripts must wait out the window |
| Normal mode `q` | which-key's macro-register prompt blocks the main loop until a key arrives; an automation that sends `q` to close a popup freezes | which-key behaviour (macros are a trigger). Not a bug of the config. | Upstream, or you (a different macro key) |
| Narrow terminals (about 93 columns, Ghostty's default here) | the neotest summary float overlaps the right part of the dap-ui strip when both are open | By design: the code window keeps its width (it went from 21 to 93 columns); the float is limited to 60 % of the screen height. Stacking them differently was not tried. | You (layout preference) |
| Terminals without the features | no 140x40 Ghostty window was verified; tmux was tested at 93x46 and 140x40, Ghostty at 93 columns and about 133 columns with a smaller font (`--window-width` was ignored) | Environment of the test machine. | You, if your terminal differs |

## Skips in the whole-suite runs

The runner prints every skip with its reason. Pinned mode has 43, dev mode 25; the 18 that differ are the first group.

| Group | Count | Specs | Reason | Who decides |
|---|---|---|---|---|
| Needs the plugin `dev` branches | 18 (pinned only) | `agent-99-guard` policy-preview checks (3), `rust-ide-features` (run configurations, action menu, organize on save, `:RustRename`, `:RustUsages`, code lens; 8), `ui-community` real popups (4), `clipboard-e2e` OSC 52 (2), `rust-analyzer unhealthy toast` (1) | The lock file pins older plugin commits. They run in dev mode and pass there. | You (push and lock bump) |
| No claude session | 1 | `agent-99-guard` "a real 99 request end to end" | Needs a real logged-in `claude` and the network. | You |
| Real-terminal and mouse checks | 5 | prompts with a real pty, multi-bin debug launch, narrow dap-ui render, clicking a codelens, threads that panic | The README lists them as untested; they need a pty-driven or mouse-driven session. | Nobody yet (could be automated with tmux; not done) |
| Tools not installed | 7 | `cargo-nextest` (2: the neotest command and the `<leader>tc` llvm-cov run), `lldb-dap` (1), `shellcheck` (1), `pwsh` (1), Mason's `tree-sitter` CLI (1), `wasm32-unknown-unknown` (1) | Not installed here and nothing may be installed in these runs. | You, per tool (commands in [PROGRESS.md](PROGRESS.md), section 5) |
| Offline advisory database | 2 | `git-lint-supply-chain` cargo-deny RUSTSEC checks | cargo-deny cannot fetch the RustSec database offline (`FETCH_HEAD`). | You (run `cargo deny fetch` online once) |
| Network and slow | 1 | `bootstrap.sh` fresh install (clones about 60 plugins) | Set `XYNO_TEST_NETWORK=1` to run it; not run in these runs. | You |
| Not applicable on this platform | 2 | `agent-failclosed`, `agent-99-guard` "no sandbox backend" | A bwrap backend exists here; the refusal path is tested in the plugin's own spec. | Nobody |
| Documentation only or covered by another spec | 7 | global git config, README per-repo opt-ins, auto-save interplay 22, `unsafe` underline, cargo-machete / cargo-deny wildcard, light-theme background leak, markdown `E31` | Informational entries (documented upstream behaviour or covered elsewhere). | Nobody |

The plugin suites: xyno-history skips 6 and xyno-rust skips 1 with a stated reason (printed by `scripts/plugin-tests.sh`); the other seven have none.

## Measured and not fixed

| Where | What | Why it is still there | Who decides |
|---|---|---|---|
| Benchmark, edit to the first rust-analyzer diagnostic | about 35 ms against 27 to 34 ms for the baseline code in four paired sets (-1 to +10 ms per set) | The cause was not isolated (rainbow boot off and the bacon-ls duplicate filter off, alone or together, did not give a clean result); [bench/final-2026-11d.md](bench/final-2026-11d.md). Far below what a person notices. | You (accept it, or ask for a profiling round) |
| Benchmark, Neovim RSS after start | 28.7 MB against 25.7 MB (the UI, hint, trust and rainbow modules) | The price of those features; total idle memory is 116 to 197 MB lower than the baseline's. | You |
| Benchmark conditions | the run was not on a quiet machine (another session compiling, disk wait, swap in use) | Not under my control; the paired runs are the evidence. | You (`final-quiet` command in PROGRESS.md section 5) |

## Platforms

Windows and macOS skip whole spec files by header (`-- xyno-os:`); the list and the failing macOS and Windows checks are in [KNOWN_ISSUES.md](KNOWN_ISSUES.md) and the README "Platforms" table. No macOS or Windows machine is available here. Who decides: you (a Mac to build the Seatbelt backend on, CI runs).

## Open decisions that are not warnings

Credential masking for the agent sandbox (needs TLS interception), the three GitHub issues, the dev.to reply, and the push, tag and lock order for the plugin `dev` branches. All are yours; none is done.
