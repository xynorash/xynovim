# UI round 3 captures (2026-11-12): real Ghostty pixels

How: a private Ghostty 1.4.0 (`GDK_BACKEND=x11`, `--background-opacity=1 --minimum-contrast=1`, JetBrainsMono Nerd Font Mono) running `nvim` on a throw-away crate (the `tools/ui-capture/demo-main.rs` file plus a `src/macros.rs` with a `macro_rules!`, a second crate with failing tests for the results panel), real rust-analyzer and bacon-ls, plugin `dev` clones (`XYNOVIM_DEV_PLUGINS=~/projects/xyno-plugins`), workspace pre-trusted in a copy of a state directory. A Lua file is run in the live Neovim through `--listen` / `--remote-expr`, then the window is grabbed with ImageMagick `import -window <title>`. I looked at every picture before using it. The driver scripts were scratch files and are not in the repo.

**Column counts are approximate and differ per image.** The window is tiled by the compositor, and its width changed between runs (941 px, or 1896 px when no other window shared the screen); the font size was adjusted until `&columns` was near the target. The actual grid (columns x lines) is in the table. The target 200 could not be reached: the smallest readable font gave 210 to 234 columns, so those images are small.

| Files | What | Grid per target (columns x lines) |
|---|---|---|
| `dark-{80,120,200}.png` | Island Dark, Rust file, cursor on the error line 19 | 80: 78x39; 120: 117x60; 200: 234x113 |
| `light-{80,120,200}.png` | `:colorscheme island-light`, same moment | 80: 78x39; 120: 117x60; 200: 234x113 |
| `lighthigh-{80,120,200}.png` | `island-light` + `:IslandContrast high` | 80: 78x39; 120: 117x60; 200: 234x113 |
| `eol-{80,120,200}.png` | `:Hints eol` (dark) | 80: 78x39; 120: 117x60; 200: 210x51 |
| `eollight-{80,120,200}.png` | `:Hints eol` in island-light | 80: 78x18; 120: 118x28; 200: 210x51 |
| `sandbox-{80,120,200}.png` | `:XynoSandboxPolicy` (**[dev]**: absent with the pinned plugins) | 80: 78x39; 120: 117x60; 200: 234x113 |
| `history2-{80,120,200}.png` | `:LocalHistoryPanel` (**[dev]**) after three snapshots and one unsaved-to-history edit | 80: 78x39; 120: 117x60; 200: 234x113 |
| `macros6-{80,120,200}.png` | `:MacroSignature` inside `pair!(1, 2)` (`src/macros.rs`) | 80: 78x18; 120: 118x28; 200: 210x51 |
| `procmacro-{80,120,200}.png` | `:ProcMacroStatus` (after the wrap fix) | 80: 78x39; 120: 117x60; 200: 234x113 |
| `results-{80,120,200}.png` | test results panel fed by a real `cargo test` (2 pass, 2 fail) of a second crate | 80: 78x39; 120: 117x60; 200: 234x113 |

## Not captured, with the reason

- **Run-configuration picker (`:RustRun`)**: after three tries (the last waited for rust-analyzer to finish loading) no picker window appeared in the session; the cause was not found (a notify override of my own hid the plugin's message, so it may be a plugin message such as a failed `cargo metadata`). Nothing is shown rather than a wrong picture.
- **Diagnostic float (`<leader>cD`)**: opened and was gone again by the time of the grab in the scripted session (five tries); the spec asserts it on the grid. The only real picture is round 2's: `../ui2/rust-after-rendered-120.png`.
- Competitors: see `../competitors/README.md`.

## Things these pictures showed that were fixed

Popup words cut at the window edge (sandbox policy), proc-macro report and macro-signature popups cut at the edge by an absolute path, end-of-line hints missing while rust-analyzer loads and three noisy lifetime entries (all described in `../../ui-assessment.md`). Not fixed: the local-history panel opens a tab named `[No Name]`; the dashboard cut at 119x29 (round 2).

Ghostty window sizes of the neighbouring rows of the table came from different sessions on the same machine: do not compare pixel positions between rows.
