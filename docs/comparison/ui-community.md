# Community-driven UI research for Rust editing

Retrieved: 2026-11-12. Scope: what public communities say about the UI of RustRover, VS Code, Zed, Helix and the popular Neovim setups (LazyVim, AstroNvim, NvChad, rustaceanvim), and what that means for xynovim. Everything is summarised in my own words; no usernames were collected, no themes or configs were copied.

## How to read this (and what it cannot claim)

- **Sources actually read** are the ones tagged `[read]` below: GitHub issues (via the GitHub API: title, body start, reaction counts), vendor docs, a Hacker News thread (Algolia API), the VS Code marketplace page, plugin READMEs. Star counts and licences come from the GitHub API on the retrieval date.
- **Indirect** sources are tagged `[indirect]`: Reddit threads whose content I only saw as search-engine summaries. Reddit itself could not be opened: Claude in Chrome refuses reddit.com ("not allowed due to safety restrictions"), and web fetch got HTTP 403 from Reddit and its mirrors. So **no r/neovim, r/rust or r/unixporn thread was read directly**. Indirect sources count in the "sources" column but are marked, and no ranking depends on a single indirect source.
- Not reached at all: Zed and JetBrains forum threads on diagnostics contrast (searches returned nothing usable), dev.to (no relevant article found), theme galleries beyond repo READMEs and star counts. Debugger and test panel readability: **no direct complaint text was found**, so that area stays `unknown` (see "Open gaps").
- "Independent sources" = distinct projects/sites/threads, not comments. Reaction counts are cited when available because they are a harder signal than a count of threads.
- Score = min(sources, 6) x impact (1-5) / effort (S=1, M=2, L=3). It is a ranking aid, not a measurement.

## Source list

