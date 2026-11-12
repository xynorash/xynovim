# Benchmark harness

Reproducible, headless-scriptable measurements of a Neovim configuration on a Rust project. It measures xynovim by default and any other config through `NVIM_APPNAME`, with the same code and the same project, so numbers are comparable. It only reports what it measured; a metric that could not be taken is `n/a` or listed under Notes.

```sh
scripts/bench/bench.sh --out docs/bench/baseline.json --md docs/bench/baseline.table.md
scripts/bench/bench.sh --only startup,plugins -n 10        # a subset
NVIM_APPNAME=lazyvim XDG_CONFIG_HOME=... scripts/bench/bench.sh --out lazyvim.json   # another config
```

Needs Linux (reads `/proc`), `nvim` 0.10+, `tmux`, `cargo`, `rust-analyzer`, and network access the first time (the demo crate's dependencies are compiled once as a pre-warm).

## What is measured

| Metric | How |
| --- | --- |
| Cold start | `nvim -n --startuptime F` in a private tmux pty (a real TUI, so `UIEnter` and lazy.nvim's `VeryLazy` fire, which a plain `--headless` start never does). Reports `NVIM STARTED`, `UIEnter`, and "ready" (all `VeryLazy` plugins loaded), median of N=10 (`-n`), with and without a `.rs` file argument. Run 1 has cold caches (fresh `XDG_CACHE_HOME`) and is reported separately. |
| Per-plugin load cost | lazy.nvim's own profile (`plugin._.loaded.time`) once the config is up, and again after opening a Rust file; top entries and the sum. Configs without lazy.nvim report "not measured". |
| Edit to first diagnostic | In a copy of `demo/netwatch`: append a function with a type error (rust-analyzer's own `E0308`) or a clippy lint (`clippy::len_zero`), and time until a diagnostic that matches arrives. Two edit modes: `type` (buffer change only, no save) and `save` (`:write` right after). Per client, so rust-analyzer's own tier and a clippy tier (bacon-ls, or rust-analyzer's flycheck) are separated. N=5 trials after a discarded warm-up; a cell with no diagnostic within 20 s is reported as none. |
| Idle memory and CPU | After the LSP clients settle (no progress for 3 s): RSS of nvim plus all its descendants (`/proc/PID/status` VmRSS, grouped by process name), then CPU ticks of the same tree over a 10 s idle window. |
| Large file | A generated Rust file (default 40 000 and 100 000 lines) outside any crate: open time, longest main-loop stall while idle, attached clients, treesitter and bigfile state, jump/search/scroll/edit/write timings (each ends with `:redraw` to the pty) and RSS. |

Opt-in metric: `--type-gaps 80,150,300` (with `--only typing`) types 40 keystrokes at those gaps (+-40 %) into a function body and reports how many clippy runs (bacon-ls progress `begin`) the burst started and when the last run ended relative to the last key. Experiment hooks, not part of published numbers: `BENCH_PRE=<lua file>` runs in the `large` probe just before the file is opened (switch one feature off), `BENCH_EARLY=<lua file>` runs from `hook.lua` before the user config (e.g. preset `vim.g.rustaceanvim` to measure one rust-analyzer setting); `BENCH_CONFIG=<dir>` measures a scratch copy of a config. The harness works on a temp copy of the demo crate, which xynovim's workspace trust gate would treat as untrusted (restricted rust-analyzer, no bacon-ls), so `hook.lua` switches the gate off (`vim.g.xynovim_workspace_trust = false`, the settings of a trusted workspace) unless `BENCH_TRUST=0`, which measures the restricted mode.

## Isolation

**Trap:** if `XDG_CONFIG_HOME` is set in your shell, the harness uses it as given and measures whatever is in `$XDG_CONFIG_HOME/$NVIM_APPNAME`, not this checkout. Run `env -u XDG_CONFIG_HOME scripts/bench/bench.sh ...` to measure the checkout (the header of the result says `config symlink ...` when it did).

Every measured nvim is a separate process with its own environment. By default the config under test is this checkout (or `BENCH_CONFIG`), symlinked as `$XDG_CONFIG_HOME/$NVIM_APPNAME` in a temp dir; `XDG_STATE_HOME` and `XDG_CACHE_HOME` are fresh temp dirs (no shada, swap, lsp.log or lua cache leaks in or out); `XDG_DATA_HOME` is the real one so installed plugins are used. If you set the `XDG_*` variables yourself, they are used as given (this is how the comparison configs get a fully private data dir). The Rust project is a private copy, so `target/` and bacon-ls's shadow never touch the repo.

Options and environment: `scripts/bench/bench.sh --help`.

## Comparing other configs

`NVIM_APPNAME` selects the config; set `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME` and `XDG_CACHE_HOME` to a private tree so the config's plugins, Mason packages and caches stay out of your real ones:

```sh
NVIM_APPNAME=lazyvim XDG_CONFIG_HOME=$D/lazyvim/config XDG_DATA_HOME=$D/lazyvim/data \
  XDG_STATE_HOME=$D/lazyvim/state XDG_CACHE_HOME=$D/lazyvim/cache \
  BENCH_CONFIG=$D/lazyvim/config/lazyvim scripts/bench/bench.sh --label lazyvim --out lazyvim.json
```

`compare.sh DIR` does this for the LazyVim starter, kickstart.nvim, the AstroNvim template and the NvChad starter: it clones each, adds Rust support the way that starter documents (LazyVim `lang.rust` extra, kickstart's `rust_analyzer` server entry, astrocommunity's `pack.rust`, NvChad's `servers` list plus the rust parser), installs plugins, and runs the harness. It executes third-party Lua, so read it and run it yourself. What a result means for configs that are not lazy.nvim based (kickstart uses `vim.pack`): per-plugin cost is "not measured" and "ready" is n/a, because there is no `VeryLazy` event; `UIEnter` and `NVIM STARTED` still apply. Which `rust-analyzer` binary each config ran (PATH or Mason's) is recorded in the result.

## Files

- `bench.sh` / `bench.lua` – orchestrator and report (JSON with sorted keys, plus a text table).
- `hook.lua` – loaded with `--cmd`: startup timestamps, and starts the probe after startup.
- `compare.sh` – clone, add Rust support and measure the public starter configs (see above).
- `probe.lua` – runs inside the measured nvim: `plugins`, `lsp` and `large` modes.

## Caveats

- Timings are wall clock on a shared desktop; the load average at start is in the JSON. Compare runs from the same machine state.
- The tmux pty is 200x50; the terminal emulator itself is not part of the numbers.
- Diagnostic latency includes the config's own debounce and auto-save behaviour on purpose: that is what a user waits for.
- Large-file results are for a file that is not in a Cargo crate; rust-analyzer's behaviour on a large file inside a crate is not covered.
- The demo crate is small (two files). Memory and index time grow with the project; these are not numbers for a big workspace.
