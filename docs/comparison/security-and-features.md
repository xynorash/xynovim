# Security and feature comparison: xynovim vs RustRover, VS Code, Zed, Helix, Neovim distributions

Retrieved: 2026-11-12 (all URLs below were fetched or searched on that date; vendor docs change often). Companion to [notes.md](notes.md).

## How to read this

- **Verdict** is `ahead`, `tied` or `behind` against the strongest competitor named in the row, and only says `ahead` where a cited page shows the competitor lacks the feature, or lacks it by default. A page that is silent is recorded as "not documented", which is weaker than "absent"; such rows say so.
- xynovim claims cite the plugin README and the commit that last touched the behaviour (`~/projects/xyno-plugins/<plugin>`, branch `dev`). Nothing here was re-run for this document; it is a research document (see "Not verified").
- "Distros" = LazyVim, AstroNvim, NvChad, kickstart.nvim, rustaceanvim. For most items they offer nothing beyond Neovim itself, so the cell says what Neovim core or the distro docs show.
- Each table is transposed (one row per column the brief asked for) because nine columns do not fit a Markdown page.

## Summary

| # | Item | Verdict | One-line reason |
|---|---|---|---|
| 1 | AI-agent sandbox | tied (split) | Ahead on Linux defaults (credentials hidden, fail closed); behind on macOS/Windows and credential masking |
| 2 | Network egress control | tied | Default-deny like Zed, Claude Code and Codex; ahead of VS Code and Junie CLI (open by default) |
| 3 | Workspace trust | tied (narrow edge) | Restricted mode (2026-11-12, dev): rust-analyzer without build scripts / proc macros / cargo check, no clippy, one prompt per workspace, restart on trust; Zed and RustRover hold the language server back entirely, xynovim keeps navigation working |
| 4 | Policy preview before running an agent | ahead (narrow) | Full plan shown and confirmed before first launch; others show it on demand |
| 5 | Exception approval log | ahead (by documentation) | Append-only JSON log of approved/refused/revoked; none of the competitor pages describe one |
| 6 | Local history | ahead | Whole-tree snapshots, 30 days / 1000 per branch, secrets excluded by default; storage in `.git` is a documented cost |
| 7 | Secrets handling in snapshots | ahead (name-based only) | Default exclude list; VS Code exclude is user-set, JetBrains page silent; content is not scanned |
| 8 | Hostile repo config handling | tied | Own git calls hardened; Helix/Zed/RustRover cover the whole editor |
| 9 | Async metadata / non-blocking loading | tied | Async layer; competitors also load in the background; no measured comparison |
| 10 | Import management | tied (split) | Ranked per-project memory and async organize; RustRover has import-on-paste and an exclusion table |
| 11 | Macro expansion safety | tied | `cargo expand` is gated and rust-analyzer runs with `procMacro.enable = false` in an untrusted workspace (spec-checked with a canary `build.rs`) |
| 12 | Dependency add confirmation / typosquat | ahead (add time) | Preview + typosquat + age check; no competitor page mentions one; continuous advisories are tied |
| 13 | Template supply chain | ahead (narrow) | Pinned commit, `https` only; LazyVim starter and RustRover custom templates document no pin |
| 14 | `:checkhealth` equivalents | tied | rustaceanvim, kickstart and LazyVim also ship health checks; xynovim has one per plugin |
| 15 | Sandboxing in Neovim agent plugins | **ahead** | none of seven popular Neovim agent plugins ships an OS sandbox; two default to auto-approve or offer a YOLO mode |
| 16 | Helix agent, sandbox and trust features | tied (trust: Helix ahead on the language server, unreleased) | no agent, no sandbox merged; workspace trust is on master only, not in the latest release 25.07.1 |

Two rows are `behind` (3, 11), both for the same reason; the fix is listed under row 3.

---

## 1. AI-agent sandbox

