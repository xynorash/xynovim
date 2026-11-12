-- Island Light: the light variant of Island Dark, with a HAND-TUNED palette (lua/island/light_palette.lua:
-- one chosen light colour for every dark colour of the scheme, designed after JetBrains Light / Islands
-- Light, GitHub Light, catppuccin-latte and tokyonight-day, see the header of that file).
--
-- It is not a JetBrains scheme. Colours the palette file does not list (tints plugins derive from the
-- dark colours at run time) still go through `flip` (lightness inverted in OKLab, hue kept). Afterwards
-- every highlight group is checked: text keeps at least min(the contrast the dark scheme gives the same
-- group, 4.5:1), a border that was 3:1 stays at least 3:1; colours that miss are moved towards black until
-- they reach it. (The first, derived version of this variant held every group to the dark contrast, capped
-- at 9:1, which made keywords and strings dark brown and dark green; the hand-tuned one holds syntax to 5:1
-- instead, as GitHub Light does, and normal text to 12:1.)
--
--   :colorscheme island-light      (colors/island-light.lua)
--   island.light.apply()           after island.setup(), used by that file
local M = {}

local function clamp(x, lo, hi)
  return math.max(lo, math.min(hi, x))
end

local function to_lin(c)
  return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

local function from_lin(c)
  c = clamp(c, 0, 1)
  return c <= 0.0031308 and 12.92 * c or 1.055 * c ^ (1 / 2.4) - 0.055
end

--- "#rrggbb" -> L, a, b (OKLab)
function M.to_oklab(hex)
  local r = to_lin(tonumber(hex:sub(2, 3), 16) / 255)
  local g = to_lin(tonumber(hex:sub(4, 5), 16) / 255)
  local b = to_lin(tonumber(hex:sub(6, 7), 16) / 255)
  local l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
  local m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
  local s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)
  return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
end

local function lin_rgb(L, a, b)
  local l = (L + 0.3963377774 * a + 0.2158037573 * b) ^ 3
  local m = (L - 0.1055613458 * a - 0.0638541728 * b) ^ 3
  local s = (L - 0.0894841775 * a - 1.2914855480 * b) ^ 3
  return 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
end

--- OKLab -> "#rrggbb"; out-of-gamut colours lose chroma (not lightness) until they fit.
function M.from_oklab(L, a, b)
  local k = 1
  for _ = 1, 20 do
    local r, g, bl = lin_rgb(L, a * k, b * k)
    if r >= -0.001 and r <= 1.001 and g >= -0.001 and g <= 1.001 and bl >= -0.001 and bl <= 1.001 then
      break
    end
    k = k * 0.9
  end
  local r, g, bl = lin_rgb(L, a * k, b * k)
  return string.format("#%02x%02x%02x", from_lin(r) * 255 + 0.5, from_lin(g) * 255 + 0.5, from_lin(bl) * 255 + 0.5)
end

