-- Island Dark theme: colors/island-dark.lua, lua/island/{init,palette}.lua, the lualine theme,
-- plugin/after/{transparency,unsafe-highlight}.lua and tools/icls2nvim.py.
-- Expected colours are written out literally (the scheme's values), the
-- palette is only read where the test is about the palette itself.
local H = require("xynotest.helpers")

-- ------------------------------------------------------------------ local helpers

local function hl(name, link)
  return vim.api.nvim_get_hl(0, { name = name, link = link or false })
end

--- nvim_get_hl colours are integers; compare as "#rrggbb"
local function hex(n)
  return n and string.format("#%06x", n) or nil
end

local function fg(name) return hex(hl(name).fg) end
local function bg(name) return hex(hl(name).bg) end
local function sp(name) return hex(hl(name).sp) end

local function lum(h)
  local ch = {}
  for i = 1, 3 do
    local c = tonumber(h:sub(2 * i, 2 * i + 1), 16) / 255
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

local function near(expected, actual, tol, msg)
  H.ok(math.abs(expected - actual) <= tol, ("%s: expected ~%s, got %s"):format(msg or "value", expected, actual))
end

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function write(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

local function reload_scheme()
  vim.cmd("colorscheme island-dark")
end

local function py(args, cwd)
  local r = vim.system(vim.list_extend({ "python3" }, args), { cwd = cwd, text = true }):wait(30000)
  return r
end

local function has_python()
  return vim.fn.executable("python3") == 1
end

-- every test starts from the freshly loaded scheme with transparency on
local function reset()
  vim.g.xynovim_transparent = nil
  vim.o.background = "dark"
  reload_scheme()
end

local function pal()
  return dofile(H.repo .. "/lua/island/palette.lua")
end

-- ------------------------------------------------------------------ 1, 2: loading

describe("island-dark loading", function()
  before_each(reset)

  it("is the active colourscheme after startup (colors_name, background, termguicolors)", function()
    H.eq("island-dark", vim.g.colors_name)
    H.eq("dark", vim.o.background)
    H.ok(vim.o.termguicolors)
  end)

  it("is configured for LazyVim and lualine through lua/plugins/island-theme.lua", function()
    local Config = require("lazy.core.config")
    local Plugin = require("lazy.core.plugin")
    local lv = H.ok(Config.spec.plugins["LazyVim"], "LazyVim in the spec")
    local ll = H.ok(Config.spec.plugins["lualine.nvim"], "lualine.nvim in the spec")
    local lv_opts = Plugin.values(lv, "opts", false)
    local ll_opts = Plugin.values(ll, "opts", false)
    H.eq("island-dark", lv_opts.colorscheme)
    H.eq("island-dark", ll_opts.options.theme)
  end)

  it("colors/island-dark.lua clears highlights, resets syntax, sets the globals, then runs setup()", function()
    local src = read(H.repo .. "/colors/island-dark.lua")
    H.match(src, 'vim.cmd("highlight clear")', true)
    H.match(src, "syntax reset", true)
    H.match(src, 'vim.o.background = "dark"', true)
    H.match(src, "vim.o.termguicolors = true", true)
    H.match(src, 'vim.g.colors_name = "island-dark"', true)
    H.match(src, 'require("island").setup()', true)
    -- behaviour: a stray group disappears (highlight clear), the scheme's come back
    vim.api.nvim_set_hl(0, "XynoStray", { fg = "#123456" })
    vim.o.background = "light"
    vim.o.termguicolors = false
    vim.g.colors_name = nil
    reload_scheme()
    H.eq({}, hl("XynoStray"), "highlight clear removed the stray group")
    H.eq("dark", vim.o.background)
    H.ok(vim.o.termguicolors)
    H.eq("island-dark", vim.g.colors_name)
    H.eq("#bcbec4", fg("Normal"))
  end)

  it("runs `syntax reset` when syntax is on", function()
    vim.cmd("syntax on")
    H.eq(1, vim.fn.exists("syntax_on"))
    local called = 0
    local orig = vim.cmd
    -- count `syntax reset` calls made by the colorscheme file
    local wrapped = setmetatable({}, {
      __call = function(_, c, ...)
        if type(c) == "string" and c:find("syntax reset", 1, true) then
          called = called + 1
        end
        return orig(c, ...)
      end,
      __index = orig,
    })
    vim.cmd = wrapped
    local ok, err = pcall(dofile, H.repo .. "/colors/island-dark.lua")
    vim.cmd = orig
    H.ok(ok, tostring(err))
    H.eq(1, called)
  end)

  it(":colorscheme island-dark loads with no messages", function()
    H.clear_messages()
    vim.cmd("colorscheme island-dark")
    H.eq("", vim.trim(H.messages()))
    H.eq("island-dark", vim.g.colors_name)
  end)
end)

-- ------------------------------------------------------------------ 3: palette

describe("palette.lua", function()
  it("is generated: header, name, counts and derived colours", function()
    local src = read(H.repo .. "/lua/island/palette.lua")
    local head = src:sub(1, 200)
    H.match(head, "GENERATED", true)
    H.match(head, "DO NOT EDIT", true)
    local P = pal()
    H.eq("Dark", P.name)
    local n = 0
    for _ in pairs(P.colors) do n = n + 1 end
    H.eq(63, n, "colors")
    n = 0
    for _ in pairs(P.attrs) do n = n + 1 end
    H.eq(173, n, "attrs")
    H.eq("#666870", P.derived.BORDER)
    H.eq("#2d416b", P.derived.SELECTION_BACKGROUND)
    H.eq("#2f5194", P.derived.SELECTION_STRONG)
  end)
end)

-- ------------------------------------------------------------------ 4, 5: icls2nvim.py

describe("tools/icls2nvim.py", function()
  local work

  before_each(function()
    if not has_python() then
      skip("python3 not found")
    end
    work = H.tmpdir()
  end)

  local function mini_icls(path)
    -- a: cycle a -> b -> a ; c: inherits from d ; e: empty entry with a FALLBACK
    -- (ANNOTATION_NAME_ATTRIBUTES -> DEFAULT_METADATA); effects 1..5 and an unknown one
    local rows = {
      '<attr name="CYCLE_A" baseAttributes="CYCLE_B"><value><option name="FOREGROUND" value="aa0000"/></value></attr>',
      '<attr name="CYCLE_B" baseAttributes="CYCLE_A"><value><option name="BACKGROUND" value="00bb00"/></value></attr>',
      '<attr name="CHILD" baseAttributes="PARENT"><value><option name="FONT_TYPE" value="2"/></value></attr>',
      '<attr name="PARENT"><value><option name="FOREGROUND" value="123456"/><option name="FONT_TYPE" value="1"/></value></attr>',
      '<attr name="DEFAULT_METADATA"><value><option name="FOREGROUND" value="bbb529"/></value></attr>',
      '<attr name="ANNOTATION_NAME_ATTRIBUTES"><value/></attr>',
      '<attr name="EMPTY_NOFALLBACK"><value/></attr>',
      '<attr name="FX1"><value><option name="EFFECT_TYPE" value="1"/><option name="EFFECT_COLOR" value="010101"/></value></attr>',
      '<attr name="FX2"><value><option name="EFFECT_TYPE" value="2"/><option name="EFFECT_COLOR" value="020202"/></value></attr>',
      '<attr name="FX3"><value><option name="EFFECT_TYPE" value="3"/><option name="EFFECT_COLOR" value="030303"/></value></attr>',
      '<attr name="FX4"><value><option name="EFFECT_TYPE" value="4"/><option name="EFFECT_COLOR" value="040404"/></value></attr>',
      '<attr name="FX5"><value><option name="EFFECT_TYPE" value="5"/><option name="EFFECT_COLOR" value="050505"/></value></attr>',
      '<attr name="FX0"><value><option name="EFFECT_TYPE" value="0"/><option name="FOREGROUND" value="0a0a0a"/></value></attr>',
    }
    write(
      path,
      table.concat({
        '<scheme name="Mini" version="142" parent_scheme="Darcula">',
        '<metaInfo><property name="ide">TestIDE</property><property name="ideVersion">9.9</property></metaInfo>',
        '<colors><option name="CARET_ROW_COLOR" value="26282e"/><option name="SELECTED_INDENT_GUIDE" value="abcdef"/>',
        '<option name="VCS_ANNOTATIONS_COLOR_1" value="111111"/><option name="VCS_ANNOTATIONS_COLOR_2" value="222222"/></colors>',
        "<attributes>",
        table.concat(rows, "\n"),
        "</attributes></scheme>",
      }, "\n")
    )
  end

  it("without an input file prints a message, exits non-zero and writes nothing (no scheme is committed)", function()
    H.not_ok(vim.uv.fs_stat(H.repo .. "/tools/Dark.icls"), "the scheme export is not distributed")
    -- run a copy of tools/ so a stray default output would land in the scratch dir, never the checkout
    vim.fn.mkdir(work .. "/tools", "p")
    write(work .. "/tools/icls2nvim.py", read(H.repo .. "/tools/icls2nvim.py"))
    local r = py({ work .. "/tools/icls2nvim.py" }, work)
    H.ok(r.code ~= 0, "exit code " .. tostring(r.code))
    H.match(r.stderr, "no input", true)
    H.match(r.stderr, "SCHEME.icls", true)
    H.is_nil(vim.uv.fs_stat(work .. "/lua/island/palette.lua"), "nothing written")
  end)

  it("round trip: a synthetic .icls rebuilt from lua/island/palette.lua converts back to the same colours and attributes", function()
    H.write_icls(work .. "/fixture.icls")
    local r = py({ H.repo .. "/tools/icls2nvim.py", work .. "/fixture.icls", work .. "/out.lua" })
    H.eq(0, r.code, r.stderr)
    local got, want = dofile(work .. "/out.lua"), dofile(H.repo .. "/lua/island/palette.lua")
    H.eq(want.colors, got.colors)
    H.eq(want.attrs, got.attrs)
    H.eq(want.derived, got.derived)
    H.eq(want.name, got.name)
    H.match(r.stdout, "fixture.icls", true)
    H.ok(vim.tbl_count(want.attrs) > 100, "a real palette, not an empty one")
  end)

  it("is stdlib only (runs with -I -S: no site-packages)", function()
    H.write_icls(work .. "/fixture.icls")
    local r = py({ "-I", "-S", H.repo .. "/tools/icls2nvim.py", work .. "/fixture.icls", work .. "/out.lua" })
    H.eq(0, r.code, r.stderr)
    local src = read(H.repo .. "/tools/icls2nvim.py")
    for line in src:gmatch("[^\n]+") do
      local m = line:match("^import ([%w_%.]+)") or line:match("^from ([%w_%.]+) import")
      if m then
        H.ok(({ os = 1, sys = 1, ["xml.etree.ElementTree"] = 1 })[m], "non-stdlib import " .. m)
      end
    end
  end)

  it("accepts custom SCHEME.icls and OUT.lua arguments and creates the output directory", function()
    mini_icls(work .. "/mini.icls")
    local out = work .. "/deep/er/out.lua"
    local r = py({ H.repo .. "/tools/icls2nvim.py", work .. "/mini.icls", out })
    H.eq(0, r.code, r.stderr)
    H.match(r.stdout, "mini.icls", true)
    local P = dofile(out)
    H.eq("Mini", P.name)
    H.eq("#26282e", P.colors.CARET_ROW_COLOR)
    H.eq("#abcdef", P.derived.BORDER)
    H.eq("#222222", P.derived.SELECTION_BACKGROUND)
    H.eq("#111111", P.derived.SELECTION_STRONG)
    H.match(read(out), "from mini.icls", true)
    H.match(read(out), "TestIDE 9.9", true)
  end)

  it("resolves baseAttributes chains (cycle-safe) and the DEFAULT_* fallbacks", function()
    mini_icls(work .. "/mini.icls")
    local r = py({ H.repo .. "/tools/icls2nvim.py", work .. "/mini.icls", work .. "/out.lua" })
    H.eq(0, r.code, r.stderr) -- no infinite recursion on CYCLE_A <-> CYCLE_B
    local A = dofile(work .. "/out.lua").attrs
    H.eq({ fg = "#aa0000", bg = "#00bb00" }, A.CYCLE_A)
    H.eq({ bg = "#00bb00", fg = "#aa0000" }, A.CYCLE_B)
    H.eq({ fg = "#123456", italic = true }, A.CHILD, "own FONT_TYPE replaces the parent's, fg inherited")
    H.eq({ fg = "#bbb529" }, A.ANNOTATION_NAME_ATTRIBUTES, "empty entry takes its DEFAULT_ fallback")
    H.is_nil(A.EMPTY_NOFALLBACK, "empty entries without fallback are dropped")
  end)

  it("maps effect types 1/4 underline, 2 undercurl, 3 strikethrough, 5 underdotted, 0 none", function()
    mini_icls(work .. "/mini.icls")
    local r = py({ H.repo .. "/tools/icls2nvim.py", work .. "/mini.icls", work .. "/out.lua" })
    H.eq(0, r.code, r.stderr)
    local A = dofile(work .. "/out.lua").attrs
    H.eq({ effect = "underline", effect_color = "#010101" }, A.FX1)
    H.eq({ effect = "undercurl", effect_color = "#020202" }, A.FX2)
    H.eq({ effect = "strikethrough", effect_color = "#030303" }, A.FX3)
    H.eq({ effect = "underline", effect_color = "#040404" }, A.FX4)
    H.eq({ effect = "underdotted", effect_color = "#050505" }, A.FX5)
    H.eq({ fg = "#0a0a0a" }, A.FX0, "box effect has no nvim equivalent")
  end)
end)

-- ------------------------------------------------------------------ 6-10: colours

describe("island-dark colours", function()
  before_each(reset)

  it("Normal fg is #bcbec4, the scheme's solid bg #1e1f22 backs terminal colours; Normal bg is nil when transparent", function()
    H.eq("#bcbec4", fg("Normal"))
    H.is_nil(bg("Normal"), "transparent by default")
    -- the solid colour of the scheme
    H.eq("#1e1f22", pal().attrs.TEXT.bg)
    H.eq("#1e1f22", vim.g.terminal_color_background)
    H.eq("#1e1f22", vim.g.terminal_color_0)
  end)

  it("Normal has the solid #1e1f22 bg when transparency is off", function()
    vim.g.xynovim_transparent = false
    reload_scheme()
    H.eq("#1e1f22", bg("Normal"))
  end)

  it("popups keep a solid #2b2d30 background (also with transparency on)", function()
    H.is_nil(bg("Normal"))
    H.eq("#2b2d30", bg("NormalFloat"))
    H.eq("#2b2d30", bg("Pmenu"))
    H.eq("#666870", fg("FloatBorder"))
    H.eq("#2b2d30", bg("FloatBorder"))
  end)

  it("selection colour #2d416b is derived for Visual and PmenuSel", function()
    H.eq("#2d416b", bg("Visual"))
    H.eq("#2d416b", bg("PmenuSel"))
    H.is_nil(pal().colors.SELECTION_BACKGROUND, "the scheme itself has no selection colour")
  end)

  it("comment #82868c, doc comment #6f8f7a italic, error virtual text #f86574 on #402929", function()
    H.eq("#82868c", fg("Comment"))
    H.eq("#7a7e85", pal().attrs.DEFAULT_LINE_COMMENT.fg, "lifted from the scheme value")
    H.eq("#6f8f7a", fg("@comment.documentation"))
    H.ok(hl("@comment.documentation").italic, "doc comment is italic")
    H.eq("#5f826b", pal().attrs.DEFAULT_DOC_COMMENT.fg)
    H.eq("#f86574", fg("DiagnosticVirtualTextError"))
    H.eq("#402929", bg("DiagnosticVirtualTextError"))
  end)

  it("gutter and chrome: LineNr, CursorLine, CursorLineNr, StatusLineNC, GitSignsChange", function()
    H.eq("#6f737a", fg("LineNr"))
    H.eq("#242d42", bg("CursorLine"))
    H.eq("#a1a3ab", fg("CursorLineNr"))
    H.eq("#242d42", bg("CursorLineNr"))
    H.eq("#9da0a8", fg("StatusLineNC"))
    H.eq("#2b2d30", bg("StatusLineNC"))
    H.eq("#70aeff", fg("GitSignsChange"))
  end)
end)

-- ------------------------------------------------------------------ 11: contrast

describe("contrast", function()
  before_each(reset)
  local base = "#1e1f22"

  it("comment, doc comment and error virtual text reach 4.5:1", function()
    H.ok(ratio(fg("Comment"), base) >= 4.5, "comment " .. ratio(fg("Comment"), base))
    H.ok(ratio(fg("@comment.documentation"), base) >= 4.5, "doc comment")
    H.ok(ratio(fg("DiagnosticVirtualTextError"), bg("DiagnosticVirtualTextError")) >= 4.5, "error virtual text on its own bg")
    -- the lift stops at the first 1% step that reaches the target: the unlifted scheme colours miss it
    H.ok(ratio("#7a7e85", base) < 4.5)
    H.ok(ratio("#5f826b", base) < 4.5)
  end)

  it("line numbers are ~3.5:1 and the cursorline band ~1.20:1", function()
    near(3.5, ratio(fg("LineNr"), base), 0.1, "line numbers")
    near(1.20, ratio(bg("CursorLine"), base), 0.02, "cursorline")
  end)

  it("lift() keeps a colour that already meets the target and mixes toward white in 1% steps otherwise", function()
    -- lift() is local to lua/island/init.lua: check it through its callers.
    -- DiagnosticFloatingError = lift(red, float_bg, 4.5)
    local red = pal().attrs.CONSOLE_ERROR_OUTPUT.fg
    -- Comment: the smallest t in 0..100 (percent mix towards white) that reaches the target
    local function mix(c, t)
      local f = {}
      for i = 1, 3 do
        local v = tonumber(c:sub(2 * i, 2 * i + 1), 16)
        f[i] = v + (255 - v) * t / 100 + 0.5
      end
      return string.format("#%02x%02x%02x", f[1], f[2], f[3])
    end
    local float_t = 0
    while ratio(mix(red, float_t), "#2b2d30") < 4.5 do
      float_t = float_t + 1
    end
    H.eq(mix(red, float_t), fg("DiagnosticFloatingError"))
    if float_t == 0 then
      H.eq(red, fg("DiagnosticFloatingError"), "unchanged when the target is already met")
    end
    local src = pal().attrs.DEFAULT_LINE_COMMENT.fg
    local t = 0
    while ratio(mix(src, t), base) < 4.5 do
      t = t + 1
    end
    H.ok(t > 0 and t <= 100)
    H.eq(mix(src, t), fg("Comment"))
    H.ok(ratio(mix(src, t - 1), base) < 4.5, "one step less would miss the target")
  end)
end)

-- ------------------------------------------------------------------ 12-16: syntax, Rust, diagnostics

describe("island-dark syntax and diagnostics", function()
  before_each(reset)

  it("classic syntax groups and search/diff backgrounds", function()
    H.eq("#6aab73", fg("String"))
    H.eq("#cf8e6d", fg("Keyword"))
    H.eq("#56a8f5", fg("Function"))
    H.eq("#a6bb77", fg("Type"))
    H.eq("#56a8f5", fg("Directory"))
    H.eq("#dfe1e5", fg("Title"))
    H.ok(hl("Title").bold)
    H.eq("#114957", bg("Search"))
    H.eq("#165e70", bg("IncSearch"))
    H.ok(hl("IncSearch").bold)
    H.eq("#43454a", bg("MatchParen"))
    H.ok(hl("MatchParen").bold)
    H.eq("#21322c", bg("DiffAdd"))
    H.eq("#452e31", bg("DiffDelete"))
    H.eq("#25324d", bg("DiffChange"))
  end)

  it("Rust semantic tokens use the scheme's colours", function()
    H.eq("#3cacac", fg("@lsp.type.lifetime.rust"))
    H.eq(fg("@lsp.type.typeParameter"), fg("@lsp.type.lifetime.rust"), "type-parameter colour")
    H.eq("#a6bb77", fg("@lsp.type.enum.rust") or fg("@lsp.type.enum"))
    H.ok(hl("@lsp.type.enum").italic, "enum italic")
    H.eq("#d5a563", fg("@lsp.type.macro.rust") or fg("@lsp.type.macro"))
    H.eq(fg("@lsp.type.struct"), fg("@lsp.type.interface"), "traits use the struct colour")
  end)

  it("RustCfgDisabled is the olive CFG_DISABLED_CODE; inactive cfg code uses DiagnosticUnnecessary grey", function()
    H.eq("#8a8e57", fg("RustCfgDisabled"))
    H.eq("#6f737a", fg("DiagnosticUnnecessary"))
    H.eq(pal().attrs.NOT_USED_ELEMENT_ATTRIBUTES.fg, fg("DiagnosticUnnecessary"))
  end)

  it("inlay hints, code lens and window separator", function()
    H.eq("#868a91", fg("LspInlayHint"))
    H.eq("#393b40", bg("LspInlayHint"))
    H.eq("#727782", fg("LspCodeLens"))
    H.eq("#393b40", fg("WinSeparator"))
  end)

  it("diagnostic groups", function()
    H.eq("#f75464", fg("DiagnosticError"))
    H.eq("#f75464", fg("ErrorMsg"))
    H.eq("#e0bb65", fg("WarningMsg"))
    H.eq("#fa6675", sp("DiagnosticUnderlineError"))
    H.ok(hl("DiagnosticUnderlineError").undercurl)
    H.eq(pal().colors.ANNOTATIONS_COLOR, fg("DiagnosticHint"))
    H.eq(pal().colors.ANNOTATIONS_COLOR, fg("DiagnosticSignHint"))
  end)
end)

-- ------------------------------------------------------------------ 17-19: coverage of groups

describe("island-dark group coverage", function()
  before_each(reset)

  local function exists(name)
    local t = vim.api.nvim_get_hl(0, { name = name })
    return t ~= nil and next(t) ~= nil
  end

  it("plugin highlight groups are defined and non-empty", function()
    local groups = {
      "BlinkCmpMenu", "BlinkCmpMenuBorder", "BlinkCmpMenuSelection", "BlinkCmpScrollBarThumb",
      "SnacksNormal", "SnacksNormalNC", "SnacksWinBar", "SnacksBackdrop",
      "WhichKey", "WhichKeyGroup", "WhichKeyDesc", "WhichKeySeparator",
      "NeoTreeNormal", "NeoTreeNormalNC", "NeoTreeEndOfBuffer", "NeoTreeWinSeparator",
      "TroubleNormal", "TroubleNormalNC", "TroubleText", "TroubleCount",
      "GitSignsAdd", "GitSignsChange", "GitSignsDelete", "GitSignsTopdelete",
      "DiffviewNormal", "DiffviewCursorLine", "DiffviewWinSeparator", "DiffviewFilePanelTitle",
      "DapBreakpoint", "DapBreakpointCondition", "DapBreakpointRejected", "DapLogPoint",
      "NeotestPassed", "NeotestFailed", "NeotestRunning", "NeotestSkipped",
      "SatelliteBar", "SatelliteBackground", "SatelliteCursor", "SatelliteSearch",
      "TreesitterContext", "TreesitterContextLineNumber", "TreesitterContextBottom",
      "NavicText", "NavicSeparator",
      "FlashBackdrop", "FlashMatch", "FlashCurrent", "FlashLabel",
      "NoiceCmdline", "NoiceCmdlinePopup", "NoiceCmdlinePopupBorder",
      "MiniIconsBlue", "MiniIconsGreen", "MiniIconsRed", "MiniIconsGrey",
      "HarpoonWindow", "HarpoonBorder", "HarpoonTitle",
      "RenderMarkdownCode", "RenderMarkdownCodeInline", "RenderMarkdownCodeBorder", "RenderMarkdownBullet",
      "CoverageCovered", "CoveragePartial", "CoverageUncovered", "CoverageSummaryBorder",
      "LspInlayHint", "LspCodeLens", "LspCodeLensSeparator",
    }
    local missing = {}
    for _, g in ipairs(groups) do
      if not exists(g) then
        missing[#missing + 1] = g
      end
    end
    H.eq({}, missing)
  end)

  it("treesitter captures resolve to a non-empty highlight", function()
    local caps = {
      "@keyword", "@keyword.function", "@keyword.return", "@function", "@function.call", "@function.method",
      "@type", "@type.builtin", "@string", "@string.escape", "@comment", "@comment.documentation",
      "@variable", "@variable.builtin", "@variable.member", "@punctuation.delimiter", "@punctuation.bracket",
      "@punctuation.special", "@constant", "@number", "@operator", "@property", "@attribute",
      "@markup.strong", "@markup.italic", "@markup.heading", "@markup.heading.1", "@markup.link",
      "@markup.link.url", "@markup.raw", "@markup.quote",
    }
    local empty = {}
    for _, c in ipairs(caps) do
      local r = vim.api.nvim_get_hl(0, { name = c, link = false })
      if next(r) == nil then
        empty[#empty + 1] = c
      end
    end
    H.eq({}, empty)
  end)

  it("LSP semantic groups exist, including the scheme's org.rust.* colours", function()
    local groups = {
      "@lsp.type.struct", "@lsp.type.enum", "@lsp.type.enumMember", "@lsp.type.interface",
      "@lsp.type.typeParameter", "@lsp.type.function", "@lsp.type.method", "@lsp.type.macro",
      "@lsp.type.lifetime.rust", "@lsp.type.selfKeyword.rust", "@lsp.type.static.rust",
      "@lsp.mod.mutable.rust", "@lsp.mod.static.rust",
      "@lsp.typemod.function.declaration", "@lsp.typemod.method.trait.rust",
      "@lsp.typemod.variable.static.rust", "@lsp.typemod.comment.documentation.rust",
    }
    for _, g in ipairs(groups) do
      H.ok(next(hl(g)) ~= nil, g .. " is empty")
    end
    local A = pal().attrs
    H.eq(A["org.rust.STRUCT"].fg, fg("@lsp.type.struct"))
    H.eq(A["org.rust.ENUM"].fg, fg("@lsp.type.enum"))
    H.eq(A["org.rust.ENUM_VARIANT"].fg, fg("@lsp.type.enumMember"))
    H.eq(A["org.rust.FUNCTION"].fg, fg("@lsp.type.function"))
    H.eq(A["org.rust.METHOD"].fg, fg("@lsp.type.method"))
    H.eq(A["org.rust.MACRO"].fg, fg("@lsp.type.macro"))
    H.eq(A["org.rust.STATIC"].fg, fg("@lsp.type.static.rust"))
    H.eq(A["org.rust.SELF_PARAMETER"].fg, fg("@lsp.type.selfKeyword.rust"))
  end)

  it("terminal ANSI colours 0..15 and fg/bg are set from the scheme", function()
    local A, C = pal().attrs, pal().colors
    local expected = {
      [0] = A.TEXT.bg, A.CONSOLE_ERROR_OUTPUT.fg, A.DEFAULT_STRING.fg, A.LOG_INFO_OUTPUT.fg,
      A.DEFAULT_FUNCTION_DECLARATION.fg, A.DEFAULT_CONSTANT.fg, A.DEFAULT_NUMBER.fg, A.TEXT.fg,
    }
    for i = 0, 7 do
      H.eq(expected[i], vim.g["terminal_color_" .. i], "terminal_color_" .. i)
    end
    for i = 8, 15 do
      H.match(vim.g["terminal_color_" .. i] or "", "^#%x%x%x%x%x%x$", false, "terminal_color_" .. i)
    end
    H.eq(C.LINE_NUMBERS_COLOR, vim.g.terminal_color_8)
    H.eq(expected[1], vim.g.terminal_color_9)
    H.eq("#bcbec4", vim.g.terminal_color_foreground)
    H.eq("#1e1f22", vim.g.terminal_color_background)
    -- set at the end of setup(): wiping and reloading restores them
    vim.g.terminal_color_foreground, vim.g.terminal_color_background, vim.g.terminal_color_5 = nil, nil, nil
    reload_scheme()
    H.eq("#bcbec4", vim.g.terminal_color_foreground)
    H.eq("#1e1f22", vim.g.terminal_color_background)
    H.eq(A.DEFAULT_CONSTANT.fg, vim.g.terminal_color_5)
  end)
end)

-- ------------------------------------------------------------------ 20, 21: lualine theme

describe("lualine theme island-dark", function()
  before_each(reset)
  local file = H.repo .. "/lua/lualine/themes/island-dark.lua"

  it("defines all modes with a/b/c and the scheme's mode colours", function()
    local T = dofile(file)
    local A = pal().attrs
    H.eq("#56a8f5", T.normal.a.bg)
    H.eq("#1e1f22", T.normal.a.fg)
    H.eq("bold", T.normal.a.gui)
    for _, m in ipairs({ "normal", "insert", "visual", "replace", "command", "terminal", "inactive" }) do
      H.ok(T[m], m .. " defined")
      for _, s in ipairs({ "a", "b", "c" }) do
        H.ok(T[m][s] and T[m][s].fg and T[m][s].bg, m .. "." .. s)
      end
    end
    H.eq(A.DEFAULT_STRING.fg, T.insert.a.bg)
    H.eq(A.DEFAULT_CONSTANT.fg, T.visual.a.bg)
    H.eq(A.CONSOLE_ERROR_OUTPUT.fg, T.replace.a.bg)
    H.eq(A.LOG_INFO_OUTPUT.fg, T.command.a.bg)
    H.eq(A.DEFAULT_NUMBER.fg, T.terminal.a.bg)
  end)

  it("follows the active colourscheme after :colorscheme habamax (returns the auto theme)", function()
    require("lazy").load({ plugins = { "lualine.nvim" } })
    vim.cmd("colorscheme habamax")
    H.eq("habamax", vim.g.colors_name)
    local T = dofile(file)
    local auto = dofile(vim.api.nvim_get_runtime_file("lua/lualine/themes/auto.lua", false)[1])
    H.ok(T.normal and T.normal.a, "auto theme has modes")
    H.eq(type(auto), type(T))
    H.ok(T.normal.a.bg ~= "#56a8f5", "not the island blue any more")
    H.is_nil(T.inactive and T.inactive.a and T.inactive.a.bg == "#2b2d30" and 1 or nil, "not the island inactive bar")
  end)
end)

-- ------------------------------------------------------------------ 22, 23: transparency

describe("transparency", function()
  before_each(reset)
  after_each(reset)

  local transparent = {
    "Normal", "Terminal", "EndOfBuffer", "FoldColumn", "Folded", "SignColumn", "LineNr", "NormalNC",
    "NeoTreeNormal", "NeoTreeNormalNC", "NeoTreeVertSplit", "NeoTreeWinSeparator", "NeoTreeEndOfBuffer",
    "NvimTreeNormal", "NvimTreeVertSplit", "NvimTreeEndOfBuffer",
    "NotifyINFOBody", "NotifyERRORBody", "NotifyWARNBody", "NotifyTRACEBody", "NotifyDEBUGBody",
    "NotifyINFOTitle", "NotifyERRORTitle", "NotifyWARNTitle", "NotifyTRACETitle", "NotifyDEBUGTitle",
    "NotifyINFOBorder", "NotifyERRORBorder", "NotifyWARNBorder", "NotifyTRACEBorder", "NotifyDEBUGBorder",
  }

  local function bg_left()
    local left = {}
    for _, g in ipairs(transparent) do
      local t = hl(g)
      if t.bg ~= nil then
        left[#left + 1] = g
      end
    end
    return left
  end

  it("strips bg from the editor surface groups on every ColorScheme (augroup user_transparency)", function()
    H.eq(1, #vim.api.nvim_get_autocmds({ group = "user_transparency", event = "ColorScheme" }))
    H.eq({}, bg_left())
    -- give the groups a bg, a ColorScheme event removes it again
    for _, g in ipairs(transparent) do
      vim.api.nvim_set_hl(0, g, { fg = "#ffffff", bg = "#101010" })
    end
    H.eq(#transparent, #bg_left())
    vim.cmd("doautocmd ColorScheme")
    H.eq({}, bg_left())
    H.eq("#ffffff", fg("Normal"), "other attributes are kept")
  end)

  it("keeps the solid popup and cursor-row backgrounds", function()
    H.eq("#2b2d30", bg("NormalFloat"))
    H.eq("#2b2d30", bg("FloatBorder"))
    H.eq("#2b2d30", bg("Pmenu"))
    H.eq("#242d42", bg("CursorLineNr"))
  end)

  it("vim.g.xynovim_transparent = false keeps solid backgrounds", function()
    vim.g.xynovim_transparent = false
    reload_scheme()
    H.eq("#1e1f22", bg("Normal"))
    H.eq("#1e1f22", bg("SignColumn"))
    vim.cmd("doautocmd ColorScheme")
    H.eq("#1e1f22", bg("Normal"))
  end)

  it("<leader>uO toggles vim.g.xynovim_transparent, re-runs the scheme and survives a theme switch", function()
    H.open(H.tmpdir() .. "/t.txt")
    local map = vim.fn.maparg(vim.g.mapleader .. "uO", "n", false, true)
    if next(map) == nil then
      -- the toggle is only registered when Snacks was loaded as plugin/after ran
      skip("<leader>uO is not mapped in this session (Snacks not loaded when plugin/after/transparency.lua ran)")
    end
    H.eq("Toggle Transparent background", map.desc and map.desc:gsub("^%s*%[.-%]%s*", ""):gsub("^Disable ", "Toggle "):gsub("^Enable ", "Toggle ") or "")
    H.is_nil(bg("Normal"))
    H.feed("<leader>uO")
    H.eq(false, vim.g.xynovim_transparent)
    H.eq("#1e1f22", bg("Normal"), "toggled off")
    H.feed("<leader>uO")
    H.eq(true, vim.g.xynovim_transparent)
    H.is_nil(bg("Normal"), "toggled on")
    -- a transparent session survives a theme round trip
    vim.cmd("colorscheme tokyonight")
    H.is_nil(bg("Normal"), "tokyonight is transparent too")
    reload_scheme()
    H.is_nil(bg("Normal"))
    H.eq("#2b2d30", bg("NormalFloat"))
  end)
end)

-- ------------------------------------------------------------------ 24: unsafe highlight

describe("unsafe highlight", function()
  before_each(reset)

  it("@lsp.mod.unsafe.rust is underline; wiped by highlight clear; restored on ColorScheme", function()
    H.eq(true, hl("@lsp.mod.unsafe.rust").underline)
    vim.cmd("highlight clear")
    H.eq({}, hl("@lsp.mod.unsafe.rust"))
    H.eq(1, #vim.api.nvim_get_autocmds({ group = "user_unsafe_highlight", event = "ColorScheme" }))
    vim.cmd("doautocmd ColorScheme")
    H.eq(true, hl("@lsp.mod.unsafe.rust").underline)
  end)

  it("is still underline after a full :colorscheme island-dark", function()
    H.eq(true, hl("@lsp.mod.unsafe.rust").underline)
  end)
end)

-- ------------------------------------------------------------------ 25, 26: switching, idempotence

describe("switching and setup()", function()
  before_each(reset)
  after_each(reset)

  it(":colorscheme tokyonight and back to island-dark works", function()
    vim.cmd("colorscheme tokyonight")
    H.match(vim.g.colors_name, "^tokyonight")
    H.ok(fg("Normal") ~= "#bcbec4", "tokyonight has its own Normal")
    reload_scheme()
    H.eq("island-dark", vim.g.colors_name)
    H.eq("#bcbec4", fg("Normal"))
    H.eq("#6aab73", fg("String"))
  end)

  it("island-dark resets background to dark after a light preview", function()
    vim.o.background = "light"
    H.eq("light", vim.o.background)
    reload_scheme()
    H.eq("dark", vim.o.background)
    H.eq("#bcbec4", fg("Normal"))
  end)

  it("setup() is idempotent: calling it twice leaves identical highlights", function()
    local function snapshot()
      local out = {}
      for name in pairs(vim.api.nvim_get_hl(0, {})) do
        out[name] = vim.api.nvim_get_hl(0, { name = name })
      end
      return out
    end
    require("island").setup()
    local first = snapshot()
    local terms = {}
    for i = 0, 15 do terms[i] = vim.g["terminal_color_" .. i] end
    require("island").setup()
    require("island").setup()
    local second = snapshot()
    H.eq(first, second)
    for i = 0, 15 do
      H.eq(terms[i], vim.g["terminal_color_" .. i])
    end
  end)
end)

-- ------------------------------------------------------------------ 27, 28: informational numbers

describe("startup cost and legibility claims", function()
  before_each(reset)

  it("colourscheme load time (informational, not asserted)", function()
    local t0 = vim.uv.hrtime()
    for _ = 1, 20 do
      reload_scheme()
    end
    local ms = (vim.uv.hrtime() - t0) / 1e6 / 20
    print(("island-dark load: %.2f ms per :colorscheme (README claims ~2.3 ms)"):format(ms))
    H.ok(ms < 1000, "a load is not absurdly slow")
  end)

  it("README legibility numbers reproduce: comments 4.5, line numbers 3.5, modified 7.2 (hint 6.0 is inconsistent)", function()
    local base = "#1e1f22"
    H.ok(ratio(fg("Comment"), base) >= 4.5)
    near(3.5, ratio(fg("LineNr"), base), 0.1, "line numbers")
    local modified = ratio(fg("GitSignsChange"), base)
    local hint = ratio(fg("DiagnosticHint"), base)
    print(("git modified %.2f:1, hint %.2f:1 on #1e1f22"):format(modified, hint))
    near(7.2, modified, 0.1, "git modified (README: 7.2:1)")
    -- lua/island/init.lua's comment says the same colour is 6.0:1; the README says 7.2:1.
    -- 6.0 is neither the modified colour nor the hint colour here: documentation inconsistency.
    local readme = H.docs_text()
    H.match(readme, "7.2:1", true)
    local init = read(H.repo .. "/lua/island/init.lua")
    local says_6 = init:find("(6.0:1)", 1, true) ~= nil
    if says_6 then
      -- flagged, not failed: the measured 7.2 matches the README, the code comment is stale
      print("DOC INCONSISTENCY: lua/island/init.lua says FILESTATUS_MODIFIED is 6.0:1, README and measurement say 7.2:1")
    end
  end)
end)

-- ------------------------------------------------------------------ 29: rust-analyzer

describe("semantic tokens from rust-analyzer", function()
  it("resolve to scheme colours on real tokens", function()
    H.need_rust()
    reset()
    local dir = H.fixture("basic")
    local lines = {
      "use std::fmt::Debug;",
      "/// doc comment",
      "#[derive(Debug)]",
      "pub struct S { pub v: i32 }",
      "pub enum E { A, B }",
      "pub trait T { fn t(&self); }",
      "static ST: i32 = 1;",
      "const CO: i32 = 2;",
      "macro_rules! m { () => {}; }",
      "impl S {",
      "    pub fn get<'a>(&'a self, mut x: i32) -> &'a i32 {",
      "        x += 1;",
      "        let _e = E::A;",
      "        let _s = ST + CO + x;",
      "        m!();",
      "        unsafe { core::mem::zeroed::<i32>(); }",
      "        &self.v",
      "    }",
      "}",
    }
    write(dir .. "/src/lib.rs", table.concat(lines, "\n") .. "\n")
    H.open(dir .. "/src/lib.rs")
    H.wait_lsp("rust-analyzer", 0)
    local function groups_at(row, word, nth)
      local col = (lines[row]:find(word, nth or 1, true)) - 1
      local out = {}
      for _, t in ipairs(vim.inspect_pos(0, row - 1, col).semantic_tokens) do
        out[#out + 1] = t.opts.hl_group
      end
      return out
    end
    local function resolved(g)
      return hl(g)
    end
    -- wait for the structure to be analysed
    H.wait_for(function()
      return #groups_at(4, "S {") > 0
    end, 90000, "semantic tokens of the struct")
    local A = pal().attrs
    local function has_fg(row, word, expected, label)
      local gs
      -- tokens arrive in stages while rust-analyzer loads (and are not always
      -- re-requested when the analysis finishes): poll, asking again every 2s
      local n = 0
      vim.wait(45000, function()
        n = n + 1
        if n % 10 == 0 then
          pcall(vim.lsp.semantic_tokens.force_refresh, 0)
        end
        gs = groups_at(row, word)
        for _, g in ipairs(gs) do
          if hex(resolved(g).fg) == expected then
            return true
          end
        end
      end, 200)
      for _, g in ipairs(gs) do
        if hex(resolved(g).fg) == expected then
          return
        end
      end
      local all = {}
      for c = 0, #lines[row] do
        for _, t in ipairs(vim.inspect_pos(0, row - 1, c).semantic_tokens) do
          all[#all + 1] = c .. "=" .. t.opts.hl_group
        end
      end
      error(("%s: no token group at %d:%s resolves to %s (got %s; row: %s; buffer: %s)"):format(label, row, word, expected, vim.inspect(gs), table.concat(all, " "), vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]))
    end
    local function has_attr(row, word, attr, label)
      local found = vim.wait(30000, function()
        for _, g in ipairs(groups_at(row, word)) do
          if resolved(g)[attr] then
            return true
          end
        end
      end, 200)
      if found then
        return
      end
      error(("%s: no token group at %d:%s has %s"):format(label, row, word, attr))
    end
    has_fg(4, "S {", A["org.rust.STRUCT"].fg, "struct")
    has_fg(5, "E {", A["org.rust.ENUM"].fg, "enum")
    has_fg(6, "T {", A["org.rust.STRUCT"].fg, "trait uses the struct colour")
    has_fg(13, "A;", A["org.rust.ENUM_VARIANT"].fg, "enum variant")
    has_fg(15, "m!", A["org.rust.MACRO"].fg, "macro")
    has_fg(11, "'a", "#3cacac", "lifetime")
    has_fg(7, "ST", A["org.rust.STATIC"].fg, "static")
    has_fg(8, "CO", A.DEFAULT_CONSTANT.fg, "const")
    has_fg(11, "self", A["org.rust.SELF_PARAMETER"].fg, "self")
    has_fg(3, "Debug", A.DEFAULT_METADATA.fg, "derive")
    has_fg(2, "doc", fg("@comment.documentation"), "doc comment")
    has_attr(11, "x:", "underline", "mut binding")
    has_attr(16, "zeroed", "underline", "unsafe call")
  end)
end)
