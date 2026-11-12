#!/usr/bin/env bash
# Redraw / scroll / typing latency of the rainbow brackets on a 2 000-line and a large Rust file, brackets on
# versus off, in a private XDG tree (nothing of yours is touched). Usage:
#   scripts/bench/rainbow.sh [--lines N] [--rounds R] [--config DIR]   (prints a table; json goes to $RB_KEEP if set)
# --config measures another checkout of this config (e.g. a `git archive` of an older commit: no rainbow module,
# so only the "off" column of that run is meaningful and it is the "before").
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
lines=40000 rounds=3 cfg=$repo
while [ $# -gt 0 ]; do
  case $1 in
    --lines) shift; lines=$1 ;;
    --rounds) shift; rounds=$1 ;;
    --config) shift; cfg=$(cd "$1" && pwd) ;;
    -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
work=$(mktemp -d "${TMPDIR:-/tmp}/rbbench.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work"/{config,state,cache,files}
ln -s "$cfg" "$work/config/nvim"
data=${XDG_DATA_HOME:-$HOME/.local/share}
for m in off on; do
  for r in $(seq "$rounds"); do
    env XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state" XDG_CACHE_HOME="$work/cache" XDG_DATA_HOME="$data" \
      RB_MODE=$m RB_LINES=$lines RB_OUT="$work/$m.$r.json" RB_FILE_DIR="$work/files" \
      timeout 300 nvim --headless --cmd "lua vim.g.xynovim_workspace_trust=false" -c "luafile $repo/scripts/bench/rainbow.lua" </dev/null >/dev/null 2>&1
  done
done
python3 - "$work" "$rounds" <<'PY'
import json, sys, statistics as st, glob
work, rounds = sys.argv[1], int(sys.argv[2])
def load(m):
    out = []
    for r in range(1, rounds + 1):
        try:
            out.append(json.load(open(f"{work}/{m}.{r}.json")))
        except Exception as e:
            print("missing", m, r, e)
    return out
runs = {m: load(m) for m in ("off", "on")}
if not runs["on"] or not runs["off"]:
    sys.exit(1)
import os
keep = os.environ.get("RB_KEEP")
if keep:
    json.dump(runs, open(keep, "w"), indent=1)
def med(m, size, key, stat):
    v = [r[size][key][stat] for r in runs[m] if r[size].get(key)]
    return st.median(v) if v else float("nan")
print("redraw latency in ms, median over %d rounds (each cell: median / p95 / max of its samples)" % rounds)
print(f"{'':28}{'off':>26}{'on':>26}{'on-off median':>16}")
for size in ("small", "large"):
    n = runs["on"][0][size]["lines"]
    for key, label in (("jump_ms", "jump"), ("scroll_ms", "scroll 3 lines"), ("typing_ms", "type one char")):
        cells = []
        for m in ("off", "on"):
            cells.append("%.1f / %.1f / %.1f" % tuple(med(m, size, key, s) for s in ("median", "p95", "max")))
        d = med("on", size, key, "median") - med("off", size, key, "median")
        print(f"{size + ' ' + str(n) + ' ' + label:28}{cells[0]:>26}{cells[1]:>26}{d:>16.2f}")
    print(f"{'  tier / first redraw':28}{'tier %d, %.0f ms' % (runs['on'][0][size]['large_tier'], med('off', size, 'first_redraw_ms', 'median') if False else runs['off'][0][size]['first_redraw_ms']):>26}{'%.0f ms' % runs['on'][0][size]['first_redraw_ms']:>26}")
p = runs["on"][0].get("provider")
print("provider counters (on, round 1):", p)
PY
