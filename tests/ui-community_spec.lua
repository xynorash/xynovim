-- The UI work of docs/comparison/ui-community.md (shortlist numbers in the test names): lua/config/ui.lua,
-- lua/xynovim/term.lua, lua/island (hint legibility, state groups, high contrast), lua/plugins/{lualine,
-- ui-icons,editing-ui}.lua. Visual claims are asserted on the real UI grid of this (headless) nvim:
-- `screenstring` for the characters and `nvim__inspect_cell` for the colours the cell is drawn with, and
-- WCAG contrast is computed here from those colours, independently of lua/island.
-- Needs rust-analyzer for the hint-kind tests (they skip without it).
local H = require("xynotest.helpers")

local ui = require("config.ui")
local ux = require("config.ux")

-- ------------------------------------------------------------------ colour maths (own copy)

local function lum(hex)
  local ch = {}
  for i = 1, 3 do
    local c = tonumber(hex:sub(2 * i, 2 * i + 1), 16) / 255
    ch[i] = c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * ch[1] + 0.7152 * ch[2] + 0.0722 * ch[3]
end

local function ratio(a, b)
  local x, y = lum(a), lum(b)
  if x < y then
    x, y = y, x
  end
  return (x + 0.05) / (y + 0.05)
end

local function hex(n)
  return n and string.format("#%06x", n) or nil
end