| Field | Content |
|---|---|
| xynovim | `xyno-sandbox.nvim` (5fab916): runs a command-line agent inside bubblewrap; filesystem read-only except project and scratch; credential paths hidden; secret env vars stripped; refuses to start without a working sandbox (a real `bwrap` probe, not "bwrap on PATH"); `allow_unsandboxed` and `sandbox=false` are explicit opt-outs that warn. Linux only; macOS and Windows are refused. README "Limits" says it is a denylist on a read-only view, "not a security boundary against a determined attacker". |
| RustRover / JetBrains | IDE agent (Junie / AI Assistant): approval modes Safe, Auto, Brave; the Junie IDE page describes no OS sandbox, network restriction or logging; secrets control is `.aiignore` only. Junie CLI has an opt-in sandbox (`srt`, bubblewrap/Seatbelt), off by default, reads unrestricted except `~/.ssh` (only `config` and `known_hosts`), network unrestricted by default, and its page says it is "not hardened isolation like a container or VM". |
| VS Code | Agent terminal sandbox (macOS Seatbelt, Linux/WSL2 bubblewrap, Windows experimental). `chat.agent.sandbox.enabled` defaults `off`. Default fs: working directory read/write; `allowDevToolAccess` defaults `true` and the page says it includes registry tokens; no default protection of `~/.ssh` is described on the sandbox page (add to `deniedPaths`). `allowUnsandboxedCommands` defaults `true` (the agent can ask to leave the sandbox). Has credential masking (`credentials.envVars`, placeholders swapped on HTTPS to `injectHosts`), managed-policy enforcement (Preview), and `/sandbox policy`. Not a VM or user-account boundary (the page says so). |
| Zed | Zed Agent `terminal` and `fetch` tools sandboxed by default since 1.14 (Seatbelt / bubblewrap; Windows only inside WSL). Default: reads most of the filesystem (the docs do not address `~/.ssh`), writes only in project dirs, `.git` read-only, network blocked, unix sockets blocked. Escalation prompts with a required `reason`, once/thread/always. On Linux, if the sandbox cannot be created "Zed may run the command unsandboxed and show a warning". Does not cover language servers (the docs name `rust-analyzer` running proc macros), external agents, tasks or the regular terminal. |
| Helix | No agent. Not applicable. |
| Distros | LazyVim installation page, kickstart `init.lua`: no agent sandbox mentioned. Not exhaustively searched. |
| Claude Code (reference) | Bash sandbox off by default; bubblewrap/Seatbelt via `@anthropic-ai/sandbox-runtime`; reads allowed across most of the machine by default, and the docs say that "still allows reading credential files" such as `~/.ssh`; opt in with `filesystem.denyRead` / `sandbox.credentials`. `dangerouslyDisableSandbox` retry unless `allowUnsandboxedCommands: false`. Built-in file tools, hooks, MCP and LSP servers are outside it. |
| Codex (reference) | `workspace-write` is the recommended mode for version-controlled folders; `.git`, `.agents`, `.codex`, `.aws` read-only inside writable roots; bubblewrap + seccomp on Linux, Seatbelt on macOS; network off by default. The page does not say whether `~/.ssh` is readable. Docker/containers may block `bwrap`; suggested fallback is `danger-full-access` inside a container. |
| **Verdict** | **tied (split)**. Ahead on Linux defaults: credentials hidden by default (VS Code, Zed, Claude Code, Junie CLI document reads of most of the filesystem), env scrubbing, fail-closed instead of an unsandboxed fallback (Zed may fall back; VS Code `allowUnsandboxedCommands` defaults `true`). Behind on platform (Linux only), on credential masking (VS Code, Claude Code), and in that it is a wrapper you must start the agent through, not an agent-integrated default. |
| Next improvement | (a) Seatbelt backend for macOS, which would remove the largest gap; (b) credential masking: have the in-Neovim proxy inject an API header so the agent never holds its token (needs TLS termination; a security design question, not a quick change); (c) document the Zed/VS Code `rust-analyzer`-outside-the-sandbox caveat in the README, because xynovim has the same one (see row 11). |
| Sources | https://code.visualstudio.com/docs/agents/run/agent-sandboxing.md ; https://code.visualstudio.com/docs/agents/concepts/trust-and-safety.md ; https://zed.dev/docs/ai/sandboxing.md ; https://zed.dev/blog/sandboxing (2026-08-05) ; https://code.claude.com/docs/en/sandboxing ; https://learn.chatgpt.com/docs/agent-approvals-security.md ; https://junie.jetbrains.com/docs/junie-cli.html ; https://www.jetbrains.com/help/ai-assistant/junie-agent.html ; https://www.lazyvim.org/installation ; https://raw.githubusercontent.com/nvim-lua/kickstart.nvim/master/init.lua . Retrieved 2026-11-12. VS Code's own page still labels platforms Preview; a trade-press article claims GA for Agent Host sessions, which the docs do not repeat (https://visualstudiomagazine.com/articles/2026/10/15/microsoft-and-github-keep-giving-ai-agents-more-power-and-more-restrictions.aspx, not relied on). |

## 2. Network egress control

| Field | Content |
|---|---|
| xynovim | `bwrap --unshare-net`; the only way out is a unix socket to a CONNECT-only filtering proxy in Neovim (pure Lua); hostname allowlist (default: the agent API host, token refresh, crates.io hosts; `github.com` not included); refuses IP literals, loopback/private/link-local resolutions (cloud metadata), plain HTTP; DNS done by the proxy for allowed names only; fails closed if the namespace, relay or listener cannot be created. Blocked hosts are logged once per host and launch. README lists what breaks (tools ignoring `HTTPS_PROXY`, UDP, ssh) and the residual exfiltration path through an allowed host. |
| RustRover / JetBrains | IDE agent: not covered on the Junie IDE page. Junie CLI: "Network access is unrestricted by default"; optional `allowedDomains` in `~/.junie/sandbox.json`. |
| VS Code | `chat.agent.sandbox.network.allowNetwork` defaults `true`; `allowedDomains` / `deniedDomains` default empty; local proxy tunnels HTTPS without decrypting; the page stresses that "enabling sandboxing doesn't block network access by default". Local network blocked by default. |
| Zed | Network blocked by default for the sandboxed tools; host-specific approval via proxy on macOS/Linux (`agent.sandbox_permissions.network_hosts`, wildcards); WSL is all-or-nothing; SSH/raw-socket tools may fail. |
| Helix | Not applicable. |
| Distros | Not applicable (no agent). |
| Claude Code / Codex (reference) | Claude Code: no direct route, hostname-checking proxy, `allowedDomains` starts empty, prompts on a new domain in manual modes, refuses link-local metadata; warns that without TLS inspection domain fronting can bypass the allowlist. Codex: network off by default; `network_proxy` allowlist feature is off by default; DNS checks "best-effort". |
| **Verdict** | **tied**. Equal in model to Zed, Claude Code and Codex (default-deny, hostname-based proxy, same residual limits, which xynovim documents too). Ahead of VS Code and Junie CLI, which are open by default. |
| Next improvement | Live approve-on-block: today a blocked host is logged and the user adds it through the preview (`e`) on the next launch; Zed and Claude Code can ask at the moment of the request. Add a notification action that approves "this launch" without restarting the agent. |
| Sources | Same as row 1 plus https://developers.openai.com/codex/agent-approvals-security (redirects to learn.chatgpt.com). Retrieved 2026-11-12. |

