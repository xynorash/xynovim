-- Underline everything rust-analyzer marks with the `unsafe` semantic-token
-- modifier (unsafe calls, derefs of raw pointers, unsafe fns). A modifier
-- group only adds an attribute on top of the token's own colour. Like
-- transparency.lua this is applied now and on every ColorScheme, because a
-- theme switch (`highlight clear` from a theme switch) wipes it.
local function apply()
	vim.api.nvim_set_hl(0, "@lsp.mod.unsafe.rust", { underline = true })
end

vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("user_unsafe_highlight", { clear = true }),
	callback = apply,
})

apply()
