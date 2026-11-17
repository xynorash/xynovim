# Competitor screenshots (2026-11-12)

Taken from the vendors' own pages, on 2026-11-12, with a headless Google Chrome (temporary profile, deleted afterwards): the Claude-in-Chrome extension was not connected in this session, so the browser was driven from the command line (`google-chrome-stable --headless=new --screenshot`, 1440 px wide) and the images were cropped with ImageMagick. No installer, theme or package was downloaded and no competitor editor was run. Reddit was not used.

What these are: marketing and documentation pictures chosen by the vendors. They are not the same file, font, window size or diagnostics as the xynovim captures, so they show how each tool presents itself, not a controlled comparison.

| File | Source (official) | What it shows | Rust? |
|---|---|---|---|
| `rustrover-quickfix-rust.png` | https://www.jetbrains.com/rust/ (section "Write your code faster") | RustRover editor: Rust struct, quick-fix popup "Add missing fields" with a preview of the change | yes |
| `vscode-rust-inlay-hints.png`, `vscode-rust-completion.png` | https://code.visualstudio.com/docs/languages/rust ("Inlay hints", "Auto completions") | VS Code with rust-analyzer: inlay hints with grey chips, completion list, quick-fix bulb, red squiggle | yes |
| `zed-editor-ts-diagnostics.png` | https://zed.dev/ (hero picture) | Zed window, light theme: agent panel, file tree, TypeScript file with inline diagnostics (error text highlighted at the end of the line) | no, TypeScript |
| `zed-docs-rust-page-text-only.png` | https://zed.dev/docs/languages/rust | the Rust docs page: only JSON settings for inlay hints, no editor picture | page only |
| `astronvim-lua-editor.png` | https://astronvim.com/ (hero picture) | AstroNvim, light theme: tree, bufferline, breadcrumbs, outline, statusline | no, Lua |
| `nvchad-js-editor.png` | https://nvchad.com/ (hero picture) | NvChad: tree, tabs, completion menu, statusline with LSP and diagnostics counts | no, JavaScript |
| `lazyvim-lua-editor.png` | https://www.lazyvim.org/ (Getting Started) | LazyVim: tree, completion with documentation float, statusline | no, Lua |

Helix: https://helix-editor.com/ was captured, but its only picture is a video that does not render in a headless page (the player is a black box), and https://github.com/helix-editor/helix has no screenshot. **No Helix editor picture was obtained in this round**; `../helix-home.jpg` (earlier, home page) is all there is.

For RustRover, VS Code and Zed the page can change at any time; the crops are what the pages showed on the date above. Zed, AstroNvim and NvChad show languages other than Rust: they say nothing about Rust-specific UI (lens, rust-analyzer status) and must not be read as such. Where the vendor shows no Rust editing UI, the assessment says "not shown", not "worse" or "better".