## 3. Workspace trust

| Field | Content |
|---|---|
| xynovim | `xyno-rust.nvim` (7016d47): runs of targets, tests, benches, `:RustTools` entries and `:ActJob` ask once per workspace root (trust / trust everything under parent / once / do not run); store `0600`-style JSON under `stdpath("state")`, `:RustTrust` lists and revokes; reading `cargo metadata --no-deps` and `cargo locate-project` is checked not to run `build.rs` or rustc wrappers; the resolving `cargo metadata` that `crate_meta` needs is run with `RUSTC*` overridden in untrusted workspaces. **Restricted mode in the main config (`lua/config/workspace_trust.lua`, 2026-11-12, `dev`, not pushed):** `plugins/rustaceanvim.lua` merges `ra_overrides(root)` plus `checkOnSave = false`, `cargo.loadOutDirsFromCheck = false` and cleared `RUSTC`/`RUSTC_WRAPPER`/`RUSTC_WORKSPACE_WRAPPER` (`cargo.extraEnv`) into the server settings of a workspace nobody trusted; `plugins/bacon-ls.lua` does not start clippy there. One prompt per workspace and session (trust / trust everything under the parent / run once / stay restricted; a refusal prints the `:RustTrust add` hint); the answer is remembered in the shared trust file; `:RustTrust add` or revoke (also from another Neovim, by watching the file) restarts rust-analyzer and starts or stops bacon-ls; the status line shows `RESTRICTED`; `:checkhealth xynovim` has a section; `vim.g.xynovim_workspace_trust = false` turns it off. Checked by `tests/workspace-trust_spec.lua` (14 specs; two use a real rust-analyzer on a crate whose `build.rs` writes a canary file: absent while restricted, present after trusting). Needs the xyno-rust.nvim commit with the trust module and `lsp_status.add_part`, which `lazy-lock.json` does not pin yet (without it nothing is gated). Neovim core: `'exrc'` is off by default and project files run only if in the trust list (`:trust`). |
| RustRover | Safe Mode for untrusted projects: Cargo import blocked (build scripts and macros do not run), rustc / cargo-check / Clippy / Rustfmt disabled, startup tasks disabled, VCS support fully disabled, file watchers and DB connections off; "Trust project" and Trusted Locations. |
| VS Code | Restricted Mode: tasks, debugging, terminal, workspace settings that can point at executables are limited; extensions that have not opted in are disabled; **agents are disabled** in restricted mode; Trusted Folders. The pages do not say what rust-analyzer does in restricted mode (not documented). |
| Zed | Worktree trust: all worktrees start in Restricted Mode; `.zed/settings.json`, project tasks and debug configs are not applied; **language servers and MCP servers are not spawned** until trusted; trust is persisted per worktree or per parent directory. |
| Helix | Workspace trust (docs on `master`, release not identified): gates language servers and DAP (configurable `level`), local `.helix/config.toml` and `languages.toml`, and git config filters; default `level = "servers"` still starts language servers, from `$PATH`; `.helix/` is hashed so edits after trusting make it stale. |
| Distros | Neovim `'exrc'`/`vim.secure` trust list. rustaceanvim health check and docs fetched mention no trust gate (not documented). LazyVim/kickstart: no trust UI. |
| **Verdict** | **tied** (was behind before the restricted mode; the new text of the xynovim row replaces the old "yes, because rust-analyzer starts regardless"). For the question "does opening an untrusted Rust repo run its build scripts and proc macros", RustRover and Zed answer no until trusted; Helix can (level `none`); VS Code limits it. xynovim answers yes, because rust-analyzer starts regardless. It is ahead of the other Neovim setups (they have nothing comparable) and of Helix's default on the explicit cargo-run gate, but that is not the baseline asked for. |
| Next improvement (what keeps it from `ahead`) | Not covered, unlike RustRover/Zed/Helix: VCS config and startup tasks in restricted mode, project-local `.cargo/config.toml` `[env]` / `rust-toolchain.toml` toolchain download, no staleness check of a trusted workspace whose build.rs changed (Helix hashes `.helix/`). Done: in the main config's rustaceanvim `server.settings`, merge `require("xyno_rust.trust").ra_overrides(root)` when the root is untrusted, restart the server on trust, statusline marker and a canary-`build.rs` spec (all in `tests/workspace-trust_spec.lua`). |
| Sources | https://www.jetbrains.com/help/rust/project-security.html ; https://code.visualstudio.com/docs/editing/workspaces/workspace-trust.md ; https://code.visualstudio.com/docs/agents/concepts/trust-and-safety.md ; https://zed.dev/docs/worktree-trust ; https://docs.helix-editor.com/master/workspace-trust.html ; Neovim 0.12.6 runtime `doc/options.txt` (`'exrc'`), same text as https://neovim.io/doc/user/options.html ; xyno-rust README "Workspace trust". Retrieved 2026-11-12. |

## 4. Policy preview before running an agent

