-- UI round 2 (docs/comparison/ui-community.md items 13-16 and the icon-mode gaps): pieces that touch
-- plugins other than the theme, kept out of config/ui.lua so that file stays the policy.
--
--   * icon mode at run time: lualine, bufferline, neo-tree and the dashboard are rebuilt from their
--     lazy.nvim options when `:XynoIcons` changes, no restart; rust-analyzer's code-lens titles lose
--     their symbol glyphs in ascii mode
--   * error colour on the file tree (item 14): a file or folder with an ERROR in it gets the
--     `XynoTreeError` colour; the tab keeps bufferline's own `glyph count` indicator (see below)
--   * opt-in winbar breadcrumbs (item 15): `vim.g.xynovim_winbar = true`, `:XynoWinbar`
local M = {}

local function ui()
  return require("config.ui")
end

-- Code lens titles (icon gap) -----------------------------------------------------------------

--- rust-analyzer's lens titles start with a symbol ("▶︎ Run", "⚙︎ Debug"): plain text for ascii mode.
--- @param title string
--- @return string
function M.ascii_title(title)
  local t = title:gsub("\239\184\142", "") -- U+FE0E, the text-presentation selector
  t = t:gsub("▶", ">"):gsub("⚙", "*")
  t = t:gsub("[\194-\244][\128-\191]*", "") -- any other symbol
  return vim.trim(t)
end

--- Wrap `client:request` so code-lens responses are rewritten while ascii mode is on (checked per
--- response: `:XynoIcons` takes effect at the next refresh).
--- @param client vim.lsp.Client
function M.wrap_codelens(client)
  if rawget(client, "_xyno_lens_wrapped") then
    return
  end
  rawset(client, "_xyno_lens_wrapped", true)
  local orig = client.request
  rawset(client, "request", function(self, method, params, handler, bufnr)
    if (method == "textDocument/codeLens" or method == "codeLens/resolve") and handler then
      local inner = handler
      handler = function(err, res, ...)
        if ui().ascii_active() and type(res) == "table" then
          local list = res.command and { res } or res
          for _, lens in ipairs(list) do
            if type(lens) == "table" and type(lens.command) == "table" and type(lens.command.title) == "string" then
              lens.command.title = M.ascii_title(lens.command.title)
            end
          end
        end
        return inner(err, res, ...)
      end
    end
    return orig(self, method, params, handler, bufnr)
  end)
end

--- Re-run the legibility floors (island.late) for the colorscheme in use: bufferline rewrites its tab groups
--- whenever it is set up.
function M.legibility()
  local name = vim.g.colors_name
  if name == "island-light" then
    require("island.light").late()
  elseif name == "island-dark" then
    require("island").late()
  end
end

-- Rebuilding the chrome at run time ----------------------------------------------------------------

local function opts_of(name)
  local ok, plugin = pcall(function()
    return require("lazy.core.config").plugins[name]
  end)
  if not ok or not plugin then
    return nil
  end
  local ok2, opts = pcall(function()
    -- lazy caches the merged opts of a plugin: drop the cache so the opts functions run again and read
    -- the icon mode as it is now
    if plugin._ and plugin._.cache then
      plugin._.cache.opts = nil
    end
    return require("lazy.core.plugin").values(plugin, "opts", false)
  end)
  return ok2 and opts or nil
end