local function hl(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

-- ------------------------------------------------------------------ the UI grid

local THEME_BG = "#1e1f22"

local function size(cols, rows)
  vim.o.columns = cols
  vim.o.lines = rows
  vim.cmd("redraw!")
end

--- The characters of a screen row, one entry per cell ("" for the 2nd half of a wide char).
local function cells(row)
  local t = {}
  for c = 1, vim.o.columns do
    t[c] = vim.fn.screenstring(row, c)
  end
  return t
end

local function row_text(row)
  return table.concat(cells(row))
end

local function screen_text()
  local t = {}
  for r = 1, vim.o.lines do
    t[r] = row_text(r)
  end
  return table.concat(t, "\n")
end

--- row, col (1-based cells) of the first occurrence of `needle` on the screen, or nil.
local function find(needle, from_row)
  for r = from_row or 1, vim.o.lines do
    local cs = cells(r)
    local s, map = {}, {}
    for c, ch in ipairs(cs) do
      for _ = 1, #ch do
        s[#s + 1] = ch
      end
      map[#map + 1] = { c, #ch }
    end
    local line = table.concat(cs)
    local at = line:find(needle, 1, true)
    if at then
      -- byte offset -> cell
      local b = 1
      for c, ch in ipairs(cs) do
        if at >= b and at < b + math.max(#ch, 0) then
          return r, c
        end
        b = b + #ch
      end
    end
  end
end

--- {char, attrs} of a screen cell of the base grid.
local function inspect(row, col)
  return vim.api.nvim__inspect_cell(1, row - 1, col - 1)
end

--- fg, bg, attrs of cell (lr, lc) (0-based, border included) of a float window. A float has a grid
--- of its own, found by its first text row (headless nvim composes floats at 0,0 on the screen, so
--- the screen position cannot be used).
local function float_colors(win, lr, lc)
  local cfg = vim.api.nvim_win_get_config(win)
  local pad = cfg.border and 1 or 0
  local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, 1, false)[1] or ""
  for g = 2, 80 do
    local same = #line > 0
    for i = 1, #line do
      local ok, res = pcall(vim.api.nvim__inspect_cell, g, pad, pad + i - 1)
      if not (ok and res[1] == line:sub(i, i)) then
        same = false
        break
      end
    end
    if same then
      local _, a = unpack(vim.api.nvim__inspect_cell(g, lr, lc))
      local normal = hl("Normal")
      return hex(a.foreground or normal.fg) or "#bcbec4", hex(a.background or normal.bg) or THEME_BG, a
    end
  end
  error("no grid for the float")
end

--- fg, bg ("#rrggbb") a cell is drawn with; unset colours resolve to the theme's Normal (a
--- transparent background is the terminal's own, the theme background is the reference).
local function colors_at(row, col)
  local _, a = unpack(inspect(row, col))
  local normal = hl("Normal")
  local fg = a.foreground or normal.fg
  local bg = a.background or normal.bg
  if a.reverse then
    fg, bg = bg, fg
  end
  return hex(fg) or "#bcbec4", hex(bg) or THEME_BG, a
end

local function eventually(pred, ms, msg)
  return H.wait_for(function()
    vim.cmd("redraw!")
    return pred()
  end, ms or 5000, msg)
end

-- ------------------------------------------------------------------ fixtures

local saved = {
  columns = vim.o.columns,
  lines = vim.o.lines,
  laststatus = vim.o.laststatus,
}

local function reset_ui()
  vim.g.xynovim_diagnostics = nil
  vim.g.xynovim_icons = nil
  vim.g.xynovim_contrast = nil
  vim.g.xynovim_hints = nil
  vim.o.columns, vim.o.lines, vim.o.laststatus = saved.columns, saved.lines, saved.laststatus
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, w)
    if ok and cfg.relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  pcall(vim.cmd, "only!")
end

after_each(reset_ui)

local function opts_of(name)
  local plugin = require("lazy.core.config").plugins[name]
  return require("lazy.core.plugin").values(plugin, "opts", false)
end

--- Scratch window with `lines` and diagnostics `defs` ({line0, severity, message, code?, source?}),
--- the diagnostic config of the real spec (nvim-lspconfig opts), everything shown.
local function with_diagnostics(lines, defs)
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.o.laststatus = 0
  local cfg = vim.deepcopy(opts_of("nvim-lspconfig").diagnostics)
  cfg.virtual_text.format = opts_of("nvim-lspconfig").diagnostics.virtual_text.format
  cfg.virtual_text.prefix = opts_of("nvim-lspconfig").diagnostics.virtual_text.prefix
  vim.diagnostic.config(cfg)
  local ns = vim.api.nvim_create_namespace("ui-community-test")
  local ds = {}
  for _, d in ipairs(defs) do
    ds[#ds + 1] = {
      lnum = d[1],
      col = 0,
      severity = d[2],
      message = d[3],
      code = d[4],
      source = d[5] or "rust-analyzer",
    }
  end
  vim.diagnostic.set(ns, buf, ds)
  vim.cmd("redraw!")
  return buf, ns
end

local E, W, I, Hh =
  vim.diagnostic.severity.ERROR,
  vim.diagnostic.severity.WARN,
  vim.diagnostic.severity.INFO,
  vim.diagnostic.severity.HINT

-- ====================================================================================================

describe("ui-community 3: inlay hint legibility", function()
  it(
    "LspInlayHint text is >= 6:1 on its chip (was 3.2:1; VS Code default 5.3:1), and still below the code text",
    function()
      local h = hl("LspInlayHint")
      local r = ratio(hex(h.fg), hex(h.bg))
      H.ok(r >= 6.0, ("hint text on chip %.2f:1"):format(r))
      H.ok(r < ratio(hl("Normal").fg and hex(hl("Normal").fg) or "#bcbec4", THEME_BG), "hints stay subordinate to code")
      H.eq(
        "#2b2d30",
        hex(h.bg),
        "the chip is the statusline bar colour: a visible chip, and 6:1 needs no code-coloured text"
      )
      H.ok(lum(hex(h.fg)) < lum(hex(hl("Normal").fg)) - 0.05, "hint text is visibly dimmer than the code text")
    end
  )

  it("code lens text is >= 4.5:1 on the editor background (was 3.7:1)", function()
    H.ok(ratio(hex(hl("LspCodeLens").fg), THEME_BG) >= 4.5)
  end)
end)

describe("ui-community 4: severity is not carried by colour alone", function()
  it("each severity has its own underline style", function()
    H.ok(hl("DiagnosticUnderlineError").undercurl)
    H.ok(hl("DiagnosticUnderlineWarn").underdashed)
    H.ok(hl("DiagnosticUnderlineInfo").underdotted)
    H.ok(hl("DiagnosticUnderlineHint").underline)
    local styles = {}
    for _, k in ipairs({ "Error", "Warn", "Info", "Hint" }) do
      local g = hl("DiagnosticUnderline" .. k)
      local key = (g.undercurl and "curl" or "")
        .. (g.underdashed and "dash" or "")
        .. (g.underdotted and "dot" or "")
        .. (g.underline and "line" or "")
      H.is_nil(styles[key], "two severities share the style " .. key)
      styles[key] = k
    end
  end)

  it("the virtual-text prefix and sign glyph differ per severity and are one cell wide (nerd and ascii)", function()
    for _, set in ipairs({ "nerd", "ascii" }) do
      vim.g.xynovim_icons = set
      local seen = {}
      for sev = 1, 4 do
        local g = ui.prefix({ severity = sev })
        H.eq(1, vim.fn.strdisplaywidth(g), set .. " glyph width for severity " .. sev)
        H.is_nil(seen[g], "duplicate glyph " .. g)
        seen[g] = true
      end
    end
    vim.g.xynovim_icons = nil
  end)

  it("the glyph is on the grid: the real virtual text starts with the severity glyph", function()
    size(100, 12)
    with_diagnostics({ "fn main() {", "    let x = 1;", "}" }, { { 1, E, "boom here" } })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eventually(function()
      return find("boom here")
    end, 3000, "virtual text")
    local r, c = find("boom here")
    H.eq("✗", vim.fn.screenstring(r, c - 2), "glyph before the text")
  end)
end)

describe("ui-community 2/10/11: cursor-line-first diagnostics, width-aware text", function()
  local lines = {
    "fn one() { let a = 1; }",
    "fn two() { let b = 2; }",
    "fn three() { let c = 3; }",
    "fn four() { let d = 4; }",
    "fn five() { let e = 5; }",
  }
  local defs = {
    { 0, E, "mismatched types: expected String, found i32", "E0308" },
    { 2, W, "unused variable: `c` (this one has quite a long explanation attached)", "unused_variables", "clippy" },
    { 3, I, "an information that is only shown on the cursor line" },
    { 4, Hh, "a hint that is only shown on the cursor line" },
  }

  it("cursor on line 3: full text there, compact Error/Warn elsewhere, Info/Hint hidden elsewhere", function()
    size(120, 12)
    with_diagnostics(lines, defs)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.cmd("doautocmd CursorMoved")
    eventually(function()
      return row_text(3):find("unused variable", 1, true)
    end, 3000, "full text on the cursor line")
    H.match(row_text(3), "unused variable: `c` (this one has quite a long explanation attached) [clippy]", true)
    H.match(row_text(1), "E0308", true, "compact code on line 1")
    H.no_match(row_text(1), "mismatched", true)
    H.no_match(row_text(4), "information", true)
    H.no_match(row_text(5), "hint that", true)
  end)

  it("moving the cursor moves the full text (debounced, no stale text)", function()
    size(120, 12)
    with_diagnostics(lines, defs)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.cmd("doautocmd CursorMoved")
    eventually(function()
      return row_text(3):find("unused variable: `c` (this", 1, true)
    end, 3000)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.cmd("doautocmd CursorMoved")
    eventually(function()
      return row_text(5):find("a hint that is only shown", 1, true)
    end, 3000, "hint on its own line")
    eventually(function()
      return not row_text(3):find("unused variable: `c` (this", 1, true)
    end, 3000, "line 3 back to compact")
    H.match(row_text(3), "unused_variables", true)
    H.no_match(row_text(4), "information", true)
  end)

  it("vim.g.xynovim_diagnostics = 'all' keeps the old behaviour, 'off' draws nothing", function()
    size(120, 12)
    with_diagnostics(lines, defs)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.g.xynovim_diagnostics = "all"
    vim.diagnostic.show()
    vim.cmd("redraw!")
    H.match(row_text(1), "mismatched types", true)
    H.match(row_text(4), "only shown on the cursor line", true)
    vim.g.xynovim_diagnostics = "off"
    vim.diagnostic.show()
    vim.cmd("redraw!")
    H.no_match(screen_text(), "mismatched", true)
  end)

  for _, w in ipairs({ 60, 80, 120, 200 }) do
    it(("at %d columns the text is cut with an ellipsis inside the window, never past it"):format(w), function()
      size(w, 12)
      local long =
        "mismatched types: expected `Vec<HashMap<String, Box<dyn Fn(i32) -> i32>>>`, found `()` and then some more words"
      with_diagnostics({ "fn f() { let v = g(1); }", "x" }, { { 0, E, long, "E0308" } })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("doautocmd CursorMoved")
      eventually(function()
        return row_text(1):find("mismatched", 1, true)
      end, 3000)
      local t = row_text(1)
      local cs = cells(1)
      local last = 0
      for c = #cs, 1, -1 do
        if cs[c] ~= " " and cs[c] ~= "" then
          last = c
          break
        end
      end
      H.ok(last <= w, "text beyond the window")
      local room = w - 8 - vim.fn.strdisplaywidth("fn f() { let v = g(1); }") - 6
      if vim.fn.strdisplaywidth(long .. " [rust-analyzer]") > room - 4 then
        H.match(t, "…", true, "ellipsis expected at " .. w)
      else
        H.no_match(t, "…", true)
      end
    end)
  end

  it("no room at all: nothing is drawn rather than a stub", function()
    size(60, 12)
    with_diagnostics({ string.rep("x", 54) }, { { 0, E, "mismatched types", "E0308" } })
    vim.cmd("redraw!")
    H.no_match(screen_text(), "mism", true)
  end)

  it("diagnostic_text of a hidden-elsewhere tier still dedupes (config.ux behaviour kept)", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x" })
    local a = vim.api.nvim_create_namespace("ui-dd-a" .. vim.uv.hrtime())
    local b = vim.api.nvim_create_namespace("ui-dd-b" .. vim.uv.hrtime())
    vim.diagnostic.set(
      a,
      buf,
      { { lnum = 0, col = 0, severity = 1, message = "oops", code = "E0308", source = "rust-analyzer" } }
    )
    vim.diagnostic.set(
      b,
      buf,
      { { lnum = 0, col = 0, severity = 1, message = "error[E0308]: oops", source = "clippy" } }
    )
    H.eq(2, #vim.diagnostic.get(buf))
    local shown = 0
    for _, d in ipairs(vim.diagnostic.get(buf)) do
      if ux.diagnostic_text(d) then
        shown = shown + 1
      end
    end
    H.eq(1, shown)
  end)
end)

describe("ui-community 1: per-kind inlay hints", function()
  it("hint_settings maps every kind to its rust-analyzer switch", function()
    local on = ui.hint_settings({ types = true, params = true, lifetimes = true })
    H.eq(true, on.typeHints.enable)
    H.eq("with_block", on.closureReturnTypeHints.enable, "the value rustaceanvim.lua sets")
    H.eq("skip_trivial", on.lifetimeElisionHints.enable)
    H.eq(true, on.parameterHints.enable)
    local off = ui.hint_settings({ types = false, params = true, lifetimes = false })
    H.eq(false, off.typeHints.enable)
    H.eq(false, off.chainingHints.enable)
    H.eq("never", off.closureReturnTypeHints.enable)
    H.eq(true, off.parameterHints.enable)
    H.eq("never", off.lifetimeElisionHints.enable)
  end)

  it("a fake client gets the settings and a didChangeConfiguration", function()
    local sent
    local client = {
      settings = { ["rust-analyzer"] = { inlayHints = { lifetimeElisionHints = { useParameterNames = true } } } },
      notify = function(_, method)
        sent = method
      end,
    }
    local real = vim.lsp.get_clients
    vim.lsp.get_clients = function()
      return { client }
    end
    vim.g.xynovim_hints = { params = false }
    local ok, err = pcall(ui.apply_hints)
    vim.lsp.get_clients = real
    H.ok(ok, err)
    H.eq("workspace/didChangeConfiguration", sent)
    local ih = client.settings["rust-analyzer"].inlayHints
    H.eq(false, ih.parameterHints.enable)
    H.eq(true, ih.typeHints.enable)
    H.eq(true, ih.lifetimeElisionHints.useParameterNames, "other settings are kept")
  end)

  it(":Hints rejects unknown arguments and reports state", function()
    H.match(ui.hints("bogus"), "unknown argument", true)
    H.match(ui.hints("status"), "types on, params on, lifetimes on", true)
  end)

  it(
    "statusline text: empty when everything is default and narrow, hints TPL when wide, letters of off kinds go",
    function()
      local b = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(b)
      vim.bo[b].filetype = "rust"
      vim.lsp.inlay_hint.enable(true, { bufnr = b })
      H.eq("", ui.hints_status(80))
      H.eq("hints TPL", ui.hints_status(120))
      vim.g.xynovim_hints = { params = false }
      H.eq("hints T-L", ui.hints_status(80))
      vim.lsp.inlay_hint.enable(false, { bufnr = b })
      H.eq("hints off", ui.hints_status(60))
      vim.bo[b].filetype = "text"
      H.eq("", ui.hints_status(200))
    end
  )

  describe("on the real grid, with rust-analyzer", function()
    local buf
    local LT = "'self" -- the lifetime hint rust-analyzer draws on `&self` (useParameterNames)
    local SRC = {
      "use basic::{answer, Shape, Square};",
      "fn add(a: i32, b: i32) -> i32 { a + b }",
      "fn two(a: &str, b: &str) { let _ = (a, b); }",
      "struct Holder(String);",
      "impl Holder { fn pick(&self, other: &str) -> &str { if other.is_empty() { &self.0 } else { other } } }",
      "fn main() {",
      "    let n = answer();",
      "    let s = add(1, 2);",
      '    two("x", "y");',
      '    let _ = Holder(String::new()).pick("z");',
      '    println!("{} {} {}", n, s, Square(2.0).area());',
      "}",
    }

    local function start()
      H.need_rust()
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_set_current_buf(buf)
        return buf
      end
      local _, b = H.open_fixture("basic", "src/main.rs", { git = true })
      buf = b
      H.wait_lsp("rust-analyzer", buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, SRC)
      vim.lsp.inlay_hint.enable(true, { bufnr = buf })
      vim.o.laststatus = 0
      size(120, 20)
      H.wait_for(function()
        vim.cmd("redraw!")
        return find("let n: i32")
      end, 90000, "type hints on the screen")
      return buf
    end

    it("all kinds show: type, parameter and lifetime hints, and the hint chip is >= 4.5:1 as drawn", function()
      start()
      eventually(function()
        return find(LT) and find("add(a: 1") and find("let n: i32")
      end, 30000, "all three kinds of hints")
      local r, c = find("n: i32")
      local fg, bg = colors_at(r, c + 1) -- the colon: part of the hint chip
      H.ok(ratio(fg, bg) >= 6.0, ("drawn hint %s on %s = %.2f:1"):format(fg, bg, ratio(fg, bg)))
    end)

    --- wait until the screen shows exactly these kinds (and keeps showing them 0.4 s later:
    --- a refresh clears the hints for a moment, which must not count as "removed")
    local function shows(t, p, l, what)
      local function now()
        vim.cmd("redraw!")
        return (find("let n: i32") ~= nil) == t and (find("add(a: 1") ~= nil) == p and (find(LT) ~= nil) == l
      end
      H.wait_for(function()
        if now() then
          vim.wait(400)
          return now()
        end
      end, 40000, what)
    end

    it(":Hints types / params / lifetimes remove exactly their own kind", function()
      start()
      shows(true, true, true, "all kinds at the start")
      ui.hints("types")
      shows(false, true, true, "type hints gone, the rest stays")
      H.match(ui.hints("status"), "types off, params on, lifetimes on", true)
      ui.hints("types")
      shows(true, true, true, "type hints back")

      ui.hints("params")
      shows(true, false, true, "parameter hints gone, the rest stays")
      ui.hints("params")
      shows(true, true, true, "parameter hints back")

      ui.hints("lifetimes")
      shows(true, true, false, "lifetime hints gone, the rest stays")
      ui.hints("lifetimes")
      shows(true, true, true, "lifetime hints back")
    end)

    it(":Hints off hides everything in this buffer, :Hints on restores all kinds", function()
      start()
      ui.hints("off")
      shows(false, false, false, "no hints")
      ui.hints("on")
      shows(true, true, true, "all hints back")
    end)
  end)
end)

describe("ui-community 9: icon fallback", function()
  it("auto picks ascii only where glyphs are impossible", function()
    H.eq("nerd", ui.icon_mode({ term = "xterm-ghostty", lang = "en_US.UTF-8" }))
    H.eq("ascii", ui.icon_mode({ term = "linux", lang = "en_US.UTF-8" }))
    H.eq("ascii", ui.icon_mode({ term = "dumb", lang = "en_US.UTF-8" }))
    H.eq("ascii", ui.icon_mode({ term = "xterm-256color", lang = "de_DE.ISO-8859-1" }))
    H.eq("nerd", ui.icon_mode({ term = "xterm-256color", lang = "C.UTF-8" }))
    H.eq("ascii", ui.icon_mode({ icons = "ascii", term = "xterm-ghostty", lang = "en_US.UTF-8" }), "the switch wins")
    H.eq("nerd", ui.icon_mode({ icons = "nerd", term = "linux", lang = "C" }), "the switch wins")
  end)

  it("font detection: Nerd Font names are recognised, others give the hint", function()
    H.ok(
      ui.has_nerd_font(
        "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Bold.ttf: JetBrainsMono Nerd Font Mono,JetBrainsMono NFM:style=Bold"
      )
    )
    H.ok(ui.has_nerd_font("Symbols Nerd Font Mono"))
    H.not_ok(ui.has_nerd_font("DejaVu Sans Mono\nNoto Sans Symbols"))
    H.is_nil(ui.font_hint("JetBrainsMono Nerd Font"))
    local hint = H.ok(ui.font_hint("DejaVu Sans Mono"))
    H.match(hint, ":XynoIcons ascii", true)
  end)

  it("ascii: LazyVim's icon table, signs and mini.icons switch, nerd restores them", function()
    local before = vim.deepcopy(LazyVim.config.icons.diagnostics)
    vim.g.xynovim_icons = "ascii"
    ui.apply_icons()
    H.eq("E ", LazyVim.config.icons.diagnostics.Error)
    H.eq("+", LazyVim.config.icons.git.added)
    H.eq("x", vim.diagnostic.config().signs.text[E])
    if package.loaded["mini.icons"] then
      H.eq("ascii", MiniIcons.config.style)
    end
    local ascii_only = true
    for _, v in pairs(LazyVim.config.icons.diagnostics) do
      ascii_only = ascii_only and not v:find("[\128-\255]")
    end
    H.ok(ascii_only, "diagnostic icons are plain ASCII")
    vim.g.xynovim_icons = "nerd"
    ui.apply_icons()
    H.eq(before, LazyVim.config.icons.diagnostics)
    H.eq("✗", vim.diagnostic.config().signs.text[E])
  end)

  it("the sign shows the glyph on the grid (ascii: 'x', nerd: the shape)", function()
    size(80, 10)
    with_diagnostics({ "let a = 1;", "let b = 2;" }, { { 0, E, "e" }, { 1, W, "w" } })
    vim.o.signcolumn = "yes:1"
    vim.wo.statuscolumn = "" -- snacks' statuscolumn lays signs out itself
    vim.g.xynovim_icons = "ascii"
    ui.apply_signs()
    vim.cmd("redraw!")
    local ra = find("let a = 1;")
    H.match(row_text(ra):sub(1, 10), "x", true)
    H.match(row_text(ra + 1):sub(1, 10), "!", true)
    vim.g.xynovim_icons = "nerd"
    ui.apply_signs()
    vim.cmd("redraw!")
    H.match(row_text(ra):sub(1, 14), "✗", true)
    H.match(row_text(ra + 1):sub(1, 14), "▲", true)
  end)

  it(
    "a child nvim with XYNOVIM_ICONS=ascii builds ascii dashboard keys, bufferline, tree and lualine separators",
    function()
      H.need_posix("runs a child nvim")
      local script = [[
      local function opts_of(name)
        local p = require("lazy.core.config").plugins[name]
        return require("lazy.core.plugin").values(p, "opts", false)
      end
      local d = opts_of("snacks.nvim").dashboard.preset
      local out = {}
      out[#out + 1] = "header=" .. d.header:gsub("\n", "|")
      out[#out + 1] = "key=" .. d.keys[1].icon
      out[#out + 1] = "bl=" .. tostring(opts_of("bufferline.nvim").options.show_buffer_icons)
      out[#out + 1] = "nt=" .. opts_of("neo-tree.nvim").default_component_configs.icon.folder_closed
      out[#out + 1] = "mode=" .. require("config.ui").icon_mode()
      io.stdout:write(table.concat(out, "\n") .. "\nDONE\n")
      vim.cmd("qa!")
    ]]
      local path = H.tmpdir() .. "/child.lua"
      local f = assert(io.open(path, "w"))
      f:write(script)
      f:close()
      local r = vim
        .system({ vim.v.progpath, "--headless", "-S", path }, {
          text = true,
          env = { XYNOVIM_ICONS = "ascii" },
          stdin = false,
        })
        :wait(60000)
      local out = (r.stdout or "") .. (r.stderr or "")
      H.match(out, "DONE", true, out)
      H.match(out, "header= x y n o v i m|", true)
      H.match(out, "key=> ", true)
      H.match(out, "bl=false", true)
      H.match(out, "nt=+", true)
      H.match(out, "mode=ascii", true)
    end
  )
end)

describe("ui-community 12: dashboard branding", function()
  it("the preset header is xynovim's, not the LazyVim banner", function()
    local preset = opts_of("snacks.nvim").dashboard.preset
    H.match(preset.header, "Rust in Neovim, sandboxed by default", true)
    H.no_match(preset.header, "██╗", true)
    H.no_match(preset.header, "LazyVim", true)
    for line in preset.header:gmatch("[^\n]+") do
      H.ok(vim.fn.strdisplaywidth(line) <= 40, "header line wider than 40 cells")
    end
  end)

  it("on the grid at 60/80/120/200 columns: whole, centred, banner above the tagline", function()
    size(80, 40)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local ok, err = pcall(Snacks.dashboard.open, { buf = buf, win = vim.api.nvim_get_current_win() })
    H.ok(ok, tostring(err))
    local tagline = "Rust in Neovim, sandboxed by default"
    for _, w in ipairs({ 60, 80, 120, 200 }) do
      size(w, 40)
      eventually(function()
        local r, c = find("Rust in Neovim")
        return r and (c - 1) - (w - (c + vim.fn.strdisplaywidth(tagline) - 1)) <= 2
      end, 5000, "dashboard drawn at " .. w)
      local r, c = find("Rust in Neovim")
      H.ok(c >= 1 and c + vim.fn.strdisplaywidth(tagline) - 1 <= w, "tagline inside the window at " .. w)
      local right = w - (c + vim.fn.strdisplaywidth(tagline) - 1)
      H.ok(math.abs((c - 1) - right) <= 2, ("tagline off-centre at %d: left %d right %d"):format(w, c - 1, right))
      local br = find("▀▄▄▀")
      H.ok(br and br < r, "banner glyph row above the tagline at " .. w)
      H.ok(find("Find File"), "entries still shown at " .. w)
    end
    vim.cmd("enew")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)

describe("ui-community 7: transparency and float regression", function()
  local function float()
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "float-one", "float-two" })
    local w = vim.api.nvim_open_win(
      b,
      false,
      { relative = "editor", row = 3, col = 10, width = 12, height = 2, border = "rounded", style = "minimal" }
    )
    vim.cmd("redraw!")
    return w
  end

  it("winborder is rounded and a plain float draws exactly one border (no doubled border)", function()
    H.eq("rounded", vim.o.winborder)
    size(80, 14)
    vim.cmd("only!")
    float()
    local r, c = find("╭")
    H.ok(r and c, "rounded corner on the grid")
    H.eq("─", vim.fn.screenstring(r, c + 1))
    H.eq(
      "flo",
      vim.fn.screenstring(r + 1, c + 1) .. vim.fn.screenstring(r + 1, c + 2) .. vim.fn.screenstring(r + 1, c + 3),
      "content directly inside the border"
    )
    H.eq("│", vim.fn.screenstring(r + 1, c))
    H.ok(not find("╭", r + 1), "only one corner pair")
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        vim.api.nvim_win_close(w, true)
      end
    end
  end)

  for _, transparent in ipairs({ true, false }) do
    it(
      ("transparent=%s: the editor is %s, floats stay solid, the dashboard statusline row is not an empty block"):format(
        tostring(transparent),
        transparent and "see-through" or "solid"
      ),
      function()
        size(80, 14)
        vim.g.xynovim_transparent = transparent
        vim.cmd.colorscheme("island-dark")
        local b = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(b)
        vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello" })
        vim.cmd("redraw!")
        local _, _, a = colors_at(5, 40) -- an empty cell, not on the cursor line
        -- the UI's default background is Normal's: unset (the terminal's own) or the theme's
        if transparent then
          H.is_nil(hl("Normal").bg, "Normal has no background: the terminal's shows")
          H.is_nil(a.background, "the cell is drawn with the default (terminal) background")
        else
          H.eq(0x1e1f22, hl("Normal").bg)
        end
        -- float: always the theme's popup background
        local w = float()
        local _, fbg, fa = float_colors(w, 1, 2)
        H.eq(hex(hl("NormalFloat").bg), fbg)
        H.ok(fa.background, "float cell has a background")
        vim.api.nvim_win_close(w, true)
        -- statusline of the dashboard filetype: lualine is off there; StatusLine must still be a defined block
        H.ok(hl("StatusLine").bg, "StatusLine keeps its colour")
        vim.g.xynovim_transparent = nil
        vim.cmd.colorscheme("island-dark")
      end
    )
  end
end)

describe("ui-community 8: narrow-window statusline", function()
  local dir, file
  local function open()
    if not dir then
      local d = H.tmpdir()
      vim.fn.mkdir(d .. "/some/deeply/nested/folder", "p")
      file = d .. "/some/deeply/nested/folder/important_notes.txt"
      vim.fn.writefile({ "alpha", "beta" }, file)
      H.git_init(d)
      vim.fn.writefile({ "alpha", "beta", "gamma" }, file) -- a change: the diff component has something to show
      dir = d
    end
    vim.cmd.cd(vim.fn.fnameescape(dir))
    H.open(file)
    vim.o.laststatus = 3
    vim.cmd("redraw!")
  end

  local function status_row()
    return row_text(vim.o.lines - vim.o.cmdheight)
  end

  for _, w in ipairs({ 60, 80, 120, 200 }) do
    it(("at %d columns the file name is whole and nothing is cut with a '<' stub"):format(w), function()
      open()
      size(w, 14)
      vim.cmd("doautocmd VimResized")
      vim.wait(300)
      eventually(function()
        return status_row():find("important_notes.txt", 1, true)
      end, 5000, "file name in the statusline")
      local s = status_row()
      H.match(s, "important_notes.txt", true)
      H.no_match(s, "<", true)
    end)
  end

  it("components drop in priority order as the window narrows", function()
    open()
    local function status_at(w)
      size(w, 14)
      vim.cmd("doautocmd VimResized") -- what a real terminal sends; lualine refreshes on it
      vim.wait(300)
      vim.cmd("redraw!")
      return eventually(function()
        return status_row():find("important_notes", 1, true) and status_row()
      end, 5000)
    end
    local s200, s120, s100, s80, s60 = status_at(200), status_at(120), status_at(100), status_at(80), status_at(60)
    local clock = "%d%d:%d%d"
    H.ok(s200:find(clock), "clock at 200")
    H.ok(s120:find(clock), "clock at 120")
    H.not_ok(s100:find(clock), "clock gone at 100")
    H.ok(s100:find("Top") or s100:find("All") or s100:find("%d+%%"), "progress still at 100")
    H.not_ok(s80:find("Top") or s80:find("All") or s80:find("%d+%%"), "progress gone at 80")
    H.ok(s80:find("1:1") or s80:find("1:%d"), "location still at 80")
    H.not_ok(s60:find("1:1"), "location gone at 60")
    -- the mode shrinks to a letter at 60, is whole above
    H.match(s80, "NORMAL", true)
    H.no_match(s60, "NORMAL", true)
    H.match(s60, "N", true)
    -- the path in front of the name shrinks, the name stays
    H.match(s200, "folder/important_notes.txt", true)
    H.no_match(s60, "nested/", true)
  end)

  it("the sandbox / guard / history components say nothing when there is nothing to say, and use words", function()
    open()
    size(200, 14)
    local s = status_row()
    H.no_match(s, "sandbox", true, "sandbox not loaded: nothing in the statusline")
    H.no_match(s, "guard", true)
    H.no_match(s, "history", true)
    -- guard: a buffer the guard paused
    vim.b.xyno_guard_warned = "gone"
    local text, group = ui.guard_status(200)
    H.eq("guard: auto-save paused", text)
    H.eq("XynoStatusWarn", group)
    H.eq("guard!", (ui.guard_status(79)))
    eventually(function()
      return status_row():find("guard: auto-save paused", 1, true)
    end, 3000, "guard in the statusline on the grid")
    vim.b.xyno_guard_warned = nil
    -- history
    package.loaded["xyno_history"] = {
      status = function()
        return { ["/r"] = { failing = { reason = "x", n = 1, time = 0 } } }
      end,
    }
    H.eq("history: failing", (ui.history_status(200)))
    H.eq("hist!", (ui.history_status(79)))
    package.loaded["xyno_history"] = nil
    H.eq("", (ui.history_status(200)))
    -- sandbox
    package.loaded["xyno_sandbox"] = {
      statusline = function()
        return "sandbox: OFF"
      end,
      statusline_hl = function()
        return "DiagnosticWarn"
      end,
    }
    local t, g = ui.sandbox_status(200)
    H.eq("sandbox: OFF", t)
    H.eq("XynoStatusWarn", g)
    H.eq("sb OFF", (ui.sandbox_status(79)))
    package.loaded["xyno_sandbox"] = nil
  end)

  it("state groups say OFF/failing in bold and are >= 4.5:1 on the statusline background", function()
    local bg = hex(hl("StatusLine").bg)
    for _, g in ipairs({ "XynoStatusOk", "XynoStatusWarn", "XynoStatusError", "XynoStatusMuted", "XynoStatusBusy" }) do
      local r = ratio(hex(hl(g).fg), bg)
      H.ok(r >= 4.5, ("%s %.2f:1 on the statusline"):format(g, r))
    end
    H.ok(hl("XynoStatusError").bold and hl("XynoStatusWarn").bold, "problem states are bold, not only coloured")
  end)
end)

describe("ui-community: popup highlight groups (sandbox, history, guard, macros)", function()
  it("the Xyno popup groups exist and every text group is >= 4.5:1 on the popup background", function()
    local bg = hex(hl("XynoPopupNormal").bg)
    H.eq(hex(hl("NormalFloat").bg), bg, "same surface as other floats")
    for _, g in ipairs({
      "XynoPopupNormal",
      "XynoPopupTitle",
      "XynoPopupFooter",
      "XynoPopupKey",
      "XynoPopupMuted",
      "XynoPopupWarn",
      "XynoPopupDanger",
    }) do
      local r = ratio(hex(hl(g).fg), bg)
      H.ok(r >= 4.5, ("%s %.2f:1"):format(g, r))
    end
    H.ok(ratio(hex(hl("XynoPopupBorder").fg), bg) >= 3, "border >= 3:1 (non-text)")
  end)

  for ft in pairs(ui.POPUP_FILETYPES) do
    it(ft .. " floats are drawn with the Xyno groups on the grid", function()
      size(100, 20)
      local b = vim.api.nvim_create_buf(false, true)
      vim.bo[b].filetype = ft
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "popup body" })
      local w = vim.api.nvim_open_win(b, true, {
        relative = "editor",
        row = 4,
        col = 10,
        width = 30,
        height = 1,
        border = "rounded",
        title = " Title ",
        footer = " q close ",
        footer_pos = "center",
        style = "minimal",
      })
      eventually(function()
        return vim.wo[w].winhighlight:find("XynoPopupBorder", 1, true)
      end, 3000, "winhighlight")
      vim.cmd("redraw!")
      local fg, bg = float_colors(w, 1, 3) -- the 2nd letter of the body: not the cursor cell
      H.eq(hex(hl("XynoPopupNormal").fg), fg)
      H.eq(hex(hl("XynoPopupNormal").bg), bg)
      local tfg = float_colors(w, 0, 3) -- "T" of the title
      H.eq(hex(hl("XynoPopupTitle").fg), tfg)
      H.eq(hex(hl("XynoPopupBorder").fg), (float_colors(w, 0, 0)))
      H.eq(hex(hl("XynoPopupBorder").fg), (float_colors(w, 1, 0)))
      vim.api.nvim_win_close(w, true)
    end)
  end

  it("a float of another filetype is left alone", function()
    local b = vim.api.nvim_create_buf(false, true)
    local w = vim.api.nvim_open_win(
      b,
      false,
      { relative = "editor", row = 1, col = 1, width = 5, height = 1, border = "rounded" }
    )
    H.not_ok(ui.style_popup(w))
    H.eq("", vim.wo[w].winhighlight)
    vim.api.nvim_win_close(w, true)
  end)
end)

describe("ui-community 6: high-contrast variant", function()
  after_each(function()
    vim.g.xynovim_contrast = nil
    vim.cmd.colorscheme("island-dark")
  end)

  it("normal: comments, line numbers and hints keep the shipped tones", function()
    vim.g.xynovim_contrast = nil
    vim.cmd.colorscheme("island-dark")
    H.ok(ratio(hex(hl("Comment").fg), THEME_BG) < 7, "normal Comment is below 7:1")
  end)

  it("high: every listed muted group is >= 7:1 on its own background", function()
    vim.g.xynovim_contrast = "high"
    vim.cmd.colorscheme("island-dark")
    for _, g in ipairs(require("island").HIGH_CONTRAST_GROUPS) do
      local h = hl(g)
      if h.fg then
        local r = ratio(hex(h.fg), h.bg and hex(h.bg) or THEME_BG)
        H.ok(r >= 7, ("%s %.2f:1"):format(g, r))
      end
    end
  end)

  it("high: syntax colours are untouched, :IslandContrast switches both ways", function()
    local kw = hl("Keyword").fg
    vim.cmd("IslandContrast high")
    H.eq("high", vim.g.xynovim_contrast)
    H.eq(kw, hl("Keyword").fg)
    local on_grid = ratio(hex(hl("LineNr").fg), THEME_BG)
    H.ok(on_grid >= 7)
    vim.cmd("IslandContrast normal")
    H.ok(ratio(hex(hl("LineNr").fg), THEME_BG) < 7)
  end)

  it("high: line numbers are drawn >= 7:1 on the grid", function()
    size(60, 8)
    vim.g.xynovim_contrast = "high"
    vim.cmd.colorscheme("island-dark")
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "a", "b", "c" })
    vim.wo.number = true
    vim.wo.cursorline = false
    vim.cmd("redraw!")
    local fg, bg = colors_at(2, 2)
    H.ok(ratio(fg, bg) >= 7, ("line number %.2f:1"):format(ratio(fg, bg)))
  end)
end)

describe("ui-community 5: terminal compatibility check", function()
  local term = require("xynovim.term")
  local function levels(r)
    local t = {}
    for _, x in ipairs(r) do
      t[#t + 1] = x.level .. ": " .. x.msg
    end
    return table.concat(t, "\n")
  end
  local function find_item(r, pat)
    for _, x in ipairs(r) do
      if x.msg:find(pat) then
        return x
      end
    end
  end

  it("Ghostty outside tmux: truecolor, curly and coloured underlines are fine", function()
    local r = term.diagnose({
      vars = { TERM = "xterm-ghostty", COLORTERM = "truecolor", GHOSTTY_RESOURCES_DIR = "/x", XYNOVIM_ICONS = "nerd" },
      infocmp = "xterm-ghostty|ghostty, Smulx=\\E[4:%p1%dm, Setulc=\\E[58:2::%p1%d,",
      ghostty_config = "\nfont-size = 12\n",
    })
    H.ok(find_item(r, "^truecolor: COLORTERM"), levels(r))
    H.eq("ok", find_item(r, "^underlines").level)
    H.eq("ok", find_item(r, "^Ghostty").level)
  end)

  it("Ghostty minimum-contrast > 1 warns and names the fix", function()
    local r = term.diagnose({
      vars = { TERM = "xterm-ghostty", COLORTERM = "truecolor", XYNOVIM_ICONS = "nerd" },
      infocmp = "Smulx Setulc",
      ghostty_config = "\nminimum-contrast = 4.5\n",
    })
    local x = find_item(r, "minimum%-contrast")
    H.eq("warn", x.level, levels(r))
    H.match(x.msg, "4.5", true)
    H.match(x.fix, "minimum-contrast = 1", true)
  end)

  it("tmux without overrides warns about truecolor and underlines and prints the exact lines", function()
    local r = term.diagnose({
      vars = { TERM = "tmux-256color", TMUX = "/tmp/tmux-1/default,1,0", XYNOVIM_ICONS = "nerd" },
      infocmp = "tmux-256color, colors#0x100,",
      tmux = "terminal-overrides[0] xterm*:XT\n",
    })
    local tc = find_item(r, "^truecolor")
    H.eq("warn", tc.level)
    H.match(table.concat(tc.fix, "\n"), "terminal-features ',*:RGB'", true)
    local ul = find_item(r, "^underlines")
    H.eq("warn", ul.level)
    H.match(table.concat(ul.fix, "\n"), "Smulx", true)
    H.match(table.concat(ul.fix, "\n"), "Setulc", true)
  end)

  it("tmux with RGB and usstyle is clean", function()
    local r = term.diagnose({
      vars = { TERM = "tmux-256color", TMUX = "/tmp/x,1,0", XYNOVIM_ICONS = "nerd" },
      infocmp = "",
      tmux = "terminal-features[0] xterm*:RGB:usstyle\n",
    })
    H.eq("ok", find_item(r, "^truecolor").level, levels(r))
    H.eq("ok", find_item(r, "^underlines").level, levels(r))
  end)

  it("WezTerm and kitty get their notes; the Linux console warns and switches icons", function()
    local w = term.diagnose({
      vars = { TERM = "xterm-256color", COLORTERM = "truecolor", WEZTERM_EXECUTABLE = "/w", XYNOVIM_ICONS = "nerd" },
      infocmp = "",
    })
    H.match(find_item(w, "^WezTerm").msg, "wezterm.terminfo", true)
    H.eq("warn", find_item(w, "^underlines").level)
    local k = term.diagnose({
      vars = { TERM = "xterm-kitty", COLORTERM = "truecolor", KITTY_WINDOW_ID = "1", XYNOVIM_ICONS = "nerd" },
      infocmp = "Smulx Setulc",
    })
    H.match(find_item(k, "^kitty").msg, "full support", true)
    local l = term.diagnose({ vars = { TERM = "linux", LANG = "en_US.UTF-8" }, infocmp = "" })
    H.eq("warn", find_item(l, "^TERM=linux").level)
    H.match(find_item(l, "^icons").msg, "plain text", true)
  end)

  it("icons: no Nerd Font on the system warns with the switch; a Nerd Font is ok", function()
    local no = term.diagnose({
      vars = { TERM = "xterm-256color", COLORTERM = "truecolor", XYNOVIM_ICONS = "nerd" },
      infocmp = "Smulx Setulc",
      fonts = "DejaVu Sans Mono",
    })
    H.eq("warn", find_item(no, "^icons").level)
    H.match(find_item(no, "^icons").msg, ":XynoIcons ascii", true)
    local yes = term.diagnose({
      vars = { TERM = "xterm-256color", COLORTERM = "truecolor", XYNOVIM_ICONS = "nerd" },
      infocmp = "Smulx Setulc",
      fonts = "JetBrainsMono Nerd Font Mono",
    })
    H.eq("ok", find_item(yes, "^icons").level)
  end)

  it(":checkhealth xynovim has the terminal section (report() runs against the real environment)", function()
    local seen = {}
    local real = {}
    for _, k in ipairs({ "start", "ok", "warn", "info", "error" }) do
      real[k] = vim.health[k]
      vim.health[k] = function(msg)
        seen[#seen + 1] = k .. ": " .. tostring(msg)
      end
    end
    local ok, err = pcall(term.report)
    for k, f in pairs(real) do
      vim.health[k] = f
    end
    H.ok(ok, err)
    H.eq("start: xynovim: terminal", seen[1])
    H.ok(#seen >= 4, "at least terminal, truecolor, underlines, icons")
    local src = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/xynovim/health.lua"), "\n")
    H.match(src, 'require("xynovim.term").report()', true)
  end)
end)
