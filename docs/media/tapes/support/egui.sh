# Sourced by 14-egui-new.tape (never run it directly): makes `nvim` in this shell
# use a staged copy of the template and a throw-away projects directory, with a demo
# git identity for the prefilled prompts. Nothing touches ~/projects, ~/.gitconfig or
# the real nvim cache. record.sh stages the ZIP in egui-stage/ (fetched once from
# the real eframe_template repo).
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$here/egui-projects" "$here/egui-cache"
printf '[user]\n\tname = Ada Demo\n\temail = ada@example.invalid\n' > "$here/egui-gitconfig"
export GIT_CONFIG_GLOBAL="$here/egui-gitconfig"
export XYNO_EGUI_BASE="file://$here/egui-stage" XYNO_EGUI_PARENT="$here/egui-projects"
nvim() {
  XDG_CACHE_HOME="$here/egui-cache" command nvim \
    --cmd "lua vim.g.xynovim_egui_template = { base_url = os.getenv('XYNO_EGUI_BASE') }; vim.g.xynovim_projects_dir = os.getenv('XYNO_EGUI_PARENT'); vim.g.xynovim_egui_keep_toolchain_pin = false" "$@"
}
