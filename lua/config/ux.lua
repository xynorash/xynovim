-- UI conveniences: right-click menu for Rust buffers, Neovide, and an opt-in
-- colourblind-safe diagnostic palette.
local M = {}

--- Press <leader><suffix> as if typed, so menu entries reuse the real keymaps
--- (keymaps.lua) instead of duplicating their logic.
function M.leader(suffix)
  vim.api.nvim_feedkeys(vim.keycode("<leader>") .. suffix, "mt", false)
end

-- Diagnostic virtual text --------------------------------------------------

--- First line of a message.
local function head(message)
  return vim.split(message or "", "\n", { plain = true, trimempty = true })[1] or ""
end

--- What identifies a problem across the two tiers: the rustc error code
--- (rust-analyzer sets `code`, clippy's rendered message has `error[E0308]:`),
--- else the first line without its `error: ` prefix, case and end punctuation.
local function same_key(d)
  local code = type(d.code) == "string" and d.code:match("^E%d+$") or head(d.message):match("^%a+%[(E%d+)%]")
  return code or (head(d.message):gsub("^%a+: ", ""):gsub("[%s%p]+$", ""):lower())
end

--- virtual_text.format: only the first line (clippy sends the whole rendered
--- cargo message, ~14 lines, on one nowrap line) followed by [source]. A
--- problem both tiers report on the same line (E0308 from rust-analyzer and
--- from clippy) is shown once: the diagnostic with a `code` (rust-analyzer's,
--- the more specific text), else the one from the earlier namespace.
function M.diagnostic_text(d)
  if d.bufnr and vim.api.nvim_buf_is_valid(d.bufnr) then
    local key = same_key(d)
    for _, o in ipairs(vim.diagnostic.get(d.bufnr, { lnum = d.lnum })) do
      if o.namespace ~= d.namespace and same_key(o) == key then
        local o_coded, d_coded = o.code ~= nil, d.code ~= nil
        if o_coded ~= d_coded then
          if o_coded then
            return nil
          end
        elseif o.namespace < d.namespace then
          return nil
        end
      end
    end
  end
  local text = head(d.message)
  return d.source and (text .. " [" .. d.source .. "]") or text
end

-- Completion -----------------------------------------------------------------

--- blink.cmp snippets provider guard: false after a `.` (method position) and
--- inside strings and comments.
function M.snippets_allowed(ctx)
  local before = ctx.line:sub(1, ctx.cursor[2])
  if before:match("[^%.]%.[%w_]*$") then
    return false
  end
  local ok, node = pcall(vim.treesitter.get_node, {
    bufnr = ctx.bufnr,
    pos = { ctx.cursor[1] - 1, math.max(ctx.cursor[2] - 1, 0) },
  })
  while ok and node do
    local t = node:type()
    local _, _, erow, ecol = node:range()
    -- a literal ends at its closing quote: the cursor behind it is outside
    local behind = t:find("literal$") and erow == ctx.cursor[1] - 1 and ecol <= ctx.cursor[2]
    if (t:find("string") or t:find("comment")) and not behind then
      return false
    end
    node = node:parent()
  end
  return true
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

  -- Virtual text is rendered per namespace, when that namespace changes; the
  -- duplicate check in diagnostic_text needs the other tier's diagnostics, so
  -- when one arrives (or goes) later, render the buffer's namespaces again.
  local redraw = {}
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    callback = function(args)
      local buf = args.buf
      if redraw[buf] then
        return
      end
      redraw[buf] = true
      vim.schedule(function()
        redraw[buf] = nil
        if vim.api.nvim_buf_is_valid(buf) then
          vim.diagnostic.show(nil, buf)
        end
      end)
    end,
  })

  -- Re-apply after every colorscheme load (a theme switch may
  -- `highlight clear` first).
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
