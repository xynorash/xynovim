# Benchmark: nvim

Measured 2026-11-12T03:10:24Z with `scripts/bench/bench.sh` (see `scripts/bench/README.md`). Raw data: `perf-2026-11-after.json`.

## Machine and tools

- CPU: AMD Ryzen 7 5800X 8-Core Processor, 16 logical CPUs, 15903 MB RAM, governor `powersave`, load average at start `2.39 3.03 3.32 2/942 2645217`
- Kernel: Linux 7.3.3-1-cachyos-bore
- NVIM v0.12.6
- rust-analyzer 1.99.1 (58cf8f9 2026-10-13)
- cargo 1.99.1 (5f94df478 2026-08-27)
- clippy 0.1.99 (58cf8f9c35 2026-10-13)
- bacon-ls 0.31.0
- Config: `/home/xynorash/projects/xynovim` at git 006ad10 (dirty), NVIM_APPNAME `nvim`
- Project: `/home/xynorash/projects/xynovim/demo/netwatch`
- Isolation: config symlink /home/xynorash/projects/xynovim -> temp XDG_CONFIG_HOME/nvim; state temp (fresh per run); cache temp (fresh per run); data real /home/xynorash/.local/share (plugins are not reinstalled)

## Results

```
Benchmark: nvim   config=nvim (006ad10 (dirty))   2026-11-12T03:10:24Z
AMD Ryzen 7 5800X 8-Core Processor | 16 CPUs | 15903 MB | NVIM v0.12.6
rust-analyzer: rust-analyzer 1.99.1 (58cf8f9 2026-10-13) | bacon-ls: 0.31.0

== Startup (ms, real TUI in a tmux pty) ==
  first run, cold cache: NVIM STARTED 57.5, ready 102.8
  no file      NVIM STARTED  36.8 (min 35.1, max 38.7, n=10)
  no file      UIEnter       35.9 (min 34.4, max 37.0, n=10)
  no file      VeryLazy fired  41.4 (min 39.6, max 43.3, n=10)
  no file      ready (VeryLazy plugins loaded) 64.7 (min 62.3, max 69.9, n=10)
  with .rs file NVIM STARTED  185.1 (min 180.4, max 198.8, n=10)
  with .rs file UIEnter       184.5 (min 179.9, max 198.5, n=10)
  with .rs file VeryLazy fired  237.4 (min 230.1, max 249.4, n=10)
  with .rs file ready (VeryLazy plugins loaded) 291.2 (min 277.7, max 306.3, n=10)

== Plugins (lazy.nvim) ==
  plugins 70.0, loaded once the config is up (after VeryLazy) 26.0; after opening a .rs file: 43.0; sum of load times 50.5 ms
  slowest to load (ms, all phases):
    lazy.nvim                             16.1  (init.lua)
    lualine.nvim                           4.7  (lazy)
    bufferline.nvim                        4.0  (lazy)
    snacks.nvim                            3.1  (start)
    LazyVim                                2.8  (start)
    xyno-crates.nvim                       2.1  (lazy)
    xyno-new.nvim                          1.8  (lazy:snacks.nvim)
    nvim-treesitter                        1.7  (lazy)
    mini.pairs                             1.6  (lazy)
    satellite.nvim                         1.4  (lazy)
    flash.nvim                             1.4  (lazy)
    xyno-rust.nvim                         1.3  (lazy:xyno-new.nvim)
  loaded by opening a .rs file (top):
    nvim-lspconfig                        29.6
    mason.nvim                            15.2
    nvim-dap                               5.6
    gitsigns.nvim                          3.3
    nvim-dap-ui                            2.6
    rustaceanvim                           2.3
    nvim-treesitter-context                1.3
    nvim-ts-autotag                        1.2
  clipboard: provider=XynoClipboard, vim.o.clipboard="unnamedplus"

== LSP on netwatch ==
  clients attached (ms after :edit): { bacon_ls = 225.5, ["rust-analyzer"] = 234.7, ["xyno-crates"] = 225.2, ["xyno-features"] = 88.4 }
  server binaries: { bacon_ls = "/home/xynorash/.local/share/nvim/mason/bin/bacon-ls", ["rust-analyzer"] = "/usr/lib/rustup/bin/rust-analyzer" } | rust-analyzer version run: rust-analyzer 1.99.1 (58cf8f9 2026-10-13)
  settled after (ms, quiet 3 s)    : 2961.7
  idle RSS MB: total 809.7, nvim 52.1; by process: { ["bacon-ls"] = 7.3, nvim = 52.1, ["rust-analyzer"] = 688, ["rust-analyzer-p"] = 62.3 }
  idle CPU (% of 1 core, 10.0s window): total 0.4; nvim 0.4; { ["bacon-ls"] = 0, nvim = 0.4, ["rust-analyzer"] = 0, ["rust-analyzer-p"] = 0 }
  RSS MB after the trials: total 822.7
  edit -> first matching diagnostic (ms; per cell: fastest source overall / per client):
    ra      type   first=31.0      bacon_ls 570.3 [5/5]; rust-analyzer 31.0 [5/5]
    ra      save   first=32.0      bacon_ls 570.9 [5/5]; rust-analyzer 32.0 [5/5]
    clippy  type   first=568.3     bacon_ls 568.3 [5/5]
    clippy  save   first=570.9     bacon_ls 570.9 [5/5]

== Typing burst (40.0 keys, gap ~80.0 ms): clippy runs 1.0 (0.0 started before the last key); last run ended 611.4 ms after the last key ==
== Typing burst (40.0 keys, gap ~150.0 ms): clippy runs 1.0 (0.0 started before the last key); last run ended 454.5 ms after the last key ==
== Typing burst (40.0 keys, gap ~300.0 ms): clippy runs 1.0 (0.0 started before the last key); last run ended 329.8 ms after the last key ==
== Large file (40013.0 lines, 0.9 MB, outside a crate) ==
  open: 129.6 ms | max main-loop stall while idle 5 s: 111.1 ms | clients: { "xyno-features", "rust-analyzer" } | treesitter hl: true | bigfile mode: false | filetype=rust
  ops (ms, each ends with :redraw to a tmux pty): goto_end 3.8 | goto_start 3.0 | jump_20000_lines 2.9 | search 4.8 | page_down_x200 310.2 | edit_middle 18.6 | write 5.1
  RSS MB: before open 26.1, after open 721.0, after ops 868.2

== Large file (100003.0 lines, 2.1 MB, outside a crate) ==
  open: 56.3 ms | max main-loop stall while idle 5 s: 26.0 ms | clients: {} | treesitter hl: false | bigfile mode: true | filetype=bigfile
  ops (ms, each ends with :redraw to a tmux pty): goto_end 6.3 | goto_start 2.2 | jump_20000_lines 7.8 | search 12.8 | page_down_x200 202.7 | edit_middle 18.4 | write 9.8
  RSS MB: before open 27.2, after open 98.1, after ops 117.9

```

## Limits (not measured, or only partly)

- Linux only (reads `/proc`); one machine, one run of this script; load average at start is above.
- Startup is measured in a tmux pty: it includes exec and the terminal protocol handshake of nvim, but not the terminal emulator's own time to first paint.
- The demo crate has two source files. Memory, indexing time and clippy time on a large workspace are not covered.
- A diagnostic cell reads `none` when no matching diagnostic arrived within 20 s; it does not say the config could not be set up to produce one.
- Large-file numbers are for a file outside a Cargo crate, generated by the harness.
