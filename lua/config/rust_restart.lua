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
--     workspace moved, or its Cargo.toml changed on disk.
--   * A Cargo.toml or Cargo.lock SAVED from nvim (BufWritePost or auto-save's
--     AutoSaveWritePost) restarts bacon-ls 500 ms after the last save of a burst: it keeps
--     reporting "cannot find crate" for a dependency just added until restarted (measured
--     minutes), and its shadow workspace holds the old manifest. The statusline shows
--     "deps resolving" meanwhile (lsp_status.deps_begin). A `cargo add` in a terminal
--     reaches the same restart through the FocusGained path above (manifest mtime).
--     Loop guard: the restart records the new manifest mtime, so the next FocusGained does
--     not restart again; bacon-ls writes buffer text only into its shadow, never to the
--     workspace, so the restart cannot trigger another save.
--   * bacon-ls clients whose workspace directory no longer exists are stopped.
local M = {}

local starts = {} -- name -> os.time() of the automatic restarts in the last minute
local disk_changed = false
local heads = {} -- workspace root -> git HEAD signature when last looked at
local manifests = {} -- workspace root -> Cargo.toml mtime when last looked at
local lives = {} -- workspace root -> identity of target/bacon-ls-live when last looked at
local locks = {} -- workspace root -> Cargo.lock signature (kept while clippy is not failed)
local swept = {} -- client ids stopped by sweep(): their exit is not a crash
local SERVER_EXES = { ["rust-analyzer"] = true, ["bacon-ls"] = true }

local function bacon_clients()
  return vim.lsp.get_clients({ name = "bacon_ls" })
end

