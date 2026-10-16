-- rust_restart.lua (server supervision), lsp_status.lua (statusline) and the
-- lualine component. The first half uses fake LSP clients and stubs
-- (deterministic, no servers); the second half ("live") runs rust-analyzer and
-- bacon-ls on scratch crates and kills them (skipped without the Rust tools).
-- The live half takes a few minutes: run it with `scripts/test.sh --timeout 600`.
-- xyno-os: linux (POSIX signals and /proc on language server processes)
local H = require("xynotest.helpers")

-- nvim-lspconfig (LazyVim enables bacon_ls from its config) must not first load
-- while vim.lsp.enable is stubbed
pcall(function()
  require("lazy").load({ plugins = { "nvim-lspconfig" } })
end)

local RR_GROUP, LS_GROUP = "xynovim_rust_restart", "xynovim_lsp_status"

local function fresh_restart()
  package.loaded["config.rust_restart"] = nil
  local rr = require("config.rust_restart")
  rr.setup()
  return rr
end

-- ------------------------------------------------------------------ stubs

--- Replaces vim.lsp.get_clients / get_client_by_id (fake clients only, for
--- the names the fakes use), vim.cmd (records and swallows `lsp restart` and
--- RustAnalyzer), vim.lsp.enable, vim.notify and rustaceanvim.lsp.start.
local stub
local function install_stubs()
  local s = {
    fakes = {},
    cmds = {},
    redraws = 0,
    notes = {},
    enabled = {},
    disabled = {},
    ra_starts = {},
    ra_cmds = {},
  }
  local o = {
    get_clients = vim.lsp.get_clients,
    get_client_by_id = vim.lsp.get_client_by_id,
    cmd = vim.cmd,
    enable = vim.lsp.enable,
    notify = vim.notify,
    ra = package.loaded["rustaceanvim.lsp"],
  }
  vim.lsp.get_clients = function(f)
    f = f or {}
    local out = {}
    for _, c in ipairs(s.fakes) do
      local b = f.bufnr
      if b == 0 then
        b = vim.api.nvim_get_current_buf()
      end
      if (not f.name or f.name == c.name) and (not b or c.attached_buffers[b]) then
        out[#out + 1] = c
      end
    end
    return out
  end
  vim.lsp.get_client_by_id = function(id)
    for _, c in ipairs(s.fakes) do
      if c.id == id then
        return c
      end
    end
  end
  vim.cmd = setmetatable({}, {
    __call = function(_, str, ...)
      s.cmds[#s.cmds + 1] = str
      if str == "lsp restart bacon_ls" then
        return
      end
      return o.cmd(str, ...)
    end,
    __index = function(_, k)
      return function(...)
        if k == "redrawstatus" then
          local src = debug.getinfo(2, "S").source
          if src:find("lsp_status.lua", 1, true) or src:find("rust_restart.lua", 1, true) then
            s.redraws = s.redraws + 1
          end
        elseif k == "RustAnalyzer" then
          s.ra_cmds[#s.ra_cmds + 1] = { ... }
          return
        end
        return o.cmd[k](...)
      end
    end,
  })
  vim.lsp.enable = function(name, on)
    if on == false then
      s.disabled[#s.disabled + 1] = name
      return
    end
    s.enabled[#s.enabled + 1] = name
  end
  vim.notify = function(msg, level)
    s.notes[#s.notes + 1] = { msg = msg, level = level }
  end
  package.loaded["rustaceanvim.lsp"] = {
    start = function(b)
      s.ra_starts[#s.ra_starts + 1] = b
    end,
  }
  s.restore = function()
    vim.lsp.get_clients, vim.lsp.get_client_by_id = o.get_clients, o.get_client_by_id
    vim.cmd, vim.lsp.enable, vim.notify = o.cmd, o.enable, o.notify
    package.loaded["rustaceanvim.lsp"] = o.ra
  end
  stub = s
  return s
end

local function remove_stubs()
  if stub then
    stub.restore()
    stub = nil
  end
end

local next_id = 9000
--- A fake client. opts: name, root, bufs (list), handlers.
local function fake_client(s, opts)
  next_id = next_id + 1
  local attached = {}
  for _, b in ipairs(opts.bufs or {}) do
    attached[b] = true
  end
  -- a bacon-ls root is a Cargo workspace root (sweep stops a client whose root lost it)
  if opts.root and opts.name == "bacon_ls" and vim.fn.isdirectory(opts.root) == 1 and vim.fn.filereadable(opts.root .. "/Cargo.toml") == 0 then
    vim.fn.writefile({ "[package]" }, opts.root .. "/Cargo.toml")
  end
  local c = {
    id = next_id,
    name = opts.name,
    config = { root_dir = opts.root },
    attached_buffers = attached,
    handlers = opts.handlers or {},
    stopped = nil,
  }
  c.stop = function(self, force)
    self.stopped = force or true
  end
  s.fakes[#s.fakes + 1] = c
  return c
end

--- Run fn with the fake clients hidden: nvim's own FileType handling (a reload
--- re-detects the filetype) would try to detach them as real clients.
local function without_fakes(s, fn)
  local keep = s.fakes
  s.fakes = {}
  local ok, e = pcall(fn)
  s.fakes = keep
  if not ok then
    error(e, 0)
  end
end

--- Let the redraws scheduled by earlier tests run (the tests do not yield).
local function flush()
  vim.wait(150, function()
    return false
  end, 10)
end

local function scratch_buf(name, ft)
  local b = vim.api.nvim_create_buf(false, true)
  if name then
    vim.api.nvim_buf_set_name(b, name)
  end
  if ft then
    vim.api.nvim_buf_call(b, function()
      vim.cmd("noautocmd set filetype=" .. ft)
    end)
  end
  return b
end

local function fire(event, group, data, buf)
  vim.api.nvim_exec_autocmds(event, { group = group, data = data, buffer = buf, modeline = false })
end

local function count(list, pred)
  local n = 0
  for _, v in ipairs(list) do
    if pred(v) then
      n = n + 1
    end
  end
  return n
end

local function has_cmd(s, str)
  return count(s.cmds, function(c)
    return c == str
  end)
end

-- ===================================================================== unit

describe("rust_restart: setup and on_exit", function()
  local s
  before_each(function()
    s = install_stubs()
    fresh_restart()
  end)
  after_each(function()
    remove_stubs()
    fresh_restart()
  end)

  it("defines :RustRestart (no args) and the autocmds in its group", function()
    local cmd = vim.api.nvim_get_commands({}).RustRestart
    H.ok(cmd, "RustRestart is defined")
    H.eq("0", cmd.nargs)
    local events = {}
    for _, a in ipairs(vim.api.nvim_get_autocmds({ group = RR_GROUP })) do
      events[a.event] = true
    end
    H.eq({ BufWritePost = true, FileChangedShellPost = true, FocusGained = true, LspAttach = true, User = true, VimLeavePre = true }, events)
  end)

  it("a clean exit (code 0, signal 0) does nothing", function()
    local b = scratch_buf()
    local c = fake_client(s, { name = "bacon_ls", bufs = { b } })
    require("config.rust_restart").on_exit("bacon_ls")(0, 0, c.id)
    vim.wait(800, function()
      return false
    end, 50)
    H.eq({}, s.notes)
    H.eq({}, s.enabled)
    H.eq(0, s.redraws)
    H.is_nil(vim.b[b].xynovim_stopped)
  end)

  it("an abnormal exit flags the buffers, redraws, warns and restarts bacon_ls after 500 ms", function()
    local b = scratch_buf()
    local c = fake_client(s, { name = "bacon_ls", bufs = { b } })
    local t0 = vim.uv.hrtime()
    require("config.rust_restart").on_exit("bacon_ls")(101, 0, c.id)
    H.wait_for(function()
      return vim.b[b].xynovim_stopped
    end, 2000, "stopped flag")
    H.eq({ bacon_ls = true }, vim.b[b].xynovim_stopped)
    H.ok(s.redraws >= 1, "statusline redrawn")
    H.eq({ { msg = "bacon_ls exited (code 101, signal 0); restarting", level = vim.log.levels.WARN } }, s.notes)
    H.eq({}, s.enabled, "not restarted yet")
    H.wait_for(function()
      return #s.enabled > 0
    end, 3000, "vim.lsp.enable('bacon_ls')")
    H.eq({ "bacon_ls" }, s.enabled)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    H.ok(ms >= 450, "restart is delayed by ~500 ms, was " .. ms)
  end)

  it("restarts rust-analyzer through rustaceanvim only for buffers lacking a client", function()
    local lost, kept = scratch_buf(), scratch_buf()
    local dying = fake_client(s, { name = "rust-analyzer", bufs = { lost, kept } })
    require("config.rust_restart").on_exit("rust-analyzer")(nil, 9, dying.id)
    H.wait_for(function()
      return vim.b[lost].xynovim_stopped
    end, 2000)
    H.eq({ ["rust-analyzer"] = true }, vim.b[lost].xynovim_stopped)
    H.eq({ ["rust-analyzer"] = true }, vim.b[kept].xynovim_stopped)
    -- a client that is back for `kept` (its replacement) by the time the restart runs
    s.fakes = {}
    fake_client(s, { name = "rust-analyzer", bufs = { kept } })
    H.wait_for(function()
      return #s.ra_starts > 0
    end, 3000, "rustaceanvim.lsp.start")
    H.eq({ lost }, s.ra_starts)
    H.eq({}, s.enabled)
  end)

  it("a signalled exit (SIGTERM, code 0 / signal 15) counts as abnormal", function()
    local b = scratch_buf()
    local c = fake_client(s, { name = "bacon_ls", bufs = { b } })
    require("config.rust_restart").on_exit("bacon_ls")(0, 15, c.id)
    H.wait_for(function()
      return #s.enabled > 0
    end, 3000, "restart after signal 15")
    H.eq("bacon_ls exited (code 0, signal 15); restarting", s.notes[1].msg)
    H.eq({ bacon_ls = true }, vim.b[b].xynovim_stopped)
  end)

  it("gives up after 3 automatic restarts in 60 s: ERROR on the 4th, status stays 'stopped'", function()
    local b = scratch_buf()
    local c = fake_client(s, { name = "bacon_ls", bufs = { b } })
    local on_exit = require("config.rust_restart").on_exit("bacon_ls")
    for i = 1, 4 do
      on_exit(2, 0, c.id)
      H.wait_for(function()
        return #s.notes >= i
      end, 2000, "notification " .. i)
    end
    for i = 1, 3 do
      H.eq(vim.log.levels.WARN, s.notes[i].level)
    end
    H.eq({
      msg = "bacon_ls keeps exiting (code 2, signal 0); giving up. :RustRestart tries again.",
      level = vim.log.levels.ERROR,
    }, s.notes[4])
    vim.wait(1000, function()
      return false
    end, 50)
    H.eq(3, #s.enabled, "three restarts, none for the 4th exit")
    -- no client any more (fakes still hold the dead one: drop it) -> stopped
    s.fakes = {}
    vim.api.nvim_set_current_buf(b)
    H.eq("clippy stopped", require("config.lsp_status").bacon(b))
  end)

  it("the loop guard is per server name", function()
    local b = scratch_buf()
    local c = fake_client(s, { name = "bacon_ls", bufs = { b } })
    local ra = fake_client(s, { name = "rust-analyzer", bufs = { b } })
    local rr = require("config.rust_restart")
    for _ = 1, 4 do
      rr.on_exit("bacon_ls")(2, 0, c.id)
    end
    rr.on_exit("rust-analyzer")(2, 0, ra.id)
    H.wait_for(function()
      return #s.notes >= 5
    end, 3000)
    local last = s.notes[#s.notes]
    H.eq(vim.log.levels.WARN, last.level)
    H.match(last.msg, "rust-analyzer exited", true)
  end)
end)

describe("rust_restart: :RustRestart and sweep", function()
  local s
  before_each(function()
    s = install_stubs()
    fresh_restart()
  end)
  after_each(function()
    remove_stubs()
    fresh_restart()
  end)

  it("sweep stops bacon_ls clients whose root_dir is gone, keeps the others", function()
    local alive, gone = H.tmpdir(), H.tmpdir()
    local c1 = fake_client(s, { name = "bacon_ls", root = alive })
    local c2 = fake_client(s, { name = "bacon_ls", root = gone })
    vim.fn.delete(gone, "rf")
    require("config.rust_restart").sweep()
    H.is_nil(c1.stopped)
    H.eq(true, c2.stopped, "stopped with force")
  end)

  it("sweep also stops a bacon_ls whose root lost its Cargo.toml (status stayed 'clippy ok')", function()
    local d = H.tmpdir()
    local c = fake_client(s, { name = "bacon_ls", root = d })
    vim.fn.delete(d .. "/Cargo.toml")
    require("config.rust_restart").sweep()
    H.eq(true, c.stopped)
  end)

  it("a save (BufWritePost or auto-save's User AutoSaveWritePost) sweeps too: a moved project is noticed without FocusGained", function()
    for _, fire_it in ipairs({
      function()
        vim.api.nvim_exec_autocmds("BufWritePost", { modeline = false })
      end,
      function()
        vim.api.nvim_exec_autocmds("User", { pattern = "AutoSaveWritePost", modeline = false })
      end,
    }) do
      local alive, gone = H.tmpdir(), H.tmpdir()
      local c1 = fake_client(s, { name = "bacon_ls", root = alive })
      local c2 = fake_client(s, { name = "bacon_ls", root = gone })
      vim.fn.delete(gone, "rf")
      fire_it()
      H.is_nil(c1.stopped)
      H.eq(true, c2.stopped, "stopped on save")
    end
  end)

  it("a save restarts bacon-ls once target/bacon-ls-live was recreated (cargo clean: clippy stayed 'ok' and blind)", function()
    local d = H.tmpdir()
    fake_client(s, { name = "bacon_ls", root = d })
    vim.fn.mkdir(d .. "/target/bacon-ls-live/shadow", "p")
    local save = function()
      vim.api.nvim_exec_autocmds("BufWritePost", { modeline = false })
    end
    save()
    save()
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"), "same directory: nothing to do")
    vim.fn.delete(d .. "/target", "rf")
    save()
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"), "gone and not yet recreated: nothing to compare")
    vim.fn.mkdir(d .. "/target/bacon-ls-live/shadow", "p")
    save()
    H.eq(1, has_cmd(s, "lsp restart bacon_ls"), "recreated: restart")
    save()
    H.eq(1, has_cmd(s, "lsp restart bacon_ls"), "once")
  end)

  it("a repaired or deleted Cargo.lock restarts bacon-ls only while clippy has failed", function()
    local d = H.tmpdir()
    local c = fake_client(s, { name = "bacon_ls", root = d })
    local ls = require("config.lsp_status")
    local orig, failed = ls.bacon_failed, false
    ls.bacon_failed = function(id)
      H.eq(c.id, id)
      return failed
    end
    local save = function()
      vim.api.nvim_exec_autocmds("BufWritePost", { modeline = false })
    end
    local ok, err = pcall(function()
      vim.fn.writefile({ "garbage = [" }, d .. "/Cargo.lock")
      save()
      vim.fn.writefile({ "# cargo rewrote it", "version = 4" }, d .. "/Cargo.lock")
      save()
      H.eq(0, has_cmd(s, "lsp restart bacon_ls"), "not failed: the lock is cargo's business")
      failed = true
      save()
      save()
      H.eq(0, has_cmd(s, "lsp restart bacon_ls"), "failed, lock unchanged")
      vim.fn.delete(d .. "/Cargo.lock")
      save()
      H.eq(1, has_cmd(s, "lsp restart bacon_ls"), "failed and the lock was deleted")
      save()
      H.eq(1, has_cmd(s, "lsp restart bacon_ls"), "once")
    end)
    ls.bacon_failed = orig
    H.ok(ok, tostring(err))
  end)

  it("the exit of a client sweep stopped (SIGTERM) is no crash: no 'exited ... restarting' warning, no restart", function()
    local gone = H.tmpdir()
    local c = fake_client(s, { name = "bacon_ls", root = gone, bufs = {} })
    vim.fn.delete(gone, "rf")
    local rr = require("config.rust_restart")
    -- earlier tests' deferred (500 ms) restarts fire in this window: let them go first
    vim.wait(700, function()
      return false
    end, 20)
    s.enabled, s.notes = {}, {}
    rr.sweep()
    H.eq(true, c.stopped)
    rr.on_exit("bacon_ls")(nil, 15, c.id) -- what a SIGTERMed server reports
    vim.wait(800, function()
      return false
    end, 20) -- the restart, if any, is deferred by 500 ms
    local warned = vim.tbl_filter(function(n)
      return n.msg:find("restarting", 1, true)
    end, s.notes)
    H.eq({}, warned)
    H.eq({}, s.enabled, "bacon_ls restarted for a deleted workspace")
  end)

  it("restarts rust-analyzer (RustAnalyzer restart) and bacon_ls, clears flags, notifies", function()
    local root, gone = H.tmpdir(), H.tmpdir()
    local rs = scratch_buf(root .. "/a.rs", "rust")
    local other = scratch_buf(nil, nil)
    vim.b[rs].xynovim_stopped = { ["rust-analyzer"] = true, bacon_ls = true }
    fake_client(s, { name = "rust-analyzer", bufs = { rs } })
    fake_client(s, { name = "bacon_ls", root = root, bufs = { rs } })
    local dead = fake_client(s, { name = "bacon_ls", root = gone })
    vim.fn.delete(gone, "rf")
    vim.api.nvim_set_current_buf(other)
    vim.cmd("RustRestart")
    H.eq(true, dead.stopped, "client with a missing root swept")
    H.eq({ { "restart" } }, s.ra_cmds)
    H.eq(1, has_cmd(s, "lsp restart bacon_ls"))
    H.eq({}, s.ra_starts)
    H.eq({}, s.enabled)
    H.is_nil(vim.b[rs].xynovim_stopped)
    H.eq({ { msg = "restarting rust-analyzer and bacon-ls", level = nil } }, s.notes)
  end)

  it("the bacon_ls start switches the config off and on (enable of an enabled config is a no-op: kill -9 stayed dead)", function()
    local rs = scratch_buf(H.tmpdir() .. "/c.rs", "rust")
    vim.api.nvim_set_current_buf(rs)
    vim.cmd("RustRestart")
    H.eq({ "bacon_ls" }, s.disabled)
    H.eq({ "bacon_ls" }, s.enabled)
  end)

  it("starts rust-analyzer for loaded rust buffers and bacon_ls when neither client exists", function()
    local rs = scratch_buf(H.tmpdir() .. "/b.rs", "rust")
    vim.b[rs].xynovim_stopped = { bacon_ls = true }
    vim.api.nvim_set_current_buf(rs)
    vim.cmd("RustRestart")
    H.eq({}, s.ra_cmds)
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"))
    H.has(s.ra_starts, rs)
    H.eq({ "bacon_ls" }, s.enabled)
    H.is_nil(vim.b[rs].xynovim_stopped)
  end)
end)

describe("rust_restart: VimLeavePre kill of servers that never initialised", function()
  local s
  before_each(function()
    s = install_stubs()
    fresh_restart()
  end)
  after_each(function()
    remove_stubs()
    fresh_restart()
  end)

  it("stops the uninitialised clients and SIGKILLs this nvim's server children of that name; initialised ones are left", function()
    local rr = require("config.rust_restart")
    local killed = {}
    local orig_kill, orig_pids = vim.uv.kill, rr.server_pids
    vim.uv.kill = function(pid, sig)
      killed[#killed + 1] = { pid, sig }
      return 0
    end
    rr.server_pids = function()
      return { [111] = "rust-analyzer", [222] = "bacon-ls" }
    end
    local ra = fake_client(s, { name = "rust-analyzer" })
    local bc = fake_client(s, { name = "bacon_ls", root = H.tmpdir() })
    ra.initialized = false
    bc.initialized = true
    local ok, e = pcall(rr.kill_uninitialised)
    vim.uv.kill, rr.server_pids = orig_kill, orig_pids
    H.ok(ok, tostring(e))
    H.eq(true, ra.stopped, "stopped with force")
    H.is_nil(bc.stopped)
    H.eq({ { 111, "sigkill" } }, killed)
    -- and the exit of the stopped one is no crash to restart from
    rr.on_exit("rust-analyzer")(nil, 9, ra.id)
    vim.wait(700, function()
      return false
    end, 20)
    H.eq({}, s.ra_starts)
  end)

  it("VimLeavePre sends SIGCONT to this nvim's server children first (SIGSTOPped servers were orphaned at quit)", function()
    local rr = require("config.rust_restart")
    local sent = {}
    local orig_kill, orig_pids = vim.uv.kill, rr.server_pids
    vim.uv.kill = function(pid, sig)
      sent[#sent + 1] = { pid, sig }
      return 0
    end
    rr.server_pids = function()
      return { [111] = "rust-analyzer" }
    end
    local ok, e = pcall(vim.api.nvim_exec_autocmds, "VimLeavePre", { group = "xynovim_rust_restart", modeline = false })
    vim.uv.kill, rr.server_pids = orig_kill, orig_pids
    H.ok(ok, tostring(e))
    H.eq({ { 111, "sigcont" } }, sent)
  end)

  it("with every client initialised nothing is killed", function()
    local rr = require("config.rust_restart")
    local killed = 0
    local orig_kill = vim.uv.kill
    vim.uv.kill = function()
      killed = killed + 1
      return 0
    end
    local c = fake_client(s, { name = "rust-analyzer" })
    c.initialized = true
    local ok, e = pcall(rr.kill_uninitialised)
    vim.uv.kill = orig_kill
    H.ok(ok, tostring(e))
    H.eq(0, killed)
    H.is_nil(c.stopped)
  end)
end)

describe("rust_restart: FocusGained refresh", function()
  local s
  before_each(function()
    s = install_stubs()
    fresh_restart()
  end)
  after_each(function()
    remove_stubs()
    fresh_restart()
  end)

  local function focus()
    fire("FocusGained", RR_GROUP)
  end
  local function settle(ms)
    vim.wait(ms or 900, function()
      return false
    end, 50)
  end
  local function attach(c)
    fire("LspAttach", RR_GROUP, { client_id = c.id })
  end
  --- a git repo with one commit; returns dir
  local function repo()
    local d = H.tmpdir()
    vim.fn.mkdir(d .. "/src", "p")
    vim.fn.writefile({ "fn main() {}" }, d .. "/src/main.rs")
    H.git_init(d)
    return d
  end

  it("does nothing without a bacon_ls client", function()
    focus()
    settle()
    H.eq(0, has_cmd(s, "silent! checktime"))
  end)

  it("no client left (swept while Cargo.toml was away): a loaded Rust buffer whose manifest is back starts bacon_ls", function()
    local d = repo()
    vim.cmd.edit(vim.fn.fnameescape(d .. "/src/main.rs"))
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].filetype = "rust"
    focus()
    settle()
    H.eq(0, #s.enabled, "no manifest: nothing to start")
    vim.fn.writefile({ "[package]", 'name = "t"', 'version = "0.1.0"', 'edition = "2021"' }, d .. "/Cargo.toml")
    focus()
    H.wait_for(function()
      return vim.tbl_contains(s.enabled, "bacon_ls")
    end, 3000, "bacon_ls enabled again")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("with a client: sweeps, runs checktime, no restart when nothing changed; debounced to one run", function()
    local d = repo()
    local c = fake_client(s, { name = "bacon_ls", root = d })
    attach(c)
    focus()
    focus()
    focus()
    H.wait_for(function()
      return has_cmd(s, "silent! checktime") > 0
    end, 3000, "checktime")
    settle()
    H.eq(1, has_cmd(s, "silent! checktime"))
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"))
    -- sweep ran: a deleted root is stopped
    vim.fn.delete(d, "rf")
    focus()
    H.wait_for(function()
      return c.stopped
    end, 3000, "sweep on focus")
  end)

  it("restarts bacon_ls when a .rs/.toml/.lock buffer under its root was reloaded from disk", function()
    local d = repo()
    local c = fake_client(s, { name = "bacon_ls", root = d })
    attach(c)
    for _, f in ipairs({ "src/main.rs", "Cargo.toml", "Cargo.lock" }) do
      local b = scratch_buf(d .. "/" .. f)
      fire("FileChangedShellPost", RR_GROUP, nil, b)
      focus()
      H.wait_for(function()
        return has_cmd(s, "lsp restart bacon_ls") > 0
      end, 3000, "restart after reload of " .. f)
      s.cmds = {}
      settle(400)
    end
  end)

  it("ignores reloads of other file types and of files outside the root", function()
    local d = repo()
    local c = fake_client(s, { name = "bacon_ls", root = d })
    attach(c)
    fire("FileChangedShellPost", RR_GROUP, nil, scratch_buf(d .. "/notes.txt"))
    fire("FileChangedShellPost", RR_GROUP, nil, scratch_buf(H.tmpdir() .. "/x.rs"))
    focus()
    H.wait_for(function()
      return has_cmd(s, "silent! checktime") > 0
    end, 3000)
    settle()
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"))
  end)

  it("a new commit moves HEAD and restarts bacon_ls; no change does not", function()
    local d = repo()
    local c = fake_client(s, { name = "bacon_ls", root = d })
    attach(c)
    focus()
    H.wait_for(function()
      return has_cmd(s, "silent! checktime") > 0
    end, 3000)
    settle()
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"), "no change, no restart")
    H.git(d, "commit", "-q", "--allow-empty", "-m", "two")
    attach(c) -- a second attach must not overwrite the remembered HEAD
    focus()
    H.wait_for(function()
      return has_cmd(s, "lsp restart bacon_ls") > 0
    end, 3000, "restart after the commit")
    -- the new HEAD is now remembered: another focus does not restart again
    s.cmds = {}
    focus()
    settle()
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"))
  end)

  it("a Cargo.toml changed on disk restarts bacon_ls on focus (a repaired manifest: 'clippy failed' stayed)", function()
    local d = repo()
    local c = fake_client(s, { name = "bacon_ls", root = d })
    attach(c)
    focus()
    H.wait_for(function()
      return has_cmd(s, "silent! checktime") > 0
    end, 3000)
    settle()
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"), "nothing changed")
    vim.uv.fs_utime(d .. "/Cargo.toml", 1000000000, 1000000000)
    focus()
    H.wait_for(function()
      return has_cmd(s, "lsp restart bacon_ls") > 0
    end, 3000, "restart after Cargo.toml changed")
    s.cmds = {}
    -- Cargo.lock is created and rewritten by cargo itself: no restart for it
    vim.fn.writefile({ "# lock" }, d .. "/Cargo.lock")
    focus()
    settle()
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"), "Cargo.lock is not watched")
    focus()
    settle()
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"), "remembered, no further restart")
  end)

  it("git_head: follows `ref:` to the ref file, detached HEAD is the sha", function()
    local d = repo()
    local c = fake_client(s, { name = "bacon_ls", root = d })
    attach(c)
    local sha = H.git(d, "rev-parse", "HEAD")
    -- detached: HEAD holds the sha
    H.git(d, "checkout", "-q", "--detach")
    -- HEAD now holds the sha text, which equals what the branch ref gave: same commit, no move
    focus()
    H.wait_for(function()
      return has_cmd(s, "silent! checktime") > 0
    end, 3000)
    settle()
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"))
    H.eq(sha, vim.trim(table.concat(vim.fn.readfile(d .. "/.git/HEAD"), "")), "HEAD is the sha")
    -- a different detached sha
    H.git(d, "commit", "-q", "--allow-empty", "-m", "three")
    local sha2 = H.git(d, "rev-parse", "HEAD")
    H.ok(sha ~= sha2)
    focus()
    H.wait_for(function()
      return has_cmd(s, "lsp restart bacon_ls") > 0
    end, 3000, "restart after a new detached sha")
  end)

  it("git_head: packed-refs fallback (ref file missing) uses the HEAD text, a branch switch shows", function()
    local d = repo()
    -- HEAD names a branch whose ref file does not exist (as with packed refs)
    vim.fn.writefile({ "ref: refs/heads/packed-a" }, d .. "/.git/HEAD")
    local c = fake_client(s, { name = "bacon_ls", root = d })
    attach(c)
    focus()
    H.wait_for(function()
      return has_cmd(s, "silent! checktime") > 0
    end, 3000)
    settle()
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"))
    vim.fn.writefile({ "ref: refs/heads/packed-b" }, d .. "/.git/HEAD")
    focus()
    H.wait_for(function()
      return has_cmd(s, "lsp restart bacon_ls") > 0
    end, 3000, "restart after a branch switch")
  end)

  it("git_head is nil outside a plain git directory: HEAD changes are not noticed", function()
    -- no .git at all
    local plain = H.tmpdir()
    local c1 = fake_client(s, { name = "bacon_ls", root = plain })
    attach(c1)
    focus()
    H.wait_for(function()
      return has_cmd(s, "silent! checktime") > 0
    end, 3000)
    settle()
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"))
    -- .git is a file (worktree/submodule), not a directory: not followed
    s.fakes = {}
    s.cmds = {}
    local wt = H.tmpdir()
    vim.fn.writefile({ "gitdir: /nonexistent" }, wt .. "/.git")
    local c2 = fake_client(s, { name = "bacon_ls", root = wt })
    attach(c2)
    focus()
    H.wait_for(function()
      return has_cmd(s, "silent! checktime") > 0
    end, 3000)
    settle()
    vim.fn.writefile({ "gitdir: /elsewhere" }, wt .. "/.git")
    focus()
    settle()
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"))
  end)

  it("a restart is only issued while a bacon_ls client still exists after sweep", function()
    local d = repo()
    local c = fake_client(s, { name = "bacon_ls", root = d })
    attach(c)
    fire("FileChangedShellPost", RR_GROUP, nil, scratch_buf(d .. "/src/lib.rs"))
    -- the client goes away before the debounce fires
    focus()
    s.fakes = {}
    settle()
    H.eq(0, has_cmd(s, "lsp restart bacon_ls"))
  end)
end)

-- --------------------------------------------------------------- lsp_status

describe("lsp_status (fake clients)", function()
  local s, status
  before_each(function()
    s = install_stubs()
    status = require("config.lsp_status")
  end)
  after_each(function()
    remove_stubs()
  end)

  local function ra_client(buf, orig)
    return fake_client(s, {
      name = "rust-analyzer",
      bufs = { buf },
      handlers = orig and { ["experimental/serverStatus"] = orig } or nil,
    })
  end
  local function attach(c, buf)
    fire("LspAttach", LS_GROUP, { client_id = c.id }, buf)
  end
  local function progress(c, token, value)
    fire("LspProgress", LS_GROUP, { client_id = c.id, params = { token = token, value = value } })
  end
  local function server_status(c, result)
    c.handlers["experimental/serverStatus"](nil, result, { client_id = c.id }, {})
  end

  it("rust_analyzer(): nil without a client and not stopped", function()
    local b = scratch_buf()
    H.is_nil(status.rust_analyzer(b))
    H.is_nil(status.bacon(b))
  end)

  it("rust_analyzer(): 'RA stopped' with the stopped flag, and no client", function()
    local b = scratch_buf()
    vim.b[b].xynovim_stopped = { ["rust-analyzer"] = true }
    H.eq("RA stopped", status.rust_analyzer(b))
    H.is_nil(status.bacon(b))
    vim.b[b].xynovim_stopped = { ["rust-analyzer"] = false }
    H.is_nil(status.rust_analyzer(b))
  end)

  it("rust_analyzer(): starting, progress with percentage, loading, error, warn, ready", function()
    local b = scratch_buf()
    local c = ra_client(b, function() end)
    attach(c, b)
    H.eq("RA starting", status.rust_analyzer(b))
    progress(c, "t1", { kind = "begin", title = "Indexing", percentage = 0 })
    H.eq("RA Indexing 0%", status.rust_analyzer(b))
    progress(c, "t1", { kind = "report", percentage = 42 })
    H.eq("RA Indexing 42%", status.rust_analyzer(b))
    progress(c, "t1", { kind = "end" })
    H.eq("RA starting", status.rust_analyzer(b), "no serverStatus yet")
    server_status(c, { health = "ok", quiescent = false })
    H.eq("RA loading", status.rust_analyzer(b))
    progress(c, "t2", { kind = "begin", title = "Roots Scanned", percentage = 7 })
    H.eq("RA Roots Scanned 7%", status.rust_analyzer(b))
    progress(c, "t2", { kind = "end" })
    server_status(c, { health = "error", quiescent = true })
    H.eq("RA error", status.rust_analyzer(b))
    server_status(c, { health = "warning", quiescent = true })
    H.eq("RA ready (warn)", status.rust_analyzer(b))
    server_status(c, { health = "ok", quiescent = true })
    H.eq("RA ready", status.rust_analyzer(b))
  end)

  it("progress_text: newest token wins, message fallback, ' N%', default 'working', end picks another", function()
    local b = scratch_buf()
    local c = ra_client(b, function() end)
    attach(c, b)
    server_status(c, { health = "ok", quiescent = true })
    progress(c, "a", { kind = "begin", title = "Indexing", percentage = 10 })
    progress(c, "b", { kind = "begin", message = "crate foo" })
    H.eq("RA crate foo", status.rust_analyzer(b), "newest token, message when no title")
    progress(c, "b", { kind = "report", percentage = 55 })
    H.eq("RA crate foo 55%", status.rust_analyzer(b))
    progress(c, "c", { kind = "begin" })
    H.eq("RA working", status.rust_analyzer(b), "neither title nor message")
    progress(c, "c", { kind = "end" })
    -- next() picks one of the remaining tokens
    local t = status.rust_analyzer(b)
    H.ok(t == "RA crate foo 55%" or t == "RA Indexing 10%", t)
    progress(c, "b", { kind = "end" })
    progress(c, "a", { kind = "end" })
    H.eq("RA ready", status.rust_analyzer(b))
  end)

  it("wraps experimental/serverStatus once per client and still calls the original", function()
    local b = scratch_buf()
    local calls = {}
    local orig = function(err, result)
      calls[#calls + 1] = result
    end
    local c = ra_client(b, orig)
    attach(c, b)
    local wrapped = c.handlers["experimental/serverStatus"]
    H.ok(wrapped ~= orig, "handler replaced")
    attach(c, b)
    attach(c, b)
    H.eq(wrapped, c.handlers["experimental/serverStatus"], "not wrapped again")
    server_status(c, { health = "ok", quiescent = true })
    H.eq({ { health = "ok", quiescent = true } }, calls, "original invoked exactly once per call")
    H.eq("RA ready", status.rust_analyzer(b))
  end)

  it("bacon(): clippy stopped / running / failed / stale / ok", function()
    local b = scratch_buf()
    vim.b[b].xynovim_stopped = { bacon_ls = true }
    H.eq("clippy stopped", status.bacon(b))
    vim.b[b].xynovim_stopped = nil

    local seen = {}
    local c = fake_client(s, {
      name = "bacon_ls",
      bufs = { b },
      handlers = {
        ["window/showMessage"] = function(_, r)
          seen[#seen + 1] = r
        end,
      },
    })
    attach(c, b)
    H.eq("clippy ok", status.bacon(b))
    progress(c, "r1", { kind = "begin", title = "checking" })
    H.eq("clippy running", status.bacon(b))
    progress(c, "r1", { kind = "end" })
    H.eq("clippy ok", status.bacon(b))
    -- an error message: failed (original handler still called), until the next run begins
    c.handlers["window/showMessage"](nil, { type = vim.lsp.protocol.MessageType.Error, message = "cargo exited: 101" }, {}, {})
    H.eq(1, #seen)
    H.eq("clippy failed", status.bacon(b))
    -- an info message does not fail it
    progress(c, "r2", { kind = "begin", title = "checking" })
    H.eq("clippy running", status.bacon(b), "running wins over failed")
    progress(c, "r2", { kind = "end" })
    H.eq("clippy ok", status.bacon(b), "next run cleared the failure")
    c.handlers["window/showMessage"](nil, { type = vim.lsp.protocol.MessageType.Info, message = "hi" }, {}, {})
    H.eq("clippy ok", status.bacon(b))
    -- an edit after the last finished run began: stale
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "edit" })
    H.eq("clippy stale", status.bacon(b))
    -- the next run began after the edit: it covers it
    progress(c, "r3", { kind = "begin", title = "checking" })
    progress(c, "r3", { kind = "end" })
    H.eq("clippy ok", status.bacon(b))
    -- an edit DURING a run is not covered by it
    progress(c, "r4", { kind = "begin", title = "checking" })
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "edit again" })
    progress(c, "r4", { kind = "end" })
    H.eq("clippy stale", status.bacon(b))
  end)

  it("a finished run with errors on screen says how many ('clippy 2E'), not 'clippy ok'", function()
    local b = scratch_buf()
    local c = fake_client(s, { name = "bacon_ls", bufs = { b } })
    attach(c, b)
    progress(c, "r1", { kind = "begin", title = "checking" })
    progress(c, "r1", { kind = "end" })
    H.eq("clippy ok", status.bacon(b))
    local ns = vim.lsp.diagnostic.get_namespace(c.id)
    local E, W = vim.diagnostic.severity.ERROR, vim.diagnostic.severity.WARN
    vim.diagnostic.set(ns, b, {
      { lnum = 0, col = 0, message = "e1", severity = E },
      { lnum = 0, col = 0, message = "e2", severity = E },
      { lnum = 0, col = 0, message = "w", severity = W },
    })
    H.eq("clippy 2E", status.bacon(b))
    vim.diagnostic.set(ns, b, { { lnum = 0, col = 0, message = "w", severity = W } })
    H.eq("clippy ok", status.bacon(b), "warnings do not count")
    vim.diagnostic.reset(ns, b)
  end)

  it("stale counts edits (nvim_buf_attach), not changedtick: :write does not leave it stale", function()
    local dir = H.tmpdir()
    local file = dir .. "/notes.txt"
    vim.fn.writefile({ "one" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    local b = vim.api.nvim_get_current_buf()
    local c = fake_client(s, { name = "bacon_ls", bufs = { b } })
    attach(c, b)
    progress(c, "r1", { kind = "begin", title = "checking" })
    progress(c, "r1", { kind = "end" })
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "two" })
    H.eq("clippy stale", status.bacon(b))
    progress(c, "r2", { kind = "begin", title = "checking" })
    progress(c, "r2", { kind = "end" })
    H.eq("clippy ok", status.bacon(b))
    local tick = vim.b[b].changedtick
    vim.cmd("write")
    H.ok(vim.b[b].changedtick >= tick)
    H.eq("clippy ok", status.bacon(b), "a write is not an edit")
    -- a reload from disk (checktime, what FocusGained does) counts as an edit
    vim.fn.writefile({ "three" }, file)
    without_fakes(s, function()
      vim.cmd("checktime")
    end)
    H.eq("three", vim.api.nvim_buf_get_lines(b, 0, 1, false)[1])
    H.eq("clippy stale", status.bacon(b), "a reload counts as an edit")
  end)

  it("edit counting survives :edit! (which detaches the buffer): the first edit after it is stale", function()
    local dir = H.tmpdir()
    local file = dir .. "/again.txt"
    vim.fn.writefile({ "one" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    local b = vim.api.nvim_get_current_buf()
    local c = fake_client(s, { name = "bacon_ls", bufs = { b } })
    attach(c, b)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "two" })
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "three" })
    progress(c, "r1", { kind = "begin", title = "checking" })
    progress(c, "r1", { kind = "end" })
    H.eq("clippy ok", status.bacon(b))
    without_fakes(s, function()
      vim.cmd("edit!")
    end) -- nvim_buf_attach detaches; the LSP client re-attaches (LspAttach again)
    attach(c, b)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "four" })
    H.eq("clippy stale", status.bacon(b))
  end)

  it("LspAttach clears the stopped flag of that server only", function()
    local b = scratch_buf()
    vim.b[b].xynovim_stopped = { bacon_ls = true, ["rust-analyzer"] = true }
    local c = fake_client(s, { name = "bacon_ls", bufs = { b } })
    attach(c, b)
    local flags = vim.b[b].xynovim_stopped
    H.not_ok(flags.bacon_ls)
    H.eq(true, flags["rust-analyzer"])
    H.eq("clippy ok", status.bacon(b))
    H.eq("RA stopped", status.rust_analyzer(b))
  end)

  it("component(): parts joined with ' | ', '' where neither server applies", function()
    local b = scratch_buf()
    vim.api.nvim_set_current_buf(b)
    H.eq("", status.component())
    local ra = ra_client(b, function() end)
    attach(ra, b)
    H.eq("RA starting", status.component())
    local bc = fake_client(s, { name = "bacon_ls", bufs = { b } })
    attach(bc, b)
    server_status(ra, { health = "ok", quiescent = true })
    H.eq("RA ready | clippy ok", status.component())
    s.fakes = { bc }
    H.eq("clippy ok", status.component())
    s.fakes = {}
    vim.b[b].xynovim_stopped = { bacon_ls = true, ["rust-analyzer"] = true }
    H.eq("RA stopped | clippy stopped", status.component())
  end)

  it("lualine: lualine_x[1] is the component, shown only when it is non-empty", function()
    local spec = dofile(H.repo .. "/lua/plugins/lualine.lua")
    local opts = { sections = { lualine_x = { "other" } } }
    spec.opts(nil, opts)
    H.eq("other", opts.sections.lualine_x[2])
    local item = opts.sections.lualine_x[1]
    H.eq(status.component, item[1])
    local b = scratch_buf()
    vim.api.nvim_set_current_buf(b)
    H.eq(false, item.cond())
    vim.b[b].xynovim_stopped = { bacon_ls = true }
    H.eq(true, item.cond())
    -- the running lualine got the same
    local ok, lualine = pcall(require, "lualine")
    if ok then
      local x = lualine.get_config().sections.lualine_x
      H.eq(status.component, x[1][1])
    end
  end)

  it("is event driven: no timers or polling, nothing scheduled at idle", function()
    local src = table.concat(vim.fn.readfile(H.repo .. "/lua/config/lsp_status.lua"), "\n")
    H.no_match(src, "new_timer", true)
    H.no_match(src, "timer_start", true)
    -- the one exception: "deps resolving" arms a 6 s grace and a 120 s ceiling timer
    -- (deps_begin), only while a manifest is being resolved
    local _, defers = src:gsub("defer_fn", "")
    H.eq(2, defers, "defer_fn only in deps_begin")
    H.no_match(src, "setInterval", true)
    local events = {}
    for _, a in ipairs(vim.api.nvim_get_autocmds({ group = LS_GROUP })) do
      events[a.event] = true
    end
    H.eq({ LspAttach = true, LspProgress = true, TextChanged = true, TextChangedI = true, BufWipeout = true }, events)
    local before = #vim.fn.timer_info()
    local b = scratch_buf()
    local c = ra_client(b, function() end)
    attach(c, b)
    progress(c, "x", { kind = "begin", title = "Indexing", percentage = 1 })
    progress(c, "x", { kind = "end" })
    vim.api.nvim_exec_autocmds("TextChanged", { group = LS_GROUP, buffer = b, modeline = false })
    H.eq(before, #vim.fn.timer_info(), "no vim timers created")
  end)

  it("a TextChanged in a buffer bacon-ls is attached to redraws (stale shows without other redraws)", function()
    local b = scratch_buf()
    vim.api.nvim_set_current_buf(b)
    local c = fake_client(s, { name = "bacon_ls", bufs = { b } })
    attach(c, b)
    flush()
    s.redraws = 0
    vim.api.nvim_exec_autocmds("TextChanged", { group = LS_GROUP, buffer = b, modeline = false })
    vim.wait(200, function()
      return false
    end, 20)
    H.ok(s.redraws >= 1)
  end)

  it("TextChanged in a buffer without a bacon-ls client does not redraw", function()
    local b = scratch_buf()
    vim.api.nvim_set_current_buf(b)
    flush()
    s.redraws = 0
    vim.api.nvim_exec_autocmds("TextChanged", { group = LS_GROUP, buffer = b, modeline = false })
    vim.wait(200, function()
      return false
    end, 20)
    H.eq(0, s.redraws)
  end)

  it("a standalone script ('Failed to discover workspace') is 'RA detached', other errors stay 'RA error'", function()
    local b = scratch_buf()
    local c = ra_client(b, function() end)
    attach(c, b)
    server_status(c, { health = "error", quiescent = true, message = "Failed to discover workspace.\nConsider adding the `Cargo.toml` of the workspace to the [`linkedProjects`] setting." })
    H.eq("RA detached", status.rust_analyzer(b))
    server_status(c, { health = "error", quiescent = true, message = "proc macro server crashed" })
    H.eq("RA error", status.rust_analyzer(b))
  end)
end)

-- ====================================================================== live

describe("live servers", function()
  local status = require("config.lsp_status")
  local crate, buf, lib

  local function bacon()
    return H.clients(nil, "bacon_ls")[1]
  end
  local function ra()
    return H.clients(nil, "rust-analyzer")[1]
  end
  local function comp()
    return status.component()
  end
  local function state()
    local names = vim.tbl_map(function(c)
      return c.name .. "#" .. c.id
    end, vim.lsp.get_clients())
    return ("component %q, clients %s, buf %s"):format(comp(), table.concat(names, ","), vim.api.nvim_buf_get_name(0))
  end
  --- finished and idle: "clippy ok", or "clippy 1E" while the crate has a clippy error on screen
  local function ready()
    local c = comp()
    return c == "RA ready | clippy ok" or c:match("^RA ready | clippy %d+E$") ~= nil
  end
  local function wait_ready(msg)
    if not vim.wait(120000, ready, 20) then
      error((msg or "'RA ready | clippy ok'") .. ": " .. state(), 2)
    end
  end
  local function sh(cmd)
    local r = vim.system({ "bash", "-c", cmd }, { cwd = crate, text = true }):wait(30000)
    H.eq(0, r.code, r.stderr)
  end
  local function focus()
    vim.cmd("doautocmd FocusGained")
  end
  local function bacon_diags(c)
    c = c or bacon()
    local n = {}
    for _, d in ipairs(vim.diagnostic.get(buf)) do
      local ns = vim.diagnostic.get_namespaces()[d.namespace]
      if ns and ns.name:find(("%d"):format(c.id), 1, true) and ns.name:find("bacon", 1, true) then
        n[#n + 1] = d
      end
    end
    return n
  end
  --- pid of the language server process of client `c`: a direct child of THIS
  --- nvim whose command is the server's binary (vim.lsp.rpc exposes no pid)
  local function pid(c)
    if not c then
      return nil
    end
    local comm = c.name == "bacon_ls" and "bacon-ls" or c.name
    local out = vim.fn.systemlist({ "ps", "-o", "pid=,comm=", "--ppid", tostring(vim.uv.os_getpid()) })
    local found
    for _, l in ipairs(out) do
      local p, name = l:match("^%s*(%d+)%s+(.+)$")
      if name == comm then
        found = tonumber(p) -- the newest one wins (ps lists by pid)
      end
    end
    return found
  end
  --- wait for a bacon_ls client attached to buf whose id is not `old_id`
  local function new_bacon(old_id, ms)
    return H.wait_for(function()
      local c = bacon()
      return c and c.id ~= old_id and H.clients(buf, "bacon_ls")[1]
    end, ms or 60000, "a new bacon_ls client")
  end

  before_each(function()
    H.need_rust()
    if vim.fn.executable("bacon-ls") ~= 1 then
      skip("bacon-ls not found")
    end
    if not crate then
      crate = H.fixture("basic", { git = true })
      vim.cmd.cd(vim.fn.fnameescape(crate))
      lib = crate .. "/src/lib.rs"
    end
  end)

  it("status sequence on a scratch crate: starting/running -> loading/indexing -> ready/ok, then stale -> running -> ok", function()
    local samples = {}
    local function sample()
      local c = comp()
      if c ~= "" and samples[#samples] ~= c then
        samples[#samples + 1] = c
      end
    end
    local au = vim.api.nvim_create_autocmd({ "LspAttach", "LspProgress" }, { callback = sample })
    buf = H.open(lib)
    if not vim.wait(120000, function()
      sample()
      return comp() == "RA ready | clippy ok"
    end, 20) then
      error("ready and ok: " .. state() .. " samples: " .. vim.inspect(samples))
    end
    vim.api.nvim_del_autocmd(au)
    local seq = table.concat(samples, "\n")
    H.match(seq, "RA starting", true)
    H.match(seq, "clippy running", true)
    H.match(seq, "RA %S.* %d+%%", false, "a progress line with a percentage")
    H.eq("RA ready | clippy ok", samples[#samples])

    -- an edit: stale -> running -> ok
    samples = {}
    local au2 = vim.api.nvim_create_autocmd({ "LspProgress" }, { callback = sample })
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "// edit" })
    sample()
    H.eq("RA ready | clippy stale", comp())
    H.wait_for(function()
      sample()
      return #samples > 1 and comp() == "RA ready | clippy ok"
    end, 60000, "stale -> running -> ok; samples: " .. vim.inspect(samples))
    vim.api.nvim_del_autocmd(au2)
    H.eq({ "RA ready | clippy stale", "RA ready | clippy running", "RA ready | clippy ok" }, samples)
  end)

  it("typing with auto-save on settles on 'clippy ok', not stale", function()
    vim.cmd.buffer(buf)
    H.feed("Goconst TYPED: i32 = 1;<Esc>")
    if not vim.wait(20000, function()
      return table.concat(vim.fn.readfile(lib), "\n"):find("TYPED", 1, true) ~= nil
    end, 50) then
      error("auto-save did not write the typed line: " .. vim.inspect(vim.api.nvim_buf_get_lines(buf, -5, -1, false)))
    end
    H.wait_for(function()
      return comp() == "RA ready | clippy ok"
    end, 60000, "'clippy ok' after the auto-save; is " .. comp())
    vim.wait(2500, function()
      return comp() ~= "RA ready | clippy ok"
    end, 50)
    H.eq("RA ready | clippy ok", comp(), "stays ok")
    H.match(table.concat(vim.fn.readfile(lib), "\n"), "const TYPED: i32 = 1;", true)
  end)

  it("sed -i on an open file then FocusGained restarts bacon-ls and the new clippy error appears", function()
    vim.cmd.buffer(buf)
    vim.cmd("silent! write")
    local old = bacon()
    -- clippy::eq_op is deny-by-default: an error that only clippy reports
    sh([[sed -i 's/return 42;/if 1 == 1 { return 1; } return 42;/' src/lib.rs]])
    focus()
    local new = new_bacon(old.id)
    H.match(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[17] or table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "1 == 1", true)
    H.wait_for(function()
      return #bacon_diags(new) > 0
    end, 90000, "clippy diagnostics from the new bacon-ls")
    local msgs = vim.tbl_map(function(d)
      return d.message
    end, bacon_diags(new))
    -- the message quotes the source line: it is the NEW content, not the shadow's old one
    H.match(table.concat(msgs, "\n"), "1 == 1", true)
    wait_ready()
  end)

  it("files not open in nvim changed on disk without a HEAD move are not noticed", function()
    local old = bacon()
    sh([[sed -i 's/println!/print!/' src/main.rs]])
    focus()
    vim.wait(2500, function()
      return bacon() == nil or bacon().id ~= old.id
    end, 50)
    H.ok(bacon() and bacon().id == old.id, "bacon-ls was not restarted")
  end)

  it("a new commit (HEAD moved) restarts bacon-ls on FocusGained; no change does not", function()
    local old = bacon()
    focus()
    vim.wait(2500, function()
      return bacon() == nil or bacon().id ~= old.id
    end, 50)
    H.ok(bacon() and bacon().id == old.id, "no change, no restart")
    H.git(crate, "commit", "-q", "--allow-empty", "-m", "moved")
    focus()
    local new = new_bacon(old.id)
    H.ok(new)
    wait_ready()
  end)

  it("a broken manifest gives 'clippy failed', repairing it gives 'clippy ok'", function()
    -- Cargo.toml open in nvim: its reload on FocusGained is what triggers the bacon-ls restart
    -- (in a window: checktime does not reload a hidden buffer)
    vim.cmd("split " .. vim.fn.fnameescape(crate .. "/Cargo.toml"))
    local toml = vim.api.nvim_get_current_buf()
    vim.cmd("wincmd p")
    local old = bacon()
    sh([[sed -i 's/^\[package\]/[packge]/' Cargo.toml]])
    focus()
    new_bacon(old.id)
    H.wait_for(function()
      return comp():find("clippy failed", 1, true) and true or false
    end, 60000, "'clippy failed'; is " .. comp())
    local broken = bacon()
    sh([[sed -i 's/^\[packge\]/[package]/' Cargo.toml]])
    focus()
    new_bacon(broken.id)
    H.wait_for(ready, 90000, "'clippy ok' after the repair; is " .. comp())
    pcall(vim.api.nvim_buf_delete, toml, { force = true })
    vim.cmd.buffer(buf)
  end)

  it("deleting a crate under a live bacon-ls client removes the client after FocusGained", function()
    local dir2 = H.fixture("basic", { git = true })
    local b2 = H.open(dir2 .. "/src/lib.rs")
    H.wait_for(function()
      for _, c in ipairs(H.clients(b2, "bacon_ls")) do
        if c.config.root_dir == dir2 then
          return c
        end
      end
    end, 60000, "bacon_ls for the second crate")
    vim.fn.delete(dir2, "rf")
    focus()
    H.wait_for(function()
      for _, c in ipairs(H.clients(nil, "bacon_ls")) do
        if c.config.root_dir == dir2 then
          return false
        end
      end
      return true
    end, 20000, "the client of the deleted crate to be gone")
    pcall(vim.api.nvim_buf_delete, b2, { force = true })
    vim.cmd.buffer(buf)
  end)

  it("kill -9 of both servers: 'RA stopped | clippy stopped', then both back with new pids and ok + clippy diagnostics", function()
    vim.cmd.buffer(buf)
    fresh_restart()
    local ra_old, bc_old = ra(), bacon()
    local pids = { ra = pid(ra_old), bc = pid(bc_old) }
    H.ok(pids.ra and pids.bc, "client pids")
    H.ok(pids.ra ~= pids.bc)
    vim.uv.kill(pids.ra, "sigkill")
    vim.uv.kill(pids.bc, "sigkill")
    H.wait_for(function()
      return comp() == "RA stopped | clippy stopped"
    end, 15000, "'RA stopped | clippy stopped'; is " .. comp())
    wait_ready("both servers back; is " .. comp())
    local ra_new, bc_new = ra(), bacon()
    H.ok(ra_new.id ~= ra_old.id and bc_new.id ~= bc_old.id, "new clients")
    H.ok(pid(ra_new) ~= pids.ra and pid(bc_new) ~= pids.bc, "new pids")
    H.wait_for(function()
      return #bacon_diags(bc_new) > 0
    end, 90000, "clippy diagnostics from the new bacon-ls")
  end)

  it(":RustRestart revives SIGSTOPped (hung) rust-analyzer and bacon-ls: new pids, ok again", function()
    vim.cmd.buffer(buf)
    fresh_restart()
    wait_ready()
    local ra_old, bc_old = ra(), bacon()
    local pids = { ra = pid(ra_old), bc = pid(bc_old) }
    H.ok(pids.ra and pids.bc, "client pids")
    vim.uv.kill(pids.ra, "sigstop")
    vim.uv.kill(pids.bc, "sigstop")
    local ok, err = pcall(function()
      vim.cmd("RustRestart")
      H.wait_for(function()
        local r, b = ra(), bacon()
        return r and b and r.id ~= ra_old.id and b.id ~= bc_old.id and pid(r) ~= pids.ra and pid(b) ~= pids.bc
      end, 60000, "new clients with new pids; is " .. state())
      wait_ready("both servers back after the hang; is " .. state())
    end)
    for _, p in pairs(pids) do
      vim.uv.kill(p, "sigkill") -- whatever is left of the stopped ones
    end
    if not ok then
      error(err, 0)
    end
  end)

  it("a SIGTERM exit counts as abnormal and restarts the server", function()
    vim.cmd.buffer(buf)
    fresh_restart()
    local cap = H.capture_notify()
    local old = bacon()
    vim.uv.kill(pid(old), "sigterm")
    new_bacon(old.id)
    local seen
    for _, n in ipairs(cap.list) do
      if n.msg:find("bacon_ls exited", 1, true) then
        seen = n
      end
    end
    H.ok(seen, "an 'exited' warning; got " .. vim.inspect(cap.list))
    H.match(seen.msg, "signal 15", true)
    H.eq(vim.log.levels.WARN, seen.level)
    wait_ready()
    cap.restore()
  end)

  it("four quick kills end at 'clippy stopped'; :RustRestart revives it", function()
    vim.cmd.buffer(buf)
    fresh_restart()
    local cap = H.capture_notify()
    local c = bacon()
    for i = 1, 3 do
      vim.uv.kill(pid(c), "sigkill")
      c = new_bacon(c.id)
    end
    vim.uv.kill(pid(c), "sigkill")
    H.wait_for(function()
      for _, n in ipairs(cap.list) do
        if n.level == vim.log.levels.ERROR and n.msg:find("keeps exiting", 1, true) then
          return true
        end
      end
    end, 20000, "the give-up error; got " .. vim.inspect(cap.list))
    vim.wait(2500, function()
      return bacon() ~= nil and not bacon().is_stopped()
    end, 50)
    H.eq("clippy stopped", status.bacon(buf), "no automatic restart; is " .. comp())
    cap.restore()
    vim.cmd("RustRestart")
    wait_ready("clippy back after :RustRestart; is " .. comp())
    H.ok(bacon())
  end)
end)
