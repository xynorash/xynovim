# Startup cost of the Rust IDE feature pass (2026-11-12)

`scripts/bench/bench.sh --only startup -n 10`, a real TUI in a tmux pty, `XYNOVIM_DEV_PLUGINS=~/projects/xyno-plugins` in every run, same machine (AMD Ryzen 7 5800X, nvim 0.12.6, rust-analyzer 1.99.1), other work was running on the machine at the same time. "before" is `git archive HEAD` of this repository, "after" is that plus the changed files of this pass (`lua/config/keymaps.lua`, `rust_assist.lua`, `problems.lua`, `lua/plugins/navigation.lua`, `editing-ui.lua`); the xyno-rust.nvim clone is the one on disk in all four runs, but `before1` was taken before `run_configs.lua` and `action_menu.lua` existed, so before1 -> after1 contains their `require` at `setup()`, while before2 -> after2 does not (the clone had them in both). Order: before1, after1, before2, after2 (median of 10 starts each, ms).

| metric | before1 | after1 | before2 | after2 |
| --- | --- | --- | --- | --- |
| no file, UIEnter | 37.3 | 36.9 | 37.6 | 38.7 |
| no file, ready (VeryLazy plugins loaded) | 67.4 | 67.8 | 68.9 | 71.2 |
| with `.rs` file, UIEnter | 169.4 | 166.9 | 168.4 | 170.9 |
| with `.rs` file, ready | 261.5 | 259.3 | 257.5 | 265.3 |

Reading: the difference between the two "before" runs (up to 4 ms) is as large as the difference between before and after. Fully loaded, with a `.rs` file: before 259.5 ms on average, after 262.3 ms on average, +2.8 ms, inside the run-to-run spread; no file: +1.3 ms. No regression beyond a few ms was measured; a change smaller than the noise cannot be excluded or claimed. Raw data: the harness JSON was kept in the scratch directory and is not committed.
