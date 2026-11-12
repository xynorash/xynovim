# Research notes (retrieved 2026-11-12)

Legend: [pc] published claim, not reproduced. [m] measured here. "n/f" = not found in sources fetched.

## 1. Rust features

| | Refactor / assists | Find usages | Debugger | Tests + coverage | Inlay hints | Call hierarchy | Run/debug gutter |
|---|---|---|---|---|---|---|---|
| RustRover | yes, incl. for_each<->for transform (2025.3.4, Feb 2026) | yes | built-in, LLDB (+GDB on Linux), breakpoints, watches, memory/disassembly views | gutter Run, Run tool window; "Run with Coverage" + Coverage tool window | yes ("inlined hints") | added in 2026.1 per a release-notes summary (third-party ComponentSource) | yes, click in gutter: Run / Debug / Run with Coverage |
| VS Code + rust-analyzer | assists, auto-import, SSR, move item, rename | Find All References | via extensions (CodeLLDB etc.); rust-analyzer page does not describe it | Run/Debug code lenses; coverage n/f | yes (configurable) | n/f on features page (LSP supports it) | "Run"/"Debug" annotations above items |
| Zed | rust-analyzer code actions (page does not list) | n/f on page | CodeLLDB primary, GDB (not Apple silicon); F4 `debugger: start`; `.zed/debug.json` | tasks via tree-sitter + LSP tasks; coverage n/f | yes, via rust-analyzer init options | n/f | tasks/runnables, n/f for gutter |
| Helix | LSP code actions only | LSP | DAP "experimental" (25.07 notes) | none built in | LSP | LSP | none |
| LazyVim (lang.rust extra) | via rust-analyzer | yes | nvim-dap | neotest | yes | via LSP | no gutter UI by default |
| AstroNvim | astrocommunity.pack.rust (contents not listed on page) | n/f | n/f | n/f | n/f | n/f | n/f |
| NvChad | page does not mention Rust | - | - | - | - | - | - |
| kickstart.nvim | page does not mention Rust (examples: TypeScript, Go) | - | - | - | - | - | - |
| rustaceanvim | via rust-analyzer | yes | `:RustLsp debuggables` / `debug`, needs nvim-dap + lldb-dap/codelldb | `:RustLsp testables`, neotest adapter included, background failures as diagnostics | yes | n/f on page | `runnables` / `run` pickers, no gutter icons |
| xynovim | rust-analyzer + code actions (README says "No code actions available" screenshot for extract in demo) | yes | dap-ui (stopped screenshot in README) | neotest + coverage bars | yes | n/f here, verify | n/f, verify |

Rows for xynovim come from its own README/website, not re-measured here. LazyVim/AstroNvim rows marked without a cell value were not stated on the pages fetched; do not read them as "absent".

Sources: https://www.jetbrains.com/help/rust/quick-start-guide-rustrover.html (modified 2026-11-03), https://rust-analyzer.github.io/book/features.html, https://zed.dev/docs/languages/rust, https://docs.helix-editor.com/lang-support.html, https://helix-editor.com/news/release-25-07-highlights/, https://github.com/mrcjkb/rustaceanvim, https://www.lazyvim.org/, https://docs.astronvim.com/, https://github.com/NvChad/NvChad, https://github.com/nvim-lua/kickstart.nvim, https://www.componentsource.com/product/rustrover/releases (third party, call hierarchy 2026.1).

## 2. UI/UX strengths (from the screenshots taken)

- RustRover: gutter run/debug/coverage icons, Cargo tool window, dedicated Run, Debug, Coverage tool windows (quick start guide). Free for non-commercial use (shown on jetbrains.com/rust).
- VS Code: rust-analyzer extension is the recommended Rust extension, the older rust-lang.rust one is deprecated (vscode docs page).
- Zed: landing pitches fast, agentic, collaborative; minimal UI, agents panel beside editor.
- Helix: selection-first modal editing, multiple selections, tree-sitter; built-in file explorer since 25.07.
- LazyVim/AstroNvim/NvChad: preconfigured IDE-like chrome (dashboard, file tree, statusline); NvChad advertises about 90 themes.
- kickstart: deliberately minimal, teaching config.
- rustaceanvim: no UI of its own, commands and pickers.
- xynovim: Island Dark theme, two-tier diagnostics, sticky scope, dap-ui, neotest coverage (own README).
Screenshots of the default Rust editing UI per product could not be taken without installing them; only landing/docs views exist (see README.md).

## 3. Startup / memory / latency (all unreproduced)

| Item | Figure | Label | Source (retrieved 2026-11-12) |
|---|---|---|---|
| Zed 1.0 startup | 0.4 s, input latency ~2 ms, 120 fps | [pc], attributed to Zed team by secondary coverage | https://noqta.tn/en/news/zed-editor-1-0-stable-rust-ai-coding-2026 (Zed 1.0 shipped 2026-04-29 per same coverage) |
| Zed vs VS Code startup | 0.6 s vs 1.3 s | [pc], blog, July 2026 retest | https://tech-insider.org/zed-vs-vscode-2026/ |
| Zed vs VS Code idle memory | 142 MB vs 730 MB; another blog 222 MB vs 3,549 MB | [pc], conflicting, low reliability | webpronews.com, tech-insider.org |
| Zed vs VS Code typing latency | 2 ms vs 12 ms | [pc], secondary | tech-insider.org |
| NvChad startup | "around 0.02 secs ~ 0.07 secs" | [pc], official README | https://github.com/NvChad/NvChad |
| LazyVim startup | "Blazingly fast", no number | no figure | https://www.lazyvim.org/ |
| AstroNvim | no figure | n/f | https://docs.astronvim.com/ |
| Neovim configs generally | 20-67 ms for personal configs | [pc], self-reported | nvimdots.lua readme, aliquote.org |
| RustRover memory | 2 GB free RAM min, 8 GB system RAM | [pc], third party mirror of requirements | componentsource.com (official page not confirmed) |
| RustRover startup, Helix, VS Code startup | none found | n/f | - |
| xynovim | diagnostics: type errors about 0.01-0.15 s, clippy 0.56 s median (website text) | [pc], author's own, not re-measured | https://xynorash.github.io/xynovim/ |

