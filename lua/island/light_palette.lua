-- Island Light, hand-tuned palette: one chosen light colour for every colour of the Island Dark scheme
-- (dark hex -> light hex). Written by hand, group role by group role, not computed from the dark colour;
-- lua/island/light.lua only falls back to its OKLab flip for a colour that is not listed here (plugins that
-- derive their own tints).
--
-- Method (2026-11-12). Roles and hues stay those of Island Dark (orange keyword, green string, teal number,
-- blue function, magenta field, olive type, amber macro, rose self) so a switch between the two keeps
-- meaning; lightness, and for a few colours the saturation, were chosen by looking at four light schemes:
--   * JetBrains Light / Islands Light (intellij-community, themes/Light.xml, islands/ManyIslandsLight.theme.json):
--     white editor, tool windows #F7F8FA / #EBECF0, caret row and selection blues (#EDF3FF, #D0DFFE), borders
--     #DFE1E5; text #080808, keyword #0033b3, string #067d17, number #1750eb, field #871094, annotation #9e880d.
--     Its comment #8c8c8c is 3.4:1 and its line numbers #adadad 2.2:1 on white: below AA, not copied.
--   * GitHub Light (github-nvim-theme palette/primitives/light.lua): text #1f2328, comment #57606a (6.2:1),
--     keyword #cf222e, string #0a3069, constant #0550ae, entity #6639ba: syntax colours deep enough to
--     stay >= 5:1 on white, which this palette takes as its floor for syntax.
--   * catppuccin-latte (palettes/latte.lua): text #4c4f69 on base #eff1f5 (6.9:1), but accents like
--     peach #fe640b (2.8:1), yellow #df8e1d, green #40a02b (2.9:1) are far below AA; the surface ladder
--     (mantle / crust) is the model for popup and chip fills here.
--   * tokyonight-day (extras/lua/tokyonight_day.lua): generated from tokyonight-night by an HSLuv
--     lightness inversion (util.invert) plus a brightness lift; comment #848cb5 is 2.4:1 on #e1e2e7.
--
-- Rules the numbers below were fitted to (checked by tests/ui-community_spec.lua on the real groups):
--   normal text >= 12:1; syntax colours >= 5:1 on the editor and >= 4.5:1 on the popup fill; comments,
--   line numbers, hints, winbar, code lens >= 4.5:1; error / warning / ok text >= 4.5:1; frames >= 3:1;
--   selection and cursor line light enough that every foreground keeps its ratio on top of them.
local M = {}

