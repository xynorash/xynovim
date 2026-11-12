-- Colours for the rainbow brackets (lua/config/rainbow.lua): the built-in palettes, the colour generator,
-- the contrast guarantee and the highlight groups.
--
-- Every colour that reaches the screen is lifted (OKLab lightness only, hue kept) until it is at least
-- `min_contrast`:1 (WCAG 2.x, default 3:1 for bracket glyphs, 7:1 with `vim.g.xynovim_contrast = "high"`)
-- against BOTH the editor background and the caret-row background, so a bracket stays legible on the
-- cursor line too. The editor background is the scheme's, not the terminal's: with the transparent
-- Normal group the variants assume #1e1f22 (island-dark) and #ffffff (island-light).
local M = {}

local L = require("island.light")

M.MAX = 16

--- Hand-picked base colours. dark = for the Island Dark surface, light = for Island Light. They are
--- starting points: `resolve` lifts whatever is below the contrast target on the real surface.
M.BASE = {
  -- the accents of the Island scheme first (gold, orchid, blue, orange, green, cyan), then four more
  -- hues that sit between them
  island = {
    dark = {
      "#e0bb65",
      "#c77dbb",
      "#56a8f5",
      "#cf8e6d",
      "#6aab73",
      "#2aacb8",
      "#b4c857",
      "#8f9cf2",
      "#e38f8f",
      "#5fd0a3",
    },
    light = {
      "#8f6400",
      "#92308c",
      "#1a5fb8",
      "#a1481a",
      "#26733a",
      "#08707d",
      "#667a0a",
      "#4a4fc9",
      "#a63f55",
      "#0b7d5f",
    },
  },
  -- Starts from the Okabe & Ito (2008) "color universal design" hues (orange, sky blue, bluish green, yellow,
  -- blue, vermillion, reddish purple + a neutral), then a hill-climbing search moved lightness, chroma and
  -- hue (+-14 degrees) to maximise the smallest OKLab distance between any two colours as seen with normal
  -- vision and under simulated protanopia, deuteranopia and tritanopia (Machado et al. 2009, severity 1;
  -- tritan distances weighted 1.4), with every colour >= 3:1 on the editor and caret-row backgrounds.
  -- Smallest pair distance (OKLab x 100, 60 000 steps, seed 7): dark 7.1 (tritan-weighted 10.0), light 4.9
  -- (weighted 6.9); the stock Okabe-Ito set lifted to 3:1 had 5.9 and 1.0. tests/rainbow_spec.lua recomputes them.
  colorblind = {
    dark = { "#efb31a", "#36adf6", "#04a76d", "#ffe73e", "#5981be", "#df711f", "#d290b1", "#c8ccd4" },
    light = { "#7d4b05", "#1562a4", "#166745", "#717316", "#2d7aad", "#c77160", "#9e3578", "#45484e" },
  },
}

M.NAMES = { "island", "colorblind" }
--- The number of colours a palette offers before the cycle repeats (the colour-blind set has 8 colours
--- that stay apart under dichromacy; more would only repeat them).
M.LIMIT = { island = 10, colorblind = 8, custom = 16, generated = 16 }

-- ----------------------------------------------------------------------------- colour helpers

local function hexnum(h)
  return tonumber(h:sub(2), 16)
end

local function tohex(n)
  return string.format("#%06x", n)
end

local function mix(a, b, t)
  local out = {}
  for i = 1, 3 do
    local x = tonumber(a:sub(2 * i, 2 * i + 1), 16)
    local y = tonumber(b:sub(2 * i, 2 * i + 1), 16)
    out[i] = math.floor(x + (y - x) * t + 0.5)
  end
  return string.format("#%02x%02x%02x", out[1], out[2], out[3])
end
M.mix = mix

M.ratio = L.ratio

function M.valid_hex(s)
  return type(s) == "string" and s:match("^#%x%x%x%x%x%x$") ~= nil
end

