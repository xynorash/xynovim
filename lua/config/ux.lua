-- UI conveniences: right-click menu for Rust buffers, Neovide, and an opt-in
-- colourblind-safe diagnostic palette.
local M = {}

--- Press <leader><suffix> as if typed, so menu entries reuse the real keymaps
--- (keymaps.lua) instead of duplicating their logic.
function M.leader(suffix)
  vim.api.nvim_feedkeys(vim.keycode("<leader>") .. suffix, "mt", false)
end

-- Right-click menu --------------------------------------------------------

-- { menu path, <leader> suffix | Lua expression }
local RUST_MENU = {
  { "Rust.Rename", "lua vim.lsp.buf.rename()" },
  { "Rust.Find\\ Usages", "lua Snacks.picker.lsp_references()" },
  { "Rust.Refactor.Actions\\ \\.\\.\\.", "ra" },
  { "Rust.Refactor.Extract\\ Variable", "rv" },
  { "Rust.Refactor.Extract\\ Function", "rf" },
  { "Rust.Refactor.Extract\\ Constant", "rc" },
  { "Rust.Refactor.Extract\\ Module", "rM" },
  { "Rust.Refactor.Inline", "ri" },
  { "Rust.Expand\\ Macro", "rm" },
  { "Rust.Run\\ Target\\ \\.\\.\\.", "rX" },
}

local function rust_menu()
  vim.cmd("silent! aunmenu PopUp.Rust")
  if vim.bo.filetype ~= "rust" then
    return
  end
  for _, item in ipairs(RUST_MENU) do
    local rhs = item[2]:find("^lua ") and item[2] or ("lua require('config.ux').leader('" .. item[2] .. "')")
    vim.cmd(("anoremenu PopUp.%s <Cmd>%s<CR>"):format(item[1], rhs))
  end
end

-- Colourblind-safe diagnostics ---------------------------------------------

-- Okabe-Ito: distinguishable under deuteranopia, protanopia and tritanopia.
local OKABE_ITO = {
  Error = "#D55E00", -- vermillion
  Warn = "#F0E442", -- yellow
  Info = "#56B4E9", -- sky blue
  Hint = "#009E73", -- bluish green
  Ok = "#0072B2", -- blue
}

local enabled = false

local function apply_palette()
  for kind, color in pairs(OKABE_ITO) do
    -- fg for text/sign/float groups, sp for underlines; virtual text/lines
    -- lose their theme-tinted bg (it was derived from the old colour).
    for _, prefix in ipairs({ "Diagnostic", "DiagnosticSign", "DiagnosticFloating", "DiagnosticVirtualText", "DiagnosticVirtualLines" }) do
      local name = prefix .. kind
      local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
      hl.fg = tonumber(color:sub(2), 16)
      if prefix:find("Virtual") then
        hl.bg = nil
      end
      vim.api.nvim_set_hl(0, name, hl)
    end
    local ul = vim.api.nvim_get_hl(0, { name = "DiagnosticUnderline" .. kind, link = false })
    ul.sp = tonumber(color:sub(2), 16)
    vim.api.nvim_set_hl(0, "DiagnosticUnderline" .. kind, ul)
  end
end

function M.colorblind(on)
  if on == nil then
    on = not enabled
  end
  enabled = on
  if on then
    apply_palette()
  elseif vim.g.colors_name then
    -- Re-run the colorscheme to drop the overrides; its ColorScheme event
    -- re-applies transparency etc.
    pcall(vim.cmd.colorscheme, vim.g.colors_name)
  end
  return enabled
end

function M.colorblind_enabled()
  return enabled
end

function M.setup()
  local group = vim.api.nvim_create_augroup("xynovim_ux", { clear = true })
  vim.api.nvim_create_autocmd("MenuPopup", { group = group, callback = rust_menu })

  -- Re-apply after every colorscheme load (incl. the Omarchy hot reload,
  -- which does `highlight clear` first).
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      if enabled then
        apply_palette()
      end
    end,
  })
  vim.api.nvim_create_user_command("ColorblindDiagnostics", function()
    vim.notify("colourblind diagnostics " .. (M.colorblind() and "on" or "off"))
  end, { desc = "Toggle the Okabe-Ito diagnostic palette" })

  -- Opt in permanently with `vim.g.xynovim_colorblind = true` (set before
  -- this runs, e.g. at the top of options.lua).
  if vim.g.xynovim_colorblind then
    enabled = true
  end

  -- Neovide: no animations (same choice as the Snacks scroll/animate settings
  -- and the cursor), and a translucent background like transparency.lua.
  if vim.g.neovide then
    vim.g.neovide_position_animation_length = 0
    vim.g.neovide_scroll_animation_length = 0
    vim.g.neovide_cursor_animation_length = 0
    vim.g.neovide_cursor_trail_size = 0
    vim.g.neovide_cursor_animate_in_insert_mode = false
    vim.g.neovide_cursor_animate_command_line = false
    vim.g.neovide_opacity = 0.9
  end
end

return M