-- foregrounds (text, syntax, glyphs)
M.fg = {
  ["#bcbec4"] = "#1f2229", -- text
  ["#ced0d6"] = "#272a30", -- text strong
  ["#dfe1e5"] = "#16181c", -- text on fill
  ["#c9cbd6"] = "#1a1c20", -- text
  ["#cf8e6d"] = "#a1481a", -- keyword
  ["#c77dbb"] = "#92308c", -- constant/field
  ["#c77dba"] = "#92308c", -- js
  ["#6aab73"] = "#26733a", -- string
  ["#2aacb8"] = "#08707d", -- number
  ["#6aa2d7"] = "#2160a3", -- rust fn
  ["#56a8f5"] = "#1a5fb8", -- fn decl/info
  ["#57aaf7"] = "#1a5fb8", -- method
  ["#70aeff"] = "#1d5fc4", -- changed
  ["#548af7"] = "#2456d0", -- link
  ["#5c92ff"] = "#2456d0", -- link2
  ["#a6bb77"] = "#53701a", -- type
  ["#b3ae60"] = "#77700f", -- attribute
  ["#b2ae60"] = "#77700f", -- attr2
  ["#d5a563"] = "#935a00", -- macro
  ["#d8a460"] = "#8f5800", -- q-op
  ["#d5b778"] = "#8a6908", -- tag
  ["#e59eae"] = "#b03562", -- self
  ["#8cc8d4"] = "#276d8c", -- enum variant
  ["#3cacac"] = "#0c7676", -- type param
  ["#1db8ab"] = "#0a7a6f", -- signal
  ["#42c3d4"] = "#087888", -- regexp
  ["#8bb33d"] = "#4a7609", -- todo
  ["#82868c"] = "#686c73", -- comment
  ["#6f8f7a"] = "#527159", -- doc comment
  ["#5f826b"] = "#4c6e57", -- doc comment2
  ["#67a37c"] = "#3a7a52", -- doc tag
  ["#3887a1"] = "#136e8b", -- intradoc
  ["#6f737a"] = "#73767c", -- line nr/ws
  ["#a1a3ab"] = "#2d3036", -- cursor line nr
  ["#868a91"] = "#63666d", -- diff del / inlay
  ["#868991"] = "#5f626a", -- folded
  ["#8d9199"] = "#5b5e65", -- hint
  ["#9da0a8"] = "#585b62", -- winbar etc
  ["#727782"] = "#5c616c", -- dap vt
  ["#757a85"] = "#656a75", -- unresolved
  ["#828690"] = "#5a5d65", -- codelens
  ["#83878d"] = "#5f6269", -- winbarNC
  ["#90949c"] = "#575a61", -- busy
  ["#a9acb1"] = "#50535a", -- inlay hint
  ["#849fbf"] = "#46658f", -- dap info
  ["#8a8e57"] = "#666a2a", -- cfg disabled
  ["#e0bb65"] = "#8f6400", -- warn
  ["#c29e4a"] = "#8a6700", -- warn dim
  ["#f75464"] = "#c8243a", -- error
  ["#f8606f"] = "#c4243a", -- error
  ["#f86574"] = "#c4243a", -- error vt
  ["#fa8e99"] = "#b3223a", -- tree error
  ["#e88f89"] = "#b5232f", -- removed
  ["#d64d5b"] = "#c93044", -- err mark
  ["#73bd79"] = "#1d7a33", -- added
  ["#549159"] = "#2c7d41", -- gitsign add
  ["#b3f6c0"] = "#176b2b", -- ok
  ["#cf84cf"] = "#8a3796", -- unmerged
  ["#d69a6b"] = "#95551d", -- ignored
  ["#b189f5"] = "#6a41c0", -- purple
  ["#6f7587"] = "#5d6277", -- redundant esc
  ["#6a707a"] = "#656a73", -- sp
  ["#2fbaa3"] = "#0a7d6c", -- html custom
  ["#32b8af"] = "#0a7a73", -- label
  ["#56c1d6"] = "#0c7488", -- named arg
  ["#16baac"] = "#0a7a70", -- type param
  ["#0da19e"] = "#0a7370", -- kw3
  ["#9c9cff"] = "#4b4bd0", -- jsx
  ["#375239"] = "#376b3d", -- cov
  ["#83acfc"] = "#2a5bb0", -- param cur
  ["#858a94"] = "#5c6069", -- param hint
}

-- fills, selections, frames and lines
M.bg = {
  ["#1e1f22"] = "#ffffff",
  ["#2b2d30"] = "#f2f3f6",
  ["#26282e"] = "#f6f7f9",
  ["#242d42"] = "#edf2fc",
  ["#26292c"] = "#f3f4f6",
  ["#343539"] = "#eceef2",
  ["#393b40"] = "#e4e6eb",
  ["#43454a"] = "#c9e8ea",
  ["#3f4045"] = "#e0eeee",
  ["#2d416b"] = "#d1e0fd",
  ["#2f5194"] = "#b4cdf6",
  ["#114957"] = "#c5ebf0",
  ["#165e70"] = "#8dd3df",
  ["#21322c"] = "#e2f4e7",
  ["#25324d"] = "#e4ecfc",
  ["#452e31"] = "#fbe3e5",
  ["#4e2c28"] = "#ffe8e0",
  ["#373b39"] = "#e6ede8",
  ["#402f33"] = "#f8e5ea",
  ["#402929"] = "#fdeaea",
  ["#66313f"] = "#ffc7d8",
  ["#2a5091"] = "#d6e4ff",
  ["#273552"] = "#e1e9fa",
  ["#313438"] = "#e9ebef",
  ["#4b5059"] = "#c3c7ce",
  ["#4f5258"] = "#c9ccd2",
  ["#666870"] = "#81848b",
  ["#74767d"] = "#777a81",
  ["#2d543f"] = "#cdeed9",
  ["#1a3b2d"] = "#d9f2e4",
  ["#293c40"] = "#dcf0f2",
  ["#27292b"] = "#f3f4f5",
  ["#35538f"] = "#c3d7fb",
  ["#40252b"] = "#fbe1e6",
  ["#8c5b65"] = "#c98896",
  ["#8bb33d"] = "#4a7609",
}

--- The hand-picked light colour for a dark hex, or nil.
function M.lookup(hex)
  hex = hex:lower()
  return M.fg[hex] or M.bg[hex]
end

return M
