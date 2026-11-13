-- Scope highlighting of the rainbow brackets (lua/config/rainbow.lua), after the JetBrains plugin:
--   Ctrl+right-click  "Highlight Current Scope": the innermost bracket pair around the click, its text range
--                     tinted with the pair's own rainbow colour mixed 0.2 into the editor background
--                     (the plugin: alpha 0.2), the two brackets marked as a box.
--   Alt+right-click   "Restrain Scope Highlighting": everything outside the pair is dimmed.
-- ESC (or any key, `scope.any_key`) clears it. Both are one-shot: nothing follows the cursor.
--
-- Deviation, on purpose: the plugin draws a BOXED effect (a rectangle outline) around the range. A terminal
-- cell grid has no outlines, so the two brackets are drawn inverted (rainbow colour as background) or
-- underlined (`scope.box`), which marks the same two edges.
local api = vim.api

local M = {}

local sns = api.nvim_create_namespace("xyno_rainbow_scope")
M.ns = sns

local active -- { buf, mode, pair, key_id }
local key_ns = api.nvim_create_namespace("xyno_rainbow_scope_keys")

local function R()
  return require("config.rainbow")
end

function M.active()
  return active and { buf = active.buf, mode = active.mode, pair = active.pair } or nil
end

function M.clear()
  if not active then
    return false
  end
  if api.nvim_buf_is_valid(active.buf) then
    api.nvim_buf_clear_namespace(active.buf, sns, 0, -1)
  end
  vim.on_key(nil, key_ns)
  active = nil
  pcall(vim.cmd, "redraw")
  return true
end

local function is_mouse_key(key)
  local k = vim.fn.keytrans(key)
  return k:find("Mouse", 1, true) or k:find("Release", 1, true) or k:find("Drag", 1, true) or k:find("Scroll", 1, true)
end

local function arm_clear()
  local any = R().opts().scope.any_key
  vim.on_key(function(key)
    if not active then
      return
    end
    if is_mouse_key(key) then
      return
    end
    if any or key == "\27" then
      vim.schedule(M.clear)
    end
  end, key_ns)
end

--- true plus nothing, or false plus the reason, when the options say the highlight must not show now
local function suppressed()
  local o = R().opts().scope
  if o.suppress_diff and vim.wo.diff then
    return "suppressed in diff windows (scope.suppress_diff)"
  end
  if o.suppress_debug then
    local dap = package.loaded["dap"]
    if dap and dap.session and dap.session() then
      return "suppressed while debugging (scope.suppress_debug)"
    end
  end
  return nil
end

local function underline_group(base, idx)
  local name = "XynoRainbowBoxU" .. idx
  local hl = api.nvim_get_hl(0, { name = base, link = false })
  api.nvim_set_hl(0, name, { fg = hl.fg, sp = hl.fg, underline = true, bold = true })
  return name
end

--- "Keep original colours": the text outside the scope keeps the hue of its tree-sitter highlight, each colour
--- mixed towards the background like the plain restrain colour. Only the rows around the visible ones are
--- processed (300 each way). Colours of LSP semantic tokens are not read (they are painted over by the dim).
local function keep_colors(buf, pair, o, mark)
  local P = require("config.rainbow_palette")
  local hl = vim.treesitter.highlighter.active[buf]
  if not hl then
    return
  end
  local light = P.variant() == "light"
  local surfaces = P.surfaces()
  local cache = {}
  local function dim_group(fg)
    local g = cache[fg]
    if not g then
      local hexfg = string.format("#%06x", fg)
      local c = P.dim(hexfg, o, surfaces, light)
      g = "XynoRainbowDim" .. c:sub(2)
      api.nvim_set_hl(0, g, { fg = tonumber(c:sub(2), 16) })
      cache[fg] = g
    end
    return g
  end
  local function fg_of(name, lang)
    local parts = vim.split(name, ".", { plain = true })
    for i = #parts, 1, -1 do
      local base = "@" .. table.concat(parts, ".", 1, i)
      for _, g in ipairs({ base .. "." .. lang, base }) do
        local h = api.nvim_get_hl(0, { name = g, link = false })
        if h.fg then
          return h.fg
        end
      end
    end
  end
  local top = math.max(vim.fn.line("w0") - 1 - 300, 0)
  local bot = math.min(vim.fn.line("w$") + 300, api.nvim_buf_line_count(buf))
  local function inside(r, c, er, ec)
    -- overlaps the scope (brackets included)?
    local o_r, o_c, c_r, c_c = pair.o[1], pair.o[2], pair.c[3], pair.c[4]
    local starts_after = r > c_r or (r == c_r and c >= c_c)
    local ends_before = er < o_r or (er == o_r and ec <= o_c)
    return not (starts_after or ends_before)
  end
  hl.tree:for_each_tree(function(tree, ltree)
    local lang = ltree:lang()
    local q = vim.treesitter.query.get(lang, "highlights")
    if not q then
      return
    end
    for id, node in q:iter_captures(tree:root(), buf, top, bot) do
      local name = q.captures[id]
      if name:sub(1, 1) ~= "_" then
        local fg = fg_of(name, lang)
        local r, c, er, ec = node:range()
        if fg and not inside(r, c, er, ec) then
          mark(r, c, { end_row = er, end_col = ec, hl_group = dim_group(fg), priority = 252 })
        end
      end
    end
  end)
