#!/usr/bin/env bash
# Copy the lint and security files of this directory into a plugin checkout:
#   docs/plugin-ci-templates/apply.sh ~/projects/xyno-plugins/xyno-rust.nvim
# Writes files only; it never commits, pushes or touches git. Existing files
# are kept (the script says so) unless FORCE=1.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dest=${1:?usage: apply.sh <plugin checkout>}
[ -d "$dest/lua" ] || { echo "apply: $dest does not look like a plugin checkout (no lua/)" >&2; exit 2; }

put() { # put <source> <relative destination>
  local to=$dest/$2
  if [ -e "$to" ] && [ "${FORCE:-}" != 1 ]; then
    echo "kept    $2 (exists; FORCE=1 overwrites)"
    return
  fi
  mkdir -p "$(dirname "$to")"
  cp "$here/$1" "$to"
  echo "wrote   $2"
}

put lint.yml .github/workflows/lint.yml
put dependabot.yml .github/dependabot.yml
put luarc.json .luarc.json
put stylua.toml .stylua.toml
put SECURITY.md SECURITY.md
echo
echo "Next: run 'stylua .' once in $dest and commit the formatting separately,"
echo "then fix what 'lua-language-server --check . --checklevel=Warning' reports."
