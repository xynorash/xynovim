-- lua/config/test_ui.lua: the test results panel (parse, assert diff, render, folds, nextest profiles,
-- lcov total). Inputs are REAL `cargo test` output captured from a copy of demo/netwatch with three
-- failing tests and a failing doc-test (tests/fixtures/test-output/cargo-test.txt). The nextest sample
-- is written after the documented format (cargo-nextest is not installed on the machine that wrote
-- this): the parser is tested on it, nextest itself was never run here.
local H = require("xynotest.helpers")
local T = require("config.test_ui")

local function read(name)
  return table.concat(vim.fn.readfile(H.fixtures .. "/test-output/" .. name), "\n")
end

local function by_name(p, name)
  for _, t in ipairs(p.tests) do
    if t.name == name then
      return t
    end
  end
end

describe("parse: cargo test", function()
  local p = T.parse(read("cargo-test.txt"))

  it("reads every test with its status, across the lib, integration and doc-test binaries", function()
    H.eq("libtest", p.format)
    H.eq("passed", by_name(p, "tests::parses_lists_and_ranges").status)
    H.eq("failed", by_name(p, "more::vec_mismatch").status)
    H.eq("failed", by_name(p, "src/lib.rs - double (line 140)").status)
    H.eq("passed", by_name(p, "src/lib.rs - double (line 136)").status)
    H.eq("passed", by_name(p, "reports_each_port").status)
  end)

  it("sums the `test result:` lines of all binaries", function()
    -- lib 3 passed / 3 failed, cli 2 passed, doc-tests 1 passed / 1 failed
    H.eq(6, p.summary.passed)
    H.eq(4, p.summary.failed)
    H.eq(10, p.summary.total)
  end)

  it("attaches each failed test's own output (stdout before the panic included)", function()
    local t = by_name(p, "more::vec_mismatch")
    H.eq("probing before the check", t.output[1])
    local pn = T.panic_of(t.output)
    H.eq("src/lib.rs", pn.file)
    H.eq(154, pn.line)
    H.match(pn.message, "left == right", true)
  end)
end)

