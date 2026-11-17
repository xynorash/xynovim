#!/usr/bin/env bash
# Run the spec suites of the xyno-*.nvim clones (docs/DEV-PLUGINS.md) with everything their optional specs need.
#
# Usage: scripts/plugin-tests.sh [plugin-name-substring...]      e.g. scripts/plugin-tests.sh guard rust
#
# Each plugin has its own `nvim --headless --clean -l tests/run.lua`; run by hand, the specs that need a
# tree-sitter parser, snacks.nvim, blink.cmp or okuuva/auto-save.nvim SKIP ("tree-sitter rust parser not
# installed", ...), which hides about 90 specs. This script points them at the copies this checkout's plugin
# manager already installed ($XDG_DATA_HOME/nvim/site for the parsers, .../lazy/<plugin> for the rest), so
# those specs run. A directory that is not there is left unset and the spec skips with its own reason.
# Nothing is installed or downloaded. XDG_CONFIG/STATE/CACHE_HOME and TMPDIR are temp dirs.
# Exit status: 0 all passed (skips allowed), 1 any failure, 2 usage/setup.
set -uo pipefail

clones=${XYNOVIM_DEV_PLUGINS:-$HOME/projects/xyno-plugins}
data=${XDG_DATA_HOME:-$HOME/.local/share}/nvim
[ -d "$clones" ] || { echo "plugin-tests: $clones is not a directory (set XYNOVIM_DEV_PLUGINS)" >&2; exit 2; }
command -v nvim >/dev/null 2>&1 || { echo "plugin-tests: nvim not found" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/xynoplug.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work"/{config,state,cache,data,tmp}
export XDG_CONFIG_HOME=$work/config XDG_STATE_HOME=$work/state XDG_CACHE_HOME=$work/cache XDG_DATA_HOME=$work/data
export TMPDIR=$work/tmp

setdir() { # setdir VAR path: export VAR when path is a directory
  [ -d "$2" ] && export "$1=$2"
  return 0
}
setdir XYNO_TEST_RTP "$data/site"
setdir XYNO_SNACKS_DIR "$data/lazy/snacks.nvim"
setdir XYNO_BLINK_DIR "$data/lazy/blink.cmp"
setdir XYNO_GUARD_AUTOSAVE_DIR "$data/lazy/auto-save.nvim"
setdir XYNO_RUST_DIR "$clones/xyno-rust.nvim"
setdir XYNO_IMPORTS_DIR "$clones/xyno-imports.nvim"

failed=() n=0
for p in "$clones"/xyno-*.nvim; do
  [ -f "$p/tests/run.lua" ] || continue
  name=$(basename "$p")
  if [ $# -gt 0 ]; then
    hit=0
    for pat in "$@"; do [[ $name == *$pat* ]] && hit=1; done
    [ $hit = 1 ] || continue
  fi
  n=$((n + 1))
  log=$work/$name.log
  (cd "$p" && timeout -k 5 1500 nvim --headless --clean -l tests/run.lua >"$log" 2>&1)
  rc=$?
  # a plugin's runner prints one RESULT line per spec file and, in some, a grand total as the last line: when the
  # last line equals the sum of the others it is that total
  read -r pass fail skip < <(grep -a -o 'RESULT passed=[0-9]* failed=[0-9]* skipped=[0-9]*' "$log" |
    sed 's/[a-z]*=//g' | awk '{P[NR]=$2; F[NR]=$3; S[NR]=$4; p+=$2; f+=$3; s+=$4}
      END{ if (NR>1 && P[NR]==p-P[NR] && F[NR]==f-F[NR] && S[NR]==s-S[NR]) print P[NR], F[NR], S[NR]; else print p+0, f+0, s+0 }')
  printf '%-22s %s passed, %s failed, %s skipped (exit %s)\n' "$name" "${pass:-0}" "${fail:-0}" "${skip:-0}" "$rc"
  grep -a -E '^(SKIP|FAIL)' "$log" | sed 's/^/    /'
  [ "$rc" = 0 ] || failed+=("$name")
done
[ "$n" -gt 0 ] || { echo "plugin-tests: no plugin matches $*" >&2; exit 2; }
if [ ${#failed[@]} -gt 0 ]; then
  echo "failed: ${failed[*]}"
  exit 1
fi
exit 0
