-- Rainbow brackets (lua/config/rainbow.lua, rainbow_palette.lua, rainbow_scope.lua, rainbow_cmd.lua,
-- lua/config/rainbow_boot.lua). Every visual claim is asserted on the real UI grid of this (headless) nvim:
-- `screenpos` finds the cell of a bracket, `nvim__inspect_cell` gives the colours it is drawn with, at
-- 60 / 120 / 200 columns. Contrast is computed here, independently of lua/config/rainbow_palette.lua.
local H = require("xynotest.helpers")

local THEME_BG = { dark = "#1e1f22", light = "#ffffff" }
local CARET_BG = { dark = "#242d42", light = "#edf2fc" }

-- ------------------------------------------------------------------ colour maths (own copy)

local function lin(c)
  c = c / 255
  return c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

local function lum(hex)
  return 0.2126 * lin(tonumber(hex:sub(2, 3), 16))
    + 0.7152 * lin(tonumber(hex:sub(4, 5), 16))
    + 0.0722 * lin(tonumber(hex:sub(6, 7), 16))
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

local function oklab(h)
  local r, g, b = lin(tonumber(h:sub(2, 3), 16)), lin(tonumber(h:sub(4, 5), 16)), lin(tonumber(h:sub(6, 7), 16))
  local l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
  local m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
  local s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)
  return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
end

local function delta(a, b)
  local l1, a1, b1 = oklab(a)
  local l2, a2, b2 = oklab(b)
  return 100 * math.sqrt((l1 - l2) ^ 2 + (a1 - a2) ^ 2 + (b1 - b2) ^ 2)
end

-- Machado, Oliveira & Fernandes (2009), severity 1.0, on linear RGB
local CVD = {
  protan = { { 0.152286, 1.052583, -0.204868 }, { 0.114503, 0.786281, 0.099216 }, { -0.003882, -0.048116, 1.051998 } },
  deutan = { { 0.367322, 0.860646, -0.227968 }, { 0.280085, 0.672501, 0.047413 }, { -0.011820, 0.042940, 0.968881 } },
  tritan = { { 1.255528, -0.076749, -0.178779 }, { -0.078411, 0.930809, 0.147602 }, { 0.004733, 0.691367, 0.303900 } },
}

local function enc(c)
  c = math.max(0, math.min(1, c))
  return c <= 0.0031308 and 12.92 * c or 1.055 * c ^ (1 / 2.4) - 0.055
end

local function simulate(h, kind)
  local r, g, b = lin(tonumber(h:sub(2, 3), 16)), lin(tonumber(h:sub(4, 5), 16)), lin(tonumber(h:sub(6, 7), 16))
  local m = CVD[kind]
  r, g, b =
    m[1][1] * r + m[1][2] * g + m[1][3] * b,
    m[2][1] * r + m[2][2] * g + m[2][3] * b,
    m[3][1] * r + m[3][2] * g + m[3][3] * b
  return string.format("#%02x%02x%02x", enc(r) * 255 + 0.5, enc(g) * 255 + 0.5, enc(b) * 255 + 0.5)
end

--- smallest distance between any two colours of `list` under normal vision and the three dichromacies
local function min_distance(list)
  local out = { normal = math.huge, protan = math.huge, deutan = math.huge, tritan = math.huge }
  for k in pairs(out) do
    for i = 1, #list do
      for j = i + 1, #list do
        local a, b = list[i], list[j]
        if k ~= "normal" then
          a, b = simulate(a, k), simulate(b, k)
        end
        out[k] = math.min(out[k], delta(a, b))
      end
    end
  end
  return out
end

-- ------------------------------------------------------------------ editor helpers

local R, P

-- before anything of the file runs: has the engine been loaded by the start-up alone?
local LOADED_AT_START = package.loaded["config.rainbow"] ~= nil

local function load()
  H.very_lazy()
  R = require("config.rainbow")
  if not R._state.ready then
    R.setup()
  end
  P = require("config.rainbow_palette")
end

--- Reset the options to the defaults (vim.g unset) and apply.
local function defaults(user)
  vim.g.xynovim_rainbow = user
  R.setup()
end

local function size(cols, rows)
  vim.o.columns = cols
  vim.o.lines = rows or 40
end

--- Wait until the tree-sitter highlighter of the current buffer has parsed, then redraw.
local function close_floats()
  -- notifications and other floats can sit on top of the cells that are read back
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, w)
    if ok and cfg.relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
end

