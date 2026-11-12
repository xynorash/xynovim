-- Test results panel (<leader>tp) on top of neotest, nextest and `cargo test --doc`:
--   * one buffer for a whole run: header with counts / wall time / nextest profile / coverage,
--     a failure summary (message + file:line per failed test), then one fold per test holding its
--     output (failed tests open, passed ones closed; `za` toggles, `zM` / `zR` all),
--   * assert_eq! / assert_ne! failures rendered as a structural diff of left and right,
--   * rerun failed (`r`), jump to the test (`<CR>`), raw log (`o`),
--   * nextest profile picker (<leader>tP), doc-tests (<leader>tD) and the coverage total.
-- parse / assert_diff / render are pure (text in, lines out) and are what tests/test-ui_spec.lua covers.
local M = {}

local ns = vim.api.nvim_create_namespace("xyno_test_ui")

--- Escape sequences out (CSI colours / erase, OSC titles and progress `ESC ] 9 ; 4 ; ... ST` that cargo
--- emits into a pty), then what a terminal would show of a line with carriage returns: the text after the last one.
local function strip_ansi(s)
  s = s:gsub("\27%].-\27\\", ""):gsub("\27%].-\7", "")
  s = s:gsub("\27%[[%d;?]*[A-Za-z]", "")
  return s
end

