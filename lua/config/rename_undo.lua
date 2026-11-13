-- One undo for a multi-file LSP edit (rename, code action...). Neovim keeps one undo tree per buffer, so
-- `u` after a project-wide rename undid one file and left the others renamed; auto-save then wrote that
-- half state to disk. VS Code and RustRover undo a refactoring as a whole.
--
-- apply_workspace_edit is wrapped to remember, for an edit that changes text in two or more buffers, each
-- buffer's undo sequence number before and after. `u` (and <C-r>) in one of those buffers, while it still
-- sits exactly at the state the edit left, goes back (forward) in all of them. Anything else is the stock
-- `u`: a count, a buffer that was edited since, a single-file edit. Edits that also create, rename or
-- delete files (a module rename) are not grouped: those cannot be undone from here.
local M = {}

local wrapped = false
--- the latest grouped edit: { bufs = { [bufnr] = { before = seq, after = seq } }, undone = bool }
M.last = nil

local function seq_cur(buf)
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.undotree().seq_cur
  end)
end

--- Buffers an edit changes text in (nil when it has file operations).
---@return integer[]|nil
local function text_buffers(edit)
  local uris = {}
  for uri, edits in pairs(edit.changes or {}) do
    if #edits > 0 then
      uris[#uris + 1] = uri
    end
  end
  for _, c in ipairs(edit.documentChanges or {}) do
    if c.kind then
      return nil
    end
    if c.textDocument and c.textDocument.uri and #(c.edits or {}) > 0 then
      uris[#uris + 1] = c.textDocument.uri
    end
  end
  local seen, bufs = {}, {}
  for _, uri in ipairs(uris) do
    local ok, buf = pcall(vim.uri_to_bufnr, uri)
    if ok and not seen[buf] then
      seen[buf] = true
      bufs[#bufs + 1] = buf
    end
  end
  return bufs
end

local function wrap()
  if wrapped then
    return
  end
  wrapped = true
  local orig = vim.lsp.util.apply_workspace_edit
  vim.lsp.util.apply_workspace_edit = function(edit, ...)
    local bufs = type(edit) == "table" and text_buffers(edit) or nil
    if not bufs or #bufs < 2 then
      return orig(edit, ...)
    end
    local before = {}
    for _, b in ipairs(bufs) do
      before[b] = vim.api.nvim_buf_is_loaded(b) and seq_cur(b) or 0
    end
    local res = orig(edit, ...)
    local group = { bufs = {}, undone = false }
    local n = 0
    for _, b in ipairs(bufs) do
      if vim.api.nvim_buf_is_loaded(b) then
        local after = seq_cur(b)
        if after ~= before[b] then
          group.bufs[b] = { before = before[b], after = after }
          n = n + 1
        end
      end
    end
    M.last = n >= 2 and group or nil
    return res
  end
end

--- Move every buffer of the group that still sits at `from` to `to`; returns moved, skipped.
local function move_all(group, from, to)
  local moved, skipped = 0, 0
  for b, s in pairs(group.bufs) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) and seq_cur(b) == s[from] then
      vim.api.nvim_buf_call(b, function()
        vim.cmd("silent undo " .. s[to])
      end)
      moved = moved + 1
    else
      skipped = skipped + 1
    end
  end
  return moved, skipped
end

--- The group when the current buffer sits at the state it left (`from` = "after" to undo, "before" to redo).
local function applicable(from, undone)
  local g = M.last
  local buf = vim.api.nvim_get_current_buf()
  if not (g and g.undone == undone and g.bufs[buf] and vim.v.count == 0 and vim.api.nvim_buf_is_loaded(buf)) then
    return nil
  end
  return seq_cur(buf) == g.bufs[buf][from] and g or nil
end

local function step(key, from, to, undone, msg)
  local g = applicable(from, undone)
  if not g then
    vim.cmd("normal! " .. (vim.v.count > 0 and vim.v.count or "") .. key)
    return
  end
  local moved, skipped = move_all(g, from, to)
  g.undone = not undone
  vim.notify(
    ("%s the multi-file edit in %d files%s"):format(
      msg,
      moved,
      skipped > 0 and (" (%d edited since: left as they are)"):format(skipped) or ""
    ),
    vim.log.levels.INFO
  )
end

function M.undo()
  step("u", "after", "before", false, "Undid")
end

function M.redo()
  step("\18", "before", "after", true, "Redid") -- <C-r>
end

--- Install the wrapper and the `u` / <C-r> maps; safe to call again.
function M.setup()
  wrap()
  vim.keymap.set("n", "u", M.undo, { desc = "Undo (a multi-file LSP edit as a whole)" })
  vim.keymap.set("n", "<C-r>", M.redo, { desc = "Redo (a multi-file LSP edit as a whole)" })
end

return M
