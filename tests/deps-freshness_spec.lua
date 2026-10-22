-- Phase 0 of docs/PLAN_MACROS_DEPS.md: a dependency added to Cargo.toml must not leave a
-- stale "cannot find crate" clippy error behind (rust_restart.manifest_saved) and the
-- statusline says "deps resolving" until rust-analyzer's workspace load is over (lsp_status).
-- The first two blocks use fake clients and stubs (no servers); the last one runs the real
-- servers on a copy of tests/fixtures/deps-lab (skipped without the Rust tools or crates.io).
local H = require("xynotest.helpers")

pcall(function()
  require("lazy").load({ plugins = { "nvim-lspconfig" } })
end)

local RR_GROUP, LS_GROUP = "xyno_rust_restart", "xyno_rust_lsp_status"

local function fresh_restart()
  package.loaded["xyno_rust.rust_restart"] = nil
  local rr = require("xyno_rust.rust_restart")
  rr.setup()
  return rr
end

local function settle(ms)
  vim.wait(ms, function()
    return false
  end, 25)
end

-- ------------------------------------------------------------------ stubs

local stub
--- Fake clients for vim.lsp.get_clients / get_client_by_id; vim.cmd records `lsp restart`.
local function install_stubs()
  local s = { fakes = {}, cmds = {} }
  local o = { get_clients = vim.lsp.get_clients, get_client_by_id = vim.lsp.get_client_by_id, cmd = vim.cmd }
  vim.lsp.get_clients = function(f)
    f = f or {}
    local out = {}
    for _, c in ipairs(s.fakes) do
      local b = f.bufnr == 0 and vim.api.nvim_get_current_buf() or f.bufnr
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
      return o.cmd[k]
    end,
  })
  s.restarts = function()
    local n = 0
    for _, c in ipairs(s.cmds) do
      if c == "lsp restart bacon_ls" then
        n = n + 1
      end
    end
    return n
  end
  s.restore = function()
    vim.lsp.get_clients, vim.lsp.get_client_by_id, vim.cmd = o.get_clients, o.get_client_by_id, o.cmd
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

