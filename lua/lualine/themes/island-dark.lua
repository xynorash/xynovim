-- lualine theme for island-dark; every colour is from island/palette.lua.
local P = require("island.palette")
local A, C = P.attrs, P.colors

local bg, fg = A.TEXT.bg, A.TEXT.fg
local bar = C.DIFF_SEPARATORS_BACKGROUND
local mid = C.RIGHT_MARGIN_COLOR
local muted = A.BREADCRUMBS_DEFAULT.fg -- inactive text: the "disabled" grey #6f737a is 2.9:1 on the bar
local function mode(color)
  return {
    a = { fg = bg, bg = color, gui = "bold" },
    b = { fg = fg, bg = mid },
    c = { fg = A.BREADCRUMBS_DEFAULT.fg, bg = bar },
  }
end

-- after `:colorscheme <other>` lualine re-requires this theme: follow the new
-- colourscheme instead of keeping the island colours
if vim.g.colors_name == "island-light" then
  -- the light variant: the same roles through island.light (accent pills darkened to 4.5:1 against the light bar text)
  local L = require("island.light")
  local light_bg = L.flip(bg)
  local function pill(color)
    local accent = L.darken_to(L.flip(color), light_bg, 4.5)
    local light_bar = L.flip(bar)
    return {
      a = { fg = light_bg, bg = accent, gui = "bold" },
      b = { fg = L.darken_to(L.flip(fg), L.flip(mid), 7.0), bg = L.flip(mid) },
      c = { fg = L.darken_to(L.flip(A.BREADCRUMBS_DEFAULT.fg), light_bar, 4.5), bg = light_bar },
    }
  end
  local light_muted = L.darken_to(L.flip(muted), L.flip(bar), 4.5)
  return {
    normal = pill(A.DEFAULT_FUNCTION_DECLARATION.fg),
    insert = pill(A.DEFAULT_STRING.fg),
    visual = pill(A.DEFAULT_CONSTANT.fg),
    replace = pill(A.CONSOLE_ERROR_OUTPUT.fg),
    command = pill(A.LOG_INFO_OUTPUT.fg),
    terminal = pill(A.DEFAULT_NUMBER.fg),
    inactive = {
      a = { fg = light_muted, bg = L.flip(bar) },
      b = { fg = light_muted, bg = L.flip(bar) },
      c = { fg = light_muted, bg = L.flip(bar) },
    },
  }
end
if vim.g.colors_name and vim.g.colors_name ~= "island-dark" then
  return require("lualine.themes.auto")
end

return {
  normal = mode(A.DEFAULT_FUNCTION_DECLARATION.fg),
  insert = mode(A.DEFAULT_STRING.fg),
  visual = mode(A.DEFAULT_CONSTANT.fg),
  replace = mode(A.CONSOLE_ERROR_OUTPUT.fg),
  command = mode(A.LOG_INFO_OUTPUT.fg),
  terminal = mode(A.DEFAULT_NUMBER.fg),
  inactive = {
    a = { fg = muted, bg = bar },
    b = { fg = muted, bg = bar },
    c = { fg = muted, bg = bar },
  },
}