end

--- Highlight (mode "scope") or restrain ("restrain") the pair around (row, col) of `buf`.
---@return boolean ok, string? message
function M.show(mode, buf, row, col)
  local rb = R()
  local why = suppressed()
  if why then
    return false, why
  end
  local pair = rb.pair_at(buf, row, col)
  if not pair then
    return false, "no bracket scope here"
  end
  M.clear()
  local o = rb.opts()
  local prio = o.priority
  local function mark(r, c, opts)
    opts.strict = false
    pcall(api.nvim_buf_set_extmark, buf, sns, r, c, opts)
  end
  if mode == "scope" then
    mark(pair.o[1], pair.o[2], {
      end_row = pair.c[3],
      end_col = pair.c[4],
      hl_group = "XynoRainbowScope" .. pair.index,
      priority = prio + 5,
    })
    if o.scope.box ~= "none" then
      local g = o.scope.box == "inverse" and ("XynoRainbowBox" .. pair.index) or underline_group(pair.group, pair.index)
      local ob = pair.o
      local cb = pair.c
      mark(ob[1], ob[2], { end_row = ob[1], end_col = ob[2] + 1, hl_group = g, priority = prio + 10 })
      mark(cb[1], cb[2], { end_row = cb[3], end_col = cb[4], hl_group = g, priority = prio + 10 })
    end
  else
    local g = "XynoRainbowRestrain"
    local last = api.nvim_buf_line_count(buf) - 1
    local last_col = #(api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or "")
    mark(0, 0, { end_row = pair.o[1], end_col = pair.o[2], hl_group = g, priority = 250 })
    mark(pair.c[3], pair.c[4], { end_row = last, end_col = last_col, hl_group = g, priority = 250 })
    if o.scope.restrain_keep_colors then
      keep_colors(buf, pair, o, mark)
    end
  end
  active = { buf = buf, mode = mode, pair = pair }
  arm_clear()
  pcall(vim.cmd, "redraw")
  return true
end

--- At the cursor of the current window.
function M.at_cursor(mode)
  local pos = api.nvim_win_get_cursor(0)
  return M.show(mode, api.nvim_get_current_buf(), pos[1] - 1, pos[2])
end

local function at_mouse(mode)
  if not R().opts().scope.mouse then
    return
  end
  local m = vim.fn.getmousepos()
  if m.winid == 0 or m.line == 0 then
    return
  end
  local buf = api.nvim_win_get_buf(m.winid)
  local ok, msg = M.show(mode, buf, m.line - 1, math.max(m.column - 1, 0))
  if not ok and msg then
    vim.notify("rainbow brackets: " .. msg, vim.log.levels.INFO)
  end
end

local mapped = false

function M.setup()
  local want = R().opts().scope.mouse
  if want and not mapped then
    vim.keymap.set("n", "<C-RightMouse>", function()
      at_mouse("scope")
    end, { desc = "Rainbow brackets: highlight current scope" })
    vim.keymap.set("n", "<A-RightMouse>", function()
      at_mouse("restrain")
    end, { desc = "Rainbow brackets: restrain scope highlighting" })
    mapped = true
  elseif not want and mapped then
    pcall(vim.keymap.del, "n", "<C-RightMouse>")
    pcall(vim.keymap.del, "n", "<A-RightMouse>")
    mapped = false
  end
end

return M
