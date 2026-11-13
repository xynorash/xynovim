-- :XynoRainbow, the command set of the rainbow brackets (lua/config/rainbow.lua). Every switch of the
-- JetBrains plugin's settings page is reachable here: `:XynoRainbow status` lists them.
local M = {}

local function R()
  return require("config.rainbow")
end

local function say(msg, level)
  vim.notify("rainbow brackets: " .. msg, level or vim.log.levels.INFO)
end

-- subcommand "toggle name" -> option path
local SWITCHES = {
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
  ["any-key"] = "scope.any_key",
  ["keep-colors"] = "scope.restrain_keep_colors",
  ["suppress-debug"] = "scope.suppress_debug",
  ["suppress-diff"] = "scope.suppress_diff",
  mouse = "scope.mouse",
  variables = "variables.enabled",
  keywords = "words.keywords",
  tags = "words.tags",
}

local ACTIONS = { "on", "off", "toggle" }

local function switch(path, action)
  local cur = R().get(path)
  local want
  if action == nil or action == "toggle" then
    want = not cur
  elseif action == "on" then
    want = true
  elseif action == "off" then
    want = false
  else
    return false, "expected on, off or toggle, got " .. action
  end
  -- "first-level" is phrased as "rainbowify the first level": on = colour it
  local ok, v = R().set(path, want)
  return ok, ok and ("%s = %s"):format(path, tostring(v)) or v
end

