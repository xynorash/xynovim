# UI assessment: xynovim against RustRover, VS Code, Zed, Helix and the popular Neovim setups

Date: 2026-11-12, branch `dev`, round 3. This is a self-assessment by the author of the config (an AI-assisted one): a list of claims with the evidence next to each. The pictures and numbers are the argument; whether something looks good is for you to judge. Companion files: [ui-community.md](ui-community.md) (what communities ask for), [gaps-and-plan.md](gaps-and-plan.md), [screenshots/competitors/README.md](screenshots/competitors/README.md) (sources and dates of every competitor picture), [screenshots/ui3/README.md](screenshots/ui3/README.md) (how the xynovim pictures were made).

## What this is based on, and what it is not

- **xynovim (strong evidence):** `tests/ui-community_spec.lua` (97 checks, all run with `XYNOVIM_DEV_PLUGINS=~/projects/xyno-plugins`) reads the real grid of a headless Neovim (`screenstring`, `nvim__inspect_cell`) and computes WCAG 2.x ratios itself. Real pixels: a private Ghostty 1.4.0 window on X11, JetBrainsMono Nerd Font Mono, grabbed with ImageMagick `import`, driven by a real rust-analyzer and bacon-ls on a throw-away crate. I looked at every picture before using it.
- **Competitors (weak evidence):** pictures are the vendors' own marketing and documentation pages, cropped (see the competitors README for URL and date of each). Only RustRover and VS Code show **Rust** in an editor; Zed, AstroNvim, NvChad and LazyVim show TypeScript, Lua or JavaScript, and Helix shows no editor picture a headless browser can render. No competitor editor was installed or run. So a competitor cell is either "what the vendor's picture shows", a number computed from a published colour value, or **not shown**. "Not shown" is not "worse".
- **Column counts are not exact.** The window is tiled by the compositor to 941 px wide, so the font size was tuned until `&columns` came close: the real grids were 78 (target 80), 117 (target 120) and 234 (target 200: the font cannot go smaller than about 5.6 pt without being unreadable, and the 234-column pictures are small at 941 px). The file names say the target.
- Reddit was not reachable. Linux, Ghostty and one font only; WezTerm, kitty, Windows Terminal, iTerm2 not checked.

Verdict key: **ahead** = I can show a measured or visible difference in xynovim's favour; **tied**; **different** = a design choice; **behind** = I can show the gap; **unknown / not shown** = no evidence on the other side.

## Side by side, per aspect

### 1. Diagnostics

| | |
|---|---|
| xynovim | Full text on the cursor line, code only elsewhere, ellipsis inside the window, glyph + underline style per severity. Picture: [dark-120](screenshots/ui3/dark-120.png) (line 19), [at 80 columns](screenshots/ui3/dark-80.png). The compiler's own rendering is `<leader>cD`: [diagfloat3-120](screenshots/ui3/diagfloat3-120.png), [at 80](screenshots/ui3/diagfloat3-80.png), [at 234](screenshots/ui3/diagfloat3-200.png). |
| Others | Zed (TypeScript): error text in a tinted block at the end of the line, several lines at once ([zed-editor-ts-diagnostics](screenshots/competitors/zed-editor-ts-diagnostics.png)). VS Code (Rust): red squiggle and a quick-fix bulb ([vscode-rust-completion](screenshots/competitors/vscode-rust-completion.png)). RustRover (Rust): the "Add missing fields" quick-fix list with a change preview ([rustrover-quickfix-rust](screenshots/competitors/rustrover-quickfix-rust.png)). Helix: per-severity cursor-line policy in its docs (docs.helix-editor.com/editor.html, read earlier), no picture. |
| Verdict | **Tied** with Zed on how an inline message looks (same idea: text after the code, tinted); policy tied with Helix's documented one; **ahead** of the LazyVim default (every line) per the issues read earlier. |
| Worse | RustRover shows a quick-fix list with a preview in the same picture; xynovim's equivalent (`:RustActions`, diff preview, a plugin feature) was **not photographed** this round, so I cannot show it. The cursor-line text is wider than the window at 80 columns and ends in `…` (see dark-80), so the full message needs `<leader>cD`. |

### 2. Inlay hints (item 16 of the shortlist, built this round)

