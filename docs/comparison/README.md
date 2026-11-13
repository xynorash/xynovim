# Comparison research: xynovim vs other Rust editing setups

Retrieved: 2026-11-12. Method: official docs/release pages fetched via web fetch and search, plus screenshots taken in Claude in Chrome (own tab, closed afterwards). No installers downloaded, no third-party binaries run.

Label convention for every number: **[published claim]** = a figure stated by a vendor/third party, not reproduced here; **[measured]** = measured by us on this machine. Nothing below about third-party products is [measured].

Screenshot limit: the browser window was narrow (about 885 px wide), and shots are landing/docs pages, not the default Rust editing UI of each product (which would need an install, forbidden here). See "Gaps".

## Screenshots (docs/comparison/screenshots/)

| Target | File | What it shows |
|---|---|---|
| xynovim | xynovim-website-home.jpg, xynovim-website-tour.jpg | live website, home and tour section |
| xynovim | xynovim-readme-hero.png, -diagnostics.png, -debug.png, -coverage.png | README media copied from docs/media (real config, demo crate) |
| RustRover | rustrover-home.jpg, rustrover-quickstart-docs.jpg | jetbrains.com/rust, docs quick start |
| VS Code | vscode-rust-docs.jpg | Rust in VS Code docs (rust-analyzer ext, v0.3.1051 shown) |
| Zed | zed-home.jpg | zed.dev landing (editor screenshot visible) |
| Helix | helix-home.jpg | helix-editor.com |
| LazyVim | lazyvim-home.jpg | lazyvim.org (dashboard screenshot) |
| AstroNvim | astronvim-home.jpg | astronvim.com (editor screenshot) |
| NvChad | nvchad-home.jpg | nvchad.com |
| kickstart.nvim | kickstart-github.jpg | GitHub repo (31.7k stars, 46.2k forks at capture) |
| rustaceanvim | rustaceanvim-github.jpg | GitHub repo (3.2k stars, v9.2.2 shown, GPL-2.0) |

See notes.md for the feature, performance, security and customization tables.

See also [MATRIX.md](MATRIX.md) (every item, one table, with sources and next steps) and [ONE-PAGE.md](ONE-PAGE.md) (short summary).
