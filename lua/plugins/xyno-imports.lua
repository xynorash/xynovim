-- Auto-import, ranked disambiguation and organize imports, from the xyno-imports.nvim plugin
-- (:ImportName, :ImportForget, :ImportOrganize, the buffer-local <leader>rI / <leader>rO in Rust files).
-- Loaded at VeryLazy, like the rest of the UI layer (the old setup waited for it too: keys and commands
-- need LazyVim's own maps in place to leave them alone). The crates.io candidate source of
-- config/crate_import.lua (Add crate X and import) is registered on the engine right after setup().
--
-- The old behaviour stays, as a thin layer over the plugin:
--   * vim.g.xynovim_auto_import ("ask" default, "single", "off") still decides the mode, read at every
--     call as before; the plugin's own vim.g.xyno_auto_import wins when both are set;
--   * the remembered choices stay in stdpath("state")/xynovim/imports.json (the plugin's default is
--     xyno-imports/imports.json), so nothing already remembered is lost.
local OLD_MODES = { ask = true, single = true, off = true }

return {
  "xynorash/xyno-imports.nvim",
  dependencies = { "xynorash/xyno-rust.nvim" },
  event = "VeryLazy",
  config = function()
    require("xyno_imports").setup({ commands = true, keymaps = true })
    local engine = require("xyno_imports.engine")
    engine.state_file = vim.fn.stdpath("state") .. "/xynovim/imports.json"
    engine.reload_memory()
    local plugin_mode = engine.mode
    engine.mode = function()
      local new = vim.g.xyno_auto_import
      local old = vim.g.xynovim_auto_import
      if not OLD_MODES[new] and OLD_MODES[old] then
        return old
      end
      return plugin_mode()
    end
    -- crates.io candidates for names no dependency offers (Add crate X and import)
    require("config.crate_import").setup()
  end,
}
