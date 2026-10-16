# Sourced by 15-rust-new.tape (never run it directly): makes `nvim` in this shell
# use a throw-away projects directory as the parent of the new projects, so nothing
# is created in ~/projects.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
XYNO_RUSTNEW_PARENT=${TMPDIR:-/tmp}/xyno-rust-demo # short on purpose (record.sh removes it)
rm -rf "$XYNO_RUSTNEW_PARENT"
mkdir -p "$XYNO_RUSTNEW_PARENT"
export XYNO_RUSTNEW_PARENT
nvim() {
  command nvim --cmd "lua vim.g.xynovim_projects_dir = os.getenv('XYNO_RUSTNEW_PARENT')" "$@"
}
