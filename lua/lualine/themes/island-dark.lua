-- lualine theme for island-dark; every colour is from island/palette.lua.
local P = require("island.palette")
local A, C = P.attrs, P.colors

local bg, fg = A.TEXT.bg, A.TEXT.fg
local bar = C.DIFF_SEPARATORS_BACKGROUND
local mid = C.RIGHT_MARGIN_COLOR
local muted = C.WHITESPACES
local function mode(color)
  return {
    a = { fg = bg, bg = color, gui = "bold" },
    b = { fg = fg, bg = mid },
    c = { fg = A.BREADCRUMBS_DEFAULT.fg, bg = bar },
  }
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