| Field | Content |
|---|---|
| xynovim | The preview is built from the same plan that becomes the `bwrap` argv: writable, read-only and guarded paths, hidden credentials, names (never values) of stripped env vars, network `FILTERED` + allowlist with provenance, and a separate line `Agent permission prompts: OFF (--dangerously-skip-permissions)`. `preview = "once"` (default, per project) / `"always"` / `"never"`; interactive float, `<CR>` launches, `q` cancels; headless never waits. `:XynoSandboxPolicy` shows it any time. |
| RustRover / JetBrains | Not documented for the IDE agent; Junie CLI keeps policy in `~/.junie/sandbox.json` (a file, not a preview). |
| VS Code | `/sandbox policy` (Copilot harness sessions) writes `sandbox-policy.md` with the effective filesystem and network policy; on demand, no model turn. The page says it does not describe previewing each command before it runs. |
| Zed | Hover the padlock in the thread for the sandbox state; each escalation prompts with a reason before it runs. |
| Helix / Distros | Not applicable. |
| Claude Code / Codex (reference) | `/sandbox` panel (Mode, Overrides, Config tabs with resolved settings) and `claude doctor`; Codex `/permissions`. On demand. |
| **Verdict** | **ahead (narrow)**: no competitor page describes a confirm-before-first-launch gate that shows the whole effective policy, including the permission-bypass flag. Inspection on demand is tied (VS Code, Claude Code, Zed all have it). Caveat: the preview is a float that needs a UI and a user who reads it. |
| Next improvement | Diff against the previous approved plan ("what changed since you last approved") so `once` does not hide a later widened policy. |
| Sources | VS Code agent-sandboxing page; https://code.claude.com/docs/en/sandboxing ; https://zed.dev/docs/ai/sandboxing.md ; https://learn.chatgpt.com/docs/agent-approvals-security.md ; xyno-sandbox README "Policy preview". Retrieved 2026-11-12. |

## 5. Exception approval log

