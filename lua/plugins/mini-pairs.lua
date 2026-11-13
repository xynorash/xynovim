-- mini.pairs: a quote typed right after a backslash is part of the text, not the end of the string.
--
-- `"` is a "closeopen" key: mini.pairs jumps over the closing quote that is already to the right of
-- the cursor without looking at its neighbourhood pattern (only open/close check it). In "a\"b" the
-- escaped quote typed after `a\` jumped over the auto-inserted closing quote, so the string had no
-- end any more, and the final quote typed opened a new pair: a stray `"` at the end of the line
-- (found with text and lua buffers; in Rust the string tree-sitter capture hid it most of the time).
-- Here a quote key after an odd number of backslashes just inserts itself.
local function escaped_before_cursor()
  if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
    return false
  end
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = vim.api.nvim_get_current_line():sub(1, col)
  local slashes = #before:match("\\*$")
  return slashes % 2 == 1
end

return {
  "nvim-mini/mini.pairs",
  config = function(_, opts)
    LazyVim.mini.pairs(opts)
    local pairs = require("mini.pairs")
    if pairs.closeopen_escape_aware then
      return
    end
    local closeopen = pairs.closeopen
    pairs.closeopen = function(pair, neigh_pattern)
      if escaped_before_cursor() then
        return pair:sub(1, 1)
      end
      return closeopen(pair, neigh_pattern)
    end
    pairs.closeopen_escape_aware = true
  end,
}
