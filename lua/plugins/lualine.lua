-- Rust server readiness (rust-analyzer indexing / ready, bacon-ls clippy
-- running / stale) in the lualine x section; see xyno_rust.lsp_status (xyno-rust.nvim). The hint kinds,
-- the 99 sandbox, the disk guard and local history are appended after the stock lualine_x items
-- (config/ui.lua).
return {
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    local ui = require("config.ui")
    -- narrow windows: components drop by priority (config/ui.lua PRIORITY); the file name, the
    -- server state and the mode never do
    ui.lualine(opts)
    if ui.ascii_active() then
      opts.options = opts.options or {}
      opts.options.section_separators = ""
      opts.options.component_separators = "|"
      opts.options.icons_enabled = false -- the branch glyph and the file-type icon (found on a real capture)
    else
      -- lualine's own defaults, said again so that `:XynoIcons nerd` undoes the ascii separators
      opts.options = opts.options or {}
      opts.options.icons_enabled = true
      opts.options.section_separators = { left = "\xee\x82\xb0", right = "\xee\x82\xb2" } -- U+E0B0, U+E0B2
      opts.options.component_separators = { left = "\xee\x82\xb1", right = "\xee\x82\xb3" } -- U+E0B1, U+E0B3
    end
    local status = require("xyno_rust.lsp_status")
    table.insert(opts.sections.lualine_x, 1, {
      status.component,
      cond = function()
        return status.component() ~= ""
      end,
    })
    -- Inlay-hint kinds, sandbox state of the 99 agent (on / checking / OFF / refused), auto-save
    -- guard and local-history failures. Each shows only when it has something to say and the
    -- window is wide enough; none loads its plugin (config/ui.lua).
    for _, c in ipairs(ui.lualine_x_components()) do
      table.insert(opts.sections.lualine_x, c)
    end
  end,
}
