-- A test run raises ONE notice: overseer's neotest tasks carry no on_complete_notify.
local H = require("xynotest.helpers")

describe("test run popups", function()
  it(
    "overseer's default_neotest component alias has no on_complete_notify (the results panel / 'tests: N passed' is the one)",
    function()
      local ok = pcall(require, "overseer")
      if not ok then
        return H.skip_file("overseer.nvim is not installed")
      end
      local cfg = require("overseer.config")
      local alias = cfg.component_aliases and cfg.component_aliases.default_neotest
      H.ok(alias, "default_neotest alias is set by this config")
      H.eq(false, vim.tbl_contains(alias, "on_complete_notify"))
      H.eq(true, vim.tbl_contains(alias, "on_exit_set_status"))
      -- other tasks keep their notification
      H.eq(true, vim.tbl_contains(cfg.component_aliases.default, "on_complete_notify"))
    end
  )
end)
