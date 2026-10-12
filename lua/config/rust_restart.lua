-- Keeps the two Rust servers alive and fresh.
--   * A server that dies (kill -9, OOM, a crash) is restarted automatically,
--     at most 3 times a minute, and shows as "RA stopped" / "clippy stopped"
--     in the statusline until it is back (lsp_status.lua). Neither
--     `:RustAnalyzer restart` nor `:lsp restart` can revive a dead client.
--   * :RustRestart restarts both by hand (also when one is already dead).
--   * bacon-ls hardlinks the workspace into a shadow once and re-syncs only
--     the files nvim reports, so an atomic replace from outside (`sed -i`,
--     `git checkout`/`pull`, an agent rewriting files) leaves clippy checking
--     the old content. On FocusGained, bacon-ls is restarted when a Rust or
--     Cargo file open in nvim was reloaded from disk, or the git HEAD of its
--     workspace moved.
--   * bacon-ls clients whose workspace directory no longer exists are stopped.
local M = {}

local starts = {} -- name -> os.time() of the automatic restarts in the last minute
local disk_changed = false
local heads = {} -- workspace root -> git HEAD signature when last looked at

local function bacon_clients()
  return vim.lsp.get_clients({ name = "bacon_ls" })
end

--- Start rust-analyzer for the rust buffers that lost it, bacon-ls for all
--- buffers that match its root_dir.
local function start(name, bufs)
  if name == "bacon_ls" then
    vim.lsp.enable("bacon_ls")
    return
  end
  local ok, lsp = pcall(require, "rustaceanvim.lsp")
  if not ok then
    return
  end
  for _, b in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(b) and #vim.lsp.get_clients({ bufnr = b, name = "rust-analyzer" }) == 0 then
      lsp.start(b)
    end
  end
end

--- on_exit callback for a server: records "stopped" on its buffers and
--- restarts it after an abnormal exit (graceful stops, `:lsp restart` and
--- quitting nvim exit with code 0 and signal 0 and are left alone).
function M.on_exit(name)
  return function(code, signal, client_id)
    if code == 0 and signal == 0 then
      return
    end
    -- runs in a fast event: read the buffers now (they are detached on the
    -- next tick), do the rest scheduled
    local client = vim.lsp.get_client_by_id(client_id)
    local bufs = vim.tbl_keys(client and client.attached_buffers or {})
    vim.schedule(function()
      for _, b in ipairs(bufs) do
        if vim.api.nvim_buf_is_valid(b) then
          local flags = vim.b[b].xynovim_stopped or {}
          flags[name] = true
          vim.b[b].xynovim_stopped = flags
        end
      end
      vim.cmd.redrawstatus()
      if vim.v.exiting ~= vim.NIL then
        return
      end
      local now = os.time()
      starts[name] = vim.tbl_filter(function(t)
        return now - t < 60
      end, starts[name] or {})
      if #starts[name] >= 3 then
        return vim.notify(
          ("%s keeps exiting (code %s, signal %s); giving up. :RustRestart tries again."):format(name, code, signal),
          vim.log.levels.ERROR
        )
      end
      table.insert(starts[name], now)
      vim.notify(("%s exited (code %s, signal %s); restarting"):format(name, code, signal), vim.log.levels.WARN)
      -- the dead client is only dropped from the client list a tick later
      vim.defer_fn(function()
        start(name, bufs)
      end, 500)
    end)
  end
end

--- Stop bacon-ls clients whose workspace directory is gone (a deleted crate
--- would otherwise keep its client and shadow forever).
function M.sweep()
  for _, c in ipairs(bacon_clients()) do
    local root = c.config.root_dir
    if root and not vim.uv.fs_stat(root) then
      c:stop(true)
    end
  end
end

--- HEAD of the git repo holding `root`: the branch's commit, or the HEAD
--- file itself when detached. nil outside a plain git directory.
local function git_head(root)
  local git = vim.fs.find(".git", { upward = true, path = root, type = "directory" })[1]
  if not git then
    return nil
  end
  local function read(f)
    local fh = io.open(f)
    if not fh then
      return nil
    end
    local t = fh:read("*a")
    fh:close()
    return vim.trim(t)
  end
  local head = read(git .. "/HEAD")
  local ref = head and head:match("^ref: (.+)$")
  if not ref then
    return head
  end
  return read(git .. "/" .. ref) or head -- packed refs: only a branch switch shows
end

--- Whether a buffer's file is a Rust/Cargo file below a bacon-ls workspace.
local function relevant(file)
  if not file:match("%.rs$") and not file:match("%.toml$") and not file:match("%.lock$") then
    return false
  end
  for _, c in ipairs(bacon_clients()) do
    local root = c.config.root_dir
    if root and file:sub(1, #root + 1) == root .. "/" then
      return true
    end
  end
  return false
end

local function refresh()
  M.sweep()
  vim.cmd("silent! checktime") -- reloads unmodified buffers; FileChangedShellPost marks them
  local moved = false
  for _, c in ipairs(bacon_clients()) do
    local root = c.config.root_dir
    local head = root and git_head(root)
    if head and heads[root] and heads[root] ~= head then
      moved = true
    end
    if root then
      heads[root] = head
    end
  end
  if disk_changed or moved then
    disk_changed = false
    if #bacon_clients() > 0 then
      vim.cmd("lsp restart bacon_ls")
    end
  end
end

function M.restart()
  M.sweep()
  local buf = vim.api.nvim_get_current_buf()
  local bufs = vim.tbl_filter(function(b)
    return vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "rust"
  end, vim.api.nvim_list_bufs())
  if #vim.lsp.get_clients({ name = "rust-analyzer" }) > 0 then
    pcall(vim.cmd.RustAnalyzer, "restart")
  elseif vim.bo[buf].filetype == "rust" or #bufs > 0 then
    start("rust-analyzer", bufs)
  end
  if #bacon_clients() > 0 then
    vim.cmd("lsp restart bacon_ls")
  else
    start("bacon_ls")
  end
  for _, b in ipairs(bufs) do
    vim.b[b].xynovim_stopped = nil
  end
  vim.notify("restarting rust-analyzer and bacon-ls")
end

function M.setup()
  local group = vim.api.nvim_create_augroup("xynovim_rust_restart", { clear = true })

  vim.api.nvim_create_user_command("RustRestart", M.restart, {
    desc = "Restart rust-analyzer and bacon-ls (also when one has died)",
  })

  vim.api.nvim_create_autocmd("FileChangedShellPost", {
    group = group,
    callback = function(ev)
      if relevant(vim.api.nvim_buf_get_name(ev.buf)) then
        disk_changed = true
      end
    end,
  })

  local timer
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      if #bacon_clients() == 0 then
        return
      end
      if timer then
        timer:stop()
      else
        timer = assert(vim.uv.new_timer())
      end
      timer:start(
        300,
        0,
        vim.schedule_wrap(function()
          refresh()
        end)
      )
    end,
  })

  -- remember the HEAD bacon-ls started on
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(ev)
      local c = vim.lsp.get_client_by_id(ev.data.client_id)
      local root = c and c.name == "bacon_ls" and c.config.root_dir
      if root and heads[root] == nil then
        heads[root] = git_head(root) or false
      end
    end,
  })
end

return M
