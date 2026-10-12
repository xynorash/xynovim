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
