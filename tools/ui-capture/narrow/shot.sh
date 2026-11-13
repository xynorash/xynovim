#!/usr/bin/env bash
# One real-pixel capture of the neotest summary and dap-ui open together. Usage: shot.sh <config-checkout> <columns> <lines> <out.png>
# (config-checkout: this repo, or an older worktree for a "before" picture). Same isolation as ../rainbow/shot.sh.
set -uo pipefail
cfgrepo=$1 cols=$2 rows=$3 out=$4
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/nrshot.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work"/{cfg,state,cache}
ln -s "$cfgrepo" "$work/cfg/nvim"
cp -r "$repo/tests/fixtures/failing-tests" "$work/crate"
cp "$here"/scene.lua "$work"/
ready=$work/ready
pre=$(xprop -root _NET_CLIENT_LIST | sed 's/.*# //; s/,//g')
env -i HOME="$HOME" PATH="$PATH" DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
  GDK_BACKEND=x11 XDG_CONFIG_HOME="$work/cfg" XDG_STATE_HOME="$work/state" XDG_CACHE_HOME="$work/cache" \
  XDG_DATA_HOME="$HOME/.local/share" NR_READY="$ready" NR_DIR="$work" TERM=xterm-ghostty \
  ghostty --class=xynonarrow --title=xynonarrow --background-opacity=1 --minimum-contrast=1 \
  --window-width="$cols" --window-height="$rows" --font-size=13 --font-family="JetBrainsMono Nerd Font Mono" \
  --window-save-state=never --confirm-close-surface=false \
  -e nvim -n -c "luafile $work/scene.lua" >/dev/null 2>&1 &
gpid=$!
for _ in $(seq 1 120); do [ -f "$ready" ] && break; sleep 0.5; done
id=""
for w in $(xprop -root _NET_CLIENT_LIST | sed 's/.*# //; s/,//g'); do case " $pre " in *" $w "*) ;; *) id=$w ;; esac; done
echo "window $id $(cat "$ready" 2>/dev/null || echo NOT-READY) -> $out"
[ -n "$id" ] && ffmpeg -loglevel error -y -f x11grab -window_id "$id" -i "${DISPLAY:-:0}" -frames:v 1 "$out"
kill "$gpid" 2>/dev/null
sleep 0.5
pkill -f "xynonarrow" 2>/dev/null
exit 0