local function status_lines()
  local o = R().opts()
  local st = R().status()
  local function onoff(v)
    return v and "on" or "off"
  end
  local lines = {
    ("brackets %s (%s)%s"):format(
      onoff(o.enabled),
      st.treesitter and (st.eligible and "this buffer: coloured" or "this buffer: not coloured")
        or "this buffer: no tree-sitter",
      vim.b.xynovim_rainbow == false and ", disabled for this buffer" or ""
    ),
    ("kinds: round %s, square %s, curly %s, angle %s, pipe %s; unmatched %s"):format(
      onoff(o.round),
      onoff(o.square),
      onoff(o.curly),
      onoff(o.angle),
      onoff(o.pipe),
      onoff(o.mismatch)
    ),
    ("colours: %d from palette %s%s; cycle over %s; first level %s; min contrast %s"):format(
      st.colors or o.colors,
      st.palette or o.palette,
      o.generator.enabled and (" (generator: " .. o.generator.hue .. ", " .. o.generator.luminosity .. ")") or "",
      o.cycle_all_types and "all kinds" or "each kind",
      o.skip_first_level and "plain" or "coloured",
      tostring(o.min_contrast)
    ),
    ("keywords: %s, tags: %s (by depth; Python, C #if / HTML, XML, JSX, YAML keys)"):format(
      onoff(o.words.keywords),
      onoff(o.words.tags)
    ),
    ("variables: %s (%d colours, by name)"):format(onoff(o.variables.enabled), o.variables.colors),
    ("scope: alpha %.2f, restrain %.2f%s, clear with %s, mouse %s, box %s"):format(
      o.scope.alpha,
      o.scope.restrain_strength,
      o.scope.restrain_keep_colors and " (keeps colours)" or "",
      o.scope.any_key and "any key" or "ESC",
      onoff(o.scope.mouse),
      o.scope.box
    ),
    ("limits: max_lines %s, large files %s, priority %d, disabled: %s"):format(
      o.max_lines == 0 and "none" or o.max_lines,
      o.large,
      o.priority,
      #o.disable > 0 and table.concat(o.disable, ",") or "-"
    ),
  }
  for _, p in ipairs(R().problems()) do
    lines[#lines + 1] = "problem: " .. p
  end
  return lines
end

--- Echo the colours as swatches: each number in its own colour.
local function show_colors()
  local groups = R()._state.groups
  if not groups then
    return
  end
  local chunks = { { "rainbow colours: ", "Normal" } }
  for i = 1, groups.count do
    chunks[#chunks + 1] = {
      ("%d %s  "):format(
        i,
        vim.api.nvim_get_hl(0, { name = "XynoRainbow" .. i }).fg
            and string.format("#%06x", vim.api.nvim_get_hl(0, { name = "XynoRainbow" .. i }).fg)
          or "?"
      ),
      "XynoRainbow" .. i,
    }
  end
  vim.api.nvim_echo(chunks, false, {})
end

local function colors_list()
  local out = {}
  local groups = R()._state.groups
  for i = 1, groups and groups.count or 0 do
    out[i] = string.format("#%06x", vim.api.nvim_get_hl(0, { name = "XynoRainbow" .. i }).fg)
  end
  return out
end

local PALETTES = { "island", "colorblind", "generated" }

local function next_palette()
  local o = R().opts()
  local cur = o.generator.enabled and "generated" or R()._state.groups.palette
  local nxt = PALETTES[(vim.fn.index(PALETTES, cur) + 1) % #PALETTES + 1]
  if nxt == "generated" then
    R().set("generator.enabled", true)
  else
    R().set("generator.enabled", false)
    R().set("palette", nxt)
  end
  return nxt
end

local SUBS = {}

SUBS.status = function()
  for _, l in ipairs(status_lines()) do
    say(l)
  end
end
SUBS.on = function()
  R().set("enabled", true)
  say("on")
end
SUBS.off = function()
  R().set("enabled", false)
  say("off")
end
SUBS.toggle = function()
  local _, v = R().toggle("enabled")
  say(v and "on" or "off")
end
SUBS.buffer = function(args)
  local a = args[1] or "toggle"
  local cur = vim.b.xynovim_rainbow ~= false
  local want = a == "on" or (a == "toggle" and not cur)
  if want then
    vim.b.xynovim_rainbow = nil
  else
    vim.b.xynovim_rainbow = false
  end
  R().refresh()
  say("this buffer: " .. (want and "on" or "off"))
end
SUBS.palette = function(args)
  local a = args[1]
  if not a or a == "next" or a == "cycle" then
    local n = next_palette()
    say("palette " .. n)
  elseif a == "generated" then
    R().set("generator.enabled", true)
    say("palette generated")
  elseif a == "island" or a == "colorblind" or a == "auto" or a == "custom" then
    R().set("generator.enabled", false)
    local ok, msg = R().set("palette", a)
    say(ok and ("palette " .. a) or msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
  else
    say("palette: island, colorblind, generated, custom, auto or next", vim.log.levels.WARN)
  end
  show_colors()
end
SUBS.cycle = SUBS.palette
SUBS.colors = function(args)
  local a = args[1]
  if a == nil or a == "show" then
    show_colors()
  elseif a == "freeze" then
    -- keep the generated (or current) colours: they become palette = custom
    local list = colors_list()
    R().set("generator.enabled", false)
    R().set("custom", list)
    R().set("palette", "custom")
    say("colours frozen as palette custom: " .. table.concat(list, " "))
  elseif a == "save" then
    local list = colors_list()
    local dir = vim.fn.stdpath("state") .. "/xynovim"
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/rainbow-colors.json"
    local f = io.open(path, "w")
    if f then
      f:write(vim.json.encode({ colors = list, variant = vim.o.background }))
      f:close()
      say("saved " .. #list .. " colours to " .. path)
    else
      say("could not write " .. path, vim.log.levels.ERROR)
    end
  else
    local n = tonumber(a) or a -- a non-number stays as typed so the error names it
    local ok, msg = R().set("colors", n)
    say(ok and ("colours " .. n) or msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
    show_colors()
  end
end
SUBS.hue = function(args)
  local ok, msg = R().set("generator.hue", args[1])
  say(ok and ("generator hue " .. args[1]) or msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
end
SUBS.luminosity = function(args)
  local ok, msg = R().set("generator.luminosity", args[1])
  say(ok and ("generator luminosity " .. args[1]) or msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
end
SUBS.scope = function()
  local ok, msg = require("config.rainbow_scope").at_cursor("scope")
  if not ok then
    say(msg)
  end
end
SUBS.restrain = function()
  local ok, msg = require("config.rainbow_scope").at_cursor("restrain")
  if not ok then
    say(msg)
  end
end
SUBS.clear = function()
  require("config.rainbow_scope").clear()
end
local function parse_scalar(raw)
  if raw == "true" then
    return true
  elseif raw == "false" then
    return false
  elseif tonumber(raw) then
    return tonumber(raw)
  elseif raw:find("^[%[{]") then
    local ok, v = pcall(vim.json.decode, raw)
    return ok and v or raw
  end
  return raw
end

--- The value of `:XynoRainbow set <path> <value...>`: a scalar, JSON, or several words as a list
--- (`set custom #ff0000 #00ff00`, `set disable md toml`); `set disable` alone, `[]` or `none` clear a list.
local function parse_value(path, values)
  local is_list = path == "disable" or path == "custom"
  if #values == 0 then
    return path == "disable" and {} or nil
  end
  if #values == 1 then
    local raw = values[1]
    if is_list and (raw == "none" or raw == "-" or raw == "[]") then
      return {}
    end
    local v = parse_scalar(raw)
    if is_list and type(v) == "string" then
      return { v }
    end
    return v
  end
  if is_list then
    return values
  end
  return vim.tbl_map(parse_scalar, values)
end

SUBS.set = function(args)
  local path = args[1]
  local value = path and parse_value(path, vim.list_slice(args, 2))
  if not path or value == nil then
    say("usage: :XynoRainbow set <option> <value>   (e.g. scope.alpha 0.3; lists: set custom #f00 #0f0, set disable md toml)", vim.log.levels.WARN)
    return
  end
  local ok, msg = R().set(path, value)
  say(ok and ("%s = %s"):format(path, vim.inspect(msg)) or msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
end
SUBS.reload = function()
  R().setup()
  say("reloaded from vim.g.xynovim_rainbow")
end
SUBS.save = function()
  local ok, msg = R().save()
  say(ok and ("saved to " .. msg) or ("could not save: " .. tostring(msg)), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
end
SUBS.forget = function()
  R().forget_saved()
  say("saved options removed; :XynoRainbow reload applies the defaults")
end
SUBS.health = function()
  vim.cmd("checkhealth xynovim")
end

for name, path in pairs(SWITCHES) do
  SUBS[name] = function(args)
    local ok, msg = switch(path, args[1])
    say(msg, ok and vim.log.levels.INFO or vim.log.levels.WARN)
  end
end

function M.names()
  local t = vim.tbl_keys(SUBS)
  table.sort(t)
  return t
end

function M.run(opts)
  local args = opts.fargs
  local sub = table.remove(args, 1) or "status"
  local fn = SUBS[sub]
  if not fn then
    say("unknown subcommand '" .. sub .. "'; one of: " .. table.concat(M.names(), ", "), vim.log.levels.WARN)
    return
  end
  fn(args)
end

function M.complete(arglead, cmdline)
  local parts = vim.split(vim.trim(cmdline), "%s+")
  local n = #parts - (cmdline:match("%s$") and 0 or 1)
  if n <= 1 then
    return vim.tbl_filter(function(s)
      return vim.startswith(s, arglead)
    end, M.names())
  end
  local sub = parts[2]
  local opts
  if SWITCHES[sub] or sub == "buffer" then
    opts = ACTIONS
  elseif sub == "palette" or sub == "cycle" then
    opts = { "island", "colorblind", "generated", "custom", "auto", "next" }
  elseif sub == "colors" then
    opts = { "show", "freeze", "save", "4", "5", "6", "8", "10" }
  elseif sub == "hue" then
    opts = { "any", "red", "orange", "yellow", "green", "blue", "purple", "pink", "monochrome" }
  elseif sub == "luminosity" then
    opts = { "bright", "light", "dark" }
  elseif sub == "set" and n == 2 then
    opts = {}
    local function walk(spec, prefix)
      for k, v in pairs(spec) do
        if type(v) == "table" and not (v.int or v.num or v.enum) then
          walk(v, prefix .. k .. ".")
        else
          opts[#opts + 1] = prefix .. k
        end
      end
    end
    walk(R().SPEC, "")
    table.sort(opts)
  end
  return vim.tbl_filter(function(s)
    return vim.startswith(s, arglead)
  end, opts or {})
end

--- The :checkhealth xynovim section.
function M.health()
  local rb = R()
  local P = require("config.rainbow_palette")
  local h = vim.health
  local S = rb._state
  if not S.ready then
    h.info("not set up yet (it starts at VeryLazy, or with the first :XynoRainbow); showing the defaults")
    rb.setup()
  end
  local o = rb.opts()
  if #rb.problems() == 0 then
    h.ok("options: vim.g.xynovim_rainbow is valid" .. (vim.g.xynovim_rainbow == nil and " (not set: defaults)" or ""))
  else
    for _, p in ipairs(rb.problems()) do
      h.warn("option ignored: " .. p, "see docs/RAINBOW.md for the option table")
    end
  end
  h.info(
    ("%s; %d colours, palette %s; kinds round %s square %s curly %s angle %s pipe %s; unmatched marking %s"):format(
      o.enabled and "on" or "OFF",
      S.groups and S.groups.count or 0,
      S.groups and S.groups.palette or "?",
      tostring(o.round),
      tostring(o.square),
      tostring(o.curly),
      tostring(o.angle),
      tostring(o.pipe),
      tostring(o.mismatch)
    )
  )
  -- contrast of every colour of this scheme variant against the editor and caret-row backgrounds
  local surfaces, target = P.surfaces(), P.min_contrast(o)
  local worst, worst_hex = math.huge, nil
  for i = 1, S.groups and S.groups.count or 0 do
    local fg = vim.api.nvim_get_hl(0, { name = "XynoRainbow" .. i, link = false }).fg
    if fg then
      local hex = string.format("#%06x", fg)
      local r = P.worst_ratio(hex, surfaces)
      if r < worst then
        worst, worst_hex = r, hex
      end
    end
  end
  if worst_hex and worst + 0.005 >= target then
    h.ok(
      ("contrast: lowest colour %s is %.2f:1 on %s (minimum %.1f:1, %s background)"):format(
        worst_hex,
        worst,
        table.concat(surfaces, " / "),
        target,
        P.variant()
      )
    )
  elseif worst_hex then
    h.warn(
      ("contrast: %s is %.2f:1, below the minimum %.1f:1"):format(worst_hex, worst, target),
      "the colours are lifted when they are applied: :XynoRainbow reload"
    )
  end
  -- grammars
  local ok_rust = pcall(vim.treesitter.language.add, "rust")
  if ok_rust then
    h.ok("tree-sitter rust parser found (other languages follow the buffers that have tree-sitter highlighting)")
  else
    h.warn("tree-sitter rust parser missing: no brackets are coloured in Rust files", ":TSInstall rust")
  end
  local st = rb.status()
  h.info(
    ("provider: %d redraws, %d rebuilt, slowest %.1f ms, last %.2f ms (this session)"):format(
      st.stats.redraws,
      st.stats.rebuilt,
      st.stats.max_us / 1000,
      st.stats.last_us / 1000
    )
  )
  local buf = vim.api.nvim_get_current_buf()
  local tier = vim.b[buf].xyno_large or 0
  if tier > 0 then
    h.info(
      ("current buffer: large-file tier %d; rainbow brackets %s there (large = %q)"):format(
        tier,
        o.large == "on" and "stay on, visible lines only" or "are off",
        o.large
      )
    )
  end
  if vim.g.xynovim_contrast == "high" then
    h.info("high contrast variant: bracket colours are held at 7:1")
  end
end

return M
