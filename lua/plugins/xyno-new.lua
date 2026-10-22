-- New Rust projects, from the xyno-new.nvim plugin: :RustNewBin, :RustNewLib, :RustNewWorkspace,
-- :RustNewMember and :EguiNew, and the dashboard entries New Rust Binary / Library / Workspace
-- (b, i, w) and New egui Project (e) on the snacks dashboard. No keymaps (keymaps = false): xynovim
-- never had any, the dashboard keys call the commands.
-- Loading: the dashboard spec below asks the plugin for its entries while snacks is configured, so it
-- is loaded at startup (as config.rust_new / config.egui_new were); `cmd` is there for a setup where
-- the dashboard is off. xyno-rust.nvim is its dependency.
-- The old globals still work, mapped here to the setup options when the plugin loads (at startup),
-- so set them before that (options.lua or --cmd); a value set later in the session is ignored:
--   vim.g.xynovim_projects_dir          -> projects_dir
--   vim.g.xynovim_egui_template         -> egui_template
--   vim.g.xynovim_egui_build_after_new  -> egui_build_after_new
return {
  {
    "xynorash/xyno-new.nvim",
    dependencies = { "xynorash/xyno-rust.nvim" },
    cmd = { "RustNewBin", "RustNewLib", "RustNewWorkspace", "RustNewMember", "EguiNew" },
    opts = function()
      return {
        commands = true,
        keymaps = false,
        projects_dir = vim.g.xynovim_projects_dir,
        egui_template = vim.g.xynovim_egui_template,
        egui_build_after_new = vim.g.xynovim_egui_build_after_new,
      }
    end,
  },
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      opts.dashboard = opts.dashboard or {}
      opts.dashboard.preset = opts.dashboard.preset or {}
      opts.dashboard.preset.keys = require("xyno_new").dashboard_keys(opts.dashboard.preset.keys or {})
    end,
  },
}