| ID | Source | Kind | What it gave |
|---|---|---|---|
| Z1 | Zed issue 4901 https://github.com/zed-industries/zed/issues/4901 | read | Request to see errors inline without hovering: 382 thumbs-up, 67 comments; later comment also wants error colour on tab and tree file names like VS Code |
| Z2 | Zed issue 7844 https://github.com/zed-industries/zed/issues/7844 | read | Request for readable, "pretty" compiler/TypeScript error text: 297 thumbs-up |
| Z3 | Zed settings docs https://zed.dev/docs/configuring-languages | read | Inlay hints: global switch plus separate type / parameter / other kinds |
| Z4 | Hacker News "Zed Editor Theme-Builder" https://news.ycombinator.com/item?id=48076651 (274 points) | read | About six distinct commenters call default dark themes low-contrast "gray on gray"; some tweak all dark themes by hand |
| H1 | Helix issue 1462 https://github.com/helix-editor/helix/issues/1462 | read | Diagnostics drawn over code; 55 thumbs-up; led to the redesign |
| H2 | Helix editor docs https://docs.helix-editor.com/editor.html | read | Inline diagnostics configured per severity for the cursor line vs other lines, end-of-line option, max count, wrap limit; recommended setup shows hints at end of line and warnings only on the cursor line; statusline is a list of elements |
| H3 | Helix issue 5758 https://github.com/helix-editor/helix/issues/5758 | read | Wish to move the statusline to the top; maintainers declined |
| V1 | Error Lens, VS Code marketplace https://marketplace.visualstudio.com/items?itemName=usernamehw.errorlens | read | 10.3M installs; inline text and line tint, severity filter, optional "active line only", optional delay |
| V2 | VS Code issue 145191 (padding around inlay hints) | indirect | Hints feel heavy; wish for a more compact style |
| R1 | RustRover help, Inlay Hints settings https://www.jetbrains.com/help/rust/2025.3/viewing-reference-information.html | read (via search excerpt) | Hints for parameters, types, chains, borrows, each switchable in Settings |
| R2 | JetBrains support thread on Rust inline hints https://intellij-support.jetbrains.com/hc/en-us/community/posts/6598348961170/comments/6601243177874 | indirect (403 on fetch) | Users ask how to configure Rust hints; answer points to per-hint settings |
| N1 | Neovim discussion 28352 https://github.com/neovim/neovim/discussions/28352 | read | Hints that push code sideways are frustrating while editing; request for a non-displacing style; closed as duplicate |
| N2 | rustaceanvim issue 639 https://github.com/mrcjkb/rustaceanvim/issues/639 | read | Wish for end-of-line hints instead of inline |
| N3 | rustaceanvim issue 442 https://github.com/mrcjkb/rustaceanvim/issues/442 | read | Wish for coloured rustc output in the diagnostic popup (rust-analyzer LSP extension exists) |
| N4 | r/neovim "what colour do you use for inlay hints" (2024-05) | indirect | Mid-line hints disliked by some; people choose very different colours |
| N5 | r/rust "what IDE for Rust" (2024-12) | indirect | One Neovim user toggles hints because they are noisy |
| N6 | rust-analyzer issue 4334 https://github.com/rust-lang/rust-analyzer/issues/4334 | indirect | Hint colour too close to code text; people want a clearly different tone |
| D1 | tiny-inline-diagnostic README + issue list https://github.com/rachartier/tiny-inline-diagnostic.nvim | read | 1,749 stars (MIT, 2026-11-12). Overlay style that does not shift lines, 8 presets incl. `nonerdfont`; its issue 91 "multiple diagnostics showing" and 144 "outdated diagnostic displayed" show duplicate/stale rendering is a recurring pain |
| D2 | LazyVim issue 1819 https://github.com/LazyVim/LazyVim/issues/1819 | read | Two servers' errors both shown inline |
| D3 | rustaceanvim issue 973 https://github.com/mrcjkb/rustaceanvim/issues/973 | read | Feature request for bacon-ls diagnostics (clippy tier) |
| D4 | LazyVim issue 750 https://github.com/LazyVim/LazyVim/issues/750 | read | Users want an easy switch for virtual text / virtual lines |
| I1 | AstroNvim docs, icons recipe https://docs.astronvim.com/recipes/icons | read (via search excerpt) | Built-in `icons_enabled = false` for terminals without a Nerd Font |
| I2 | AstroNvim issues 812, 1848, 1772 https://github.com/AstroNvim/AstroNvim/issues/812 | read | Missing or wrong icons (iTerm2 bug; Nerd Fonts v3 codepoint moves) |
| I3 | kickstart.nvim PR 711, mini.icons ascii style, NvChad FAQ | indirect | Unicode/ASCII icon alternatives; NvChad only says "install a Nerd Font" |
| T1 | tokyonight README https://github.com/folke/tokyonight.nvim | read | tmux needs `Smulx` and `Setulc` overrides for coloured undercurl (tmux 3.0+); `transparent`, and float/sidebar modes dark / transparent / normal. 8,258 stars (Apache-2.0) |
| T2 | WezTerm issue 415 https://github.com/wez/wezterm/issues/415 | read | Undercurl missing in WezTerm, fixed after terminfo/`Smulx` workarounds; ConPTY still blocks it on Windows |
| T3 | Ghostty config reference https://ghostty.org/docs/config/reference | read | `minimum-contrast` (WCAG ratio, 1-21) can silently re-colour low-contrast text, e.g. dim hints |
| T4 | LazyVim issue 6943 https://github.com/LazyVim/LazyVim/issues/6943 and lualine issue 1401 | read | Transparent theme: empty dark statusline on the dashboard since Neovim 0.11 highlight inheritance change |
| T5 | r/neovim "double borders with 0.11" (2025-04) | indirect | `winborder` plus plugin borders gave doubled borders |
| T6 | catppuccin/nvim README, rose-pine changelog, kanagawa README | indirect | Each exposes a float-transparency / solid choice and notes border interplay |
| C1 | github-nvim-theme, nightfox.nvim, caret.nvim, achroma.nvim | indirect (repo descriptions) | Colour-blind variants (protan/deutan/tritan) or modes exist in several popular themes |
| S1 | lualine docs, mini.statusline docs, Helix statusline docs | read/indirect | Components can hide below a width; Helix lets users list elements |
| S2 | Dropbar (1,612 stars, GPL-3.0), nvim-navic (1,681 stars, Apache-2.0) | read (stars only) | Breadcrumb plugins are mainstream, but no complaint text was read |
| S3 | catppuccin issues 22 and 2 https://github.com/catppuccin/nvim/issues/22 | read (titles) | Contrast complaints on bufferline tabs and a tree root folder |
| P1 | LazyVim NEWS / commit "use snacks.dashboard as default" | indirect | The most popular distribution moved to a section-based dashboard; no opinion thread read |