--- The light colour for a dark one: the hand-tuned palette entry if there is one, else the OKLab flip.
--- (OKLab flip: lightness inverted around the middle of the range the scheme uses (dark background L 0.24 -> 0.97,
--- light text L 0.90 -> 0.25), hue kept, chroma x 0.92.
function M.flip(hex)
  local chosen = require("island.light_palette").lookup(hex)
  if chosen then
    return chosen
  end
  local L, a, b = M.to_oklab(hex)
  return M.from_oklab(clamp(1.238 - 1.098 * L, 0.05, 0.99), a * 0.92, b * 0.92)
end

local function lum(hex)
  local function ch(i)
    return to_lin(tonumber(hex:sub(2 * i, 2 * i + 1), 16) / 255)
  end
  return 0.2126 * ch(1) + 0.7152 * ch(2) + 0.0722 * ch(3)
end

function M.ratio(x, y)
  local p, q = lum(x), lum(y)
  if p < q then
    p, q = q, p
  end
  return (p + 0.05) / (q + 0.05)
end

--- `fg` moved towards black (OKLab lightness, 0.5% steps) until it is `target`:1 on `on`.
function M.darken_to(fg, on, target)
  local L, a, b = M.to_oklab(fg)
  local out = fg
  while L > 0 and M.ratio(out, on) < target do
    L = L - 0.005
    out = M.from_oklab(math.max(L, 0), a, b)
  end
  return out
end

--- `fg` moved towards white until it is `target`:1 on `on` (for text on a dark fill kept in light).
function M.lighten_to(fg, on, target)
  local L, a, b = M.to_oklab(fg)
  local out = fg
  while L < 1 and M.ratio(out, on) < target do
    L = L + 0.005
    out = M.from_oklab(math.min(L, 1), a, b)
  end
  return out
end

local function hex(n)
  return n and string.format("#%06x", n) or nil
end

local function num(h)
  return h and tonumber(h:sub(2), 16) or nil
end

--- A group defined after the colorscheme ran: does it assume a dark editor? Groups plugins derive from the
--- current (light) colours are already fine; colours picked for dark are light text (low contrast on the
--- light background) or dark fills.
function M.looks_dark(spec, light_bg)
  local fg, bg = hex(spec.fg), hex(spec.bg)
  if fg then
    return M.ratio(fg, bg or light_bg) < 3
  end
  return bg ~= nil and lum(bg) < 0.25
end

local seen = {} -- group names already converted in this colorscheme load

local function convert(groups, light_bg, dark_bg, only_new, untouched)
  local updated = {}
  for name, spec in pairs(groups) do
    if
      not spec.link
      and name ~= "Normal"
      and not (only_new and seen[name])
      and not (untouched and vim.deep_equal(untouched[name], spec))
      and (not only_new or M.looks_dark(spec, light_bg))
    then
      local dfg, dbg = hex(spec.fg), hex(spec.bg)
      local target
      if dfg then
        -- the contrast this group has in the dark scheme (its own fill, else the editor background)
        target = math.min(M.ratio(dfg, dbg or dark_bg), 4.5)
      end
      local n = vim.deepcopy(spec)
      n.default = nil -- groups defined `default` (bufferline & co.) must be replaced, not skipped
      n.fg = dfg and M.flip(dfg) or nil
      n.bg = dbg and M.flip(dbg) or nil
      n.sp = hex(spec.sp) and M.flip(hex(spec.sp)) or nil
      if n.fg then
        local on = n.bg or light_bg
        if M.ratio(n.fg, on) < target then
          n.fg = M.darken_to(n.fg, on, target)
          if M.ratio(n.fg, on) < target then
            -- the fill itself is too dark to reach it with darker text (rare): use lighter text
            n.fg = M.lighten_to(n.fg, on, target)
          end
        end
      end
      updated[name] = n
    end
    seen[name] = true
  end
  return updated
end

local dark_bg_of_load, light_bg_of_load

--- Transform every highlight group of the dark scheme in place, then restore the contrast it had.
--- Run it right after `require("island").setup()`.
--- @param defaults? table  nvim_get_hl(0, {}) taken after `highlight clear` and `background=light`, before
---   island.setup(): groups still equal to it are Neovim's own light defaults and stay as they are
function M.apply(defaults)
  seen = {}
  local groups = vim.api.nvim_get_hl(0, {})
  local normal = groups.Normal or {}
  local dark_bg = hex(normal.bg) or "#1e1f22"
  local light_bg = M.flip(dark_bg)
  dark_bg_of_load, light_bg_of_load = dark_bg, light_bg
  local updated = convert(groups, light_bg, dark_bg, false, defaults)
  -- Normal last: the editor background and text
  local nfg = hex(normal.fg) or "#bcbec4"
  local n = vim.deepcopy(normal)
  n.bg = light_bg
  n.fg = M.darken_to(M.flip(nfg), light_bg, 12)
  updated.Normal = n
  for name, spec in pairs(updated) do
    vim.api.nvim_set_hl(0, name, spec)
  end
  -- the console palette
  for i = 0, 15 do
    local key = "terminal_color_" .. i
    if type(vim.g[key]) == "string" then
      vim.g[key] = M.flip(vim.g[key])
    end
  end
  vim.g.terminal_color_background = light_bg
  vim.g.terminal_color_foreground = n.fg
  require("island").apply_high_contrast() -- no-op unless vim.g.xynovim_contrast == "high"
end

--- Groups that plugins define after the colorscheme ran (their ColorScheme handlers) still carry dark
--- colours: convert the ones not seen yet. Returns how many.
function M.late()
  if vim.g.colors_name ~= "island-light" or not light_bg_of_load then
    return 0
  end
  local updated = convert(vim.api.nvim_get_hl(0, {}), light_bg_of_load, dark_bg_of_load, true)
  local n = 0
  for name, spec in pairs(updated) do
    vim.api.nvim_set_hl(0, name, spec)
    n = n + 1
  end
  return n + require("island").late()
end

M.num = num

return M
