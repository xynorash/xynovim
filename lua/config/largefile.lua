-- Progressive feature shedding for large buffers.
--
-- snacks.nvim's bigfile (size > 1.5 MB or an average line over 1000 bytes) is an on/off switch: a
-- 0.9 MB, 40 000 line Rust file stayed "normal" and cost a 530-700 ms main-loop stall after opening
-- (scripts/bench, docs/bench/perf-2026-11.md). Profiling it with LuaJIT's sampler showed where the
-- time went: LazyVim's per-line `foldexpr` wrapper plus treesitter and LSP folds over the whole
-- buffer, the treesitter indent query, semantic tokens and inlay hints for the whole file, and the
-- context / words / indent-guide plugins. So the features whose cost grows with the BUFFER (not with
-- the window) are switched off by tier, and the ones that only look at the visible lines
-- (treesitter highlighting, diagnostics, completion, hover, go-to-definition) stay on.
--
--   tier 0  small: everything on
--   tier 1  large (>= 20 000 lines, >= 512 KB or an average line >= 300 bytes): folds, treesitter
--           indent, semantic tokens, inlay hints, code lens, spell, indent guides, word
--           illumination, sticky context and the breadcrumb are off for that buffer
--   tier 2  huge: snacks.nvim's bigfile (> 1.5 MB or an average line > 1000 bytes): no LSP, no
--           treesitter, filetype "bigfile" (this module only reports it)
--
-- Per-buffer, nothing global is touched. `:LargeFile` shows the tier and what was shed;
-- `:LargeFile off` brings the features of the current buffer back (folds, indent and hints return). Override the limits with
-- `vim.g.xynovim_largefile = { lines = 20000, bytes = 524288, avg_line = 300 }`
-- (any subset), or turn it off with `vim.g.xynovim_largefile = false`.
local M = {}

local defaults = { lines = 20000, bytes = 512 * 1024, avg_line = 300 }

---@return table
function M.limits()
  local o = vim.g.xynovim_largefile
  if type(o) ~= "table" then
    return defaults
  end
  return vim.tbl_extend("force", defaults, o)
end

--- Pure classification, so it can be tested without a buffer.
---@param lines integer
---@param bytes integer
---@param lim? table
---@return 0|1
function M.tier_of(lines, bytes, lim)
  lim = lim or M.limits()
  if lines >= lim.lines or bytes >= lim.bytes then
    return 1
  end
  if lines > 0 and (bytes - lines) / lines >= lim.avg_line then
    return 1
  end
  return 0
end

---@param buf integer
---@return 0|1|2
function M.tier(buf)
  if vim.g.xynovim_largefile == false or not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  if vim.bo[buf].filetype == "bigfile" then
    return 2
  end
  if vim.bo[buf].buftype ~= "" then
    return 0
  end
  local lines = vim.api.nvim_buf_line_count(buf)
  -- offset of the end of the buffer = its size in bytes
  local bytes = vim.api.nvim_buf_get_offset(buf, lines)
  return M.tier_of(lines, math.max(bytes, 0))
end