--- "#rgb" / "#rrggbb" / "rrggbb" -> "#rrggbb" (lower case) or nil
function M.normalize(s)
  if type(s) ~= "string" then
    return nil
  end
  s = s:lower():gsub("^%s+", ""):gsub("%s+$", "")
  s = s:gsub("^#?(%x%x%x)$", function(c)
    return "#" .. c:gsub(".", "%0%0")
  end)
  if s:match("^%x%x%x%x%x%x$") then
    s = "#" .. s
  end
  return M.valid_hex(s) and s or nil
end

local function hue_of(hex)
  local _, a, b = L.to_oklab(hex)
  return (math.deg(math.atan2(b, a))) % 360
end

-- ----------------------------------------------------------------------------- surfaces

local function variant()
  return vim.o.background == "light" and "light" or "dark"
end
M.variant = variant

--- { editor background, caret-row background } the colours must stand out against.
function M.surfaces()
  local light = variant() == "light"
  local function bg(name, fallback)
    local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    return ok and h.bg and tohex(h.bg) or fallback
  end
  return {
    bg("Normal", light and "#ffffff" or "#1e1f22"),
    bg("CursorLine", light and "#edf2fc" or "#242d42"),
  }
end

function M.min_contrast(o)
  if o.min_contrast ~= "auto" then
    return o.min_contrast
  end
  return vim.g.xynovim_contrast == "high" and 7.0 or 3.0
end

--- `fg` lifted to `target`:1 on every surface (the lowest ratio decides).
function M.ensure(fg, surfaces, target, light)
  local out = fg
  for _, on in ipairs(surfaces) do
    if M.ratio(out, on) < target then
      out = light and L.darken_to(out, on, target) or L.lighten_to(out, on, target)
    end
  end
  return out
end

--- The smallest contrast ratio of `hex` over the surfaces.
function M.worst_ratio(hex, surfaces)
  local w = math.huge
  for _, on in ipairs(surfaces) do
    w = math.min(w, M.ratio(hex, on))
  end
  return w
end

-- ----------------------------------------------------------------------------- generator

local HUES = { red = 25, orange = 55, yellow = 95, green = 145, blue = 255, purple = 305, pink = 355 }
local LUMI = {
  dark = { bright = 0.78, light = 0.86, dark = 0.68 },
  light = { bright = 0.52, light = 0.60, dark = 0.40 },
}

--- `n` colours that stay apart: golden-angle hues (or one hue family when `hue` names one),
--- alternating lightness inside a family. Deterministic.
---@param n integer
---@param g table { hue = "any"|"red"|...|"monochrome"|"#rrggbb", luminosity = "bright"|"light"|"dark" }
function M.generate(n, g, light)
  local lum = LUMI[light and "light" or "dark"][g.luminosity or "bright"]
  local center, spread, chroma = nil, 360, 0.13
  local hue = g.hue or "any"
  if hue == "monochrome" then
    chroma = 0
  elseif HUES[hue] then
    center, spread = HUES[hue], 28
  elseif M.valid_hex(hue) then
    center, spread = hue_of(hue), 28
  end
  local out = {}
  for i = 1, n do
    local h
    if center then
      -- a hue family: walk across the spread, lightness alternates so neighbours differ
      h = center + (((i * 0.618034) % 1) - 0.5) * spread
    else
      h = (30 + i * 137.508) % 360
    end
    local lightness = lum + ((i % 3 == 0) and 0.06 or (i % 3 == 1) and 0 or -0.06) * (center and 1.6 or 0.6)
    if chroma == 0 then
      lightness = lum + ((i - 1) % 6 - 2.5) * 0.045
    end
    local rad = math.rad(h)
    out[i] = L.from_oklab(lightness, chroma * math.cos(rad), chroma * math.sin(rad))
  end
  return out
end

-- ----------------------------------------------------------------------------- resolution

--- Which palette `auto` stands for: the colour-blind one while the diagnostics are colour-blind.
function M.effective_name(o)
  if o.palette == "auto" then
    local ok, ux = pcall(require, "config.ux")
    if ok and ux.colorblind_enabled and ux.colorblind_enabled() then
      return "colorblind"
    end
    return "island"
  end
  return o.palette
end

