#!/usr/bin/env bash
# One real-pixel capture of the rainbow brackets: a private Ghostty window (X11), this config, scene.lua, then
# ffmpeg x11grab of that window. Usage: shot.sh <scene> <columns> <lines> <out.png> [font-size]
#   scene: off | on | light | cb | lightcb | high | scope | restrain | vars | mismatch | words-{py,c,html,tsx,yaml}   (see scene.lua)
# Needs ghostty, ffmpeg, xprop and an X11 (or Xwayland) display. Private XDG state / cache; the real plugin
# directory (XDG_DATA_HOME) is read, nothing is installed. The window size follows the compositor: the grid
# actually reached is written next to "window" in the output line.
set -uo pipefail
scene=$1 cols=$2 rows=$3 out=$4 fs=${5:-13}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/rbshot.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work"/{cfg,state,cache}
ln -s "$repo" "$work/cfg/nvim"
cp "$here"/demo.rs "$here"/mismatch.rs "$here"/words.* "$here"/scene.lua "$work"/
ready=$work/ready
pre=$(xprop -root _NET_CLIENT_LIST | sed 's/.*# //; s/,//g')
env -i HOME="$HOME" PATH="$PATH" DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
  GDK_BACKEND=x11 XDG_CONFIG_HOME="$work/cfg" XDG_STATE_HOME="$work/state" XDG_CACHE_HOME="$work/cache" \
  XDG_DATA_HOME="$HOME/.local/share" RB_SCENE="$scene" RB_READY="$ready" RB_DIR="$work" TERM=xterm-ghostty \
  ghostty --class=xynorainbow --title=xynorainbow --background-opacity=1 --minimum-contrast=1 \
  --window-width="$cols" --window-height="$rows" --font-size="$fs" --font-family="JetBrainsMono Nerd Font Mono" \
  --window-save-state=never --confirm-close-surface=false \
  -e nvim -n -c "lua vim.g.xynovim_workspace_trust=false" -c "luafile $work/scene.lua" >/dev/null 2>&1 &
gpid=$!
for _ in $(seq 1 120); do [ -f "$ready" ] && break; sleep 0.5; done
id=""
for w in $(xprop -root _NET_CLIENT_LIST | sed 's/.*# //; s/,//g'); do case " $pre " in *" $w "*) ;; *) id=$w ;; esac; done
echo "window $id $(cat "$ready" 2>/dev/null || echo NOT-READY) -> $out"
[ -n "$id" ] && ffmpeg -loglevel error -y -f x11grab -window_id "$id" -i "${DISPLAY:-:0}" -frames:v 1 "$out"
kill "$gpid" 2>/dev/null
sleep 0.5
pkill -f "xynorainbow" 2>/dev/null
exit 0
