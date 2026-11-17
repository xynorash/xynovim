# Debugger and test UX: research, what changed, evidence

2026-11-12, branch `dev`, not pushed. Rows 2, 3 and 16 of [gaps-and-plan.md](gaps-and-plan.md). Labels: **[m]** measured on this machine in this pass, **[pc]** published claim, not reproduced. RustRover was not installed or run (licence); Zed and VS Code were not installed (nothing downloaded or run). Where a statement about them is a published claim it says so; where it is my inference it says so.

## What people complain about and praise (sources, all read 2026-11-12)

| Source | Finding |
| --- | --- |
| [nexte.st, RustRover integration](https://nexte.st/docs/integrations/rustrover/) [pc] | RustRover 2026.1+ can run tests with nextest; "Currently, RustRover does not support debugging tests with the nextest environment configured." The page says nothing about doctests, output or profiles. |
| [Zed debugger docs](https://zed.dev/docs/debugger) [pc] | Breakpoints with log message, condition and hit count; exception breakpoints (types depend on the adapter); inline values; Rust has a built-in adapter and debug tasks can be generated from tests. The page does not describe a variables panel, hover values or a call stack, so those are not compared here. |
| [CodeLLDB manual](https://github.com/vadimcn/codelldb/blob/master/MANUAL.md) [pc] | `sourceLanguages: ["rust"]` makes CodeLLDB "locate and load LLDB data formatters provided by the Rust toolchain" (so VS Code and Zed with CodeLLDB get the same stock summaries as xynovim did before this pass: `size=3`); hit conditions are `<`, `<=`, `=`, `>=`, `>`, `%` plus a number; logpoint messages take `{expr}`. |
| [rustc-dev-guide, LLDB visualizers](https://rustc-dev-guide.rust-lang.org/debuginfo/lldb-visualizers.html) and [lldb_lookup.py upstream](https://rust.googlesource.com/rust/+/refs/heads/main/src/etc/lldb_lookup.py) [pc] | The stock providers register summaries by regex on the type name; Vec / HashMap / Rc / RefCell summaries stop at `size=N` / `strong=, weak=` / `borrow=`. |
| [Helix wiki, debugger configurations](https://github.com/helix-editor/helix/wiki/Debugger-Configurations) [pc] | Strings showing as memory addresses until the formatters are loaded by hand. |
| [Rust users forum, "Debugger variables panel is very slow"](https://users.rust-lang.org/t/debugger-variables-panel-is-very-slow/141001) [pc] | A VS Code + CodeLLDB report: the variables panel took half a minute to update on one crate and CodeLLDB used 99 % of a core. Not reproduced; xynovim computes its previews with caps (8 items, 100 characters) for that reason. |
| Earlier rows of [notes.md](notes.md) section 9 | nvim-dap-ui #377, #286, #309; CodeLLDB #827, #1166 (formatters silently missing); neotest #123, #319, #441, #230. |

Searches that found nothing usable: user complaints about RustRover's assert_eq output (none found), Zed variables-panel complaints for 2026 (none found). Reddit is unreachable from here.

## Debugger

All "real" rows ran against a real codelldb (Mason, `codelldb` in `~/.local/share/nvim/mason`) through nvim-dap, headless, in `tests/debug-values_spec.lua` (21 checks, 11 s) on `tests/fixtures/debug-values`.

| Area | Before | Now | Proof |
| --- | --- | --- | --- |
| Rust value rendering | `Vec` -> `size=3`, `HashMap` -> `size=1`, `Rc` -> `strong=2, weak=0`, `RefCell` -> `borrow=0`, slice `size=2` (captured raw, [m]) | `size=3 [1, 2, 3]`, `size=1 {"a": 1}`, `strong=2, weak=0 "rc"`, `strong=1, weak=0 size=2 [1, 2]` (Arc<Vec>), `borrow=0 5`, `size=2 [2, 3]`; String, `&str`, `Option`, `Result`, enums were already readable (`"hello"`, `Some(5)`, `Err("bad")`, `Rect{w:2, h:3}`). Done as lldb summaries (`scripts/lldb/xyno_rust_preview.py`, own category `XynoRust`, enabled after codelldb loads rust's) so every surface gets them: variables pane, watch, REPL, hover, inline text. Falls back to the stock summary on any error. | real session, 15 values asserted, plus [dbg-stopped.png](screenshots/debug-test/dbg-stopped.png) |
| Type names | `alloc::vec::Vec<int, alloc::alloc::Global>` | `Vec<int>`; `vim.g.xynovim_dap_full_types = true` keeps the adapter's | real session |
| Variables / watch / hover | long values cut by the pane; no tree on hover | `<leader>dv` (and `K` while stopped, LSP hover otherwise): float with the type, the whole value (600-character String arrives whole, wrapped; string escapes undone), children two levels deep, `[raw]` dropped | real session + [dbg-float-map.png](screenshots/debug-test/dbg-float-map.png), [dbg-float-long.png](screenshots/debug-test/dbg-float-long.png) |
| Inline virtual text | whole value, a 600-character String filled the line | `= value`, one line, cut at 60 characters, containers show their preview | real session, extmarks read back; visible in dbg-stopped.png |
| Formatter health | silently raw (CodeLLDB #1166) | one WARN when codelldb did not report "Loading Rust formatters" on the first stop; `:checkhealth xynovim` section "debugger value rendering" | unit (fake session) + real session (flag set); health spec |
| Breakpoints | `<leader>dB` condition, `<leader>db` | + `<leader>dL` logpoint, `<leader>dH` hit count, `<leader>dX` exception breakpoints (the pick list is what the adapter advertises), `<leader>dQ` list to quickfix | real session: condition `i == 3` stops at i=3, hit count `3` stops at i=2, logpoint prints `loop i=0..4` and never stops; the key functions were called directly (key presses not driven) |
| Exception breakpoints incl. panics | `breakpoint set -n rust_panic` in initCommands | unchanged, plus the menu. **codelldb advertises exactly one filter, `rust_panic`** [m]; no `cpp_throw` / `cpp_catch` in this version. | real session |
| Stepping | LazyVim keys | unchanged | step over and step out asserted; step into not tested |
| Call stack | all frames incl. `lang_start`, `catch_unwind`, `FnOnce::call_once` | runtime frames marked `subtle`: nvim-dap-ui's stacks element hides those (its `t` shows them again), `dap.up/down` still walk all | real session (frames and hints), screenshot (stack shows `work`, `main`) |
| Async / tokio | nothing | closures and async frames named `<closure>`, `<async fn>`, `<async block>`; one notice per session when stopped in async code saying what the frames mean | unit test on synthetic frames **only**: no tokio program was debugged. A DAP adapter cannot list tasks; tokio-console does. |
| Debugging tests | `<leader>td` (LazyVim) | `<leader>td` through neotest's `dap` strategy: stops at the breakpoint inside the test with its locals, same formatters / previews in the launch | real: neotest + rustaceanvim + codelldb, stops in `add` with `a=2`, `b=3` |

### Against the baseline (honest status)

- **Default CodeLLDB rendering (VS Code, and Zed if it uses the stock summaries, which is my inference from the manual)**: xynovim is ahead on container contents (`size=3 [1, 2, 3]` against `size=3`), measured on the same binary.
- **RustRover**: not measured. Its debugger is not available here and I found no source that says how it prints a `HashMap`; no claim either way.
- **Zed hover tree**: xynovim has an equivalent float (type, value, children); Zed's UI was not seen. Row 2 of gaps-and-plan named PR 53198 as the comparison; I did not open it again.
- **Popular Neovim configs**: nvim-dap-ui defaults show the same stock summaries; LazyVim, AstroNvim and NvChad were not re-run this pass.

Not done: disassembly view (nvim-dap-ui #309, upstream has none); other tasks / threads view for async; step into asserted; `K` pressed through a real key (the map and the function are tested separately).

## Tests

Real runs: `tests/test-ui-neotest_spec.lua` (neotest + rustaceanvim + `cargo test`, then `cargo test --doc`), 4 checks on `tests/fixtures/failing-tests` (3 failing unit tests, 1 failing doc-test); `tests/test-ui_spec.lua`, 22 checks on real captured `cargo test` output (`tests/fixtures/test-output/`).

| Area | Now | Proof |
| --- | --- | --- |
| Output panel, persistent, bottom | `lua/plugins/neotest.lua`: neotest's output panel `botright split | resize 14`, summary `botright vsplit | vertical resize 48`, no float per run, no Trouble quickfix popup (LazyVim opens one on failure) | opts asserted in `dap-neotest-coverage_spec.lua` |
| Results panel `<leader>tp`, opens by itself on a failure | header (failed / passed / skipped, time, wall time, nextest profile, coverage), failure list with `file:line` and the first message, then one **fold per test** with its output (failed open, passed closed; `za`, `zM`, `zR`), `<CR>` jumps to the test, `o` opens the raw log, `q` closes | real run; [test-panel.png](screenshots/debug-test/test-panel.png) |
| assert_eq! / assert_ne! diff | left and right broken into one token per line and diffed (`-   3` / `+   4` for `[1, 2, 3]` vs `[1, 2, 4]`), strings show both lines with the differing word highlighted | parser spec (vec, string, nested struct, ne) and the real run |
| Rerun failed | `<leader>tf` / `r` in the panel reruns the failed test ids one by one and merges the results into the same panel | real run: 3 failed + 1 passed stays 3 + 1 |
| Watch mode | neotest's `<leader>tw` (unchanged); auto-save already re-emits `BufWritePost` for it | not re-tested in this pass |
| Doc-tests | `<leader>tE` runs `cargo test --doc --workspace` (with the `:RustContext` flags) into the same panel, location taken from the `(line N)` in the name; `<leader>tD` keeps the terminal run | real run; [test-doctests.png](screenshots/debug-test/test-doctests.png) |
| Coverage gutter and summary | gutter as before; `<leader>tc` now notifies the total and the three least covered files and puts the total in the panel header; `<leader>tG` summary as before | real `<leader>tc` (cargo-llvm-cov) in the Ghostty session: "coverage 90.0% of 20 lines", [coverage.png](screenshots/debug-test/coverage.png); lcov parsing on a real report |
| nextest profiles | `<leader>tP` lists the profiles of `.config/nextest.toml` and sets `NEXTEST_PROFILE` ([documented](https://nexte.st/docs/configuration/env-vars/)); the panel shows the profile | profile listing and parsing tested; **nextest was not run: `cargo-nextest` is not installed here**. The nextest parser is tested on a sample I wrote from memory of nextest's output format, not on a real run, so it may not match every nextest version. |
| Timing | wall time per run; per-test time from nextest status lines (`PASS [ 0.004s ]`); libtest prints no per-test time on stable, so none is shown for `cargo test` | parser spec; no live nextest |
| What neotest's adapter captures | `--nocapture` output with OSC / CR / ANSI and no per-test sections: the parser strips terminal sequences, attributes `thread 'x' panicked` blocks to the test, tolerates "test x ... " split by another thread's print | parser spec on the real capture (`neotest-nocapture.txt`) |

### Against the baseline

- **RustRover**: it has a test tool window with a tree and per-test output (not re-viewed this pass); the nexte.st page [pc] states it cannot debug tests with the nextest environment set. xynovim debugs a test through the same `cargo test` runner (verified) and has no statement either way for nextest: debugging with `NEXTEST` set was **not verified** (no nextest here). Not claimed.
- **VS Code / Zed**: not run. Zed generates debug tasks from tests [pc]; xynovim's debug-a-test works (verified).
- **Neovim configs**: neotest's own summary and output panel are what they ship; the additions here are not in LazyVim's test extra.

Not done: per-test timing for plain `cargo test`; test output of a *passing* test (cargo captures it unless `--nocapture`, which the adapter does pass, but prints from parallel tests interleave and cannot be attributed); live nextest; watch mode retest; a flaky first neotest run (discovery of the file's tests can take longer than a run started right after rust-analyzer attaches finds: the spec waits for "RA ready" and retries).

## Screenshots

Real pixels: Ghostty 1.4.0 as an X11 window (`GDK_BACKEND=x11`, fullscreen 1920x1080, JetBrainsMono Nerd Font 13) with this checkout as the config (`XDG_CONFIG_HOME` symlink, state and cache in a scratch dir), driven with `nvim --listen` and `--remote-expr`, captured with ImageMagick `import -window`. The crates are copies of `tests/fixtures/debug-values` and `failing-tests`. Not pixel-compared with any other tool.
