-- lua/config/rendered.lua: opening the rendered-diagnostic float repeatedly must not pile up autocmds.
local H = require("xynotest.helpers")
local rendered = require("config.rendered")

local function make()
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fn a() {}", "fn b() {}", "fn c() {}" })
  local d = { bufnr = buf, lnum = 0, col = 0, end_lnum = 0, end_col = 2, severity = vim.diagnostic.severity.ERROR, message = "boom", source = "rustc" }
  return buf, d
end

local function count(event)
  return #vim.api.nvim_get_autocmds({ event = event })
end

describe("rendered diagnostic float autocmds", function()
  it("opening it ten times adds no ungrouped autocmds and one group of three", function()
    local buf, d = make()
    local before = { count("CursorMoved"), count("InsertEnter"), count("BufLeave") }
    for _ = 1, 10 do
      H.ok(rendered.open(d))
    end
    local after = { count("CursorMoved"), count("InsertEnter"), count("BufLeave") }
    H.eq({ before[1] + 1, before[2] + 1, before[3] + 1 }, after, "one autocmd per event, not ten")
    H.eq(3, #vim.api.nvim_get_autocmds({ group = "xynovim_rendered_float" }))
    vim.cmd("only")
    H.ok(buf)
  end)

  it("moving the cursor in the source window closes the float and drops its autocmds", function()
    local buf, d = make()
    local win = rendered.open(d)
    H.ok(win and vim.api.nvim_win_is_valid(win))
    vim.cmd("wincmd p")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("doautocmd CursorMoved")
    H.eq(false, vim.api.nvim_win_is_valid(win))
    local ok, left = pcall(vim.api.nvim_get_autocmds, { group = "xynovim_rendered_float" })
    H.eq(0, ok and #left or 0, "the group is gone")
    H.ok(buf)
  end)

  it("a CursorMoved with the cursor inside the float does not close it or use up the autocmd", function()
    local _, d = make()
    local win = rendered.open(d)
    vim.api.nvim_win_call(win, function()
      vim.cmd("doautocmd CursorMoved")
    end)
    H.eq(true, vim.api.nvim_win_is_valid(win))
    H.eq(3, #vim.api.nvim_get_autocmds({ group = "xynovim_rendered_float" }))
    vim.api.nvim_win_close(win, true)
  end)
end)
