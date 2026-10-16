-- What auto-save must never do: write into dependency/std sources, overwrite a
-- file that changed on disk behind the buffer's back (git checkout, an agent,
-- `sed -i`, cargo fmt in another pane), or leave the files a multi-file
-- rename touched unsaved.
--   * Dependency and std buffers (~/.cargo/registry, ~/.cargo/git, ~/.rustup)
--     are nomodifiable (`:set modifiable` to hack on one deliberately).
--   * auto-save's `condition` (can_save): the disk mtime recorded when the
--     buffer was read/written must still match, else the save is skipped and
--     the user is warned once. nvim itself would stop at a blocking W12 "Do you
--     really want to write to it (y/n)?" that swallows keystrokes.
--   * FileChangedShell never prompts: an unmodified buffer is reloaded, a
--     modified one (or a deleted file) is left alone with one warning. (The
--     `:checktime` on FocusGained is LazyVim's own, group lazyvim_checktime.)
--   * Workspace edits touching other files (rename, file rename, code
--     actions) are followed by a write of every modified buffer that passes
--     can_save: undo/disk stay consistent without waiting for :wa.
local M = {}

local home = vim.uv.os_homedir()

-- Windows and macOS file systems are case-insensitive by default, and nvim
-- hands out backslash paths on Windows: compare normalized and lowercased.
local fold = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1
local function norm(p)
  local slash = p:sub(-1) == "/" or p:sub(-1) == "\\" -- normalize() drops a trailing slash, a root needs it
  p = vim.fs.normalize(p) .. (slash and "/" or "")
  return fold and p:lower() or p
end

local function dep_roots()
  local roots = { home .. "/.cargo/registry/", home .. "/.cargo/git/", home .. "/.rustup/" }
  for _, v in ipairs({ { "CARGO_HOME", "/registry/" }, { "CARGO_HOME", "/git/" }, { "RUSTUP_HOME", "/" } }) do
    local base = vim.env[v[1]]
    if base and base ~= "" then
      roots[#roots + 1] = vim.fs.normalize(base):gsub("/+$", "") .. v[2]
    end
  end
  for i, r in ipairs(roots) do
    roots[i] = norm(r)
  end
  return roots
end

--- @param name string
--- @return boolean
function M.is_dependency(name)
  name = norm(name)
  for _, r in ipairs(dep_roots()) do
    if name:sub(1, #r) == r then
      return true
    end
  end
  return false
end

--- mtime of the file behind `buf` as "sec.nsec" (nil: no such file).
local function stamp(name)
  local st = vim.uv.fs_stat(name)
  return st and ("%d.%09d"):format(st.mtime.sec, st.mtime.nsec) or nil
end

local function is_file_buf(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
end

local function record(buf)
  if is_file_buf(buf) then
    vim.b[buf].xynovim_disk_stamp = stamp(vim.api.nvim_buf_get_name(buf))
  end
end

local function warn_once(buf, key, msg)
  if vim.b[buf].xynovim_disk_warned ~= key then
    vim.b[buf].xynovim_disk_warned = key
    vim.notify(msg, vim.log.levels.WARN)
  end
end

--- auto-save's `condition`: may this buffer be written to disk now?
--- @param buf integer
--- @return boolean
function M.can_save(buf)
  -- Non-file buffers (the 99 prompt is an acwrite buffer) and readonly ones are
  -- never written: `:write` on them raised a blocking "'readonly' option is set" prompt.
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" or vim.bo[buf].readonly then
    return false
  end
  if not is_file_buf(buf) then
    return true
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if M.is_dependency(name) then
    return false
  end
  local was = vim.b[buf].xynovim_disk_stamp
  local now = stamp(name)
  if was == nil then
    -- never read or written by this nvim (new file, or opened before the guard
    -- ran): nothing to compare against
    record(buf)
    return true
  end
  local short = vim.fn.fnamemodify(name, ":~:.")
  if now == nil then
    warn_once(buf, "gone", short .. " no longer exists on disk: auto-save is paused for this buffer (:w to recreate it)")
    return false
  end
  if now ~= was then
    warn_once(
      buf,
      now,
      short .. " changed on disk while this buffer has unsaved edits: auto-save is paused for it (:w! keeps the buffer, :e! takes the disk version)"
    )
    return false
  end
  return true
end

--- Write every modified buffer that may be written. `write` (not noautocmd):
--- didSave, local history and neotest all hear about it.
function M.save_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(buf)
      and is_file_buf(buf)
      and vim.bo[buf].modified
      and vim.bo[buf].modifiable
      and M.can_save(buf)
    then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent! write")
      end)
    end
  end
end

--- Does a WorkspaceEdit touch anything but the current buffer?
local function touches_other_files(edit)
  local cur = vim.uri_from_bufnr(0)
  for uri in pairs(edit.changes or {}) do
    if uri ~= cur then
      return true
    end
  end
  for _, c in ipairs(edit.documentChanges or {}) do
    if c.kind or (c.textDocument and c.textDocument.uri ~= cur) then
      return true
    end
  end
  return false
end

local wrapped = false
local function wrap_workspace_edit()
  if wrapped then
    return
  end
  wrapped = true
  local orig = vim.lsp.util.apply_workspace_edit
  vim.lsp.util.apply_workspace_edit = function(edit, ...)
    local res = orig(edit, ...)
    if type(edit) == "table" and touches_other_files(edit) then
      vim.schedule(M.save_all)
    end
    return res
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("xynovim_disk_guard", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "BufFilePost", "FileChangedShellPost" }, {
    group = group,
    callback = function(ev)
      record(ev.buf)
    end,
  })
  -- auto-save checks `condition` when the event fires but writes up to a second
  -- later (debounce): the file may change in between. So check again right
  -- before the write, and turn a refused write into a harmless one: a "nowrite"
  -- buffer cannot be written (E382, silenced by auto-save's `silent!`).
  -- Whoever listens to AutoSaveWritePost can tell by `modified` still being set.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AutoSaveWritePre",
    callback = function(ev)
      local buf = ev.data and ev.data.saved_buffer
      if buf and vim.api.nvim_buf_is_valid(buf) and not M.can_save(buf) then
        vim.b[buf].xynovim_disk_buftype = vim.bo[buf].buftype
        vim.bo[buf].buftype = "nowrite"
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AutoSaveWritePost", -- auto-save writes with noautocmd: no BufWritePost
    callback = function(ev)
      local buf = ev.data and ev.data.saved_buffer
      if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
      end
      local bt = vim.b[buf].xynovim_disk_buftype
      if bt ~= nil then
        vim.bo[buf].buftype = bt
        vim.b[buf].xynovim_disk_buftype = nil
      else
        record(buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      if M.is_dependency(vim.api.nvim_buf_get_name(ev.buf)) then
        vim.bo[ev.buf].modifiable = false
        vim.bo[ev.buf].readonly = true
      end
    end,
  })
  vim.api.nvim_create_autocmd("FileChangedShell", {
    group = group,
    callback = function(ev)
      local reason = vim.v.fcs_reason
      if reason == "conflict" or reason == "deleted" then
        vim.v.fcs_choice = ""
        vim.b[ev.buf].xynovim_disk_warned = stamp(ev.file) or "gone" -- can_save need not repeat it
        local short = vim.fn.fnamemodify(ev.file, ":~:.")
        vim.notify(
          reason == "deleted" and (short .. " was deleted on disk (the buffer is kept)")
            or (short .. " changed on disk and the buffer has unsaved edits (:e! takes the disk version, :w! keeps the buffer)"),
          vim.log.levels.WARN
        )
      else
        vim.v.fcs_choice = vim.o.autoread and "reload" or "ask"
      end
    end,
  })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    once = true,
    callback = wrap_workspace_edit,
  })
  -- buffers opened before this ran
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      record(buf)
    end
  end
end

return M
