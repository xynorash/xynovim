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