--- true when this buffer is in tier 1 or 2 (used by plugin specs, e.g. treesitter-context's on_attach).
---@param buf integer
function M.is_large(buf)
  return vim.b[buf].xyno_large ~= nil and vim.b[buf].xyno_large > 0
end

local SHED =
  { "injections", "folds", "indent", "spell", "snacks indent guides", "snacks words", "sticky context", "breadcrumb" }
local SHED_LSP = { "semantic tokens", "inlay hints", "code lens" }

local function lsp_shed(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not M.is_large(buf) then
    return
  end
  pcall(vim.lsp.semantic_tokens.enable, false, { bufnr = buf })
  pcall(vim.lsp.inlay_hint.enable, false, { bufnr = buf })
  if vim.lsp.codelens and vim.lsp.codelens.enable then
    pcall(vim.lsp.codelens.enable, false, { bufnr = buf })
  end
end

local function win_shed(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].spell = false
  end
end

--- Apply the tier to a buffer. Returns the tier.
---@param buf integer
function M.apply(buf)
  local t = M.tier(buf)
  if t == 0 then
    vim.b[buf].xyno_large = nil
    return 0
  end
  vim.b[buf].xyno_large = t
  if t == 2 then
    return t -- snacks.nvim's bigfile does the rest
  end
  -- Injections are searched over the whole tree on every parse: ~2 800 macro calls in a 40 000 line
  -- file are 2 800 nested Rust trees (the biggest part of the stall that was left after the folds).
  -- The parser of this buffer is created without the injection query of its own language, so macro
  -- arguments and sqlx strings lose their nested highlighting; the rest of the file keeps it.
  local lang = vim.treesitter.language.get_lang(vim.bo[buf].filetype)
  if lang then
    pcall(vim.treesitter.get_parser, buf, lang, { injections = { [lang] = "" } })
  end
  vim.b[buf].snacks_indent = false
  vim.b[buf].snacks_words = false
  vim.b[buf].navic_disabled = true
  vim.bo[buf].indentexpr = ""
  -- the window may not show the buffer yet (FileType runs before BufWinEnter): the current window
  -- is the one being filled, the others are handled on BufWinEnter
  if vim.api.nvim_get_current_buf() == buf then
    vim.wo.foldmethod = "manual"
    vim.wo.spell = false
  end
  win_shed(buf)
  lsp_shed(buf)
  -- LazyVim's treesitter FileType handler runs after this one and sets indentexpr / folds again
  -- (its set_default sees the untouched defaults): redo it once everything has run
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].xyno_large == 1 then
      vim.bo[buf].indentexpr = ""
      win_shed(buf)
    end
  end)
  return t
end

function M.describe(buf)
  local t = vim.b[buf].xyno_large or 0
  local lines = vim.api.nvim_buf_line_count(buf)
  local bytes = math.max(vim.api.nvim_buf_get_offset(buf, lines), 0)
  local s = ("tier %d (%d lines, %.0f KB)"):format(t, lines, bytes / 1024)
  if t == 1 then
    s = s .. ": off: " .. table.concat(vim.list_extend(vim.list_slice(SHED), SHED_LSP), ", ")
  elseif t == 2 then
    s = s .. ": snacks.nvim bigfile (no LSP, no treesitter)"
  else
    s = s .. ": all features on"
  end
  return s
end

local setup_done = false

function M.setup()
  if setup_done then
    return
  end
  setup_done = true
  local group = vim.api.nvim_create_augroup("xynovim_largefile", { clear = true })

  -- FileType: the buffer is loaded, and this runs before the plugins' FileType handlers that would
  -- start the treesitter folds (LazyVim.set_default leaves a foldmethod that was changed by a script alone).
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(ev)
      M.apply(ev.buf)
    end,
  })
  -- A plugin may still set the folds after FileType (LSP folds arrive with the client), and a
  -- window that opens the buffer later needs the window-local options.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
      if M.is_large(ev.buf) and vim.b[ev.buf].xyno_large == 1 then
        win_shed(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(ev)
      if M.is_large(ev.buf) and vim.b[ev.buf].xyno_large == 1 then
        -- LazyVim enables the hints / folds in its own LspAttach handlers: run after them
        vim.schedule(function()
          lsp_shed(ev.buf)
          win_shed(ev.buf)
        end)
      end
    end,
  })
  -- The buffer grows past a limit while typing (a paste of a big file): apply on the next write.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      local before = vim.b[ev.buf].xyno_large or 0
      local now = M.tier(ev.buf)
      if now == 1 and before == 0 then
        M.apply(ev.buf)
      end
    end,
  })

  vim.api.nvim_create_user_command("LargeFile", function(c)
    local buf = vim.api.nvim_get_current_buf()
    if c.args == "off" then
      vim.b[buf].xyno_large = nil
      vim.b[buf].snacks_indent = nil
      vim.b[buf].snacks_words = nil
      vim.b[buf].navic_disabled = nil
      vim.wo.foldmethod = "expr"
      vim.wo.foldexpr = "v:lua.LazyVim.treesitter.foldexpr()"
      vim.bo[buf].indentexpr = "v:lua.LazyVim.treesitter.indentexpr()"
      pcall(vim.lsp.semantic_tokens.enable, true, { bufnr = buf })
      pcall(vim.lsp.inlay_hint.enable, true, { bufnr = buf })
      vim.notify("LargeFile: features back on for this buffer")
    else
      vim.notify("LargeFile: " .. M.describe(buf))
    end
  end, {
    nargs = "?",
    complete = function()
      return { "off" }
    end,
    desc = "Show the large-file tier of the buffer; `off` restores its features",
  })
end

return M