| | |
|---|---|
| xynovim | Inline (default) and **end of line** (`:Hints eol`): the code columns do not move. Pictures: inline [dark-120](screenshots/ui3/dark-120.png) vs eol [eol-120](screenshots/ui3/eol-120.png), [eol-80](screenshots/ui3/eol-80.png), [eol-200](screenshots/ui3/eol-200.png), eol in the light theme [eollight-120](screenshots/ui3/eollight-120.png). The grid test (real rust-analyzer) asserts that `= answer()` moves left by exactly the hint's width when switching to eol, that `a=1  b=2` is at the end of the call line and that the hint text is >= 4.5:1. Per-kind switches (`types`, `params`, `lifetimes`) work in both modes. Hint text contrast 6.07:1 dark, 6.94:1 light. |
| Others | VS Code, Rust, inline chips ([vscode-rust-inlay-hints](screenshots/competitors/vscode-rust-inlay-hints.png)); its docs page names the setting `editor.inlayHints.enabled`. Zed's Rust docs page shows only rust-analyzer's `inlayHints` JSON ([zed-docs-rust-page-text-only](screenshots/competitors/zed-docs-rust-page-text-only.png)). RustRover: inline. I did **not** find an end-of-line mode in the pages I read; I did not search their settings reference exhaustively. VS Code default hint contrast 5.31:1 and tokyonight 2.47:1 are computed from their published colours (earlier round). |
| Verdict | **Ahead** on having a choice that I can show; **tied** on inline hints. |
| Worse | The eol text is a summary I build (`n: i32`, `a=1  b=2`), not the server's label parts: no hover, no go-to-type on a hint, no "insert this type". A line too long for its window gets no hints. Hints are requested by me (one request per edit pause, 150 ms to 1.5 s), so they can lag behind the built-in renderer. In eol mode the first request after start can return nothing while rust-analyzer loads (found on a real capture at 80 columns; the code now asks again up to 8 times). |

### 3. Statusline

| | |
|---|---|
| xynovim | Mode, branch, diagnostic counts, file, symbol, server state (`RA ready | clippy 1E`), hint state (`hints TPL`, `hints TPL eol`), position; priority collapse at narrow widths. [dark-120](screenshots/ui3/dark-120.png), [dark-80](screenshots/ui3/dark-80.png). |
| Others | NvChad: mode, file, branch, diagnostics, LSP name ([nvchad-js-editor](screenshots/competitors/nvchad-js-editor.png)). AstroNvim: branch, language, LSP, tree-sitter flag, position ([astronvim-lua-editor](screenshots/competitors/astronvim-lua-editor.png)). VS Code: `0 errors 0 warnings`, rust-analyzer progress ([vscode-rust-completion](screenshots/competitors/vscode-rust-completion.png) is cropped above it; the status bar is in the page text). |
| Verdict | **Different**. xynovim shows more server state (rust-analyzer and clippy separately) than the two Neovim distributions' pictures; whether more is better is taste. |
| Worse | At 117 columns the bar holds nine items; I have no measurement that people read them. |

### 4. Tabs and file tree

| | |
|---|---|
| xynovim | Bufferline with error counts, tree with the error colour on names: [round 2 tree picture](screenshots/ui2/rust-after-tree-120.png). **Not re-photographed in round 3.** |
| Others | NvChad: tabs with close buttons, tree with git colours; AstroNvim: tree with a warning marker; LazyVim: tree with markers (competitor pictures above). VS Code and RustRover: no tree in the Rust pictures I have. |
| Verdict | **Tied** with the distributions on features visible in their pictures; no new evidence. |
| Worse | A tab name is not coloured by diagnostics (the count after it is). The local-history panel opens as a tab titled `[No Name]` ([history2-120](screenshots/ui3/history2-120.png), top): found on the real picture, **not fixed** (the plugin names no buffer). |

### 5. Dashboard

| | |
|---|---|
| xynovim | [Round 2 dashboard pictures](screenshots/ui2/dash-after-120.png). **Not re-photographed.** |
| Others | LazyVim and AstroNvim show their dashboard on their sites (earlier pictures in `screenshots/`). |
| Verdict | **Unknown** against the others. |
| Worse | Still open from round 2: at 119x29 the entry list is cut at the bottom and an empty statusline-coloured bar shows under it. Not fixed in round 3. |

### 6. Popups and panels (plugin windows)

Captured with `XYNOVIM_DEV_PLUGINS=~/projects/xyno-plugins`, each at the three widths. None of these exist in the other editors in this form, so there is nothing to put beside them.

