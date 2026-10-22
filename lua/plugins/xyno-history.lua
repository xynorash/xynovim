-- Local History: shadow-ref snapshots on every (throttled) save, from the xyno-history.nvim plugin
-- (refs/lochist/* layout unchanged). Not lazy: setup() starts the snapshots and registers the
-- commands, and it ran at startup before the plugin was split out.
return {
  "xynorash/xyno-history.nvim",
  lazy = false,
  keys = { { "<leader>gH", "<cmd>LocalHistory<cr>", desc = "Local history (file)" } },
  config = function()
    local history = require("xyno_history")
    history.setup()
    -- the old caps stay honoured, read on every use as before: vim.g.xynovim_lochist_max_bytes and
    -- vim.g.xynovim_lochist_max_total_bytes (setup() replaces M.config, so this comes after it)
    setmetatable(history.config, {
      __index = function(_, key)
        if key == "max_bytes" then
          return vim.g.xynovim_lochist_max_bytes
        elseif key == "max_total_bytes" then
          return vim.g.xynovim_lochist_max_total_bytes
        end
      end,
    })
  end,
}