Popularity context (GitHub API, 2026-11-12): snacks.nvim 8,211 stars; lualine 8,182; catppuccin 7,662; kanagawa 6,449; nightfox 4,099; nvim-dap-ui 3,389; neotest 3,120; trouble 6,924; mini.statusline 108.

## What the communities say, grouped

### (a) Complaints and wishes
- **Diagnostics hide code or overwhelm it** (H1, Z1, D1): people want the message visible without hovering, but not covering code or filling every line. Helix answered with per-severity, cursor-line-first rendering; Error Lens offers "active line only"; tiny-inline-diagnostic answers with an overlay that does not push lines.
- **Duplicate and stale diagnostics** (D1 issues 91/144, D2, D3): two servers reporting the same problem is a recurring complaint in LazyVim and rustaceanvim land.
- **Inlay hints** (N1, N2, N4, N5, N6, V2): noisy, shift text, colour too close to code (N6) or too faint. Both directions occur, so the safe answer is a toggle plus tuned contrast, not one fixed look.
- **Low contrast defaults** (Z4, S3, N6): the strongest direct evidence is the Zed theme thread, where several people independently describe dark themes as too grey.
- **Missing icons** (I1, I2, I3): a steady stream of "icons broken" issues; AstroNvim shipped a switch, NvChad only documents the fix.
- **Terminal quirks** (T1, T2, T3): undercurl in tmux/WezTerm, and Ghostty's contrast adjustment altering dim colours.
- **Transparent themes break chrome** (T4, T5): dashboard statusline, doubled float borders.
- **Readable compiler output** (Z2 with 297 thumbs-up, N3): people want rustc/TypeScript errors formatted, not raw.

### (b) Praised features
- Inline diagnostics as text (Error Lens at 10.3M installs, Zed issue 4901 at 382 reactions): the single most demanded UI feature.
- Per-kind inlay hint control (Z3, R1).
- A Helix-like, severity-aware, cursor-line-first diagnostic policy (H2) - cited by users as the fix for the noise.
- Colour-blind variants shipping in popular themes (C1).
- Theme builders and visible control over contrast (Z4).

### (c) Popular public ideas (with source counts) - see the scored table next.

## Scored table

Support counts independent sources from the list above; "(i)" means one of them is indirect.

