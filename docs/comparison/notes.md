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
| Helix | no AI agent merged (Copilot, ACP and Landlock-sandbox PRs 15955, 16312, 15983 closed unmerged, 2026); workspace trust merged to master 2026-03-26 / 2026-06-20 but in no tagged release (latest 25.07.1); default level `servers` still starts language servers. See security-and-features.md rows 15-16. |
| Neovim agent plugins (avante, codecompanion, claudecode, sidekick, opencode, 99, claude-code.nvim) | none has a sandbox module (git-tree search, 2026-11-12); avante auto-approves all tools by default; codecompanion has Ask/Auto/YOLO modes. security-and-features.md row 15. |
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

## 8. rust-analyzer memory and startup on small crates: what is published (searched 2026-11-12)

No vendor or maintainer figure for a hello-world crate exists for Zed, VS Code, RustRover or Helix. What was found, all [pc]:

| Item | Figure | Quality | Source |
|---|---|---|---|
| rust-analyzer, new minimal Tauri 2 project in VS Code on Windows | about 2.5 GB, persists after `cargo clean` | single user report, closed issue, heavy dependency tree (not a small crate) | https://github.com/rust-lang/rust-analyzer/issues/20028 (2025-06-17) |
| rust-analyzer, Zed repository | 12 GB idle, up to 16 GB while indexing | big workspace | https://github.com/rust-lang/rust-analyzer/discussions/20871 |
| rust-analyzer typical workspace | 1-4 GB | issue comment, old | https://github.com/rust-lang/rust-analyzer/discussions/20871 and linked threads |
| RustRover vs VS Code vs Neovim, "hello world"/idle | RustRover about 1.2 GB, VS Code about 400 MB, Neovim about 50 MB (one guide); another post 1.2 / 1.8 / 0.24 GB with an impossible Rust version in its text | no method, internally inconsistent: do not cite as evidence | https://dev.to/johalputt/benchmark-vs-code-20-vs-jetbrains-rustrover-10-vs-neovim-010-for-rust-196-development-1430 , https://devpro-portal-com.pages.dev/languages/rust/rust-ide-battleground-vscode-rustrover-neovim |
| Zed's own comparison page | RustRover "slow startup, high memory/CPU usage (JVM-based)"; Zed "instant startup, minimal resource use"; no numbers | vendor marketing | https://zed.dev/compare/rust-rover (updated 2026-05-01) |
| Helix | nothing found; Helix issues search for "rust-analyzer memory" returns unrelated results | n/f | gh search, 2026-11-12 |
| xynovim (measured here) | 702 MB idle on a one-dependency crate (825 MB before the arena cap); `cargo.sysroot=null` 249 MB | [m], docs/bench/perf-2026-11.md | local |

Reading: rust-analyzer is the same engine in VS Code, Zed (default) and Helix, so on a small crate they should be near each other and near xynovim's 702 MB; xynovim cannot claim "ahead" on rust-analyzer memory against them without running them side by side. Where xynovim can be ahead is that it caps the allocator arenas and offers a lower-memory sysroot setting by default-off (the 249 MB figure); RustRover does not use rust-analyzer (JetBrains blog says so per search summary) and its figure is unmeasured here. Status: **unknown against Zed/VS Code/Helix (same engine), behind-or-unknown against RustRover memory (published 1.2 GB claim is unreliable)**. Plan in gaps-and-plan.md item 7.

## 9. Debugger and test panel UX complaints (GitHub issues, vendor forums, rust-lang forum; no Reddit; retrieved 2026-11-12)