| Window | Pictures | Seen, and what was done |
|---|---|---|
| Sandbox policy (`:XynoSandboxPolicy`) | [80](screenshots/ui3/sandbox-80.png), [120](screenshots/ui3/sandbox-120.png), [234](screenshots/ui3/sandbox-200.png) | Before: a long path or rule wrapped at the last cell, cutting words and putting the rest under the label (first capture at 120 columns). Now: wrap at words with a hanging indent (`style_popup`, tested). |
| Local-history panel (`:LocalHistoryPanel`) | [80](screenshots/ui3/history2-80.png), [120](screenshots/ui3/history2-120.png), [234](screenshots/ui3/history2-200.png) | Works: list, changed files, diff with `-`/`+` colours. Not fixed: the `[No Name]` tab; three snapshots made within one second all read `now`. |
| Macros (`:MacroSignature` on a call) | [80](screenshots/ui3/macros3-80.png), [120](screenshots/ui3/macros3-120.png), [234](screenshots/ui3/macros3-200.png) | See "Not shown" below. |
| Proc-macro report (`:ProcMacroStatus`) | [80](screenshots/ui3/procmacro-80.png), [120](screenshots/ui3/procmacro-120.png), [234](screenshots/ui3/procmacro-200.png) | The first line carried the whole project path and was cut at the window edge; now it wraps (xyno-macros.nvim `dev`, commit `dc1aa05`, not published). |
| Run-configuration picker (`:RustRun`) | [80](screenshots/ui3/runcfg3-80.png), [120](screenshots/ui3/runcfg3-120.png), [234](screenshots/ui3/runcfg3-200.png) | See "Not shown" below. |
| Test results panel (`<leader>tp`, fed by a real `cargo test` of a crate with two failing `assert_eq!`) | [80](screenshots/ui3/results-80.png), [120](screenshots/ui3/results-120.png), [234](screenshots/ui3/results-200.png) | Header with counts, failure list with file:line, structural `-`/`+` diff of left and right. Nothing to fix seen. |
| Diagnostic float (`<leader>cD`) | [80](screenshots/ui3/diagfloat3-80.png), [120](screenshots/ui3/diagfloat3-120.png), [234](screenshots/ui3/diagfloat3-200.png) | See picture. |

Verdict: **not comparable**; the real windows are measured on the grid (>= 4.5:1 text, solid float, one border) and now also photographed. **Worse / open:** see the "Not shown" notes and the two unfixed items above.

### 7. Theming

| | |
|---|---|
| xynovim | One dark scheme (the RustRover Dark export, "Island Dark"; identity unchanged), a hand-tuned light scheme, `:IslandContrast high`, an opt-in Okabe-Ito diagnostic palette. |
| Others | NvChad's page says "68 inbuilt ... themes" (read on [nvchad-js-editor](screenshots/competitors/nvchad-js-editor.png)'s page, 2026-11-12); catppuccin and tokyonight ship their own families; VS Code and Zed have theme marketplaces. |
| Verdict | **Behind** on the number of themes (two plus a contrast mode against dozens) by design; **ahead** only in that every key group has a checked ratio. |

### 8. Icon fallback without a Nerd Font

`:XynoIcons ascii` rebuilds statusline, tabs, dashboard, file icons, dap-ui and code-lens titles at run time ([round 2 ASCII picture](screenshots/ui2/rust-after-ascii-120.png), not re-photographed). AstroNvim has `icons_enabled = false` (docs); NvChad documents the font fix only. **Tied** with AstroNvim, **ahead** of NvChad. Worse: the tree's expander arrows and git/diagnostic symbols are read at startup only.

### 9. Light mode (redone this round: hand-tuned)

`:colorscheme island-light`: [light-80](screenshots/ui3/light-80.png), [light-120](screenshots/ui3/light-120.png), [light-234](screenshots/ui3/light-200.png); the dark picture of the same moment is [dark-120](screenshots/ui3/dark-120.png). The first version (round 2) was derived from the dark scheme by a lightness flip ([old picture](screenshots/ui2/rust-after-light-120.png)).

How the new palette was made: every dark colour of the scheme got one chosen light colour (`lua/island/light_palette.lua`, the header lists the reasoning), same hue roles as Island Dark (orange keyword, green string, teal number, blue function, magenta field, olive type, amber macro). I read the sources of JetBrains Light and Islands Light (`Light.xml`, `ManyIslandsLight.theme.json` in intellij-community), GitHub Light (github-nvim-theme `primitives/light.lua`), catppuccin-latte (`palettes/latte.lua`) and tokyonight-day (`extras/lua/tokyonight_day.lua`; its `colors/day.lua` generates day from night by an HSLuv lightness inversion, i.e. a derived scheme too). Contrast on each scheme's own editor background, computed here from the published hex values (which highlight group uses which colour is the usual mapping, not verified in each plugin's group table):

