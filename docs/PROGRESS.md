# Progress since the baseline

State of branch `dev` on 2026-11-12, final numbers and statuses of the integration round 2026-11-13. **Nothing in this work is pushed**: no commit, tag, issue, pull request or reply left this machine. The nine plugin clones in `~/projects/xyno-plugins` carry their own `dev` branches that are ahead of what `lazy-lock.json` pins; xynovim uses them only with `XYNOVIM_DEV_PLUGINS` ([DEV-PLUGINS.md](DEV-PLUGINS.md)).

The standard the work was held to: on every item, better than RustRover, VS Code, Zed, Helix and the popular Neovim configurations. What I could show is in the tables below with the evidence file next to it. **Where I could not run the other product (RustRover, Zed, VS Code were not installed or run; the starter configs are for you to run) the table says `unknown` or compares documents, not measurements.** The plan areas A to I are the ones of the approved master plan.

## 1. Numbers of this run

Machine: AMD Ryzen 7 5800X, 15.9 GB, Linux 7.3.3 (CachyOS), Neovim 0.12.6, rust-analyzer 1.99.1, bacon-ls 0.31.0, bwrap present, no `cargo-nextest`, no `pwsh`, no `wl-clipboard`, `~/.cargo/config.toml` without `debug = true`.

| Run | Result |
|---|---|
| `scripts/test.sh` (pinned plugins), 57 spec files | 1287 passed, 0 failed, 49 skipped (568 s, 2026-11-13, whole suite in one run). The runs of 2026-11-12: 1286 passed, 1 failed (the README spec count, fixed), and before the rainbow work 49 files, 1137 passed, 1 failed (lockfile drift, gone now, see below), 67 skipped |
| `scripts/dev-plugins.sh test` (plugin clones on `dev`) | 1304 passed, 0 failed, 32 skipped (580 s, 2026-11-13, whole suite in one run). The earlier dev run of 2026-11-12 (49 files): 1185 passed, 1 failed (the drift), 32 skipped; the full dev run before it had three fixed or load-dependent specs (`agent-99-guard` absolute `/usr/bin/env` and `bwrap` paths, `debug-values` Noice notice racing the notify capture, `keymaps-rust` "rv" timing out under load) |
| `stylua --check .` (StyLua 2.6.0 from Mason) | clean in xynovim and in all nine plugin clones (each with its own `.stylua.toml`; xyno-history's was added on 2026-11-13, same settings as the others); five sandbox spec files were reformatted the same day; the lint spec (`supply-chain-lint`) passes |
| xyno-clipboard `nvim -l tests/run.lua` (2026-11-13) | 42 passed, 0 failed, 0 skipped |
| xyno-crates | 114 passed, 0 failed, 1 skipped |
| xyno-guard | 63 passed, 0 failed, 7 skipped |
| xyno-history | 158 passed, 0 failed, 6 skipped |
| xyno-imports | 67 passed, 0 failed, 0 skipped |
| xyno-macros | 283 passed, 0 failed, 2 skipped |
| xyno-new | 230 passed, 0 failed, 0 skipped |
| xyno-rust | 414 passed, 0 failed, 1 skipped |
| xyno-sandbox | 1102 passed, 0 failed, 0 skipped, 1 expected failure (run with the real HOME; was 897 before the git write mode and round 8 and 9 specs) |

The one failure of the earlier runs, `startup-and-options` "every locked plugin is installed with its git HEAD at the pinned commit", came from ten installed plugins sitting on newer commits than `lazy-lock.json`. On 2026-11-13 the check passes: the four I compared (SchemaStore.nvim, friendly-snippets, mini.ai, neo-tree.nvim) are at the pinned commits. I did not run Lazy update or restore and do not know who or what moved them back; on an install that drifts again, `nvim --headless "+Lazy! restore" +qa` fixes it and is yours to run (section 5). `lazy-lock.json` itself is unmodified (`git status` is clean, its last commit is from 2026-10-22, not from this work).

Skips are listed with their reasons by the runner; the biggest groups are the specs that need the plugin `dev` branches (they skip against the pinned plugins with a message naming `XYNOVIM_DEV_PLUGINS`), the real-debugger specs (`~/.cargo/config.toml` lacks `debug = true`), `cargo-nextest`, `pwsh`, `shellcheck` and the offline cargo-deny advisory database.

Benchmarks, second run ([bench/final-2026-11b.md](bench/final-2026-11b.md), raw [bench/final-2026-11b.json](bench/final-2026-11b.json)): the machine was loaded by a game and Discord (load 7 to 9), so its raw timings are 40 to 60 % slower than the first run and must not be read against it; the paired check of the previous benchmarked commit against current `dev`, alternated under the same load, shows **no regression** (startup, 40 013-line file, memory), and memory matches the quiet run to 1 MB. The re-run also found that the harness measured an untrusted workspace (bacon-ls off, restricted rust-analyzer) now that the trust gate fails closed with the pinned plugins; `hook.lua` switches the gate off for the temp crate (`BENCH_TRUST=0` measures restricted mode). First run ([bench/final-2026-11.md](bench/final-2026-11.md), raw [bench/final-2026-11.json](bench/final-2026-11.json), against [bench/baseline.json](bench/baseline.json)): **no regression.** Startup without a file 33.2 to 33.5 ms, with a `.rs` file 177.3 to 176.1 ms, rust-analyzer diagnostic 25.6/32.3 to 28.1/30.6 ms, clippy 562 to 565 ms (all inside run-to-run noise); idle memory 1002 to 805 MB; a 40 013-line Rust file: longest stall 527 to 100 ms, edit 243 to 19 ms, RSS after use 1207 to 798 MB. The 100 003-line file looked 4 to 13 ms slower in one run; re-measured, the baseline commit gives the same numbers today, so it is the day, not the config.

Benchmarks, third run, 2026-11-13 ([bench/final-2026-11c.md](bench/final-2026-11c.md), raw [bench/final-2026-11c.json](bench/final-2026-11c.json)): not a quiet machine (load 3.7, another session compiling and running a Rust program, Discord, governor `powersave`; I waited about ten minutes and it did not clear), so the raw numbers are 10 to 15 % above the quiet runs (no file 38.0 ms against 33.5, with a `.rs` file 201.7 against 175.8, UIEnter). A paired alternating run of the `final-2026-11` code (85db1a3) against this checkout in the same conditions shows no start-up or large-file difference (no file 39.5 ms old, 38.9 ms new; `.rs` file 204 old, 204 new), and one small difference: edit to first rust-analyzer diagnostic 33.5 ms old, 34.5 ms with the rainbow brackets off, 36.2 ms on (spread of single trials 28 to 46 ms), which is the documented redraw cost of the brackets. No regression found in start-up, memory, the large-file paths or bacon-ls; the +1 to +3 ms on the first diagnostic is the price of a feature, stated, not hidden. A quiet-machine run is open.

## 2. What changed per area

Commits are on `dev` of this repository unless a plugin is named. Evidence for each line is the spec or document named; a line without evidence says so.

### A. Visual design and beauty

- Done: highlight groups for the plugin popups (`Xyno*`, defined by the theme, measured at or above 4.5:1 on the real windows after the first measurement found some below), statusline components for hints, sandbox, guard and history, a light variant (`island-light`, derived by a lightness flip, every group keeps the contrast it has in dark), a complete high-contrast mode (7:1 text, 4.5:1 frames, hue kept), colourblind diagnostics (existing), severity as shape, WCAG checks on about 1000 groups of the running config, `:checkhealth xynovim` terminal section (truecolor, undercurl, tmux, Ghostty, WezTerm, kitty), ASCII icon mode that switches at run time, narrow-window statusline, rustc-style diagnostic float, tree error colour, opt-in winbar. Spec: `tests/ui-community_spec.lua` (91 checks against the rendered grid), `tests/theme-island_spec.lua`.
- Macros popup layout options and the popup groups are in xyno-macros `dev` (3af1ae2).
- Not done: end-of-line hints (#16), a designed (not derived) light theme, a fresh side-by-side screenshot against the other editors (A8: only marketing pages were captured, no competitor was run), a check of the dashboard with a non-Cargo project directory (A7: not examined in this round), and the empty statusline-coloured bar on a 119x29 dashboard ([comparison/ui-assessment.md](comparison/ui-assessment.md)).
- Evidence: [comparison/ui-assessment.md](comparison/ui-assessment.md), [comparison/ui-community.md](comparison/ui-community.md), captures in `comparison/screenshots/ui/` and `ui2/` (Ghostty 1.4.0 as an X11 window).

### B. Flexibility and customization

- Done in the plugins (`dev`): validated `setup()` options with an options table in each README (xyno-crates, xyno-imports, xyno-new, xyno-macros, xyno-rust, xyno-clipboard), `setup()` idempotent in xyno-clipboard and repeatable in xyno-crates, xyno-new workspace template options, history/sandbox/imports/rust settings that were hard-coded are options now.
- Done in xynovim: `vim.g.xynovim_largefile`, `xynovim_workspace_trust`, `xynovim_organize_on_save`, `xynovim_clippy_debounce_ms`, `xynovim_hints`, `xynovim_diagnostics`, `xynovim_icons`, `xynovim_contrast`, `xynovim_winbar`; the dev-plugin mode.
- Not done / not verified: the single documented options table for all `vim.g.xynovim_*` globals in xynovim itself (they are documented where each feature is described), per-project config layer, minimal/full profiles, each plugin tested on a plain LazyVim.

### C. Performance

- Done: tiered large-file shedding, `MALLOC_ARENA_MAX=2` for rust-analyzer (idle RSS 880 to 683 MB on the demo crate), nvim-dap no longer a hard dependency of rustaceanvim and `nvim-dap-virtual-text` lazy, bisection in the contrast lift (startup runs about 30 of them), async cargo metadata in xyno-rust, async resolve/organize in xyno-imports, background exit snapshot and a cheaper snapshot path in xyno-history, faster sandbox plan, the bench harness itself with typing-latency and large-file probes. Numbers: section 1 and [bench/](bench/).
- Not done: benchmark numbers as CI regression guards (the harness needs a real pty, tmux and rust-analyzer; not wired into `ci.yml`), the wl-copy timeout and the route scan: not verified in this round.

### D. Security

- Done on the plugin `dev` branches: sandbox policy preview and approval log, `--unshare-net` with a default-deny allowlist proxy, a `home` allowlist view, five hardening rounds (hard links, sockets, token formats, nested `.git`, absent files, env scrub by value; mutation checks of 102 and 88 mutants in the plugin's own changelog, which I read but did not re-run), secrets exclude list and a push guard in xyno-history, `cargo expand` and `cargo add` behind confirmation/trust, pinned egui template with `https` only.
- Done in xynovim: restricted mode for untrusted Rust workspaces (`:RustTrust`), `ci.yml` pins the Neovim download with a sha256, Dependabot, `SECURITY.md`, pinned Mason registry, StyLua/lua-language-server pinned by sha256 in the lint job.
- Only the AI agent is sandboxed. rust-analyzer, build scripts, proc macros, cargo, the debuggee, tests and plugins run with your privileges; the restricted mode limits what rust-analyzer executes and is not a sandbox. With the pinned xyno-sandbox the network is open.
- Not done: a macOS Seatbelt backend (no Mac), credential masking (needs TLS interception, a decision for you), a live demo of a hostile agent against the other editors (D10; the comparison is by their documentation), the three GitHub issues (I1).

### E. Correctness and robustness

- Done: the five `KNOWN_ISSUES.md` items (multi-file rename undone by one `u`, panic stop selects your frame, naming lints once, no stray quote after a backslash, crates.nvim diagnostics once), `tests/known-issues_spec.lua`; per-plugin gap fixes listed in each plugin's `dev` log (guard stat+hash staleness and nowrite recovery, history rename tracking and restore fidelity, clipboard failed `wl-copy` reported once, imports masking scanner for `use` items, new workspace-name validation and dotted `workspace.members`, macros snippet guard); this run: the 11 live-server supervision specs were skipped as "bacon-ls not found" because Mason's bin is not on PATH in a spec, now they find it and pass (b2d577f); an unrunnable `//` operator in an uncommitted perf edit broke the colourscheme load (88 failing checks) and was fixed (85db1a3).
- Not done: macOS and Windows are not stabilised (specs there skip with "cause not diagnosed", and the README says so); whether every `known_bug()` skip became a visible one: not verified.
- One spec is flaky under load: `keymaps-rust` "rv on `1 + 2 + 3`" failed once in the dev-plugin run (timed out waiting for rust-analyzer's edit) and passed twice when run alone.

### F. Rust IDE features

- Done on `dev`: run configurations saved per project (`:RustRun`, `<leader>rb`), profiling profile on the command line, code actions and refactorings with a diff preview (`<leader>ca`, `<leader>ra`), `:RustFixAll`, Problems panel filters, opt-in organize imports on save, debugger value readability (container previews, value float, frames), a test results panel (`<leader>tp`), `cargo add` preview with typosquat/age/audit warnings, macro schemas (diesel, tracing, axum, bevy), restricted mode. Evidence: [comparison/gaps-and-plan.md](comparison/gaps-and-plan.md), [comparison/debug-test-ux.md](comparison/debug-test-ux.md), `tests/rust-ide-features_spec.lua`, `tests/debug-values_spec.lua`, `tests/test-ui_spec.lua`.
- Not done: clickable Run/Debug gutter icons (behind RustRover and VS Code on the mouse), `cargo-generate` templates (they execute template scripts), run configurations shared through the repository (deliberate), a profiler view inside the editor, nextest runs and debugging under nextest (not installed here, not verified), a tokio program in the debugger.

### G. UX and onboarding

- Done: `:checkhealth` for each plugin except xyno-sandbox (the sandbox has `:XynoSandboxStatus` instead; I did not check whether it also registers a health check), failures made visible (history snapshots, clipboard, sandbox refusal), accessibility options (ASCII icons, high contrast, colourblind palette, severity shapes).
- Done, rainbow brackets (2026-11-12 and 13; [RAINBOW.md](RAINBOW.md), `tests/rainbow_spec.lua` 87 checks on the real grid, captures in `comparison/screenshots/rainbow/`): nesting colours from the syntax tree, per-kind switches, scope highlight (mouse, keys, commands), unmatched marking, contrast-checked palettes including a colour-blind one, locals-based variable colours, keywords and tags by depth (Python, C `#if`, HTML / XML / JSX, YAML keys; off by default), started from `options.lua` by a boot module (no lazy spec). Not done: Ruby, C++ and Kotlin rules (grammars not installed here, none downloaded), the rectangular scope box, the debugger Execution Point colour. Cost measured under load: +1.1 to +2.4 ms redraw, start-up not measurable.
- Done, review round U1 to U11 (CHANGELOG): `:RustRun` picker no longer shadowed by rust.vim, trust prompt wrapped and sized, vendored trust fallback for the pinned xyno-rust.nvim, `cargo add` re-records trust, calmer inlay hints, one popup per test run, quieter clipboard notice on a local Wayland session, once-only blink.cmp library download. The trust prompt was captured on the tmux grid, not in Ghostty pixels, and the pinned set was exercised through the vendored `xyno_rust.trust` module, not with a real `lazy-lock.json` bump.
- Not done: timed common tasks against the other editors (G4), a clean-machine first run on this machine (`XYNO_TEST_NETWORK=1`, skipped).

### H. Architecture and maintenance

- Done: StyLua clean in xynovim (the files of the last rounds were formatted in 73b1811; `--check` is clean today); the three oversized files split behind unchanged facades with no behaviour change (xyno-crates `crate_features`, xyno-imports `engine`, xyno-macros `tools`); version contract: each dependent pins xyno-rust's API at `setup()` (xyno-rust is API 1.3 / 0.3.0 on `dev`); duplicated cargo metadata and feature-name validation merged; plugin CI templates in [plugin-ci-templates/](plugin-ci-templates/) (not applied to the plugin repositories).
- Done since: StyLua is clean in all nine plugin clones (committed on each `dev`; xyno-history's diff is large because it had no `.stylua.toml` and was never formatted, so its commit is mostly whitespace). Not done: the lint/security templates are not applied; tags and changelogs for the new plugin versions are yours to cut (section 5); CHANGELOGs exist in 4 of the 9 plugins.

### I. Promised and open work

- Not done on purpose, they publish under your account: the GitHub issues for policy preview, exception log and egress allowlist, and the dev.to reply. Reading `PLAN_MACROS_DEPS.md` and the other unread files (I2): not done in this round.

## 3. Comparison status

Against the strongest of RustRover, VS Code, Zed, Helix and the popular Neovim configurations named in the evidence. `ahead` is claimed only where a cited page or a measurement shows the others lack the thing; `unknown` means the other side was not run or not documented. Evidence documents: [S] [comparison/security-and-features.md](comparison/security-and-features.md), [G] [comparison/gaps-and-plan.md](comparison/gaps-and-plan.md), [U] [comparison/ui-assessment.md](comparison/ui-assessment.md), [D] [comparison/debug-test-ux.md](comparison/debug-test-ux.md), [N] [comparison/notes.md](comparison/notes.md), [B] [bench/final-2026-11.md](bench/final-2026-11.md).

| Item | Status | Evidence |
|---|---|---|
| Rainbow brackets: depth colouring, scope highlight, contrast guarantee, colour-blind palette | tied on depth colouring and scope (the JetBrains plugin has both); ahead on the contrast guarantee and colour-blind palette by documentation; behind on Ruby / C++ / Kotlin rules, the scope box and the Execution Point colour | MATRIX RB1 to RB6 |
| Sandbox git write mode (opt-in, plugin `dev`) | ahead by documentation; two critical bypasses found and closed, not audited | MATRIX ST1 |
| Workspace trust through the pinned plugin set | tied | MATRIX ST2 |
| Agent sandbox on Linux (credentials hidden, fail closed) | ahead on defaults; behind on macOS / Windows and credential masking | S 1 |
| Network egress control (plugin `dev`; pinned version is open) | tied (default-deny like Zed, Claude Code, Codex; ahead of VS Code) | S 2 |
| Sandbox in other Neovim agent plugins | ahead (none of seven read ships one) | S 15 |
| Policy preview before an agent runs | ahead (narrow) | S 4 |
| Exception approval log | ahead, by documentation only | S 5 |
| Workspace trust for rust-analyzer | tied (narrow edge); Zed / RustRover hold the server back entirely; Helix unreleased | S 3, G 1 |
| Local History and secrets handling | ahead | S 6, 7 |
| Hostile repo config | tied | S 8 |
| Async loading | tied (no measured comparison) | S 9 |
| Import management | tied (RustRover has import on paste and an exclusion table) | S 10, G 9 |
| Macro expansion safety | tied | S 11 |
| Dependency add confirmation | ahead at add time | S 12 |
| Template supply chain | ahead (narrow) | S 13 |
| Health checks | tied | S 14 |
| Debugger value readability | ahead of CodeLLDB's stock rendering (measured); RustRover and Zed not measured | D, G 2 |
| Test results panel | ahead of neotest/LazyVim defaults on what was run; RustRover and VS Code not run | D, G 3 |
| Debug a test | works with `cargo test`; nextest unverified | G 16 |
| Inlay hint kinds, cursor-line diagnostics, severity not by colour alone | tied with Helix / Zed on policy; contrast numbers measured only for xynovim | U, G 4-6 |
| Diagnostic text as rustc prints it | ahead of rustaceanvim's float; RustRover shows rendered text too | U |
| Hint contrast (6.07:1) | ahead of tokyonight (2.47:1) and VS Code default (5.31:1), computed from their sources; others unknown | U |
| High-contrast variant | different (VS Code and JetBrains ship separate themes; not measured) | U |
| Light variant | behind in craft (derived, not designed) | U |
| Icons without a Nerd Font | tied with AstroNvim, ahead of NvChad | U |
| Terminal compatibility check | ahead of documentation-only setups | U, G 8 |
| Code actions with a diff preview | tied (VS Code has a Refactor Preview panel) | G |
| Run configurations | behind RustRover and Zed on sharing with a team (deliberate); ahead of Helix and plain LazyVim | G |
| Run/Debug gutter icons by mouse | behind RustRover and VS Code | G 13 |
| Call hierarchy, workspace symbols, macro expansion | tied | G 13, 15 |
| Cargo.toml dependency UI | tied / unknown | G 14 |
| HTTP client and database tools | behind (no Rust angle, not built) | G 17 |
| Startup, memory, large-file latency | measured for xynovim only ([B]); no same-machine run of the others | G 7, 20 |
| rust-analyzer memory vs other editors | unknown (no published figure, same server) | G 7 |
| macOS agent sandbox | behind (no Mac to build or test on) | G 10 |

## 4. Blocked on you

- Install `wl-clipboard` (needs `sudo`): without it the clipboard specs cover only the fake tools and the OSC 52 fallback path.
- `Lazy! restore` is no longer needed on this install (the lockfile check passes on 2026-11-13); run it only if the check fails again.
- Mason's `tree-sitter-cli` (one `bacon-ls-config` check skips without it).
- Optional: `cargo-nextest` (`cargo install cargo-nextest --locked`, or `sudo pacman -S cargo-nextest`); I did not install it, so nextest runs and debugging under nextest are unverified.
- Ghostty setting for OSC 52 (reading is `ask` by default).
- Pushing the plugin `dev` branches, tagging, and bumping `lazy-lock.json`: until then everything marked "needs the `dev` branch" is not what an installed xynovim runs.
- Decisions: credential masking (TLS interception), opening the three issues, the dev.to reply.
- Things I cannot do here: macOS Seatbelt (no Mac), RustRover / Zed / VS Code side-by-side numbers (not installed, one needs a licence), `cargo-nextest` runs (not installed), Reddit (unreachable).
- A quiet-machine benchmark repeat (the run in this file was under game load): `scripts/bench/bench.sh --out docs/bench/final-quiet.json`, with nothing else running (the 2026-11-13 run was under load, see third run above).
- Leftovers in `/tmp` that I was not allowed to delete: about 144 `xyno-run-*` directories (the xyno-sandbox test runner of earlier rounds; a complete run now leaves none), `xynotest.*`, `xyno_clippy.log`, `xyno_fmt.log`, `xyno_test.log`, `xyno_done`: `rm -rf /tmp/xyno-run-* /tmp/xynotest.* /tmp/xyno_*` when no test is running.
- Running `scripts/bench/compare.sh`: it clones and executes the starter configs' code, so it is yours.

## 5. Commands for you

```sh
# 1. Clipboard tool (Wayland); X11 uses xclip instead
sudo pacman -S wl-clipboard

# 2. Only if the lockfile-drift spec fails on your install: put the plugins back on lazy-lock.json
cd ~/projects/xynovim && nvim --headless "+Lazy! restore" +qa

# 2b. Optional: nextest (nextest runs and nextest debugging are unverified here)
cargo install cargo-nextest --locked

# 3. Mason's tree-sitter CLI
nvim --headless "+MasonInstall tree-sitter-cli" +qa

# 4. Ghostty: ~/.config/ghostty/config
#      clipboard-write = allow
#      clipboard-read = ask

# 5. Push the plugin dev branches. The clones' origin is the local lazy checkout of GitHub, so name the URL.
#    Order: xyno-rust first (the others call its API), then the plugins that depend on it, then the standalone ones.
cd ~/projects/xyno-plugins
for p in xyno-rust xyno-imports xyno-crates xyno-macros xyno-new xyno-history xyno-sandbox xyno-clipboard xyno-guard; do
  git -C $p.nvim push https://github.com/xynorash/$p.nvim.git dev
done
#    Review and merge dev into main (a pull request per plugin, or locally), then tag. The code says xyno-rust 0.3.0 (API 1.3; a local tag v0.2.0 exists in the clone and was not pushed)
#    and xyno-imports 0.2.0 (already tagged); the other versions are your call, for example:
git -C xyno-rust.nvim tag v0.3.0 && git -C xyno-rust.nvim push origin v0.3.0

# 6. Move the lockfile to the published commits and commit the lock lines
cd ~/projects/xynovim
unset XYNOVIM_DEV_PLUGINS
nvim --headless "+Lazy! update xyno-rust.nvim xyno-imports.nvim xyno-macros.nvim xyno-crates.nvim xyno-history.nvim xyno-sandbox.nvim xyno-clipboard.nvim xyno-guard.nvim xyno-new.nvim" +qa
git diff lazy-lock.json
scripts/test.sh            # every dev-only spec should now run instead of skip

# 7. The comparison against the starter configs (clones and runs their code; read it first)
scripts/bench/compare.sh ~/bench-compare
```

Step 5 pushes to your GitHub account and step 6 changes `lazy-lock.json`; I ran neither.
