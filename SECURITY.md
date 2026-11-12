# Security policy

xynovim is a personal Neovim configuration, maintained by one person, not a product with a security team. This file says what is in scope, what the safeguards in it are and are not, and how to report a problem.

## Supported versions

Only the latest commit on `main` (and the latest tag of each `xyno-*.nvim` plugin). There are no backports.

## Reporting a vulnerability

Please do not open a public issue with exploit details.

1. Use GitHub's private report: the repository's **Security** tab, **Report a vulnerability**. If that button is missing, the feature is off for the repository: open an issue that says only "security report, please contact me" (no details) and a private channel will be arranged.
2. Say what you did, what you expected and what happened, on which OS and Neovim version.

This is best effort by one person: no response-time guarantee and no bounty. A confirmed problem is fixed on `main` and noted in the CHANGELOG.

## What the sandbox is, and is not

The AI agent integration ([99](https://github.com/ThePrimeagen/99) with the Claude Code provider, wrapped by [xyno-sandbox.nvim](https://github.com/xynorash/xyno-sandbox.nvim)) runs `claude --dangerously-skip-permissions` inside **bubblewrap**. Treat it as a **seatbelt, not a jail**. It lowers the damage of an agent that does something unintended; it is not a boundary you can rely on against a hostile program or a hostile repository.

What it does (Linux with `bwrap` and unprivileged user namespaces; checked by specs here, and only here):

- the filesystem is read-only except the project directory and the agent's own state;
- credentials and agent sockets (`~/.ssh`, `~/.aws`, GPG and SSH agents and similar) are hidden;
- `.git/hooks`, `.git/config` and the agent's settings are locked read-only, so a request cannot plant code that later runs outside the sandbox;
- the environment is scrubbed of tokens;
- a Local History snapshot is taken before every request and auto-save is paused during it;
- without a sandbox backend the agent **refuses to start**, unless you opt out explicitly (`vim.g.xynovim_99_sandbox = false` or `vim.g.xynovim_99_allow_unsandboxed = true`), which warns on every request.

What it does not do:

- **Only the AI agent is sandboxed.** rust-analyzer, build scripts and proc macros, `cargo`, the debugger target, tests and all plugins run with your privileges. The restricted mode for untrusted Rust workspaces (rust-analyzer without build scripts, proc macros and `cargo check`) limits what rust-analyzer executes; it is not a sandbox.
- **The network stays open with the pinned plugin version.** The xyno-sandbox.nvim `dev` branch (not pinned yet) runs the agent in its own network namespace and lets HTTPS through an allowlist proxy only, failing closed; until `lazy-lock.json` pins it, assume the agent can reach any host. Anything the agent can read (the project, its own state) it can send out. Prompts and file contents go to the model provider by design.
- **The project directory is writable**, including `target/`, build scripts and test code. Code the agent writes runs with your privileges as soon as you build or test it outside the sandbox. Review the diff before you run it.
- **The hidden paths are a denylist.** A secret kept in an unlisted place under a readable path is visible to the agent. Some state under `~/.claude` stays writable inside the sandbox.
- **No sandbox on Windows or macOS.** There the agent does not run at all (fail-closed), except under the explicit opt-out above, which runs it with no sandbox.
- **Other 99 providers** (OpenCode, Cursor, Gemini, Kiro) are not sandboxed and are reachable only through that opt-in.
- It has not been audited and no escape test beyond the repository's specs has been run. bubblewrap itself is a privilege-reduction tool, not a hardened VM.

Other things that run code on your machine, by design: the plugins in `lazy-lock.json`, the tools Mason installs, `cargo`/`rust-analyzer` proc-macros and build scripts of the project you open (the same exposure as every Rust IDE; on `dev` a workspace you have not trusted with `:RustTrust` starts rust-analyzer without them, see CHANGELOG, "Restricted mode"), and the `build` hooks of a few plugins.

## Supply chain: what is pinned and what is not

Pinned:

- plugins: every plugin at a commit in `lazy-lock.json`; `scripts/bootstrap.sh` restores exactly those, and CI fails when the lockfile changes;
- GitHub Actions: by full commit SHA; Dependabot proposes updates (`.github/dependabot.yml`);
- Neovim, StyLua and lua-language-server in CI: by version and sha256 of the downloaded archive;
- Mason: the registry is pinned to a release tag (`lua/plugins/mason-pin.lua`), which fixes the version of every Mason tool that comes from it.

Not pinned or not verified:

- Mason verifies what its registry says (download URL and, for most packages, a checksum), but the tools are third-party binaries and npm/cargo packages fetched at install time; a pinned registry fixes versions, it does not audit them;
- the treesitter parsers are compiled from whatever revision `nvim-treesitter` pins, on your machine, with your C compiler;
- `lazy.nvim` itself is cloned from its `stable` branch on first start (`lua/config/lazy.lua`);
- the README's CI evidence comes from GitHub-hosted runners and is only as trustworthy as they are.

Workflow files are linted with actionlint and zizmor from inside the editor (`lua/plugins/supply-chain.lua`) and by the spec suite when the tools are installed.
