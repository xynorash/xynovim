-- xyno-timeout: 400
-- Second round of Rust IDE features against the real server (tests/fixtures/keymaps-rust-crate): the keys,
-- :RustRename with a per-file preview, :RustUsages grouping, and the code lens a real rust-analyzer offers
-- (its titles are what a mouse click lands on). Plugin-level specs (shared run configs, profile view,
-- :TokioConsole, lens click in a tmux terminal) live in xyno-rust.nvim/tests. Needs XYNOVIM_DEV_PLUGINS.
local H = require("xynotest.helpers")

local S
local function session()
  H.need_rust()
  if S then
    vim.api.nvim_set_current_buf(S.buf)
    return S
  end
  local dir, buf = H.open_fixture("keymaps-rust-crate")
  local client = H.wait_lsp("rust-analyzer", buf)
  H.wait_for(function()
    return vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg("<leader>rb", "n", false, true).desc ~= nil
    end)
  end, 20000, "the scheduled rust maps")
  H.wait_for(function()
    local r = vim.lsp.buf_request_sync(buf, "textDocument/documentSymbol", { textDocument = vim.lsp.util.make_text_document_params(buf) }, 5000)
    for _, x in pairs(r or {}) do
      if x.result and #x.result > 0 then return true end
    end
  end, 90000, "analysis")
  S = { dir = dir, buf = buf, client = client }
  return S
end

local function need_dev()
  for _, c in ipairs({ "RustRename", "RustUsages", "RustProfile", "TokioConsole", "RustRunShare" }) do
    if vim.fn.exists(":" .. c) ~= 2 then
      H.skip_file("the pinned xyno-rust.nvim lacks :" .. c .. " (run with XYNOVIM_DEV_PLUGINS=~/projects/xyno-plugins)")
    end
  end
end

local function pos_of(buf, pat)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local c = l:find(pat, 1, true)
    if c then return { i, c - 1 } end
  end
  error("pattern not in the fixture: " .. pat)
end

describe("second-round Rust IDE features", function()
  it("<leader>rn, rU, rY, rA map to the new commands in a Rust buffer", function()
    need_dev()
    local s = session()
    vim.api.nvim_buf_call(s.buf, function()
      local want = { ["<leader>rn"] = "RustRename", ["<leader>rU"] = "RustUsages", ["<leader>rY"] = "RustProfile", ["<leader>rA"] = "TokioConsole" }
      for lhs, cmd in pairs(want) do
        local m = vim.fn.maparg(lhs, "n", false, true)
        H.match(m.rhs or "", cmd, true)
      end
    end)
  end)

  it(":RustUsages groups the usages of `used` and says how many", function()
    need_dev()
    local s = session()
    local at = pos_of(s.buf, "pub fn used")
    vim.api.nvim_win_set_cursor(0, { at[1], at[2] + 8 })
    local got
    local N = require("xyno_rust.rust_nav")
    H.wait_for(function()
      N.all_usages({ pick = function(items, _, summary) got = { items = items, summary = summary } end })
      vim.wait(2000, function() return got ~= nil end)
      return got
    end, 90000, "usages")
    H.ok(#got.items >= 1)
    H.match(got.summary, "usage(s) in 1 file(s)", true)
    H.eq("code", got.items[1].group)
  end)

  it(":RustRename previews the rename of `used` as a diff and applies it", function()
    need_dev()
    local s = session()
    local at = pos_of(s.buf, "pub fn used")
    vim.api.nvim_win_set_cursor(0, { at[1], at[2] + 8 })
    local R = require("xyno_rust.rename_preview")
    local got
    H.wait_for(function()
      R.rename("used_renamed", { pick = function(items, popts) got = { items = items, popts = popts } end })
      vim.wait(2000, function() return got ~= nil end)
      return got
    end, 90000, "rename edit")
    H.match(got.popts.title, "used_renamed", true)
    H.match(got.items[1].diff, "+pub fn used_renamed", true)
    local before = table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n")
    H.is_nil(before:find("used_renamed", 1, true))
    got.popts.confirm({ close = function() end }, nil)
    local after = table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n")
    H.match(after, "pub fn used_renamed", true)
    vim.cmd("silent! undo") -- one step
    H.match(table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n"), "pub fn used(", true)
  end)

  it("rust-analyzer's own code lens offers Run / Debug titles over `fn main` (what the click handler maps)", function()
    need_dev()
    local s = session()
    local L = require("xyno_rust.lens_click")
    local entries = H.wait_for(function()
      local e = vim.lsp.codelens.get({ bufnr = s.buf })
      return #e > 0 and e
    end, 90000, "code lenses")
    local at = pos_of(s.buf, "fn main")
    local sp = L.spans(entries, at[1] - 1, 0)
    local titles = vim.tbl_map(function(x) return x.lens.command.title end, sp)
    H.ok(#titles >= 2, vim.inspect(titles))
    H.match(table.concat(titles, " "), "Run", true)
    H.match(table.concat(titles, " "), "Debug", true)
  end)
end)
