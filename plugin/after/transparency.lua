-- Make highlight groups transparent while preserving their other attributes.
-- Applied immediately AND on every ColorScheme change, so a manual
-- `:colorscheme` mid-session keeps transparency too (re-sourcing this file is
-- safe: the augroup clears its old autocmd).
local function make_transparent(name)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	if ok and hl.bg ~= nil then
		hl.bg = nil
		vim.api.nvim_set_hl(0, name, hl)
	end
end

-- Floats and the completion menu (NormalFloat, FloatBorder, Pmenu, Telescope,
-- which-key) are deliberately NOT here: they keep the theme's solid popup
-- background so they stay readable over code. CursorLineNr keeps its bg so the
-- cursor-row band has no gap in the gutter. Only the editor surface is made
-- transparent.
local groups = {
	-- transparent background
	"Normal",
	"Terminal",
	"EndOfBuffer",
	"FoldColumn",
	"Folded",
	"SignColumn",
	"LineNr",
	"NormalNC",
	-- neotree
	"NeoTreeNormal",
	"NeoTreeNormalNC",
	"NeoTreeVertSplit",
	"NeoTreeWinSeparator",
	"NeoTreeEndOfBuffer",
	-- nvim-tree
	"NvimTreeNormal",
	"NvimTreeVertSplit",
	"NvimTreeEndOfBuffer",
	-- notify
	"NotifyINFOBody",
	"NotifyERRORBody",
	"NotifyWARNBody",
	"NotifyTRACEBody",
	"NotifyDEBUGBody",
	"NotifyINFOTitle",
	"NotifyERRORTitle",
	"NotifyWARNTitle",
	"NotifyTRACETitle",
	"NotifyDEBUGTitle",
	"NotifyINFOBorder",
	"NotifyERRORBorder",
	"NotifyWARNBorder",
	"NotifyTRACEBorder",
	"NotifyDEBUGBorder",
}

local function apply()
	-- vim.g.xynovim_transparent = false keeps the theme's solid backgrounds
	-- (toggle: <leader>uO)
	if vim.g.xynovim_transparent == false then
		return
	end
	for _, name in ipairs(groups) do
		make_transparent(name)
	end
end

vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("user_transparency", { clear = true }),
	callback = apply,
})

apply()

-- Toggle: off re-runs the colorscheme to bring the solid backgrounds back.
if _G.Snacks and Snacks.toggle then
	Snacks.toggle({
		name = "Transparent background",
		get = function()
			return vim.g.xynovim_transparent ~= false
		end,
		set = function(state)
			vim.g.xynovim_transparent = state
			if vim.g.colors_name then
				pcall(vim.cmd.colorscheme, vim.g.colors_name)
			end
		end,
	}):map("<leader>uO")
end
