-- Code coverage in the gutter (same idea as "Run with Coverage" in the JetBrains IDEs).
-- <leader>tc runs `cargo llvm-cov nextest` (falls back to plain cargo test),
-- writes target/lcov.info in the workspace root and loads it as signs. On demand
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
        local root = require("xyno_rust.rust_context").root()
        if not root then
          return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
        end
        local nextest = vim.fn.executable("cargo-nextest") == 1
        local cmd = { "cargo", "llvm-cov" }
        if nextest then
          table.insert(cmd, "nextest")
        end
        -- --ignore-run-fail: without it one failing test aborts the run and no
        -- lcov is written (it cannot be combined with --no-fail-fast).
        vim.list_extend(cmd, { "--workspace", "--ignore-run-fail", "--lcov", "--output-path", "target/lcov.info" })
        -- same features/target as the diagnostics (:RustContext)
        local rc = require("xyno_rust.rust_context")
        vim.list_extend(cmd, rc.cargo_flags(rc.get(root)))
        vim.notify("coverage: running " .. table.concat(cmd, " "))
        vim.system(cmd, { cwd = root, text = true }, function(o)
          vim.schedule(function()
            if o.code ~= 0 then
              return vim.notify("coverage run failed:\n" .. (o.stderr or ""):sub(-600), vim.log.levels.ERROR)
            end
            vim.cmd("CoverageLoad")
            vim.cmd("CoverageShow")
            vim.notify("coverage loaded (" .. root .. "/target/lcov.info)")
            -- cargo test: "1 failed;", nextest: "1 failed,"
            if (o.stderr or ""):find("[1-9]%d* failed") or (o.stdout or ""):find("[1-9]%d* failed") then
              vim.notify("coverage: some tests FAILED (the report is still written)", vim.log.levels.WARN)
            end
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
    commands = true,
    -- Summary float: plenary's default winblend = 15 let the code show
    -- through the table; opaque and smaller (140x28 was most of the screen).
    summary = { window = { winblend = 0 }, width_percentage = 0.6, height_percentage = 0.4 },
    -- the stock rust backend shells out to grcov; read cargo-llvm-cov's lcov instead
    lang = {
      rust = {
        coverage_file = function()
          return (require("xyno_rust.rust_context").root() or vim.uv.cwd()) .. "/target/lcov.info"
        end,
      },
    },
  },
  config = function(_, opts)
    local common = require("coverage.languages.common")
    local Path = require("plenary.path")
    local util = require("coverage.util")
    package.loaded["coverage.languages.rust"] = {
      sign_list = common.sign_list,
      summary = common.summary,
      load = function(callback)
        local p = Path:new(util.get_coverage_file(require("coverage.config").opts.lang.rust.coverage_file))
        if not p:exists() then
          return vim.notify("No coverage file (target/lcov.info); run <leader>tc", vim.log.levels.INFO)
        end
        callback(util.lcov_to_table(p))
      end,
    }
    require("coverage").setup(opts)
  end,
}