| # | Idea | Sources | Support | Proposal for xynovim | Effort | Score |
|---|---|---|---|---|---|---|
| 1 | Inlay hint toggle with per-kind control (types / params / lifetimes) | Z3, R1, R2(i), N5(i) | 4 | One `:Hints` style command and a `vim.g` default for kinds; show state in the statusline | S | 16.0 |
| 2 | Cursor-line-first diagnostics: full text on the cursor line, short marker or Error/Warn only elsewhere | H1, H2, V1, Z1, D1 | 5 | Severity filter for non-cursor lines (Error+Warn), everything on the cursor line; keep the [source] suffix | M | 12.5 |
| 3 | Hint legibility: subordinate to code but not faint | N6(i), N4(i), V2(i), Z4 | 4 | Raise hint text to at least 4.5:1 against its chip (now 3.2:1, measured); keep chip optional | S | 12.0 |
| 4 | Do not rely on colour alone for severity (shape, underline style, glyph) | C1(i), Okabe-Ito already shipped, T1 | 3 | Distinct sign glyphs per severity and undercurl/underline/dotted differences, documented | S | 9.0 |
| 5 | Terminal compatibility check and doc: truecolor, undercurl in tmux, WezTerm, Ghostty min-contrast | T1, T2, T3, T4 | 4 | `:checkhealth xynovim` section that inspects `$TMUX`, `$TERM`, terminfo `Smulx`/`Setulc`, and prints the exact fix; README note on Ghostty `minimum-contrast` | M | 8.0 |
| 6 | High-contrast theme variant on request | Z4, S3, N6(i), T1 | 4 | `vim.g.xynovim_contrast = "high"` raising muted text and comment tones; covered by the existing palette contrast spec | M | 8.0 |
| 7 | Transparency and float regression checks (statusline on dashboard, double borders) | T4, T5(i), T6(i), T1 | 4 | Add a spec that renders dashboard and a float with transparency on/off and asserts highlight groups; keep `winborder = rounded` | S | 8.0 |
| 8 | Narrow-window statusline that keeps the filename and server state | S1, H2, lualine docs | 3 | Priority collapse: drop branch/diff/encoding first; never truncate the filename to a stub | M | 7.5 |
| 9 | Icon fallback (no Nerd Font) | I1, I2, D1, I3(i), I3(i) | 5 | `vim.g.xynovim_icons = "ascii"` honoured by statusline, dashboard, diagnostics signs and tree | L | 6.7 |
| 10 | Truncate long virtual text with an ellipsis and offer the full text on demand | H1, H2, D1 | 3 | Width-aware format in `diagnostic_text`; `<leader>cd` style float already exists for the full text | M | 6.0 |
| 11 | Debounce diagnostics while typing | H2, V1 | 2 | Keep `update_in_insert` for the instant tier, add a short delay for virtual text redraw | S | 6.0 |
| 12 | Dashboard: keep minimal, project-branded header | P1(i), observation | 2 | Replace the stock LazyVim header with an xynovim one; keep short-window fallbacks | S | 6.0 |
| 13 | Readable compiler output in the float (coloured rendered message) | Z2, N3, Z1 comment | 3 | Render rust-analyzer's coloured-diagnostic payload or `rendered` text with highlights | L | 4.0 |
| 14 | Error colour on tab / tree file names | Z1 comment, V1 | 2 | Diagnostic highlight on bufferline and tree entries (Error only) | S | 4.0 |
| 15 | Opt-in winbar breadcrumbs | S2 (stars only), S1 | 2 | Keep breadcrumb in statusline by default; optional winbar | M | 2.0 |
| 16 | End-of-line hints that do not shift text | N1, N2, N4(i) | 3 | Only if a clean implementation exists; otherwise rely on the toggle (#1) | L | 2.0 |
| 17 | Merge duplicate diagnostics across servers | D1, D2, D3 | 3 | **Already done**: `config.ux.diagnostic_text` hides the duplicate tier | - | done |
| 18 | Okabe-Ito colour-blind palette toggle | C1(i) | 3 | **Already done** (`:ColorblindDiagnostics`) | - | done |
| 19 | Debugger and test panel readability | none read | 0 | `unknown`: no direct complaint text found; do not invent demand | - | unknown |

## Ranked shortlist: top 15 changes (by score)

1. Inlay hint toggle with per-kind control (16.0, S)
2. Cursor-line-first diagnostics with severity filter on other lines (12.5, M)
3. Hint legibility: lift hint text to 4.5:1 (12.0, S)
4. Severity not by colour alone (9.0, S)
5. Terminal compatibility health check and README fix list (8.0, M)
6. High-contrast variant (8.0, M)
7. Transparency and float regression spec (8.0, S)
8. Narrow-window statusline priority collapse (7.5, M)
9. ASCII icon mode (6.7, L)
10. Width-aware virtual text truncation (6.0, M)
11. Short debounce for virtual text while typing (6.0, S)
12. xynovim dashboard header (6.0, S)
13. Coloured, readable compiler output in the float (4.0, L)
14. Error colour on tab / tree file names (4.0, S)
15. Optional winbar breadcrumbs (2.0, M)

Tie at 2.0 with #15: end-of-line hints (#16 in the table), left out because it needs a new rendering path and the community signal is split.

## xynovim today (code reading plus a real run)

Run on 2026-11-12: `nvim` in a detached tmux pane (140x40, then 60x14), a throw-away crate in the scratchpad directory, captured with `tmux capture-pane -ep`. rust-analyzer was running; these are my observations, not screenshots of every state.

Code facts
- `lua/island/` is the colour theme (palette in `palette.lua`, groups in `init.lua`, about 1,200 lines). Diagnostics: `lua/plugins/editing-ui.lua` (virtual text with one line plus `[source]`, `update_in_insert = true`) and `lua/config/ux.lua` (`diagnostic_text` dedupe across the rust-analyzer and clippy tiers, Okabe-Ito toggle). `vim.o.winborder = "rounded"` in `options.lua`. Lualine with a Rust server status component and a sandbox state in `lua/plugins/lualine.lua`; custom `island-dark` lualine theme. Dashboard: snacks with a height-adaptive layout. Transparency: `plugin/after/transparency.lua` with `vim.g.xynovim_transparent = false` as the opt-out. Inlay hints configured in `lua/plugins/rustaceanvim.lua`.
- Not found in the code: an icon-fallback switch, a winbar (the WinBar highlight exists but no winbar is set), a severity filter for virtual text, a Rust-specific hint toggle (a general LazyVim toggle may exist; I did not verify it by running).

What I saw
- Dashboard (140x40): the header is the **LazyVim** banner, not an xynovim one. 14 entries with Nerd Font glyphs and one-letter keys, then the footer line "Neovim loaded 9/70 plugins in 33.69ms". No stray statusline row appeared in the captured text (colours of that row were not checked).
- Rust file (140x40): inlay hints are inline and visible (`let n: String`, closure parameter `&i32`, argument name `xs:`), type error shown as virtual text "expected String, found i32 [rust-analyzer]", Run | Debug code lens above `main`, git signs in the gutter, statusline showing mode, branch, filename, the breadcrumb `main` once the cursor was in the function, "RA ready | clippy 1E". The clippy unused-variable warning had not appeared after about 45 s in my run.
- Contrast, computed from the captured colour codes and palette: inlay hint text #868a91 on its chip #393b40 is **3.2:1**; the same text on the editor background #1e1f22 would be 4.75:1; main text #bcbec4 on #1e1f22 is 8.9:1.
- Narrow window (60x14): the statusline dropped the mode/branch block and the filename became a truncated stub (`<n.rs`), while the diagnostic virtual text was cut mid-sentence ("expected String, found") with no ellipsis and no way to see the rest on that line.

## Where xynovim stands against the baseline

Evidence is limited to what is in this file; "unknown" means I could not establish it.

| Item | vs. field | Evidence |
|---|---|---|
| Inline diagnostic text with source and tier de-duplication | ahead of LazyVim defaults, tiny-inline-diagnostic (open duplicate issues) | D1, D2, `ux.lua` |
| Severity-aware inline rendering (cursor line vs other lines) | **behind** Helix and Error Lens | H2, V1; xynovim shows every diagnostic everywhere |
| Inlay hint control | **behind** Zed and RustRover (per-kind UI) | Z3, R1 |
| Hint legibility | tied/unknown (no measured numbers for competitors) | 3.2:1 measured here only |
| Colour-blind support | ahead of LazyVim/AstroNvim/NvChad/Helix/Zed defaults as far as the searches show (absence of evidence, not proof) | C1, `ux.lua` |
| Icon fallback | **behind** AstroNvim | I1 |
| Terminal-compat guidance | **behind** theme READMEs such as tokyonight | T1 |
| Narrow-window statusline | **behind** lualine/mini.statusline best practice | observed at 60 columns |
| Dashboard on short windows | ahead (adapts down to about 18 rows, documented in `editing-ui.lua`) | code comment; not compared against others by running them |
| Dashboard branding | **behind** (still shows the LazyVim banner) | observed |
| Debugger / test panels | **behind or tied** (complaints now found, see notes.md section 9): nvim-dap-ui long-value and disassembly gaps, neotest output placement; Zed added a hover value tree in 2026-04 | GitHub issues cited in notes.md section 9 |

## Open gaps (not resolved)

- Reddit threads could not be read (browser safety block and 403), so r/neovim, r/rust and r/unixporn evidence is indirect. A person with a logged-in browser could read the three threads tagged `(i)` above.
- Debugger/test panel complaints were found on 2026-11-12 (GitHub issues, JetBrains and rust-lang forums) and are in notes.md section 9; still no side-by-side of the panels themselves.
- Zed's inline diagnostics settings were not found in the docs page fetched; only the 382-reaction request (Z1) is cited.
- Colour-blind support of Zed, Helix and RustRover themes was not checked beyond search results.
- Nothing here was implemented; the shortlist is a proposal.

## Implementation status (2026-11-12, branch `dev`)

Tests: `tests/ui-community_spec.lua`, 55 checks, grid assertions via `screenstring` / `nvim__inspect_cell` in headless Neovim at 60/80/120/200 columns, WCAG ratios computed in the spec itself. Captures: `docs/comparison/screenshots/ui/` (see its README for method and limits).

| # | Item | Status | Source count (this file) | Measured |
|---|---|---|---|---|
| 1 | Per-kind inlay hints | done: `:Hints`, statusline `hints TPL`, real rust-analyzer grid test | 4 (1 indirect) | types / params / lifetimes each removed alone on the grid |
| 2 | Cursor-line-first diagnostics | done: `:DiagnosticsView`, `vim.g.xynovim_diagnostics` | 5 | full text only on the cursor line; Info/Hint hidden elsewhere |
| 3 | Hint legibility | done | 4 (3 indirect) | 3.23:1 -> 6.07:1 (VS Code default 5.31:1 from its source, tokyonight 2.47:1 computed from its source) |
| 4 | Severity not by colour alone | done | 3 (1 indirect) | glyph `✗ ▲ ● ◆` (ASCII `x ! i ?`), four underline styles |
| 5 | Terminal check | done: `lua/xynovim/term.lua` | 4 | tmux / Ghostty / WezTerm / kitty cases in the spec |
| 6 | High contrast | done, widened round 2: every visible group >= 7:1, frames >= 4.5:1; plus `island-light` | 4 (1 indirect) | all ~1,000 groups checked in dark and light |
| 7 | Transparency / float regression | done round 2: real grid cells (editor see-through, floats, borders, titles, footers solid) | 4 (2 indirect) | one border, solid float on a transparent editor |
| 8 | Narrow statusline | done | 3 | file name whole at 60/80/120/200; `<main` stub gone |
| 9 | ASCII icons | done (dashboard, tabs, tree, statusline separators, signs, mini.icons); code lens "Debug" icon and a few plugin popups still use their own glyphs | 5 (2 indirect) | child Neovim with `XYNOVIM_ICONS=ascii` |
| 10 | Width-aware truncation | done | 3 | `…` inside the window at 4 widths |
| 11 | Debounce | done (120 ms in insert mode) | 2 | not timed |
| 12 | Dashboard header | done | 2 (1 indirect) | centred at 4 widths |
| 13 | Coloured rustc text | done round 2: `<leader>cD`, `:DiagnosticRendered` | 3 | spans + grid colours, all cells >= 4.5:1 |
| 14 | Error colour on names | done for the tree; the tab keeps bufferline's count (name not recolourable) | 2 | tree name cell colour on the grid; tab count >= 4.5:1 |
| 15 | Winbar | done, opt-in `:XynoWinbar` | 2 | row 1 on the grid, narrow window keeps the file name |
| 16 | End-of-line hints | **not built** (no clean Neovim way that does not shift text) | 3 | - |

Round 2 added a derived light variant (`island-light`) although no source asked for one; it is the user's request, not community demand. `unknown` that stayed unknown: how Helix, Zed and RustRover measure on hint contrast (only VS Code and tokyonight were derived from source).
