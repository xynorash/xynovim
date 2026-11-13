-- Redraw and typing latency of the rainbow brackets (lua/config/rainbow.lua), run by rainbow.sh in a headless
-- nvim with the full config. RB_MODE = on | off ("off" sets enabled=false: the same code path minus the
-- provider's work, so the difference is the cost of the brackets), RB_LINES (large file, default 40000),
-- RB_OUT (json path), RB_FILE_DIR (where the generated files go).
--
-- Every sample is `vim.cmd("redraw!")` after one change of the view or the text, timed with hrtime; the
-- provider's own counters (S.stats) are reported next to them so a run in which the provider never ran is
-- visible. Typing = one inserted character at the middle of the buffer, then a redraw: it includes the
-- incremental tree-sitter parse, the highlighter and the brackets.
local uv = vim.uv
local mode = vim.env.RB_MODE or "on"
local big = tonumber(vim.env.RB_LINES) or 40000
local dir = vim.env.RB_FILE_DIR or vim.fn.stdpath("cache")
local out = { mode = mode, big_lines = big }

local function now()
  return uv.hrtime() / 1e6
end

local function pct(t, p)
  if #t == 0 then
    return nil
  end
  local s = vim.deepcopy(t)
  table.sort(s)
  return math.floor(s[math.max(1, math.ceil(#s * p))] * 100 + 0.5) / 100
end

local function summary(t)
  return { n = #t, median = pct(t, 0.5), p95 = pct(t, 0.95), max = pct(t, 1) }
end

local function gen(path, lines)
  local f = assert(io.open(path, "w"))
  local n, i = 0, 0
  while n < lines do
    i = i + 1
    f:write(
      ('/// item %d\n#[derive(Debug, Clone)]\npub struct Item%d { pub id: u64, pub name: String }\n\nimpl Item%d {\n    pub fn new(id: u64) -> Self {\n        Self { id, name: format!("item-{}", id) }\n    }\n\n    pub fn target_%d(&self, v: &[Vec<u8>]) -> u64 {\n        let c = |a: u64, b: u64| (a + b) * 2;\n        if v.len() < 3 && self.id > 1 { return c(self.id, v[0][0] as u64); }\n        self.id.wrapping_mul(%d) + self.name.len() as u64\n    }\n}\n\n'):format(
        i,
        i,
        i,
        i,
        i
      )
    )
    n = n + 17
  end
  f:close()
end

vim.o.columns = 160
vim.o.lines = 50
local ok, R = pcall(require, "config.rainbow")
if ok then
  if not R._state.ready then
    R.setup() -- VeryLazy never fires headless
  end
  if mode == "off" then
    R.set("enabled", false)
  end
end
vim.fn.mkdir(dir, "p")

local function sample_file(path, label, steps)
  vim.cmd("silent edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  local total = vim.api.nvim_buf_line_count(buf)
  local t0 = now()
  vim.cmd("redraw!")
  local first = now() - t0
  vim.wait(1500)
  local res = { lines = total, filetype = vim.bo[buf].filetype, large_tier = vim.b[buf].xyno_large or 0 }
  res.first_redraw_ms = math.floor(first * 10) / 10
  -- jumps to places far from the last one (cold tree-sitter range and cold bracket caches)
  local jumps = {}
  for _, frac in ipairs({ 0.5, 0.9, 0.1, 0.7, 0.3, 0.95, 0.2, 0.6 }) do
    local t = now()
    vim.cmd("normal! " .. math.floor(total * frac) .. "Gzz")
    vim.cmd("redraw!")
    jumps[#jumps + 1] = now() - t
  end
  res.jump_ms = summary(jumps)
  -- scrolling: 3 lines per step
  local scroll = {}
  vim.cmd("normal! " .. math.floor(total * 0.4) .. "Gzt")
  vim.cmd("redraw!")
  for _ = 1, steps do
    local t = now()
    vim.cmd("normal! 3\5")
    vim.cmd("redraw!")
    scroll[#scroll + 1] = now() - t
  end
  res.scroll_ms = summary(scroll)
  -- typing in the middle of the visible area
  vim.cmd("normal! " .. math.floor(total * 0.5) .. "Gzz")
  vim.cmd("redraw!")
  local row = vim.fn.line("w0") + 12
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local col = #line
  local typing = {}
  for i = 1, steps do
    local t = now()
    local ch = ({ "(", "x", ")", "[", "]", "{", " ", "}" })[(i - 1) % 8 + 1]
    vim.api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, { ch })
    col = col + 1
    vim.cmd("redraw!")
    typing[#typing + 1] = now() - t
  end
  res.typing_ms = summary(typing)
  vim.cmd("silent! bwipeout!")
  return res
end

local small = dir .. "/rb_small.rs"
local large = dir .. "/rb_large.rs"
gen(small, 2000)
gen(large, big)
out.small = sample_file(small, "small", 120)
out.large = sample_file(large, "large", 120)
if ok then
  out.provider = R._state.stats
end
local f = assert(io.open(vim.env.RB_OUT, "w"))
f:write(vim.json.encode(out))
f:close()
vim.cmd("qa!")
