-- Code coverage in the gutter (RustRover "Run with Coverage").
-- <leader>tc runs `cargo llvm-cov nextest` (falls back to plain cargo test),
-- writes lcov.info in the workspace root and loads it as signs. On demand
-- only, never per autosave: an instrumented build is a separate target tree
-- and takes as long as a full test run.
return {
  "andythigpen/nvim-coverage",
  dependencies = { "nvim-lua/plenary.nvim" },
  cmd = { "Coverage", "CoverageLoad", "CoverageShow", "CoverageHide", "CoverageToggle", "CoverageSummary", "CoverageClear" },
  keys = {
    {
      "<leader>tc",
      function()
        local root = require("config.rust_context").root()
        if not root then
          return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
        end
        local nextest = vim.fn.executable("cargo-nextest") == 1
        local cmd = { "cargo", "llvm-cov" }
        if nextest then
          table.insert(cmd, "nextest")
        end
        vim.list_extend(cmd, { "--workspace", "--lcov", "--output-path", "lcov.info" })
        vim.notify("coverage: running " .. table.concat(cmd, " "))
        vim.system(cmd, { cwd = root, text = true }, function(o)
          vim.schedule(function()
            if o.code ~= 0 then
              return vim.notify("coverage run failed:\n" .. (o.stderr or ""):sub(-600), vim.log.levels.ERROR)
            end
            vim.cmd("CoverageLoad")
            vim.cmd("CoverageShow")
            vim.notify("coverage loaded (" .. root .. "/lcov.info)")
          end)
        end)
      end,
      desc = "Coverage: run + show",
    },
    { "<leader>tg", "<cmd>CoverageToggle<cr>", desc = "Coverage: toggle signs" },
    { "<leader>tG", "<cmd>CoverageSummary<cr>", desc = "Coverage: summary" },
  },
  opts = {
    auto_reload = true,
    lcov_file = "lcov.info",
    commands = true,
  },
}