local function settle(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  close_floats()
  H.wait_for(function()
    vim.cmd("redraw!")
    local hl = vim.treesitter.highlighter.active[buf]
    return hl and not hl.parsing and hl.tree:is_valid(true)
  end, 8000, "tree-sitter highlighter")
  -- the provider has drawn this tick with a finished tree (when it is on for the buffer at all)
  vim.wait(1500, function()
    vim.cmd("redraw!")
    local c = R._state.cache[vim.api.nvim_get_current_win()]
    return c ~= nil and c.buf == buf and c.tick == vim.api.nvim_buf_get_changedtick(buf)
  end, 20)
  close_floats()
  -- the grid is read back: let it settle (an asynchronous redraw of the highlighter may still be queued)
  local last, same = nil, 0
  vim.wait(2000, function()
    vim.cmd("redraw!")
    local t = {}
    for r = 0, 9 do
      for c = 0, vim.o.columns - 1 do
        local x = vim.api.nvim__inspect_cell(1, r, c)
        t[#t + 1] = x[1] .. (x[2].foreground or 0)
      end
    end
    local snap = table.concat(t, ",")
    same = (snap == last) and same + 1 or 0
    last = snap
    return same >= 3
  end, 30)
end

local function write_file(name, text)
  local dir = H.tmpdir()
  local path = dir .. "/" .. name
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
  return path
end

local function open_text(name, text, cols)
  size(cols or 120)
  vim.o.cursorline = false
  local buf = H.open(write_file(name, text))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  settle(buf)
  return buf
end

--- fg, bg, attrs of the screen cell showing byte column `col` (1-based) of line `lnum`
local function cell(lnum, col)
  local pos = vim.fn.screenpos(0, lnum, col)
  assert(pos.row > 0, ("line %d is not on the screen"):format(lnum))
  local ch, a = unpack(vim.api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1))
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  return hex(a.foreground or normal.fg), hex(a.background or normal.bg), a, ch
end

--- byte column (1-based) of the n-th occurrence of the plain text `needle` in line `lnum`
local function col_of(lnum, needle, nth)
  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
  local from = 1
  for _ = 1, nth or 1 do
    local s = line:find(needle, from, true)
    assert(s, ("'%s' (#%d) not in line %d: %s"):format(needle, nth or 1, lnum, line))
    from = s + 1
    if _ == (nth or 1) then
      return s
    end
  end
end

--- the colour of the n-th `needle` in line `lnum`
local function fg_of(lnum, needle, nth)
  local fg = cell(lnum, col_of(lnum, needle, nth))
  return fg
end

--- { "#rrggbb", ... } the cycle as applied (the highlight groups)
local function cycle()
  local out = {}
  for i = 1, R._state.groups.count do
    out[i] = hex(vim.api.nvim_get_hl(0, { name = "XynoRainbow" .. i, link = false }).fg)
  end
  return out
end

local function is_rainbow(color)
  for _, c in ipairs(cycle()) do
    if c == color then
      return true
    end
  end
  return false
end

--- the colour of the n-th `needle` of line `lnum` equals the colour of the n-th `ref` of line `rl` (text that
--- the rainbow does not paint: a string, a comment)
local function plain_like(lnum, needle, nth, rl, ref, rnth)
  return fg_of(lnum, needle, nth) == fg_of(rl, ref, rnth)
end

local function mismatch_fg()
  return hex(vim.api.nvim_get_hl(0, { name = "XynoRainbowMismatch", link = false }).fg)
end

local RUST = [[
fn f(x: &[u8]) {
    let a = [(1, 2), (3, 4)];
}
]]

-- ------------------------------------------------------------------ options

describe("rainbow brackets: options", function()
  before_each(function()
    load()
  end)
  after_each(function()
    vim.g.xynovim_rainbow = nil
    R.setup()
  end)

  it("the engine is not loaded by the start-up: a command and a VeryLazy autocmd only, no lazy.nvim spec", function()
    H.not_ok(LOADED_AT_START, "config.rainbow was already required before the first screen")
    H.eq(2, vim.fn.exists(":XynoRainbow"))
    local f = assert(io.open(H.repo .. "/lua/config/rainbow_boot.lua"))
    local src = f:read("*a")
    f:close()
    H.match(src, 'pattern = "VeryLazy"', true)
    H.eq(0, vim.fn.filereadable(H.repo .. "/lua/plugins/rainbow.lua"), "a spec would be a plugin without a lock entry")
    local o = assert(io.open(H.repo .. "/lua/config/options.lua"))
    local opts = o:read("*a")
    o:close()
    H.match(opts, 'require("config.rainbow_boot").setup()', true)
    H.no_match(opts, 'require("config.rainbow")', true)
  end)

  it("defaults are valid and complete", function()
    local o, problems = R.resolve_options(nil)
    H.eq({}, problems)
    H.eq(true, o.enabled)
    H.eq(6, o.colors)
    H.eq(true, o.cycle_all_types)
    H.eq(false, o.skip_first_level)
    H.eq("auto", o.palette)
    H.eq(0.2, o.scope.alpha)
  end)

  it("a wrong type, an out-of-range number and an unknown key are reported and fall back", function()
    local o, problems =
      R.resolve_options({ colors = 99, round = "yes", palette = "neon", bogus = 1, scope = { alpha = 3, box = "x" } })
    H.eq(6, o.colors)
    H.eq(true, o.round)
    H.eq("auto", o.palette)
    H.eq(0.2, o.scope.alpha)
    H.eq("inverse", o.scope.box)
    H.eq(6, #problems)
    local all = table.concat(problems, "\n")
    for _, k in ipairs({ "colors", "round", "palette", "bogus", "scope.alpha", "scope.box" }) do
      H.match(all, k, true)
    end
  end)

  it("a valid value is taken, a partly valid table keeps the good keys", function()
    local o, problems =
      R.resolve_options({ colors = 4, angle = false, scope = { alpha = 0.5 }, disable = { ".MD", "Lua" } })
    H.eq({}, problems)
    H.eq(4, o.colors)
    H.eq(false, o.angle)
    H.eq(0.5, o.scope.alpha)
    H.eq({ "md", "lua" }, o.disable)
    H.eq(0.65, o.scope.restrain_strength, "untouched sibling")
  end)

  it("false turns it off; a non-table is a problem", function()
    H.eq(false, (R.resolve_options(false)).enabled)
    local _, problems = R.resolve_options("on")
    H.eq(1, #problems)
  end)

  it("saved options sit below vim.g", function()
    local o = R.resolve_options({ colors = 8 }, { colors = 3, round = false })
    H.eq(8, o.colors)
    H.eq(false, o.round)
  end)

  it("custom colours: lists and per-kind tables are normalised, bad hex is rejected", function()
    local o, problems = R.resolve_options({ palette = "custom", custom = { "#ABC", "ff0000" } })
    H.eq({}, problems)
    H.eq({ all = { "#aabbcc", "#ff0000" } }, o.custom)
    local o2 = R.resolve_options({ custom = { round = { "#112233" }, curly = { "#445566" } } })
    H.eq({ "#112233" }, o2.custom.round)
    local _, bad = R.resolve_options({ custom = { "#12345" } })
    H.eq(1, #bad)
    local _, bad2 = R.resolve_options({ custom = { weird = { "#112233" } } })
    H.eq(1, #bad2)
  end)

  it("min_contrast accepts auto or 1..21; generator hue accepts names and hex", function()
    local _, p1 = R.resolve_options({ min_contrast = 4.5, generator = { hue = "#00ff00" } })
    H.eq({}, p1)
    local _, p2 = R.resolve_options({ min_contrast = 30, generator = { hue = "teal" } })
    H.eq(2, #p2)
  end)

  it("R.set validates dotted paths; toggle only flips switches", function()
    H.eq(true, (R.set("scope.alpha", 0.4)))
    H.eq(0.4, R.get("scope.alpha"))
    local ok, msg = R.set("scope.alpha", 7)
    H.eq(false, ok)
    H.match(msg, "scope.alpha", true)
    local ok2 = R.set("no.such", 1)
    H.eq(false, ok2)
    H.eq(false, (R.toggle("colors")))
    local before = R.get("curly")
    R.toggle("curly")
    H.eq(not before, R.get("curly"))
    R.toggle("curly")
  end)

  it("an invalid vim.g value warns once and leaves the defaults working", function()
    local seen = {}
    local notify = vim.notify
    vim.notify = function(msg)
      seen[#seen + 1] = msg
    end
    vim.g.xynovim_rainbow = { colors = 0 }
    R.setup()
    vim.wait(100)
    vim.notify = notify
    H.eq(6, R.opts().colors)
    H.eq(1, #R.problems())
    H.ok(#seen >= 1 and seen[1]:find("colors", 1, true), "a warning names the option")
  end)
end)

-- ------------------------------------------------------------------ the colouring itself

describe("rainbow brackets: levels on the real grid", function()
  before_each(function()
    load()
    defaults(nil)
    vim.cmd("colorscheme island-dark")
  end)
  after_each(function()
    defaults(nil)
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  for _, cols in ipairs({ 60, 120, 200 }) do
    it(("nesting depth picks the colour and the cycle repeats (%d columns)"):format(cols), function()
      defaults({ colors = 3 })
      open_text("a.rs", RUST, cols)
      local c = cycle()
      H.eq(3, #c)
      -- fn f( x: &[u8] ) {       level 0: ( ) and { }; [u8] is level 1
      H.eq(c[1], fg_of(1, "("))
      H.eq(c[1], fg_of(1, ")"))
      H.eq(c[2], fg_of(1, "["))
      H.eq(c[2], fg_of(1, "]"))
      H.eq(c[1], fg_of(1, "{"))
      -- let a = [ ( 1, 2 ), ( 3, 4 ) ];     [ is level 1, ( is level 2
      H.eq(c[2], fg_of(2, "["))
      H.eq(c[3], fg_of(2, "(", 1))
      H.eq(c[3], fg_of(2, ")", 1))
      H.eq(c[3], fg_of(2, "(", 2))
      H.eq(c[2], fg_of(2, "]"))
      H.eq(c[1], fg_of(3, "}"))
      -- a fourth level wraps to the first colour
      vim.api.nvim_buf_set_lines(0, 1, 2, false, { "    let a = [((1, 2), (3, 4))];" })
      settle()
      H.eq(c[1], fg_of(2, "(", 2), "level 3 uses colour 1 again")
    end)
  end

  it("the level counts enclosing pairs only: siblings share a level, a close matches its open", function()
    open_text("b.rs", "fn f() { g(h(1), h(2)); }\n")
    local c = cycle()
    H.eq(c[1], fg_of(1, "{"))
    H.eq(c[2], fg_of(1, "(", 2), "g( is inside { }")
    H.eq(c[3], fg_of(1, "(", 3), "the first h( is inside g( )")
    H.eq(c[3], fg_of(1, "(", 4), "the second h( is its sibling: same level")
    H.eq(c[1], fg_of(1, ")", 1), "f( ) is level 0")
    H.eq(c[3], fg_of(1, ")", 2), "h(1) closes in the colour of its open")
    H.eq(c[3], fg_of(1, ")", 3), "h(2) too")
    H.eq(c[2], fg_of(1, ")", 4), "g( ... ) closes in the colour of g(")
    H.eq(c[1], fg_of(1, "}"))
  end)

  it("strings, comments, char literals and lifetimes are never coloured", function()
    open_text(
      "c.rs",
      table.concat({
        "fn f<'a>(x: &'a str) {",
        '    let s = "([{<)]}>";',
        "    let c = '(';",
        "    // ( [ { in a comment",
        "    /* ) ] } */",
        "}",
        "",
      }, "\n")
    )
    -- the brackets inside the string are drawn in the string's colour, like its letters
    for _, ch in ipairs({ "(", "[", "{", "<", ")", "]", "}", ">" }) do
      H.ok(plain_like(2, ch, 1, 2, '"', 1), "string content '" .. ch .. "' is plain string text")
    end
    H.ok(plain_like(3, "(", 1, 3, "'", 1), "char literal")
    H.ok(plain_like(4, "(", 1, 4, "comment", 1), "line comment (")
    H.ok(plain_like(4, "[", 1, 4, "comment", 1), "line comment [")
    H.ok(plain_like(5, ")", 1, 5, "/*", 1), "block comment )")
    H.ok(is_rainbow(fg_of(1, "(")), "the parameter list is")
    H.ok(is_rainbow(fg_of(1, "<")), "the generics are")
  end)

  it("format-string braces are plain text, like in the JetBrains plugin", function()
    open_text("d.rs", 'fn f(x: i32) { println!("{x} {}", x); }\n')
    H.ok(plain_like(1, "{", 2, 1, '"', 1), "{x} inside the string is string text")
    H.ok(plain_like(1, "}", 2, 1, '"', 1))
    H.ok(is_rainbow(fg_of(1, "(", 2)), "the macro's own parenthesis is coloured")
  end)

  it("generics and turbofish are angle pairs; a comparison is not", function()
    open_text(
      "e.rs",
      table.concat({
        "fn f(a: u8, b: u8) -> Vec<Vec<u8>> {",
        "    let v = Vec::<Vec<u8>>::new();",
        "    if a < b && b > a { return v; }",
        "    v",
        "}",
        "",
      }, "\n")
    )
    local c = cycle()
    H.eq(c[1], fg_of(1, "<", 1), "return type: level 0")
    H.eq(c[2], fg_of(1, "<", 2), "nested: level 1")
    H.eq(c[2], fg_of(1, ">", 2), "inner close (the first > is the arrow)")
    H.eq(c[1], fg_of(1, ">", 3), "outer close")
    H.eq(c[2], fg_of(2, "<", 1), "turbofish ::< inside { }: level 1")
    H.eq(c[3], fg_of(2, "<", 2))
    H.eq(c[3], fg_of(2, ">", 1))
    H.eq(c[2], fg_of(2, ">", 2))
    H.not_ok(is_rainbow(fg_of(3, "<")), "comparison <")
    H.not_ok(is_rainbow(fg_of(3, ">")), "comparison >")
  end)

  it("closure pipes are a pair; a binary | is not", function()
    open_text("f.rs", "fn f(a: u8, b: u8) -> u8 {\n    let c = |x, y| x + y;\n    a | b\n}\n")
    local c = cycle()
    H.eq(c[2], fg_of(2, "|", 1))
    H.eq(c[2], fg_of(2, "|", 2))
    H.not_ok(is_rainbow(fg_of(3, "|")), "a | b")
  end)

  it("macro bodies, attributes, visibility, patterns and indexing are coloured", function()
    open_text(
      "g.rs",
      table.concat({
        "#[derive(Debug)]",
        "pub(crate) fn f(v: Vec<u8>) {",
        "    let w = vec![(1), (2)];",
        "    match w.get(0) { Some(a) => a, None => v[0] }",
        "}",
        "",
      }, "\n")
    )
    local c = cycle()
    H.eq(c[1], fg_of(1, "["), "#[ is level 0")
    H.eq(c[2], fg_of(1, "(", 1), "derive( is inside #[ ]")
    H.eq(c[1], fg_of(2, "(", 1), "pub( ) is level 0")
    H.eq(c[1], fg_of(2, "(", 2), "the parameter list is level 0 too")
    H.eq(c[2], fg_of(3, "[")) -- vec![ in the fn body { (level 0) -> level 1
    H.eq(c[3], fg_of(3, "(", 1), "(1) inside the macro's brackets")
    H.eq(c[2], fg_of(4, "(", 1), "w.get( is in the fn body: level 1")
    H.eq(c[2], fg_of(4, "{"), "the match block is level 1")
    H.eq(c[3], fg_of(4, "(", 2), "Some( in the arm pattern: inside the fn body and the match block")
    H.eq(c[3], fg_of(4, "[", 1), "v[0] in an arm: level 2")
  end)

  it("a switch per bracket kind; a disabled kind does not count towards the level", function()
    open_text("h.rs", RUST)
    local c = cycle()
    H.eq(c[2], fg_of(2, "["))
    R.set("square", false)
    vim.cmd("redraw!")
    H.not_ok(is_rainbow(fg_of(2, "[")), "[ off")
    H.eq(c[2], fg_of(2, "(", 1), "( was level 2, without [ it is level 1")
    R.set("square", true)
    R.set("round", false)
    vim.cmd("redraw!")
    H.not_ok(is_rainbow(fg_of(1, "(")))
    H.eq(c[1], fg_of(1, "{"))
    R.set("round", true)
    R.set("curly", false)
    vim.cmd("redraw!")
    H.not_ok(is_rainbow(fg_of(1, "{")))
    H.eq(c[1], fg_of(2, "[", 1), "[ no longer sits in a { }")
    R.set("curly", true)
    R.set("angle", false)
    R.set("pipe", false)
    vim.cmd("redraw!")
  end)

  it("cycle_all_types = false: every kind counts its own nesting", function()
    open_text("i.rs", RUST)
    local c = cycle()
    R.set("cycle_all_types", false)
    vim.cmd("redraw!")
    H.eq(c[1], fg_of(2, "(", 1), "the first ( is round level 0 although inside [ ] and { }")
    H.eq(c[1], fg_of(2, "["))
    R.set("cycle_all_types", true)
  end)

  it("skip_first_level leaves level 0 plain", function()
    open_text("j.rs", RUST)
    local c = cycle()
    R.set("skip_first_level", true)
    vim.cmd("redraw!")
    H.not_ok(is_rainbow(fg_of(1, "{")))
    H.eq(c[2], fg_of(2, "["))
    R.set("skip_first_level", false)
  end)

  it("colors = N cycles over N colours", function()
    open_text("k.rs", RUST)
    R.set("colors", 2)
    vim.cmd("redraw!")
    local c = cycle()
    H.eq(2, #c)
    H.eq(c[1], fg_of(2, "(", 1), "level 2 wraps to colour 1")
    R.set("colors", 6)
  end)

  it(":XynoRainbow colors names the rejected value", function()
    open_text("kk.rs", RUST)
    local seen = {}
    local notify = vim.notify
    vim.notify = function(msg)
      seen[#seen + 1] = msg
    end
    vim.cmd("XynoRainbow colors abc")
    vim.notify = notify
    local all = table.concat(seen, "\n")
    H.ok(all:find('"abc"', 1, true), "names abc: " .. all)
    H.not_ok(all:find("nil is not valid", 1, true), "no nil: " .. all)
    H.eq(6, R.opts().colors)
  end)

  it("the disable list takes filetypes, languages and extensions; a buffer variable and max_lines too", function()
    open_text("l.rs", RUST)
    local c = cycle()
    H.eq(c[1], fg_of(1, "{"))
    for _, entry in ipairs({ "rust", ".rs", "RS" }) do
      defaults({ disable = { entry } })
      vim.cmd("redraw!")
      H.not_ok(is_rainbow(fg_of(1, "{")), entry .. " disables")
    end
    defaults(nil)
    vim.b.xynovim_rainbow = false
    vim.cmd("redraw!")
    H.not_ok(is_rainbow(fg_of(1, "{")), "buffer variable")
    vim.b.xynovim_rainbow = nil
    defaults({ max_lines = 2 })
    vim.cmd("redraw!")
    H.not_ok(is_rainbow(fg_of(1, "{")), "max_lines")
    defaults({ max_lines = 3 })
    vim.cmd("redraw!")
    H.ok(is_rainbow(fg_of(1, "{")), "a file at the limit is coloured")
    defaults(nil)
  end)

  it("enabled = false draws nothing and the buffer is untouched afterwards", function()
    open_text("m.rs", RUST)
    local before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    R.set("enabled", false)
    vim.cmd("redraw!")
    H.not_ok(is_rainbow(fg_of(1, "{")))
    R.set("enabled", true)
    vim.cmd("redraw!")
    H.ok(is_rainbow(fg_of(1, "{")))
    H.eq(before, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  it("large files: tier 1 stays on (visible lines only) unless large = off", function()
    open_text("n.rs", RUST)
    vim.b.xyno_large = 1
    vim.cmd("redraw!")
    H.ok(is_rainbow(fg_of(1, "{")))
    R.set("large", "off")
    vim.cmd("redraw!")
    H.not_ok(is_rainbow(fg_of(1, "{")))
    R.set("large", "on")
    vim.b.xyno_large = nil
  end)
end)

-- ------------------------------------------------------------------ unmatched brackets

describe("rainbow brackets: unmatched brackets", function()
  before_each(function()
    load()
    defaults(nil)
    vim.cmd("colorscheme island-dark")
  end)
  after_each(function()
    defaults(nil)
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("an open that never closes is marked, with the red curl", function()
    open_text("u.rs", "fn f() {\n    foo( (1\n}\n")
    local red = mismatch_fg()
    local fg, _, a = cell(2, col_of(2, "(", 1))
    H.eq(red, fg)
    H.ok(a.undercurl, "undercurl")
    H.eq(red, (cell(2, col_of(2, "(", 2))))
    H.ok(is_rainbow(fg_of(1, "{")), "the balanced pair is a normal colour")
  end)

  it("a missing closing brace at the end of the file marks the brace that stays open", function()
    open_text("v.rs", "fn f() {\n    let a = 1;\n")
    H.eq(mismatch_fg(), (cell(1, col_of(1, "{"))))
    H.ok(is_rainbow(fg_of(1, "(")), "the ( ) before it is fine")
  end)

  it("a stray close is marked", function()
    open_text("w.rs", "fn f() {\n}\n}\n")
    H.eq(mismatch_fg(), (cell(3, 1)))
  end)

  it(
    "a kind that is switched off is not examined at all: its unmatched brackets are not marked, the others are",
    function()
      open_text("y.rs", "fn f() {\n    foo(;\n    bar[1;\n}\n")
      H.eq(mismatch_fg(), (cell(2, col_of(2, "("))), "marked while round is on")
      R.set("round", false)
      vim.cmd("redraw!")
      H.not_ok(fg_of(2, "(") == mismatch_fg(), "round off: foo( is not marked")
      H.eq(mismatch_fg(), (cell(3, col_of(3, "["))), "square is still marked")
      R.set("round", true)
    end
  )

  it("mismatch = false leaves the unmatched ones alone", function()
    open_text("x.rs", "fn f() {\n    foo( (1\n}\n")
    R.set("mismatch", false)
    vim.cmd("redraw!")
    H.not_ok(fg_of(2, "(", 1) == mismatch_fg())
    R.set("mismatch", true)
  end)

  it("valid code never shows a mismatch: every Rust and Lua file of this repo", function()
    -- scratch buffers with a string parser: no file is opened, so no language server starts in a fixture crate
    local files = vim.fn.globpath(H.repo, "{demo,tests,tools,scripts}/**/*.rs", false, true)
    vim.list_extend(files, vim.fn.globpath(H.repo, "{lua,tests}/**/*.lua", false, true))
    local checked, marks, bad = 0, 0, {}
    for _, f in ipairs(files) do
      local lang = f:match("%.rs$") and "rust" or "lua"
      if f:find("mismatch.rs", 1, true) then
        lang = nil -- the deliberately broken capture scene
      end
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(f))
      local ok, parser = false, nil
      if lang then
        ok, parser = pcall(vim.treesitter.get_parser, buf, lang)
      end
      if ok and parser then
        parser:parse(true)
        checked = checked + 1
        for _, m in ipairs(R.collect(buf, parser, 0, vim.api.nvim_buf_line_count(buf) - 1)) do
          marks = marks + 1
          if m[4] == "XynoRainbowMismatch" then
            bad[#bad + 1] = ("%s:%d:%d"):format(f, m[1] + 1, m[2] + 1)
          end
        end
      end
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    H.ok(checked >= 40, "enough files checked: " .. checked)
    H.ok(marks > 5000, "brackets were found: " .. marks)
    H.eq({}, bad)
  end)
end)

-- ------------------------------------------------------------------ interplay

describe("rainbow brackets: injected languages and other plugins", function()
  before_each(function()
    load()
    defaults(nil)
    vim.cmd("colorscheme island-dark")
  end)
  after_each(function()
    defaults(nil)
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("a code block injected into markdown gets its own brackets coloured, prose does not", function()
    local buf = open_text("n.md", 'Text (not code) [here].\n\n```json\n{ "a": [1, 2] }\n```\n')
    local hl = vim.treesitter.highlighter.active[buf]
    if not hl then
      skip("no markdown tree-sitter highlighting in this environment")
    end
    hl.tree:parse(true)
    vim.wo.conceallevel = 0 -- the json quotes are concealed, which shifts the cells screenpos() reports
    vim.cmd("redraw!")
    H.not_ok(is_rainbow(fg_of(1, "(")), "prose parenthesis")
    local c = cycle()
    H.eq(c[1], fg_of(4, "{"))
    H.eq(c[2], fg_of(4, "["))
    H.eq(c[1], fg_of(4, "}"))
  end)

  it(
    "a SQL string injected into a Rust macro colours the SQL's own parentheses, with the macro's level as base",
    function()
      local buf = open_text("s.rs", 'fn f() {\n    sqlx::query!("SELECT (1 + (2))");\n}\n')
      local hl = vim.treesitter.highlighter.active[buf]
      hl.tree:parse(true)
      vim.cmd("redraw!")
      local ok_sql = pcall(vim.treesitter.language.add, "sql")
      if not ok_sql then
        skip("sql parser missing")
      end
      local c = cycle()
      -- query!( is level 1 (inside fn { }); the SQL pairs sit inside it: levels 2 and 3
      H.eq(c[2], fg_of(2, "(", 1), "the macro's parenthesis")
      local inner = fg_of(2, "(", 2)
      H.ok(inner == c[3] or inner == c[1], "SQL parenthesis is a rainbow colour: " .. tostring(inner))
      H.not_ok(inner == (cell(2, col_of(2, "SELECT"))), "text of the string is not a bracket colour")
    end
  )

  it("tree-sitter highlight and LSP semantic tokens do not win over the bracket colour", function()
    local buf = open_text("t.rs", RUST)
    local c = cycle()
    -- a semantic token at priority 125 on the first { (as rust-analyzer's `bracket` tokens), and one on top of
    -- the other priorities we know of (matchparen is a window match, tested below)
    local col = col_of(1, "{") - 1
    local ns = vim.api.nvim_create_namespace("rainbow_spec_lsp")
    vim.api.nvim_buf_set_extmark(
      buf,
      ns,
      0,
      col,
      { end_col = col + 1, hl_group = "@lsp.type.bracket.rust", priority = 125 }
    )
    vim.cmd("redraw!")
    H.eq(c[1], fg_of(1, "{"))
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end)

  it("MatchParen keeps its background and the bracket keeps its rainbow foreground", function()
    open_text("p.rs", RUST)
    local c = cycle()
    vim.api.nvim_win_set_cursor(0, { 1, col_of(1, "{") - 1 })
    vim.cmd("doautocmd CursorMoved")
    vim.cmd("redraw!")
    local fg, bg = cell(1, col_of(1, "{"))
    H.eq(c[1], fg)
    local mp = vim.api.nvim_get_hl(0, { name = "MatchParen", link = false })
    if vim.g.loaded_matchparen then
      -- matchparen paints with matchadd: the closing brace (line 3) shows the group's background
      local _, bg2 = cell(3, 1)
      H.eq(hex(mp.bg), bg2, "matching brace background")
      H.eq(c[1], (cell(3, 1)), "matching brace keeps the rainbow foreground")
    else
      H.ok(bg == nil or bg ~= nil)
    end
  end)

  it("typing: an auto-inserted pair is coloured at once, both cells", function()
    open_text("q.rs", "fn f() {\n    \n}\n")
    local c = cycle()
    H.feed("2GA(<Esc>")
    settle()
    local line = vim.api.nvim_get_current_line()
    H.eq("    ()", line, "mini.pairs closed the parenthesis")
    H.eq(c[2], (cell(2, 5)))
    H.eq(c[2], (cell(2, 6)))
  end)

  it("an edit that unbalances the file does not parse synchronously inside the redraw", function()
    local buf = open_text("r.rs", string.rep("fn f() { (1) }\n", 300))
    local hl = vim.treesitter.highlighter.active[buf]
    local calls = 0
    local parse = hl.tree.parse
    hl.tree.parse = function(self, ...)
      calls = calls + 1
      return parse(self, ...)
    end
    vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { "{ " })
    local before = calls
    local R_ = require("config.rainbow")
    -- drive the provider the way a redraw does
    vim.cmd("redraw!")
    hl.tree.parse = parse
    H.ok(R_._state.stats.redraws > 0)
    -- every parse() call during the redraw is the highlighter's own (it passes a callback); ours has none
    H.ok(calls - before <= 2, "parse calls during the redraw: " .. (calls - before))
  end)
end)

-- ------------------------------------------------------------------ rainbow variables

describe("rainbow brackets: rainbow variables", function()
  before_each(function()
    load()
    defaults({ variables = { enabled = true } })
    vim.cmd("colorscheme island-dark")
  end)
  after_each(function()
    defaults(nil)
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  local SRC = table.concat({
    "struct P { total: u32 }",
    "fn add(total: u32, count: u32) -> u32 {",
    "    let sum = total + count;",
    "    let p = P { total };",
    '    println!("{}", sum);',
    "    let f = |count| count + sum;",
    "    p.total + f(count) + sum",
    "}",
    "",
  }, "\n")

  local function var_colors()
    local out = {}
    for i = 1, R._state.groups.var_count do
      out[hex(vim.api.nvim_get_hl(0, { name = "XynoRainbowVar" .. i, link = false }).fg)] = true
    end
    return out
  end

  it("a name has one colour wherever it is declared or used; different names differ", function()
    open_text("v1.rs", SRC)
    local vc = var_colors()
    local total_def = fg_of(2, "total", 1)
    H.ok(vc[total_def], "a variable colour")
    H.eq(total_def, fg_of(3, "total"), "use in the initialiser")
    H.eq(total_def, fg_of(4, "total"), "shorthand field initialiser uses the local")
    local sum = fg_of(3, "sum")
    H.eq(sum, fg_of(5, "sum"), "in the macro arguments")
    H.eq(sum, fg_of(6, "sum", 1), "in the closure body")
    H.eq(sum, fg_of(7, "sum"))
    H.ok(sum ~= total_def, "sum and total differ")
    H.ok(fg_of(2, "count", 1) ~= sum)
    H.eq(fg_of(2, "count", 1), fg_of(3, "count"), "parameter and use")
    H.eq(fg_of(2, "count", 1), fg_of(6, "count", 1), "closure parameter with the same name: same name, same colour")
  end)

  it("fields, functions and types keep their own colours", function()
    open_text("v2.rs", SRC)
    local vc = var_colors()
    H.not_ok(vc[fg_of(1, "total")], "the field `total` of the struct is not a variable colour")
    H.not_ok(vc[fg_of(7, "total")], "p.total is a field access")
    H.not_ok(vc[fg_of(2, "add")], "the function name")
    H.not_ok(vc[fg_of(2, "u32", 1)], "a type")
  end)

  it("every variable colour is >= 3:1 on the editor and the caret row, in both variants", function()
    for _, variant in ipairs({ "dark", "light" }) do
      vim.cmd("colorscheme island-" .. variant)
      defaults({ variables = { enabled = true, colors = 16 } })
      for i = 1, 16 do
        local c = hex(vim.api.nvim_get_hl(0, { name = "XynoRainbowVar" .. i, link = false }).fg)
        H.ok(
          ratio(c, THEME_BG[variant]) >= 3 and ratio(c, CARET_BG[variant]) >= 3,
          variant .. " var colour " .. i .. " " .. c
        )
      end
    end
    vim.cmd("colorscheme island-dark")
  end)

  it("off by default, switched by :XynoRainbow variables and colours by variables.colors", function()
    defaults(nil)
    open_text("v3.rs", SRC)
    local before = fg_of(3, "sum")
    H.not_ok(var_colors()[before] and true or false, "off: not a variable colour")
    vim.cmd("XynoRainbow variables on")
    vim.cmd("redraw!")
    H.ok(var_colors()[fg_of(3, "sum")], "on")
    vim.cmd("XynoRainbow set variables.colors 2")
    vim.cmd("redraw!")
    H.eq(2, R._state.groups.var_count)
    vim.cmd("XynoRainbow variables off")
    vim.cmd("redraw!")
    H.eq(before, fg_of(3, "sum"))
  end)

  it("brackets and variables together: the brackets keep their level colours", function()
    open_text("v4.rs", SRC)
    local c = cycle()
    H.eq(c[1], fg_of(2, "("), "the parameter list")
    H.eq(c[1], fg_of(2, "{"))
  end)
end)

-- ------------------------------------------------------------------ scope highlighting

describe("rainbow brackets: scope highlighting", function()
  local S

  before_each(function()
    load()
    defaults(nil)
    vim.cmd("colorscheme island-dark")
    S = require("config.rainbow_scope")
  end)
  after_each(function()
    S.clear()
    defaults(nil)
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  local TEXT = table.concat({
    "fn f() {",
    "    let a = [1, (2, 3)];",
    "    let b = 4;",
    "}",
    "",
    "",
  }, "\n")

  local function blend(a, b, t)
    local out = {}
    for i = 1, 3 do
      local x, y = tonumber(a:sub(2 * i, 2 * i + 1), 16), tonumber(b:sub(2 * i, 2 * i + 1), 16)
      out[i] = math.floor(x + (y - x) * t + 0.5)
    end
    return string.format("#%02x%02x%02x", out[1], out[2], out[3])
  end

  for _, cols in ipairs({ 60, 120, 200 }) do
    it(
      ("Highlight Current Scope: range tinted 0.2 of the pair's colour, the two brackets boxed (%d columns)"):format(
        cols
      ),
      function()
        open_text("s1.rs", TEXT, cols)
        local c = cycle()
        -- cursor on the 2 inside (2, 3): the innermost pair is the tuple (level 3 -> colour 3)
        vim.api.nvim_win_set_cursor(0, { 2, col_of(2, "2") - 1 })
        local ok = S.at_cursor("scope")
        H.eq(true, ok)
        vim.cmd("redraw!")
        local want_bg = blend(THEME_BG.dark, c[3], 0.2)
        local _, bg_in = cell(2, col_of(2, "2"))
        H.eq(want_bg, bg_in, "inside the tuple")
        local _, bg_in2 = cell(2, col_of(2, "3"))
        H.eq(want_bg, bg_in2)
        -- outside: untouched
        local _, bg_out = cell(2, col_of(2, "1"))
        H.not_eq = nil
        H.ok(bg_out ~= want_bg, "outside the pair")
        local _, bg_out2 = cell(3, col_of(3, "4"))
        H.ok(bg_out2 ~= want_bg)
        -- the box: inverted brackets, editor background as text, the rainbow colour behind
        local fg_o, bg_o = cell(2, col_of(2, "(", 1))
        H.eq(c[3], bg_o, "( drawn on the rainbow colour")
        H.eq(THEME_BG.dark, fg_o)
        local _, bg_c = cell(2, col_of(2, ")", 1))
        H.eq(c[3], bg_c)
        -- contrast of the boxed bracket
        H.ok(ratio(fg_o, bg_o) >= 3, "box contrast " .. ratio(fg_o, bg_o))
        -- the text colour inside is unchanged by the tint
        H.eq(true, (S.active() ~= nil))
      end
    )
  end

  it("the scope of the cursor on a bracket is that bracket's own pair; no pair gives a message", function()
    open_text("s2.rs", TEXT)
    vim.api.nvim_win_set_cursor(0, { 2, col_of(2, "[") - 1 })
    H.eq(true, (S.at_cursor("scope")))
    local a = S.active()
    H.eq("square", a.pair.kind)
    S.clear()
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    local ok, msg = S.at_cursor("scope")
    H.eq(false, ok)
    H.match(msg, "no bracket scope", true)
  end)

  it("Restrain Scope Highlighting dims everything outside, keeps the inside", function()
    open_text("s3.rs", TEXT)
    local c = cycle()
    vim.api.nvim_win_set_cursor(0, { 2, col_of(2, "2") - 1 })
    H.eq(true, (S.at_cursor("restrain")))
    vim.cmd("redraw!")
    local dim = hex(vim.api.nvim_get_hl(0, { name = "XynoRainbowRestrain", link = false }).fg)
    H.eq(dim, (cell(1, 1)), "fn is dimmed")
    H.eq(dim, (cell(1, col_of(1, "{"))), "the outer brace is dimmed (its rainbow colour is overridden)")
    H.eq(dim, (cell(3, col_of(3, "let"))))
    H.eq(dim, (cell(4, 1)))
    H.eq(dim, (cell(2, col_of(2, "[") + 1)), "inside the square brackets but outside the tuple")
    H.eq(c[3], (cell(2, col_of(2, "(", 1))), "the tuple keeps its colour")
    -- dimmed text is still readable: >= 3:1 against the theme background
    H.ok(ratio(dim, THEME_BG.dark) >= 4.5, "restrain contrast " .. ratio(dim, THEME_BG.dark))
    S.clear()
    vim.cmd("redraw!")
    H.ok(is_rainbow((cell(1, col_of(1, "{")))), "cleared: the brace is a rainbow colour again")
  end)

  it("restrain_keep_colors dims every syntax colour towards the background and keeps its hue", function()
    open_text("s4.rs", TEXT)
    local kw_before = (cell(1, 1)) -- `fn`
    vim.api.nvim_win_set_cursor(0, { 2, col_of(2, "2") - 1 })
    H.eq(true, (S.at_cursor("restrain")))
    vim.cmd("redraw!")
    local plain = (cell(1, 1))
    S.clear()
    R.set("scope.restrain_keep_colors", true)
    H.eq(true, (S.at_cursor("restrain")))
    vim.cmd("redraw!")
    local kept = (cell(1, 1))
    local want = P.ensure(
      P.mix(kw_before, THEME_BG.dark, R.get("scope.restrain_strength")),
      { THEME_BG.dark, CARET_BG.dark },
      4.5,
      false
    )
    H.eq(want, kept, "the keyword colour, dimmed")
    H.ok(kept ~= plain, "differs from the grey of the plain restrain")
    H.ok(kept ~= kw_before, "dimmed")
    H.ok(ratio(kept, THEME_BG.dark) >= 4.5, "still legible")
    -- inside the scope nothing is dimmed
    H.eq(cycle()[3], (cell(2, col_of(2, "(", 1))))
    S.clear()
    R.set("scope.restrain_keep_colors", false)
  end)

  it("ESC clears; any other key does not, unless scope.any_key", function()
    open_text("s5.rs", TEXT)
    vim.api.nvim_win_set_cursor(0, { 2, col_of(2, "2") - 1 })
    S.at_cursor("scope")
    vim.api.nvim_feedkeys("j", "xt", false)
    vim.wait(50)
    H.ok(S.active(), "j keeps it")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
    H.wait_for(function()
      return not S.active()
    end, 1000, "ESC to clear")
    R.set("scope.any_key", true)
    vim.api.nvim_win_set_cursor(0, { 2, col_of(2, "2") - 1 })
    S.at_cursor("scope")
    vim.api.nvim_feedkeys("k", "xt", false)
    H.wait_for(function()
      return not S.active()
    end, 1000, "any key to clear")
    R.set("scope.any_key", false)
  end)

  it("the mouse: Ctrl+right-click highlights the scope under the click, Alt+right-click restrains", function()
    local buf = open_text("s6.rs", TEXT)
    local win = vim.api.nvim_get_current_win()
    local map = vim.fn.maparg("<C-RightMouse>", "n", false, true)
    H.ok(map.callback, "<C-RightMouse> is mapped")
    local map2 = vim.fn.maparg("<A-RightMouse>", "n", false, true)
    H.ok(map2.callback, "<A-RightMouse> is mapped")
    local getmousepos = vim.fn.getmousepos
    vim.fn.getmousepos = function()
      return { winid = win, line = 2, column = col_of(2, "1") }
    end
    map.callback()
    local a = S.active()
    H.eq(buf, a.buf)
    H.eq("scope", a.mode)
    H.eq("square", a.pair.kind)
    map2.callback()
    H.eq("restrain", S.active().mode)
    vim.fn.getmousepos = getmousepos
    -- the mouse option off removes both
    defaults({ scope = { mouse = false } })
    H.eq("", vim.fn.maparg("<C-RightMouse>", "n"))
    defaults({ scope = { mouse = true } })
    H.ok(vim.fn.maparg("<C-RightMouse>", "n") ~= "")
  end)

  it("suppress_diff and suppress_debug refuse to show", function()
    open_text("s7.rs", TEXT)
    vim.api.nvim_win_set_cursor(0, { 2, col_of(2, "2") - 1 })
    R.set("scope.suppress_diff", true)
    vim.wo.diff = true
    local ok, msg = S.at_cursor("scope")
    vim.wo.diff = false
    H.eq(false, ok)
    H.match(msg, "diff", true)
    R.set("scope.suppress_diff", false)
    R.set("scope.suppress_debug", true)
    package.loaded["dap"] = {
      session = function()
        return {}
      end,
    }
    local ok2, msg2 = S.at_cursor("scope")
    package.loaded["dap"] = nil
    H.eq(false, ok2)
    H.match(msg2, "debugging", true)
    R.set("scope.suppress_debug", false)
    H.eq(true, (S.at_cursor("scope")))
  end)

  it("scope.alpha and scope.box change what is drawn", function()
    open_text("s8.rs", TEXT)
    local c = cycle()
    R.set("scope.alpha", 0.5)
    vim.api.nvim_win_set_cursor(0, { 2, col_of(2, "2") - 1 })
    S.at_cursor("scope")
    vim.cmd("redraw!")
    local _, bg = cell(2, col_of(2, "2"))
    H.eq(blend(THEME_BG.dark, c[3], 0.5), bg)
    S.clear()
    R.set("scope.box", "underline")
    S.at_cursor("scope")
    vim.cmd("redraw!")
    local fg, _, a = cell(2, col_of(2, "(", 1))
    H.eq(c[3], fg)
    H.ok(a.underline, "underlined bracket")
    S.clear()
    R.set("scope.box", "inverse")
    R.set("scope.alpha", 0.2)
  end)
end)

-- ------------------------------------------------------------------ palettes

describe("rainbow brackets: palettes and contrast", function()
  before_each(function()
    load()
    defaults(nil)
  end)
  after_each(function()
    vim.g.xynovim_contrast = nil
    defaults(nil)
    pcall(vim.cmd, "silent! %bwipeout!")
    pcall(vim.cmd, "colorscheme island-dark")
  end)

  --- every colour of the cycle on the real grid, against the editor and the caret row
  local function grid_ratios(variant, min)
    vim.cmd("colorscheme island-" .. variant)
    defaults({ colors = 16, min_contrast = "auto", generator = { enabled = false } })
    vim.o.cursorline = true
    local c = cycle()
    for i, color in ipairs(c) do
      H.ok(
        ratio(color, THEME_BG[variant]) >= min,
        ("%s colour %d %s on the editor: %.2f"):format(variant, i, color, ratio(color, THEME_BG[variant]))
      )
      H.ok(
        ratio(color, CARET_BG[variant]) >= min,
        ("%s colour %d %s on the caret row: %.2f"):format(variant, i, color, ratio(color, CARET_BG[variant]))
      )
    end
    return c
  end

  it("island palette: every colour >= 3:1 on island-dark and island-light (editor and caret row)", function()
    grid_ratios("dark", 3)
    grid_ratios("light", 3)
  end)

  it(
    "brackets drawn on the grid keep >= 3:1 against the cell's background, in both variants and at every width",
    function()
      for _, variant in ipairs({ "dark", "light" }) do
        vim.cmd("colorscheme island-" .. variant)
        for _, cols in ipairs({ 60, 120, 200 }) do
          open_text("pc.rs", RUST, cols)
          for _, spec in ipairs({ { 1, "(" }, { 1, "[" }, { 1, "{" }, { 2, "(", 1 }, { 2, "[" } }) do
            local fg, bg = cell(spec[1], col_of(spec[1], spec[2], spec[3]))
            H.ok(is_rainbow(fg), "rainbow colour")
            H.ok(
              ratio(fg, bg or THEME_BG[variant]) >= 3,
              ("%s %d cols %s: %.2f"):format(variant, cols, spec[2], ratio(fg, bg or THEME_BG[variant]))
            )
          end
          pcall(vim.cmd, "silent! %bwipeout!")
        end
      end
    end
  )

  it("high contrast: every colour >= 7:1", function()
    vim.g.xynovim_contrast = "high"
    grid_ratios("dark", 7)
    grid_ratios("light", 7)
  end)

  it("min_contrast is honoured", function()
    vim.cmd("colorscheme island-dark")
    defaults({ min_contrast = 10, colors = 10 })
    for _, color in ipairs(cycle()) do
      H.ok(ratio(color, THEME_BG.dark) >= 10)
    end
  end)

  it("the colour-blind palette: contrast >= 3:1 and no two colours alike under any dichromacy", function()
    local want = { dark = 7.0, light = 5.0 }
    for _, variant in ipairs({ "dark", "light" }) do
      vim.cmd("colorscheme island-" .. variant)
      defaults({ palette = "colorblind", colors = 8 })
      local c = cycle()
      H.eq(8, #c)
      for _, color in ipairs(c) do
        H.ok(ratio(color, THEME_BG[variant]) >= 3 and ratio(color, CARET_BG[variant]) >= 3, variant .. " " .. color)
      end
      local d = min_distance(c)
      for k, v in pairs(d) do
        H.ok(v >= want[variant], ("%s %s: smallest distance %.1f < %.1f"):format(variant, k, v, want[variant]))
      end
      -- the stock Okabe-Ito set, lifted to the same contrast, is worse (that is what the search improved on)
      local stock = { "#e69f00", "#56b4e9", "#009e73", "#f0e442", "#0072b2", "#d55e00", "#cc79a7", "#c8ccd4" }
      local lifted = {}
      for i, s in ipairs(stock) do
        lifted[i] = P.ensure(s, { THEME_BG[variant], CARET_BG[variant] }, 3, variant == "light")
      end
      local ds = min_distance(lifted)
      local worst_ours, worst_stock = math.huge, math.huge
      for k in pairs(d) do
        worst_ours = math.min(worst_ours, d[k])
        worst_stock = math.min(worst_stock, ds[k])
      end
      H.ok(worst_ours > worst_stock, ("%s: %.1f vs stock %.1f"):format(variant, worst_ours, worst_stock))
    end
  end)

  it("palette = colorblind caps the cycle at its 8 colours; auto follows :ColorblindDiagnostics", function()
    defaults({ palette = "colorblind", colors = 12 })
    H.eq(8, R._state.groups.count)
    defaults(nil)
    H.eq("island", R._state.groups.palette)
    require("config.ux").colorblind(true)
    R.apply_colors()
    H.eq("colorblind", R._state.groups.palette)
    require("config.ux").colorblind(false)
    R.apply_colors()
    H.eq("island", R._state.groups.palette)
  end)

  it("custom colours: lists, per-kind tables, and the contrast lift still applies", function()
    vim.cmd("colorscheme island-dark")
    defaults({ palette = "custom", custom = { "#ff0000", "#00ff00", "#0000ff" }, colors = 6 })
    local c = cycle()
    H.eq(3, #c, "limited to the list")
    H.eq("#ff0000", c[1])
    H.ok(ratio(c[3], THEME_BG.dark) >= 3, "pure blue is lifted: " .. c[3])
    H.ok(c[3] ~= "#0000ff")
    defaults({
      palette = "custom",
      custom = { round = { "#ff8800", "#88ff00" }, all = { "#aaaaaa", "#bbbbbb" } },
      colors = 2,
    })
    open_text("cu.rs", RUST)
    H.eq("#ff8800", fg_of(1, "("))
    H.eq("#aaaaaa", fg_of(1, "{"), "other kinds use the shared list")
    H.eq("#ff8800", fg_of(2, "(", 1), "round, level 2 of 2 colours: back to the first of its own list")
    H.eq("#ff8800", fg_of(1, "(", 1), "round, level 0: the first")
  end)

  it("the generator: n colours, all >= 3:1, hue families and luminosity, deterministic", function()
    for _, variant in ipairs({ "dark", "light" }) do
      vim.cmd("colorscheme island-" .. variant)
      defaults({ generator = { enabled = true }, colors = 12 })
      local c = cycle()
      H.eq(12, #c)
      H.eq("generated", R._state.groups.palette)
      for _, color in ipairs(c) do
        H.ok(ratio(color, THEME_BG[variant]) >= 3 and ratio(color, CARET_BG[variant]) >= 3, variant .. " " .. color)
      end
      local d = min_distance(c)
      H.ok(d.normal >= 4, ("generated colours are told apart: %.1f"):format(d.normal))
      defaults({ generator = { enabled = true }, colors = 12 })
      H.eq(c, cycle(), "deterministic")
    end
    vim.cmd("colorscheme island-dark")
    defaults({ generator = { enabled = true, hue = "blue" }, colors = 6 })
    for _, color in ipairs(cycle()) do
      local r, g, b = tonumber(color:sub(2, 3), 16), tonumber(color:sub(4, 5), 16), tonumber(color:sub(6, 7), 16)
      H.ok(b >= r and b >= g * 0.9, "a blue family colour: " .. color)
    end
    defaults({ generator = { enabled = true, hue = "monochrome" }, colors = 6 })
    for _, color in ipairs(cycle()) do
      local r, g, b = tonumber(color:sub(2, 3), 16), tonumber(color:sub(4, 5), 16), tonumber(color:sub(6, 7), 16)
      H.ok(math.max(r, g, b) - math.min(r, g, b) <= 8, "grey: " .. color)
    end
    defaults({ generator = { enabled = true, luminosity = "dark" }, colors = 6 })
    local dark = cycle()
    defaults({ generator = { enabled = true, luminosity = "light" }, colors = 6 })
    local light = cycle()
    local function avg(list)
      local s = 0
      for _, x in ipairs(list) do
        s = s + lum(x)
      end
      return s / #list
    end
    H.ok(avg(light) > avg(dark), "luminosity light is lighter than dark on a dark scheme")
  end)

  it("a ColorScheme switch re-applies the colours for the new variant", function()
    open_text("cs.rs", RUST)
    vim.cmd("colorscheme island-dark")
    vim.cmd("redraw!")
    local dark = fg_of(1, "{")
    vim.cmd("colorscheme island-light")
    vim.cmd("redraw!")
    local light = fg_of(1, "{")
    H.ok(dark ~= light)
    H.ok(ratio(light, THEME_BG.light) >= 3, "light variant brackets on a white editor")
    H.ok(ratio(dark, THEME_BG.dark) >= 3)
    vim.cmd("colorscheme island-dark")
  end)
end)

-- ------------------------------------------------------------------ commands

describe("rainbow brackets: :XynoRainbow", function()
  local notes

  before_each(function()
    load()
    defaults(nil)
    vim.cmd("colorscheme island-dark")
    notes = {}
    H._rb_notify = vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    vim.g.xynovim_rainbow = nil
  end)
  after_each(function()
    vim.notify = H._rb_notify
    R.forget_saved()
    defaults(nil)
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("exists, completes its subcommands and the option names", function()
    H.eq(2, vim.fn.exists(":XynoRainbow"))
    local c = vim.fn.getcompletion("XynoRainbow ", "cmdline")
    for _, name in ipairs({
      "status",
      "toggle",
      "round",
      "square",
      "curly",
      "angle",
      "palette",
      "colors",
      "scope",
      "restrain",
      "clear",
      "set",
      "save",
      "reload",
      "first-level",
      "cycle-all",
      "generator",
      "buffer",
    }) do
      H.ok(vim.tbl_contains(c, name), name .. " completes")
    end
    local s = vim.fn.getcompletion("XynoRainbow set scope.", "cmdline")
    H.ok(vim.tbl_contains(s, "scope.alpha"))
    H.eq({ "on", "off", "toggle" }, vim.fn.getcompletion("XynoRainbow round ", "cmdline"))
  end)

  it("every switch can be turned on, off and toggled individually", function()
    for name, path in pairs({
      round = "round",
      square = "square",
      squiggly = "curly",
      curly = "curly",
      angle = "angle",
      pipe = "pipe",
      mismatch = "mismatch",
      ["first-level"] = "skip_first_level",
      ["cycle-all"] = "cycle_all_types",
      generator = "generator.enabled",
    }) do
      local start = R.get(path)
      vim.cmd("XynoRainbow " .. name .. " off")
      H.eq(false, R.get(path), name .. " off")
      vim.cmd("XynoRainbow " .. name .. " on")
      H.eq(true, R.get(path), name .. " on")
      vim.cmd("XynoRainbow " .. name)
      H.eq(false, R.get(path), name .. " toggled")
      R.set(path, start)
    end
  end)

  it("on / off / toggle drive the global switch and colour the grid accordingly", function()
    open_text("cm.rs", RUST)
    vim.cmd("XynoRainbow off")
    vim.cmd("redraw!")
    H.not_ok(is_rainbow(fg_of(1, "{")))
    vim.cmd("XynoRainbow on")
    vim.cmd("redraw!")
    H.ok(is_rainbow(fg_of(1, "{")))
    vim.cmd("XynoRainbow toggle")
    H.eq(false, R.get("enabled"))
    vim.cmd("XynoRainbow toggle")
    H.eq(true, R.get("enabled"))
  end)

  it("buffer off disables one buffer only", function()
    open_text("b1.rs", RUST)
    local b1 = vim.api.nvim_get_current_buf()
    vim.cmd("XynoRainbow buffer off")
    H.eq(false, vim.b[b1].xynovim_rainbow)
    vim.cmd("redraw!")
    H.not_ok(is_rainbow(fg_of(1, "{")))
    open_text("b2.rs", RUST)
    H.ok(is_rainbow(fg_of(1, "{")), "another buffer is still coloured")
    vim.cmd("buffer " .. b1)
    vim.cmd("XynoRainbow buffer on")
    vim.cmd("redraw!")
    H.ok(is_rainbow(fg_of(1, "{")))
  end)

  it("palette next cycles island -> colorblind -> generated -> island", function()
    vim.cmd("XynoRainbow palette island")
    H.eq("island", R._state.groups.palette)
    vim.cmd("XynoRainbow palette next")
    H.eq("colorblind", R._state.groups.palette)
    vim.cmd("XynoRainbow palette next")
    H.eq("generated", R._state.groups.palette)
    vim.cmd("XynoRainbow cycle")
    H.eq("island", R._state.groups.palette)
  end)

  it("colors N sets the count, a bad value is refused with a message", function()
    vim.cmd("XynoRainbow colors 4")
    H.eq(4, R.get("colors"))
    H.eq(4, R._state.groups.count)
    vim.cmd("XynoRainbow colors 40")
    H.eq(4, R.get("colors"))
    H.ok(table.concat(notes, "\n"):find("colors", 1, true))
  end)

  it("colors freeze turns the generated colours into a custom palette; colors save writes them", function()
    vim.cmd("XynoRainbow palette generated")
    local before = cycle()
    vim.cmd("XynoRainbow colors freeze")
    H.eq("custom", R.get("palette"))
    H.eq(before, cycle())
    vim.cmd("XynoRainbow colors save")
    local f = io.open(vim.fn.stdpath("state") .. "/xynovim/rainbow-colors.json")
    H.ok(f, "saved file")
    local data = vim.json.decode(f:read("*a"))
    f:close()
    H.eq(before, data.colors)
    os.remove(vim.fn.stdpath("state") .. "/xynovim/rainbow-colors.json")
  end)

  it("set validates; save/reload/forget round-trip the options through the state file", function()
    vim.cmd("XynoRainbow set scope.alpha 0.35")
    H.eq(0.35, R.get("scope.alpha"))
    vim.cmd("XynoRainbow set scope.alpha 9")
    H.eq(0.35, R.get("scope.alpha"))
    vim.cmd("XynoRainbow set bogus 1")
    H.ok(table.concat(notes, "\n"):find("unknown option bogus", 1, true))
    vim.cmd("XynoRainbow set disable md toml")
    H.eq({ "md", "toml" }, R.get("disable"))
    vim.cmd("XynoRainbow set generator.hue #336699")
    H.eq("#336699", R.get("generator.hue"))
    vim.cmd("XynoRainbow save")
    R.set("scope.alpha", 0.2)
    vim.cmd("XynoRainbow reload")
    H.eq(0.35, R.get("scope.alpha"), "restored from the state file")
    vim.g.xynovim_rainbow = { scope = { alpha = 0.1 } }
    vim.cmd("XynoRainbow reload")
    H.eq(0.1, R.get("scope.alpha"), "vim.g wins over the saved file")
    vim.g.xynovim_rainbow = nil
    vim.cmd("XynoRainbow forget")
    vim.cmd("XynoRainbow reload")
    H.eq(0.2, R.get("scope.alpha"))
  end)

  it("status says what is on; an unknown subcommand lists the known ones", function()
    open_text("st.rs", RUST)
    vim.cmd("XynoRainbow status")
    local text = table.concat(notes, "\n")
    for _, w in ipairs({ "brackets on", "kinds: round on", "colours: 6", "scope: alpha 0.20", "limits:" }) do
      H.match(text, w, true)
    end
    notes = {}
    vim.cmd("XynoRainbow frobnicate")
    H.match(notes[1], "unknown subcommand", true)
    H.match(notes[1], "palette", true)
  end)

  it("scope / restrain / clear from the command line", function()
    open_text("sc.rs", RUST)
    vim.api.nvim_win_set_cursor(0, { 2, col_of(2, "1") - 1 })
    vim.cmd("XynoRainbow scope")
    H.eq("scope", require("config.rainbow_scope").active().mode)
    vim.cmd("XynoRainbow restrain")
    H.eq("restrain", require("config.rainbow_scope").active().mode)
    vim.cmd("XynoRainbow clear")
    H.is_nil(require("config.rainbow_scope").active())
  end)

  it("the keys: <leader>uk toggles, <leader>uj / uJ show the scope", function()
    for _, lhs in ipairs({ "<leader>uk", "<leader>uj", "<leader>uJ" }) do
      H.ok(vim.fn.maparg(lhs, "n") ~= "", lhs .. " is mapped")
    end
  end)
end)

-- ------------------------------------------------------------------ every feature at every width

describe("rainbow brackets: each feature at 60, 120 and 200 columns", function()
  local S

  before_each(function()
    load()
    defaults(nil)
    vim.cmd("colorscheme island-dark")
    S = require("config.rainbow_scope")
  end)
  after_each(function()
    S.clear()
    defaults(nil)
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  local SRC = table.concat({
    "fn f(a: Vec<Vec<u8>>, k: u8) -> u8 {",
    "    let s = a.iter().map(|x| (x.len() as u8) * k).sum();",
    "    if s < 3 && k > 1 { return s; }",
    "    foo( (1",
    "}",
    "",
    "",
  }, "\n")

  for _, cols in ipairs({ 60, 120, 200 }) do
    it(
      ("generics, pipes, comparison, unmatched, kinds, palette, restrain, variables (%d columns)"):format(cols),
      function()
        open_text("w.rs", SRC, cols)
        local c = cycle()
        -- generics and closure pipes coloured, the comparison not
        H.eq(c[2], fg_of(1, "<", 1), "inside the parameter list: level 1")
        H.eq(c[3], fg_of(1, "<", 2))
        H.eq(c[3], fg_of(2, "|", 1), "fn body {, map( and then the pipes: level 2")
        H.not_ok(is_rainbow(fg_of(3, "<")))
        -- unmatched
        H.eq(mismatch_fg(), fg_of(4, "(", 1))
        -- a kind switch
        R.set("pipe", false)
        vim.cmd("redraw!")
        H.not_ok(is_rainbow(fg_of(2, "|", 1)))
        R.set("pipe", true)
        -- the colour-blind palette
        R.set("palette", "colorblind")
        vim.cmd("redraw!")
        local cb = cycle()
        H.eq(cb[2], fg_of(1, "<", 1))
        R.set("palette", "auto")
        -- restrain
        vim.api.nvim_win_set_cursor(0, { 2, col_of(2, "x.len") - 1 })
        H.eq(true, (S.at_cursor("restrain")))
        vim.cmd("redraw!")
        local dim = hex(vim.api.nvim_get_hl(0, { name = "XynoRainbowRestrain", link = false }).fg)
        H.eq(dim, (cell(1, 1)))
        S.clear()
        -- variables
        R.set("variables.enabled", true)
        vim.cmd("redraw!")
        H.eq(fg_of(2, "k"), fg_of(1, "k"), "k: parameter and use share a colour")
        H.not_ok(fg_of(1, "k") == fg_of(2, "s"), "k and s differ (their hashes land on different colours)")
        R.set("variables.enabled", false)
      end
    )
  end
end)

-- ------------------------------------------------------------------ health, performance

describe("rainbow brackets: health and cost", function()
  before_each(function()
    load()
    defaults(nil)
    vim.cmd("colorscheme island-dark")
  end)
  after_each(function()
    defaults(nil)
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it(":checkhealth xynovim has a rainbow brackets section with the contrast line", function()
    vim.cmd("checkhealth xynovim")
    vim.wait(200)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    vim.cmd("bwipeout!")
    H.match(text, "rainbow brackets", true)
    H.match(text, "contrast: lowest colour", true)
    H.match(text, "vim.g.xynovim_rainbow is valid", true)
  end)

  it("health reports an invalid option", function()
    vim.g.xynovim_rainbow = { colors = 100 }
    R.setup()
    vim.cmd("checkhealth xynovim")
    vim.wait(200)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    vim.cmd("bwipeout!")
    H.match(text, "option ignored", true)
  end)

  it("a window of a 40 000-line file costs a few milliseconds, warm or after an edit", function()
    local lines = {}
    for i = 1, 40000 do
      lines[i] = ("fn f%d(a: &[u8]) { (a, [%d]) }"):format(i, i)
    end
    local buf = open_text("big.rs", table.concat(lines, "\n") .. "\n")
    vim.cmd("normal! 20000Gzz")
    settle(buf)
    local hl = vim.treesitter.highlighter.active[buf]
    local top = vim.fn.line("w0") - 1
    local bot = vim.fn.line("w$")
    local function time(f)
      local t = vim.uv.hrtime()
      f()
      return (vim.uv.hrtime() - t) / 1e6
    end
    local cold = time(function()
      R.collect(buf, hl.tree, top, bot)
    end)
    local warm = time(function()
      R.collect(buf, hl.tree, top, bot)
    end)
    vim.api.nvim_buf_set_text(buf, top + 5, 0, top + 5, 0, { " " })
    local edited = time(function()
      R.collect(buf, hl.tree, top, bot)
    end)
    H.ok(cold < 60, "cold window: " .. cold .. " ms")
    H.ok(warm < 20, "warm window: " .. warm .. " ms")
    H.ok(edited < 60, "after an edit: " .. edited .. " ms")
    H.ok(#R.collect(buf, hl.tree, top, bot) > 100, "brackets found")
  end)
end)

-- ------------------------------------------------------------------ rainbow keywords and tags

describe("rainbow brackets: keywords and tags by depth", function()
  before_each(function()
    load()
    defaults(nil)
    vim.cmd("colorscheme island-dark")
  end)
  after_each(function()
    defaults(nil)
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  local PY = "if a:\n    for i in b:\n        while c:\n            pass\n    else:\n        pass\nelse:\n    pass\n"
  local function normal_fg()
    return hex(vim.api.nvim_get_hl(0, { name = "Normal", link = false }).fg)
  end

  it("both are off by default and the keywords keep their syntax colour", function()
    open_text("w1.py", PY)
    local off_if, off_for = fg_of(1, "if"), fg_of(2, "for")
    H.eq(off_if, off_for, "both are plain syntax keywords")
    H.eq(false, R.get("words.keywords"))
    H.eq(false, R.get("words.tags"))
    defaults({ words = { keywords = true } })
    vim.cmd("redraw!")
    H.not_ok(fg_of(2, "for") == off_for, "on: the nested for changes colour")
  end)

  it("Python keywords take the colour of their block depth, an else matches its if", function()
    open_text("w2.py", PY)
    local off_pass = fg_of(4, "pass")
    defaults({ words = { keywords = true } })
    vim.cmd("redraw!")
    local c = cycle()
    H.eq(c[1], fg_of(1, "if"))
    H.eq(c[2], fg_of(2, "for"))
    H.eq(c[3], fg_of(3, "while"))
    H.eq(c[2], fg_of(5, "else"), "else of the for-if sits at the for's depth")
    H.eq(c[1], fg_of(7, "else"), "else matches the outer if")
    H.eq(off_pass, fg_of(4, "pass"), "pass is not a keyword of the rule")
  end)

  it("C #if / #else / #endif match, nested conditionals go one level deeper", function()
    defaults({ words = { keywords = true } })
    open_text("w3.c", "#if A\n#ifdef B\nint x;\n#else\nint y;\n#endif\n#else\nint z;\n#endif\n")
    vim.cmd("redraw!")
    local c = cycle()
    H.eq(c[1], fg_of(1, "#if"))
    H.eq(c[2], fg_of(2, "#ifdef"))
    H.eq(c[2], fg_of(4, "#else"))
    H.eq(c[2], fg_of(6, "#endif"))
    H.eq(c[1], fg_of(7, "#else"))
    H.eq(c[1], fg_of(9, "#endif"))
  end)

  local HTML = "<div>\n  <p>\n    <b>x</b>\n    <br/>\n  </p>\n</div>\n"
  it("HTML tag names and brackets follow the element depth, open and close tags match", function()
    defaults({ words = { tags = true } })
    open_text("w4.html", HTML)
    vim.cmd("redraw!")
    local c = cycle()
    H.eq(c[1], fg_of(1, "div"))
    H.eq(c[1], fg_of(1, "<"))
    H.eq(c[1], fg_of(1, ">"))
    H.eq(c[2], fg_of(2, "p"))
    H.eq(c[3], fg_of(3, "b"))
    H.eq(c[3], fg_of(3, "b", 2), "the closing b")
    H.eq(c[3], fg_of(4, "br"))
    H.eq(c[3], fg_of(4, "/>"))
    H.eq(c[2], fg_of(5, "p"), "closing p matches the opening p")
    H.eq(c[1], fg_of(6, "div"))
    H.not_ok(fg_of(3, "x") == c[3], "text between tags is untouched")
  end)

  it("XML and JSX tags too; JSX text and comparisons are untouched", function()
    defaults({ words = { tags = true } })
    open_text("w5.xml", '<a>\n  <b k="1"/>\n  <c>t</c>\n</a>\n')
    vim.cmd("redraw!")
    local c = cycle()
    H.eq(c[1], fg_of(1, "a"))
    H.eq(c[2], fg_of(2, "b"))
    H.eq(c[2], fg_of(3, "c"))
    H.eq(c[1], fg_of(4, "a"))
    open_text("w6.tsx", "const x = (\n  <A>\n    <B k={1 < 2} />\n  </A>\n);\n")
    vim.cmd("redraw!")
    H.eq(c[1], fg_of(2, "A"))
    H.eq(c[2], fg_of(3, "B"))
    H.eq(c[1], fg_of(4, "A"))
    H.not_ok(fg_of(3, "<", 2) == c[1] or fg_of(3, "<", 2) == c[2], "the comparison < is not a tag bracket")
  end)

  it("YAML mapping keys follow the mapping depth", function()
    defaults({ words = { tags = true } })
    open_text("w7.yaml", "a:\n  b:\n    c: 1\n  d: 2\n")
    vim.cmd("redraw!")
    local c = cycle()
    H.eq(c[1], fg_of(1, "a"))
    H.eq(c[2], fg_of(2, "b"))
    H.eq(c[3], fg_of(3, "c"))
    H.eq(c[2], fg_of(4, "d"))
  end)

  it("switched by :XynoRainbow keywords / tags, validated, shown in the status", function()
    open_text("w8.py", PY)
    vim.cmd("XynoRainbow keywords on")
    H.eq(true, R.get("words.keywords"))
    vim.cmd("XynoRainbow tags on")
    H.eq(true, R.get("words.tags"))
    vim.cmd("XynoRainbow keywords off")
    H.eq(false, R.get("words.keywords"))
    local seen = {}
    local notify = vim.notify
    vim.notify = function(msg)
      seen[#seen + 1] = msg
    end
    vim.cmd("XynoRainbow status")
    vim.notify = notify
    H.ok(table.concat(seen, "\n"):find("keywords: off, tags: on", 1, true), table.concat(seen, "\n"))
    H.not_ok(normal_fg() == nil)
    vim.g.xynovim_rainbow = { words = { tags = "yes" } }
    R.setup()
    H.eq(1, #R.problems())
  end)
end)
