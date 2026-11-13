# Benchmark: xynovim

Measured 2026-11-11T23:22:38Z with `scripts/bench/bench.sh` (see `scripts/bench/README.md`). Raw data: `the .json next to this file`.

## Machine and tools

- CPU: AMD Ryzen 7 5800X 8-Core Processor, 16 logical CPUs, 15903 MB RAM, governor `powersave`, load average at start `0.18 0.34 0.27 2/831 101411`
- Kernel: Linux 7.3.3-1-cachyos-bore
- NVIM v0.12.6
- rust-analyzer 1.99.1 (58cf8f9 2026-10-13)
- cargo 1.99.1 (5f94df478 2026-08-27)
- clippy 0.1.99 (58cf8f9c35 2026-10-13)
- bacon-ls 0.31.0
- Config: `/home/xynorash/projects/xynovim` at git 84b0277, NVIM_APPNAME `nvim`
- Project: `/home/xynorash/projects/xynovim/demo/netwatch`
- Isolation: config symlink /home/xynorash/projects/xynovim -> temp XDG_CONFIG_HOME/nvim; state temp (fresh per run); cache temp (fresh per run); data real /home/xynorash/.local/share (plugins are not reinstalled)

## Results

```
Benchmark: xynovim   config=nvim (84b0277)   2026-11-11T23:22:38Z
AMD Ryzen 7 5800X 8-Core Processor | 16 CPUs | 15903 MB | NVIM v0.12.6
rust-analyzer: rust-analyzer 1.99.1 (58cf8f9 2026-10-13) | bacon-ls: 0.31.0

== Startup (ms, real TUI in a tmux pty) ==
  first run, cold cache: NVIM STARTED 52.5, ready 97.1
  no file      NVIM STARTED  33.2 (min 31.1, max 35.9, n=10)
  no file      UIEnter       33.2 (min 31.2, max 36.0, n=10)
  no file      VeryLazy fired  38.2 (min 36.0, max 41.0, n=10)
  no file      ready (VeryLazy plugins loaded) 59.3 (min 57.6, max 63.5, n=10)
  with .rs file NVIM STARTED  177.3 (min 169.1, max 197.4, n=10)
  with .rs file UIEnter       176.8 (min 168.5, max 196.9, n=10)
  with .rs file VeryLazy fired  224.5 (min 215.8, max 250.2, n=10)
  with .rs file ready (VeryLazy plugins loaded) 275.4 (min 267.1, max 309.4, n=10)

== Plugins (lazy.nvim) ==
  plugins 70.0, loaded once the config is up (after VeryLazy) 26.0; after opening a .rs file: 43.0; sum of load times 41.4 ms
  slowest to load (ms, all phases):
    lazy.nvim                             13.6  (init.lua)
    lualine.nvim                           3.9  (lazy)
    satellite.nvim                         2.8  (lazy)
    snacks.nvim                            2.4  (start)
    LazyVim                                2.4  (start)
    bufferline.nvim                        1.7  (lazy)
    xyno-macros.nvim                       1.7  (lazy)
    nvim-treesitter                        1.5  (lazy)
    xyno-new.nvim                          1.4  (lazy:snacks.nvim)
    flash.nvim                             1.0  (lazy)
    mini.pairs                             0.9  (lazy)
    xyno-imports.nvim                      0.9  (lazy:xyno-macros.nvim)
  loaded by opening a .rs file (top):
    rustaceanvim                          15.2
    nvim-dap                              13.5
    nvim-lspconfig                        12.5
    nvim-dap-ui                            4.0
    gitsigns.nvim                          3.6
    mason.nvim                             2.7
    nvim-ts-autotag                        1.4
    nvim-treesitter-context                1.1
  clipboard: provider=XynoClipboard, vim.o.clipboard="unnamedplus"

== LSP on netwatch ==
  clients attached (ms after :edit): { bacon_ls = 212.3, ["rust-analyzer"] = 219.6, ["xyno-crates"] = 212, ["xyno-features"] = 87.1 }
  settled after (ms, quiet 3 s)    : 2676.2
  idle RSS MB: total 1002.0, nvim 52.3; by process: { ["bacon-ls"] = 7.3, nvim = 52.3, ["rust-analyzer"] = 880.2, ["rust-analyzer-p"] = 62.3 }
  idle CPU (% of 1 core, 10.0s window): total 0.5; nvim 0.5; { ["bacon-ls"] = 0, nvim = 0.5, ["rust-analyzer"] = 0, ["rust-analyzer-p"] = 0 }
  RSS MB after the trials: total 1016.8
  edit -> first matching diagnostic (ms; per cell: fastest source overall / per client):
    ra      type   first=25.6      bacon_ls 562.8 [5/5]; rust-analyzer 25.6 [5/5]
    ra      save   first=32.3      bacon_ls 562.1 [5/5]; rust-analyzer 32.3 [5/5]
    clippy  type   first=562.0     bacon_ls 562.0 [5/5]
    clippy  save   first=562.4     bacon_ls 562.4 [5/5]

== Large file (40013.0 lines, 0.9 MB, outside a crate) ==
  open: 373.4 ms | max main-loop stall while idle 5 s: 527.4 ms | clients: { "xyno-features", "rust-analyzer" } | treesitter hl: true | bigfile mode: false | filetype=rust
  ops (ms, each ends with :redraw to a tmux pty): goto_end 4.5 | goto_start 2.6 | jump_20000_lines 3.7 | search 5.0 | page_down_x200 637.3 | edit_middle 243.0 | write 5.2
  RSS MB: before open 26.3, after open 887.6, after ops 1207.4

== Large file (100003.0 lines, 2.1 MB, outside a crate) ==
  open: 52.4 ms | max main-loop stall while idle 5 s: 20.4 ms | clients: none | treesitter hl: false | bigfile mode: true | filetype=bigfile
  ops (ms, each ends with :redraw to a tmux pty): goto_end 6.2 | goto_start 1.6 | jump_20000_lines 7.1 | search 12.6 | page_down_x200 201.9 | edit_middle 19.2 | write 9.6
  RSS MB: before open 26.9, after open 98.3, after ops 117.7

```

## Limits (not measured, or only partly)

- Linux only (reads `/proc`); one machine, one run of this script; load average at start is above.
- Startup is measured in a tmux pty: it includes exec and the terminal protocol handshake of nvim, but not the terminal emulator's own time to first paint.
- The demo crate has two source files. Memory, indexing time and clippy time on a large workspace are not covered.
- A diagnostic cell reads `none` when no matching diagnostic arrived within 20 s; it does not say the config could not be set up to produce one.
- Large-file numbers are for a file outside a Cargo crate, generated by the harness.
