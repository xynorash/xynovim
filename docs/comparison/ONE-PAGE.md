# xynovim against RustRover, VS Code, Zed, Helix and the popular Neovim configs: one page

Written 2026-11-12, final statuses 2026-11-13, on branch `dev` (not pushed). The full table with sources is [MATRIX.md](MATRIX.md). Labels: **measured** = run on one machine (Ryzen 7 5800X, Linux, Neovim 0.12.6, rust-analyzer 1.99.1); **published** = a claim from a vendor, docs or blog that I did not reproduce. I did not install or run RustRover, VS Code, Zed or Helix, so every statement about them comes from their docs, source files and release notes.

## Where xynovim leads

Only where a page or a measurement shows the others lack it or do it worse.

- **Agent isolation on Linux.** The agent runs in bubblewrap with credentials hidden, secrets stripped from the environment, a default-deny network allowlist, and it refuses to start without a working sandbox. VS Code's sandbox is off by default and allows leaving it; Zed reads most of the filesystem and may run unsandboxed when setup fails; none of seven popular Neovim agent plugins ships a sandbox (git-tree search). Published docs, not a live attack demo.
- **Policy preview and approval log.** The full policy is shown before the first launch, and every approval, refusal and revocation is logged. No competitor page describes either. (Absence from docs, not proof of absence.)
- **Adding a dependency.** `cargo add` shows a preview with a typosquat and age warning. No competitor page mentions one.
- **Local History.** Whole-tree snapshots, 30 days by default, secrets excluded by name. RustRover keeps 5 working days; VS Code keeps 50 entries per file and 256 KB per file.
- **Debugger values.** `Vec` shows `size=3 [1, 2, 3]` where stock CodeLLDB shows `size=3` (measured, same binary). VS Code and Zed use CodeLLDB; that they show the stock text is my inference. RustRover was not run.
- **Test results panel.** Failure summary, per-test folds, `assert_eq!` diff, rerun failed, doc-tests. Better than neotest's defaults; Zed shows test output in a terminal (published docs). RustRover's Test window was not seen.
- **Diagnostics and contrast.** Hint text 6.07:1 (measured) against VS Code's default 5.31:1 and tokyonight's 2.47:1 (both computed from their source). The other editors' whole UI was not measured.
- **Rainbow brackets: contrast guarantee and colour-blind palette.** Nesting colours are enforced at 3:1 (7:1 for restrained text) and a colour-blind palette is measured; none of the pages read (JetBrains Rainbow Brackets, rainbow-delimiters.nvim, VS Code, Zed, Helix) states a guarantee, and only Zed has a minimum-contrast setting. Absence from docs, not proof of absence. Rows RB1 to RB6 in [MATRIX.md](MATRIX.md).
- **Sandboxed agent and git.** Commits fail by default (read-only `.git`); `policy.git_write` is an opt-in whose bypasses (`.git` rebuilt by rename, `commondir` redirect) were found by a red-team round and closed, in the plugin `dev` branch only (not pinned). Row ST1.

## Where it ties

- Restricted mode for untrusted Rust workspaces. RustRover, VS Code (the rust-analyzer extension declares itself unsupported in untrusted workspaces) and Zed hold the language server back entirely. xynovim keeps navigation working but disables build scripts, proc macros and cargo check. That is a trade, not a lead.
- Egress control (like Zed, Claude Code, Codex), call hierarchy (Zed 1.19, RustRover 2026.1), macro expansion, inlay hint control, cursor-line diagnostics policy (Helix, Zed), code actions with a diff preview (VS Code's Refactor Preview), Problems filters, health checks, async loading.
- **rust-analyzer memory.** Bare `rust-analyzer` on the demo crate: 681 and 762 MB (measured, 2 runs); with xynovim's allocator cap 674 and 674 MB. The 702 MB figure is the same engine's number, not an advantage over VS Code, Zed or Helix. No published small-crate figure exists.
- Rainbow brackets by depth and the scope highlight: the JetBrains plugin has both (scope on mouse only), VS Code, Zed and Helix have the depth colouring. Row RB1, RB2.
- Workspace trust through the pinned plugin set (vendored fallback) and `cargo add`, row ST2: the prompt was captured on the tmux grid, not in Ghostty pixels.

## Where it trails

- Clickable Run/Debug gutter icons (RustRover, VS Code, Zed have them). Closable.
- Memory and disassembly views (RustRover; Zed has a memory view). Closable with DAP `readMemory` / `disassemble`.
- Locked-vs-latest version hint in Cargo.toml, grouped Find usages, a `macro_rules!` tester (RustRover 2026.2, published), partial accept in refactor preview (VS Code), import exclusion table. All closable.
- Run configurations are not shared through the repository. Deliberate: a config from a cloned repo would run on your machine.
- Credential masking (VS Code) needs TLS interception; macOS and Windows are unsupported and unverified (no Mac here).
- The light theme is derived, not designed.
- Rainbow brackets: Ruby keywords, C++ `#if`, Kotlin arrows (grammars not installed here), the plugin's rectangular scope box and the debugger Execution Point colour are not built (RB5).

## Commands to run yourself

```sh
scripts/test.sh                              # the suite with the pinned plugins (about 10 minutes)
scripts/dev-plugins.sh test                  # the same against the plugin clones on dev
scripts/bench/bench.sh --out my.json         # the benchmarks (run it on a quiet machine)
scripts/bench/rainbow.sh --rounds 5          # rainbow redraw latency, brackets on against off
nvim --headless "+Lazy! restore" +qa         # only if the lockfile-drift check fails on your install
```

In the editor: `:XynoRainbow` (tab-completes; `palette next`, `scope`, `restrain`, `keywords`, `tags`, `colors show|save|freeze`), `<leader>uk` / `uj` / `uJ`; `:RustRun` (run-configuration picker, **[dev]**: only with `XYNOVIM_DEV_PLUGINS`, absent from the pinned plugins); `:RustTrust` (trust list, **[dev]**); `:XynoSandboxPolicy` (**[dev]** policy preview, "Git write mode" section on the plugin `dev` branch); `:checkhealth xynovim`.

## What is unknown

Same-machine startup, latency and memory against RustRover, VS Code, Zed and Helix; RustRover's debugger and test panels; nextest (not installed). xynovim measured: 33.5 ms startup with no file, 176 ms with a `.rs` file (UIEnter, TUI in tmux). Published: NvChad 20 to 70 ms, Zed 0.4 s, VS Code 1.3 s. Different methods and hardware, so no ranking is claimed.

## Caveats

Everything here is on the `dev` branch. Several features need plugin `dev` branches that are not pushed or pinned in `lazy-lock.json`; an installed xynovim does not have them yet. With the pinned plugins the whole suite (57 files, 2026-11-13) had 1287 passed, 0 failed and 49 skipped; with the plugin `dev` clones 1304 passed, 0 failed, 32 skipped. That says the code does what its tests check, not that it beats anything.
