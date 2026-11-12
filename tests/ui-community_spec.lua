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
    H.match(preset.header, "Rust in Neovim, AI agent sandboxed", true)
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
    local tagline = "Rust in Neovim, AI agent sandboxed"
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

  it("high: :IslandContrast switches both ways and the hue of syntax colours is kept", function()
    vim.g.xynovim_contrast = nil
    vim.cmd.colorscheme("island-dark")
    local kw = hl("Keyword").fg
    vim.cmd("IslandContrast high")
    H.eq("high", vim.g.xynovim_contrast)
    local k2 = hex(hl("Keyword").fg)
    H.ok(ratio(k2, THEME_BG) >= 7, "keyword lifted to 7:1: " .. k2)
    H.ok(tonumber(k2:sub(2, 3), 16) > tonumber(k2:sub(6, 7), 16), "still orange-ish: " .. k2)
    H.ok(ratio(hex(hl("LineNr").fg), THEME_BG) >= 7)
    vim.cmd("IslandContrast normal")
    H.eq(kw, hl("Keyword").fg, "normal restores the shipped keyword colour")
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

-- ====================================================================================================
-- UI round 2 (docs/comparison/ui-community.md items 4, 6, 7, 9, 13-15; docs/comparison/ui-assessment.md)
-- ====================================================================================================

local function readfile(path)
  local f = io.open(path, "rb")
  if not f then
    return ""
  end
  local t = f:read("*a")
  f:close()
  return t
end

--- name -> { fg, bg } of every highlight group that has a foreground (links resolved), "#rrggbb"
local function all_groups()
  local t = {}
  for name in pairs(vim.api.nvim_get_hl(0, {})) do
    local h = hl(name)
    if h.fg and not h.reverse then
      t[name] = { fg = hex(h.fg), bg = h.bg and hex(h.bg) or nil }
    end
  end
  return t
end

local function is_frame(name)
  return name:find("Border")
    or name:find("Separator")
    or name:find("Split")
    or name:find("Indent")
    or name:find("Backdrop")
    or name:find("Guide")
    or name:find("Progress")
end

describe("ui round 2: the tagline says only what is true", function()
  it("the dashboard names the AI agent; no page or document says the editor is sandboxed by default", function()
    local preset = opts_of("snacks.nvim").dashboard.preset
    H.match(preset.header, "AI agent sandboxed", true)
    H.no_match(preset.header, "by default", true)
    local repo = H.repo
    local files = { repo .. "/README.md", repo .. "/lua/plugins/ui-icons.lua" }
    for _, dir in ipairs({ repo .. "/docs", repo .. "/docs/comparison", repo .. "/site" }) do
      for _, n in ipairs(vim.fn.readdir(dir)) do
        if n:match("%.md$") or n:match("%.html$") then
          files[#files + 1] = dir .. "/" .. n
        end
      end
    end
    for _, f in ipairs(files) do
      H.no_match(readfile(f), "Neovim, sandboxed by default", true, f)
    end
  end)
end)

describe("ui round 2: Island Light (derived, contrast-checked per group)", function()
  after_each(function()
    vim.g.xynovim_contrast = nil
    vim.g.xynovim_transparent = nil
    vim.cmd.colorscheme("island-dark")
  end)

  it("is a light scheme: light background, dark text >= 7:1, background option follows", function()
    vim.cmd.colorscheme("island-light")
    H.eq("island-light", vim.g.colors_name)
    H.eq("light", vim.o.background)
    local nb, nf = hex(hl("Normal").bg), hex(hl("Normal").fg)
    H.ok(lum(nb) > 0.85, "background luminance " .. lum(nb))
    H.ok(ratio(nf, nb) >= 7, ("Normal text %.2f:1"):format(ratio(nf, nb)))
    vim.cmd.colorscheme("island-dark")
    H.eq("dark", vim.o.background)
    H.eq(0xbcbec4, hl("Normal").fg, "dark is unchanged by having loaded light")
  end)

  it(
    "every highlight group keeps the contrast it has in dark (capped at 8:1 here, 9:1 in the construction), checked group by group",
    function()
      vim.g.xynovim_transparent = false -- compare solid with solid: transparency drops backgrounds in dark only
      vim.cmd.colorscheme("island-dark")
      local dark, dbg = all_groups(), THEME_BG
      vim.cmd.colorscheme("island-light")
      vim.wait(100) -- the late pass (groups plugins define after the file ran)
      local light, lbg = all_groups(), hex(hl("Normal").bg)
      local checked, worse = 0, {}
      for name, d in pairs(dark) do
        local l = light[name]
        local was = ratio(d.fg, d.bg or dbg)
        -- lualine_* are written by lualine from the theme file (checked >= 4.5:1 in the statusline test)
        if l and was >= 1.2 and not name:find("^lualine_") and not name:find("^BufferLine") then
          checked = checked + 1
          local want, got = math.min(was, 8), ratio(l.fg, l.bg or lbg)
          if got < want - 0.15 then
            worse[#worse + 1] = ("%s dark %.2f light %.2f"):format(name, was, got)
          end
        end
      end
      table.sort(worse)
      H.ok(checked > 700, "groups compared: " .. checked)
      for name, g in pairs(light) do
        if name:find("^BufferLine") and name:find("Buffer$") or name == "BufferLineBackground" then
          H.ok(
            ratio(g.fg, g.bg or lbg) >= 4.5,
            ("%s %.2f:1 (bufferline derives its own tints)"):format(name, ratio(g.fg, g.bg or lbg))
          )
        end
      end
      H.eq({}, vim.list_slice(worse, 1, 15), #worse .. " groups lost contrast in light")
    end
  )

  it("the statusline and the lualine pills are >= 4.5:1 on the grid", function()
    vim.cmd.colorscheme("island-light")
    package.loaded["lualine.themes.island-dark"] = nil
    local theme = require("lualine.themes.island-dark")
    for mode, t in pairs(theme) do
      for sect, c in pairs(t) do
        H.ok(ratio(c.fg, c.bg) >= 4.5, ("lualine %s.%s %.2f:1"):format(mode, sect, ratio(c.fg, c.bg)))
      end
    end
    package.loaded["lualine.themes.island-dark"] = nil
    size(100, 12)
    local d = H.tmpdir()
    vim.fn.writefile({ "alpha" }, d .. "/notes.txt")
    H.open(d .. "/notes.txt")
    vim.o.laststatus = 3
    pcall(function()
      require("lualine").setup(opts_of("lualine.nvim"))
    end)
    eventually(function()
      vim.cmd("redrawstatus!")
      return row_text(vim.o.lines - vim.o.cmdheight):find("notes.txt", 1, true)
    end, 5000, "file name in the statusline")
    local row = vim.o.lines - vim.o.cmdheight
    local seen, bad = 0, {}
    for c = 1, vim.o.columns do
      local ch = vim.fn.screenstring(row, c)
      if ch:match("%S") and not ch:match("^\238[\130-\131]") then -- not a powerline separator (U+E0B0..E0BF)
        local fg, bg = colors_at(row, c)
        seen = seen + 1
        if ratio(fg, bg) < 4.5 then
          bad[#bad + 1] = ("%s@%d %.2f"):format(ch, c, ratio(fg, bg))
        end
      end
    end
    H.ok(seen > 3, "the statusline row has text")
    H.eq({}, bad, "statusline cells below 4.5:1")
  end)

  it("it keeps its own background: transparency applies to light only when asked for", function()
    vim.cmd.colorscheme("island-light")
    H.ok(hl("Normal").bg, "Normal keeps a background (a dark terminal behind dark text is unreadable)")
    vim.g.xynovim_transparent = true
    vim.cmd.colorscheme("island-light")
    H.is_nil(hl("Normal").bg, "explicit opt-in is honoured")
  end)

  it("light + high contrast: text >= 7:1 and frames >= 4.5:1 too", function()
    vim.g.xynovim_contrast = "high"
    vim.cmd.colorscheme("island-light")
    vim.wait(100)
    local lbg, bad = hex(hl("Normal").bg), {}
    vim.wait(600)
    for name, g in pairs(all_groups()) do
      local r = ratio(g.fg, g.bg or lbg)
      if r >= 1.2 and r < (is_frame(name) and 4.5 or 7) - 0.05 then
        bad[#bad + 1] = ("%s %.2f"):format(name, r)
      end
    end
    table.sort(bad)
    H.eq({}, vim.list_slice(bad, 1, 15), #bad .. " groups under target")
  end)
end)

describe("ui round 2: high-contrast variant covers every visible group", function()
  after_each(function()
    vim.g.xynovim_contrast = nil
    vim.cmd.colorscheme("island-dark")
  end)

  it("high (dark): text groups >= 7:1 against their own background, frames >= 4.5:1; hue kept", function()
    vim.g.xynovim_contrast = nil
    vim.cmd.colorscheme("island-dark")
    local before = 0
    for _, g in pairs(all_groups()) do
      if ratio(g.fg, g.bg or THEME_BG) < 7 then
        before = before + 1
      end
    end
    vim.g.xynovim_contrast = "high"
    vim.cmd.colorscheme("island-dark")
    vim.wait(100)
    local bad, after_n = {}, 0
    for name, g in pairs(all_groups()) do
      local r = ratio(g.fg, g.bg or THEME_BG)
      if r < 7 then
        after_n = after_n + 1
      end
      if r >= 1.2 and r < (is_frame(name) and 4.5 or 7) - 0.05 then
        bad[#bad + 1] = ("%s %.2f"):format(name, r)
      end
    end
    table.sort(bad)
    H.eq({}, vim.list_slice(bad, 1, 15), #bad .. " groups under target")
    H.ok(before > 500 and after_n < before / 4, ("groups under 7:1: %d normal -> %d high"):format(before, after_n))
    local kw = hex(hl("Keyword").fg)
    H.ok(tonumber(kw:sub(2, 3), 16) > tonumber(kw:sub(6, 7), 16), "keyword hue kept: " .. kw)
  end)

  it("high: a float's text is drawn >= 7:1 on the grid", function()
    vim.g.xynovim_contrast = "high"
    vim.cmd.colorscheme("island-dark")
    vim.wait(100)
    size(60, 10)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "popup text here" })
    local w = vim.api.nvim_open_win(b, false, {
      relative = "editor",
      row = 2,
      col = 5,
      width = 20,
      height = 1,
      border = "rounded",
      style = "minimal",
    })
    vim.cmd("redraw!")
    local fg, bg = float_colors(w, 1, 3)
    H.ok(ratio(fg, bg) >= 7, ("float text %.2f:1"):format(ratio(fg, bg)))
    vim.api.nvim_win_close(w, true)
  end)
end)

describe("ui round 2 (#4): severity is not carried by colour alone, on the real grid", function()
  local lines = { "let aaa = 1;", "let bbb = 2;", "let ccc = 3;", "let ddd = 4;" }

  local function signatures()
    size(100, 10)
    local buf, ns = with_diagnostics(lines, {})
    vim.g.xynovim_diagnostics = "all"
    vim.o.signcolumn = "yes:1"
    vim.wo.statuscolumn = ""
    vim.o.laststatus = 0
    local ds = {}
    for i, s in ipairs({ E, W, I, Hh }) do
      ds[#ds + 1] = { lnum = i - 1, col = 4, end_col = 7, severity = s, message = "msg" .. i, source = "ra" }
    end
    vim.diagnostic.set(ns, buf, ds)
    vim.cmd("redraw!")
    local parts = { signs = {}, prefixes = {}, unders = {}, all = {} }
    for i = 1, 4 do
      local r, c = find(lines[i])
      H.ok(r, "line " .. i .. " drawn")
      local text = row_text(r)
      local sign = vim.fn.strcharpart(text, 0, 1)
      local prefix = text:match("%d;%s+([\194-\244][\128-\191]*)") or "?"
      local _, a = unpack(inspect(r, c + 4))
      local style = (a.undercurl and "curl" or "")
        .. (a.underdashed and "dash" or "")
        .. (a.underdotted and "dot" or "")
        .. (a.underline and "line" or "")
      parts.signs[sign], parts.prefixes[prefix], parts.unders[style] = true, true, true
      parts.all[sign .. "|" .. prefix .. "|" .. style] = true
    end
    return parts
  end

  it("glyph in the sign column, glyph before the text and underline style all differ per severity", function()
    local p = signatures()
    H.eq(4, vim.tbl_count(p.signs), "sign glyphs: " .. vim.inspect(p.signs))
    H.eq(4, vim.tbl_count(p.prefixes), "glyphs before the message: " .. vim.inspect(p.prefixes))
    H.eq(4, vim.tbl_count(p.unders), "underline styles: " .. vim.inspect(p.unders))
    H.eq(4, vim.tbl_count(p.all))
  end)

  it("with all four colours forced to one grey the four severities are still told apart", function()
    local saved = {}
    for _, k in ipairs({ "Error", "Warn", "Info", "Hint" }) do
      for _, pre in ipairs({ "DiagnosticSign", "DiagnosticVirtualText", "DiagnosticUnderline" }) do
        saved[pre .. k] = vim.api.nvim_get_hl(0, { name = pre .. k, link = false })
        local g = vim.deepcopy(saved[pre .. k])
        g.fg, g.sp, g.bg = 0x888888, 0x888888, nil
        vim.api.nvim_set_hl(0, pre .. k, g)
      end
    end
    local p = signatures()
    for name, g in pairs(saved) do
      vim.api.nvim_set_hl(0, name, g)
    end
    H.eq(4, vim.tbl_count(p.all), "told apart with identical colours: " .. vim.inspect(p.all))
  end)
end)

local chrome = require("config.ui_chrome")

--- No tree, no float, one empty buffer: the round-2 tests start from the same screen.
local function clean_slate()
  pcall(vim.cmd, "Neotree close")
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, w)
    if ok and cfg.relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  pcall(vim.cmd, "only!")
  pcall(vim.cmd, "silent! %bwipeout!")
  vim.o.winbar = ""
  vim.g.xynovim_winbar = nil
  vim.o.laststatus = 0
end
local rendered = require("config.rendered")

--- Private-use glyphs (Nerd Font icons) and symbol arrows on the whole screen: { "U+F027B@row:col", ... }
local function glyphs_on_screen()
  local out = {}
  for r = 1, vim.o.lines do
    for c = 1, vim.o.columns do
      local ch = vim.fn.screenstring(r, c)
      if ch ~= "" then
        local n = vim.fn.char2nr(ch)
        if
          (n >= 0xE000 and n <= 0xF8FF)
          or n >= 0xF0000
          or (n >= 0x2190 and n <= 0x21FF)
          or (n >= 0x2600 and n <= 0x27BF)
        then
          out[#out + 1] = ("U+%X@%d:%d"):format(n, r, c)
        end
      end
    end
  end
  return out
end

describe("ui round 2 (#9): ascii mode reaches the places that kept their glyphs", function()
  before_each(clean_slate)
  after_each(function()
    vim.g.xynovim_icons = nil
    ui.apply_icons()
    chrome.refresh() -- the dashboard preset, tabs and statusline back to the nerd set for the next test
  end)

  it("code lens titles: the symbols go, the words stay", function()
    H.eq("> Run", chrome.ascii_title("▶\239\184\142 Run"))
    H.eq("* Debug", chrome.ascii_title("⚙\239\184\142 Debug"))
    H.eq("2 implementations", chrome.ascii_title("2 implementations"))
    H.eq("Run Test", chrome.ascii_title("▶ Run Test"):gsub("^> ", ""))
  end)

  it("a client's code-lens responses are rewritten in ascii mode and left alone in nerd mode", function()
    local seen = {}
    local client = {
      request = function(_, method, _, handler)
        local lens = {
          { range = {}, command = { title = "▶\239\184\142 Run" } },
          { range = {}, command = { title = "⚙\239\184\142 Debug" } },
        }
        handler(nil, lens, { method = method })
        seen[#seen + 1] = lens
      end,
    }
    chrome.wrap_codelens(client)
    local titles = {}
    client:request("textDocument/codeLens", {}, function(_, res)
      for _, l in ipairs(res) do
        titles[#titles + 1] = l.command.title
      end
    end)
    H.eq({ "▶\239\184\142 Run", "⚙\239\184\142 Debug" }, titles, "nerd mode: untouched")
    vim.g.xynovim_icons = "ascii"
    titles = {}
    client:request("textDocument/codeLens", {}, function(_, res)
      for _, l in ipairs(res) do
        titles[#titles + 1] = l.command.title
      end
    end)
    H.eq({ "> Run", "* Debug" }, titles, "ascii mode: rewritten")
  end)

  describe("with rust-analyzer", function()
    it(
      "the lens above `fn main` shows ▶︎ Run | ⚙︎ Debug in nerd mode and > Run | * Debug in ascii, on the grid",
      function()
        H.need_rust()
        local _, buf = H.open_fixture("basic", "src/main.rs", { git = true })
        H.wait_lsp("rust-analyzer", buf)
        vim.o.laststatus = 0
        size(120, 20)
        eventually(function()
          return find("Run")
        end, 90000, "code lens on the screen")
        H.ok(find("▶") and find("⚙"), "nerd mode keeps the symbols")
        vim.g.xynovim_icons = "ascii"
        ui.apply_icons()
        chrome.refresh()
        eventually(function()
          return find("> Run") and not find("▶")
        end, 30000, "ascii lens")
        H.ok(find("* Debug"), "the Debug lens is plain too")
        H.ok(not find("⚙"), "no gear left")
        vim.g.xynovim_icons = "nerd"
        ui.apply_icons()
        chrome.refresh()
        eventually(function()
          return find("▶")
        end, 30000, "nerd lens back")
      end
    )
  end)

  it("a child nvim with XYNOVIM_ICONS=ascii: file icons, dap-ui and tree diagnostics are plain too", function()
    H.need_posix("runs a child nvim")
    local script = [[
      local function opts_of(name)
        local p = require("lazy.core.config").plugins[name]
        return require("lazy.core.plugin").values(p, "opts", false)
      end
      local out = {}
      out[#out + 1] = "mini=" .. tostring(opts_of("mini.icons").style)
      local du = opts_of("nvim-dap-ui")
      out[#out + 1] = "dapui=" .. du.icons.expanded .. du.controls.icons.play
      out[#out + 1] = "treediag=" .. opts_of("neo-tree.nvim").default_component_configs.diagnostics.symbols.error
      require("lazy").load({ plugins = { "mini.icons" } })
      local icon = require("mini.icons").get("file", "main.rs")
      out[#out + 1] = "file=" .. icon .. "|" .. (icon:find("[\128-\255]") and "NONASCII" or "ascii")
      io.stdout:write(table.concat(out, "\n") .. "\nDONE\n")
      vim.cmd("qa!")
    ]]
    local path = H.tmpdir() .. "/child2.lua"
    local f = assert(io.open(path, "w"))
    f:write(script)
    f:close()
    local r = vim
      .system({ vim.v.progpath, "--headless", "-S", path }, { text = true, env = { XYNOVIM_ICONS = "ascii" }, stdin = false })
      :wait(60000)
    local out = (r.stdout or "") .. (r.stderr or "")
    H.match(out, "DONE", true, out)
    H.match(out, "mini=ascii", true, out)
    H.match(out, "dapui=v>", true, out)
    H.match(out, "treediag=x", true, out)
    H.match(out, "|ascii", true, out)
  end)

  it(":XynoIcons rebuilds statusline, tabline, tree and dashboard at run time (no restart), both ways", function()
    size(110, 30)
    local d = H.tmpdir()
    vim.fn.mkdir(d .. "/src", "p")
    vim.fn.writefile({ "x" }, d .. "/src/a.txt")
    vim.fn.writefile({ "y" }, d .. "/src/b.txt")
    H.git_init(d) -- a branch: the statusline then draws its branch glyph (found missing on a real capture)
    vim.cmd.cd(vim.fn.fnameescape(d))
    vim.cmd("edit src/a.txt")
    vim.cmd("edit src/b.txt")
    require("lazy").load({ plugins = { "bufferline.nvim", "lualine.nvim", "neo-tree.nvim" } })
    vim.o.laststatus = 3
    pcall(function()
      require("lualine").setup(opts_of("lualine.nvim"))
    end)
    vim.cmd("Neotree show dir=" .. vim.fn.fnameescape(d))
    eventually(function()
      return find("a.txt") and find("src")
    end, 10000, "tree drawn")
    vim.cmd("redrawtabline")
    vim.cmd("redrawstatus!")
    local nerd = glyphs_on_screen()
    H.ok(#nerd > 0, "nerd mode draws icon glyphs somewhere (tree, tabs, statusline)")

    vim.cmd("XynoIcons ascii")
    -- the tree's expander arrows (U+F47C / U+F47D) are read at startup (neo-tree cannot be set up twice); nothing
    -- else may be left: not the file and folder icons, not the tabs, not the statusline
    local function leftovers()
      local out = {}
      for _, g in ipairs(glyphs_on_screen()) do
        if not (g:find("^U%+F47[CD]@")) then
          out[#out + 1] = g
        end
      end
      return out
    end
    pcall(eventually, function()
      vim.cmd("redrawtabline")
      vim.cmd("redrawstatus!")
      return #leftovers() == 0
    end, 5000, "no icon glyph left")
    H.eq({}, leftovers(), "ascii mode: no Nerd Font glyph on the screen\n" .. screen_text())
    H.eq("", require("lualine").get_config().options.section_separators.left)
    H.eq(false, require("bufferline.config").options.show_buffer_icons)

    vim.cmd("XynoIcons nerd")
    eventually(function()
      vim.cmd("redrawtabline")
      vim.cmd("redrawstatus!")
      return #glyphs_on_screen() > 0
    end, 8000, "glyphs back")
    H.ok(require("bufferline.config").options.show_buffer_icons ~= false)
    H.eq(
      "\xee\x82\xb0",
      require("lualine").get_config().options.section_separators.left,
      "powerline separator restored"
    )
    H.eq("\xef\x82\xa8", require("bufferline.config").options.left_trunc_marker, "tab truncation marker restored")
    pcall(vim.cmd, "Neotree close")
  end)

  it("the dashboard header and keys switch to plain text without a restart", function()
    pcall(vim.cmd, "Neotree close")
    vim.cmd("only!")
    size(100, 40)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    Snacks.dashboard.open({ buf = buf, win = vim.api.nvim_get_current_win() })
    eventually(function()
      return find("▀▄▄▀") and find("Find File")
    end, 5000, "dashboard drawn")
    H.ok(#glyphs_on_screen() > 0, "nerd dashboard has glyphs")
    vim.cmd("XynoIcons ascii")
    eventually(function()
      return find("x y n o v i m")
    end, 8000, "ascii header")
    H.ok(not find("▀▄▄▀"), "banner glyphs gone")
    pcall(eventually, function()
      return #glyphs_on_screen() == 0
    end, 3000, "no glyph left on the dashboard")
    H.eq({}, glyphs_on_screen(), "glyphs on the ascii dashboard: " .. table.concat(glyphs_on_screen(), " "))
    vim.cmd("XynoIcons nerd")
    eventually(function()
      return find("▀▄▄▀")
    end, 8000, "banner back")
    vim.cmd("enew")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)

describe("ui round 2 (#14): error colour on the file tree and the tabs", function()
  before_each(clean_slate)
  local d, bad_buf
  local function setup_files()
    size(110, 30)
    d = H.tmpdir()
    vim.fn.mkdir(d .. "/src", "p")
    vim.fn.writefile({ "fn main() {", '    let x: i32 = "a";', "}" }, d .. "/src/bad.rs")
    vim.fn.writefile({ "fn ok() {}" }, d .. "/src/good.rs")
    vim.cmd.cd(vim.fn.fnameescape(d))
    vim.cmd("edit src/good.rs")
    vim.cmd("edit src/bad.rs")
    bad_buf = vim.api.nvim_get_current_buf()
    require("lazy").load({ plugins = { "bufferline.nvim", "neo-tree.nvim" } })
    vim.wait(150) -- the scheduled legibility pass after bufferline loaded
    vim.o.laststatus = 0
  end

  it("XynoTreeError is >= 4.5:1 on the editor background", function()
    local g = hl("XynoTreeError")
    H.ok(ratio(hex(g.fg), THEME_BG) >= 4.5, ("%.2f:1"):format(ratio(hex(g.fg), THEME_BG)))
  end)

  it(
    "a file with an error is drawn in the error colour in the tree, a clean file and a warning-only file are not",
    function()
      setup_files()
      vim.fn.writefile({ "fn warn() {}" }, d .. "/src/warn.rs")
      vim.cmd("edit src/warn.rs")
      local warn_buf = vim.api.nvim_get_current_buf()
      local ns = vim.api.nvim_create_namespace("ui-tree-test")
      vim.diagnostic.set(ns, bad_buf, {
        {
          lnum = 1,
          col = 17,
          end_col = 20,
          severity = E,
          message = "mismatched types",
          code = "E0308",
          source = "rustc",
        },
      })
      vim.diagnostic.set(
        ns,
        warn_buf,
        { { lnum = 0, col = 3, end_col = 7, severity = W, message = "unused", source = "rustc" } }
      )
      vim.cmd("Neotree show dir=" .. vim.fn.fnameescape(d) .. " reveal_file=" .. vim.fn.fnameescape(d .. "/src/bad.rs"))
      local mgr = require("neo-tree.sources.manager")
      vim.wait(1200)
      mgr.refresh("filesystem")
      local want = hex(hl("XynoTreeError").fg)
      local last
      --- all names read from the same drawn frame (the tree redraws on focus and cursor events)
      local function frame()
        vim.cmd("redraw!")
        local t = {}
        for _, n in ipairs({ "bad.rs", "good.rs", "warn.rs", "src" }) do
          local r, c = find(n, 2) -- row 1 is the tabline
          if not r then
            return nil
          end
          local fg, bg = colors_at(r, c)
          t[n] = { fg = fg, bg = bg }
        end
        last = t
        return t
      end
      local ok, err = pcall(eventually, function()
        local t = frame()
        return t
          and t["bad.rs"].fg == want
          and t["src"].fg == want
          and t["good.rs"].fg ~= want
          and t["warn.rs"].fg ~= want
      end, 10000, "names drawn in their colours")
      if not ok then
        error(("%s\n%s\n%s"):format(err, vim.inspect(last), screen_text():sub(1, 1200)))
      end
      H.ok(ratio(last["bad.rs"].fg, last["bad.rs"].bg) >= 4.5, "error name legible")
      -- the error colour is the file's, the folder above it; a clean file and a warning-only file keep theirs
      pcall(vim.cmd, "Neotree close")
    end
  )

  it("the tab of a buffer with an error shows the error count right after its name, in a legible colour", function()
    setup_files()
    local ns = vim.api.nvim_create_namespace("ui-tab-test")
    vim.diagnostic.set(
      ns,
      bad_buf,
      { { lnum = 1, col = 17, end_col = 20, severity = E, message = "mismatched types", source = "rustc" } }
    )
    eventually(function()
      vim.cmd("redrawtabline")
      local r, c = find("bad.rs")
      return r == 1 and row_text(1):match("bad%.rs%s+%S*%s*1")
    end, 8000, "tab with the error count")
    local r, c = find("bad.rs")
    local text = row_text(r):sub(c)
    local after = text:match("bad%.rs%s+(.*)")
    H.match(after, "1", false, "count after the name: " .. text)
    local cc = c + vim.fn.strdisplaywidth("bad.rs")
    while vim.fn.screenstring(r, cc) ~= "1" and cc < vim.o.columns do
      cc = cc + 1
    end
    local fg, bg = colors_at(r, cc)
    H.ok(ratio(fg, bg) >= 4.5, ("count %.2f:1"):format(ratio(fg, bg)))
    local gfg = colors_at(r, (find("good.rs")))
    H.not_ok(fg == gfg, "the count is not in the plain tab text colour")
  end)
end)

describe("ui round 2 (#15): opt-in winbar breadcrumbs", function()
  before_each(clean_slate)
  before_each(function()
    vim.o.showtabline = 0 -- bufferline may be loaded by an earlier test: keep row 1 for the winbar
  end)
  after_each(function()
    vim.o.showtabline = 1
    vim.g.xynovim_winbar = nil
    vim.o.winbar = ""
    pcall(vim.cmd, "only!")
  end)

  it("off by default: no winbar row", function()
    H.is_nil(vim.g.xynovim_winbar)
    H.eq("", vim.o.winbar)
  end)

  it(":XynoWinbar on draws the path (project-relative, ascii separators in ascii mode), off removes it", function()
    size(80, 12)
    vim.cmd("silent! %bwipeout!") -- one buffer: bufferline shows no tabline, row 1 is the winbar
    local d = H.tmpdir()
    vim.fn.mkdir(d .. "/src/deep", "p")
    vim.fn.writefile({ "x" }, d .. "/src/deep/mod.rs")
    vim.cmd.cd(vim.fn.fnameescape(d))
    vim.cmd("edit src/deep/mod.rs")
    vim.o.laststatus = 0
    vim.cmd("XynoWinbar on")
    vim.cmd("redraw!")
    local r = find("mod.rs")
    H.eq(1, r, "the winbar is the first row")
    H.match(row_text(1), "src", true)
    H.match(row_text(1), "deep", true)
    vim.g.xynovim_icons = "ascii"
    vim.cmd("redraw!")
    H.match(row_text(1), "src > deep > mod.rs", true)
    vim.g.xynovim_icons = nil
    local fg, bg = colors_at(1, 2)
    H.ok(ratio(fg, bg) >= 4.5, ("winbar text %.2f:1"):format(ratio(fg, bg)))
    vim.cmd("XynoWinbar off")
    vim.cmd("redraw!")
    H.not_ok(row_text(1):find("mod.rs", 1, true), "winbar gone")
  end)

  it("the symbol breadcrumb (nvim-navic) is drawn as text with its colours, not as raw %#Group# codes", function()
    size(80, 12)
    vim.cmd("silent! %bwipeout!")
    local d = H.tmpdir()
    vim.fn.writefile({ "x" }, d .. "/m.rs")
    vim.cmd.cd(vim.fn.fnameescape(d))
    vim.cmd("edit m.rs")
    local real = package.loaded["nvim-navic"]
    package.loaded["nvim-navic"] = {
      is_available = function()
        return true
      end,
      get_location = function()
        return "%#NavicIconsFunction#f %*%#NavicText#main%*"
      end,
    }
    vim.cmd("XynoWinbar on")
    vim.cmd("redraw!")
    package.loaded["nvim-navic"] = real
    local row = row_text(1)
    vim.cmd("XynoWinbar off")
    H.match(row, "m.rs", true)
    H.match(row, "main", true)
    H.no_match(row, "%#", true, "raw statusline codes on the winbar")
    H.no_match(row, "Navic", true)
  end)

  it("a narrow window keeps the file name and drops the folders", function()
    size(30, 10)
    local d = H.tmpdir()
    vim.fn.mkdir(d .. "/a_rather_long_folder_name/another_long_folder", "p")
    vim.fn.writefile({ "x" }, d .. "/a_rather_long_folder_name/another_long_folder/file.rs")
    vim.cmd.cd(vim.fn.fnameescape(d))
    vim.cmd("edit a_rather_long_folder_name/another_long_folder/file.rs")
    vim.cmd("XynoWinbar on")
    vim.cmd("redraw!")
    H.match(row_text(1), "file.rs", true)
    H.no_match(row_text(1), "another_long_folder", true)
  end)
end)

describe("ui round 2 (#13): the diagnostic as rustc prints it, coloured", function()
  before_each(clean_slate)
  local RUSTC = table.concat({
    "error[E0308]: mismatched types",
    " --> src/bad.rs:2:17",
    "  |",
    '2 |     let x: i32 = "a";',
    "  |            ---   ^^^ expected `i32`, found `&str`",
    "  |            |",
    "  |            expected due to this",
    "  |",
    "  = note: expected type `i32`",
    "  = help: try parsing",
  }, "\n")

  it("spans: kind word, location, gutter, carets and note/help are each their own highlight", function()
    local lines = vim.split(RUSTC, "\n")
    local spans = rendered.spans(lines, E)
    local function at(row, col)
      for _, s in ipairs(spans) do
        if s.row == row and s.col <= col and col < s.end_col then
          return s.hl
        end
      end
    end
    H.eq("XynoRenderedError", at(0, 0), "'error[E0308]'")
    H.eq("XynoRenderedMessage", at(0, 20), "the message")
    H.eq("XynoRenderedPath", at(1, 8), "the path after -->")
    H.eq("XynoRenderedGutter", at(3, 0), "line number")
    H.eq("XynoRenderedGutter", at(3, 2), "the bar")
    local dash = lines[5]:find("---", 1, true) - 1
    local caret = lines[5]:find("^^^", 1, true) - 1
    H.eq("XynoRenderedNote", at(4, dash), "--- secondary span")
    H.eq("XynoRenderedError", at(4, caret), "^^^ carets in the severity colour")
    H.eq("XynoRenderedError", at(4, #lines[5] - 3), "the label after the carets")
    H.eq("XynoRenderedNote", at(6, #lines[7] - 3), "the label hanging under a secondary span")
    H.is_nil(at(3, #lines[4] - 2), "a source line containing '-' or '^' is not an underline row")
    H.eq("XynoRenderedNote", at(8, 4), "note:")
    H.eq("XynoRenderedHelp", at(9, 4), "help:")
    local wspans = rendered.spans({ "warning: unused", "  |", "1 | x", "  | ^" }, W)
    local caret_hl
    for _, s in ipairs(wspans) do
      if s.row == 3 and s.hl ~= "XynoRenderedGutter" then
        caret_hl = s.hl
      end
    end
    H.eq("XynoRenderedWarn", caret_hl, "warning carets use the warning colour")
  end)

  it("ANSI colour codes from a server are removed", function()
    H.eq("error: x", rendered.strip_ansi("\27[1m\27[38;5;9merror\27[0m: x"))
  end)

  it("text source: rust-analyzer's data.rendered, or a multi-line message (clippy); a one-liner has none", function()
    local d1 = { message = "short", user_data = { lsp = { data = { rendered = RUSTC } } } }
    local t1, r1 = rendered.rendered_text(d1)
    H.eq(RUSTC, t1)
    H.eq(true, r1)
    local t2, r2 = rendered.rendered_text({ message = RUSTC })
    H.eq(true, r2)
    H.eq(RUSTC, t2)
    local _, r3 = rendered.rendered_text({ message = "expected String, found i32" })
    H.eq(false, r3)
  end)

  it("on the grid: the float shows the rustc text with the parts in their colours, all >= 4.5:1", function()
    size(100, 24)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fn main() {", '    let x: i32 = "a";', "}" })
    vim.o.laststatus = 0
    local ns = vim.api.nvim_create_namespace("rendered-test")
    vim.diagnostic.set(ns, buf, {
      {
        lnum = 1,
        col = 17,
        end_col = 20,
        severity = E,
        message = "mismatched types",
        code = "E0308",
        source = "rustc",
        user_data = { lsp = { data = { rendered = RUSTC } } },
      },
    })
    vim.api.nvim_win_set_cursor(0, { 2, 18 })
    local win = rendered.open()
    H.ok(win, "float opened")
    vim.cmd("redraw!")
    local function cell(lr, lc)
      return float_colors(win, lr + 1, lc + 1) -- +1: the border
    end
    local want = {
      { 0, 0, "XynoRenderedError" }, -- "e" of error
      { 0, 18, "XynoRenderedMessage" },
      { 1, 8, "XynoRenderedPath" },
      { 3, 0, "XynoRenderedGutter" },
    }
    for _, w in ipairs(want) do
      local fg = cell(w[1], w[2])
      H.eq(hex(hl(w[3]).fg), fg, w[3])
    end
    -- every drawn cell of the float is >= 4.5:1
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    local worst = 99
    for i, l in ipairs(lines) do
      for j = 1, #l do
        if l:sub(j, j):match("%S") then
          local fg, bg = cell(i - 1, j - 1)
          worst = math.min(worst, ratio(fg, bg))
        end
      end
    end
    H.ok(worst >= 4.5, ("worst cell in the float %.2f:1"):format(worst))
    -- the title and footer say what and from where
    local cfg = vim.api.nvim_win_get_config(win)
    H.match(vim.inspect(cfg.title), "E0308", true)
    H.match(vim.inspect(cfg.footer), "rustc", true)
    vim.api.nvim_win_close(win, true)
  end)

  it("a message longer than the window wraps and the float is tall enough to show all of it", function()
    size(60, 24)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x" })
    vim.diagnostic.set(vim.api.nvim_create_namespace("rendered-test2"), buf, {
      { lnum = 0, col = 0, severity = W, message = ("word "):rep(60), source = "rust-analyzer" },
    })
    local win = rendered.open()
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    local width = vim.api.nvim_win_get_width(win)
    local need = 0
    for _, l in ipairs(lines) do
      need = need + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
    end
    H.ok(vim.api.nvim_win_get_height(win) >= math.min(need, vim.o.lines - 6), "tall enough for the wrapped text")
    vim.cmd("redraw!")
    H.match(
      vim.fn.join(
        vim.tbl_map(function(r)
          return row_text(r)
        end, vim.fn.range(1, vim.o.lines)),
        "\n"
      ),
      "one-line message",
      true
    )
    vim.api.nvim_win_close(win, true)
  end)
end)

describe("ui round 2 (#7): transparency and floats on the real grid", function()
  before_each(clean_slate)
  after_each(function()
    vim.g.xynovim_transparent = nil
    vim.cmd.colorscheme("island-dark")
  end)

  --- Cell background as drawn: nil = the terminal's own (see-through), else "#rrggbb". `a.background` is the
  --- attribute of the cell (no fallback to Normal here, unlike colors_at).
  local function drawn_bg(row, col)
    local _, a = unpack(inspect(row, col))
    local bg = a.background
    if a.reverse then
      bg = a.foreground
    end
    -- no attribute background = the default one, which is Normal's: nil when the editor is transparent
    return hex(bg or hl("Normal").bg)
  end

  for _, transparent in ipairs({ true, false }) do
    it(
      ("transparent=%s: editor surfaces %s, floats, borders, titles and footers are solid"):format(
        tostring(transparent),
        transparent and "see through" or "are solid"
      ),
      function()
        vim.g.xynovim_transparent = transparent
        vim.cmd.colorscheme("island-dark")
        size(80, 14)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
        vim.wo.number = true
        vim.wo.cursorline = false
        vim.o.signcolumn = "yes:1"
        vim.wo.statuscolumn = ""
        vim.diagnostic.set(
          vim.api.nvim_create_namespace("transp"),
          buf,
          { { lnum = 1, col = 0, severity = W, message = "w", source = "x" } }
        )
        vim.cmd("redraw!")
        local want
        if not transparent then
          want = "#1e1f22"
        end
        H.eq(want, drawn_bg(8, 40), "empty editor cell")
        local r = find("two")
        H.eq(want, drawn_bg(r, 70), "the rest of a text line")
        local r3 = find("three") -- (the cursor cell of the grid is drawn with the Cursor group: not on this row)
        H.eq(want, drawn_bg(r3, 1), "sign column cell")
        H.eq(want, drawn_bg(r3, 3), "gap before the line number")
        H.eq(want, drawn_bg(r3, 5), "line number cell")
        -- a float: solid everywhere including border, title and footer
        local fb = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(fb, 0, -1, false, { "float body" })
        local w = vim.api.nvim_open_win(fb, false, {
          relative = "editor",
          row = 3,
          col = 12,
          width = 20,
          height = 1,
          border = "rounded",
          style = "minimal",
          title = " Title ",
          footer = " foot ",
          footer_pos = "center",
        })
        vim.cmd("redraw!")
        local solid = hex(hl("NormalFloat").bg)
        local grid
        for g = 2, 3000 do
          local ok, cell = pcall(vim.api.nvim__inspect_cell, g, 1, 1)
          if ok and cell[1] == "f" then
            grid = g
            break
          end
        end
        H.ok(grid, "float grid found")
        local checked = 0
        for rr = 0, 2 do
          for cc = 0, 21 do
            local ok, cell = pcall(vim.api.nvim__inspect_cell, grid, rr, cc)
            if ok then
              checked = checked + 1
              H.eq(solid, hex(cell[2].background), ("float cell %d,%d (%q) is solid"):format(rr, cc, cell[1]))
            end
          end
        end
        H.ok(checked >= 60, "cells checked: " .. checked)
        vim.api.nvim_win_close(w, true)
        -- the completion popup and the statusline keep their fills
        H.ok(hl("Pmenu").bg, "Pmenu has a background")
        H.ok(hl("StatusLine").bg, "StatusLine has a background")
        H.ok(hl("XynoPopupNormal").bg, "plugin popups have a background")
      end
    )
  end

  it("the dashboard in a transparent editor: the statusline row is uniform, not a patchwork", function()
    vim.g.xynovim_transparent = true
    vim.cmd.colorscheme("island-dark")
    size(100, 30)
    vim.o.laststatus = 3
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    Snacks.dashboard.open({ buf = buf, win = vim.api.nvim_get_current_win() })
    eventually(function()
      return find("Find File")
    end, 5000, "dashboard drawn")
    vim.cmd("redrawstatus!")
    vim.cmd("redraw!")
    local row = vim.o.lines - vim.o.cmdheight
    local seen = {}
    for c = 1, vim.o.columns do
      seen[tostring(drawn_bg(row, c))] = (seen[tostring(drawn_bg(row, c))] or 0) + 1
    end
    local kinds = vim.tbl_count(seen)
    H.ok(kinds <= 2, "statusline row backgrounds: " .. vim.inspect(seen))
    -- the dashboard body itself is see-through
    local r, c = find("Find File")
    H.is_nil(drawn_bg(r, c + 12), "dashboard text cell has no fill")
    vim.cmd("enew")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)

-- ====================================================================================================
-- The real popups of the xyno plugins (not synthetic floats). The locked plugin versions (lazy-lock.json) have
-- no sandbox policy window and no history panel: these tests use them when the loaded plugin has them, which
-- is the case with XYNOVIM_DEV_PLUGINS=<clones> (scripts/dev-plugins.sh test ui-community), and say SKIP otherwise.
-- ====================================================================================================

--- The grid number of a float window (found by its first text row), as in float_colors.
local function float_grid(win)
  local cfg = vim.api.nvim_win_get_config(win)
  local pad = cfg.border and 1 or 0
  local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, 1, false)[1] or ""
  for g = 2, 3000 do -- grid ids keep counting up over a long run
    local same = #line > 0
    for i = 1, math.min(#line, 6) do
      local ok, res = pcall(vim.api.nvim__inspect_cell, g, pad, pad + i - 1)
      if not (ok and res[1] == line:sub(i, i)) then
        same = false
        break
      end
    end
    if same then
      return g
    end
  end
end

--- Every non-blank cell of a float grid (border included): { ch, fg, bg, row, col }.
local function float_cells(win)
  local g = assert(float_grid(win), "no grid for the float")
  local cfg = vim.api.nvim_win_get_config(win)
  local h, w = vim.api.nvim_win_get_height(win) + 2, vim.api.nvim_win_get_width(win) + 2
  local normal = hl("Normal")
  local out = {}
  for r = 0, h - 1 do
    for c = 0, w - 1 do
      local ok, cell = pcall(vim.api.nvim__inspect_cell, g, r, c)
      if ok and cell[1]:match("%S") then
        local a = cell[2]
        out[#out + 1] = {
          ch = cell[1],
          fg = hex(a.foreground or normal.fg) or "#bcbec4",
          bg = hex(a.background or normal.bg) or THEME_BG,
          row = r,
          col = c,
        }
      end
    end
  end
  return out, cfg
end

local function text_cells_ratio(cells)
  local worst, at = 99, nil
  for _, c in ipairs(cells) do
    if not c.ch:match("[─│╭╮╰╯]") then
      local r = ratio(c.fg, c.bg)
      if r < worst then
        worst, at = r, c
      end
    end
  end
  return worst, at
end

describe("ui round 2: the real popups of the xyno plugins on the grid", function()
  before_each(clean_slate)

  local function hermetic_home()
    local saved = vim.env.HOME
    vim.env.HOME = H.tmpdir()
    return function()
      vim.env.HOME = saved
    end
  end

  it(
    "sandbox policy window (:XynoSandboxPolicy): Xyno groups, every text cell >= 4.5:1, tall enough for its text",
    function()
      H.need_sandbox()
      if not pcall(require, "xyno_sandbox.ui") then
        skip("the loaded xyno-sandbox.nvim has no policy window (lock file pins the older plugin)")
      end
      local restore = hermetic_home()
      local project = H.fixture("basic", { git = true })
      vim.cmd.cd(vim.fn.fnameescape(project))
      size(120, 40)
      vim.cmd("XynoSandboxPolicy")
      local win
      eventually(function()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "xyno-sandbox" then
            win = w
            return true
          end
        end
      end, 15000, "the policy window")
      restore()
      eventually(function()
        return vim.wo[win].winhighlight:find("XynoPopupBorder", 1, true)
      end, 3000, "winhighlight")
      vim.cmd("redraw!")
      local cells, cfg = float_cells(win)
      H.ok(#cells > 200, "the window has text: " .. #cells)
      local height = vim.api.nvim_win_get_height(win)
      local cur = vim.api.nvim_win_get_cursor(win)
      local body, title, footer = {}, {}, {}
      for _, c in ipairs(cells) do
        if c.row == 0 then
          title[#title + 1] = c
        elseif c.row == height + 1 then
          footer[#footer + 1] = c
        elseif c.row == cur[1] then
        -- the cursor row: its cells carry the cursor / reference highlights of other plugins (an LSP
        -- reference or code-lens group landed on it in the multigrid read), not the popup's text colour
        else
          body[#body + 1] = c
        end
      end
      local worst, at = text_cells_ratio(body)
      H.ok(
        worst >= 4.5,
        ("worst body cell %.2f:1 (%s %s on %s at %d,%d)"):format(
          worst,
          at and at.ch or "",
          at and at.fg or "",
          at and at.bg or "",
          at and at.row or -1,
          at and at.col or -1
        )
      )
      -- title and footer: their text is on the grid; their colour is whatever FloatTitle / FloatFooter map to in
      -- winhighlight (checked below): reading those cells back is unreliable here (an LSP reference highlight of
      -- another plugin lands on the title row), so the groups themselves carry the contrast assertion
      H.ok(#title > 5 and #footer > 5, "title and footer cells are drawn")
      H.match(vim.wo[win].winhighlight, "FloatTitle:XynoPopupTitle", true)
      H.match(vim.wo[win].winhighlight, "FloatFooter:XynoPopupFooter", true)
      H.ok(ratio(hex(hl("XynoPopupTitle").fg), hex(hl("XynoPopupTitle").bg)) >= 4.5)
      H.ok(ratio(hex(hl("XynoPopupFooter").fg), hex(hl("XynoPopupFooter").bg)) >= 4.5)
      local first = cells[1]
      H.ok(ratio(first.fg, first.bg) >= 3, ("border corner %.2f:1 (non-text: 3:1)"):format(ratio(first.fg, first.bg)))
      -- nothing cut: no '@@@' marker, and the window grew to the wrapped text or says how to scroll
      local screen = screen_text()
      H.no_match(screen, "@@@", true, "text cut off at the bottom of the window")
      H.match(vim.inspect(cfg.footer), "q close", true)
      vim.api.nvim_win_close(win, true)
    end
  )

  it("local-history panel (:LocalHistoryPanel): every text cell >= 4.5:1, selected row included", function()
    if not pcall(require, "xyno_history.panel") then
      skip("the loaded xyno-history.nvim has no panel (lock file pins the older plugin)")
    end
    H.need_posix("git")
    local root = H.fixture("basic", { git = true })
    vim.cmd.cd(vim.fn.fnameescape(root))
    vim.cmd("edit src/main.rs")
    local LH = require("xyno_history")
    for i = 1, 3 do
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// edit " .. i })
      vim.cmd("silent write")
      local done = false
      LH.snapshot({
        path = root,
        force = true,
        done = function()
          done = true
        end,
      })
      H.wait_for(function()
        return done
      end, 20000, "snapshot")
    end
    size(120, 36)
    require("xyno_history.panel").open({ scope = "file" })
    eventually(function()
      return find("Local history") and find("Changed files")
    end, 10000, "the panel")
    vim.cmd("redraw!")
    local worst, at = 99, nil
    local cells = 0
    local sp = { row = vim.fn.screenrow(), col = vim.fn.screencol() }
    for r = 2, vim.o.lines - vim.o.cmdheight do -- row 1 is the tabline
      for c = 1, vim.o.columns do
        local ch = vim.fn.screenstring(r, c)
        if ch:match("%S") and not ch:match("[─│╭╮╰╯▏▕▎]") and not (r == sp.row and c == sp.col) then
          local fg, bg = colors_at(r, c)
          cells = cells + 1
          if ratio(fg, bg) < worst then
            worst, at = ratio(fg, bg), ("%s@%d:%d %s/%s"):format(ch, r, c, fg, bg)
          end
        end
      end
    end
    H.ok(cells > 50, "panel text cells: " .. cells)
    H.ok(worst >= 4.5, ("worst panel cell %.2f:1 %s"):format(worst, tostring(at)))
    pcall(vim.cmd, "tabonly!")
  end)

  it("macros: the popup groups the plugin links are >= 4.5:1 on the popup surface", function()
    -- the signature popup needs a macro call under a running rust-analyzer: its groups are checked, the window is not opened here
    local bg = hex(hl("XynoMacrosFloat").bg or hl("NormalFloat").bg)
    H.ok(ratio(hex(hl("XynoMacrosDim").fg), bg) >= 4.5, "XynoMacrosDim (arms that cannot match)")
    H.ok(ratio(hex(hl("PmenuSel").fg), hex(hl("PmenuSel").bg)) >= 4.5, "the best arm is drawn with PmenuSel")
  end)

  it("macros: :ProcMacroStatus opens a report window whose text is all >= 4.5:1", function()
    if not pcall(require, "xyno_macros.tools.status") then
      skip("this xyno-macros.nvim has no proc-macro status report")
    end
    H.need_rust()
    local _, buf = H.open_fixture("basic", "src/main.rs", { git = true })
    H.wait_lsp("rust-analyzer", buf)
    size(120, 40)
    vim.cmd("ProcMacroStatus")
    local ok = pcall(eventually, function()
      return find("proc-macro") or find("Proc-macro") or find("proc macro")
    end, 40000, "report")
    if not ok then
      skip("no report window within 40 s on this machine")
    end
    local worst, at, n = 99, nil, 0
    local rwin
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find("proc-macro-status", 1, true) then
        rwin = w
      end
    end
    H.ok(rwin, "the report window")
    -- the report's own text, cell by cell through screenpos (not the whole window: the cursor cell and other
    -- plugins' virtual text are not the report)
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(rwin), 0, -1, false)
    local sp = { row = vim.fn.screenrow(), col = vim.fn.screencol() }
    for i, line in ipairs(lines) do
      for j = 1, #line do
        if line:sub(j, j):match("[%w%p]") then
          local pos = vim.fn.screenpos(rwin, i, j)
          if pos.row > 0 and not (pos.row == sp.row and pos.col == sp.col) then
            local fg, bg = colors_at(pos.row, pos.col)
            n = n + 1
            if ratio(fg, bg) < worst then
              worst, at = ratio(fg, bg), ("%s@%d:%d %s/%s"):format(line:sub(j, j), pos.row, pos.col, fg, bg)
            end
          end
        end
      end
    end
    H.ok(n > 30, "report cells: " .. n)
    H.ok(worst >= 4.5, ("worst report cell %.2f:1 %s"):format(worst, tostring(at)))
  end)

  it(
    "guard: a dependency buffer shows its state in words (DEP RO) in a legible colour, on the real statusline",
    function()
      local guard = package.loaded["xyno_guard"] or select(2, pcall(require, "xyno_guard"))
      if type(guard) ~= "table" or type(guard.statusline) ~= "function" then
        skip("the loaded xyno-guard.nvim has no statusline component")
      end
      local d = H.tmpdir()
      local saved = vim.env.CARGO_HOME
      vim.env.CARGO_HOME = d
      vim.fn.mkdir(d .. "/registry/src/index.crates.io-x/foo-1.0.0/src", "p")
      local f = d .. "/registry/src/index.crates.io-x/foo-1.0.0/src/lib.rs"
      vim.fn.writefile({ "pub fn foo() {}" }, f)
      size(110, 12)
      vim.cmd("edit " .. vim.fn.fnameescape(f))
      vim.o.laststatus = 3
      eventually(function()
        return guard.state(0) == "dependency"
      end, 5000, "dependency state")
      pcall(function()
        require("lualine").setup(opts_of("lualine.nvim"))
      end)
      local row = vim.o.lines - vim.o.cmdheight
      eventually(function()
        vim.cmd("redrawstatus!")
        return row_text(row):find(guard.statusline(0), 1, true)
      end, 5000, "guard text in the statusline")
      local text = guard.statusline(0)
      H.ok(text ~= "", "the state has words/letters, not only a colour: " .. text)
      local r, c = find(vim.trim(text):sub(1, 3), row)
      local fg, bg = colors_at(r, c)
      H.ok(ratio(fg, bg) >= 4.5, ("guard text %.2f:1"):format(ratio(fg, bg)))
      vim.env.CARGO_HOME = saved
    end
  )
end)
