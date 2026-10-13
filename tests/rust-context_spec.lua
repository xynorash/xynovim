-- config.rust_context (:RustContext, per-workspace cargo features/target) and
-- its two consumers, plugins/rustaceanvim.lua (server.settings) and
-- plugins/bacon-ls.lua (before_init). The pure part and the picker/command
-- part run without servers; the "live" part needs rust-analyzer + cargo
-- (bacon-ls assertions are made when Mason's bacon-ls attaches).
local H = require("xynotest.helpers")

local rc = require("config.rust_context")
local state_file = vim.fn.stdpath("state") .. "/rust-context.json"

local function write_text(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function read_text(path)
  local f = io.open(path)
  if not f then
    return nil
  end
  local t = f:read("*a")
  f:close()
  return t
end

local function state()
  local t = read_text(state_file)
  return t and vim.json.decode(t) or nil
end

--- Cleanups of stubs installed by a test, run (reverse order) by after_each.
local undo = {}
local function on_undo(fn)
  undo[#undo + 1] = fn
end

local function notes()
  local cap = H.capture_notify()
  on_undo(cap.restore)
  return cap
end

--- Make a named scratch buffer current (M.root() with no argument reads its name).
local function buf_named(path)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_name(b, path)
  return b
end

--- A crate directory with the given Cargo.toml text (+ an empty src/lib.rs).
local function crate(toml)
  local dir = H.tmpdir()
  write_text(dir .. "/Cargo.toml", toml)
  write_text(dir .. "/src/lib.rs", "")
  return dir
end

--- Replace vim.system for given argv[1] values; others pass through.
--- handlers[exe](cmd, opts) returns a SystemCompleted-like table; every call
--- is recorded in the returned list as { cmd, opts, wait }.
local function stub_system(handlers)
  local orig = vim.system
  local calls = {}
  vim.system = function(cmd, opts, ...)
    local h = handlers[cmd[1]]
    if not h then
      return orig(cmd, opts, ...)
    end
    local rec = { cmd = cmd, opts = opts }
    calls[#calls + 1] = rec
    return {
      wait = function(_, ms)
        rec.wait = ms
        return h(cmd, opts)
      end,
    }
  end
  on_undo(function()
    vim.system = orig
  end)
  return calls
end

--- Replace Snacks.picker; returns a table whose .opts holds the options of the last call.
local function stub_picker()
  local cap = {}
  local orig = Snacks.picker
  -- a callable table: snacks reads fields (picker.config, ...) of the original
  Snacks.picker = setmetatable({}, {
    __call = function(_, opts)
      cap.opts = opts
    end,
    __index = orig,
  })
  on_undo(function()
    Snacks.picker = orig
  end)
  return cap
end

--- A picker object as confirm() receives it, "selecting" the items whose text is in `texts`.
local function fake_picker(cap, texts)
  local sel = {}
  for _, it in ipairs(cap.opts.items) do
    if vim.tbl_contains(texts, it.text) then
      sel[#sel + 1] = it
    end
  end
  local p = { closed = false }
  function p:selected()
    return sel
  end
  function p:close()
    self.closed = true
  end
  return p
end

--- Replace vim.ui.select; .call = { items, opts, cb } of the last call.
local function stub_select()
  local cap = {}
  local orig = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    cap.call = { items = items, opts = opts, cb = cb }
  end
  on_undo(function()
    vim.ui.select = orig
  end)
  return cap
end

--- Replace vim.cmd by a recorder: calls are logged ("RustLsp reloadWorkspace"
--- for vim.cmd.RustLsp(...), the string for vim.cmd("...")) and passed on,
--- except RustLsp which is only logged.
local function record_cmd()
  local log = {}
  local orig = vim.cmd
  vim.cmd = setmetatable({
    RustLsp = function(...)
      log[#log + 1] = "RustLsp " .. table.concat({ ... }, " ")
    end,
  }, {
    __call = function(_, ...)
      local a = ...
      if type(a) == "string" then
        log[#log + 1] = a
      end
      return orig(...)
    end,
    __index = orig,
  })
  on_undo(function()
    vim.cmd = orig
  end)
  return log
end

local function stop_all_clients()
  for _, c in ipairs(vim.lsp.get_clients()) do
    c:stop(true)
  end
  vim.wait(5000, function()
    return #vim.lsp.get_clients() == 0
  end, 20)
end

local function reset_world()
  for i = #undo, 1, -1 do
    pcall(undo[i])
  end
  undo = {}
  stop_all_clients()
  pcall(vim.cmd, "silent! %bwipeout!")
  vim.fn.delete(state_file)
end

describe("rust_context", function()
  before_each(function()
    vim.fn.delete(state_file)
  end)
  after_each(reset_world)

  -- ------------------------------------------------------------------ root

  describe("root", function()
    it("walks up to the outermost Cargo.toml with [workspace], from a member crate", function()
      local ws = H.fixture("workspace")
      H.eq(ws, rc.root(ws .. "/app/src/main.rs"))
      H.eq(ws, rc.root(ws .. "/core/src/lib.rs"))
      -- nested workspaces: the outermost wins, not the nearest [workspace]
      local outer = crate('[workspace]\nmembers = ["inner"]\n')
      write_text(outer .. "/inner/Cargo.toml", '[package]\nname = "inner"\n[workspace]\n')
      write_text(outer .. "/inner/src/lib.rs", "")
      H.eq(outer, rc.root(outer .. "/inner/src/lib.rs"))
      -- a plain package above a workspace is not the root; [workspace.xxx] tables count
      local plain = crate('[package]\nname = "plain"\n')
      write_text(plain .. "/mid/Cargo.toml", "[workspace.package]\nedition = '2021'\n")
      write_text(plain .. "/mid/leaf/Cargo.toml", '[package]\nname = "leaf"\n')
      H.eq(plain .. "/mid", rc.root(plain .. "/mid/leaf/src/lib.rs"))
    end)

    it("falls back to the nearest Cargo.toml for a plain crate", function()
      local basic = H.fixture("basic")
      H.eq(basic, rc.root(basic .. "/src/lib.rs"))
      H.eq(basic, rc.root(basic .. "/tests/it.rs"))
      -- a nested plain crate inside a plain crate: the nearest one
      local outer = crate('[package]\nname = "o"\n')
      write_text(outer .. "/in/Cargo.toml", '[package]\nname = "i"\n')
      H.eq(outer .. "/in", rc.root(outer .. "/in/src/lib.rs"))
    end)

    it("defaults to the current buffer's name", function()
      local basic = H.fixture("basic")
      buf_named(basic .. "/src/main.rs")
      H.eq(basic, rc.root())
      local ws = H.fixture("workspace")
      buf_named(ws .. "/app/src/main.rs")
      H.eq(ws, rc.root())
    end)

    it("returns nil for a path outside any crate", function()
      local dir = H.tmpdir()
      H.is_nil(rc.root(dir .. "/x.rs"))
      buf_named(dir .. "/notes.txt")
      H.is_nil(rc.root())
    end)
  end)

  -- ----------------------------------------------------------------- state

  describe("state file", function()
    it("holds { [root] = ctx } under stdpath('state')", function()
      H.eq(vim.fn.stdpath("state") .. "/rust-context.json", state_file)
      notes()
      local ctx = { all = false, no_default = false, features = { "ssr" }, target = "t" }
      rc.apply("/r/one", ctx)
      H.eq({ ["/r/one"] = ctx }, state())
    end)

    it("reads as empty when the file is missing, invalid or not a table", function()
      local root = "/r/one"
      H.is_nil(read_text(state_file), "precondition: no state file")
      H.is_nil(rc.get(root))
      for _, junk in ipairs({ "{not json", "", "42", '"str"', "null", "true" }) do
        write_text(state_file, junk)
        local ok, got = pcall(rc.get, root)
        H.ok(ok, ("get raised on %q: %s"):format(junk, tostring(got)))
        H.is_nil(got, ("get on %q"):format(junk))
      end
      -- a JSON array is a table but holds no root
      write_text(state_file, "[1,2]")
      H.is_nil(rc.get(root))
    end)

    it("does not raise on a corrupt file and overwrites it on the next apply", function()
      notes()
      write_text(state_file, '{"/r/one": {"all": tru')
      H.ok(pcall(rc.get, "/r/one"))
      local ok, err = pcall(rc.apply, "/r/one", { all = true, features = {} })
      H.ok(ok, tostring(err))
      H.eq({ all = true, features = {} }, rc.get("/r/one"))
      H.eq({ ["/r/one"] = { all = true, features = {} } }, state())
    end)

    it("write_all creates the missing parent directory", function()
      local dir = H.tmpdir() .. "/no/such/state"
      local orig_stdpath = vim.fn.stdpath
      local saved = package.loaded["config.rust_context"]
      vim.fn.stdpath = function(what)
        if what == "state" then
          return dir
        end
        return orig_stdpath(what)
      end
      package.loaded["config.rust_context"] = nil
      local ok, err = pcall(function()
        local fresh = require("config.rust_context")
        notes()
        H.eq(0, vim.fn.isdirectory(dir))
        fresh.apply("/r/x", { all = true, features = {} })
        H.eq(1, vim.fn.isdirectory(dir))
        H.eq({ all = true, features = {} }, fresh.get("/r/x"))
      end)
      vim.fn.stdpath = orig_stdpath
      package.loaded["config.rust_context"] = saved
      H.ok(ok, tostring(err))
    end)

    it("get(nil) is nil; get(root) is the stored ctx or nil", function()
      notes()
      H.is_nil(rc.get(nil))
      H.is_nil(rc.get("/r/one"))
      local ctx = { all = false, no_default = true, features = { "a", "b" }, target = "x" }
      rc.apply("/r/one", ctx)
      H.eq(ctx, rc.get("/r/one"))
      H.is_nil(rc.get("/r/two"))
      H.is_nil(rc.get(nil), "get(nil) even with a populated file")
    end)

    it("keeps independent entries per workspace root", function()
      notes()
      local a = { all = false, features = { "ssr" } }
      local b = { all = false, features = { "csr" }, target = "wasm32-unknown-unknown" }
      rc.apply("/r/a", a)
      rc.apply("/r/b", b)
      H.eq(a, rc.get("/r/a"))
      H.eq(b, rc.get("/r/b"))
      -- changing one leaves the other, forgetting one leaves the other
      rc.apply("/r/a", { all = true, features = {} })
      H.eq(b, rc.get("/r/b"))
      rc.apply("/r/b", nil)
      H.eq({ all = true, features = {} }, rc.get("/r/a"))
      H.is_nil(rc.get("/r/b"))
      H.eq({ ["/r/a"] = { all = true, features = {} } }, state())
    end)
  end)

  -- ------------------------------------------------- pure flag/arg builders

  describe("ra_cargo", function()
    it("is nil without a context", function()
      H.is_nil(rc.ra_cargo(nil))
    end)

    it("maps all=true to allFeatures with an empty feature list", function()
      H.eq({ allFeatures = true, noDefaultFeatures = false, features = {} }, rc.ra_cargo({ all = true }))
      -- the list is ignored when all is on
      H.eq({}, rc.ra_cargo({ all = true, features = { "a" } }).features)
    end)

    it("maps an explicit feature list and passes the target through", function()
      H.eq(
        { allFeatures = false, noDefaultFeatures = false, features = { "a", "b" } },
        rc.ra_cargo({ features = { "a", "b" } })
      )
      H.eq(
        { allFeatures = false, noDefaultFeatures = true, features = {}, target = "wasm32-unknown-unknown" },
        rc.ra_cargo({ no_default = true, target = "wasm32-unknown-unknown" })
      )
      H.eq("t", rc.ra_cargo({ all = true, target = "t" }).target)
    end)
  end)

  describe("cargo_flags", function()
    it("defaults to --all-features", function()
      H.eq({ "--all-features" }, rc.cargo_flags(nil))
    end)

    it("handles all, target, feature lists and no-default", function()
      H.eq({ "--all-features", "--target", "t" }, rc.cargo_flags({ all = true, target = "t" }))
      H.eq({ "--features", "ssr,csr" }, rc.cargo_flags({ features = { "ssr", "csr" } }))
      H.eq(
        { "--no-default-features", "--features", "a" },
        rc.cargo_flags({ no_default = true, features = { "a" } }),
        "no-default comes first"
      )
      H.eq({ "--no-default-features" }, rc.cargo_flags({ no_default = true, features = {} }))
      H.eq({ "--features", "a", "--target", "t" }, rc.cargo_flags({ features = { "a" }, target = "t" }))
      H.eq({ "--all-features" }, rc.cargo_flags({ all = true, no_default = true }), "all wins over no-default")
    end)

    it("adds nothing for an empty feature list", function()
      H.eq({}, rc.cargo_flags({ features = {} }))
      H.eq({}, rc.cargo_flags({ all = false }))
      H.eq({ "--target", "t" }, rc.cargo_flags({ features = {}, target = "t" }))
    end)
  end)

  describe("bacon_args", function()
    it("defaults to the workspace, all features, no deps", function()
      H.eq({ "--workspace", "--all-features", "--no-deps" }, rc.bacon_args(nil))
    end)

    it("is --workspace, the context flags, --no-deps in that order", function()
      local ctx = { no_default = true, features = { "ssr" }, target = "t" }
      H.eq(
        vim.list_extend(vim.list_extend({ "--workspace" }, rc.cargo_flags(ctx)), { "--no-deps" }),
        rc.bacon_args(ctx)
      )
      H.eq(
        { "--workspace", "--no-default-features", "--features", "ssr", "--target", "t", "--no-deps" },
        rc.bacon_args(ctx)
      )
      -- calling twice gives the same answer (no shared table mutated)
      H.eq({ "--workspace", "--all-features", "--no-deps" }, rc.bacon_args(nil))
      H.eq({ "--workspace", "--all-features", "--no-deps" }, rc.bacon_args(nil))
    end)
  end)

  describe("describe", function()
    it("names the default context", function()
      H.eq("all features, host target", rc.describe(nil))
      H.eq("all features, host target", rc.describe({ all = true }))
    end)

    it("shows target and feature lists", function()
      H.eq("all features | target: x", rc.describe({ all = true, target = "x" }))
      H.eq("features: ssr,csr | target: host", rc.describe({ features = { "ssr", "csr" } }))
      H.eq("features: (none) | target: host", rc.describe({ features = {} }))
      H.eq("features: (none) | target: host", rc.describe({ all = false }))
    end)

    it("mentions no default features", function()
      H.eq("features: a | no default | target: host", rc.describe({ features = { "a" }, no_default = true }))
      H.eq("features: (none) | no default | target: t", rc.describe({ no_default = true, target = "t" }))
    end)
  end)

  -- ------------------------------------------------------ apply, no servers

  describe("apply without servers", function()
    it("writes the state, schedules RustLsp reloadWorkspace and notifies", function()
      local cap = notes()
      local log = record_cmd()
      local ctx = { all = false, no_default = false, features = { "ssr", "csr" }, target = "t" }
      rc.apply("/r/one", ctx)
      H.eq({ ["/r/one"] = ctx }, state())
      H.eq({ { msg = "Rust context: features: ssr,csr | target: t", level = nil } }, cap.list)
      H.wait_for(function()
        return vim.tbl_contains(log, "RustLsp reloadWorkspace")
      end, 2000, "RustLsp reloadWorkspace")
      H.not_ok(vim.tbl_contains(log, "lsp restart bacon_ls"), "no bacon_ls client: no restart")
    end)

    it("apply(root, nil) forgets the choice and resets to all features / host target", function()
      local cap = notes()
      rc.apply("/r/one", { all = false, features = { "ssr" }, target = "t" })
      rc.apply("/r/two", { all = true, features = {} })
      H.ok(rc.get("/r/one"))
      cap.list = {}
      rc.apply("/r/one", nil)
      H.is_nil(rc.get("/r/one"))
      H.is_nil(state()["/r/one"], "entry removed from the file")
      H.eq({ all = true, features = {} }, rc.get("/r/two"), "other roots stay")
      H.eq("Rust context: all features, host target", cap.list[1].msg)
    end)
  end)

  -- ---------------------------------------------------------------- command

  describe(":RustContext", function()
    local function cmd()
      return vim.api.nvim_get_commands({}).RustContext
    end

    it("takes an optional argument and completes show/reset", function()
      local c = H.ok(cmd(), "command not defined")
      H.eq("?", c.nargs)
      H.eq({ "show", "reset" }, c.complete())
    end)

    it("show notifies the stored context, or the default", function()
      local ws = H.fixture("workspace")
      buf_named(ws .. "/app/src/main.rs")
      local cap = notes()
      vim.cmd("RustContext show")
      H.eq("Rust context: all features, host target", cap.list[#cap.list].msg)
      rc.apply(ws, { all = false, features = { "csr" }, target = "t" })
      vim.cmd("RustContext show")
      H.eq("Rust context: features: csr | target: t", cap.list[#cap.list].msg)
      -- outside a crate: the default
      buf_named(H.tmpdir() .. "/notes.txt")
      vim.cmd("RustContext show")
      H.eq("Rust context: all features, host target", cap.list[#cap.list].msg)
    end)

    it("reset calls M.reset, any other argument opens the picker", function()
      local calls = {}
      local orig_reset, orig_pick = rc.reset, rc.pick
      rc.reset = function()
        calls[#calls + 1] = "reset"
      end
      rc.pick = function()
        calls[#calls + 1] = "pick"
      end
      on_undo(function()
        rc.reset, rc.pick = orig_reset, orig_pick
      end)
      vim.cmd("RustContext reset")
      H.eq({ "reset" }, calls)
      vim.cmd("RustContext")
      vim.cmd("RustContext features")
      vim.cmd("RustContext resett")
      H.eq({ "reset", "pick", "pick", "pick" }, calls)
    end)

    it("reset in a crate forgets the stored choice of that workspace only", function()
      local ws = H.fixture("workspace")
      buf_named(ws .. "/app/src/main.rs")
      notes()
      rc.apply(ws, { all = false, features = { "csr" } })
      rc.apply("/r/other", { all = false, features = { "x" } })
      vim.cmd("RustContext reset")
      H.is_nil(rc.get(ws))
      H.eq({ all = false, features = { "x" } }, rc.get("/r/other"))
    end)

    it("reset outside a crate warns instead of doing nothing", function()
      buf_named(H.tmpdir() .. "/notes.txt")
      local cap = notes()
      vim.cmd("RustContext reset")
      H.eq({ { msg = "no Cargo.toml found: nothing to reset", level = vim.log.levels.WARN } }, cap.list)
      H.is_nil(read_text(state_file), "nothing written")
    end)

    it("pick outside a crate warns 'no Cargo.toml found'", function()
      buf_named(H.tmpdir() .. "/notes.txt")
      local cap = notes()
      local picker = stub_picker()
      vim.cmd("RustContext")
      H.eq({ { msg = "no Cargo.toml found", level = vim.log.levels.WARN } }, cap.list)
      H.is_nil(picker.opts, "no picker opened")
    end)
  end)

  -- ----------------------------------------------------------------- picker

  describe("picker", function()
    local function need_cargo()
      if vim.fn.executable("cargo") ~= 1 then
        H.skip_file("cargo not found")
      end
    end

    it("reads `cargo metadata --no-deps` in the root with a 30 s wait", function()
      local ws = H.fixture("workspace")
      buf_named(ws .. "/app/src/main.rs")
      stub_picker()
      local calls = stub_system({
        cargo = function()
          return { code = 0, stdout = '{"packages":[]}' }
        end,
      })
      rc.pick()
      H.eq(1, #calls)
      H.eq({ "cargo", "metadata", "--format-version", "1", "--no-deps" }, calls[1].cmd)
      H.eq(ws, calls[1].opts.cwd)
      H.eq(30000, calls[1].wait)
    end)

    it("notifies an ERROR when cargo metadata fails", function()
      local dir = crate("[package\nname = broken\n")
      buf_named(dir .. "/notes.txt")
      need_cargo()
      local cap = notes()
      local picker = stub_picker()
      rc.pick()
      H.eq(1, #cap.list)
      H.eq(vim.log.levels.ERROR, cap.list[1].level)
      H.match(cap.list[1].msg, "^cargo metadata failed: ")
      H.match(cap.list[1].msg, "Cargo.toml", true, "carries cargo's stderr")
      H.is_nil(picker.opts)
      -- the same through a stubbed failure
      cap.list = {}
      stub_system({
        cargo = function()
          return { code = 101, stderr = "boom" }
        end,
      })
      rc.pick()
      H.eq({ { msg = "cargo metadata failed: boom", level = vim.log.levels.ERROR } }, cap.list)
    end)

    it("lists the special entries, then pkg/feature for a multi-package workspace", function()
      need_cargo()
      local ws = H.fixture("workspace")
      buf_named(ws .. "/app/src/main.rs")
      local picker = stub_picker()
      rc.pick()
      local texts = vim.tbl_map(function(i)
        return i.text
      end, picker.opts.items)
      H.eq({
        "* all features",
        "* default features only (clears the list)",
        "* no-default-features",
        "core-lib/csr",
        "core-lib/ssr",
      }, texts)
      H.eq("Cargo features (<Tab> multi-select) - now: all features, host target", picker.opts.title)
    end)

    it("does not prefix features of a single-package crate and sorts them", function()
      need_cargo()
      local dir = crate('[package]\nname = "solo"\nversion = "0.1.0"\nedition = "2021"\n'
        .. "[features]\ndefault = []\nzeta = []\nalpha = []\nmid = [\"alpha\"]\n")
      buf_named(dir .. "/src/lib.rs")
      local picker = stub_picker()
      rc.pick()
      local texts = vim.tbl_map(function(i)
        return i.text
      end, picker.opts.items)
      H.eq({ "* all features", "* default features only (clears the list)", "* no-default-features", "alpha", "mid", "zeta" }, texts)
    end)

    it("shows the stored context in the title", function()
      need_cargo()
      local ws = H.fixture("workspace")
      buf_named(ws .. "/app/src/main.rs")
      notes()
      rc.apply(ws, { all = false, features = { "csr" }, target = "wasm32-unknown-unknown" })
      local picker = stub_picker()
      rc.pick()
      H.eq(
        "Cargo features (<Tab> multi-select) - now: features: csr | target: wasm32-unknown-unknown",
        picker.opts.title
      )
    end)

    it("confirm lists '(host default)' + installed rustup targets and applies the choice", function()
      need_cargo()
      local ws = H.fixture("workspace")
      buf_named(ws .. "/app/src/main.rs")
      notes()
      local picker = stub_picker()
      local rustup = stub_system({
        rustup = function()
          return { code = 0, stdout = "x86_64-unknown-linux-gnu\nwasm32-unknown-unknown\n" }
        end,
      })
      local select = stub_select()
      rc.pick()
      local p = fake_picker(picker, { "core-lib/ssr", "* no-default-features" })
      picker.opts.confirm(p)
      H.ok(p.closed, "picker closed on confirm")
      H.eq({ "rustup", "target", "list", "--installed" }, rustup[1].cmd)
      H.wait_for(function()
        return select.call
      end, 2000, "the target step")
      H.eq({ "(host default)", "x86_64-unknown-linux-gnu", "wasm32-unknown-unknown" }, select.call.items)
      H.eq("Target (currently host)", select.call.opts.prompt)
      H.is_nil(rc.get(ws), "nothing applied before a target is chosen")
      select.call.cb("wasm32-unknown-unknown")
      H.eq(
        { all = false, no_default = true, features = { "core-lib/ssr" }, target = "wasm32-unknown-unknown" },
        rc.get(ws)
      )
    end)

    it("choosing the host target clears the stored one; cancelling changes nothing", function()
      need_cargo()
      local ws = H.fixture("workspace")
      buf_named(ws .. "/app/src/main.rs")
      notes()
      rc.apply(ws, { all = false, features = { "core-lib/csr" }, target = "wasm32-unknown-unknown" })
      local picker = stub_picker()
      stub_system({
        rustup = function()
          return { code = 0, stdout = "wasm32-unknown-unknown\n" }
        end,
      })
      local select = stub_select()
      rc.pick()
      -- fallback selection: picker:selected({fallback=true}) may hand back the cursor item
      picker.opts.confirm(fake_picker(picker, { "* all features" }))
      H.wait_for(function()
        return select.call
      end, 2000)
      H.eq("Target (currently wasm32-unknown-unknown)", select.call.opts.prompt)
      select.call.cb(nil)
      H.eq({ "core-lib/csr" }, rc.get(ws).features, "cancel keeps the stored context")
      select.call.cb("(host default)")
      local got = rc.get(ws)
      H.eq(true, got.all)
      H.is_nil(got.target, "host clears the target")
    end)

    it("keeps the current target when only the features change (picker preselects it)", function()
      need_cargo()
      local ws = H.fixture("workspace")
      buf_named(ws .. "/app/src/main.rs")
      notes()
      rc.apply(ws, { all = true, features = {}, target = "wasm32-unknown-unknown" })
      local picker = stub_picker()
      stub_system({
        rustup = function()
          return { code = 0, stdout = "wasm32-unknown-unknown\n" }
        end,
      })
      local select = stub_select()
      rc.pick()
      picker.opts.confirm(fake_picker(picker, { "core-lib/csr" }))
      H.wait_for(function()
        return select.call
      end, 2000)
      select.call.cb("wasm32-unknown-unknown")
      H.eq(
        { all = false, no_default = false, features = { "core-lib/csr" }, target = "wasm32-unknown-unknown" },
        rc.get(ws)
      )
    end)
  end)

  -- ----------------------------------------------- plugin glue (no servers)

  describe("plugin glue", function()
    local function plugin_opts(name)
      local plugin = require("lazy.core.config").plugins[name]
      return require("lazy.core.plugin").values(plugin, "opts", false)
    end

    it("rustaceanvim server.settings layers ra_cargo(ctx) over the default settings", function()
      local o = plugin_opts("rustaceanvim").server
      local root = crate('[workspace]\nmembers = ["m"]\n')
      notes()
      local base = o.settings(root, o.default_settings)
      H.eq(o.default_settings["rust-analyzer"].cargo, base["rust-analyzer"].cargo, "no stored context: defaults untouched")
      H.eq(true, base["rust-analyzer"].cargo.targetDir)
      rc.apply(root, { all = false, no_default = false, features = { "csr" } })
      local s = o.settings(root, o.default_settings)
      H.eq(false, s["rust-analyzer"].cargo.allFeatures)
      H.eq({ "csr" }, s["rust-analyzer"].cargo.features)
      H.eq(false, s["rust-analyzer"].cargo.noDefaultFeatures)
      H.eq(true, s["rust-analyzer"].cargo.targetDir, "other cargo defaults kept")
      H.eq(8, s["rust-analyzer"].numThreads, "other defaults kept")
      -- the shared default table is not modified
      H.eq(base["rust-analyzer"].cargo, o.default_settings["rust-analyzer"].cargo)
      -- a member path of the workspace resolves to the same stored context
      write_text(root .. "/m/Cargo.toml", '[package]\nname = "m"\n')
      H.eq(false, o.settings(root .. "/m", o.default_settings)["rust-analyzer"].cargo.allFeatures)
    end)

    it("rustaceanvim server.settings tolerates a missing root", function()
      local o = plugin_opts("rustaceanvim").server
      local ok, s = pcall(o.settings, nil, o.default_settings)
      H.ok(ok, tostring(s))
      H.eq(o.default_settings["rust-analyzer"].cargo, s["rust-analyzer"].cargo)
    end)

    it("bacon_ls before_init rebuilds init options and settings from bacon_args(ctx)", function()
      local def = plugin_opts("nvim-lspconfig").servers.bacon_ls
      local root = crate('[package]\nname = "p"\n')
      notes()
      local default_args = { "--workspace", "--all-features", "--no-deps" }
      H.eq(default_args, def.init_options.cargo.extraArgs, "precondition: defaults")

      rc.apply(root, { all = false, no_default = false, features = { "ssr" }, target = "t" })
      local params, config = {}, { root_dir = root, settings = { keep = 1 } }
      local settings_ref = config.settings
      def.before_init(params, config)
      local want = { "--workspace", "--features", "ssr", "--target", "t", "--no-deps" }
      H.eq(want, params.initializationOptions.cargo.extraArgs)
      H.eq(want, config.settings.bacon_ls.cargo.extraArgs)
      H.ok(config.settings == settings_ref, "settings patched in place")
      H.eq(1, config.settings.keep)
      H.eq("clippy", params.initializationOptions.cargo.command, "other options kept")
      H.eq(true, params.initializationOptions.cargo.updateOnInsert)

      -- after a reset: rebuilt from the defaults, no stale --features
      rc.apply(root, nil)
      local params2, config2 = {}, { root_dir = root }
      def.before_init(params2, config2)
      H.eq(default_args, params2.initializationOptions.cargo.extraArgs)
      H.eq(default_args, config2.settings.bacon_ls.cargo.extraArgs)
      -- the shared defaults never got the context's args
      H.eq(default_args, def.init_options.cargo.extraArgs)
      H.eq(default_args, def.settings.bacon_ls.cargo.extraArgs)
    end)

    it("bacon_ls root_dir is the workspace root, from a member; no root for non-crates", function()
      local def = plugin_opts("nvim-lspconfig").servers.bacon_ls
      local ws = H.fixture("workspace")
      local b = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(b, ws .. "/app/src/main.rs")
      local got
      def.root_dir(b, function(r)
        got = r
      end)
      H.eq(ws, got)
      local b2 = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(b2, H.tmpdir() .. "/solo.rs")
      got = nil
      def.root_dir(b2, function(r)
        got = r
      end)
      H.is_nil(got)
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- Live: real rust-analyzer (+ bacon-ls when Mason's attaches). A fresh copy of
-- the workspace fixture and fresh clients per test (about 10 s each).

describe("rust_context with live servers", function()
  local session

  --- Open the workspace fixture's core crate (its lib.rs holds the
  --- compile_error!), wait for rust-analyzer, and for bacon_ls when installed.
  local function live(opts)
    H.need_rust()
    stop_all_clients() -- a client of a previous test still shutting down must not be picked up
    local ws = H.fixture("workspace")
    vim.cmd.cd(vim.fn.fnameescape(ws))
    local buf = H.open(ws .. "/core/src/lib.rs")
    local ra = H.wait_lsp("rust-analyzer", buf)
    local bacon
    if vim.fn.executable("bacon-ls") == 1 then
      bacon = H.wait_lsp("bacon_ls", buf)
    end
    session = { root = ws, buf = buf, ra = ra, bacon = bacon }
    return session
  end

  local function conflict(buf, source)
    for _, d in ipairs(vim.diagnostic.get(buf)) do
      if d.source == source and d.message:find("mutually exclusive", 1, true) then
        return true
      end
    end
    return false
  end

  local function bacon_args()
    local c = vim.lsp.get_clients({ name = "bacon_ls" })[1]
    return c and c.settings and c.settings.bacon_ls and c.settings.bacon_ls.cargo.extraArgs
  end

  local function ra_cargo()
    return session.ra.settings["rust-analyzer"].cargo
  end

  before_each(function()
    vim.fn.delete(state_file)
  end)
  after_each(function()
    session = nil
    reset_world()
  end)

  it("apply updates the matching rust-analyzer clients, reloads, restarts bacon_ls and notifies", function()
    local s = live()
    -- a second rust-analyzer client rooted at another workspace must stay untouched
    -- (started by hand: rustaceanvim would attach the existing client to it instead)
    local basic = H.fixture("basic")
    local sbuf = vim.api.nvim_create_buf(false, true)
    local other_id = vim.lsp.start({
      name = "rust-analyzer",
      cmd = { "rust-analyzer" },
      root_dir = basic,
      settings = { ["rust-analyzer"] = { cargo = {} } },
    }, { bufnr = sbuf, reuse_client = function() return false end })
    local other = H.ok(vim.lsp.get_client_by_id(other_id), "second rust-analyzer client")
    H.ok(other.id ~= s.ra.id)
    s.ra.settings["rust-analyzer"].cargo.target = "stale-target" -- must be cleared by a nil target

    local cap = notes()
    local log = record_cmd()
    local ctx = { all = false, no_default = true, features = { "csr" } }
    rc.apply(s.root, ctx)

    local cargo = s.ra.settings["rust-analyzer"].cargo
    H.eq(false, cargo.allFeatures)
    H.eq(true, cargo.noDefaultFeatures)
    H.eq({ "csr" }, cargo.features)
    H.is_nil(cargo.target, "nil target clears the previous one")
    H.eq(true, cargo.targetDir, "unrelated cargo settings survive")
    H.is_nil(other.settings["rust-analyzer"].cargo.allFeatures, "other workspace's client untouched")
    H.eq({ [s.root] = ctx }, state())
    H.eq("Rust context: " .. rc.describe(ctx), cap.list[#cap.list].msg)
    H.wait_for(function()
      return vim.tbl_contains(log, "RustLsp reloadWorkspace")
    end, 5000, "RustLsp reloadWorkspace")
    if s.bacon then
      H.wait_for(function()
        return vim.tbl_contains(log, "lsp restart bacon_ls")
      end, 5000, "lsp restart bacon_ls")
      local fresh = H.wait_for(function()
        local c = vim.lsp.get_clients({ name = "bacon_ls" })[1]
        return c and c.id ~= s.bacon.id and c
      end, 30000, "a new bacon_ls client")
      H.eq(rc.bacon_args(ctx), fresh.settings.bacon_ls.cargo.extraArgs)
    end
  end)

  it("apply(root, nil) resets the running clients to all features", function()
    local s = live()
    notes()
    rc.apply(s.root, { all = false, features = { "ssr" } })
    H.eq(false, ra_cargo().allFeatures)
    rc.apply(s.root, nil)
    H.eq(true, ra_cargo().allFeatures)
    H.eq({}, ra_cargo().features)
    H.is_nil(ra_cargo().target)
    H.is_nil(rc.get(s.root))
    H.eq({}, state() or {})
  end)

  it("default context reports compile_error! from rust-analyzer and bacon-ls", function()
    local s = live()
    H.wait_for(function()
      return conflict(s.buf, "rust-analyzer")
    end, 60000, "rust-analyzer's compile_error diagnostic")
    if s.bacon then
      H.wait_for(function()
        return conflict(s.buf, "bacon-ls")
      end, 60000, "bacon-ls's compile_error diagnostic")
    end
  end)

  it("selecting only ssr removes the error in both tiers, reset brings it back", function()
    local s = live()
    H.wait_for(function()
      return conflict(s.buf, "rust-analyzer") and (not s.bacon or conflict(s.buf, "bacon-ls"))
    end, 90000, "the compile_error in both tiers before the change")
    notes()

    rc.apply(s.root, { all = false, no_default = false, features = { "ssr" } })
    H.wait_for(function()
      return not conflict(s.buf, "rust-analyzer")
    end, 60000, "rust-analyzer's error to disappear with only ssr")
    if s.bacon then
      H.wait_for(function()
        return vim.deep_equal(bacon_args(), { "--workspace", "--features", "ssr", "--no-deps" })
      end, 30000, "bacon_ls restarted with '--workspace --features ssr --no-deps'")
      H.wait_for(function()
        return not conflict(s.buf, "bacon-ls")
      end, 60000, "bacon-ls's error to disappear with only ssr")
    end

    rc.apply(s.root, nil)
    H.wait_for(function()
      return conflict(s.buf, "rust-analyzer")
    end, 60000, "rust-analyzer's error to come back after reset")
    if s.bacon then
      H.wait_for(function()
        return vim.deep_equal(bacon_args(), { "--workspace", "--all-features", "--no-deps" })
      end, 30000, "bacon_ls restarted without the stale --features args")
      H.wait_for(function()
        return conflict(s.buf, "bacon-ls")
      end, 60000, "bacon-ls's error to come back after reset")
    end
  end)

  -- KNOWN BUG (confirmed by hand): rustaceanvim attaches every further
  -- workspace's buffers to the ONE running rust-analyzer client (adding a
  -- workspace folder) whose config.root_dir stays the first workspace's, so
  -- apply(second_root, ctx) matches no client (M.root(client root) ~= second_root)
  -- and the live rust-analyzer never gets the new context, while the stored
  -- choice and the notification claim it was applied. Repro: open
  -- tests/fixtures/workspace/core/src/lib.rs, then tests/fixtures/basic/src/lib.rs
  -- in the same nvim (one client, two workspace folders), :RustContext in the
  -- basic buffer and pick a feature: the client's settings cargo.features and
  -- allFeatures are unchanged. Expected: the shared client is updated.
  pending("apply for a second workspace reaches the shared rust-analyzer client", "known bug: shared rustaceanvim client keeps the first workspace's root_dir")

  it("a stored csr choice is applied on a fresh server start", function()
    H.need_rust()
    local ws = H.fixture("workspace")
    notes()
    rc.apply(ws, { all = false, no_default = false, features = { "csr" } })
    vim.cmd.cd(vim.fn.fnameescape(ws))
    local buf = H.open(ws .. "/core/src/lib.rs")
    local ra = H.wait_lsp("rust-analyzer", buf)
    local cargo = ra.settings["rust-analyzer"].cargo
    H.eq(false, cargo.allFeatures)
    H.eq({ "csr" }, cargo.features)
    H.eq(false, cargo.noDefaultFeatures)
    if vim.fn.executable("bacon-ls") == 1 then
      local bacon = H.wait_lsp("bacon_ls", buf)
      H.eq({ "--workspace", "--features", "csr", "--no-deps" }, bacon.settings.bacon_ls.cargo.extraArgs)
    end
  end)

  it("choosing wasm32-unknown-unknown sets cargo.target live and in the state file; reset clears both", function()
    local wasm = "wasm32-unknown-unknown"
    H.need_rust()
    if vim.fn.executable("rustup") ~= 1 then
      H.skip_file("rustup not found")
    end
    local out = vim.system({ "rustup", "target", "list", "--installed" }, { text = true }):wait(10000)
    if not (out.stdout or ""):find(wasm, 1, true) then
      H.skip_file(wasm .. " is not installed (rustup target add " .. wasm .. ")")
    end
    local s = live()
    notes()
    local picker = stub_picker()
    local select = stub_select()
    vim.api.nvim_set_current_buf(s.buf)
    rc.pick()
    picker.opts.confirm(fake_picker(picker, { "* all features" }))
    H.wait_for(function()
      return select.call
    end, 10000, "the target step")
    H.has(select.call.items, wasm)
    H.eq("(host default)", select.call.items[1])
    select.call.cb(wasm)
    H.eq(wasm, ra_cargo().target)
    H.eq(true, ra_cargo().allFeatures)
    H.eq(wasm, state()[s.root].target)
    if s.bacon then
      H.wait_for(function()
        return vim.deep_equal(bacon_args(), { "--workspace", "--all-features", "--target", wasm, "--no-deps" })
      end, 30000, "bacon_ls restarted with --target " .. wasm)
    end

    vim.api.nvim_set_current_buf(s.buf)
    vim.cmd("RustContext reset")
    H.is_nil(ra_cargo().target)
    H.is_nil(state()[s.root])
    if s.bacon then
      H.wait_for(function()
        return vim.deep_equal(bacon_args(), { "--workspace", "--all-features", "--no-deps" })
      end, 30000, "bacon_ls restarted without --target")
    end
  end)
end)
