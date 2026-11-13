# Rainbow brackets: real Ghostty pixels (2026-11-12)

How: `tools/ui-capture/rainbow/shot.sh <scene> <columns> <lines> <out.png> [font-size]` starts a private Ghostty 1.4.0
window (`GDK_BACKEND=x11`, `--background-opacity=1 --minimum-contrast=1`, JetBrainsMono Nerd Font Mono) running this
config's Neovim on a throw-away file outside any crate (`demo.rs`, `mismatch.rs`; rust-analyzer is stopped and the
notifications dismissed before the grab) and grabs the window with `ffmpeg -f x11grab -window_id`. The pictures were
LOOKED AT (also zoomed with ImageMagick) before this page was written.

**Column counts are approximate**: the compositor tiles the window, so the font size was changed to get near the target.
Grids reached (columns x lines): `*-60`: 58x27, `*-120`: 117x57, `*-200`: 187x88.

| File | What |
| --- | --- |
| `off-{60,120,200}.png` | before: the same file with `:XynoRainbow off` |
| `on-{60,120,200}.png` | after: Island Dark, defaults (6 colours) |
| `scope-{60,120,200}.png` | after `Ctrl`+right-click equivalent (`:XynoRainbow scope`) on `(a + b)`: tint alpha 0.2, the two brackets inverted |
| `restrain-120.png` | `Alt`+right-click equivalent: everything outside `(a + b)` dimmed |
| `light-120.png` | `:colorscheme island-light` |
| `cb-120.png`, `lightcb-120.png` | the colour-blind palette, dark and light |
| `high-120.png` | `vim.g.xynovim_contrast = "high"` (7:1) |
| `vars-120.png` | rainbow variables on (`count`, `sum`, `weights`, ... each in its own colour) |
| `words-{py,c,html,tsx,yaml}.png` | `words.keywords` and `words.tags` on: Python `def/for/if/while/try` by block depth, C `#if`/`#else`/`#endif` by conditional depth, HTML and JSX tag names with their brackets by element depth (the comparison `<` in the JSX is untouched), YAML keys by mapping depth. 78x17 grid, Island Dark; colours read back from the pixels for the Python file |
| `mismatch-120.png` | unmatched brackets marked red with a curl |

## What they show, and what they do not

- Mismatch: the marked brackets are the ones tree-sitter's error recovery could not pair. Next to a real mistake it can
  also mark the pair around it: in `mismatch-120.png` the `{` and `}` of `main` are marked as well as the three brackets
  of line 2 and the `println!(` whose `)` is missing. The JetBrains plugin marks nothing here.
- The mouse itself was not clicked in these captures: the scope pictures are made with the command that the mouse
  mapping calls (the mouse path is asserted in `tests/rainbow_spec.lua` with a stubbed `getmousepos`).
- Ghostty's own cursor, the window title bar and the compositor's decoration are part of the grab.
