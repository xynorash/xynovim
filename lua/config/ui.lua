-- UI policy from docs/comparison/ui-community.md (the numbers in the comments are its shortlist
-- items): per-kind inlay hints (1), cursor-line-first diagnostics with width-aware text (2, 10, 11),
-- severity glyphs (4), icon fallback (9), narrow-window statusline (8), state components for the
-- sandbox / guard / history (statusline) and the popup highlight mapping.
--
-- Switches (all `vim.g`, set before the config loads, or at run time through the commands):
--   vim.g.xynovim_hints        { types = true, params = true, lifetimes = true }   :Hints
--   vim.g.xynovim_hints_style  "inline" (default) | "eol" (end of line, code never moves)  :Hints eol|inline
--   vim.g.xynovim_diagnostics  "cursor" (default) | "all" | "off"                 :DiagnosticsView
--   vim.g.xynovim_icons        "auto" (default) | "nerd" | "ascii"  (or $XYNOVIM_ICONS) :XynoIcons
--   vim.g.xynovim_contrast     "normal" (default) | "high"                         :IslandContrast
--   vim.g.xynovim_winbar       false (default) | true                              :XynoWinbar
--   :colorscheme island-light  the light variant (lua/island/light.lua)
local M = {}

-- Width ------------------------------------------------------------------------------------

--- Columns the statusline can use: the whole screen with a global statusline, else the window.
function M.width()
  if vim.o.laststatus == 3 then
    return vim.o.columns
  end
  return vim.api.nvim_win_get_width(0)
end

-- Icons (item 9) -----------------------------------------------------------------------------

-- Plain-text stand-ins. Keys mirror LazyVim.config.icons (the table the lualine, diagnostics and
-- bufferline specs read).
M.ASCII = {
  diagnostics = { Error = "E ", Warn = "W ", Hint = "H ", Info = "I " },
  git = { added = "+", modified = "~", removed = "-" },
  misc = { dots = "..." },
  dap = {
    Stopped = { ">", "DiagnosticWarn", "DapStoppedLine" },
    Breakpoint = "o",
    BreakpointCondition = "?",
    BreakpointRejected = { "x", "DiagnosticError" },
    LogPoint = ".>",
  },
}

--- Characters that mark each severity (distinct shapes, one cell wide). Used as the virtual text
--- prefix and as the sign text, so severity never rests on colour alone (item 4).
M.SEVERITY_GLYPHS = {
  nerd = { [1] = "✗", [2] = "▲", [3] = "●", [4] = "◆" },
  ascii = { [1] = "x", [2] = "!", [3] = "i", [4] = "?" },
}

--- "nerd" | "ascii". `auto` picks ascii only when it is certain the terminal cannot show the
--- glyphs (Linux console, dumb terminal, non-UTF-8 locale); it cannot see the terminal's font, so
--- a missing Nerd Font is reported as a hint (see font_hint), not guessed.
--- @param env? { icons?: string, term?: string, lang?: string } test seam
function M.icon_mode(env)
  env = env or {}
  local want = env.icons or vim.env.XYNOVIM_ICONS or vim.g.xynovim_icons or "auto"
  if want == "nerd" or want == "ascii" then
    return want
  end
  local term = env.term or vim.env.TERM or ""
  local lang = (env.lang or vim.env.LC_ALL or vim.env.LC_CTYPE or vim.env.LANG or ""):lower()
  if term == "linux" or term == "dumb" or (lang ~= "" and lang ~= "c.utf-8" and not lang:find("utf%-?8")) then
    return "ascii"
  end
  return "nerd"
end

--- @param fonts string  output of `fc-list` (or any list of font names)
--- @return boolean
function M.has_nerd_font(fonts)
  fonts = fonts:lower()
  return fonts:find("nerd font", 1, true) ~= nil
    or fonts:find(" nfm", 1, true) ~= nil
    or fonts:find("nerdfont", 1, true) ~= nil
    or fonts:find("symbols nerd", 1, true) ~= nil
end

