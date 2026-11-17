# Security policy

This plugin is maintained by one person. Only the latest tagged release and `main` are supported.

## Reporting a vulnerability

Please do not open a public issue with exploit details. Use GitHub's private report (the repository's **Security** tab, **Report a vulnerability**). If that button is missing, open an issue that says only "security report, please contact me" and a private channel will be arranged. Best effort: no response-time guarantee, no bounty.

## Scope

The plugin runs Lua inside your Neovim with your privileges and, where its README says so, starts external programs (`git`, `cargo`, `rust-analyzer`, ...). It has no network code of its own unless its README says otherwise. It is not a sandbox and does not defend against a hostile project or a hostile plugin installed next to it.

<!-- xyno-sandbox.nvim only, replace the paragraph above with: -->
<!--
The plugin wraps a command-line agent in bubblewrap. That is a seatbelt, not a jail: the network stays open, the project directory is writable, the hidden paths are a denylist, and it is Linux only. It has not been audited. See https://github.com/xynorash/xynovim/blob/main/SECURITY.md for the full list.
-->