--- The list of colours of one bracket kind (nil = the shared list), contrast-lifted.
---@return string[] colours, string palette-name
function M.resolve(o, kind)
  local light = variant() == "light"
  local name = M.effective_name(o)
  local n = math.min(o.colors, M.LIMIT[name] or M.MAX)
  local base
  if o.generator.enabled then
    name = "generated"
    n = math.min(o.colors, M.MAX)
    base = M.generate(n, o.generator, light)
  elseif name == "custom" then
    local c = o.custom
    base = kind and type(c[kind]) == "table" and c[kind] or c.all or c
    if type(base) ~= "table" or #base == 0 then
      base = M.BASE.island[light and "light" or "dark"]
      name = "island"
    else
      n = math.min(o.colors, #base, M.MAX)
    end
  else
    base = M.BASE[name][light and "light" or "dark"]
  end
  local surfaces, target = M.surfaces(), M.min_contrast(o)
  local out = {}
  for i = 1, n do
    out[i] = M.ensure(base[(i - 1) % #base + 1], surfaces, target, light)
  end
  return out, name
end

-- ----------------------------------------------------------------------------- highlight groups

local KINDS = { "round", "square", "curly", "angle", "pipe" }
M.KINDS = KINDS

local function cap(s)
  return s:sub(1, 1):upper() .. s:sub(2)
end

--- Define the highlight groups for the current options and scheme.
--- Returns { by_kind = { round = { "XynoRainbow1", ... }, ... }, count = n, palette = name }.
function M.apply(o)
  local set = vim.api.nvim_set_hl
  local shared, name = M.resolve(o)
  local per_kind = o.palette == "custom" and type(o.custom) == "table"
  local by_kind = {}
  for i, c in ipairs(shared) do
    set(0, "XynoRainbow" .. i, { fg = hexnum(c), default = false })
  end
  local names = {}
  for i = 1, #shared do
    names[i] = "XynoRainbow" .. i
  end
  for _, k in ipairs(KINDS) do
    if per_kind and type(o.custom[k]) == "table" and #o.custom[k] > 0 then
      local list = M.resolve(o, k)
      by_kind[k] = {}
      for i, c in ipairs(list) do
        by_kind[k][i] = "XynoRainbow" .. cap(k) .. i
        set(0, by_kind[k][i], { fg = hexnum(c) })
      end
    else
      by_kind[k] = names
    end
  end
  -- unmatched brackets: red (the scheme's error red), lifted like the rest, plus a curl
  local light = variant() == "light"
  local surfaces = M.surfaces()
  local red = M.ensure(light and "#c8243a" or "#f75464", surfaces, M.min_contrast(o), light)
  set(0, "XynoRainbowMismatch", { fg = hexnum(red), sp = hexnum(red), bold = true, undercurl = true })
  -- scope highlighting: one tint (rainbow colour mixed 0.2 into the editor background) and one
  -- inverted "box" group per colour; restrain dims the text outside the scope
  local bg = surfaces[1]
  for i, c in ipairs(shared) do
    set(0, "XynoRainbowScope" .. i, { bg = hexnum(mix(bg, c, o.scope.alpha)) })
    set(0, "XynoRainbowBox" .. i, { fg = hexnum(bg), bg = hexnum(c), bold = true })
  end
  -- variables: their own colours (golden-angle hues, lifted like the rest), picked by a hash of the name
  local nvar = o.variables.colors
  for i, c in ipairs(M.generate(nvar, { hue = "any", luminosity = "bright" }, light)) do
    set(0, "XynoRainbowVar" .. i, { fg = hexnum(M.ensure(c, surfaces, M.min_contrast(o), light)) })
  end
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local text = normal.fg and tohex(normal.fg) or (light and "#1f2229" or "#bcbec4")
  -- restrained text is dimmed towards the background, but never below the minimum contrast
  set(0, "XynoRainbowRestrain", {
    fg = hexnum(M.ensure(mix(text, bg, o.scope.restrain_strength), surfaces, M.min_contrast(o), light)),
  })
  return { by_kind = by_kind, count = #shared, palette = name, red = red, var_count = nvar }
end

return M
