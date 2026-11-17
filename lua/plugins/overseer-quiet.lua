-- One popup per test run. overseer.nvim runs neotest through its strategy and its default components include
-- `on_complete_notify` ("neotest SUCCESS"), on top of the "tests: 1 passed" notice / results panel of
-- config/test_ui.lua (which also opens by itself on a failure). The neotest tasks drop the notification and
-- keep the rest (status, disposal); other overseer tasks keep theirs.
return {
  "stevearc/overseer.nvim",
  opts = function(_, opts)
    opts.component_aliases = opts.component_aliases or {}
    opts.component_aliases.default_neotest = opts.component_aliases.default_neotest
      or {
        "on_exit_set_status",
        { "on_complete_dispose", require_view = { "SUCCESS", "FAILURE" } },
      }
  end,
}
