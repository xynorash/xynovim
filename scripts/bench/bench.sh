#!/usr/bin/env bash
# Benchmark harness entry point; see README.md. Thin wrapper: `nvim -l` runs bench.lua
# without loading any user config (the measured nvims are separate processes).
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "${BENCH_NVIM:-nvim}" -l "$here/bench.lua" "$@"
