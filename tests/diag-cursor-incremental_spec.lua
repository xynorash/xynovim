-- Cursor-mode diagnostics (lua/config/ui.lua): a cursor move rewrites only the lines around the cursor
-- instead of calling vim.diagnostic.show(nil, buf) (every diagnostic formatted again, every handler redrawn).
-- The result must be identical to the full redraw; the cost must not grow with the number of diagnostics.
local H = require("xynotest.helpers")
local ui = require("config.ui")
local ux = require("config.ux")

local E, W, I = vim.diagnostic.severity.ERROR, vim.diagnostic.severity.WARN, vim.diagnostic.severity.INFO

local function setup_buf(nlines, step, multi)
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.o.columns, vim.o.lines = 140, 30
  local lines = {}
  for i = 1, nlines do
    lines[i] = ("fn f%d() { let v = g(%d); }"):format(i, i)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.diagnostic.config({
    update_in_insert = true,
    virtual_text = {
      source = false,
      prefix = function(d)
        return ui.prefix(d)
      end,
      format = function(d)
        return ux.diagnostic_text(d)
      end,
    },
  })
  local ns = vim.api.nvim_create_namespace("diag-cursor-incremental")
  local ds = {}
  for l = 0, nlines - 1, step do
    local sev = ({ E, W, I })[math.floor(l / step) % 3 + 1]
    local d = {
      lnum = l,
      col = 0,
      severity = sev,
      message = ("problem %d: something is wrong with this line and the text is long enough to be cut"):format(l),
      code = "E" .. (1000 + l),
      source = "rust-analyzer",
    }
    if multi and math.floor(l / step) % 7 == 0 and l + 3 < nlines then
      d.end_lnum = l + 3
    end
    ds[#ds + 1] = d
    if math.floor(l / step) % 5 == 0 then
      ds[#ds + 1] = vim.tbl_extend("force", d, { severity = W, message = "second one on the line", code = "W1" })
    end
  end
  vim.diagnostic.set(ns, buf, ds)
  vim.cmd("redraw!")
  return buf, ns
end

--- line -> concatenated virtual text chunks of the namespace's virtual-text extmarks
local function drawn(buf, ns)
  local vns = vim.diagnostic.get_namespace(ns).user_data.virt_text_ns
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, vns, 0, -1, { details = true })) do
    local parts = {}
    for _, c in ipairs(m[4].virt_text or {}) do
      parts[#parts + 1] = c[1]
    end
    local text = table.concat(parts)
    if text:match("%S") then
      out[m[2]] = text
    end
  end
  return out
end

local function ms(f)
  local t = vim.uv.hrtime()
  f()
  return (vim.uv.hrtime() - t) / 1e6
end

describe("cursor-mode diagnostics redraw incrementally", function()
  before_each(function()
    vim.g.xynovim_diagnostics = nil
  end)

  it("the virtual-text handler is the wrapped one", function()
    local buf = setup_buf(10, 2)
    H.ok(type(ui._vt_refresh) == "function")
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    H.eq(true, ui._vt_refresh(buf), "state was remembered by the wrapper")
  end)

  it("any cursor path gives exactly what a full vim.diagnostic.show would draw", function()
    local buf, ns = setup_buf(300, 2, true)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.diagnostic.show(nil, buf)
    local rows = { 5, 6, 7, 40, 41, 3, 150, 1, 299, 148, 149, 150, 12, 13 }
    math.randomseed(7)
    for _ = 1, 30 do
      rows[#rows + 1] = math.random(1, 300)
    end
    for _, r in ipairs(rows) do
      vim.api.nvim_win_set_cursor(0, { r, 0 })
      H.eq(true, ui._vt_refresh(buf))
      local inc = drawn(buf, ns)
      vim.diagnostic.show(nil, buf)
      H.eq(drawn(buf, ns), inc, "cursor row " .. r)
      H.eq(true, ui._vt_refresh(buf)) -- the full show re-remembered the state with this cursor row
    end
  end)

  it("the cursor line shows the full text, the others the compact form", function()
    local buf, ns = setup_buf(40, 2)
    vim.api.nvim_win_set_cursor(0, { 5, 0 }) -- line index 4: an Error ('E1004')? find it by severity
    ui._vt_refresh(buf)
    local d = drawn(buf, ns)
    H.match(d[4], "problem 4: something is wrong", true)
    H.no_match(d[6] or "", "problem 6", true)
    vim.api.nvim_win_set_cursor(0, { 7, 0 })
    ui._vt_refresh(buf)
    d = drawn(buf, ns)
    H.match(d[6], "problem 6: something is wrong", true)
    H.no_match(d[4] or "", "problem 4:", true)
  end)

  it("the debounced CursorMoved path never calls vim.diagnostic.show", function()
    local buf = setup_buf(200, 2)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("doautocmd CursorMoved")
    H.wait_for(function()
      return true
    end, 100)
    vim.wait(80)
    local real, calls = vim.diagnostic.show, 0
    vim.diagnostic.show = function(...)
      calls = calls + 1
      return real(...)
    end
    local ok, err = pcall(function()
      for r = 2, 40 do
        vim.api.nvim_win_set_cursor(0, { r, 0 })
        vim.cmd("doautocmd CursorMoved")
        vim.wait(45)
      end
    end)
    vim.diagnostic.show = real
    H.ok(ok, tostring(err))
    H.eq(0, calls, "no full redraw on cursor moves")
    vim.wait(60)
    H.eq(0, calls)
    H.ok(buf)
  end)

  it("a resize still redraws everything (the room per line changed)", function()
    local buf, ns = setup_buf(60, 2)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    ui._vt_refresh(buf)
    local wide = drawn(buf, ns)
    vim.o.columns = 70
    vim.cmd("redraw!")
    vim.cmd("doautocmd VimResized")
    H.wait_for(function()
      local now = drawn(buf, ns)
      return now[2] and wide[2] and #now[2] < #wide[2]
    end, 3000, "line 2 re-cut to the narrower window")
    vim.o.columns = 140
  end)

  it("2000 diagnostics: a cursor move costs a small fraction of the full redraw", function()
    local buf = setup_buf(4000, 2, true)
    vim.api.nvim_win_set_cursor(0, { 2000, 0 })
    ui._vt_refresh(buf)
    local full = ms(function()
      vim.diagnostic.show(nil, buf)
    end)
    local inc = {}
    for i = 1, 20 do
      vim.api.nvim_win_set_cursor(0, { 2000 + i * 3, 0 })
      inc[#inc + 1] = ms(function()
        ui._vt_refresh(buf)
      end)
    end
    table.sort(inc)
    local med = inc[10]
    io.stdout:write(
      ("      [measured] %d diagnostics: full vim.diagnostic.show %.1f ms, incremental refresh median %.2f ms\n"):format(
        #vim.diagnostic.get(buf),
        full,
        med
      )
    )
    H.ok(med < 5, ("incremental refresh median %.2f ms"):format(med))
    H.ok(med * 10 < full, ("incremental %.2f ms vs full %.1f ms"):format(med, full))
  end)
end)
