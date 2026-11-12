-- End-of-line inlay hints (ui-community.md item 16). The built-in renderer (vim.lsp.inlay_hint) draws every
-- hint inline, which moves the code to the right. In this mode the buffer's inline hints are switched off
-- and the same hints are requested from the same server (textDocument/inlayHint, the kinds the server was
-- told by `:Hints`) and drawn once per line as end-of-line virtual text: the code never moves.
-- Switch: `:Hints eol` / `:Hints inline`, or vim.g.xynovim_hints_style = "eol" (default "inline").
local M = {}

local ns = vim.api.nvim_create_namespace("xynovim.eolhints")
local active = {} -- bufnr -> true
local timers = {} -- bufnr -> uv timer

local schedule

local function label_text(h)
  local l = h.label
  if type(l) == "table" then
    local t = {}
    for _, p in ipairs(l) do
      t[#t + 1] = p.value
    end
    l = table.concat(t)
  end
  return l or ""
end

--- Text a line's hints become (pure). `hints` = { { col = byte column (0-based), label = "...", kind = 1|2 } }
--- sorted by column; `line` = the buffer line. Type hints read "name: Type" (the identifier before the
--- hint), parameter hints read "name=arg" (the token after it). Identical entries are dropped; the result
--- is cut at `max` display cells with an ellipsis.
function M.format_line(line, hints, max)
  local out, seen = {}, {}
  for _, h in ipairs(hints) do
    local lab = (h.label or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local entry
    if h.kind == 2 then
      local nm = lab:gsub(":$", "")
      local arg = line:sub(h.col + 1):match("^%s*([%w_%.&\"'%-]+)") or ""
      entry = arg ~= "" and (nm .. "=" .. arg) or nm
    else
      local before = line:sub(1, h.col)
      local ident = before:match("([%w_]+)%s*$")
      if lab:sub(1, 1) == ":" or lab:sub(1, 1) == "-" or not ident then
        entry = (ident and lab:sub(1, 1) == ":") and (ident .. lab) or lab
      else
        entry = ident .. ": " .. lab
      end
    end
    if not seen[entry] then
      seen[entry] = true
      out[#out + 1] = entry
    end
  end
  local text = table.concat(out, "  ")
  if max and vim.fn.strdisplaywidth(text) > max then
    text = vim.fn.strcharpart(text, 0, math.max(max - 1, 1)) .. "…"
  end
  return text
end

local function clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

local function render(buf, hints)
  clear(buf)
  if not active[buf] or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local by_line = {}
  for _, h in ipairs(hints) do
    local l = h.position.line
    local line = vim.api.nvim_buf_get_lines(buf, l, l + 1, false)[1]
    if line then
      local ok, col = pcall(vim.str_byteindex, line, "utf-16", h.position.character)
      by_line[l] = by_line[l] or {}
      table.insert(by_line[l], { col = ok and col or h.position.character, label = label_text(h), kind = h.kind })
    end
  end
  local win = vim.fn.bufwinid(buf)
  local width = win ~= -1 and vim.api.nvim_win_get_width(win) or vim.o.columns
  for l, hs in pairs(by_line) do
    table.sort(hs, function(a, b)
      return a.col < b.col
    end)
    local line = vim.api.nvim_buf_get_lines(buf, l, l + 1, false)[1] or ""
    local room = width - vim.fn.strdisplaywidth(line) - 8 -- number column, sign, a gap
    local text = room >= 8 and M.format_line(line, hs, room) or ""
    if text ~= "" then
      vim.api.nvim_buf_set_extmark(buf, ns, l, 0, {
        virt_text = { { "  " .. text, "LspInlayHint" } },
        virt_text_pos = "eol",
        hl_mode = "combine",
        priority = 5,
      })
    end
  end
end

local tries = {} -- bufnr -> empty answers in a row (rust-analyzer answers [] while it still loads)

local function refresh(buf)
  if not active[buf] or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local clients = vim.lsp.get_clients({ bufnr = buf, method = "textDocument/inlayHint" })
  local c = clients[1]
  if not c then
    return
  end
  local last = vim.api.nvim_buf_line_count(buf)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    range = { start = { line = 0, character = 0 }, ["end"] = { line = last, character = 0 } },
  }
  local tick = vim.b[buf].changedtick
  c:request("textDocument/inlayHint", params, function(err, res)
    if not err and active[buf] and vim.api.nvim_buf_is_valid(buf) and vim.b[buf].changedtick == tick then
      render(buf, res or {})
      -- an empty answer from a server that is still loading: ask again a few times (the built-in renderer
      -- gets workspace/inlayHint/refresh for this; a plain request does not)
      if #(res or {}) == 0 and (tries[buf] or 0) < 8 then
        tries[buf] = (tries[buf] or 0) + 1
        schedule(buf, 1500)
      else
        tries[buf] = nil
      end
    end
  end, buf)
end

schedule = function(buf, delay)
  local t = timers[buf]
  if not t then
    t = assert(vim.uv.new_timer())
    timers[buf] = t
  end
  t:stop()
  t:start(delay or 150, 0, vim.schedule_wrap(function()
    refresh(buf)
  end))
end

function M.is_active(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  return active[buf] == true
end

--- Re-request (after the kinds changed) or draw again.
function M.refresh(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if active[buf] then
    schedule(buf, 50)
  end
end

function M.enable(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if active[buf] then
    return
  end
  active[buf] = true
  pcall(vim.lsp.inlay_hint.enable, false, { bufnr = buf })
  local g = vim.api.nvim_create_augroup("xynovim_eolhints_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "LspAttach", "LspProgress", "WinResized", "BufEnter" }, {
    group = g,
    buffer = buf,
    callback = function()
      schedule(buf, 200)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = g,
    buffer = buf,
    callback = function()
      M.disable(buf)
    end,
  })
  schedule(buf, 50)
end

function M.disable(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if not active[buf] then
    return
  end
  active[buf] = nil
  pcall(vim.api.nvim_del_augroup_by_name, "xynovim_eolhints_" .. buf)
  if timers[buf] then
    timers[buf]:stop()
    timers[buf]:close()
    timers[buf] = nil
  end
  clear(buf)
end

return M
