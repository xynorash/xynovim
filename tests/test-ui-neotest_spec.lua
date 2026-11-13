-- The results panel fed by a REAL neotest run (rustaceanvim adapter, `cargo test`) and a real
-- `cargo test --doc`, on tests/fixtures/failing-tests (3 failing unit tests, 1 failing doc-test).
-- cargo-nextest is not installed here: the nextest runner path is covered by the parser spec only.
local H = require("xynotest.helpers")
local T = require("config.test_ui")

local function setup()
  H.need_rust()
  -- parallel tests print into one stream under --nocapture; one thread keeps every panic block whole
  -- (the parser also copes with interleaving, tests/test-ui_spec.lua, but this spec is about the panel)
  vim.env.RUST_TEST_THREADS = "1"
  local dir = vim.uv.fs_realpath(H.tmpdir())
  vim.fn.system({ "cp", "-r", H.fixtures .. "/failing-tests/.", dir })
  vim.cmd.cd(vim.fn.fnameescape(dir))
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/src/lib.rs"))
  H.very_lazy()
  local buf = vim.api.nvim_get_current_buf()
  H.wait_lsp("rust-analyzer", buf, 120000)
  -- runnables are empty until rust-analyzer has loaded the workspace
  local status = require("xyno_rust.lsp_status")
  H.wait_for(function()
    local c = status.component()
    return c:match("^RA ready") ~= nil
  end, 120000, "rust-analyzer ready")
  return dir, buf
end

--- A run whose log came back whole. neotest reads the test process's stdout and stderr as two streams, so under
--- load a panic's `left:`/`right:` lines can arrive after the next test's header: the log is then complete but
--- misattributed (the assert diff of one test is missing, the lines sit under its neighbour). Such a log is not
--- what this spec is about, so it counts as "not back yet" and the run is repeated, like an empty result.
local function complete(parsed)
  if parsed.summary.failed < 3 then
    return false
  end
  for _, name in ipairs({ "tests::vec_mismatch", "tests::string_mismatch" }) do
    local t
    for _, x in ipairs(parsed.tests) do
      if x.name == name then
        t = x
      end
    end
    local out = t and table.concat(t.output, "\n") or ""
    if not (out:find("left:", 1, true) and out:find("right:", 1, true)) then
      return false
    end
  end
  return true
end

--- Run the file through neotest; a run started before the adapter discovered the file's positions
--- finds no tests (and says so with an empty result), so it is retried until tests come back.
local function run_file(dir)
  local nio = require("nio")
  for _ = 1, 12 do
    T.state.run = nil
    nio.run(function()
      require("neotest").run.run(dir .. "/src/lib.rs")
    end)
    local ok = pcall(H.wait_for, function()
      return T.state.run and complete(T.state.run.parsed)
    end, 20000, "the three failures to come back, whole")
    if ok then
      return
    end
  end
  error("neotest never ran the file's tests")
end

local function panel_text()
  local w = T.state.win
  if not (w and vim.api.nvim_win_is_valid(w)) then
    return nil
  end
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
end

describe("neotest run -> results panel", function()
  local dir
  it("a failing run opens the panel by itself: counts, failure summary, assert diff, wall time", function()
    dir = setup()
    run_file(dir)
    local text = H.wait_for(panel_text, 180000, "the panel to open after the run")
    H.match(text, "3 failed  1 passed", true)
    H.match(text, "(wall ", true)
    H.match(text, "FAIL tests::vec_mismatch  src/lib.rs:", true)
    H.match(text, "assert_eq!: ports differ", true)
    H.match(text, "-   3", true)
    H.match(text, "+   4", true)
    H.match(text, '- "refused"', true)
    H.match(text, "ok   tests::doubles", true)
    H.eq(3, #T.state.failed_ids)
  end)

  it("<CR> on a failure row jumps to the test; the failed ids are what `r` reruns", function()
    local w = T.state.win
    H.ok(w and vim.api.nvim_win_is_valid(w))
    vim.api.nvim_set_current_win(w)
    local row
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:match("^FAIL tests::string_mismatch") then
        row = i
      end
    end
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    T.jump()
    H.match(vim.api.nvim_buf_get_name(0), "src/lib.rs", true)
    local line = vim.api.nvim_win_get_cursor(0)[1]
    H.match(vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1], "fn string_mismatch", true)
  end)

  it("rerun failed runs the three failed tests again (a fresh panel with the same three failures)", function()
    local before = T.state.run
    T.rerun_failed()
    H.wait_for(function()
      return T.state.run ~= before and not T.state.rerunning
    end, 180000, "the rerun to finish")
    -- three single-test runs, merged into the one panel: still 3 failed + 1 passed, 3 ids to rerun
    H.eq(3, T.state.run.parsed.summary.failed)
    H.eq(1, T.state.run.parsed.summary.passed)
    H.eq(3, #T.state.failed_ids)
    H.match(panel_text(), "FAIL tests::plain_panic", true)
  end)
end)

describe("doc-tests -> results panel", function()
  it("<leader>tE: per-doctest rows, the failing one with its assert diff", function()
    local dir = setup()
    T.close()
    T.run_doctests()
    local text = H.wait_for(function()
      local t = panel_text()
      return t and t:find("Doc-tests", 1, true) and t
    end, 180000, "the doc-test panel")
    H.match(text, "1 failed  1 passed", true)
    H.match(text, "FAIL src/lib.rs - double (line 7)", true)
    H.match(text, "ok   src/lib.rs - double (line 3)", true)
    H.match(text, "- 4", true)
    H.match(text, "+ 5", true)
    _ = dir
  end)
end)