| Product | Complaint (source) | Reading |
|---|---|---|
| nvim-dap-ui | Long values are hard to read: issue 377 "Recommendation to handle long debug line" (open, 2024-07, screenshot of a long line); issue 286 watch-list formatting options, asked for RemedyBG-style filters for matrices and multi-line strings (open, 2023-08); issue 309 disassembly view (open, 17 reactions); issue 167 inconsistent default icons (closed, 3 reactions); issue 380 more visible debug cursor (closed). https://github.com/rcarriga/nvim-dap-ui/issues | The readability gap is value display (long, multi-line, nested) and no disassembly; xynovim ships dap-ui, so it inherits all of these. |
| neotest (the test panel in nvim) | Output panel position: issue 123 asks for a fixed bottom panel (16 reactions, closed), issue 319 asks to move it to the side because test output is long (open, 10 reactions); issue 441 `Neotest Summary` freezes Neovim (open, 14); issue 230 key-map help in summary (14). https://github.com/nvim-neotest/neotest/issues | Layout and discoverability complaints. |
| CodeLLDB (VS Code Rust debugging) | Variables view for Rust types: issue 827 enum variant name not shown for recursive enums (24 reactions, closed); issue 1166 no pretty-printing of Vec and HashMap in 1.11.0 on Windows (open, 6); issue 67 use Rust's `Debug` to display values (open, 11); issue 726 cannot inspect correct value. https://github.com/vadimcn/codelldb/issues | The same LLDB data formatters xynovim's setup uses (codelldb) have these failures; xynovim shares them. |
| Zed debugger | Hover values: issue 32932 (177 reactions) asked for hover variable values, fixed by PR 53198 "debugger: Add hover tree UI" (2026-04, 87 reactions): expandable tree, wrapping for long values. Issue 36516 config options ignored (open). https://github.com/zed-industries/zed/issues/32932 , https://github.com/zed-industries/zed/pull/53198 | Zed now has the best hover story; Zed's compare page says its debugging does not yet match RustRover. |
| RustRover | rust-lang forum: variables not available where expected when stepping, `Option<T>` on Windows needs many expansion levels, breakpoints failing to trigger, attributed to LLDB (https://users.rust-lang.org/t/rust-rover-users-how-do-you-rate-it/119074). JetBrains support thread "RustRover does not properly display data in debug": Vec<char> contents missing, fixed in 2024.3.1 (https://intellij-support.jetbrains.com/hc/en-us/community/posts/23267266917906). rust-lang forum: a String shown as a Python TypeError and `jb_renderers_set_markup` invalid (https://users.rust-lang.org/t/debugger-in-rustrover-spews-errors-about-jb-renderers-set-markup/122397). nextest runs cannot be debugged (https://nexte.st/docs/integrations/rustrover/). | RustRover's debugger is rated best by Zed's page, yet users report the same LLDB formatting problems. Test runner: no complaint found; only the nextest-debug gap. |
| VS Code | Same CodeLLDB issues as above. No separate test-panel complaint text read. | unknown for test panel. |

Net: the "unknown" for readability is now a documented set of complaints, mostly about value display (long, nested, Rust container types) and test output placement. They bear on all editors, so a fix is a way to be ahead. Plan: gaps-and-plan.md items 3 and 4.

## 10. What RustRover offers that others lack, and a credible xynovim answer (docs read via search summaries, 2026-11-12; JetBrains blog pages returned HTTP 403 to fetch)

| RustRover feature | Evidence | Others | xynovim today | Credible plan |
|---|---|---|---|---|
| Cargo.toml: crate-name/version completion, inlay hints with locked and latest versions, inspections, one-click fixes, auto-add dependency from code | https://www.jetbrains.com/help/rust/toml-files.html | VS Code "Dependi", crates.nvim, taplo | crates.nvim (version virtual text, upgrade actions, from LazyVim lang.rust) plus xyno-crates (preview + typosquat on add) | Likely tied on hints already (not compared side by side); verify crates.nvim shows locked vs latest like RustRover, and add the missing piece to xyno-crates only if it does not. |
| Macro expansion, recursive and single-step, in quick docs | https://www.jetbrains.com/help/rust/viewing-reference-information.html | rust-analyzer `expandMacro` is in VS Code/Zed(LSP)/Neovim | `<leader>rm` recursive expand (keymaps.lua:132) | Add a hover/float preview on macro call and a single-step variant if the LSP supports it. Step-through debugging inside macro expansions: no DAP support; not credible. |
| Database tools, HTTP client (.http files) | https://www.jetbrains.com/help/rust/http-client-in-product-code-editor.html ; DB reworked in 2024.2 | VS Code extensions; nvim: vim-dadbod-ui, kulala.nvim | none | Document recommended optional plugins (kulala.nvim for .http, vim-dadbod-ui); not a Rust differentiator, low priority; adding them to the starter as opt-in is credible, building one is not. |
| Profiler | RustRover docs show a CPU snapshot for IDE issues only; no Rust profiler page found in 2026.2 search | cargo flamegraph, samply | `:RustTargets` samply and flamegraph entries | Already tied; add a flamegraph viewer hand-off (open the SVG/Firefox Profiler URL) only if measured value. |
| nextest integration with Test tool window | https://blog.jetbrains.com/rust/2026/04/03/rustrover-2026-1-professional-testing-with-native-cargo-nextest-integration/ (via search) | neotest-rust, rustaceanvim | neotest + nextest if configured | Verify neotest-rust nextest path; debug-with-nextest is an advantage opportunity (RustRover cannot). |
| Debugger renderers and expression evaluation (2025.3 new LLDB engine) | https://www.jetbrains.com/help/rust/rust-switch-debuggers-and-renderers.html | CodeLLDB | dap-ui + codelldb | Value formatting layer (gaps-and-plan item 3). |
| Axum endpoint discovery (2026.2) | https://alternativeto.net/news/2026/7/rustrover-2026-2-axum-endpoint-discovery-ferrocene-support-and-ai-integration/ | none found | `routes` spec exists in xyno-rust (route scan) | Compare once routes UI is read; unknown. |

## Gaps

- Resolved on 2026-11-12 in sections 8-10: agent plugins, Helix, small-crate figures (none exist), debugger and test complaints, RustRover-only features. Remaining unknowns are listed in gaps-and-plan.md.
- No screenshots of other editors' real Rust editing/diagnostics/debugger/test panels (needs install or in-product media; not captured).
- Official startup/memory pages for JetBrains and VS Code not found; Helix performance figures absent.
- Zed docs fetched did not cover call hierarchy, coverage, or find references.
