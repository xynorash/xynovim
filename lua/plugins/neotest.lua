-- Tests: neotest (LazyVim test.core + rustaceanvim's adapter) with
--   * a persistent output panel at the bottom and the summary on the right,
--   * the xynovim results panel (lua/config/test_ui.lua): failures first, per-test folded output,
--     assert_eq! diff, timing, nextest profile, coverage total; it opens by itself when a run fails,
--   * rerun failed (<leader>tf), nextest profile (<leader>tP), doc-tests into the same panel (<leader>tE; <leader>tD is the terminal run).
-- Debugging a test: <leader>td (neotest strategy dap -> codelldb, same formatters / panic stop as a launch).
return {
  {
    "nvim-neotest/neotest",
    -- a plain table: lazy.nvim merges it into LazyVim's (opts.adapters must stay a table for the specs)
    opts = {
      -- LazyVim opens a float with the output on every run; the panel below replaces it
      output = { enabled = true, open_on_run = false },
      output_panel = { enabled = true, open = "botright split | resize 14" },
      summary = {
        enabled = true,
        animated = false,
        follow = true,
        expand_errors = true,
        -- a 48-column split on a wide window, a float over the right edge below 120 columns
        -- (config/narrow.lua): the split left ~30 columns for the code at 93
        open = function()
          return require("config.narrow").summary_open()
        end,
      },
      -- LazyVim opens Trouble's quickfix on a failed run; the results panel already lists the failures
      quickfix = { enabled = true, open = false },
      status = { enabled = true, virtual_text = true, signs = true },
      diagnostic = { enabled = true, severity = vim.diagnostic.severity.ERROR },
      floating = { border = "rounded", max_height = 0.6, max_width = 0.8 },
      consumers = {
        -- every neotest run (cargo test / nextest of the rustaceanvim adapter) compiles and runs workspace code:
        -- workspace trust first (config/workspace_trust.lua)
        xyno_trust = function(client)
          require("config.workspace_trust").guard_neotest(client)
          return {}
        end,
        xyno_panel = function(client)
          require("config.test_ui").consumer(client)
        end,
      },
    },
    keys = {
      {
        "<leader>tp",
        function()
          require("config.test_ui").toggle()
        end,
        desc = "Test results panel (failures, diff, timing)",
      },
      {
        "<leader>tf",
        function()
          require("config.test_ui").rerun_failed()
        end,
        desc = "Rerun failed tests",
      },
      {
        "<leader>tE",
        function()
          require("config.test_ui").run_doctests()
        end,
        ft = "rust",
        desc = "Doctests into the results panel",
      },
      {
        "<leader>tP",
        function()
          require("config.test_ui").pick_profile()
        end,
        desc = "nextest profile",
      },
    },
  },
}