--- The detection hint: text when this machine has no Nerd Font installed (via fontconfig), else
--- nil. It is a hint only: the terminal may use a font fontconfig does not list.
--- @param fonts? string test seam; default `fc-list`
--- @return string?
function M.font_hint(fonts)
  if not fonts then
    if vim.fn.executable("fc-list") ~= 1 then
      return nil
    end
    local ok, o = pcall(function()
      return vim.system({ "fc-list" }, { text = true }):wait(3000)
    end)
    if not ok or o.code ~= 0 then
      return nil
    end
    fonts = o.stdout or ""
  end
  if M.has_nerd_font(fonts) then
    return nil
  end
  return "No Nerd Font found on this system (fc-list). If icons show as boxes, install one and set the "
    .. 'terminal font to it, or switch to plain text: :XynoIcons ascii (vim.g.xynovim_icons = "ascii").'
end

local icons_original
--- Apply the icon mode to what can change at run time: LazyVim's icon table, diagnostic signs and
--- mini.icons. Plugins that copy icons into their options at load (lualine, bufferline, neo-tree,
--- the dashboard) read ascii_active() in their own specs (lua/plugins/ui-icons.lua).
function M.apply_icons()
  local ok, LazyVim = pcall(function()
    return _G.LazyVim
  end)
  local ascii = M.icon_mode() == "ascii"
  if ok and LazyVim and LazyVim.config and LazyVim.config.icons then
    icons_original = icons_original or vim.deepcopy(LazyVim.config.icons)
    local base = vim.deepcopy(icons_original)
    LazyVim.config.icons = ascii and vim.tbl_deep_extend("force", base, M.ASCII) or base
  end
  if package.loaded["mini.icons"] and _G.MiniIcons and MiniIcons.config then
    local style = ascii and "ascii" or "glyph"
    if MiniIcons.config.style ~= style then
      -- setup() again: mini.icons caches what it returned, a bare config change would not show
      local cfg = vim.deepcopy(MiniIcons.config)
      cfg.style = style
      pcall(MiniIcons.setup, cfg)
      MiniIcons.config.style = style
      if package.loaded["nvim-web-devicons"] and MiniIcons.mock_nvim_web_devicons then
        pcall(MiniIcons.mock_nvim_web_devicons)
      end
    end
  end
  M.apply_signs()
  return ascii and "ascii" or "nerd"
end

function M.ascii_active()
  return M.icon_mode() == "ascii"
end

-- Diagnostics (items 2, 4, 10, 11) --------------------------------------------------------------

--- "cursor" | "all" | "off"
function M.diag_mode()
  local v = vim.g.xynovim_diagnostics
  return (v == "all" or v == "off") and v or "cursor"
end

local function glyphs()
  return M.SEVERITY_GLYPHS[M.icon_mode()]
end

--- Sign text per severity: the shape glyphs above (one cell: the sign column is 2 wide with a
--- space after it).
function M.apply_signs()
  local g = glyphs()
  vim.diagnostic.config({
    signs = {
      text = {
        [vim.diagnostic.severity.ERROR] = g[1],
        [vim.diagnostic.severity.WARN] = g[2],
        [vim.diagnostic.severity.INFO] = g[3],
        [vim.diagnostic.severity.HINT] = g[4],
      },
    },
  })
  if vim.v.vim_did_enter == 1 then
    pcall(vim.diagnostic.show) -- the sign handler reads the config when it draws
  end
end

--- virtual_text.prefix: the severity glyph.
function M.prefix(d)
  return glyphs()[d.severity] or "●"
end

