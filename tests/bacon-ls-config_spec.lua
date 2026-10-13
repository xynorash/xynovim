-- bacon-ls (clippy tier) configuration: lua/plugins/bacon-ls.lua,
-- lua/config/rust_restart.lua, lua/config/rust_context.lua.
-- Needs rust-analyzer and cargo (skipped with a message otherwise); the
-- bacon-ls binary is Mason's, from the real XDG_DATA_HOME.
local H = require("xynotest.helpers")

local mason_bin = vim.fn.stdpath("data") .. "/mason/bin"

--- The plugin spec's bacon_ls server table, evaluated fresh (own upvalues).
local function plugin_server()
  return dofile(H.repo .. "/lua/plugins/bacon-ls.lua").opts.servers.bacon_ls
end

local function exists(p)
  return vim.uv.fs_stat(p) ~= nil
end

local function bacon_diags(buf)
  return H.diagnostics("bacon", buf)
end

--- Open <fixture>/<rel> and wait for the bacon_ls client. Returns dir, buf, client.
local function open_bacon(name, rel)
  local dir, buf = H.open_fixture(name, rel)
  return dir, buf, H.wait_lsp("bacon_ls", buf, 60000)
end

local function has_arg(args, a)
  return vim.tbl_contains(args, a)
end

describe("bacon-ls config", function()
  before_each(function()
    H.need_rust()
    if vim.fn.executable(mason_bin .. "/bacon-ls") ~= 1 then
      skip("Mason's bacon-ls is not installed")
    end
  end)
  after_each(function()
    H.cleanup()
  end)

  -- 1
  it("declares the bacon_ls server with the cargo/clippy settings", function()
    local srv = plugin_server()
    local want = {
      backend = "cargo",
      cargo = {
        command = "clippy",
        extraArgs = { "--workspace", "--all-features", "--no-deps" },
        updateOnInsert = true,
        updateOnInsertDebounceMillis = 500,
        checkOnSave = false,
      },
    }
    H.eq(want, srv.init_options)
    H.eq(want, srv.settings.bacon_ls)
    -- and the merged lsp config nvim really uses (loaded with the first Rust buffer)
    open_bacon("basic", "src/lib.rs")
    local cfg = vim.lsp.config.bacon_ls
    H.eq(want, cfg.init_options)
    H.eq(want, cfg.settings.bacon_ls)
    H.eq(nil, srv.cmd, "no cmd override in the plugin spec")
  end)

  -- 2 + 3
  it("sends updateOnInsert in init_options and runs Mason's bacon-ls >= 0.31.0", function()
    local _, _, c = open_bacon("basic", "src/lib.rs")
    H.eq(true, c.config.init_options.cargo.updateOnInsert)
    -- advertised sync kind (TextDocumentSyncKind.Full = 1)
    local sync = c.server_capabilities.textDocumentSync
    local change = type(sync) == "table" and sync.change or sync
    H.eq(1, change, "Full didChange sync advertised")
    -- the binary: resolved through $PATH to Mason's, nothing under ~/.cargo
    local bin = vim.fn.exepath(c.config.cmd[1])
    H.eq(vim.uv.fs_realpath(mason_bin .. "/bacon-ls"), vim.uv.fs_realpath(bin))
    H.no_match(table.concat(c.config.cmd, " "), ".cargo", true)
    local v = vim.system({ mason_bin .. "/bacon-ls", "--version" }, { text = true }):wait(10000).stdout
    local maj, min = v:match("(%d+)%.(%d+)")
    H.ok(maj and (tonumber(maj) > 0 or tonumber(min) >= 31), "bacon-ls >= 0.31.0, got " .. vim.trim(v))
  end)

  -- 4
  it("roots a workspace member at the outermost [workspace] and keeps ONE client", function()
    local dir = H.fixture("workspace")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local b1 = H.open(dir .. "/core/src/lib.rs")
    local c = H.wait_lsp("bacon_ls", b1, 60000)
    H.eq(vim.uv.fs_realpath(dir), vim.uv.fs_realpath(c.config.root_dir))
    local b2 = H.open(dir .. "/app/src/main.rs")
    H.wait_for(function()
      return H.clients(b2, "bacon_ls")[1]
    end, 30000, "bacon_ls on the second member")
    vim.wait(1500)
    -- (only this workspace's clients: one from an earlier test may still be stopping)
    local all = vim.tbl_filter(function(cl)
      return cl.config.root_dir and vim.uv.fs_realpath(cl.config.root_dir) == vim.uv.fs_realpath(dir)
    end, vim.lsp.get_clients({ name = "bacon_ls" }))
    H.eq(1, #all, "exactly one bacon_ls client")
    H.eq(c.id, all[1].id)
    H.eq(c.id, H.clients(b2, "bacon_ls")[1].id)
    H.eq(vim.uv.fs_realpath(dir), vim.uv.fs_realpath(all[1].config.root_dir))
  end)

  -- 5
  it("roots a plain crate at the crate dir; empty names and loose .rs files get none", function()
    local srv = plugin_server()
    local function root_of(buf)
      local got = "none"
      srv.root_dir(buf, function(r)
        got = r
      end)
      return got
    end
    local dir = H.fixture("basic")
    local b = vim.fn.bufadd(dir .. "/src/lib.rs")
    H.eq(dir, root_of(b))
    local empty = vim.api.nvim_create_buf(true, false)
    H.eq("none", root_of(empty), "empty buffer name")
    local solo_dir = H.tmpdir()
    vim.fn.writefile({ "fn main() {}" }, solo_dir .. "/solo.rs")
    H.eq("none", root_of(vim.fn.bufadd(solo_dir .. "/solo.rs")), "no Cargo.toml above")
  end)

  it("without cargo on PATH no client is started and one WARN says why (not a bare os error 2)", function()
    local srv = plugin_server()
    local dir = H.fixture("basic")
    local b = vim.fn.bufadd(dir .. "/src/lib.rs")
    local real = vim.fn.executable
    rawset(vim.fn, "executable", function(name)
      if name == "cargo" then
        return 0
      end
      return real(name)
    end)
    local cap = H.capture_notify()
    local got = "none"
    local ok, err = pcall(function()
      srv.root_dir(b, function(r)
        got = r
      end)
      srv.root_dir(b, function(r)
        got = r
      end)
    end)
    rawset(vim.fn, "executable", nil)
    cap.restore()
    H.ok(ok, err)
    H.eq("none", got)
    H.eq(1, #cap.list, "told once")
    H.eq(vim.log.levels.WARN, cap.list[1].level)
    H.match(cap.list[1].msg, "cargo is not on PATH", true)
    H.eq(dir, (function()
      local r
      srv.root_dir(b, function(x)
        r = x
      end)
      return r
    end)(), "with cargo again it roots normally")
  end)

  it("a standalone .rs file attaches rust-analyzer but not bacon_ls", function()
    local _, buf = H.open_fixture("standalone.rs")
    H.wait_lsp("rust-analyzer", buf)
    vim.wait(2000)
    H.eq(0, #H.clients(buf, "bacon_ls"))
    H.eq(0, #vim.lsp.get_clients({ name = "bacon_ls" }))
  end)

  -- 6
  for _, seg in ipairs({ "/.cargo/registry/", "/.cargo/git/", "/.rustup/" }) do
    it("starts no bacon_ls under " .. seg, function()
      local base = H.tmpdir()
      local dest = base .. seg .. "basic"
      vim.fn.mkdir(vim.fs.dirname(dest), "p")
      H.eq(0, vim.system({ "cp", "-a", H.fixtures .. "/basic", dest }):wait(10000).code)
      vim.cmd.cd(vim.fn.fnameescape(dest))
      local buf = H.open(dest .. "/src/lib.rs")
      H.wait_lsp("rust-analyzer", buf)
      vim.wait(3000)
      H.eq(0, #vim.lsp.get_clients({ name = "bacon_ls" }))
      H.not_ok(exists(dest .. "/target/bacon-ls-live"), "no shadow written")
      H.not_ok(exists(dest .. "/target/debug"), "no clippy build output written")
    end)
  end

  -- 7 + 12 (shadow location)
  it("writes the shadow under the workspace root only, never into a member crate", function()
    local dir = H.fixture("workspace")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/app/src/main.rs")
    H.wait_lsp("bacon_ls", buf, 60000)
    -- the shadow is built by the first edit-triggered run ("first run only")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "// edit" })
    H.wait_for(function()
      return exists(dir .. "/target/bacon-ls-live")
    end, 60000, "shadow workspace under <root>/target/bacon-ls-live")
    H.not_ok(exists(dir .. "/app/target"), "no target/ in app")
    H.not_ok(exists(dir .. "/core/target"), "no target/ in core")
  end)

  -- 8
  describe("before_init", function()
    local function run_before_init(srv, root)
      local params, config = { initializationOptions = {} }, { root_dir = root }
      srv.before_init(params, config)
      return params, config
    end

    it("uses the stored :RustContext for the root without mutating the shared settings", function()
      local rc = require("config.rust_context")
      local srv = plugin_server()
      local dir = H.fixture("basic")
      local cap = H.capture_notify()
      rc.apply(dir, { all = false, no_default = true, features = { "csr", "ssr" }, target = "wasm32-unknown-unknown" })
      cap.restore()
      local want = { "--workspace", "--no-default-features", "--features", "csr,ssr", "--target", "wasm32-unknown-unknown", "--no-deps" }
      local params, config = run_before_init(srv, dir)
      H.eq(want, params.initializationOptions.cargo.extraArgs)
      H.eq(want, config.settings.bacon_ls.cargo.extraArgs)
      -- the rest of the settings are carried over
      H.eq("clippy", params.initializationOptions.cargo.command)
      H.eq(true, params.initializationOptions.cargo.updateOnInsert)
      -- the shared upvalue is a deep copy source, not mutated
      H.eq({ "--workspace", "--all-features", "--no-deps" }, srv.init_options.cargo.extraArgs)
      H.eq({ "--workspace", "--all-features", "--no-deps" }, srv.settings.bacon_ls.cargo.extraArgs)
      H.ok(params.initializationOptions ~= srv.init_options)
      -- a context stored for ANOTHER root does not leak in
      local other = H.fixture("broken")
      local p2 = run_before_init(srv, other)
      H.eq({ "--workspace", "--all-features", "--no-deps" }, p2.initializationOptions.cargo.extraArgs)
    end)

    it("rebuilds from the defaults when no context is stored (also after a reset)", function()
      local rc = require("config.rust_context")
      local srv = plugin_server()
      local dir = H.fixture("basic")
      local cap = H.capture_notify()
      rc.apply(dir, { all = false, features = { "x" } })
      rc.apply(dir, nil) -- :RustContext reset
      cap.restore()
      H.is_nil(rc.get(dir))
      -- a config.settings left over from the previous client start
      local params, config = { initializationOptions = {} }, {
        root_dir = dir,
        settings = { bacon_ls = { cargo = { extraArgs = { "--features", "x" } } } },
      }
      srv.before_init(params, config)
      H.eq({ "--workspace", "--all-features", "--no-deps" }, params.initializationOptions.cargo.extraArgs)
      H.eq({ "--workspace", "--all-features", "--no-deps" }, config.settings.bacon_ls.cargo.extraArgs)
    end)
  end)

  -- 9
  it("restarts bacon-ls through rust_restart.on_exit after it was killed", function()
    -- earlier tests' forced client stops count as exits in the module's
    -- 3-per-minute budget: start from a fresh module (the hook requires it per call)
    package.loaded["config.rust_restart"] = nil
    local _, buf, c = open_bacon("basic", "src/lib.rs")
    H.is_nil(vim.b[buf].xynovim_stopped)
    H.eq("function", type(c.config.on_exit))
    local cap = H.capture_notify()
    -- our own child only: the bacon-ls process of THIS nvim
    local kids = vim.api.nvim_get_proc_children(vim.uv.os_getpid())
    local pid
    for _, p in ipairs(kids) do
      -- the newest one is this test's client (older ones may still be exiting)
      if (vim.api.nvim_get_proc(p) or {}).name == "bacon-ls" and (not pid or p > pid) then
        pid = p
      end
    end
    H.ok(pid, "bacon-ls child process")
    vim.uv.kill(pid, "sigkill")
    H.wait_for(function()
      for _, n in ipairs(cap.list) do
        if n.msg:find("bacon_ls exited", 1, true) then
          return true
        end
      end
    end, 10000, "the restart notice")
    H.eq(true, (vim.b[buf].xynovim_stopped or {}).bacon_ls, "marked stopped on the buffer")
    local new = H.wait_for(function()
      local n = H.clients(buf, "bacon_ls")[1]
      return n and n.id ~= c.id and n
    end, 30000, "a new bacon_ls client")
    H.ok(new)
  end)

  -- 10
  it("delivers clippy diagnostics for the basic crate", function()
    local _, buf = open_bacon("basic", "src/lib.rs")
    local d = H.wait_for(function()
      return bacon_diags(buf)[1]
    end, 120000, "a bacon_ls diagnostic")
    H.eq("needless_return", (tostring(d.code or d.message):match("needless_return")), vim.inspect(d))
    H.match(d.source, "bacon", true)
  end)

  it("shows the type error from rust-analyzer first and clippy's tier later (broken crate)", function()
    local _, buf = open_bacon("broken", "src/main.rs")
    local ra = H.wait_for(function()
      return H.diagnostics("rust-analyzer", buf)[1]
    end, 60000, "rust-analyzer diagnostic")
    H.eq("E0308", ra.code)
    local b = H.wait_for(function()
      return bacon_diags(buf)[1]
    end, 120000, "a bacon_ls diagnostic")
    H.match(b.message, "mismatched types", true)
  end)

  -- 11 + 12
  it("reports an edit within 5 s, with one run pipeline and nothing started by :w", function()
    local dir, buf, c = open_bacon("basic", "src/lib.rs")
    H.wait_for(function()
      return bacon_diags(buf)[1]
    end, 120000, "the initial diagnostic")

    local begins, active, max_active = 0, 0, 0
    local ac = vim.api.nvim_create_autocmd("LspProgress", {
      callback = function(ev)
        if ev.data.client_id ~= c.id then
          return
        end
        local kind = ev.data.params.value and ev.data.params.value.kind
        if kind == "begin" then
          begins = begins + 1
          active = active + 1
          max_active = math.max(max_active, active)
        elseif kind == "end" then
          active = math.max(0, active - 1)
        end
      end,
    })
    table.insert(H._restore, function()
      pcall(vim.api.nvim_del_autocmd, ac)
    end)
    vim.o.autowrite = false

    local function lint(d)
      return (tostring(d.code or "") .. d.message):find("len_zero", 1, true)
    end
    -- a new clippy finding, edited in without saving
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.list_extend(lines, { "", "pub fn empty(v: &[i32]) -> bool {", "    v.len() == 0", "}" })
    local t0 = vim.uv.hrtime()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    H.wait_for(function()
      return vim.iter(bacon_diags(buf)):any(lint)
    end, 5000, "len_zero diagnostic within 5 s of the edit")
    local secs = (vim.uv.hrtime() - t0) / 1e9
    io.stdout:write(("info: edit-to-diagnostic %.2f s\n"):format(secs))
    H.ok(secs < 5)
    H.ok(exists(dir .. "/target/bacon-ls-live"), "shadow workspace under <root>/target/bacon-ls-live")
    H.ok(max_active <= 1, "runs did not overlap, saw " .. max_active)

    -- let the run finish, then save: checkOnSave = false => no new run
    H.wait_for(function()
      return active == 0
    end, 20000, "run to end")
    vim.wait(1500)
    local before = begins
    vim.cmd("silent write")
    vim.wait(3000)
    H.eq(before, begins, "a :w started no progress/run")
    H.ok(vim.iter(bacon_diags(buf)):any(lint), "diagnostic still there after the save")
  end)

  -- 13
  it("stops the client of a deleted workspace on FocusGained (rust_restart.sweep)", function()
    local dir, buf, c = open_bacon("basic", "src/lib.rs")
    vim.cmd.cd("/")
    H.eq(0, vim.fn.delete(dir, "rf"))
    vim.cmd("doautocmd FocusGained")
    H.wait_for(function()
      return #vim.lsp.get_clients({ name = "bacon_ls" }) == 0
    end, 10000, "the sweep to stop the client")
    H.ok(c:is_stopped())
    H.ok(vim.api.nvim_buf_is_valid(buf))
  end)

  -- 14
  it("restarts with matching args when :RustContext changes the features", function()
    local rc = require("config.rust_context")
    local dir = H.fixture("workspace")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/app/src/main.rs")
    local c = H.wait_lsp("bacon_ls", buf, 60000)
    H.ok(has_arg(c.config.settings.bacon_ls.cargo.extraArgs, "--all-features"))
    local cap = H.capture_notify()
    rc.apply(rc.root(dir .. "/x"), { all = false, no_default = true, features = { "ssr" } })
    local new = H.wait_for(function()
      -- (this root's client: a supervision restart of an earlier test's buffer may be running too)
      for _, n in ipairs(vim.lsp.get_clients({ name = "bacon_ls" })) do
        if n.id ~= c.id and n.initialized and n.config.root_dir == c.config.root_dir then
          return n
        end
      end
    end, 30000, "restarted bacon_ls")
    local args = new.config.settings.bacon_ls.cargo.extraArgs
    H.eq({ "--workspace", "--no-default-features", "--features", "ssr", "--no-deps" }, args)
    H.not_ok(has_arg(args, "--all-features"))
    H.has(cap.list[1].msg, "features: ssr")
    -- the stored choice is also what a later before_init would use
    H.eq({ all = false, no_default = true, features = { "ssr" } }, rc.get(rc.root(dir .. "/x")))
    -- one client for this root (an earlier test's open buffer may have got its own after a supervision restart)
    H.eq(1, #vim.tbl_filter(function(n)
      return n.config.root_dir == c.config.root_dir
    end, vim.lsp.get_clients({ name = "bacon_ls" })))
  end)

  -- 15
  it("has the Mason tools the README names", function()
    for _, t in ipairs({
      "bacon-ls", "codelldb", "taplo", "wgsl-analyzer", "stylua", "shfmt", "marksman", "markdownlint-cli2",
      "markdown-toc", "yaml-language-server", "vscode-json-language-server", "lua-language-server", "tree-sitter",
    }) do
      H.ok(exists(mason_bin .. "/" .. t), t .. " missing from " .. mason_bin)
    end
    local v = vim.system({ mason_bin .. "/bacon-ls", "--version" }, { text = true }):wait(10000)
    H.match(v.stdout, "^0%.3[1-9]")
  end)
end)
