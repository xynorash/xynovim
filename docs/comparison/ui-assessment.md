# UI assessment: xynovim against RustRover, VS Code, Zed, Helix and the popular Neovim setups

Date: 2026-11-12, branch `dev`. This is a self-assessment by the author of the config (an AI-assisted one), so read it as a list of claims with their evidence, not as a neutral review. Companion to [ui-community.md](ui-community.md) (what communities ask for) and [gaps-and-plan.md](gaps-and-plan.md).

## What this is based on, and what it is not

- **Own measurements (strong evidence):** `tests/ui-community_spec.lua` (about 90 checks) renders the real UI in a headless Neovim and reads the characters (`screenstring`) and the colours (`nvim__inspect_cell`) of the cells, with WCAG 2.x contrast computed in the spec itself. Real pixels: Ghostty 1.4.0 as an X11 window, grabbed with ImageMagick `import -window <id>`, files in [screenshots/ui2/](screenshots/ui2/README.md). I looked at each image before using it.
- **Competitor evidence (weak):** the screenshots already in [screenshots/](screenshots/) are marketing/home pages (RustRover, Zed, Helix, LazyVim, AstroNvim, NvChad, VS Code docs), not editor panes. I did **not** capture fresh pictures of competitor editors in this round, and no competitor editor was run. So every "better" below that compares against a competitor rests on documented behaviour (cited in ui-community.md and notes.md), on published defaults, or on my own number for xynovim with *no* number for them. Where there is no number for the other side the verdict is **unknown**, not "better".
- Reddit was not reachable (browser safety block, HTTP 403). Nothing here is drawn from Reddit threads.
- Linux, Ghostty, JetBrains Mono Nerd Font only. Nothing was checked in WezTerm, kitty, Windows Terminal, iTerm2 or tmux in this round (the terminal health check from round 1 only inspects the environment).

## Side by side

Verdict key: **better** = I can show a measured or documented difference in xynovim's favour; **different** = a design choice, neither clearly better; **worse** = I can show the gap; **unknown** = no evidence on the other side.

| Area | xynovim now | Others (evidence) | Verdict |
|---|---|---|---|
| Diagnostics inline | Full text on the cursor line, code or few words for Error/Warn elsewhere, Info/Hint hidden elsewhere, ellipsis inside the window, two tiers de-duplicated (round 1) | Helix: per-severity cursor-line policy (docs.helix-editor.com/editor.html). Error Lens / Zed request: inline text always. LazyVim default: every line, duplicates reported in issues | Tied with Helix on the policy, **better** than the LazyVim default; Zed/VS Code inline modes were not run |
| Diagnostic text as the compiler prints it | `<leader>cD` float: rustc text with kind, location, gutter, carets, note/help coloured; wraps and is tall enough for its text | rustaceanvim `:RustLsp renderDiagnostic` shows the text in a float without per-part colour (read from its source). RustRover shows rendered text in a popup; Zed issue 7844 asks for it (297 reactions) | **Better** than rustaceanvim (colour); **unknown** against RustRover (not compared pixel by pixel) |
| Severity not by colour alone | Sign glyph, virtual-text glyph and underline style all differ per severity; checked on the grid, and again with all four colours forced to one grey | Okabe-Ito toggle (already). No competitor measured | **Unknown** (no competitor number); the property holds here |
| Contrast, default | Hints 6.07:1, comments 4.5:1, popups, tab counts, winbars and tree error colour at or above 4.5:1 (checked per group) | VS Code default hint 5.31:1 (from its source), tokyonight 2.47:1 (computed from its source). Zed dark themes called low-contrast by several HN commenters | **Better** than tokyonight and VS Code on hints; others **unknown** |
| High-contrast variant | `:IslandContrast high`: every visible group with a foreground at 7:1 (frames 4.5:1), hue kept, 4 colour pills moved instead of their text | VS Code ships High Contrast themes; JetBrains has a High contrast theme. Not measured | **Different** (a dark variant of the same theme, not a separate theme), contrast numbers only for xynovim |
| Light variant | `:colorscheme island-light`, derived by lightness flip, every group keeps the dark scheme's contrast (capped), own background | JetBrains Islands has a hand-made light scheme (not measured, I only have the dark export); catppuccin, tokyonight ship light variants | **Worse** in craft (a derived palette, not designed: accents look darker and flatter, see the capture), **better** in having a per-group contrast guarantee |
| Icons without a Nerd Font | `:XynoIcons ascii` rebuilds statusline, tabs, dashboard, file icons, dap-ui, code-lens titles at run time | AstroNvim has `icons_enabled = false` (docs). NvChad documents the font fix only | **Tied** with AstroNvim, **better** than NvChad. Not at run time: tree expander arrows, git and diagnostic symbols |
| Terminal compatibility check | `:checkhealth xynovim` section (tmux, Ghostty min-contrast, WezTerm, kitty, console) | tokyonight documents tmux overrides in its README; no health check seen elsewhere | **Better** than documentation-only; only the environment is inspected |
| Narrow windows | Statusline priority collapse, file name never cut, text ellipsis | lualine/mini.statusline best practice; Helix element list | **Tied** (the same technique), checked at 60/80/120/200 columns |
| Transparency + floats | Spec on the grid: transparent editor surfaces, solid floats, borders, titles and footers solid, one border | tokyonight offers float modes; LazyVim issue 6943 shows an empty statusline block on the dashboard | **Different**; the dashboard statusline row still shows an empty bar (see Worse) |
| File tree error colour | Name of a file or folder with an error in the error colour | VS Code colours names; Zed issue 4901 comment wants it | **Tied** with VS Code on tree; **worse** on tabs (count only) |
| Plugin popups | Sandbox policy, history panel, proc-macro report and guard state measured on the real windows (dev plugins) | No equivalent in the other editors | **Not comparable**; found and fixed below-4.5:1 text |
| Winbar breadcrumbs | Opt-in (`:XynoWinbar`), statusline keeps its own | Zed and VS Code show breadcrumbs by default; dropbar/navic exist for Neovim | **Different**; off by default on purpose |
| Debugger / test panels | Unchanged this round | Complaints exist for dap-ui and neotest (notes.md section 9) | **Unknown / behind**, not worked on here |