local function trunc(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width <= 1 then
    return width == 1 and "…" or ""
  end
  local out = vim.fn.strcharpart(text, 0, width - 1)
  while vim.fn.strdisplaywidth(out) > width - 1 do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out .. "…"
end
M.truncate = trunc

--- Columns left on the line for the message of virtual text.
local function room(d)
  local win = vim.fn.bufwinid(d.bufnr)
  if win == -1 then
    return 200
  end
  local info = vim.fn.getwininfo(win)[1]
  local line = vim.api.nvim_buf_get_lines(d.bufnr, d.lnum, d.lnum + 1, false)[1] or ""
  local used = vim.fn.strdisplaywidth(line:gsub("\t", string.rep(" ", vim.bo[d.bufnr].tabstop)))
  -- nvim draws one prefix glyph per diagnostic on the line, then the last one's message
  local glyphs_on_line = math.max(#vim.diagnostic.get(d.bufnr, { lnum = d.lnum }), 1)
  -- 4 cells of spacing, the glyph(s), the space before the message, one spare cell
  return info.width - info.textoff - used - 4 - glyphs_on_line - 1 - 1
end

--- Whether the cursor of the window showing d's buffer is on the diagnostic's lines.
local function on_cursor(d)
  local win = vim.fn.bufwinid(d.bufnr)
  if win == -1 then
    return true
  end
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  return row >= d.lnum and row <= (d.end_lnum or d.lnum)
end

--- Shortest useful text of a problem for lines the cursor is not on: the rustc/lint code when
--- there is one, else the start of the message.
local function compact(d, text)
  local code = d.code ~= nil and tostring(d.code) or nil
  if code and #code <= 24 then
    return code
  end
  return (text:gsub(" %[[^%]]*%]$", ""))
end

--- Shape the text virtual_text.format returns (config.ux.diagnostic_text calls this last):
--- `cursor` mode shows the full text on the cursor line and, elsewhere, only Error and Warn as
--- a code or a few words; the text is cut with an ellipsis to the room the line has left, and
--- `nil` (nothing drawn) when there is none. The full message stays in the diagnostic float.
--- @param d vim.Diagnostic
--- @param text string
--- @return string?
function M.shape_text(d, text)
  local mode = M.diag_mode()
  if mode == "off" then
    return nil
  end
  if not (d.bufnr and d.lnum and vim.api.nvim_buf_is_valid(d.bufnr)) then
    return text -- not a diagnostic of a buffer: nothing to place it against
  end
  if mode == "cursor" and not on_cursor(d) then
    if d.severity > vim.diagnostic.severity.WARN then
      return nil
    end
    text = compact(d, text)
  end
  local avail = room(d)
  if avail < 6 then
    return nil
  end
  return trunc(text, avail)
end

local last_row = {}

-- Hints (item 1) ----------------------------------------------------------------------------------

-- rust-analyzer settings behind each kind: { path in `inlayHints`, on value, off value }
M.HINT_KINDS = {
  types = {
    label = "T",
    long = "types",
    { "typeHints", "enable", true, false },
    { "chainingHints", "enable", true, false },
    { "closureReturnTypeHints", "enable", "with_block", "never" },
  },
  params = {
    label = "P",
    long = "params",
    { "parameterHints", "enable", true, false },
  },
  lifetimes = {
    label = "L",
    long = "lifetimes",
    { "lifetimeElisionHints", "enable", "skip_trivial", "never" },
  },
}
M.HINT_ORDER = { "types", "params", "lifetimes" }

--- Hints shown in this buffer by either renderer (inline built-in, or end-of-line, item 16).
function M.hints_enabled(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  return vim.lsp.inlay_hint.is_enabled({ bufnr = buf }) or require("config.eolhints").is_active(buf)
end

function M.hint_style()
  return require("config.eolhints").is_active(0) and "eol" or "inline"
end

function M.hint_state()
  local st = vim.g.xynovim_hints
  local out = {}
  for _, k in ipairs(M.HINT_ORDER) do
    out[k] = type(st) ~= "table" or st[k] ~= false
  end
  return out
end

--- The `inlayHints` settings for a kind state (pure; what the server is told).
function M.hint_settings(state)
  local out = {}
  for _, k in ipairs(M.HINT_ORDER) do
    for _, e in ipairs(M.HINT_KINDS[k]) do
      out[e[1]] = out[e[1]] or {}
      out[e[1]][e[2]] = state[k] and e[3] or e[4]
    end
  end
  return out
end

local function apply_client(client)
  if type(client.settings) ~= "table" then
    return false
  end
  local ra = client.settings["rust-analyzer"] or {}
  ra.inlayHints = vim.tbl_deep_extend("force", ra.inlayHints or {}, M.hint_settings(M.hint_state()))
  client.settings["rust-analyzer"] = ra
  client:notify("workspace/didChangeConfiguration", { settings = vim.empty_dict() })
  return true
end

--- Tell every running rust-analyzer the current kinds, then re-request the hints.
function M.apply_hints()
  for _, c in ipairs(vim.lsp.get_clients({ name = "rust-analyzer" })) do
    apply_client(c)
  end
  vim.defer_fn(function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if
        vim.api.nvim_buf_is_loaded(b)
        and #vim.lsp.get_clients({ bufnr = b, method = "textDocument/inlayHint" }) > 0
      then
        if require("config.eolhints").is_active(b) then
          require("config.eolhints").refresh(b)
        elseif vim.lsp.inlay_hint.is_enabled({ bufnr = b }) then
          pcall(vim.lsp.inlay_hint.enable, false, { bufnr = b })
          pcall(vim.lsp.inlay_hint.enable, true, { bufnr = b })
        end
      end
    end
  end, 150)
end

--- :Hints [types|params|lifetimes|all|on|off|status]
--- @return string  the state line
function M.hints(arg)
  arg = vim.trim(arg or "")
  local st = M.hint_state()
  -- the master switch is per buffer, like LazyVim's <leader>uh; the kinds are the server's
  local buf = { bufnr = 0 }
  local eol = require("config.eolhints")
  local master = M.hints_enabled(0)
  -- the style outlives the switch: after `:Hints eol`, `:Hints off` and `:Hints on` come back as eol
  local function turn_on()
    if vim.g.xynovim_hints_style == "eol" then
      eol.enable(0)
    else
      vim.lsp.inlay_hint.enable(true, buf)
    end
  end
  local function turn_off()
    eol.disable(0)
    vim.lsp.inlay_hint.enable(false, buf)
  end
  if arg == "" or arg == "all" or arg == "toggle" then
    if master then
      turn_off()
    else
      turn_on()
    end
  elseif arg == "eol" then
    vim.g.xynovim_hints_style = "eol"
    eol.enable(0)
  elseif arg == "inline" then
    vim.g.xynovim_hints_style = "inline"
    eol.disable(0)
    vim.lsp.inlay_hint.enable(true, buf)
  elseif arg == "on" then
    turn_on()
    for _, k in ipairs(M.HINT_ORDER) do
      st[k] = true
    end
  elseif arg == "off" then
    turn_off()
  elseif M.HINT_KINDS[arg] then
    st[arg] = not st[arg]
    if not master then
      turn_on()
    end
  elseif arg ~= "status" then
    return "Hints: unknown argument '" .. arg .. "' (types, params, lifetimes, eol, inline, on, off, status)"
  end
  vim.g.xynovim_hints = st
  if arg ~= "status" and arg ~= "" and arg ~= "all" and arg ~= "toggle" and arg ~= "off" then
    M.apply_hints()
  end
  return M.hints_line()
end

function M.hints_line()
  local st = M.hint_state()
  local parts = {}
  for _, k in ipairs(M.HINT_ORDER) do
    parts[#parts + 1] = k .. " " .. (st[k] and "on" or "off")
  end
  return "inlay hints "
    .. (M.hints_enabled(0) and (M.hint_style() == "eol" and "on, end of line" or "on") or "off")
    .. " ("
    .. table.concat(parts, ", ")
    .. ")"
end

--- Statusline text for rust buffers: "" when everything is at its default and the window is
--- narrow, "hints TPL" otherwise; letters of switched-off kinds are replaced by "-".
function M.hints_status(width)
  if vim.bo.filetype ~= "rust" then
    return ""
  end
  width = width or M.width()
  local st = M.hint_state()
  local letters, full = {}, true
  for _, k in ipairs(M.HINT_ORDER) do
    letters[#letters + 1] = st[k] and M.HINT_KINDS[k].label or "-"
    full = full and st[k]
  end
  if not M.hints_enabled(0) then
    return "hints off"
  end
  local eolmark = M.hint_style() == "eol" and " eol" or ""
  if full and width < 110 then
    return eolmark ~= "" and "hints eol" or ""
  end
  return "hints " .. table.concat(letters) .. eolmark
end

-- Statusline state: sandbox / guard / history ------------------------------------------------------

--- Sandbox of the 99 agent: shown only once the module is loaded (never loads it).
--- @return string text, string hl
function M.sandbox_status(width)
  local sb = package.loaded["xyno_sandbox"]
  if not sb or type(sb.statusline) ~= "function" then
    return "", "XynoStatusMuted"
  end
  local text = sb.statusline()
  if (width or M.width()) < 80 then
    text = text:gsub("^sandbox: ", "sb ")
  end
  local hl = type(sb.statusline_hl) == "function" and sb.statusline_hl() or "DiagnosticOk"
  local map = {
    DiagnosticOk = "XynoStatusOk",
    DiagnosticWarn = "XynoStatusWarn",
    DiagnosticError = "XynoStatusError",
    DiagnosticHint = "XynoStatusBusy",
  }
  return text, map[hl] or hl
end

--- Disk guard of auto-save: the current buffer changed (or vanished) on disk, so auto-save is
--- paused for it. Empty otherwise.
function M.guard_status(width)
  local b = vim.api.nvim_get_current_buf()
  if vim.b[b].xyno_guard_warned == nil or vim.b[b].xyno_guard_warned == vim.NIL then
    return "", "XynoStatusMuted"
  end
  return (width or M.width()) < 80 and "guard!" or "guard: auto-save paused", "XynoStatusWarn"
end

--- Local history: a snapshot failure of this session's repositories ("history: FAILING"), else
--- empty (a healthy history needs no statusline space; :checkhealth and :LocalHistory say more).
function M.history_status(width)
  local h = package.loaded["xyno_history"]
  if not h or type(h.status) ~= "function" then
    return "", "XynoStatusMuted"
  end
  local ok, st = pcall(h.status)
  if not ok then
    return "", "XynoStatusMuted"
  end
  for _, row in pairs(st) do
    if row.failing then
      return (width or M.width()) < 80 and "hist!" or "history: failing", "XynoStatusError"
    end
  end
  return "", "XynoStatusMuted"
end

-- lualine ------------------------------------------------------------------------------------------

-- Minimum columns for a component to be drawn; below it the component is dropped. The order is
-- the order they disappear in: clock, progress, git diff / noice, branch, root dir, location,
-- filetype icon. The mode (a letter below 70), the filename and the server state never go.
M.PRIORITY = {
  clock = 120,
  progress = 100,
  diff = 100,
  noice = 100,
  lazy = 100,
  branch = 90,
  root = 85,
  diagnostics = 70,
  location = 70,
  ficon = 64,
  hints = 100,
  sandbox = 70,
  guard = 70,
  history = 70,
}

local function wide(name)
  return function()
    return M.width() >= M.PRIORITY[name]
  end
end

--- Return `component` (a string name or a table) with a width condition added.
local function guard(component, name)
  local w = wide(name)
  if type(component) == "string" then
    return { component, cond = w }
  elseif type(component) == "function" then
    return { component, cond = w }
  end
  local c = vim.deepcopy(component)
  local old = c.cond
  c.cond = function()
    return w() and (old == nil or old())
  end
  return c
end

--- Rewrite lualine opts (LazyVim's layout) into the narrow-window priority collapse and add the
--- state components. Idempotent per opts table.
function M.lualine(opts)
  if opts._xyno_ui then
    return opts
  end
  opts._xyno_ui = true
  local s = opts.sections
  local function each(list, fn)
    for i, c in ipairs(list or {}) do
      list[i] = fn(c, i) or c
    end
  end
  -- mode: one letter when narrow
  s.lualine_a = {
    {
      "mode",
      fmt = function(str)
        return M.width() < 70 and str:sub(1, 1) or str
      end,
    },
  }
  each(s.lualine_b, function(c)
    return c == "branch" and guard(c, "branch") or nil
  end)
  local pretty
  each(s.lualine_c, function(c)
    if type(c) == "table" and c[1] == "diagnostics" then
      return guard(c, "diagnostics")
    elseif type(c) == "table" and c[1] == "filetype" then
      return guard(c, "ficon")
    elseif type(c) == "table" and type(c[1]) == "function" and c.color then
      return guard(c, "root") -- LazyVim.lualine.root_dir() (a function with a colour)
    elseif type(c) == "table" and type(c[1]) == "function" and _G.LazyVim and LazyVim.lualine then
      -- LazyVim.lualine.pretty_path(): the file name never goes, the path in front of it shrinks
      -- (3 parent folders, then 2, then none: pretty_path's own length=1 drops the name)
      pretty = pretty or {}
      local keep = vim.deepcopy(c)
      keep[1] = function(self)
        local w = M.width()
        if w < 80 then
          local name = vim.fn.expand("%:t")
          if name == "" then
            return ""
          end
          return LazyVim.lualine.format(self, name, vim.bo.modified and "MatchParen" or "Bold")
            .. (vim.bo.readonly and " RO" or "")
        end
        local len = w >= 100 and 3 or 2
        pretty[len] = pretty[len] or LazyVim.lualine.pretty_path({ length = len })
        return pretty[len](self)
      end
      return keep
    end
  end)
  each(s.lualine_x, function(c)
    if type(c) == "table" and c[1] == "diff" then
      return guard(c, "diff")
    elseif type(c) == "table" and (type(c[1]) == "function" or c[1] == "lazy") then
      return guard(c, "noice") -- profiler, noice command / mode, dap, plugin updates
    end
  end)
  each(s.lualine_y, function(c)
    if type(c) == "table" and c[1] == "progress" then
      return guard(c, "progress")
    elseif type(c) == "table" and c[1] == "location" then
      return guard(c, "location")
    end
  end)
  each(s.lualine_z, function(c)
    return guard(c, "clock")
  end)
  return opts
end

--- Components to append to lualine_x: hints, sandbox, guard, history. Each hides on its own when
--- there is nothing to say or the window is narrow.
function M.lualine_x_components()
  local function item(fn, name)
    local function text()
      local t = fn(M.width())
      return type(t) == "string" and t or ""
    end
    return {
      function()
        return (fn(M.width()))
      end,
      cond = function()
        return M.width() >= M.PRIORITY[name] and text() ~= ""
      end,
      color = function()
        local _, hl = fn(M.width())
        return hl
      end,
    }
  end
  return {
    {
      function()
        return M.hints_status()
      end,
      cond = function()
        return M.hints_status() ~= ""
          and (M.width() >= M.PRIORITY.hints or not M.hints_enabled(0))
      end,
      color = function()
        return M.hints_enabled(0) and "XynoStatusMuted" or "XynoStatusWarn"
      end,
    },
    item(M.guard_status, "guard"),
    item(M.history_status, "history"),
    item(M.sandbox_status, "sandbox"),
  }
end

-- Popup windows ---------------------------------------------------------------------------------------

M.POPUP_FILETYPES = { ["xyno-sandbox"] = true, ["xyno-history"] = true, ["xyno-guard"] = true, ["xyno-macros"] = true }

local WINHL =
  "NormalFloat:XynoPopupNormal,FloatBorder:XynoPopupBorder,FloatTitle:XynoPopupTitle,FloatFooter:XynoPopupFooter"

--- Put a plugin popup window on the Xyno* groups (no-op for any other window).
function M.style_popup(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not M.POPUP_FILETYPES[vim.bo[buf].filetype] or vim.api.nvim_win_get_config(win).relative == "" then
    return false
  end
  vim.wo[win].winhighlight = WINHL
  return true
end

-- Setup ----------------------------------------------------------------------------------------------------

function M.setup()
  local group = vim.api.nvim_create_augroup("xynovim_ui", { clear = true })

  vim.api.nvim_create_user_command("Hints", function(o)
    vim.notify(M.hints(o.args))
  end, {
    nargs = "?",
    desc = "Inlay hints: toggle, or switch one kind (types, params, lifetimes) on/off",
    complete = function()
      return { "types", "params", "lifetimes", "eol", "inline", "on", "off", "status" }
    end,
  })

  vim.api.nvim_create_user_command("DiagnosticsView", function(o)
    local a = vim.trim(o.args)
    if a == "cursor" or a == "all" or a == "off" then
      vim.g.xynovim_diagnostics = a
      vim.diagnostic.show()
    elseif a ~= "" then
      return vim.notify("DiagnosticsView: cursor, all or off", vim.log.levels.WARN)
    end
    vim.notify("inline diagnostics: " .. M.diag_mode())
  end, {
    nargs = "?",
    desc = "Inline diagnostics: cursor (full on the cursor line, compact elsewhere), all, off",
    complete = function()
      return { "cursor", "all", "off" }
    end,
  })

  vim.api.nvim_create_user_command("XynoIcons", function(o)
    local a = vim.trim(o.args)
    if a == "nerd" or a == "ascii" or a == "auto" then
      vim.g.xynovim_icons = a
      M.apply_icons()
      local rebuilt = require("config.ui_chrome").refresh()
      vim.notify(
        "icons: "
          .. M.icon_mode()
          .. (a ~= "auto" and "" or " (auto)")
          .. "; rebuilt now: signs, "
          .. table.concat(rebuilt, ", ")
          .. ". Read at startup only: the tree's expander arrows, git and diagnostic symbols"
      )
    elseif a ~= "" then
      return vim.notify("XynoIcons: nerd, ascii or auto", vim.log.levels.WARN)
    else
      vim.notify("icons: " .. M.icon_mode() .. (M.font_hint() and ("\n" .. M.font_hint()) or ""))
    end
  end, {
    nargs = "?",
    desc = "Icon set: nerd, ascii (no Nerd Font needed) or auto",
    complete = function()
      return { "nerd", "ascii", "auto" }
    end,
  })

  vim.api.nvim_create_user_command("IslandContrast", function(o)
    local a = vim.trim(o.args)
    if a == "normal" or a == "high" then
      vim.g.xynovim_contrast = a
      if vim.g.colors_name then
        pcall(vim.cmd.colorscheme, vim.g.colors_name)
      end
    elseif a ~= "" then
      return vim.notify("IslandContrast: normal or high", vim.log.levels.WARN)
    end
    vim.notify("contrast: " .. (vim.g.xynovim_contrast or "normal"))
  end, {
    nargs = "?",
    desc = "Island Dark contrast: normal or high (muted text lifted to 7:1)",
    complete = function()
      return { "normal", "high" }
    end,
  })

  -- hints: kinds survive a rust-analyzer (re)start
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local c = vim.lsp.get_client_by_id(args.data.client_id)
      if c and c.name == "rust-analyzer" then
        if vim.g.xynovim_hints_style == "eol" then
          -- after LazyVim's own enable on this event: take the buffer over
          vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(args.buf) then
              require("config.eolhints").enable(args.buf)
            end
          end, 300)
        end
        local st = M.hint_state()
        if not (st.types and st.params and st.lifetimes) then
          apply_client(c)
        end
      end
    end,
  })

  -- diagnostics: the cursor line changed, so the cursor-line-first text moves with it; a resize
  -- changes the room a line has. Debounced (item 11): holding j does not redraw per line.
  local timer = assert(vim.uv.new_timer())
  local pending = {}
  local function flush()
    for buf in pairs(pending) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
        pcall(vim.diagnostic.show, nil, buf)
      end
    end
    pending = {}
  end
  local function later(buf)
    pending[buf] = true
    timer:stop()
    timer:start(vim.fn.mode():find("^[iR]") and 120 or 30, 0, vim.schedule_wrap(flush))
  end
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(args)
      if M.diag_mode() ~= "cursor" then
        return
      end
      local row = vim.api.nvim_win_get_cursor(0)[1]
      if last_row[args.buf] == row then
        return
      end
      last_row[args.buf] = row
      if next(vim.diagnostic.count(args.buf)) ~= nil then
        later(args.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local b = vim.api.nvim_win_get_buf(w)
        if next(vim.diagnostic.count(b)) ~= nil then
          later(b)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      last_row[args.buf] = nil
      pending[args.buf] = nil
    end,
  })

  -- popups
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinNew", "FileType" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          M.style_popup(w)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = M.apply_signs })
  M.apply_icons()
  require("config.ui_chrome").setup()
end

return M
