-- Rust server readiness (rust-analyzer indexing / ready, bacon-ls clippy
-- running / stale) in the lualine x section; see xyno_rust.lsp_status (xyno-rust.nvim). The 99 sandbox
-- state (xyno-sandbox.nvim) is appended after the stock lualine_x items.
return {
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    local status = require("xyno_rust.lsp_status")
    table.insert(opts.sections.lualine_x, 1, {
      status.component,
      cond = function()
        return status.component() ~= ""
      end,
    })
    -- Sandbox state of the 99 agent (on / checking / OFF / refused). Shown once the sandbox module is
    -- loaded (99 or a :XynoSandbox* command), so the statusline never loads it at startup.
    table.insert(opts.sections.lualine_x, {
      function()
        return require("xyno_sandbox").statusline()
      end,
      cond = function()
        local sandbox = package.loaded["xyno_sandbox"]
        return sandbox ~= nil and type(sandbox.statusline) == "function"
      end,
      color = function()
        -- lualine builds its highlights while the module may be absent or an older plugin version
        local sandbox = package.loaded["xyno_sandbox"]
        if sandbox and type(sandbox.statusline_hl) == "function" then
          return sandbox.statusline_hl()
        end
      end,
    })
  end,
}
