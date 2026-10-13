-- Rust-only buffer settings.

-- mini.pairs pairs `'` after `&` and `<`, so typing a lifetime left a stray
-- quote (`&'a str)` became `&'a str')`). Rust has lifetimes and char
-- literals, which no pairing rule tells apart: type `'` plainly (a char
-- literal's closing quote is one more key).
vim.keymap.set("i", "'", "'", { buffer = true, desc = "Quote (no pairing: lifetimes)" })

-- Spell check comments and doc comments only: the Rust highlights query marks
-- them @spell, so identifiers and strings are skipped. `camel` also checks
-- the parts of camelCase words.
vim.opt_local.spell = true
vim.opt_local.spelloptions:append("camel")

-- Rust words (Vec, tokio, impl, usize, ...) are not in the `en` dictionary and
-- were flagged in every comment: spell/en.utf-8.add ships them (it must be named
-- after a 'spelllang' language, else nvim does not load it). nvim only reads the
-- compiled .spl, which is built here when missing or older (git-ignored). `zg`
-- still writes to the first entry (the user's own list, not this repo).
local add = vim.fn.stdpath("config") .. "/spell/en.utf-8.add"
local add_stat, spl_stat = vim.uv.fs_stat(add), vim.uv.fs_stat(add .. ".spl")
if add_stat and (not spl_stat or spl_stat.mtime.sec < add_stat.mtime.sec) then
  pcall(vim.cmd, "silent mkspell! " .. vim.fn.fnameescape(add))
end
vim.opt_local.spellfile = { vim.fn.stdpath("data") .. "/site/spell/en.utf-8.add", add }

-- mini.pairs jumps over the auto-inserted closing `"` when it is typed behind
-- a backslash, so `"a\"b"` ended as `"a\"b";"`. An escaped quote (odd number
-- of backslashes before the cursor) is inserted plainly; every other `"`
-- keeps the global mini.pairs mapping.
vim.keymap.set("i", '"', function()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local backslashes = #vim.api.nvim_get_current_line():sub(1, col):match("\\*$")
  if backslashes % 2 == 1 then
    return '"'
  end
  for _, m in ipairs(vim.api.nvim_get_keymap("i")) do
    if m.lhs == '"' and m.expr == 1 then
      return m.callback and m.callback() or vim.api.nvim_eval(m.rhs) -- mini.pairs: a v:lua expression
    end
  end
  return '"'
end, { buffer = true, expr = true, replace_keycodes = false, desc = "Quote (plain after a backslash)" })
