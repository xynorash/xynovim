-- xyno-timeout: 300
-- Progressive feature shedding for large buffers (lua/config/largefile.lua): the pure tier function,
-- what tier 1 switches off in a real buffer and what it leaves on, the :LargeFile command, the
-- overrides, and that a small buffer is untouched.
local H = require("xynotest.helpers")
local L = require("config.largefile")

local function write_rs(lines, per_line, name)
  local dir = H.tmpdir()
  local path = dir .. "/" .. (name or "big.rs")
  local f = assert(io.open(path, "w"))
  local row = per_line or 'fn f() { println!("x"); }'
  for _ = 1, lines do
    f:write(row, "\n")
  end
  f:close()
  return path
end

describe("largefile tiers", function()
  it("tier_of: lines, bytes and average line length decide, small stays 0", function()
    local lim = { lines = 20000, bytes = 524288, avg_line = 300 }
    H.eq(0, L.tier_of(100, 3000, lim))
    H.eq(0, L.tier_of(19999, 400000, lim))
    H.eq(1, L.tier_of(20000, 400000, lim), "line count")
    H.eq(1, L.tier_of(5000, 524288, lim), "byte size")
    H.eq(1, L.tier_of(100, 100 * 301, lim), "long lines")
    H.eq(0, L.tier_of(100, 100 * 200, lim))
    H.eq(0, L.tier_of(0, 0, lim), "empty buffer")
  end)

  it("limits() merges vim.g.xynovim_largefile over the defaults", function()
    H.eq(20000, L.limits().lines)
    vim.g.xynovim_largefile = { lines = 5 }
    H.eq(5, L.limits().lines)
    H.eq(300, L.limits().avg_line)
    vim.g.xynovim_largefile = false
    local path = write_rs(30000)
    local buf = H.open(path)
    H.eq(0, L.tier(buf), "switched off")
    vim.g.xynovim_largefile = nil
  end)

  it("a small Rust buffer keeps folds, indent expression and hints settings", function()
    local buf = H.open(write_rs(50))
    vim.wait(200)
    H.eq(0, L.tier(buf))
    H.is_nil(vim.b[buf].xyno_large)
    H.ok(vim.b[buf].snacks_indent ~= false, "indent guides stay on")
    H.ok(not L.is_large(buf))
  end)

  it("a 30 000 line buffer is tier 1: manual folds, no indentexpr, guides / words / spell off", function()
    local buf = H.open(write_rs(30000))
    -- LazyVim's FileType handlers run after ours: the shedding is repeated on the next loop turn
    vim.wait(300)
    H.eq(1, vim.b[buf].xyno_large)
    H.ok(L.is_large(buf))
    H.eq("manual", vim.wo.foldmethod)
    H.eq("", vim.bo[buf].indentexpr)
    H.eq(false, vim.b[buf].snacks_indent)
    H.eq(false, vim.b[buf].snacks_words)
    H.eq(false, vim.wo.spell)
    H.match(L.describe(buf), "tier 1", true)
  end)

  it("tier 1 keeps treesitter highlighting but parses without the injection query of its language", function()
    local buf = H.open(write_rs(30000))
    vim.wait(300)
    H.ok(vim.treesitter.highlighter.active[buf], "treesitter highlighting is on")
    local parser = vim.treesitter.get_parser(buf, "rust")
    -- the injection query of the root language was replaced by an empty one
    local caps = parser._injection_query and parser._injection_query.captures or {}
    H.eq(0, #caps)
  end)

  it("a long-lines buffer (few lines, 400 bytes each) is tier 1", function()
    local buf = H.open(write_rs(300, "// " .. ("x"):rep(400)))
    vim.wait(300)
    H.eq(1, vim.b[buf].xyno_large)
  end)

  it(":LargeFile reports the tier and `off` restores the folds of the buffer", function()
    local buf = H.open(write_rs(30000))
    vim.wait(300)
    local cap = H.capture_notify()
    vim.cmd("LargeFile")
    cap.restore()
    H.match(cap.list[1].msg, "tier 1", true)
    vim.cmd("LargeFile off")
    H.is_nil(vim.b[buf].xyno_large)
    H.eq("expr", vim.wo.foldmethod)
    -- the folds of a 30 000 line buffer are exactly what tier 1 avoids: do not leave them to the next test
    vim.wo.foldmethod = "manual"
  end)

  it("a buffer that grows past the limit while editing is shed on the next write", function()
    -- a plain .dat file: no filetype, so no LSP / treesitter work on the 25 000 added lines
    local buf = vim.fn.bufadd(write_rs(50, nil, "grow.dat"))
    vim.fn.bufload(buf)
    vim.api.nvim_set_current_buf(buf)
    H.eq(0, L.tier(buf))
    local more = {}
    for i = 1, 25000 do
      more[i] = "fn g() {}"
    end
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, more)
    -- (the event itself: a real :write would run the formatters on 25 000 lines)
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf, group = "xynovim_largefile" })
    vim.wait(300)
    H.eq(1, vim.b[buf].xyno_large)
  end)
end)
