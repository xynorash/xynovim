#!/usr/bin/env bash
# Set up isolated copies of the four public starter configs with Rust support and benchmark each
# with the same harness. NOT run by the harness's own tests: it clones and executes third-party
# Lua (the starters and their plugins), so read it and run it yourself.
#
# usage: scripts/bench/compare.sh DIR [name...]      names: lazyvim kickstart astronvim nvchad
# Everything (config, data, state, cache) lives under DIR/<name>/; nothing touches ~/.config/nvim,
# ~/.local/share/nvim, ~/.local/state/nvim or ~/.cache/nvim. Results: DIR/results/<name>.json + .md.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=${1:?usage: compare.sh DIR [name...]}
shift || true
names=("$@")
[ ${#names[@]} -gt 0 ] || names=(lazyvim kickstart astronvim nvchad)
mkdir -p "$root/results"
root=$(cd "$root" && pwd)

declare -A repo=(
  [lazyvim]=https://github.com/LazyVim/starter
  [kickstart]=https://github.com/nvim-lua/kickstart.nvim
  [astronvim]=https://github.com/AstroNvim/template
  [nvchad]=https://github.com/NvChad/starter
)

rust_support() { # name: the documented way to add Rust, per starter
  local d=$root/$1/config/$1
  case $1 in
    lazyvim) # the lang.rust extra, as :LazyExtras would enable it
      perl -0pi -e 's|(    -- import/override with your plugins\n)|    { import = "lazyvim.plugins.extras.lang.rust" },\n$1|' "$d/lua/config/lazy.lua" ;;
    kickstart) # the commented-out rust_analyzer entry of the servers table
      sed -i 's|^    -- rust_analyzer = {},|    rust_analyzer = {},|' "$d/init.lua" ;;
    astronvim) # astrocommunity's rust pack
      sed -i '/^if true then return {} end/d; s|  { import = "astrocommunity.pack.lua" },|&\n  { import = "astrocommunity.pack.rust" },|' "$d/lua/community.lua" ;;
    nvchad) # the servers list of lua/configs/lspconfig.lua, plus the rust parser
      sed -i 's|local servers = { "html", "cssls" }|local servers = { "html", "cssls", "rust_analyzer" }|' "$d/lua/configs/lspconfig.lua"
      perl -0pi -e 's|  -- \{\n  -- \t"nvim-treesitter/nvim-treesitter",\n  -- \topts = \{\n  -- \t\tensure_installed = \{\n  -- \t\t\t"vim", "lua", "vimdoc",\n  --      "html", "css"\n  -- \t\t\},\n  -- \t\},\n  -- \},|  { "nvim-treesitter/nvim-treesitter", opts = { ensure_installed = { "vim", "lua", "vimdoc", "html", "css", "rust", "toml" } } },|' "$d/lua/plugins/init.lua" ;;
  esac
}

for n in "${names[@]}"; do
  [ -n "${repo[$n]:-}" ] || { echo "unknown config $n" >&2; exit 2; }
  mkdir -p "$root/$n"/{config,data,state,cache}
  if [ ! -d "$root/$n/config/$n" ]; then
    git clone -q --depth 1 "${repo[$n]}" "$root/$n/config/$n"
    rust_support "$n"
  fi
  echo "== $n: $(git -C "$root/$n/config/$n" rev-parse --short HEAD)"
  export NVIM_APPNAME=$n XDG_CONFIG_HOME=$root/$n/config XDG_DATA_HOME=$root/$n/data \
    XDG_STATE_HOME=$root/$n/state XDG_CACHE_HOME=$root/$n/cache
  # first start installs plugins/parsers/mason packages; bounded, two passes
  for _ in 1 2; do
    timeout 600 nvim --headless "+lua if package.loaded.lazy then require('lazy').sync({wait=true}) end" \
      "+lua vim.wait(90000, function() return false end)" +qa >/dev/null 2>&1 || true
  done
  BENCH_CONFIG="$XDG_CONFIG_HOME/$n" "$here/bench.sh" --label "$n" --out "$root/results/$n.json" --md "$root/results/$n.md" || echo "bench failed for $n" >&2
done