describe("parse: nextest", function()
  local p = T.parse(read("nextest.txt"))
  it("status lines carry the time; the output below a FAIL line belongs to that test only", function()
    H.eq("nextest", p.format)
    H.eq(3, #p.tests)
    local f = by_name(p, "more::vec_mismatch")
    H.eq("failed", f.status)
    H.eq(0.006, f.time)
    H.eq("netwatch", f.crate)
    H.eq("passed", by_name(p, "tests::rejects_bad_input").status)
    H.eq({}, by_name(p, "tests::rejects_bad_input").output)
    H.ok(vim.tbl_contains(f.output, "[stderr]"), "stream headers are kept as [stderr]")
    H.eq(0.032, p.summary.time)
    H.eq(1, p.summary.failed)
  end)
  it("the end-of-run recap line does not duplicate or wipe the test", function()
    local n = 0
    for _, t in ipairs(p.tests) do
      if t.name == "more::vec_mismatch" then
        n = n + 1
      end
    end
    H.eq(1, n)
    H.ok(#by_name(p, "more::vec_mismatch").output > 3)
  end)
  it("assert_eq! output is found in nextest's indented stderr too", function()
    H.ok(T.assert_diff(by_name(p, "more::vec_mismatch").output), "diff")
  end)
end)

describe("assert_eq! diff", function()
  local p = T.parse(read("cargo-test.txt"))

  it("a Vec is compared element by element: only the differing element is marked", function()
    local d = T.assert_diff(by_name(p, "more::vec_mismatch").output)
    H.eq("eq", d.kind)
    H.eq("ports differ", d.message)
    local signs = vim.tbl_map(function(x)
      return x.sign .. x.text:gsub("^%s+", "")
    end, d.diff)
    H.eq({ "-3", "+4" }, vim.tbl_filter(function(s)
      return s:sub(1, 1) ~= " "
    end, signs))
    H.ok(#d.diff > 3, "unchanged elements are kept as context")
  end)

  it("two strings: both lines with the differing span", function()
    local d = T.assert_diff(by_name(p, "more::string_mismatch").output)
    H.eq(2, #d.diff)
    H.eq('"connection refused"', d.diff[1].text)
    local l, r = d.diff[1], d.diff[2]
    H.eq("refused", l.text:sub(l.span[1] + 1, l.span[2]))
    H.eq("reset", r.text:sub(r.span[1] + 1, r.span[2]))
  end)

  it("a doc-test failure has one too; a plain panic and a pass have none", function()
    H.ok(T.assert_diff(by_name(p, "src/lib.rs - double (line 140)").output))
    H.is_nil(T.assert_diff(by_name(p, "more::plain_panic").output))
  end)

  it("nested structs break into one token per line and diff structurally", function()
    local out = {
      "assertion `left == right` failed",
      '  left: Cfg { name: "a", ports: [1, 2], on: true }',
      ' right: Cfg { name: "a", ports: [1, 3], on: true }',
    }
    local d = T.assert_diff(out)
    local changed = vim.tbl_filter(function(x)
      return x.sign ~= " "
    end, d.diff)
    H.eq({ "-", "+" }, { changed[1].sign, changed[2].sign })
    H.eq("2", vim.trim(changed[1].text))
    H.eq("3", vim.trim(changed[2].text))
  end)

  it("assert_ne! is recognised", function()
    local d = T.assert_diff({ "assertion `left != right` failed", "  left: 1", " right: 1" })
    H.eq("ne", d.kind)
  end)

  it("commas and brackets inside quoted strings do not split", function()
    H.eq({ '"a, b [c]"' }, T.pretty('"a, b [c]"'))
  end)
end)

describe("render", function()
  local p = T.parse(read("cargo-test.txt"))
  local r = T.render({ parsed = p, wall = 2.5, profile = "ci", coverage = { pct = 87.25, found = 80 } })
  local text = table.concat(r.lines, "\n")

  it("header: counts, time, profile, coverage; failure summary lists each failed test with file:line", function()
    H.match(r.lines[1], "4 failed  6 passed", true)
    H.match(r.lines[1], "nextest profile ci", true)
    H.match(r.lines[1], "coverage 87.2%", true)
    H.match(text, "FAIL more::vec_mismatch  src/lib.rs:154  assert_eq!: ports differ", true)
    H.match(text, "FAIL more::plain_panic  src/lib.rs:165  index out of bounds", true)
  end)

  it("failed tests come first, passed ones after, each failed one has an open fold with its output", function()
    local first_fail, first_ok
    for i, l in ipairs(r.lines) do
      if l:match("^FAIL ") then first_fail = first_fail or i end
      if l:match("^ok   ") then first_ok = first_ok or i end
    end
    H.ok(first_fail < first_ok)
    local open = 0
    for _, f in ipairs(r.folds) do
      if f.open then open = open + 1 end
    end
    H.eq(4, open)
  end)

  it("the diff block uses DiffDelete / DiffAdd", function()
    local groups = {}
    for _, h in ipairs(r.hl) do groups[h[4]] = true end
    H.ok(groups.DiffDelete and groups.DiffAdd and groups.DiffText)
  end)
end)

describe("panel window (real grid)", function()
  after_each(function()
    T.close()
  end)
  it("opens a bottom split with the failures expanded and passed output folded", function()
    local p = T.parse(read("cargo-test.txt"))
    T.show({ parsed = p, wall = 1 }, { enter = true })
    local w = T.state.win
    H.ok(vim.api.nvim_win_is_valid(w))
    local b = vim.api.nvim_win_get_buf(w)
    local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    local row
    for i, l in ipairs(lines) do
      if l:match("^FAIL more::vec_mismatch") then row = i end
    end
    H.ok(row)
    -- the fold under the failed test is open: its first output line is visible
    vim.api.nvim_win_call(w, function()
      H.eq(-1, vim.fn.foldclosed(row + 1) , "fold under a failed test is open")
    end)
    -- an `ok` row has no output
    H.eq(false, vim.bo[b].modifiable)
  end)

  it("a fold with output of a passing test (--success-output) starts closed", function()
    local p = T.parse("test a ... ok\n\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s\n")
    p.tests[1].output = { "hello", "world" }
    T.show({ parsed = p }, { enter = true })
    local w = T.state.win
    local b = vim.api.nvim_win_get_buf(w)
    local row
    for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      if l:match("^ok   a") then row = i end
    end
    vim.api.nvim_win_call(w, function()
      H.ok(vim.fn.foldclosed(row + 1) ~= -1, "closed")
    end)
  end)
end)

describe("nextest profiles, lcov total", function()
  it("lists the profiles of .config/nextest.toml, default first", function()
    local dir = H.tmpdir()
    vim.fn.mkdir(dir .. "/.config", "p")
    vim.fn.writefile({ "[profile.ci]", "retries = 2", "[profile.\"slow-net\"]", "[profile.default]" }, dir .. "/.config/nextest.toml")
    H.eq({ "default", "ci", "slow-net" }, T.profiles(dir))
    H.eq({ "default" }, T.profiles(H.tmpdir()))
  end)

  it("lcov: totals and the weakest file first", function()
    local f = H.tmpdir() .. "/lcov.info"
    vim.fn.writefile({ "SF:/a.rs", "LF:10", "LH:10", "end_of_record", "SF:/b.rs", "LF:10", "LH:5", "end_of_record" }, f)
    local s = T.lcov_summary(f)
    H.eq(75, s.pct)
    H.eq("/b.rs", s.files[1].path)
    H.is_nil(T.lcov_summary("/nonexistent"))
  end)
end)

describe("parse: --nocapture output (what neotest's rustaceanvim adapter captures: ANSI, OSC, CR, no per-test sections)", function()
  local p = T.parse(read("neotest-nocapture.txt"))
  it("panic blocks are attributed to the test named by the thread", function()
    H.eq("libtest", p.format)
    H.eq(4, #p.tests)
    local v = by_name(p, "tests::vec_mismatch")
    H.eq("failed", v.status)
    H.match(table.concat(v.output, "\n"), "left: [1, 2, 3]", true)
    local d = T.assert_diff(v.output)
    H.eq("ports differ", d.message)
    H.eq("passed", by_name(p, "tests::doubles").status)
    H.eq("failed", by_name(p, "tests::plain_panic").status, "status word glued to the test's own print")
    H.eq(3, p.summary.failed)
    H.eq(1, p.summary.passed)
  end)
  it("no escape sequence survives into the output lines", function()
    for _, t in ipairs(p.tests) do
      for _, l in ipairs(t.output) do
        H.no_match(l, "\27", true)
        H.no_match(l, "\r", true)
      end
    end
  end)
end)

describe("doc-test failures point at the doc comment, not the generated file", function()
  it("src/lib.rs - double (line 140) -> src/lib.rs:140", function()
    local p = T.parse(read("cargo-test.txt"))
    local r = T.render({ parsed = p })
    H.match(table.concat(r.lines, "\n"), "FAIL src/lib.rs - double (line 140)  src/lib.rs:140", true)
  end)
end)

describe("lcov total from a real cargo-llvm-cov report", function()
  it("tests/fixtures/test-output/lcov.info (failing-tests, one failing run): lines found / hit and the percentage", function()
    local s = T.lcov_summary(H.fixtures .. "/test-output/lcov.info")
    H.eq(1, #s.files)
    H.eq("/work/failing-tests/src/lib.rs", s.files[1].path)
    H.ok(s.found > 0 and s.hit > 0 and s.hit < s.found, vim.inspect({ s.found, s.hit }))
    H.eq(s.hit / s.found * 100, s.pct)
  end)
end)
