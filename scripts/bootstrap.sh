#!/usr/bin/env bash
# Bootstrap this config on a fresh machine (or an empty XDG data dir) so the
# plugins end up on exactly the commits in lazy-lock.json.
#
# Why two steps: a single `nvim --headless '+Lazy! restore' +qa` on an empty
# data dir installs in several rounds (a plugin's own specs are only read
# after it is cloned) and lazy rewrites lazy-lock.json after every round with
# the plugins it knows so far, which drops the pins of the ones discovered
# later; those land on their newest commit and the lockfile changes. So:
#   1. `Lazy! install` clones everything (the lockfile is rewritten, ignored);
#   2. the original lockfile is put back, then `Lazy! restore` checks out the
#      pinned commits of the now complete plugin set.
# lazy-lock.json is left exactly as it was; the script fails if it is not.
#
# Usage: scripts/bootstrap.sh          (config = the checkout this lives in)
# Env:   XDG_CONFIG_HOME / XDG_DATA_HOME / ... are honoured (fresh dirs work).
#        BOOTSTRAP_SKIP_PREREQS=1 skips the prerequisite check.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lock=$repo/lazy-lock.json

# nvim reads the config from $XDG_CONFIG_HOME/nvim; make sure that is us.
cfg=${XDG_CONFIG_HOME:-$HOME/.config}/nvim
if [ "$(readlink -f "$cfg" 2>/dev/null || true)" != "$(readlink -f "$repo")" ]; then
  echo "bootstrap: $cfg is not this checkout ($repo)." >&2
  echo "  link it first:  ln -s '$repo' '$cfg'" >&2
  exit 1
fi

# Prerequisites. Required to bring the config up and to build/run what Mason
# and the Rust workflow need: git/curl/tar/unzip/gzip (lazy, Mason downloads), gcc
# (treesitter parsers, blink.cmp fallback), node/npm (Mason's markdownlint-cli2,
# markdown-toc, yaml-language-server), cargo/rustup/rust-analyzer (Rust).
if [ "${BOOTSTRAP_SKIP_PREREQS:-}" != 1 ]; then
  missing=()
  for tool in nvim git curl tar unzip gzip gcc npm node cargo rustup rust-analyzer; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  # rustup ships a rust-analyzer proxy even when the component is absent.
  if command -v rust-analyzer >/dev/null 2>&1 && ! rust-analyzer --version >/dev/null 2>&1; then
    missing+=("rust-analyzer (installed as a rustup proxy only: rustup component add rust-analyzer)")
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    echo "bootstrap: missing prerequisites:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo "Install them (or set BOOTSTRAP_SKIP_PREREQS=1 to go on anyway) and rerun." >&2
    exit 1
  fi
fi

orig=$(mktemp)
trap 'rm -f "$orig"' EXIT
cp "$lock" "$orig"

echo "bootstrap: step 1/3, Lazy! install"
nvim --headless '+Lazy! install' +qa
cp "$orig" "$lock"

echo "bootstrap: step 2/3, Lazy! restore"
nvim --headless '+Lazy! restore' +qa

echo "bootstrap: step 3/3, treesitter parsers and Mason tools (LazyVim downloads them lazily on a first start)"
nvim --headless "+luafile $repo/scripts/provision.lua" +qa

if cmp -s "$orig" "$lock"; then
  echo "bootstrap: done, lazy-lock.json unchanged."
else
  echo "bootstrap: lazy-lock.json changed during restore (some plugin is not on its pinned commit):" >&2
  diff "$orig" "$lock" >&2 || true
  cp "$orig" "$lock"
  exit 1
fi
