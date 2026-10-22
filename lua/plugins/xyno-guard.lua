-- Auto-save safety, from the xyno-guard.nvim plugin: no writes into dependency sources or over files that
-- changed on disk, nothing prompts on an external change, and everything a multi-file rename touched is
-- saved. Not lazy: setup() ran at startup (options.lua) before the plugin was split out, and it has to
-- lock dependency buffers that are open right at startup. plugins/auto-save.lua uses its can_save as
-- the `condition`. No options yet, no keymap (xynovim never had one for save_all).
return {
  "xynorash/xyno-guard.nvim",
  lazy = false,
  config = function()
    require("xyno_guard").setup()
  end,
}
