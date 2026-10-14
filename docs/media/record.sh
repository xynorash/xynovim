#!/usr/bin/env bash
# Regenerates the screenshots and videos in docs/media/ from the tapes in
# docs/media/tapes/ (vhs: https://github.com/charmbracelet/vhs).
#
#   docs/media/record.sh              all tapes
#   docs/media/record.sh 02-diag ...  only the named tapes (file names without .tape)
#
# Needs: vhs, ttyd, chromium, ffmpeg, the JetBrainsMono Nerd Font and this
# config installed as ~/.config/nvim (after scripts/bootstrap.sh).
# Every tape runs on a fresh copy of demo/netwatch in a temp dir (git repo with
# one commit), so recording never touches the checkout.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out=$repo/docs/media
for tool in vhs ttyd ffmpeg nvim cargo git; do
  command -v "$tool" >/dev/null || { echo "record.sh: $tool not found" >&2; exit 1; }
done
command -v chromium >/dev/null || command -v chromium-browser >/dev/null || command -v google-chrome >/dev/null ||
  { echo "record.sh: chromium not found" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$repo/docs/media/tapes/support" "$work/support" # helper scripts the tapes call as ../support/<name>.sh

prepare() { # fresh demo copy with a warm build so rust-analyzer/clippy answer quickly
  rm -rf "$work/netwatch"
  cp -r "$repo/demo/netwatch" "$work/netwatch"
  (
    cd "$work/netwatch"
    rm -rf target
    git init -q -b main
    git add -A
    git -c user.name=demo -c user.email=demo@example.invalid commit -qm "netwatch demo"
    cargo build -q --all-targets 2>/dev/null
  )
}

tapes=("$@")
if [ ${#tapes[@]} -eq 0 ]; then
  while IFS= read -r f; do tapes+=("$(basename "$f" .tape)"); done < <(ls "$repo"/docs/media/tapes/[0-9]*.tape)
fi

for name in "${tapes[@]}"; do
  src=$repo/docs/media/tapes/$name.tape
  [ -f "$src" ] || { echo "record.sh: no tape $src" >&2; exit 1; }
  echo "== $name"
  prepare
  cd "$work/netwatch"
  { cat "$repo/docs/media/tapes/_common.tape"; echo "Output \"$name.gif\""; echo "Output \"$name.mp4\""; cat "$src"; } > "$work/$name.tape"
  vhs "$work/$name.tape"
  for f in "$name".gif "$name".mp4 "$name"*.png; do
    [ -f "$f" ] && mv -f "$f" "$out/"
  done
done
ls -la "$out"