local function lines_of(text)
  local out = {}
  for l in (strip_ansi(text) .. "\n"):gmatch("(.-)\n") do
    local last = l:match("([^\r]*)\r*$")
    out[#out + 1] = (last ~= "" and last) or l:gsub("\r", "")
  end
  return out
end

-- ------------------------------------------------------------------ parsing

local NEXTEST_STATUS = {
  PASS = "passed",
  FLAKY = "passed",
  LEAK = "passed",
  FAIL = "failed",
  SIGABRT = "failed",
  SIGSEGV = "failed",
  TIMEOUT = "failed",
  EXECFAIL = "failed",
  SKIP = "ignored",
}

--- Trim leading and trailing blank lines.
local function trim_blank(t)
  while #t > 0 and t[#t]:match("^%s*$") do
    t[#t] = nil
  end
  while #t > 0 and t[1]:match("^%s*$") do
    table.remove(t, 1)
  end
  return t
end

--- Parse cargo test (libtest) or cargo nextest output.
---@return { format: string, tests: table[], summary: table }
function M.parse(text)
  local lines = lines_of(text or "")
  local res = { format = "unknown", tests = {}, summary = { passed = 0, failed = 0, ignored = 0, time = nil } }
  local by_name = {}
  local function test(name, crate)
    local key = (crate or "") .. "\0" .. name
    if not by_name[key] then
      by_name[key] = { name = name, crate = crate, status = "passed", output = {} }
      res.tests[#res.tests + 1] = by_name[key]
    end
    return by_name[key]
  end

  local i = 1
  local cur, cur_kind -- the test whose output block is being read
  local libtest_time = 0
  local saw_result_line = false
  while i <= #lines do
    local l = lines[i]
    -- nextest: `        PASS [   0.004s] netwatch tests::foo`
    local st, secs, rest = l:match("^%s*(%u+)%s+%[%s*([%d.]+)s%]%s+(.+)$")
    if st and NEXTEST_STATUS[st] then
      res.format = "nextest"
      local crate, name = rest:match("^(%S+)%s+(.+)$")
      name = (name or rest):gsub("%s+%(retry.*$", "")
      local t = test(name, crate)
      t.status = NEXTEST_STATUS[st]
      t.time = tonumber(secs)
      t.raw_status = st
      -- nextest prints a test's captured output right below its status line (failures; passes with
      -- --success-output); the end-of-run recap repeats the status line, keep the first output only
      cur = #t.output == 0 and t or nil
      cur_kind = "nextest"
    elseif l:match("^%-%-%- STD%u+:") and res.format ~= "libtest" then
      local crate, name = l:match("^%-%-%- STD%u+:%s+(%S+)%s+(.-)%s*%-%-%-$")
      if name then
        cur = test(name, crate)
        cur_kind = "nextest"
      end
    elseif l:match("^%s*Summary%s+%[") then
      res.format = "nextest"
      local secs2, rest2 = l:match("Summary%s+%[%s*([%d.]+)s%]%s+(.*)$")
      res.summary.time = tonumber(secs2)
      res.summary.total = tonumber(rest2:match("(%d+) tests? run"))
      res.summary.passed = tonumber(rest2:match("(%d+) passed")) or 0
      res.summary.failed = tonumber(rest2:match("(%d+) failed")) or 0
      res.summary.ignored = tonumber(rest2:match("(%d+) skipped")) or 0
      cur = nil
    elseif l:match("^test .+ %.%.%.%s*.*$") and res.format ~= "nextest" then
      -- libtest: `test tests::foo ... ok`, `... FAILED`, `... ignored, reason`, optional ` <0.002s>`
      res.format = "libtest"
      local name, status = l:match("^test (.-) %.%.%.%s*(.*)$")
      local secs3 = status:match("<([%d.]+)s>")
      -- with --nocapture a test's own prints are glued to the status word ("FAILEDprobing ...")
      local word = status:match("^(FAILED)")
        or status:match("^(ok)")
        or status:match("^(ignored)")
        or status:match("^(%a+)")
      local t = test(name)
      -- no status word: a parallel test printed between "test x ... " and its "ok"; it did not fail
      -- (a failure prints FAILED on that line), so it keeps what it had
      if word then
        t.status = word == "ok" and "passed"
          or (word == "ignored" and "ignored" or (word == "FAILED" and "failed" or "passed"))
      end
      t.time = tonumber(secs3)
      cur = nil
    elseif l:match("^---- .- stdout ----$") then
      local name = l:match("^%-%-%-%- (.-) stdout %-%-%-%-$")
      cur = test(name)
      cur.output = {}
      cur.status = "failed"
      cur_kind = "libtest"
    elseif l:match("^test result: ") then
      res.format = res.format == "unknown" and "libtest" or res.format
      saw_result_line = true
      local p = tonumber(l:match("(%d+) passed")) or 0
      local f = tonumber(l:match("(%d+) failed")) or 0
      local ig = tonumber(l:match("(%d+) ignored")) or 0
      res.summary.passed = (res.summary.passed or 0) + p
      res.summary.failed = (res.summary.failed or 0) + f
      res.summary.ignored = (res.summary.ignored or 0) + ig
      libtest_time = libtest_time + (tonumber(l:match("finished in ([%d.]+)s")) or 0)
      cur = nil
    elseif cur and cur_kind == "libtest" and (l == "failures:" or l:match("^running %d+ test")) then
      cur = nil
    elseif cur then
      if
        cur_kind == "nextest"
        and (
          l:match("^[\226\148\128]+%s*$")
          or l:match("^%-%-%-%-+%s*$")
          or (l:match("^%s*%u+%s+%[") and NEXTEST_STATUS[l:match("^%s*(%u+)")])
        )
      then
        cur = nil
      else
        local body = l
        if cur_kind == "nextest" then
          local hdr = l:match("^%s*(std%a+) \226\148\128")
          body = hdr and ("[" .. hdr .. "]") or l:gsub("^    ", "")
        end
        cur.output[#cur.output + 1] = body
      end
    end
    i = i + 1
  end
  -- --nocapture (neotest's rustaceanvim adapter): no per-test sections, the panic text is printed in the
  -- stream under the thread's name, which is the test's path; status lines of other tests can sit inside
  -- such a block (parallel tests), they are skipped
  for idx, l in ipairs(lines) do
    local name = l:match("^thread '(.-)'.-panicked at ")
    local t = name and by_name["\0" .. name]
    if t and #t.output == 0 then
      t.output[1] = l
      t.status = "failed"
      local n = 0
      for k = idx + 1, math.min(idx + 12, #lines) do
        local x = lines[k]
        -- parallel tests can print a blank line right after the header: a block is not over before it has a message
        if x:match("^thread '") or (x == "" and #t.output >= 2) then
          break
        end
        if x ~= "" and not x:match("^test .+ %.%.%. ") then
          t.output[#t.output + 1] = x
        end
        n = n + 1
      end
    end
  end
  for _, t in ipairs(res.tests) do
    trim_blank(t.output)
  end
  if saw_result_line then
    res.summary.time = libtest_time
  end
  -- counts from the tests when the summary line was missing (a killed run)
  if not res.summary.total then
    local c = { passed = 0, failed = 0, ignored = 0 }
    for _, t in ipairs(res.tests) do
      c[t.status] = c[t.status] + 1
    end
    if saw_result_line then
      res.summary.total = res.summary.passed + res.summary.failed + res.summary.ignored
    else
      res.summary.passed, res.summary.failed, res.summary.ignored = c.passed, c.failed, c.ignored
      res.summary.total = #res.tests
    end
  end
  return res
end

--- `thread 'x' panicked at src/lib.rs:12:5:` + message of a failed test's output:
--- { file, line, message } or nil.
function M.panic_of(output)
  for idx, l in ipairs(output) do
    local file, ln = l:match("panicked at ([^:]+):(%d+):%d+")
    if file then
      local msg = output[idx + 1] or ""
      if msg:match("^note: run with") then
        msg = ""
      end
      return { file = file, line = tonumber(ln), message = msg }
    end
  end
end

-- ------------------------------------------------------------------ assert diff

--- Break a Debug-printed value into one token per line, indented by nesting: `Foo { a: 1, b: [1, 2] }`
--- becomes lines a structural line diff can work on. Quoted strings are kept whole.
function M.pretty(text)
  local out, cur, depth, i, n = {}, "", 0, 1, #text
  local function flush()
    if cur:match("%S") then
      out[#out + 1] = string.rep("  ", depth) .. vim.trim(cur)
    end
    cur = ""
  end
  while i <= n do
    local c = text:sub(i, i)
    if c == '"' then
      local j = i + 1
      while j <= n do
        local d = text:sub(j, j)
        if d == "\\" then
          j = j + 1
        elseif d == '"' then
          break
        end
        j = j + 1
      end
      cur = cur .. text:sub(i, j)
      i = j
    elseif c == "{" or c == "[" or c == "(" then
      cur = cur .. c
      flush()
      depth = depth + 1
    elseif c == "}" or c == "]" or c == ")" then
      flush()
      depth = math.max(0, depth - 1)
      cur = c
      -- keep a trailing comma with its bracket
      if text:sub(i + 1, i + 1) == "," then
        cur = cur .. ","
        i = i + 1
      end
      flush()
    elseif c == "," then
      cur = cur .. c
      flush()
      if text:sub(i + 1, i + 1) == " " then
        i = i + 1
      end
    else
      cur = cur .. c
    end
    i = i + 1
  end
  flush()
  return out
end

--- Common prefix and suffix trimmed from a pair: returns the (start, end) byte ranges that differ.
local function changed_span(a, b)
  local p = 0
  local m = math.min(#a, #b)
  while p < m and a:byte(p + 1) == b:byte(p + 1) do
    p = p + 1
  end
  -- start the span at the beginning of the word ("re|fused" -> "refused")
  while p > 0 and a:sub(p, p):match("[%w_]") do
    p = p - 1
  end
  local s = 0
  while s < m - p and a:byte(#a - s) == b:byte(#b - s) do
    s = s + 1
  end
  return { p, #a - s }, { p, #b - s }
end

--- Find an assert_eq! / assert_ne! failure in a test's output.
---@return { kind: string, message: string?, left: string, right: string, diff: table[] }|nil
function M.assert_diff(output)
  for idx, l in ipairs(output) do
    local op = l:match("assertion `left ([=!]=) right` failed")
    op = op and op:sub(1, 1)
    if op then
      local message = l:match("assertion `left [=!]= right` failed: (.+)$")
      local left, right
      for k = idx + 1, math.min(idx + 6, #output) do
        left = left or output[k]:match("^%s*left: (.*)$")
        right = right or output[k]:match("^%s*right: (.*)$")
      end
      if left and right then
        local a, b = M.pretty(left), M.pretty(right)
        local diff = {}
        if #a == 1 and #b == 1 then
          -- scalars / one string: show the differing span
          local sa, sb = changed_span(a[1], b[1])
          diff[#diff + 1] = { sign = "-", text = vim.trim(a[1]), span = { sa[1], sa[2] } }
          diff[#diff + 1] = { sign = "+", text = vim.trim(b[1]), span = { sb[1], sb[2] } }
        else
          local hunks = vim.diff(
            table.concat(a, "\n") .. "\n",
            table.concat(b, "\n") .. "\n",
            { result_type = "indices", algorithm = "myers" }
          )
          local ia, ib = 1, 1
          local function same(upto_a, upto_b)
            while ia <= upto_a and ib <= upto_b do
              diff[#diff + 1] = { sign = " ", text = a[ia] }
              ia, ib = ia + 1, ib + 1
            end
          end
          for _, h in ipairs(hunks) do
            local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
            -- vim.diff reports the line before an insertion/deletion when the count is 0
            local a_from = ca == 0 and sa + 1 or sa
            local b_from = cb == 0 and sb + 1 or sb
            same(a_from - 1, b_from - 1)
            for _ = 1, ca do
              diff[#diff + 1] = { sign = "-", text = a[ia] }
              ia = ia + 1
            end
            for _ = 1, cb do
              diff[#diff + 1] = { sign = "+", text = b[ib] }
              ib = ib + 1
            end
          end
          same(#a, #b)
        end
        return { kind = op == "=" and "eq" or "ne", message = message, left = left, right = right, diff = diff }
      end
    end
  end
end

-- ------------------------------------------------------------------ rendering

local function secs(t)
  return t and (t < 10 and ("%.3fs"):format(t) or ("%.1fs"):format(t)) or ""
end

local LABEL = { passed = "ok  ", failed = "FAIL", ignored = "skip" }

--- Build the panel text from a run.
---@param run { parsed: table, wall: number?, profile: string?, coverage: table?, ids: table?, title: string? }
---@return { lines: string[], hl: table[], folds: table[], entries: table<integer, table> }
function M.render(run)
  local p = run.parsed
  local lines, hl, folds, entries = {}, {}, {}, {}
  local function add(text, group, entry)
    lines[#lines + 1] = text
    if group then
      hl[#hl + 1] = { #lines - 1, 0, -1, group }
    end
    if entry then
      entries[#lines] = entry
    end
    return #lines
  end
  local s = p.summary
  local head = ("%s  %d failed  %d passed  %d skipped"):format(
    run.title or "Tests",
    s.failed or 0,
    s.passed or 0,
    s.ignored or 0
  )
  local bits = {}
  if s.time or run.wall then
    bits[#bits + 1] = secs(s.time or run.wall) .. (s.time and run.wall and (" (wall " .. secs(run.wall) .. ")") or "")
  end
  if run.profile then
    bits[#bits + 1] = "nextest profile " .. run.profile
  end
  if run.coverage then
    bits[#bits + 1] = ("coverage %.1f%% of %d lines"):format(run.coverage.pct, run.coverage.found)
  end
  add(
    head .. (#bits > 0 and ("   " .. table.concat(bits, "   ")) or ""),
    (s.failed or 0) > 0 and "DiagnosticError" or "DiagnosticOk"
  )
  add("<CR> jump   za fold   zM/zR all   r rerun failed   o raw log   q close", "Comment")
  add("")

  local failed = vim.tbl_filter(function(t)
    return t.status == "failed"
  end, p.tests)
  if #failed > 0 then
    add("Failures", "Title")
    table.sort(failed, function(a, b)
      return a.name < b.name
    end)
    for _, t in ipairs(failed) do
      local pn = M.panic_of(t.output)
      -- a doc-test's panic line is relative to the generated test file; its name carries the real line
      local dfile, dline = t.name:match("^(.-) %- .-%(line (%d+)%)$")
      if dfile then
        pn = pn or { message = "" }
        pn.file, pn.line = dfile, tonumber(dline)
      end
      local ad = M.assert_diff(t.output)
      local why = ad and ("assert_" .. ad.kind .. "!" .. (ad.message and (": " .. ad.message) or ""))
        or (pn and vim.trim(pn.message) ~= "" and vim.trim(pn.message))
        or (t.output[1] and vim.trim(t.output[1]))
        or ""
      add(
        ("  FAIL %s%s  %s"):format(t.name, pn and ("  " .. pn.file .. ":" .. pn.line) or "", why),
        "DiagnosticError",
        { test = t, file = pn and pn.file, line = pn and pn.line }
      )
    end
    add("")
  end

  add("Tests", "Title")
  local order = { failed = 1, passed = 2, ignored = 3 }
  local sorted = vim.deepcopy(p.tests)
  table.sort(sorted, function(a, b)
    if a.status ~= b.status then
      return order[a.status] < order[b.status]
    end
    return false
  end)
  for _, t in ipairs(sorted) do
    local ref = run.ids and run.ids[t.name]
    local row = add(
      ("%s %s%s%s"):format(
        LABEL[t.status],
        t.name,
        t.crate and ("  [" .. t.crate .. "]") or "",
        t.time and ("  " .. secs(t.time)) or ""
      ),
      t.status == "failed" and "DiagnosticError" or (t.status == "ignored" and "Comment" or nil),
      { test = t, id = ref }
    )
    if t.status == "passed" and #t.output == 0 then
      -- nothing to fold
    else
      local first = row
      local ad = t.status == "failed" and M.assert_diff(t.output)
      if ad then
        add(
          ("  assert_%s! failed%s"):format(ad.kind, ad.message and (": " .. ad.message) or ""),
          "Special",
          { test = t }
        )
        for _, d in ipairs(ad.diff) do
          local r = add(
            ("  %s %s"):format(d.sign, d.text),
            d.sign == "-" and "DiffDelete" or (d.sign == "+" and "DiffAdd" or "Comment"),
            { test = t }
          )
          if d.span then
            -- the changed span within the line (2 columns of "  X " prefix)
            hl[#hl + 1] = { r - 1, 4 + d.span[1], 4 + d.span[2], "DiffText" }
          end
        end
        add("")
      end
      for _, o in ipairs(t.output) do
        add("    " .. o, "Comment", { test = t })
      end
      if t.status == "failed" or #t.output > 0 then
        folds[#folds + 1] = { first + 1, #lines, open = t.status == "failed" }
      end
    end
  end
  if #p.tests == 0 then
    add("no test results in the output", "Comment")
  end
  return { lines = lines, hl = hl, folds = folds, entries = entries }
end

-- ------------------------------------------------------------------ the panel

M.state = { run = nil, log = nil, failed_ids = {}, coverage = nil, win = nil, buf = nil }

function M.foldtext()
  local first = vim.fn.getline(vim.v.foldstart)
  return ("    ... %d lines of output"):format(vim.v.foldend - vim.v.foldstart + 1)
    .. (first:match("panicked") and "  (panic)" or "")
end

local function panel_buf()
  local b = M.state.buf
  if b and vim.api.nvim_buf_is_valid(b) then
    return b
  end
  b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].swapfile = false
  vim.bo[b].filetype = "xynotests"
  pcall(vim.api.nvim_buf_set_name, b, "xyno://tests")
  M.state.buf = b
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = b, nowait = true, desc = desc })
  end
  map("q", function()
    M.close()
  end, "Close test panel")
  map("<CR>", function()
    M.jump()
  end, "Jump to test")
  map("r", function()
    M.rerun_failed()
  end, "Rerun failed tests")
  map("o", function()
    M.open_log()
  end, "Open raw log")
  return b
end

--- Show a run in the panel and open it (focus stays where it was unless enter).
function M.show(run, opts)
  opts = opts or {}
  M.state.run = run
  local b = panel_buf()
  local r = M.render(run)
  M.state.rendered = r
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, r.lines)
  vim.bo[b].modifiable = false
  vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
  for _, h in ipairs(r.hl) do
    pcall(
      vim.api.nvim_buf_set_extmark,
      b,
      ns,
      h[1],
      h[2],
      h[3] == -1 and { line_hl_group = h[4] } or { end_col = h[3], hl_group = h[4] }
    )
  end
  local win = M.state.win
  if not (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == b) then
    local cur = vim.api.nvim_get_current_win()
    vim.cmd("botright 16split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, b)
    M.state.win = win
    if not opts.enter then
      vim.api.nvim_set_current_win(cur)
    end
  elseif opts.enter then
    vim.api.nvim_set_current_win(win)
  end
  vim.wo[win].wrap = true
  vim.wo[win].foldmethod = "manual"
  vim.wo[win].foldtext = "v:lua.require'config.test_ui'.foldtext()"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.api.nvim_win_call(win, function()
    vim.cmd("silent! normal! zE")
    for _, f in ipairs(r.folds) do
      if f[2] >= f[1] then
        vim.cmd(("silent! %d,%dfold"):format(f[1], f[2]))
        if f.open then
          vim.cmd(("silent! %dfoldopen"):format(f[1]))
        end
      end
    end
    vim.cmd("silent! normal! gg")
  end)
  return r
end

function M.close()
  local w = M.state.win
  if w and vim.api.nvim_win_is_valid(w) then
    pcall(vim.api.nvim_win_close, w, true)
  end
  M.state.win = nil
end

function M.toggle()
  local w = M.state.win
  if w and vim.api.nvim_win_is_valid(w) then
    return M.close()
  end
  if not M.state.run then
    return vim.notify("no test run yet (<leader>tr, <leader>tt, <leader>tD)", vim.log.levels.INFO, { title = "tests" })
  end
  M.show(M.state.run, { enter = true })
end

function M.jump()
  local r = M.state.rendered
  if not r then
    return
  end
  local e = r.entries[vim.api.nvim_win_get_cursor(0)[1]]
  if not e then
    return
  end
  local file, line = e.file, e.line
  if e.id and M.state.positions and M.state.positions[e.id] then
    file, line = M.state.positions[e.id].path, M.state.positions[e.id].line
  end
  if not file then
    return vim.notify("no source location for this entry", vim.log.levels.INFO, { title = "tests" })
  end
  local root = require("xyno_rust.rust_context").root() or vim.uv.cwd()
  if not vim.uv.fs_stat(file) and vim.uv.fs_stat(root .. "/" .. file) then
    file = root .. "/" .. file
  end
  local target
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= M.state.win and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "" then
      target = w
      break
    end
  end
  if target then
    vim.api.nvim_set_current_win(target)
  end
  vim.cmd.edit(vim.fn.fnameescape(file))
  pcall(vim.api.nvim_win_set_cursor, 0, { line or 1, 0 })
end

function M.open_log()
  local log = M.state.log
  if not log or not vim.uv.fs_stat(log) then
    return vim.notify("no raw log for this run", vim.log.levels.INFO, { title = "tests" })
  end
  vim.cmd("botright split " .. vim.fn.fnameescape(log))
end

-- ------------------------------------------------------------------ neotest + doctests

--- Failed neotest position ids of the last run (set by the neotest consumer).
function M.rerun_failed()
  local ids = M.state.failed_ids
  if not ids or #ids == 0 then
    return vim.notify("no failed tests to rerun", vim.log.levels.INFO, { title = "tests" })
  end
  local ok, nio = pcall(require, "nio")
  if not ok then
    return
  end
  M.state.rerunning = true
  nio.run(function()
    for _, id in ipairs(ids) do
      require("neotest").run.run(id)
    end
    M.state.rerunning = false
  end)
end

--- neotest consumer: build the panel when a run finishes.
function M.consumer(client)
  local started
  client.listeners.run = function()
    started = started or vim.uv.hrtime()
    return {}
  end
  client.listeners.results = function(adapter_id, results, partial)
    if partial then
      return {}
    end
    local wall = started and (vim.uv.hrtime() - started) / 1e9
    started = nil
    local failed_ids, ids, positions, log = {}, {}, {}, nil
    local texts = {}
    for id, result in pairs(results) do
      local pos0 = result.status == "failed" and client:get_position(id, { adapter = adapter_id })
      if pos0 and pos0:data().type == "test" then
        failed_ids[#failed_ids + 1] = id
      end
      if result.output and not texts[result.output] then
        local f = io.open(result.output, "rb")
        if f then
          texts[result.output] = f:read("*a")
          f:close()
          log = log or result.output
        end
      end
      local pos = client:get_position(id, { adapter = adapter_id })
      if pos then
        local d = pos:data()
        if d.type == "test" then
          -- libtest names are module paths: match the id's tail
          local name = id:match("::(.+)$")
          if name then
            ids[name] = id
            positions[id] = { path = d.path, line = d.range and d.range[1] + 1 or 1 }
          end
        end
      end
    end
    table.sort(failed_ids)
    local all = {}
    for _, tx in pairs(texts) do
      all[#all + 1] = tx
    end
    local parsed = M.parse(table.concat(all, "\n"))
    vim.schedule(function()
      local prev = M.state.run
      if M.state.rerunning and prev then
        -- a rerun of failed tests: the tests it ran replace their old rows, the rest of the run stays
        local by = {}
        for idx, tt in ipairs(prev.parsed.tests) do
          by[tt.name] = idx
        end
        for _, tt in ipairs(parsed.tests) do
          if by[tt.name] then
            prev.parsed.tests[by[tt.name]] = tt
          else
            prev.parsed.tests[#prev.parsed.tests + 1] = tt
          end
        end
        local c = { passed = 0, failed = 0, ignored = 0 }
        for _, tt in ipairs(prev.parsed.tests) do
          c[tt.status] = c[tt.status] + 1
        end
        prev.parsed.summary =
          vim.tbl_extend("force", prev.parsed.summary, c, { total = #prev.parsed.tests, time = nil })
        prev.ids = vim.tbl_extend("force", prev.ids or {}, ids)
        positions = vim.tbl_extend("force", M.state.positions or {}, positions)
        failed_ids = {}
        for _, tt in ipairs(prev.parsed.tests) do
          if tt.status == "failed" and prev.ids[tt.name] then
            failed_ids[#failed_ids + 1] = prev.ids[tt.name]
          end
        end
        table.sort(failed_ids)
        parsed, ids = prev.parsed, prev.ids
      end
      M.state.failed_ids = failed_ids
      M.state.positions = positions
      M.state.log = log
      local run = {
        parsed = parsed,
        wall = wall,
        profile = parsed.format == "nextest" and M.profile() or nil,
        coverage = M.state.coverage,
        ids = ids,
      }
      local s = parsed.summary
      if (s.failed or 0) > 0 or (M.state.win and vim.api.nvim_win_is_valid(M.state.win)) then
        M.show(run, {})
      else
        -- a green run does not take screen space; <leader>tp shows it
        M.state.run = run
        vim.notify(
          ("tests: %d passed%s%s"):format(
            s.passed or 0,
            s.ignored and s.ignored > 0 and (", " .. s.ignored .. " skipped") or "",
            wall and (" in " .. secs(wall)) or ""
          ),
          vim.log.levels.INFO,
          { title = "tests" }
        )
      end
    end)
    return {}
  end
end

--- `cargo test --doc` in the workspace, shown in the panel.
function M.run_doctests()
  local rc = require("xyno_rust.rust_context")
  local root = rc.root()
  if not root then
    return vim.notify("no Cargo.toml found", vim.log.levels.WARN, { title = "tests" })
  end
  local cmd = { "cargo", "test", "--doc", "--workspace" }
  vim.list_extend(cmd, rc.cargo_flags(rc.get(root)))
  local t0 = vim.uv.hrtime()
  local tmp = vim.fn.tempname()
  -- doctests compile and run the workspace's code (build.rs, proc macros, the examples): workspace trust first
  require("config.workspace_trust").system(cmd, {
    cwd = root,
    text = true,
    on_start = function()
      vim.notify("doc-tests: " .. table.concat(cmd, " "), vim.log.levels.INFO, { title = "tests" })
    end,
  }, function(o)
    vim.schedule(function()
      if o.denied then
        return
      end
      local text = (o.stdout or "") .. "\n" .. (o.stderr or "")
      vim.fn.writefile(vim.split(text, "\n", { plain = true }), tmp)
      local parsed = M.parse(text)
      if #parsed.tests == 0 and o.code ~= 0 then
        return vim.notify("doc-tests did not run:\n" .. text:sub(-600), vim.log.levels.ERROR, { title = "tests" })
      end
      M.state.failed_ids = {}
      M.state.log = tmp
      M.show(
        { parsed = parsed, wall = (vim.uv.hrtime() - t0) / 1e9, title = "Doc-tests", coverage = nil, ids = {} },
        { enter = false }
      )
    end)
  end, "doc-tests (" .. table.concat(cmd, " ") .. ")")
end

-- ------------------------------------------------------------------ nextest profiles

--- Profile names declared in <root>/.config/nextest.toml (plus `default`).
function M.profiles(root)
  local names, seen = { "default" }, { default = true }
  local f = (root or "") .. "/.config/nextest.toml"
  if vim.uv.fs_stat(f) then
    for _, l in ipairs(vim.fn.readfile(f)) do
      local n = l:match("^%[profile%.([%w_%-]+)%]") or l:match('^%[profile%."([^"]+)"%]')
      if n and n ~= "default" and not seen[n] then
        seen[n] = true
        names[#names + 1] = n
      end
    end
  end
  return names
end

--- The profile NEXTEST_PROFILE selects ("default" when unset).
function M.profile()
  return vim.env.NEXTEST_PROFILE or "default"
end

--- Pick the nextest profile for the neotest runs of this session.
function M.pick_profile()
  local root = require("xyno_rust.rust_context").root() or vim.uv.cwd()
  local names = M.profiles(root)
  vim.ui.select(names, { prompt = "nextest profile (now: " .. M.profile() .. ")" }, function(choice)
    if not choice then
      return
    end
    vim.env.NEXTEST_PROFILE = choice ~= "default" and choice or nil
    vim.notify("nextest profile: " .. choice, vim.log.levels.INFO, { title = "tests" })
  end)
end

-- ------------------------------------------------------------------ coverage

--- Totals of an lcov file: { found, hit, pct, files = { { path, found, hit, pct } } } or nil.
function M.lcov_summary(path)
  if not (path and vim.uv.fs_stat(path)) then
    return nil
  end
  local files, cur = {}, nil
  for _, l in ipairs(vim.fn.readfile(path)) do
    local sf = l:match("^SF:(.+)$")
    if sf then
      cur = { path = sf, found = 0, hit = 0 }
      files[#files + 1] = cur
    elseif cur then
      local lf = l:match("^LF:(%d+)")
      local lh = l:match("^LH:(%d+)")
      if lf then
        cur.found = tonumber(lf)
      elseif lh then
        cur.hit = tonumber(lh)
      end
    end
  end
  local found, hit = 0, 0
  for _, f in ipairs(files) do
    f.pct = f.found > 0 and f.hit / f.found * 100 or 100
    found, hit = found + f.found, hit + f.hit
  end
  table.sort(files, function(a, b)
    return a.pct < b.pct
  end)
  return { found = found, hit = hit, pct = found > 0 and hit / found * 100 or 0, files = files }
end

return M
