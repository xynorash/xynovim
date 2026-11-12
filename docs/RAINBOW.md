# Rainbow brackets

Brackets coloured by nesting depth, the way the JetBrains plugin
[Rainbow Brackets](https://github.com/izhangzhihao/intellij-rainbow-brackets) does it in RustRover, built natively on
Neovim's tree-sitter trees. It is this config's own code (`lua/config/rainbow*.lua`, no plugin installed: the supply-chain
policy of this repo keeps new dependencies out, and [rainbow-delimiters.nvim](https://gitlab.com/HiPhish/rainbow-delimiters.nvim),
the usual choice, has no scope highlighting, no unmatched-bracket marking and no contrast guarantee). It is on by default;
nothing is coloured in a buffer without tree-sitter highlighting.

Excluded on purpose (you asked for it): the plugin's **rainbow indent guides** ("colored indent space"). The indent guides
are untouched.

## How a bracket is found

The same rule as the plugin's PSI walk, on a tree-sitter tree: a *pair* is a node whose direct children contain an open
bracket token and its matching close token (so `Foo(a)` in a pattern, `pub(crate)`, `#[attr]`, `a[i]`, `{ ... }` and
`<T>` all count, wherever the tokens sit among the children). The **level** of a bracket is the number of enclosing pairs;
the colour is `level mod colours`. Brackets in strings, comments, char literals and lifetimes are not tokens of a pair, so
nothing inside them is touched. `<` is a bracket only inside a generics node of the grammar (`type_arguments`,
`type_parameters`, turbofish `::<>`, `for<'a>`), never as the comparison operator; the plugin's `isValidBracket` does the
same by asking for the partner token among the siblings. Format-string braces (`"{x}"`) are string text, as in the plugin.

Rust specifics, each checked on the real grid (`tests/rainbow_spec.lua`):

| Rust construct | Coloured? | Plugin / others |
| --- | --- | --- |
| `()` `[]` `{}` | yes | plugin: yes |
| generics `Vec<Vec<u8>>`, turbofish `::<T>`, `for<'a>` | yes (angle) | plugin: via the Rust brace matcher; rainbow-delimiters, Zed: yes |
| closure pipes `\|a, b\|` | yes (`pipe`), a binary `a \| b` is not | plugin: no; rainbow-delimiters, Zed: yes |
| macro invocation / `macro_rules!` bodies | yes (token trees) | plugin: where the Rust PSI exposes them |
| `#[attr]`, `#![attr]`, `pub(crate)` | yes | plugin: via PSI |
| a SQL / JSON / regex string injected into a macro | SQL, JSON: yes (own tree; the macro's level is the base); regex, Lua patterns, markdown prose, comments: no (text, not code) | - |
| comparison `<` `>`, `->`, `=>`, lifetimes `'a`, `"("`, `'('`, `// (` | no | same |

## Options

`vim.g.xynovim_rainbow = { ... }`, a table, set before startup (or `:XynoRainbow reload` after). Every key is validated: a
wrong type, an out-of-range number or an unknown key is ignored (the default stays), named in one warning and in
`:checkhealth xynovim`. `vim.g.xynovim_rainbow = false` turns the feature off. Options saved with `:XynoRainbow save` sit
below `vim.g`.

| Option | Default | Meaning | JetBrains setting |
| --- | --- | --- | --- |
| `enabled` | `true` | master switch | Enable rainbow brackets |
| `round` `square` `curly` `angle` | `true` | the four kinds | Enable rainbow round / square / squiggly / angle brackets |
| `pipe` | `true` | Rust closure pipes | (none) |
| `mismatch` | `true` | mark unmatched brackets (red, bold, curl) | (none: the plugin leaves them to the IDE) |
| `colors` | `6` | colours in the cycle, 1..16 (colour-blind palette: 8) | Number of colors |
| `cycle_all_types` | `true` | one level counter for all kinds; `false`: each kind counts its own nesting | Cycle count on all bracket types |
| `skip_first_level` | `false` | leave level 0 uncoloured | Do not rainbowify brackets of the first level |
| `palette` | `"auto"` | `auto` (island, or colour-blind while `:ColorblindDiagnostics` is on), `island`, `colorblind`, `custom` | Color scheme page |
| `custom` | `{}` | `{ "#rrggbb", ... }` or `{ all = {...}, round = {...}, square = {...}, curly = {...}, angle = {...}, pipe = {...} }` | Color #1..#N, per-kind colour keys |
| `min_contrast` | `"auto"` | `auto` = 3:1 (7:1 with `vim.g.xynovim_contrast = "high"`), or a number 1..21; colours are lifted (OKLab lightness, hue kept) against the editor and the caret-row background | (none) |
| `generator.enabled` | `false` | generate the colours | Use color generator |
| `generator.hue` | `"any"` | `any red orange yellow green blue purple pink monochrome` or `#rrggbb` (its hue) | hue |
| `generator.luminosity` | `"bright"` | `bright light dark` | luminosity |
| `priority` | `130` | extmark priority (tree-sitter 100, LSP semantic tokens 125) | (none) |
| `max_lines` | `0` | `0` = no limit, `N` = files with more lines get no colours | Do NOT rainbowify files with more than N lines (default 1000 there) |
| `large` | `"on"` | `"on"`: also in large-file tier 1 (only visible lines are processed); `"off"` | (none) |
| `disable` | `{}` | filetypes, tree-sitter languages or file extensions (`"md"`, `".toml"`, `"lua"`); also applies to injected trees | Do NOT rainbowify these languages |
| `variables.enabled` | `false` | rainbow variables: locals coloured by name | Rainbow variables |
| `variables.colors` | `10` | 2..16 | (premium: generator for variables) |
| `scope.alpha` | `0.2` | scope tint: the rainbow colour mixed this much into the editor background | the plugin's alpha 0.2 |
| `scope.restrain_strength` | `0.65` | how far outside text is dimmed towards the background (never below `min_contrast`) | restrain highlighting effect |
| `scope.restrain_keep_colors` | `false` | keep the tree-sitter hue of the dimmed text | Keep original colours when restrained |
| `scope.any_key` | `false` | `false`: ESC clears the scope highlight; `true`: any key | Press any key to remove the highlighting effect |
| `scope.mouse` | `true` | `<C-RightMouse>` highlights, `<A-RightMouse>` restrains | the two mouse actions |
| `scope.box` | `"inverse"` | how the two scope brackets are drawn: `inverse`, `underline`, `none` | BOXED effect |
| `scope.suppress_debug` | `false` | no scope highlight while nvim-dap has a session | Suppress scope highlighting while debugging |
| `scope.suppress_diff` | `false` | none in diff windows | Suppress scope highlighting when diffing |

## Commands and keys

`:XynoRainbow {sub}` (tab-completes everything, `:XynoRainbow status` shows the state):

| Subcommand | What |
| --- | --- |
| `on` `off` `toggle` | the master switch |
| `buffer [on\|off\|toggle]` | this buffer only (`vim.b.xynovim_rainbow = false`) |
| `round` `square` `curly` (`squiggly`) `angle` `pipe` `mismatch` `first-level` `cycle-all` `generator` `variables` `any-key` `keep-colors` `suppress-debug` `suppress-diff` `mouse` `[on\|off\|toggle]` | one switch each |
| `palette [island\|colorblind\|generated\|custom\|auto\|next]` (`cycle`) | pick a palette; `next` / `cycle` walks island, colour-blind, generated |
| `colors [N\|show\|freeze\|save]` | the number of colours; `show` prints them in their colours; `freeze` turns the generated colours into `palette = custom`; `save` writes them to `stdpath("state")/xynovim/rainbow-colors.json` |
| `hue NAME` `luminosity NAME` | generator options |
| `scope` `restrain` `clear` | at the cursor (the mouse does the same under the pointer) |
| `set OPTION VALUE` | any option by its dotted path, validated (`set scope.alpha 0.35`, `set disable md toml`) |
| `save` `forget` `reload` | write the options that differ from the defaults to `stdpath("state")/xynovim-rainbow.json`, delete it, re-read everything |
| `health` | `:checkhealth xynovim` |

Keys: `<leader>uk` toggle, `<leader>uj` highlight the scope at the cursor, `<leader>uJ` restrain outside it. ESC clears.
Mouse: `Ctrl+right-click` / `Alt+right-click`, like the plugin's `Ctrl` / `Alt` + `Button3`.

## Colours

Defaults are tuned for Island Dark and Island Light (`lua/config/rainbow_palette.lua`): the scheme's gold, orchid, blue,
orange, green and cyan first, then four more hues. Every colour that reaches the screen is lifted until it has the minimum
contrast (3:1 for glyphs, 7:1 in the high-contrast variant) against both the editor background and the caret-row
background, so a bracket stays legible on the cursor line. The test (`tests/rainbow_spec.lua`) measures it on the grid, in
both variants and at 60 / 120 / 200 columns.

The colour-blind palette starts from the Okabe-Ito hues and was improved by a hill-climbing search (not committed; its
result is the list in `rainbow_palette.lua`, and the spec re-measures it) that moved lightness, chroma and hue (up to 14
degrees) to maximise the smallest distance between any two colours, as seen with normal vision and under simulated
protanopia, deuteranopia and tritanopia (Machado et al. 2009, severity 1), with every colour at least 3:1 on the editor
and the caret row. Smallest OKLab distance x 100 over all pairs and the four vision types: dark 7.2, light 5.1. The stock
Okabe-Ito set lifted to the same contrast scores 5.9 (dark) and 1.0 (light). The spec asserts these floors and that the
palette beats the stock set.

## Scope highlighting

`Ctrl+right-click` (or `<leader>uj`, `:XynoRainbow scope`) marks the innermost bracket pair around the pointer / cursor:
its text range is tinted with the pair's own rainbow colour mixed `scope.alpha` (0.2) into the editor background and its
two brackets are drawn inverted. `Alt+right-click` (`<leader>uJ`, `:XynoRainbow restrain`) dims everything outside the
pair instead. ESC (or any key, `scope.any_key`) clears it.

**Differences from the plugin, stated:**

- The plugin draws a *boxed* effect, a rectangle outline. A terminal grid cannot, so the two brackets are drawn inverted
  (or underlined, `scope.box`).
- "Keep original colours while restrained" re-colours each syntax capture with its dimmed colour for the rows around
  the window (300 each way); LSP semantic-token colours are not read.
- The plugin's premium "restrain foreground / background effect colour" has no option here (`restrain_strength` only).
- "Respects the debugger Execution Point colour" is not implemented: the scope colours are drawn under the line highlight
  of nvim-dap; `suppress_debug` switches the highlight off while a session is running.

## Rainbow variables

`variables.enabled = true` (or `:XynoRainbow variables on`) colours every local variable and parameter by a hash of its
name, using the tree-sitter `locals` query: the declaration and each use of `total` match, `total` and `count` differ;
fields, functions, types and anything not a local of an enclosing scope keep their colour. Like IntelliJ's semantic
highlighting it colours by name inside the function, so shadowing is not told apart; two names can collide on one colour.
Off by default.

## Performance

Only the visible lines are processed: a decoration provider emits ephemeral extmarks per redraw; the per-tree memo is
keyed on the tree object and `changedtick`. The provider never parses (nvim 0.12's highlighter parses asynchronously;
a synchronous `parse()` from the provider forced a 900 ms reparse after an unbalanced `{` in a 38 000-line file, found
with the latency probe and removed). While the highlighter is parsing, the edited old tree is used and nothing is cached.

Measured with `scripts/bench/rainbow.sh` ([results below](#measured)).

### Measured

2026-11-12, this machine (Ryzen 7 5800X, Neovim 0.12.6), **under load**: other jobs were running (load average 5-6 of 16
threads), so absolute numbers are inflated and noisy; on and off ran interleaved so a load change hits both columns.

**Redraw latency** (`scripts/bench/rainbow.sh --rounds 5`: headless, full config, `redraw!` after each step, ms; each cell
is the median of the five rounds' medians; brackets off = `enabled = false`, the same code path without the provider's
work):

| | off | on | on minus off |
| --- | --- | --- | --- |
| 1 888-line file: jump (cold window) | 4.5 | 7.0 | +2.4 |
| 1 888-line file: scroll 3 lines | 2.8 | 4.1 | +1.3 |
| 1 888-line file: type one character | 2.6 | 4.4 | +1.8 |
| 37 648-line file (large-file tier 1): jump | 2.3 | 4.6 | +2.3 |
| 37 648-line file: scroll 3 lines | 2.2 | 3.3 | +1.1 |
| 37 648-line file: type one character | 1.8 | 3.5 | +1.7 |

The 95th percentile of typing was 13.8 ms off and 24.9 ms on in the small file and 9.5 / 20.7 ms in the large one: an
edit that is slower than the median costs about 10 ms more with the brackets on. Before the fix described above, typing
`{` into the large file took 909 ms (median) in this probe.

**Startup** (`scripts/bench/bench.sh --only startup -n 10`, five interleaved pairs of the config before this work against
the config with it, real TUI in a tmux pty; medians, ms): no file, VeryLazy fired 51.2 -> 50.2, ready 82.6 -> 81.0; with a
`.rs` file, UIEnter 224.2 -> 224.8, ready 360.2 -> 357.3. The paired differences range from -26 to +35 ms because of the
load, so **no change is measurable at this noise level**; the in-process cost of loading the module and running its
`setup()` at VeryLazy was 0.9 to 2.6 ms in five runs (`require("lazy").load` of the virtual spec, no file open), which is
the number to compare with the 3 ms budget. The first draw of a Rust buffer also compiles the bracket query once (a
few milliseconds, inside the first redraw, after the first screen).

## Not implemented, and why

| Plugin feature | Status |
| --- | --- |
| rainbow indent guides | excluded by you |
| Python / Ruby keywords, C/C++ `#if` macros, Kotlin function-literal arrows and labels, HTML / XML / JSX / YAML tags | **not implemented.** None of these exists in Rust; the grammars for Kotlin, Ruby and C++ are not installed here, so they could not be tested. Nothing in Neovim prevents them (a rule table on top of the same pair engine would do it). |
| per-colour-scheme XML file (`rainbow_brackets.xml`) | replaced by `vim.g.xynovim_rainbow` and `:XynoRainbow save` |
| premium "show and save generated colors" window | `:XynoRainbow colors show|save|freeze` |
| "Respects the debugger Execution Point colour" | not implemented (see above) |

## Compared with the others

| | brackets by depth | scope highlight | unmatched marking | contrast guarantee | per-kind switches | colour-blind palette |
| --- | --- | --- | --- | --- | --- | --- |
| this config | yes | yes (mouse, keys, commands) | yes | 3:1 / 7:1 enforced | yes | yes, measured |
| JetBrains Rainbow Brackets | yes | yes (mouse only) | no | no | yes | no |
| rainbow-delimiters.nvim | yes (per-language queries) | no | no | no | per query | no |
| VS Code | yes | bracket pair guides (not built here: indent-guide family) | yes (`unexpectedBracket`) | no | `independentColorPoolPerBracketType` | no |
| Zed | yes (`colorize_brackets`, off by default) | no | no | min contrast against the background | no | no |
| Helix | yes (`rainbow-brackets`, off by default) | no | no | no | no | no |

Sources, read 2026-11-12: the plugin's README, `CHANGELOG.md` and Lite source (github.com/izhangzhihao/intellij-rainbow-brackets,
branch 2022.3), intellij-rust `RsBraceMatcher.kt`, the rainbow-delimiters Rust query and `doc/rainbow-delimiters.txt`, VS Code
`editorOptions.ts` and the bracket-pair-colorization blog post, Zed's `rainbow-brackets` blog post and `brackets.scm`, Helix
`editor.md` / `rainbows.scm`.

## Files

`lua/config/rainbow.lua` (options, engine, provider), `rainbow_palette.lua` (palettes, generator, contrast, groups),
`rainbow_scope.lua`, `rainbow_vars.lua`, `rainbow_cmd.lua` (`:XynoRainbow`, health), `lua/plugins/rainbow.lua` (a virtual
lazy spec: loads at VeryLazy), `tests/rainbow_spec.lua`, `scripts/bench/rainbow.{sh,lua}`.