| Role | Island Light | JetBrains Light | GitHub Light | catppuccin latte | tokyonight day |
|---|---|---|---|---|---|
| background | #ffffff | #ffffff | #ffffff | #eff1f5 | #e1e2e7 |
| text | 15.92 | 20.03 | 15.80 | 7.06 | 4.52 |
| keyword | 6.07 | 9.88 | 5.36 | 4.79 (mauve) | 3.33 (purple) |
| string | 5.84 | 5.31 | 12.81 | 2.96 (green) | 4.04 (green) |
| number | 5.79 | 6.21 | 7.59 | 2.64 (peach) | 3.69 (orange) |
| function | 6.23 | 6.94 | 7.34 | 4.34 (blue) | 3.11 (blue) |
| comment | 5.27 | 3.36 | 6.39 | 2.30 (overlay0) | 2.54 |
| line numbers | 4.55 | 2.24 | n/a | n/a | n/a |

The spec checks 46 key groups against explicit minimums (normal text >= 12:1, syntax >= 5:1, comments, line numbers, hints, winbar, code lens, diagnostics >= 4.5:1, text on selection / cursor line / search / diff fills >= 7:1, float border >= 3:1) and the old per-group rule (no group below min(its dark ratio, 4.5:1)). High contrast on top of light (`:IslandContrast high`, [lighthigh-120](screenshots/ui3/lighthigh-120.png)) still reaches 7:1 / 4.5:1 on every visible group.

| Verdict | **Ahead** on measured contrast of the syntax colours and comments against catppuccin latte, tokyonight day and JetBrains' own comment colour; **tied** with GitHub Light on numbers. On *looks* I give no verdict. |
|---|---|
| Worse | One person's tuning by eye on one machine and one sample file; no second pair of eyes, no colour-blindness simulation of the light palette. A few colours that plugins derive from the dark ones at run time still go through the old lightness flip (a fallback with a contrast floor, not hand-picked). Warning text is a dark amber (`#8f6400`) to reach 5:1, which reads brown. Only the Rust sample was photographed. |

### 10. High contrast

`:IslandContrast high` (dark and light): every visible group 7:1, frames 4.5:1, hue kept ([dark](screenshots/ui2/rust-after-high-120.png), [light](screenshots/ui3/lighthigh-120.png)). VS Code and JetBrains ship High Contrast themes (not measured). **Different**: a mode of the same theme, not a separate theme. Worse: in the Rust sample the difference to normal is small to the eye; it shows in the muted tones and in the numbers.

### 11. Accessibility

Severity is never colour alone (glyph, underline style, text), checked with all four colours forced to one grey; Okabe-Ito toggle; ASCII icons; contrast numbers per group. **Unknown** against the others: no competitor measured. **Behind, expected, not verified:** a terminal editor exposes no accessibility tree; GUI editors can, and I did not test any screen-reader support in any product.

### 12. Narrow windows

78 columns: [dark-80](screenshots/ui3/dark-80.png), [light-80](screenshots/ui3/light-80.png), [sandbox-80](screenshots/ui3/sandbox-80.png), [results-80](screenshots/ui3/results-80.png), [eol-80](screenshots/ui3/eol-80.png). 60 columns (round 2): [rust-after-60](screenshots/ui2/rust-after-60.png). The statusline drops items by priority and keeps the file name; messages end in `…`; popups wrap at words. **Tied** with lualine / mini.statusline practice and Helix's element list on technique; the competitor pictures are all wide, so there is no narrow competitor evidence.

## Not shown, honestly

- **Macros popup.** `:MacroSignature` on a `macro_rules!` call did not open a window in the capture (see [macros3-120](screenshots/ui3/macros3-120.png): cursor on `pair!(1, 2)`); the reason was not established in this round. The popup's colours are covered by the grid spec; the window itself is **not photographed**. (Debug capture `macros4` records what the command reported; see the ui3 README.)
- **Run-configuration picker.** `:RustRun` opened floating windows according to the window list, but the picture shows none of them (see [runcfg3-120](screenshots/ui3/runcfg3-120.png)); the picker is a snacks picker and the cause (it may close when the capture window loses focus) was not established. **Not photographed**.
- Competitor Helix editor: none obtained.
- Tabs, tree, dashboard, ASCII mode: round-2 pictures only.

## Things found by looking and fixed this round

1. Plugin popups wrapped mid-word with no hanging indent (sandbox policy): fixed in `style_popup`, with a test.
2. Proc-macro report first line cut at the window edge: fixed in xyno-macros.nvim `dev`.
3. End-of-line hints were empty on a real window because rust-analyzer answers `[]` while loading: the module asks again. (The headless test had not shown it.)
4. Island Light: derived palette replaced by the hand-tuned one; `Normal` is #ffffff instead of #f5f7fb.

## Website

Unchanged since round 2 (`https://xynorash.github.io/xynovim/`, no horizontal overflow at 1106 px and, in a 390 px iframe, none on three pages).