Caution: several Zed/VS Code blog numbers cite product versions that could not be verified; treat as direction only. A fair table needs [m] runs (hyperfine, nvim --startuptime) on one machine; none done for third parties.

## 4. Security features for AI agents and extensions

| Target | What the docs say |
|---|---|
| RustRover (Junie) | Safe / Auto / Brave approval modes, Action Allowlist; JetBrains advises against Brave. No OS sandbox or network control found. https://www.jetbrains.com/help/ai-assistant/junie-agent.html |
| VS Code | Workspace Trust restricted mode: agents disabled, terminal/tasks/debug prompt for trust, workspace settings pointing to executables disabled, extensions limited; but cannot stop a malicious extension. Terminal auto-approve rules (`chat.tools.terminal.autoApprove`), Autopilot/Bypass modes. Agent terminal sandbox in Preview (macOS, Linux/WSL2 with bubblewrap+socat), `chat.agent.sandbox.enabled`; covers shell subprocesses only, not built-in file tools. https://code.visualstudio.com/docs/editing/workspaces/workspace-trust, https://code.visualstudio.com/docs/agents/run/agent-sandboxing |
| Zed | Worktree trust gates project-local instructions/skills; tool permissions + agent profiles; API keys in system keychain; extensions run as WebAssembly with capability grants (`process:exec`, `download_file`, `npm:install`), restrictable via `granted_extension_capabilities`. No agent sandbox or network control documented. https://zed.dev/docs/ai/privacy-and-security, https://zed.dev/docs/extensions/capabilities |
| Helix | no AI agent features or plugin system found (plugin system absent per third-party review, unverified) |
| Neovim distros / rustaceanvim | no sandbox or trust model of their own; Neovim `exrc` is a per-project config opt-in (rustaceanvim README points to it). Not stated in sources: whether rust-analyzer config in untrusted repos is gated. |
| xynovim | AI agent (99 with Claude Code) runs inside bubblewrap on Linux: read-only FS except project, creds hidden, env scrubbed, .git/hooks locked, Local History snapshot per request; refuses to start without a sandbox unless opted out. Network stays open. Author's own claim, from the website, not re-verified. |

Takeaway [from sources]: only VS Code (preview) and xynovim document an OS-level sandbox for agent commands; neither restricts network by default (VS Code sandbox network behaviour not read in detail).

## 5. Customization model

- RustRover: GUI settings, run configs, code style/templates, plugins.
- VS Code: settings.json, extensions marketplace.
- Zed: settings.json, extensions (WASM, no custom UI panels per secondary sources).
- Helix: config.toml, languages.toml; no stable plugin system.
- LazyVim: lazy.nvim specs; extras. AstroNvim: lua/plugins, community.lua, polish.lua. NvChad: gitignored custom config over imported base. kickstart: fork/template and edit init.lua; NVIM_APPNAME. rustaceanvim: vim.g.rustaceanvim table.
- xynovim: LazyVim-based, one spec per concern, own xyno-*.nvim plugin repos.

## 6. xynovim self-observations to act on (measured here, 2026-11-12)

- Clipboard: in headless nvim 0.12.6 on this machine (Wayland, session wayland-1), `has("clipboard")` is 0, `vim.g.clipboard` is nil and `clipboard` option is empty even after 3 s. `wl-copy`, `xclip` and `xsel` are not installed. xyno-clipboard.nvim is documented as an OSC 52 provider for tmux/SSH/herdr only (README line 62). So local Wayland has no provider: `"+y` does not reach the system clipboard. Not fixed here; cause (missing wl-clipboard vs plugin gating) is not fully confirmed.
- Competitors' defaults mostly work with system clipboard out of the box (not verified here).
- Gaps vs RustRover: gutter run/debug icons, call hierarchy, refactoring menu UI (not verified in xynovim).

## 7. Performance re-measured (2026-11-12, [m] unless marked)

Details and method: `docs/bench/perf-2026-11.md`. rust-analyzer idle RSS on a one-dependency crate 702 MB (825 MB before the `MALLOC_ARENA_MAX=2` change), about 450-600 MB of it sysroot analysis (`cargo.sysroot=null`: 249 MB). No published small-crate figure was found (searches 2026-11-12: users.rust-lang.org thread 50420, rust-analyzer discussion 20871 and thread 133914 are 2.5-13 GB big-workspace reports); Neovim startup: 67.4 ms +- 1.0 for `hyperfine nvim --headless +qa` of one personal lazy.nvim config, hardware unstated (https://aliquote.org/post/lazy-nvim/ , [pc]) against 35 ms UIEnter / 64 ms ready here (TUI in tmux, a different method). Edit to clippy diagnostic: 570 ms (debounce 500 + 70); VS Code / Zed / rust-analyzer defaults run clippy on save only [pc, from their docs].

## Gaps

- No screenshots of other editors' real Rust editing/diagnostics/debugger/test panels (needs install or in-product media; not captured).
- Official startup/memory pages for JetBrains and VS Code not found; Helix performance figures absent.
- Zed docs fetched did not cover call hierarchy, coverage, or find references.
