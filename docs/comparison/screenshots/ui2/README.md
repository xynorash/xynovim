# UI round 2 captures (2026-11-12): real Ghostty pixels

Ghostty 1.4.0 as an X11 window (`GDK_BACKEND=x11`, fullscreen, JetBrainsMono Nerd Font Mono, `minimum-contrast = 1`, opaque background), grabbed with ImageMagick `import -window <id>`. Neovim was started with `--listen` inside it and driven through `nvim --server ... --remote-send`. Same throw-away crate as round 1 (`tools/ui-capture/demo-main.rs`: a type error on line 19), real rust-analyzer and bacon-ls, cursor on line 19. I opened and looked at each image before listing it.

- **Before** = `git archive` of the commit before this round (2acc5d4), **after** = the working tree of `dev`.
- **Columns are real, set by the font size** (the window is the whole 1920x1080 screen): the actual `&columns x &lines` were 61x15 (nominal 60), 79x20 (80), 119x29 (120), 191x50 (nominal 200: the font could not be tuned to exactly 200). Because the font differs per width these images are not pixel-comparable between widths.
- Another agent's Ghostty window on the same display shrinks the capture window; the driver waited for a free display, which is why the series took long.

| Files | What |
|---|---|
| `dash-{before,after}-{60,80,120,200}.png` | dashboard: tagline changed to "Rust in Neovim, AI agent sandboxed" |
| `rust-{before,after}-{60,80,120,200}.png` | Rust file, cursor on the error line |
| `rust-after-light-120.png`, `rust-after-light-high-120.png` | `island-light`, and with `:IslandContrast high` |
| `rust-after-high-120.png` | dark, high contrast (looks close to normal at this size; the difference is in the muted tones, see the numbers in the spec) |
| `rust-after-ascii-120.png`, `rust-after-nerd-restored-120.png` | `:XynoIcons ascii` (code lens `> Run | * Debug`, `x E0308`, `E 2`), and back to nerd without a restart |
| `rust-after-rendered-120.png` | `<leader>cD`: the clippy (bacon-ls) message as rustc prints it, coloured |
| `rust-after-tree-120.png` | file tree with the error colour on `main.rs` (and on the root folder that contains it) |

## Seen on these images, not fixed

- Dashboard at 119x29 and below: the entry list is cut at the bottom (at 61x15 only four entries are visible), and an empty statusline-coloured bar shows under it.
- The code-lens gear sits tight against "Debug" (font metrics).
- `rust-after-rendered-120.png`: the float overlaps the statusline's right part; the `+++++` of a suggested diff is not coloured.
- A stale winbar capture (raw `%#NavicIconsFunction#` text, found on the real image, fixed in code and covered by a test) was removed; the winbar is not photographed again.

## Not captured

The sandbox policy window, the local-history panel and the proc-macro report (they exist only with the plugin `dev` clones; they are measured on the grid in `tests/ui-community_spec.lua` and were not photographed), the 80/200-column variants of light, high contrast, ASCII and the popups, and any competitor editor.