local next_id = 19000
local function fake_client(s, name, root, bufs)
  next_id = next_id + 1
  local attached = {}
  for _, b in ipairs(bufs or {}) do
    attached[b] = true
  end
  local c = {
    id = next_id,
    name = name,
    config = { root_dir = root },
    attached_buffers = attached,
    handlers = { ["experimental/serverStatus"] = function() end },
  }
  c.stop = function() end
  s.fakes[#s.fakes + 1] = c
  return c
end

local function fire(event, group, data, buf)
  vim.api.nvim_exec_autocmds(event, { group = group, data = data, buffer = buf, modeline = false })
end

--- A crate directory (Cargo.toml + src/main.rs) and a loaded buffer for `rel` in it.
local function crate()
  local d = H.tmpdir()
  vim.fn.mkdir(d .. "/src", "p")
  vim.fn.writefile({ "[package]", 'name = "t"', 'version = "0.1.0"', 'edition = "2021"' }, d .. "/Cargo.toml")
  vim.fn.writefile({ "fn main() {}" }, d .. "/src/main.rs")
  return d
end

--- A scratch buffer named `path` (nothing is read: a loaded .rs buffer would start real servers
--- under the stubs). One per path.
local named = {}
local function buf_of(path)
  local b = named[path]
  if not (b and vim.api.nvim_buf_is_valid(b)) then
    b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(b, path)
    named[path] = b
  end
  return b
end

-- --------------------------------------------------------- restart on save

describe("deps-freshness: Cargo.toml / Cargo.lock saved from nvim restarts bacon-ls", function()
  local s, d, bacon
  before_each(function()
    s = install_stubs()
    fresh_restart()
    d = crate()
    bacon = fake_client(s, "bacon_ls", d, {})
  end)
  after_each(function()
    remove_stubs()
    fresh_restart()
    require("xyno_rust.lsp_status").deps_clear()
  end)

  it("BufWritePost of Cargo.toml: one debounced restart and 'deps resolving' on the crate's buffers", function()
    H.known_issue({ "windows" }, "bacon_ls never attaches on Windows (windows-latest run 39647013043; Mason installed bacon-ls but no client starts, cause not found)")
    local mb, rb = buf_of(d .. "/Cargo.toml"), buf_of(d .. "/src/main.rs")
    fire("BufWritePost", RR_GROUP, nil, mb)
    H.eq("deps resolving", require("xyno_rust.lsp_status").deps(rb))
    H.eq(0, s.restarts(), "debounced: nothing at once")
    H.wait_for(function()
      return s.restarts() > 0
    end, 3000, "restart after the Cargo.toml save")
    settle(900)
    H.eq(1, s.restarts())
    H.ok(bacon)
  end)

  it("auto-save's User AutoSaveWritePost (saved_buffer) does the same, for Cargo.lock too", function()
    H.known_issue({ "windows" }, "bacon_ls never attaches on Windows (windows-latest run 39647013043; Mason installed bacon-ls but no client starts, cause not found)")
    local lb = buf_of(d .. "/Cargo.lock")
    fire("User", RR_GROUP, { saved_buffer = lb }, nil)
    -- (User pattern is matched on the event's pattern: exec with it)
    vim.api.nvim_exec_autocmds("User", { pattern = "AutoSaveWritePost", group = RR_GROUP, data = { saved_buffer = lb }, modeline = false })
    H.wait_for(function()
      return s.restarts() > 0
    end, 3000, "restart after the Cargo.lock auto-save")
  end)

  it("a burst of saves is one restart (500 ms debounce)", function()
    H.known_issue({ "windows" }, "bacon_ls never attaches on Windows (windows-latest run 39647013043; Mason installed bacon-ls but no client starts, cause not found)")
    local mb = buf_of(d .. "/Cargo.toml")
    for _ = 1, 4 do
      fire("BufWritePost", RR_GROUP, nil, mb)
      settle(100)
    end
    settle(1200)
    H.eq(1, s.restarts())
  end)

  it("other files, and manifests outside every server workspace, do not restart", function()
    fire("BufWritePost", RR_GROUP, nil, buf_of(d .. "/src/main.rs"))
    local other = crate()
    fire("BufWritePost", RR_GROUP, nil, buf_of(other .. "/Cargo.toml"))
    settle(1000)
    H.eq(0, s.restarts())
    H.is_nil(require("xyno_rust.lsp_status").deps(buf_of(other .. "/src/main.rs")))
  end)

  it("loop guard: FocusGained after the save's restart does not restart again", function()
    H.known_issue({ "windows" }, "bacon_ls never attaches on Windows (windows-latest run 39647013043; Mason installed bacon-ls but no client starts, cause not found)")
    local mb = buf_of(d .. "/Cargo.toml")
    fire("LspAttach", RR_GROUP, { client_id = bacon.id })
    vim.fn.writefile({ "[package]", 'name = "t"', 'version = "0.1.1"' }, d .. "/Cargo.toml")
    fire("BufWritePost", RR_GROUP, nil, mb)
    H.wait_for(function()
      return s.restarts() == 1
    end, 3000)
    fire("FocusGained", RR_GROUP)
    settle(1200)
    H.eq(1, s.restarts())
  end)

  it("a Cargo.toml changed on disk (cargo add in a terminal) restarts on focus and shows 'deps resolving'", function()
    local rb = buf_of(d .. "/src/main.rs")
    fire("LspAttach", RR_GROUP, { client_id = bacon.id })
    vim.uv.fs_utime(d .. "/Cargo.toml", 1000000000, 1000000000)
    fire("FocusGained", RR_GROUP)
    H.wait_for(function()
      return s.restarts() > 0
    end, 3000, "restart after the on-disk change")
    H.eq("deps resolving", require("xyno_rust.lsp_status").deps(rb))
  end)
end)

-- --------------------------------------------------------- deps resolving

describe("deps-freshness: the 'deps resolving' status", function()
  local s, status, d, ra, rb
  before_each(function()
    s = install_stubs()
    status = require("xyno_rust.lsp_status")
    status.setup()
    d = crate()
    rb = buf_of(d .. "/src/main.rs")
    ra = fake_client(s, "rust-analyzer", d, { rb })
    fire("LspAttach", LS_GROUP, { client_id = ra.id }, rb)
  end)
  after_each(function()
    status.deps_clear()
    remove_stubs()
  end)
  local function server_status(q)
    ra.handlers["experimental/serverStatus"](nil, { health = "ok", quiescent = q }, { client_id = ra.id }, {})
  end
  local function shown()
    return status.deps(rb) == "deps resolving"
  end

  it("shows from the write, survives a quiescent report that precedes the reload, ends at the next one", function()
    server_status(true)
    status.deps_begin(d)
    H.ok(shown())
    vim.api.nvim_set_current_buf(rb)
    H.match(status.component(), "deps resolving", true)
    server_status(true)
    H.ok(shown(), "no busy phase seen yet")
    server_status(false)
    H.ok(shown())
    server_status(true)
    H.not_ok(shown(), "quiescent after loading")
    H.no_match(status.component(), "deps", true)
  end)

  it("a rust-analyzer already loading when the manifest is saved ends at its quiescence", function()
    server_status(false)
    status.deps_begin(d)
    server_status(true)
    H.not_ok(shown())
  end)

  it("never sticks: rust-analyzer that never goes busy releases it after the 6 s grace", function()
    server_status(true)
    status.deps_begin(d)
    H.wait_for(function()
      return not shown()
    end, 9000, "grace expiry")
  end)

  it("ends on :RustRestart and on the wipe of the manifest buffer", function()
    status.deps_begin(d)
    H.ok(shown())
    require("xyno_rust.rust_restart").restart()
    H.not_ok(shown(), "restart")
    local mb = buf_of(d .. "/Cargo.toml")
    status.deps_begin(d, mb)
    H.ok(shown())
    vim.api.nvim_buf_delete(mb, { force = true })
    H.not_ok(shown(), "wipe")
  end)

  it("only the buffers under the root show it", function()
    status.deps_begin(d)
    H.is_nil(status.deps(buf_of(crate() .. "/src/main.rs")))
  end)
end)

-- ----------------------------------------------------------------- live

describe("deps-freshness: live servers on deps-lab", function()
  local function online()
    local r = vim.system({ "curl", "-sS", "-o", "/dev/null", "--max-time", "6", "https://index.crates.io/config.json" }):wait(10000)
    return r.code == 0
  end

  it("adding rand to Cargo.toml: the stale 'cannot find crate' clippy error is gone within 8 s, status says deps resolving meanwhile", function()
    H.need_rust()
    if vim.fn.executable("bacon-ls") ~= 1 then
      skip("bacon-ls not found")
    end
    if not online() then
      skip("crates.io not reachable (rand must be fetched)")
    end
    local dir, main = H.open_fixture("deps-lab", "src/main.rs")
    local status = require("xyno_rust.lsp_status")
    H.wait_for(function()
      return status.component() == "RA ready | clippy ok"
    end, 180000, "ready; is " .. status.component())
    local function bacon_msgs()
      local t = {}
      for _, dg in ipairs(vim.diagnostic.get(main)) do
        if dg.source == "bacon-ls" then
          t[#t + 1] = dg.message
        end
      end
      return table.concat(t, "\n")
    end
    local lines = vim.api.nvim_buf_get_lines(main, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:find("Ok(())", 1, true) then
        table.insert(lines, i, "    let _r: u8 = rand::random();")
        break
      end
    end
    vim.api.nvim_buf_set_lines(main, 0, -1, false, lines)
    vim.cmd("silent write")
    H.wait_for(function()
      return bacon_msgs():find("rand", 1, true) ~= nil
    end, 90000, "the stale 'cannot find crate rand' error; component " .. status.component())

    local old = H.clients(nil, "bacon_ls")[1]
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/Cargo.toml"))
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'rand = "0.9"' })
    vim.cmd("silent write")
    local t0 = vim.uv.now()
    vim.cmd.buffer(main)
    H.eq("deps resolving", status.deps(main), "shown right after the write")
    H.match(status.component(), "deps resolving", true)
    H.wait_for(function()
      local c = H.clients(nil, "bacon_ls")[1]
      return c and c.id ~= old.id
    end, 8000, "bacon-ls restarted by the Cargo.toml save")
    H.wait_for(function()
      return bacon_msgs():find("cannot find module or crate `rand`", 1, true) == nil
    end, 8000, "the stale error gone")
    H.ok(vim.uv.now() - t0 <= 8000, "within 8 s")
    H.wait_for(function()
      return status.deps(main) == nil
    end, 120000, "deps resolving ends with rust-analyzer's quiescence; " .. status.component())
  end)
end)