--- Rebuild what copies icons into its own options: statusline, tabline, tree, dashboard, dap-ui
--- (only if it is loaded; nothing is loaded by this). Returns the names it rebuilt.
--- @return string[]
function M.refresh()
  local done = {}
  local function try(name, fn)
    local ok = pcall(fn)
    if ok then
      done[#done + 1] = name
    end
  end
  if package.loaded["lualine"] then
    local o = opts_of("lualine.nvim")
    if o then
      try("lualine", function()
        require("lualine").setup(o)
      end)
    end
  end
  if package.loaded["bufferline"] then
    local o = opts_of("bufferline.nvim")
    if o then
      try("bufferline", function()
        require("bufferline").setup(o)
        M.legibility()
        vim.cmd("redrawtabline")
      end)
    end
  end
  if package.loaded["neo-tree"] then
    local o = opts_of("neo-tree.nvim")
    if o then
      try("neo-tree", function()
        -- NOT neo-tree's setup() again: a second call clears the tree's event subscriptions and never
        -- defines them again (setup/init.lua `events_setup`), so diagnostics, git and file-system updates
        -- would stop. Folder and file icons are drawn by tree_icon() below and follow the mode on the next
        -- draw; the expander arrows, git and diagnostic symbols are read at startup.
        require("neo-tree.sources.manager").refresh("filesystem")
      end)
    end
  end
  if package.loaded["dapui"] then
    local o = opts_of("nvim-dap-ui")
    if o then
      try("dap-ui", function()
        require("dapui").setup(o)
      end)
    end
  end
  if _G.Snacks and Snacks.config and Snacks.config.dashboard then
    local o = opts_of("snacks.nvim")
    if o and o.dashboard and o.dashboard.preset then
      try("dashboard", function()
        Snacks.config.dashboard.preset = vim.tbl_deep_extend("force", Snacks.config.dashboard.preset or {}, {
          header = o.dashboard.preset.header,
          keys = o.dashboard.preset.keys,
        })
        Snacks.config.dashboard.sections = o.dashboard.sections or Snacks.config.dashboard.sections
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.bo[b].filetype == "snacks_dashboard" and vim.api.nvim_buf_is_valid(b) then
            local wins = vim.fn.win_findbuf(b)
            if #wins > 0 then
              vim.api.nvim_win_call(wins[1], function()
                vim.api.nvim_buf_delete(b, { force = true })
                Snacks.dashboard.open()
              end)
            end
          end
        end
      end)
    end
  end
  try("code lens", function()
    for _, c in ipairs(vim.lsp.get_clients()) do
      if c:supports_method("textDocument/codeLens") then
        M.wrap_codelens(c)
      end
    end
    -- (enable(true) on an enabled buffer does nothing: off and on makes it ask the server again)
    if vim.lsp.codelens and vim.lsp.codelens.enable then
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if
          vim.api.nvim_buf_is_loaded(b) and #vim.lsp.get_clients({ bufnr = b, method = "textDocument/codeLens" }) > 0
        then
          vim.lsp.codelens.enable(false, { bufnr = b })
          vim.lsp.codelens.enable(true, { bufnr = b })
        end
      end
    end
  end)
  return done
end

-- File tree: icons that follow the icon mode at draw time -----------------------------------------------

--- neo-tree `default_component_configs.icon.provider`: the stock behaviour (file icons from
--- nvim-web-devicons, which is mini.icons here) plus plain-text folder icons while ascii mode is on.
function M.tree_icon(icon, node)
  if node.type == "file" or node.type == "terminal" then
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if ok then
      local text, hlg = devicons.get_icon(node.type == "terminal" and "terminal" or node.name)
      icon.text = text or icon.text
      icon.highlight = hlg or icon.highlight
    end
  elseif ui().ascii_active() and node.type == "directory" then
    local expanded = node:is_expanded()
    if node.loaded and not expanded and not node:has_children() then
      icon.text = "o"
    else
      icon.text = expanded and "-" or "+"
    end
  end
end

-- File tree: error colour (item 14) ----------------------------------------------------------------

--- neo-tree `components.name` for the filesystem source: the stock name, in `XynoTreeError` when the
--- file (or, for a folder, anything below it) has an ERROR diagnostic. Warnings do not colour a name
--- (the right-hand `diagnostics` component, errors only, stays as it is).
function M.tree_name(config, node, state)
  local result = require("neo-tree.sources.common.components").name(config, node, state)
  local diag = state.diagnostics_lookup
  if diag then
    local ok, utils = pcall(require, "neo-tree.utils")
    local d = ok and utils.index_by_path(diag, node:get_id())
    if d and d.severity_number == 1 then
      result.highlight = "XynoTreeError"
    end
  end
  return result
end

-- Winbar breadcrumbs (item 15) -----------------------------------------------------------------------

--- The winbar text of the current window: the path below the project root, then the symbol
--- breadcrumb (nvim-navic) when it has one. Called through `%{%v:lua...%}`; never errors.
--- @return string
function M.winbar_text()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then
    return ""
  end
  local rel = vim.fn.fnamemodify(name, ":.")
  if vim.fn.has("win32") == 1 then
    rel = rel:gsub("\\", "/") -- Windows spells it with backslashes
  end
  local sep = ui().ascii_active() and " > " or " › " -- (U+203A, plain Unicode, no Nerd Font)
  local parts = vim.split(rel, "/", { plain = true })
  local text = table.concat(parts, sep)
  local width = vim.api.nvim_win_get_width(0)
  if vim.fn.strdisplaywidth(text) > width - 4 then
    text = parts[#parts] -- the file name never goes
  end
  text = text:gsub("%%", "%%%%") -- the path is plain text; the navic part below is already statusline format
  local ok, navic = pcall(require, "nvim-navic")
  if ok and navic.is_available() then
    local loc = navic.get_location()
    if loc ~= "" then
      text = text .. sep .. loc -- carries its own %#Group# codes: must not be escaped (found on a real capture)
    end
  end
  return text
end

--- Switch the winbar on/off for all windows (`vim.g.xynovim_winbar`).
function M.apply_winbar()
  local on = vim.g.xynovim_winbar == true
  vim.o.winbar = on and "%{%v:lua.require('config.ui_chrome').winbar_text()%}" or ""
  return on
end

function M.setup()
  local group = vim.api.nvim_create_augroup("xynovim_ui_chrome", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local c = vim.lsp.get_client_by_id(args.data.client_id)
      if c and c.name == "rust-analyzer" then
        M.wrap_codelens(c)
      end
    end,
  })
  -- bufferline writes its tab groups when it loads (after the colorscheme): floor their contrast then too
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LazyLoad",
    callback = function(args)
      if args.data == "bufferline.nvim" then
        vim.schedule(M.legibility)
      end
    end,
  })
  vim.api.nvim_create_user_command("XynoWinbar", function(o)
    local a = vim.trim(o.args)
    if a == "on" or a == "off" or a == "toggle" or a == "" then
      if a == "toggle" or a == "" then
        vim.g.xynovim_winbar = not (vim.g.xynovim_winbar == true)
      else
        vim.g.xynovim_winbar = a == "on"
      end
      M.apply_winbar()
      vim.notify("winbar breadcrumbs: " .. (vim.g.xynovim_winbar and "on" or "off"))
    else
      vim.notify("XynoWinbar: on, off or toggle", vim.log.levels.WARN)
    end
  end, {
    nargs = "?",
    desc = "Breadcrumbs in the winbar (default off; the statusline keeps its own)",
    complete = function()
      return { "on", "off", "toggle" }
    end,
  })
  if vim.g.xynovim_winbar == true then
    M.apply_winbar()
  end
  require("config.rendered").setup()
end

return M
