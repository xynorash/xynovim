-- Runs ONE spec file inside this nvim (the full config is loaded). Started by
-- scripts/test.sh as
--   nvim --headless -S tests/runner.lua      with XYNO_SPEC=<spec file>
-- Output: one line per test (ok / FAIL / SKIP) and a final
--   XYNO_RESULT passed=N failed=N skipped=N
-- line that scripts/test.sh parses. Exit code is 0 only without failures.
local spec = assert(vim.env.XYNO_SPEC, "XYNO_SPEC not set")
local repo = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
-- "tests.*" would also match other plugins' lua/tests/ modules (lazy's loader
-- runs before package.path), so the helpers live under a private name.
for _, name in ipairs({ "helpers", "harness" }) do
  package.preload["xynotest." .. name] = function()
    return dofile(repo .. "/tests/" .. name .. ".lua")
  end
end

local function finish(n)
  -- The result goes out first: a cleanup that hangs (a language server that does
  -- not die) must not turn a finished spec into a timeout; test.sh gives the
  -- process a grace period after the result line, then kills it.
  io.stdout:write(("XYNO_RESULT passed=%d failed=%d skipped=%d\n"):format(n.passed, n.failed, n.skipped))
  io.stdout:flush()
  local ok, helpers = pcall(function()
    return package.loaded["xynotest.helpers"]
  end)
  if ok and helpers then
    pcall(helpers.cleanup)
  end
  if vim.env.XYNO_COV_OUT and _G.__xyno_cov then
    pcall(_G.__xyno_cov.dump, vim.env.XYNO_COV_OUT)
  end
  if n.failed > 0 then
    vim.cmd("cquit 1")
  else
    vim.cmd("qa!")
  end
end

local function main()
  local harness = require("xynotest.harness")
  harness.install()
  -- A spec may bail out at load time with helpers.skip_file(reason).
  local ok, err = xpcall(dofile, debug.traceback, spec)
  if not ok then
    if harness.is_skip(err) then
      io.stdout:write(("SKIP %s (%s)\n"):format(vim.fs.basename(spec), err.reason))
      return finish({ passed = 0, failed = 0, skipped = 1 })
    end
    io.stdout:write("FAIL loading " .. spec .. "\n")
    for l in tostring(err):gmatch("[^\n]+") do
      io.stdout:write("       " .. l .. "\n")
    end
    return finish({ passed = 0, failed = 1, skipped = 0 })
  end
  finish(harness.run())
end

-- The config's own VimEnter work must be done before a test looks at it.
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.schedule(function()
      local ok, e = xpcall(main, debug.traceback)
      if not ok then
        io.stdout:write("FAIL runner: " .. tostring(e) .. "\n")
        io.stdout:flush()
        vim.cmd("cquit 2")
      end
    end)
  end,
})
