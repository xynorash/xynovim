-- Auto-save safety, from the xyno-guard.nvim plugin: no writes into dependency sources or over files that
-- changed on disk, nothing prompts on an external change, and everything a multi-file rename touched is
-- saved. Not lazy: setup() ran at startup (options.lua) before the plugin was split out, and it has to
-- lock dependency buffers that are open right at startup. plugins/auto-save.lua uses its can_save as
-- the `condition`. Default options, no keymap (xynovim never had one for save_all).
-- Statusline: the plugin's own component (DEP RO / STALE / GONE, groups XynoGuard*) in the lualine x
-- section. The "guard: auto-save paused" component of config/ui.lua (when that file exists) already says it
-- for a paused buffer, so the plugin's text only shows where that one is silent (dependency sources).
return {
  {
    "xynorash/xyno-guard.nvim",
    lazy = false,
    config = function()
      require("xyno_guard").setup()
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      local function guard()
        local g = package.loaded["xyno_guard"]
        return g and type(g.statusline) == "function" and g or nil
      end
      table.insert(opts.sections.lualine_x, {
        function()
          return guard().statusline()
        end,
        cond = function()
          local g = guard()
          if not g or g.statusline() == "" then
            return false
          end
          local warned = vim.b.xyno_guard_warned
          local paused_shown = package.loaded["config.ui"]
            and type(package.loaded["config.ui"].guard_status) == "function"
          return not (paused_shown and warned ~= nil and warned ~= vim.NIL)
        end,
        color = function()
          local g = guard()
          return g and g.statusline_hl()
        end,
      })
    end,
  },
}
