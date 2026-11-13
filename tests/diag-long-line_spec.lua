-- Cursor-line diagnostics on a long line (lua/config/ui.lua, block_draw): beside a long line, or one with inline
-- inlay hints, the message used to start so far right that a few characters were visible ('× expecte').
-- Now it goes under the line, wrapped, when fewer than 20 columns are left and it does not fit whole.
local H = require("xynotest.helpers")
local ui = require("config.ui")
local ux = require("config.ux")

local E = vim.diagnostic.severity.ERROR

local MSG = "expected one of `,`, `;`, `}`, or an operator, found keyword `let` which is not allowed here"

local function setup_buf(line, cols)
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.o.columns, vim.o.lines = cols or 120, 30
  vim.g.xynovim_diagnostics = nil
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fn first() {}", line, "fn last() {}" })
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
  local ns = vim.api.nvim_create_namespace("diag-long-line")
  vim.diagnostic.set(ns, buf, { { lnum = 1, col = 0, severity = E, message = MSG, source = "rustc" } })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  return buf, ns
end

local function settle()
  vim.wait(300, function()
    return false
  end)
  vim.cmd("redraw!")
end

--- the text drawn on screen row `row` (1-based), cells joined
local function screen_row(row)
  local out = {}
  for c = 1, vim.o.columns do
    out[#out + 1] = vim.fn.screenstring(row, c)
  end
  return table.concat(out)
end

local function inline_marks(buf, ns)
  local vns = vim.diagnostic.get_namespace(ns).user_data.virt_text_ns
  return vim.api.nvim_buf_get_extmarks(buf, vns, { 1, 0 }, { 1, -1 }, { details = true })
end

local function block_lines(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ui.block_ns, 0, -1, { details = true })
  local out = {}
  for _, m in ipairs(marks) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      local t = {}
      for _, chunk in ipairs(vl) do
        t[#t + 1] = chunk[1]
      end
      out[#out + 1] = table.concat(t)
    end
  end
  return out
end

describe("cursor-line diagnostics on a long line", function()
  after_each(function()
    vim.g.xynovim_diagnostics = nil
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  local LONG = "    let value = compute_something_quite_long(first_argument, second_argument, third_argument) + other;"

  it("a message that does not fit beside the line goes under it, whole and wrapped", function()
    local buf, ns = setup_buf(LONG, 80)
    settle()
    H.eq(0, #inline_marks(buf, ns), "no end-of-line text with 'expecte' left of it")
    local lines = block_lines(buf)
    H.ok(#lines >= 2, "wrapped into several lines: " .. vim.inspect(lines))
    local width = vim.o.columns - vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
    for _, l in ipairs(lines) do
      H.ok(vim.fn.strdisplaywidth(l) <= width, "fits the window: " .. l)
    end
    local joined = table.concat(lines, " "):gsub("%s+", " ")
    for _, word in ipairs({ "expected", "operator,", "found", "keyword", "allowed", "here", "[rustc]" }) do
      H.ok(joined:find(word, 1, true), "the message is complete, missing " .. word .. ": " .. joined)
    end
    -- on the real screen: right under the line
    local srow = vim.fn.screenpos(0, 2, 1).row
    H.match(screen_row(srow + 1), "expected", true)
    H.match(screen_row(srow + 1), ui.prefix({ severity = E }), true)
    H.match(screen_row(srow + #lines + 1), "fn last() {}", true, "the next line follows the block")
  end)

  it("the block follows the cursor and is gone when the cursor leaves the line", function()
    local buf = setup_buf(LONG, 120)
    settle()
    H.ok(#block_lines(buf) > 0)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.cmd("doautocmd CursorMoved")
    settle()
    H.eq(0, #block_lines(buf), "cleared on the other line")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("doautocmd CursorMoved")
    settle()
    H.ok(#block_lines(buf) > 0, "back")
  end)

  it("a line with room keeps the message at the end of the line, no block", function()
    local buf, ns = setup_buf("    let v = 1;", 120)
    settle()
    H.eq(0, #block_lines(buf))
    H.eq(1, #inline_marks(buf, ns))
  end)

  it("inline inlay hints count: they push the line right, so the message no longer fits beside it", function()
    local buf, ns = setup_buf("    let value = compute(first_argument, second_argument);", 120)
    settle()
    H.eq(0, #block_lines(buf), "without hints there is room (about 60 columns)")
    local hints = vim.api.nvim_create_namespace("diag-long-line-hints")
    for i = 0, 3 do
      vim.api.nvim_buf_set_extmark(buf, hints, 1, 10 + i * 8, {
        virt_text = { { ": SomeVeryLongTypeName", "Comment" } },
        virt_text_pos = "inline",
      })
    end
    vim.diagnostic.show(ns, buf)
    ui.block_draw(buf) -- (hints arriving later are noticed on the next cursor move / diagnostic update)
    settle()
    H.ok(#block_lines(buf) > 0, "with about 85 cells of hints the message goes under the line")
    H.eq(0, #inline_marks(buf, ns))
  end)

  it("a narrow window (60 columns) and a very long message are bounded", function()
    local buf, ns = setup_buf(LONG, 60)
    vim.diagnostic.set(ns, buf, {
      { lnum = 1, col = 0, severity = E, message = string.rep("word ", 200), source = "rustc" },
    })
    settle()
    local lines = block_lines(buf)
    H.ok(#lines >= 2 and #lines <= 6, "at most 6 lines: " .. #lines)
    H.match(lines[#lines], "…", true)
    for _, l in ipairs(lines) do
      H.ok(vim.fn.strdisplaywidth(l) <= 60)
    end
  end)

  it("DiagnosticsView off draws nothing", function()
    local buf = setup_buf(LONG, 120)
    vim.g.xynovim_diagnostics = "off"
    ui.block_draw(buf)
    H.eq(0, #block_lines(buf))
  end)
end)
