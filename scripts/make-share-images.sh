#!/usr/bin/env bash
# Regenerate the share images with ImageMagick (the Island Dark palette from
# lua/island/palette.lua, DejaVu fonts, a screenshot from docs/media):
#
#   site/assets/og.png              1200x630 card of the home page
#   site/assets/og/<slug>.png       1200x630 card of each guide
#   site/assets/og-plugins.png      1200x630 card of the plugins page (the nine names, no screenshot)
#   site/assets/social-preview.png  1280x640 GitHub social preview (upload it by hand:
#                                   Settings > Social preview; GitHub has no API for it)
#
# Usage: scripts/make-share-images.sh      (needs `magick`; the PNGs are committed)
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"
command -v magick >/dev/null || { echo "make-share-images: ImageMagick (magick) is missing" >&2; exit 2; }

BG='#1e1f22' PANEL='#2b2d30' BORDER='#393b40' TITLE='#e6e8ec' MUTED='#9da0a8' BLUE='#56a8f5' GREEN='#6aab73'
BOLD=DejaVu-Sans-Bold SANS=DejaVu-Sans MONO=DejaVu-Sans-Mono-Bold

# card OUT WIDTH HEIGHT KICKER TITLE SUBTITLE SHOT [TITLE_SIZE_PERMILLE_OF_WIDTH]
card() {
  local out=$1 w=$2 h=$3 kicker=$4 title=$5 sub=$6 shot=$7 tsize=${8:-46}
  local tw=$((w - 144)) shotw=$((w * 8 / 10))
  mkdir -p "$(dirname "$out")"
  magick -size "${w}x${h}" "xc:$BG" \
    \( "$shot" -resize "${shotw}x" -bordercolor "$BORDER" -border 2 \) -gravity north -geometry "+0+$((h * 52 / 100))" -composite \
    \( -size "${w}x$((h * 52 / 100))" "xc:$BG" \) -gravity north -composite \
    \( -size "${tw}x40" -background none -fill "$BLUE" -font "$MONO" -pointsize 28 -gravity west caption:"$kicker" \) -gravity northwest -geometry "+72+$((h * 6 / 100))" -composite \
    \( -size "${tw}x$((h * 22 / 100))" -background none -fill "$TITLE" -font "$BOLD" -pointsize $((w * tsize / 1000)) -gravity northwest caption:"$title" \) -gravity northwest -geometry "+72+$((h * 16 / 100))" -composite \
    \( -size "${tw}x40" -background none -fill "$MUTED" -font "$SANS" -pointsize 27 -gravity west caption:"$sub" \) -gravity northwest -geometry "+72+$((h * 40 / 100))" -composite \
    \( -size "$((w / 3))x36" -background none -fill "$GREEN" -font "$MONO" -pointsize 22 -gravity east caption:"xynorash.github.io/xynovim" \) -gravity northeast -geometry "+72+$((h * 8 / 100))" -composite \
    -colors 128 -depth 8 "PNG8:$out"
  echo "$out $(identify -format '%wx%h' "$out") $(stat -c %s "$out") bytes"
}

TAG="A personal Neovim configuration for Rust"
card site/assets/og.png 1200 630 "Neovim, Rust, LazyVim" "xynovim" "$TAG" docs/media/01-hero.png 100
card site/assets/social-preview.png 1280 640 "Neovim, Rust, LazyVim" "xynovim" "$TAG" docs/media/01-hero.png 100

# slug | title | subtitle | screenshot
while IFS='|' read -r slug title sub shot; do
  card "site/assets/og/$slug.png" 1200 630 "xynovim guide" "$title" "$sub" "docs/media/$shot"
done <<'LIST'
neovim-rust-diagnostics|Instant Rust diagnostics in Neovim|rust-analyzer while you type, clippy half a second later|02-diagnostics-clippy.png
neovim-rust-debugging|Debugging Rust in Neovim|nvim-dap and codelldb, with Rust-aware variable views|06-debug-stopped.png
neovim-rust-tests-coverage|Rust tests and coverage in Neovim|neotest, cargo-nextest and coverage in the gutter|05-tests-coverage.png
neovim-cargo-workspaces|Cargo workspaces, features and crates in Neovim|New projects, :CrateAdd and :CrateFeatures|15-rust-new-workspace-tree.png
neovim-git-local-history|A git safety net for Neovim|Local History as git refs, lazygit and diffview|08-git-local-history.png
neovim-island-dark-theme|The Island Dark colour scheme for Neovim|A dark palette for Rust, Treesitter and LSP tokens|09-theme-completion.png
LIST

# The plugins page: the card shows the nine plugin names instead of a screenshot.
plug=$(mktemp --suffix=.png)
trap 'rm -f "$plug"' EXIT
magick -size 1440x470 "xc:$PANEL" -font "$MONO" -pointsize 40 \
  -fill "$BLUE" -annotate +60+80 "Standalone" -fill "$BLUE" -annotate +760+80 "Rust toolkit" \
  -fill "$TITLE" -annotate +60+160 "xyno-history.nvim" -annotate +60+215 "xyno-sandbox.nvim" -annotate +60+270 "xyno-clipboard.nvim" -annotate +60+325 "xyno-guard.nvim" \
  -annotate +760+160 "xyno-rust.nvim" -annotate +760+215 "xyno-new.nvim" -annotate +760+270 "xyno-imports.nvim" -annotate +760+325 "xyno-crates.nvim" -annotate +760+380 "xyno-macros.nvim" \
  "$plug"
card site/assets/og-plugins.png 1200 630 "xynovim plugins" "Nine Neovim plugins" "MIT licensed, extracted from my config, installed with lazy.nvim" "$plug" 60
