-- Rust server readiness (rust-analyzer indexing / ready, bacon-ls clippy
-- running / stale) in the lualine x section; see config/lsp_status.lua.
return {
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    local status = require("config.lsp_status")
    table.insert(opts.sections.lualine_x, 1, {
      status.component,
      cond = function()
        return status.component() ~= ""
      end,
    })
  end,
}
