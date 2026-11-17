#!/usr/bin/env bash
# Run xynovim (or its tests, or the benchmarks) against LOCAL clones of the xyno-* plugins instead of the
# commits pinned in lazy-lock.json. Nothing is installed, pushed or updated; ~/.local/share/nvim/lazy is
# not touched. See docs/DEV-PLUGINS.md.
#
#   scripts/dev-plugins.sh status            which clone is on which branch/commit, dirty or not
#   scripts/dev-plugins.sh nvim [args]       nvim with the clones (default: interactive)
#   scripts/dev-plugins.sh test [args]       scripts/test.sh with the clones (args as for test.sh)
#   scripts/dev-plugins.sh bench [args]      scripts/bench/bench.sh with the clones
#   scripts/dev-plugins.sh run CMD...        any command with XYNOVIM_DEV_PLUGINS exported
#
# The clone directory is $XYNOVIM_DEV_PLUGINS, default ~/projects/xyno-plugins.
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dir=${XYNOVIM_DEV_PLUGINS:-$HOME/projects/xyno-plugins}
if [ ! -d "$dir" ]; then
  echo "dev-plugins: $dir is not a directory (set XYNOVIM_DEV_PLUGINS to the folder holding the xyno-*.nvim clones)" >&2
  exit 2
fi
export XYNOVIM_DEV_PLUGINS=$dir

status() {
  local p name branch dirty
  for p in "$dir"/xyno-*.nvim; do
    [ -d "$p/.git" ] || continue
    name=$(basename "$p")
    branch=$(git -C "$p" branch --show-current)
    dirty=""
    [ -n "$(git -C "$p" status --porcelain)" ] && dirty=" (uncommitted changes)"
    printf '%-24s %-8s %s%s\n' "$name" "${branch:-detached}" "$(git -C "$p" log -1 --format='%h %s' | cut -c1-70)" "$dirty"
  done
}

cmd=${1:-nvim}
[ $# -gt 0 ] && shift
case $cmd in
  status) status ;;
  nvim) exec nvim "$@" ;;
  test) exec "$repo/scripts/test.sh" "$@" ;;
  bench) exec "$repo/scripts/bench/bench.sh" "$@" ;;
  run) exec "$@" ;;
  *)
    echo "usage: scripts/dev-plugins.sh status|nvim|test|bench|run ..." >&2
    exit 2
    ;;
esac