## What changed in this round

1. Dashboard tagline: "Rust in Neovim, AI agent sandboxed". The old text claimed the whole editor was sandboxed by default; only the 99 agent runs in bubblewrap. A spec scans the README, the site, the docs and the plugin spec so the old phrase cannot return.
2. Light variant `island-light` and a complete high-contrast variant (see table). Both are checked group by group on every highlight group of the running config (about 1,000), including groups plugins define after the theme.
3. Items #13 (rustc-style float), #14 (tree error colour), #15 (opt-in winbar). #16 (end-of-line hints) was **not** built.
4. `:XynoIcons` at run time. Gaps closed: rust-analyzer code-lens "Debug" gear and "Run" arrow, mini.icons file icons, dap-ui icons, the dashboard "startup" bolt, the lualine branch glyph, the tree's folder and file icons.
5. Things found only by rendering the real UI and fixed: `WinBarNC` was 3.46:1; bufferline's error count was 2.55:1; the history panel's diff-delete lines were 3.59:1 and its age text 3.5:1; lualine kept ASCII separators after `:XynoIcons nerd`; the sandbox policy float cut its last lines with `@@@` (plugin clone fixed on its `dev` branch, not published); `lazy` caches plugin opts, so a naive run-time rebuild changed nothing; calling neo-tree's `setup()` twice silently drops its diagnostics/git events (so the tree is not re-setup).
6. Not changed: Island Dark's identity (same palette, same groups). Normal mode of the dark theme only gained the contrast lifts listed above.

## What is still worse, or not verified

- The dashboard on a 119x29 window: the entry list is cut at the bottom by the statusline bar, and an empty statusline-coloured bar shows on the dashboard (visible in `dash-after-120.png`). I did not fix this round.
- The lens gear glyph sits tight against the word "Debug" in JetBrains Mono (font metrics, not changed).
- A tab name is not coloured by diagnostics (bufferline has no hook for it); the count after the name is.
- Light variant: derived, not designed. I looked at one captured screen only.
- The sandbox popup's title and footer cells could not be checked on the grid (the multigrid reads for those rows returned other plugins' highlights); they are checked through their groups (>= 4.5:1) and winhighlight mapping; the popup was not photographed.
- Real-popup tests need `XYNOVIM_DEV_PLUGINS`; with the locked plugin versions they print SKIP.
- Competitor editors were not run; competitor numbers come from documents and source reading only.

## Website

`https://xynorash.github.io/xynovim/` was opened in Chrome on 2026-11-12. No horizontal overflow at the desktop width (1106 px) and, measured in a 390 px iframe (the browser window could not be made narrower), none on the home page, the debugging guide and the plugins page. The pages still say "the AI agent runs inside a sandbox" (true). No layout change was needed, so `site/` is unchanged. Not checked: every guide page, tablet widths, other browsers.
