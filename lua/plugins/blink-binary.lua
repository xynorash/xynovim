-- blink.cmp's native fuzzy library: quiet, once-only, explicit (config/blink_binary.lua, :checkhealth xynovim).
return {
  "saghen/blink.cmp",
  opts = function(_, opts)
    opts.fuzzy = vim.tbl_deep_extend("force", opts.fuzzy or {}, require("config.blink_binary").fuzzy_opts())
  end,
}