--- Start rust-analyzer for the rust buffers that lost it, bacon-ls for all
--- buffers that match its root_dir.
local function start(name, bufs)
  if name == "bacon_ls" then
    -- enable() of an already enabled config is a no-op, so a bacon-ls that died stayed
    -- dead in headless nvim (the field test's kill -9): off and on re-attaches the buffers
    if #bacon_clients() == 0 then
      vim.lsp.enable("bacon_ls", false)
    end
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
    if (code == 0 and signal == 0) or swept[client_id] then
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

--- Stop bacon-ls clients whose workspace directory is gone, or whose root
--- lost its Cargo.toml (moved away: the status stayed `clippy ok`); a deleted
--- crate would otherwise keep its client and shadow forever.
function M.sweep()
  for _, c in ipairs(bacon_clients()) do
    local root = c.config.root_dir
    if root and not (vim.uv.fs_stat(root) and vim.uv.fs_stat(root .. "/Cargo.toml")) then
      swept[c.id] = true
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

--- mtime of the root's Cargo.toml ("-" when absent). Not Cargo.lock: cargo/rust-analyzer
--- create and rewrite it on their own, which restarted bacon-ls for nothing.
local function manifest_sig(root)
  local st = vim.uv.fs_stat(root .. "/Cargo.toml")
  return st and (st.mtime.sec .. "." .. st.mtime.nsec) or "-"
end

--- Inode and birth time of the root's target/bacon-ls-live ("-" when absent): a `cargo clean`
--- deletes it and bacon-ls then recreates it, with the same path but another identity.
local function live_sig(root)
  local st = vim.uv.fs_stat(root .. "/target/bacon-ls-live")
  return st and (st.ino .. ":" .. (st.birthtime and (st.birthtime.sec .. "." .. st.birthtime.nsec) or "")) or "-"
end

local function lock_sig(root)
  local st = vim.uv.fs_stat(root .. "/Cargo.lock")
  return st and (st.size .. ":" .. st.mtime.sec .. "." .. st.mtime.nsec) or "-"
end

--- On a save: restart bacon-ls when its in-memory shadow no longer matches the disk.
---  * `cargo clean` wiped target/bacon-ls-live under a running bacon-ls, which then never
---    reported a new error again while the status said `clippy ok` (field test).
---  * Cargo.lock was repaired/deleted while clippy has `failed`: the shadow kept the bad
---    hardlinked lock. (Watched only in that state: cargo rewrites the lock itself.)
function M.check_shadow()
  local restart = false
  for _, c in ipairs(bacon_clients()) do
    local root = c.config.root_dir
    if root and root:sub(1, 1) == "/" then
      local live = live_sig(root)
      if live ~= "-" and lives[root] and lives[root] ~= live then
        restart = true
      end
      lives[root] = live ~= "-" and live or lives[root]
      local lock = lock_sig(root)
      if not require("config.lsp_status").bacon_failed(c.id) then
        locks[root] = lock
      elseif locks[root] == nil then
        locks[root] = lock
      elseif locks[root] ~= lock then
        locks[root] = lock
        restart = true
      end
    end
  end
  if restart then
    lives, locks = {}, {}
    vim.cmd("lsp restart bacon_ls")
    vim.notify("bacon-ls restarted (target/ was cleaned or Cargo.lock changed)", vim.log.levels.INFO)
  end
  return restart
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

--- A loaded Rust buffer whose workspace has a Cargo.toml but no bacon-ls client.
local function orphan_rust_buffer()
  local ok, rc = pcall(require, "config.rust_context")
  if not ok then
    return false
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "rust" and vim.bo[b].buftype == "" and name:sub(1, 1) == "/" and not name:find("/%.cargo/registry/") and not name:find("/%.cargo/git/") and not name:find("/%.rustup/") then
      local root = rc.root(name)
      if root and root:sub(1, 1) == "/" and vim.uv.fs_stat(root .. "/Cargo.toml") then
        return true
      end
    end
  end
  return false
end

--- The root of the server workspace (bacon-ls or rust-analyzer) that contains `file`.
local function server_root(file)
  for _, name in ipairs({ "bacon_ls", "rust-analyzer" }) do
    for _, c in ipairs(vim.lsp.get_clients({ name = name })) do
      local root = c.config.root_dir
      if root and root:sub(1, 1) == "/" and file:sub(1, #root + 1) == root .. "/" then
        return root
      end
    end
  end
end

local manifest_timer

--- A Cargo.toml / Cargo.lock was saved from nvim: show "deps resolving" and restart bacon-ls
--- once per burst of saves (500 ms debounce). Returns whether `file` was such a manifest.
function M.manifest_saved(file, buf)
  local base = file and vim.fs.basename(file)
  if base ~= "Cargo.toml" and base ~= "Cargo.lock" then
    return false
  end
  local root = server_root(file)
  if not root then
    return false
  end
  require("config.lsp_status").deps_begin(root, buf)
  if manifest_timer then
    manifest_timer:stop()
  else
    manifest_timer = assert(vim.uv.new_timer())
  end
  manifest_timer:start(
    500,
    0,
    vim.schedule_wrap(function()
      if #bacon_clients() == 0 then
        return
      end
      -- what we are about to restart for is already seen: FocusGained must not restart again
      for _, c in ipairs(bacon_clients()) do
        local r = c.config.root_dir
        if r then
          manifests[r] = manifest_sig(r)
        end
      end
      lives, locks = {}, {}
      vim.cmd("lsp restart bacon_ls")
    end)
  )
  return true
end

local function refresh()
  M.sweep()
  -- the manifest was away (deleted, a checkout without it) and is back: the sweep had stopped
  -- the client and nothing re-enabled it; only :RustRestart or reopening the buffer did
  if #bacon_clients() == 0 and orphan_rust_buffer() then
    start("bacon_ls")
  end
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
      -- a Cargo.toml repaired from outside: "clippy failed" stayed until the next edit
      local sig = manifest_sig(root)
      -- (a vanished manifest is sweep()'s business, not a reason to restart every client)
      if sig ~= "-" and manifests[root] and manifests[root] ~= sig then
        moved = true
        require("config.lsp_status").deps_begin(root) -- cargo add in a terminal: same transient as a save
      end
      manifests[root] = sig
    end
  end
  if disk_changed or moved then
    disk_changed = false
    if #bacon_clients() > 0 then
      vim.cmd("lsp restart bacon_ls")
    end
  end
end

--- pid -> name of the Rust servers that are children of this nvim.
function M.server_pids()
  local out = {}
  for _, pid in ipairs(vim.api.nvim_get_proc_children(vim.uv.os_getpid())) do
    local p = vim.api.nvim_get_proc(pid)
    local name = p and p.name:gsub("%.exe$", "") -- Windows names carry the .exe
    if p and SERVER_EXES[name] then
      out[pid] = name
    end
  end
  return out
end

--- SIGKILL the processes of `pids` that are still alive after `ms`. A server
--- that hangs or was SIGSTOPped never answers the shutdown request and a
--- stopped process does not act on SIGTERM either, so a graceful restart
--- alone left it in place; its exit then lets the supervision above start a
--- fresh one.
function M.kill_survivors(pids, ms)
  vim.defer_fn(function()
    for pid, name in pairs(pids) do
      local p = vim.api.nvim_get_proc(pid)
      if p and p.name:gsub("%.exe$", "") == name then
        vim.uv.kill(pid, "sigkill")
      end
    end
  end, ms or 3000)
end

--- VimLeavePre: a rust-analyzer or bacon-ls that has not answered `initialize` yet
--- never gets (or answers) the shutdown handshake when nvim quits right after
--- opening a file, and was left behind with PPID 1 (field test, seen under load,
--- 1 of 40 quits). Those are stopped and SIGKILLed here; initialised servers
--- shut down through nvim's own exit path.
function M.kill_uninitialised()
  local exes = {}
  for _, name in ipairs({ "rust-analyzer", "bacon_ls" }) do
    for _, c in ipairs(vim.lsp.get_clients({ name = name })) do
      if not c.initialized then
        swept[c.id] = true
        pcall(c.stop, c, true)
        exes[name == "bacon_ls" and "bacon-ls" or name] = true
      end
    end
  end
  -- (vim.lsp.rpc exposes no pid: the servers are this nvim's children, by name)
  for pid, name in pairs(M.server_pids()) do
    if exes[name] then
      vim.uv.kill(pid, "sigkill")
    end
  end
end

--- VimLeavePre: a SIGSTOPped server does not act on the SIGTERM/shutdown of nvim's exit and was
--- orphaned (state T, PPID 1). SIGCONT lets it handle them (harmless for a running one).
function M.resume_servers()
  if vim.fn.has("win32") == 1 then -- no SIGSTOP / SIGCONT there
    return
  end
  for pid in pairs(M.server_pids()) do
    vim.uv.kill(pid, "sigcont")
  end
end

function M.restart()
  require("config.lsp_status").deps_clear()
  M.sweep()
  M.kill_survivors(M.server_pids())
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

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.resume_servers()
      M.kill_uninitialised()
    end,
  })

  -- A project directory moved or deleted under a running nvim: bacon-ls recreated
  -- <old path>/target/bacon-ls-live on the next edit and the status said `clippy ok` until
  -- FocusGained (tmux has focus-events off by default). A save is cheap to hook: two stats per client.
  vim.api.nvim_create_autocmd({ "BufWritePost", "User" }, {
    group = group,
    pattern = { "*", "AutoSaveWritePost" },
    callback = function(ev)
      if ev.event == "User" and ev.match ~= "AutoSaveWritePost" then
        return
      end
      if #bacon_clients() > 0 then
        M.sweep()
        M.check_shadow()
      end
      local buf = ev.event == "User" and ev.data and ev.data.saved_buffer or ev.buf
      if buf and vim.api.nvim_buf_is_valid(buf) then
        M.manifest_saved(vim.api.nvim_buf_get_name(buf), buf)
      end
    end,
  })

  local timer
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      if #bacon_clients() == 0 and not orphan_rust_buffer() then
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
        manifests[root] = manifest_sig(root)
      end
    end,
  })
end

return M
