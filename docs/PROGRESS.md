# Progress since the baseline

State of branch `dev` on 2026-11-12. **Nothing in this work is pushed**: no commit, tag, issue, pull request or reply left this machine. The nine plugin clones in `~/projects/xyno-plugins` carry their own `dev` branches that are ahead of what `lazy-lock.json` pins; xynovim uses them only with `XYNOVIM_DEV_PLUGINS` ([DEV-PLUGINS.md](DEV-PLUGINS.md)).

The standard the work was held to: on every item, better than RustRover, VS Code, Zed, Helix and the popular Neovim configurations. What I could show is in the tables below with the evidence file next to it. **Where I could not run the other product (RustRover, Zed, VS Code were not installed or run; the starter configs are for you to run) the table says `unknown` or compares documents, not measurements.** The plan areas A to I are the ones of the approved master plan.

## 1. Numbers of this run

Machine: AMD Ryzen 7 5800X, 15.9 GB, Linux 7.3.3 (CachyOS), Neovim 0.12.6, rust-analyzer 1.99.1, bacon-ls 0.31.0, bwrap present, no `cargo-nextest`, no `pwsh`, no `wl-clipboard`, `~/.cargo/config.toml` without `debug = true`.

| Run | Result |
|---|---|
| `scripts/test.sh` (pinned plugins), 43 spec files | 1104 passed, 1 failed, 46 skipped (460 s, 2026-11-12). The failure is the lockfile drift below |
| `scripts/dev-plugins.sh test` (plugin clones on `dev`) | 1131 passed, 1 failed (the same drift), 32 skipped (489 s). A first dev run also had `keymaps-rust` "rv" fail once on a timeout; it passed in 2 of 2 reruns and in this run |
| `stylua --check .` (StyLua 2.6.0 from Mason) | clean; the lint spec (`supply-chain-lint`) passes with it |
| xyno-clipboard `nvim -l tests/run.lua` | 33 passed, 0 failed, 0 skipped |
| xyno-crates | 107 passed, 0 failed, 1 skipped |
| xyno-guard | 63 passed, 0 failed, 7 skipped |
| xyno-history | 158 passed, 0 failed, 6 skipped |
| xyno-imports | 67 passed, 0 failed, 0 skipped |
| xyno-macros | 283 passed, 0 failed, 2 skipped |
| xyno-new | 220 passed, 0 failed, 0 skipped |
| xyno-rust | 339 passed, 0 failed, 1 skipped |
| xyno-sandbox | 799 passed, 0 failed, 0 skipped, 1 expected failure |

The one failure with the pinned plugins is `startup-and-options` "every locked plugin is installed with its git HEAD at the pinned commit": ten installed plugins sit on newer commits than `lazy-lock.json` (SchemaStore.nvim, friendly-snippets, grug-far.nvim, mason-lspconfig.nvim, mini.ai, mini.icons, mini.pairs, neo-tree.nvim, nvim-treesitter-context, render-markdown.nvim). It is drift of this machine's install, not a defect of the config; `nvim --headless "+Lazy! restore" +qa` fixes it and is yours to run (section 5). The spec's message names that command.

Skips are listed with their reasons by the runner; the biggest groups are the specs that need the plugin `dev` branches (they skip against the pinned plugins with a message naming `XYNOVIM_DEV_PLUGINS`), the real-debugger specs (`~/.cargo/config.toml` lacks `debug = true`), `cargo-nextest`, `pwsh`, `shellcheck` and the offline cargo-deny advisory database.

Benchmarks ([bench/final-2026-11.md](bench/final-2026-11.md), raw [bench/final-2026-11.json](bench/final-2026-11.json), against [bench/baseline.json](bench/baseline.json)): **no regression.** Startup without a file 33.2 to 33.5 ms, with a `.rs` file 177.3 to 176.1 ms, rust-analyzer diagnostic 25.6/32.3 to 28.1/30.6 ms, clippy 562 to 565 ms (all inside run-to-run noise); idle memory 1002 to 805 MB; a 40 013-line Rust file: longest stall 527 to 100 ms, edit 243 to 19 ms, RSS after use 1207 to 798 MB. The 100 003-line file looked 4 to 13 ms slower in one run; re-measured, the baseline commit gives the same numbers today, so it is the day, not the config.

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
- Not done: timed common tasks against the other editors (G4), a clean-machine first run on this machine (`XYNO_TEST_NETWORK=1`, skipped).

### H. Architecture and maintenance

- Done: StyLua clean in xynovim (the files of the last rounds were formatted in 73b1811; `--check` is clean today); the three oversized files split behind unchanged facades with no behaviour change (xyno-crates `crate_features`, xyno-imports `engine`, xyno-macros `tools`); version contract: each dependent pins xyno-rust's API at `setup()` (xyno-rust is API 1.2 / 0.3.0 on `dev`); duplicated cargo metadata and feature-name validation merged; plugin CI templates in [plugin-ci-templates/](plugin-ci-templates/) (not applied to the plugin repositories).
- Not done: StyLua is not clean in the plugin clones (for example 33 diff hunks in xyno-rust under StyLua 2.6.0 with xynovim's settings); the lint/security templates are not applied; tags and changelogs for the new plugin versions are yours to cut (section 5); CHANGELOGs exist in 4 of the 9 plugins.

### I. Promised and open work

- Not done on purpose, they publish under your account: the GitHub issues for policy preview, exception log and egress allowlist, and the dev.to reply. Reading `PLAN_MACROS_DEPS.md` and the other unread files (I2): not done in this round.

## 3. Comparison status

Against the strongest of RustRover, VS Code, Zed, Helix and the popular Neovim configurations named in the evidence. `ahead` is claimed only where a cited page or a measurement shows the others lack the thing; `unknown` means the other side was not run or not documented. Evidence documents: [S] [comparison/security-and-features.md](comparison/security-and-features.md), [G] [comparison/gaps-and-plan.md](comparison/gaps-and-plan.md), [U] [comparison/ui-assessment.md](comparison/ui-assessment.md), [D] [comparison/debug-test-ux.md](comparison/debug-test-ux.md), [N] [comparison/notes.md](comparison/notes.md), [B] [bench/final-2026-11.md](bench/final-2026-11.md).

| Item | Status | Evidence |
|---|---|---|
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
- Run `Lazy! restore` (it moves ten plugins on this install to the pinned commits, so I did not).
- Mason's `tree-sitter-cli` (one `bacon-ls-config` check skips without it).
- Ghostty setting for OSC 52 (reading is `ask` by default).
- Pushing the plugin `dev` branches, tagging, and bumping `lazy-lock.json`: until then everything marked "needs the `dev` branch" is not what an installed xynovim runs.
- Decisions: credential masking (TLS interception), opening the three issues, the dev.to reply.
- Things I cannot do here: macOS Seatbelt (no Mac), RustRover / Zed / VS Code side-by-side numbers (not installed, one needs a licence), `cargo-nextest` runs (not installed), Reddit (unreachable).
- Running `scripts/bench/compare.sh`: it clones and executes the starter configs' code, so it is yours.

## 5. Commands for you

```sh
# 1. Clipboard tool (Wayland); X11 uses xclip instead
sudo pacman -S wl-clipboard

# 2. Put the ten drifted plugins back on lazy-lock.json (fixes the one failing spec)
cd ~/projects/xynovim && nvim --headless "+Lazy! restore" +qa

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
#    Review and merge dev into main (a pull request per plugin, or locally), then tag. The code says xyno-rust 0.3.0 (API 1.2)
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
