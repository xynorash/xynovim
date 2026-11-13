# UI captures (2026-11-12)

Before = `git archive HEAD` of the commit before the UI work (2becd3a); after = the working tree of branch `dev`. Same throw-away crate (`tools/ui-capture/demo-main.rs`: a type error on line 19, an unused variable), same machine, real rust-analyzer and bacon-ls, cursor on line 19. These are the files the shortlist items in [../../ui-community.md](../../ui-community.md) refer to. They show what changed; whether it looks good is for you to judge.

## How they were made

1. `tools/ui-capture/scene.py` starts Neovim in a private tmux server (`TERM=tmux-256color`, `RGB` and `usstyle` features on), waits for the diagnostics and `RA ready`, sends keys and runs `tmux capture-pane -ep` (`*.txt` is the plain text of the same moment).
2. `tools/ui-capture/render.py` draws the ANSI capture to PNG with Pillow and the installed JetBrainsMono Nerd Font Mono (cell grid, bold / italic, curly / dashed / dotted underlines in their colour). **Limits:** a transparent editor background is drawn as `#1e1f22`; code points the font lacks (the code-lens "Debug" gear `⚙︎`) show as an empty box in these renders only; half-block banner rows have a 2 px gap because the line height is larger than the glyph. The renderer is mine, not a terminal.
3. True pixels: `ghostty-x11-*.png` are a real Ghostty 1.4.0 window (`GDK_BACKEND=x11 ghostty -e nvim`) grabbed with `ffmpeg -f x11grab -window_id <id>`. **Result of the one try:** it works with `-window_id`; grabbing the whole X11 root gave a black frame (Xwayland root is not composited), and ImageMagick `import` refused to write a file (`missing an image filename`, cause not found). The Ghostty window used the font and theme of this machine's Ghostty config, not the 16 px renderer above, and was not resized, so its columns differ from the tmux captures.

## Files

| Item | Files |
| --- | --- |
| #2, #3, #4, #8, #10 (rust file, cursor on the error line) | `rust-before-{60,80,120,200}.png` / `rust-after-{60,80,120,200}.png` |
| #12 dashboard | `dash-before-{60,80,120}.png` / `dash-after-{60,80,120}.png` |
| #6 high contrast | `rust-after-high-120.png` |
| #9 ASCII icons | `rust-after-ascii-100.png`, `dash-after-ascii-80.png` |
| true pixels | `ghostty-x11-dashboard-after.png`, `ghostty-x11-rust-after.png` |

## What to look at, with numbers

- Inlay hints: text/chip contrast 3.23:1 -> 6.07:1 (chip `#393b40` -> `#2b2d30`; code text stays 8.9:1 on the editor). The grid test measures the colours the cells are really drawn with.
- Narrow statusline (60 columns): before `<main` (a stub), after `main.rs ƒ main`; widths 60/80/120/200 are asserted in `tests/ui-community_spec.lua`.
- Diagnostics: before, `● expected String, found i32 [rust-analyzer]` on every line with a problem; after, the full text on the cursor line and `✗ E0308` elsewhere; at 60 columns the text ends with `…` inside the window.
- High contrast: comments 4.50 -> 7.09:1, line numbers 3.46 -> 7.07:1, code-lens 4.52 -> 7.00:1.

## Source counts (from ui-community.md)

#1: 4 sources (1 indirect); #2: 5; #3: 4 (3 indirect); #4: 3 (1 indirect); #5: 4; #6: 4 (1 indirect); #7: 4 (2 indirect); #8: 3; #9: 5 (2 indirect); #10: 3; #11: 2; #12: 2 (1 indirect).

## Not captured

Light variant (nothing in the shortlist asks for one), the sandbox / history / guard / macros popups (asserted on the grid in the spec, not photographed: a real popup needs a session of each plugin), `:checkhealth xynovim` terminal section (asserted in the spec with injected environments).
