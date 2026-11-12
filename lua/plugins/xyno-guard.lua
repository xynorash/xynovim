-- Auto-save safety, from the xyno-guard.nvim plugin: no writes into dependency sources or over files that
-- changed on disk, nothing prompts on an external change, and everything a multi-file rename touched is
-- saved. Not lazy: setup() ran at startup (options.lua) before the plugin was split out, and it has to
-- lock dependency buffers that are open right at startup. plugins/auto-save.lua uses its can_save as
-- the `condition`. Default options, no keymap (xynovim never had one for save_all). The lualine
-- component (DEP RO / STALE / GONE, groups XynoGuard*) is added to the x section below.
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
      -- the plugin may be an older version without statusline(): lualine is built once at startup
      local function guard()
        local g = package.loaded["xyno_guard"]
        return g and type(g.statusline) == "function" and g or nil
      end
      table.insert(opts.sections.lualine_x, 1, {
        function()
          return guard().statusline()
        end,
        cond = function()
          local g = guard()
          return g ~= nil and g.statusline() ~= ""
        end,
        color = function()
          local g = guard()
          return g and g.statusline_hl()
        end,
      })
    end,
  },
}