| Field | Content |
|---|---|
| xynovim | Every exception decision (`approved`, `refused`, `revoked`; kinds `env`, `unhide`, `writable`, `host`) is appended to `stdpath("state")/xyno-sandbox/exceptions.log` as one JSON object (UTC `ts`, project, path/name/host, scope); variable values are never logged; blocked destinations are logged too; remembered approvals are listed and revoked in `:XynoSandboxApprovals`; state files are `0600` and outside every writable path so the agent cannot edit its own approvals. Limit: "the log tells what and when, it does not make the exception safe." |
| RustRover / JetBrains | Junie: "Always allow" writes `~/.junie/allowlist.json`; the IDE page describes no audit log. |
| VS Code | The trust-and-safety page says it does not describe an audit log of approval decisions; points to checkpoints and session history. |
| Zed | "Always" approvals are saved to `settings.json`; the sandbox page does not describe logging. |
| Helix / Distros | Not applicable. |
| Claude Code / Codex (reference) | Claude Code: "don't ask again" saves a rule to settings; no audit log in the sandbox page (read in full, including the troubleshooting and limitations sections). Codex: OpenTelemetry export exists but defaults to `exporter = "none"`; session history under `CODEX_HOME`. |
| **Verdict** | **ahead, by documentation**: no competitor page describes a decision log that includes refusals and revocations. This rests on silence of docs (and on Codex's optional, off-by-default telemetry), not on proof of absence; a hook- or telemetry-based equivalent can be built in Claude Code and Codex. |
| Next improvement | `:XynoSandboxApprovals log --since` filter, and a size cap/rotation for `exceptions.log` (not documented in the README). |
| Sources | As rows 1 and 4; https://code.visualstudio.com/docs/agents/concepts/trust-and-safety.md ; https://junie.jetbrains.com/docs/junie-cli.html . Retrieved 2026-11-12. |

## 6. Local history

| Field | Content |
|---|---|
| xynovim | `xyno-history.nvim` (4c70c40): each throttled save snapshots the whole worktree (untracked included, `.gitignore` respected, `target/` out) as a commit on `refs/lochist/<branch>` using a private index and compare-and-swap `update-ref`; renames followed; restore keeps line endings; retention default 30 days and 1000 per branch, pruned in the background; failure shown once; measured on 100k files: 0.11 to 0.12 s per snapshot after a save, editor stall at most 1 ms (README, one machine, warm cache); first snapshot of a session 1.7 to 2.1 s; quitting waits (synchronously, at most 5 s). Downside, documented: snapshots live in the repo's `.git`, so mirror pushes, bundles and copies of `.git` carry them unless `push_guard = true`. |
| RustRover / JetBrains | Local History independent of VCS; default retention **5 working days**; stored outside the project (`~/.cache/JetBrains/<product><version>` on Linux); "cleared when you install a new version"; has a size maximum but the page gives no number; labels; the page does not address excluded or secret files. |
| VS Code | Timeline / local history: `workbench.localHistory.enabled` default `true`, `maxFileEntries` 50 per file, `maxFileSize` 256 KB, `mergeWindow` 10 s, `exclude` globs (no default listed); per-file entries on save; stored in the user data dir, not the repo. |
| Zed | No local-history feature found: searched Zed docs, release notes and issues; only git file history and "restore" from git. This is a negative search result, not a Zed statement. |
| Helix | No local-history feature found in the docs fetched (not exhaustively searched). |
| Distros | kickstart sets `vim.o.undofile = true` (per-file undo across sessions, text kept in the undo directory). LazyVim, AstroNvim and NvChad: nothing found on their pages. Undo files do not capture a deleted file or a `git reset --hard` (reasoning, not a cited claim). |
| **Verdict** | **ahead**: whole-tree, 30-day / 1000-snapshot default retention (JetBrains 5 days, VS Code 50 entries per file and a 256 KB file cap), rename tracking, and a default secrets exclusion (row 7). Not ahead on UI polish (JetBrains and VS Code have panels and labels) or on storage hygiene: a snapshot in `.git` is a larger secret-exposure surface than a cache directory. |
| Next improvement | Labels (JetBrains "Put Label") on events such as test runs and commits; an option to keep refs in an alternate object dir outside `.git` (`GIT_OBJECT_DIRECTORY`/`GIT_ALTERNATE_OBJECT_DIRECTORIES`) to remove the clone/mirror exposure; a measured cold-cache and network-FS run. |
| Sources | https://www.jetbrains.com/help/rust/local-history.html ; https://raw.githubusercontent.com/microsoft/vscode/main/src/vs/workbench/browser/workbench.contribution.ts (the `workbench.localHistory.*` definitions; the VS Code docs pages fetched did not carry them) ; https://github.com/nvim-lua/kickstart.nvim ; xyno-history README. Retrieved 2026-11-12. |

## 7. Secrets handling in snapshots

| Field | Content |
|---|---|
| xynovim | Default exclude list (`require("xyno_history").default_exclude`), matched case-insensitively through git's ignore machinery even when `.gitignore` does not cover it: env files, private keys and keystores, password stores, tool credentials (`.npmrc`, `.netrc`, `.git-credentials`, `credentials*`, `*.tfvars`, `*.tfstate`, `kubeconfig`), and `.ssh/ .gnupg/ .aws/ .kube/`; `exclude = false` disables; `push_guard` refuses pushes carrying `refs/lochist/*`. Limit: matching is by file name; a secret inside an ordinary source file is snapshotted. |
| RustRover / JetBrains | The Local History page does not address excluded or secret files (not documented). |
| VS Code | `workbench.localHistory.exclude` exists; no default patterns are listed; a third-party DFIR write-up recommends disabling local history or setting excludes (https://ogmini.github.io/2025/02/22/Investigating-Visual-Studio-Code-Part-3.html, secondary source). |
| Zed / Helix | No feature. |
| Distros | kickstart `undofile` stores file text in the undo directory with no exclusion (the init.lua sets it; no filter shown). |
| **Verdict** | **ahead (name-based only)**: the only one with a default secrets list, according to the pages above. Not a content scanner. |
| Next improvement | Optional content scan before commit (a gitleaks-style pattern check on added blobs, off by default), and a test that proves a secret in `.env` is absent from `refs/lochist/*` after `git gc` (the README states the exclusion, the spec `tests/secrets_spec.lua` covers the push side). |
| Sources | As row 6, plus xyno-history README "Secrets and pushing". Retrieved 2026-11-12. |

## 8. Hostile repository configuration

| Field | Content |
|---|---|
| xynovim | `xyno-history`: every git call runs with neutral overrides via `GIT_CONFIG_COUNT` (beats every config file including includes) for `core.fsmonitor`, `core.hooksPath`, `core.sshCommand`, `core.gitProxy`, pager/editor/askpass and others, and filter drivers; Windows form untested (README). `xyno-rust`: trust store; `crate_meta` overrides `RUSTC*` for untrusted roots; the stored context is validated before it reaches cargo's argv. The main config does not harden git calls made by other plugins (gitsigns, diffview) and does not stop rust-analyzer (row 3). |
| RustRover | Safe Mode disables VCS support entirely in untrusted projects, plus Cargo import and startup tasks. |
| VS Code | Restricted Mode (workspace settings pointing at executables are disabled; extensions limited). |
| Zed | Untrusted worktree: project settings, tasks, debug configs, language servers and MCP not applied. |
| Helix | Untrusted workspaces open git in gix `Trust::Reduced`, ignoring repo-local `.git/config` keys that run external programs; local config hash-pinned. |
| Distros | Neovim `'exrc'` off by default with a trust list. Third-party plugins' git calls: not checked. |
| **Verdict** | **tied**, for the scope of xynovim's own git calls and cargo layer. The competitors treat the whole editor; xynovim does not, so it is not ahead. |
| Next improvement | Export the neutral-config environment from `xyno-history` as a function and use it for the gitsigns/diffview git calls in the main config, only for roots not in the trust store. |
| Sources | https://www.jetbrains.com/help/rust/project-security.html ; https://zed.dev/docs/worktree-trust ; https://docs.helix-editor.com/master/workspace-trust.html ; VS Code workspace-trust page; xyno-history README "Hostile repository configuration". Retrieved 2026-11-12. |

## 9. Async metadata and non-blocking project loading

| Field | Content |
|---|---|
| xynovim | `xyno-rust` (7016d47): asynchronous cargo layer (`metadata_async`, `locate_async`, `exec`, `collect_async`); synchronous forms kept only where callers cannot take a callback (listed in the README); `xyno-imports` removed a `vim.wait` of up to 30 s; `:checkhealth xyno-rust` reports how long `cargo metadata` takes in the current workspace. |
| RustRover | Loads the Cargo project in the background (import is the step blocked in Safe Mode); no timing is published on the pages read. |
| VS Code / Zed / Helix | rust-analyzer loads the workspace through `cargo metadata` in the server process, away from the UI; its docs mention refresh on `Cargo.toml` change and `RA_LOG=project_model=debug`. |
| Distros | rustaceanvim sits on the same server. |
| **Verdict** | **tied**. Editor-side the work is off the main loop in all of them; no benchmark of "time until usable" across products exists in this document, so nothing here supports `ahead`. |
| Next improvement | A reproducible measurement on a large workspace (time to first diagnostics, longest editor stall) against rustaceanvim alone, kept under `docs/bench`. |
| Sources | https://rust-analyzer.github.io/book/configuration ; https://rust-analyzer.github.io/manual.html ; https://www.jetbrains.com/help/rust/project-security.html ; xyno-rust README. Retrieved 2026-11-12. |

## 10. Import management

| Field | Content |
|---|---|
| xynovim | `xyno-imports.nvim` (201ef96): auto-import of unresolved names on idle, single candidate applied or one key; several candidates ranked by what the project already does with a per-project memory of the choice; `:ImportOrganize` runs rust-analyzer's merge, normalize and remove-unused assists in one undo step, asynchronously; action recognition by assist id first, then shape, then the English title (locale-independent). |
| RustRover | Add unambiguous imports on the fly; import on completion and on paste (copy within the IDE); Optimize Imports (removes unused, organizes, can add missing); **exclusion table** to hide re-exports (`::*`); no per-project ranking memory described. |
| VS Code / Zed / Helix | rust-analyzer "Import X" code action chosen from a menu. |
| Distros | rustaceanvim: code actions via `:RustLsp codeAction`; no auto-import or organize command found in the vimdoc fetched. |
| **Verdict** | **tied (split)**. Ahead of VS Code, Zed, Helix and the distros (no ranking, no memory, no single-key flow in their documented behaviour). Behind RustRover on import-on-paste, the exclusion list and the maturity of Optimize Imports. |
| Next improvement | Import-on-paste (resolve names in the pasted text once rust-analyzer is ready) and an `exclude = { "::internal::*" }` table consulted by the ranker. |
| Sources | https://www.jetbrains.com/help/rust/rust-autocomplete-code.html ; https://raw.githubusercontent.com/mrcjkb/rustaceanvim/master/doc/rustaceanvim.txt ; xyno-imports README. Retrieved 2026-11-12. |

## 11. Macro expansion safety

| Field | Content |
|---|---|
| xynovim | `xyno-macros.nvim` (99db4c1): `:MacroExpand` uses rust-analyzer's `expandMacro`; the `cargo expand` fallback compiles the crate (runs `build.rs` and proc macros), so it is **gated behind workspace trust** and asks first; snippet guard on expression nodes. Limit (row 3): rust-analyzer itself runs proc macros and build scripts when it loads the workspace, and xynovim does not prevent that in untrusted workspaces. |
| RustRover | Build scripts and proc macros run only in trusted projects; Safe Mode disables macros and Cargo import. Proc-macro expansion runs in a separate process (`proc_macro_srv`) per the JetBrains blog. |
| VS Code | Restricted Mode limits extensions; what rust-analyzer does there is not documented in the pages read. |
| Zed | Language servers are not spawned in an untrusted worktree; the sandbox page names `rust-analyzer` running proc macros as an out-of-sandbox risk. |
| Helix | Trust gates servers only at level `none`; default starts them. |
| Distros | rustaceanvim exposes `expandMacro`; no trust gate in the vimdoc fetched. |
| **Verdict** | **tied** with RustRover and Zed: an untrusted project's proc macros and build scripts do not run (rust-analyzer restricted, clippy off, `cargo expand` asks); ahead of Neovim distros and Helix default. Limit: the trusted-workspace path is unchanged, so a trusted project runs everything. |
| Next improvement | Done with row 3. Open: show which macros were not expanded (rust-analyzer reports unresolved macro calls as diagnostics). |
| Sources | https://www.jetbrains.com/help/rust/project-security.html ; https://blog.jetbrains.com/rust/2022/12/05/what-every-rust-developer-should-know-about-macro-support-in-ides/ ; https://zed.dev/docs/ai/sandboxing.md ; https://zed.dev/docs/worktree-trust ; xyno-macros README "Trust before `cargo expand`". Retrieved 2026-11-12. |

## 12. Dependency add confirmation and typosquat warning

| Field | Content |
|---|---|
| xynovim | `xyno-crates.nvim` (0682b7e): every add (`:CrateAdd` and the code action, and the import source) shows a preview: crate, version, features and default-features flag, target table, downloads (total and 90 days), first-published and last-updated, repository; typosquat warning when within one edit (two for names of eight letters or more), neighbour swaps, or look-alike letters (`rn`/`m`, `0`/`o`, `1`/`l`) of a popular crate and under 2 million downloads, with **Cancel first**; also warns on a crate younger than 30 days or unknown to the index; `cargo-audit` hint or run after the add. Limit: the popularity list is about 250 built-in names, not the live top of crates.io. The main config also runs `cargo-deny` (advisories, bans) and `cargo-machete` as diagnostics (`lua/plugins/supply-chain.lua`). |
| RustRover | Cargo.toml inspections check that crates exist and whether versions are up to date; completion of names and versions; inlay hints for locked vs latest version. The page mentions no vulnerability check, typosquat check or add confirmation. |
| VS Code | Dependi (successor of Crates; free "Core"): "identify vulnerabilities in your project dependencies" (source not named in the README; Pro adds detailed vulnerability reports); no typosquat or add confirmation mentioned. |
| Zed | Dependi has a Zed port using OSV.dev, per its listing (secondary source). No add confirmation described. |
| Helix | None. |
| Distros | crates.nvim README mentions neither vulnerability checking nor typosquat warnings (README only; its wiki was not read). |
| Context | Real incidents: `faster_log` / `async_println` (Rust Security Response WG, 2025-09-24), `tracing-check` (2026-02), `dnp3times` (2026-03), `proc-macro1` typosquat pulled in by compromised `arrayref` and others (2026-08); crates.io removed the latter in about 90 minutes (trade-press summary). |
| **Verdict** | **ahead at add time** (confirmation + typosquat + age; nothing comparable on the competitor pages). **Tied** on advisories: Dependi (live OSV) and cargo-deny/cargo-audit in xynovim cover the same ground differently. |
| Next improvement | Show cargo-deny/RustSec advisories as Cargo.toml diagnostics in the add preview itself (query the local advisory DB before adding, not only after), and build the popularity list from crates.io's weekly dump instead of a fixed 250 names. |
| Sources | https://www.jetbrains.com/help/rust/toml-files.html ; https://raw.githubusercontent.com/filllabs/dependi/main/README.md ; https://mpiton.github.io/zed-dependi/languages/rust.html ; https://raw.githubusercontent.com/saecki/crates.nvim/main/README.md ; https://blog.rust-lang.org/2025/09/24/crates.io-malicious-crates-fasterlog-and-asyncprintln ; https://thehackernews.com/2026/08/rust-supply-chain-attack-puts-build.html (secondary) ; xyno-crates README. Retrieved 2026-11-12. |

## 13. Template supply chain

| Field | Content |
|---|---|
| xynovim | `xyno-new.nvim` (c16af8e): `:EguiNew` downloads `emilk/eframe_template` at a pinned commit (`PINNED_REF` f108546, 2026-08-31), as a ZIP, never a copy kept in the plugin; refuses `http://` and `file://` unless `allow_insecure`; nothing from the template is executed; its `rust-toolchain` file is never copied. Limits: no content hash of the ZIP is verified, and only this one template exists. |
| RustRover | Custom templates from "any Git repository" through cargo-generate: the Add Custom Template dialog takes a Git URL and a name; the page documents no branch/tag pinning, no hook warning and no trust prompt (not documented); cargo-generate templates can run Rhai hook scripts (project docs, via search). |
| VS Code / Zed / Helix | No template mechanism; `cargo new`/`cargo generate` in the terminal. |
| Distros | LazyVim installation: `git clone https://github.com/LazyVim/starter` with no tag, branch or commit given ("the clone isn't pinned"). |
| **Verdict** | **ahead (narrow)**: pinned and scheme-checked by default, against an unpinned starter clone and a custom-template dialog with no documented pin. Not a full supply-chain control (no hash). |
| Next improvement | Record and verify the SHA-256 of the pinned ZIP; refuse on mismatch with a message naming the commit. |
| Sources | https://www.jetbrains.com/help/rust/rust-project-templates.html ; https://www.lazyvim.org/installation ; cargo-generate documentation search results (https://cargo-generate.github.io/cargo-generate/templates/pitfalls.html shows hooks run Rhai scripts that can call `sed`); xyno-new README. Retrieved 2026-11-12. |

## 14. `:checkhealth` equivalents

| Field | Content |
|---|---|
| xynovim | `:checkhealth xynovim` (`lua/xynovim/health.lua`: external tools and what each is for), plus per-plugin `xyno_history`, `xyno-rust` (versions, tools, state files with invalid values flagged, trust of the current workspace, `cargo metadata` timing), `xyno_sandbox` (readiness probe, `:XynoSandboxStatus!`), crates, imports, macros and new. |
| RustRover | No health-check command found; rust-analyzer-style status is in the Cargo tool window (not verified). |
| VS Code | rust-analyzer status command and server log; no single health report found in the pages read. |
| Zed / Helix | Helix has `hx --health` (known from its CLI; not fetched this session, so not cited). Zed: not found. |
| Distros | kickstart tells users to run `:checkhealth`; LazyVim recommends `:LazyHealth`; rustaceanvim ships a health check (rust-analyzer binary, `cargo`, `rustc`, DAP adapter, config validation, conflicts, tree-sitter parser; it does not check the Neovim version or trust). |
| **Verdict** | **tied**: the distros ship one too; xynovim's is wider (trust, sandbox probe, state files), but breadth of coverage is not shown to matter more. |
| Next improvement | One aggregate `:checkhealth xynovim` that calls the plugin checks and prints a single pass/fail line per plugin and the one-line fix, so a new machine can be verified in one command. |
| Sources | https://raw.githubusercontent.com/mrcjkb/rustaceanvim/master/lua/rustaceanvim/health.lua ; https://www.lazyvim.org/installation ; https://raw.githubusercontent.com/nvim-lua/kickstart.nvim/master/init.lua ; plugin READMEs. Retrieved 2026-11-12. |

---

## 15. Sandboxing in Neovim agent plugins

Method: README fetched with `gh api repos/<r>/readme` (read-only) and, for each repo, the full git tree (`git/trees/<default branch>?recursive=1`) searched for paths matching `sandbox|bwrap|seatbelt|firejail|landlock`. Zero matching paths in all six repos below; this shows no sandbox module exists, not that the plugin cannot be run inside one by the user. Retrieved 2026-11-12. Stars and last push are from the same API call.

| Plugin (stars, last push) | What it does about agent safety | OS sandbox / network control |
|---|---|---|
| avante.nvim (18.2k, 2026-11-12) | README config: `auto_approve_tool_permissions = true` is the default ("auto-approve all tools (no prompts)"); can be `false` or a list of tool names (`{"bash","str_replace"}`); `confirmation_ui_style`. Scoped `AVANTE_`-prefixed API keys. The same default is in `lua/avante/config.lua`. | None found. By default its bash tool needs no prompt. |
| codecompanion.nvim (6.9k, 2026-11-09) | Docs (`doc/codecompanion.txt`): per-tool approval keymaps (accept once / always / reject / cancel); "always accept" for `run_command` covers only that exact command; approval modes Ask, Auto (runs everything but `run_command` unless on a safe list, and protected tools such as `delete_file`), YOLO ("runs every tool without asking, including `delete_file` and any shell command"); `protect = true` option that YOLO ignores; optional LLM "judge" of commands; code review of agent edits. | None found. |
| claudecode.nvim (3.2k, 2026-11-12) | Bridges Claude Code's IDE protocol: loopback WebSocket listener, lock file `0600`, diff accept/reject in Neovim. Permission behaviour is Claude Code's own. | None; the README's "Global Side Effects" section documents the network/disk footprint only. |
| sidekick.nvim (2.8k, 2026-09-08) | Runs CLI agents in a tmux/zellij or native terminal. No approval layer of its own found in README/config. | None found. |
| opencode.nvim (3.9k, 2026-10-30) | README "Permissions": when the connected OpenCode asks, the plugin prompts approve/deny; edit requests open a `:diffpatch` view with accept keys. | None; policy lives in OpenCode. |
| 99 (4.8k, 2026-06-12) | README warns that `tmp_dir` outside the cwd causes permission failures in claude/opencode and links their permission docs. | None. |
| claude-code.nvim (greggh, 2.1k, 2026-02-04) | README has no permission or sandbox text. | None. |

**Verdict: ahead.** Against Neovim agent plugins, xynovim is the only one found with an OS sandbox (bubblewrap), default-deny egress and fail-closed startup (rows 1-2). The strongest of the others (codecompanion) offers approval prompts, which xynovim also leaves to the agent itself; the approval layer is orthogonal, and xynovim does not claim to be ahead of codecompanion on in-chat tool approval UX (not compared). Caveat: avante's default (auto-approve everything) and codecompanion's YOLO mode are the cases a sandbox protects against.

Not verified: no plugin was installed or run; plugins not listed here (e.g. gp.nvim, parrot.nvim, CopilotChat.nvim, minuet) were not read. A user can still launch any of these inside their own bwrap/firejail.

Sources: https://github.com/avante-corp/avante.nvim ; https://github.com/olimorris/codecompanion.nvim ; https://github.com/coder/claudecode.nvim ; https://github.com/folke/sidekick.nvim ; https://github.com/nickjvandyke/opencode.nvim ; https://github.com/ThePrimeagen/99 ; https://github.com/greggh/claude-code.nvim . Retrieved 2026-11-12.

## 16. Helix: agent, sandbox and trust features

| Field | Content |
|---|---|
| Workspace trust | Book chapter `book/src/workspace-trust.md` on master: gates language servers, debug adapters, `.helix/config.toml` / `languages.toml` and `.git/config` filters; `[editor.workspace-trust] level` = `none` / `servers` (default) / `insecure`, `prompt`, `trusted` globs; `:workspace-trust`, `:workspace-untrust`, `:workspace-exclude`; hash of `.helix/` detects later changes (stale state). **Default `servers` still starts language servers**, so rust-analyzer runs in an unreviewed repo by default; only `level = "none"` stops it. Shipped: PR 15177 merged 2026-03-26, "v2" PR 15857 merged 2026-06-20 (commits touching the chapter); the latest tagged release is 25.07.1 (2025-07-15), so **no release contains it** as of 2026-11-12 (tags list shows 24.03 ... 25.07.1; a `v0.6.0` tag is unrelated). |
| Agent / AI | Not in the editor. PR 15955 (Copilot inline completion) and PR 16312 (assist panel driving agents over ACP) were closed unmerged (2026-07-05, 2026-09-25); issue 14390 (ACP support) closed as duplicate. |
| Sandbox | PR 15983 "Add fs sandboxing on Linux using Landlock" closed unmerged 2026-07-05. Issue 16459 "Sharing my bubblewrap sandboxing" is open: a user-side wrapper, not a feature. |
| **Verdict** | **tied on trust, ahead on agents/sandbox only in the trivial sense**: Helix has a trust model on master (unreleased) that gates the language server when the user sets `level = "none"`; xynovim does not gate rust-analyzer (row 3, behind). Helix has no agent, so there is nothing to sandbox. The honest reading is: Helix is ahead of xynovim on the language-server trust question once released; xynovim is ahead of Helix on agent isolation because Helix has none. |
| Sources | https://docs.helix-editor.com/master/workspace-trust.html (book source via `gh api repos/helix-editor/helix/contents/book/src/workspace-trust.md`) ; https://github.com/helix-editor/helix/pull/15177 ; https://github.com/helix-editor/helix/pull/15857 ; https://github.com/helix-editor/helix/pull/15983 ; https://github.com/helix-editor/helix/pull/16312 ; https://github.com/helix-editor/helix/issues/14390 ; https://github.com/helix-editor/helix/issues/16459 ; https://github.com/helix-editor/helix/releases . Retrieved 2026-11-12. |

---

## Not verified

- No xynovim behaviour was re-run for this document. Claims come from READMEs and commit titles; the plugin specs were not executed here.
- No competitor product was installed or run. Everything about RustRover, VS Code, Zed, Helix, Claude Code, Codex and the distros is from vendor docs or source files read through web fetch (a summarising fetch tool, so quotes are paraphrases of its output) and search on 2026-11-12. One VS Code docs page was also opened in Chrome (own tab, closed) and turned out to be the wrong page; the `workbench.localHistory.*` defaults come from VS Code's source file on GitHub.
- Helix workspace trust is taken from the `master` book; resolved in row 16: merged 2026-03-26 (PR 15177), reworked 2026-06-20 (PR 15857), and not in the latest tagged release (25.07.1, 2025-07-15) as of 2026-11-12. VS Code's agent sandbox is labelled Preview on its macOS/Linux rows in the docs; GA claims in trade press were not relied on.
- "Not documented" and "no feature found" are search results, not proof. Zed and Helix local history, RustRover sandboxing of its IDE agent, and rust-analyzer's behaviour in VS Code Restricted Mode are the three that matter most; re-check before quoting them as absences.
- The Windows and macOS behaviour of xynovim's hardening is unexercised (READMEs say so).

## Where xynovim is not ahead, ranked

1. Rows 3 and 11 (`behind`): apply `ra_overrides` to rust-analyzer in untrusted workspaces (main-repo change plus a spec).
2. Row 1: macOS backend; credential masking.
3. Row 10: import-on-paste and an exclusion list.
4. Rows 8, 9, 14 (`tied`): widen git hardening to other plugins; measure loading; one aggregate health command.
