-- xyno-timeout: 400
-- xyno_rust.rust_context (:RustContext, per-workspace cargo features/target) and
-- its two consumers, plugins/rustaceanvim.lua (server.settings) and
-- plugins/bacon-ls.lua (before_init). The pure part and the picker/command
-- part run without servers; the "live" part needs rust-analyzer + cargo
-- (bacon-ls assertions are made when Mason's bacon-ls attaches).
local H = require("xynotest.helpers")

local rc = require("xyno_rust.rust_context")
local state_file = vim.fn.stdpath("state") .. "/rust-context.json"

local function write_text(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
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

--- A crate directory with the given Cargo.toml text (+ an empty src/lib.rs).
local function crate(toml)
  local dir = H.tmpdir()
  write_text(dir .. "/Cargo.toml", toml)
  write_text(dir .. "/src/lib.rs", "")
  return dir
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

  -- ----------------------------------------------------------------- state

  -- ------------------------------------------------- pure flag/arg builders

  -- ------------------------------------------------------ apply, no servers

  -- ---------------------------------------------------------------- command

  -- ----------------------------------------------------------------- picker

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
      local default_args = { "--workspace", "--all-features", "--no-deps", "--keep-going" }
      H.eq(default_args, def.init_options.cargo.extraArgs, "precondition: defaults")

      rc.apply(root, { all = false, no_default = false, features = { "ssr" }, target = "t" })
      local params, config = {}, { root_dir = root, settings = { keep = 1 } }
      local settings_ref = config.settings
      def.before_init(params, config)
      local want = { "--workspace", "--features", "ssr", "--target", "t", "--no-deps", "--keep-going" }
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
      vim.bo[b].buftype = "" -- a real file buffer (a scratch one gets no client)
      local got
      def.root_dir(b, function(r)
        got = r
      end)
      H.eq(ws, got)
      local b2 = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(b2, H.tmpdir() .. "/solo.rs")
      vim.bo[b2].buftype = ""
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
    H.known_issue({ "windows" }, "live servers need bacon_ls / rust-analyzer (windows-latest run 39647013043); the state-file sanitising failure is not diagnosed")
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

  it("default context reports compile_error! from rust-analyzer and bacon-ls", function()
    H.known_issue({ "windows" }, "live servers need bacon_ls / rust-analyzer (windows-latest run 39647013043); the state-file sanitising failure is not diagnosed")
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
    H.known_issue({ "windows" }, "live servers need bacon_ls / rust-analyzer (windows-latest run 39647013043); the state-file sanitising failure is not diagnosed")
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
        return vim.deep_equal(bacon_args(), { "--workspace", "--features", "ssr", "--no-deps", "--keep-going" })
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
        return vim.deep_equal(bacon_args(), { "--workspace", "--all-features", "--no-deps", "--keep-going" })
      end, 30000, "bacon_ls restarted without the stale --features args")
      H.wait_for(function()
        return conflict(s.buf, "bacon-ls")
      end, 60000, "bacon-ls's error to come back after reset")
    end
  end)

  -- rustaceanvim attaches every further workspace's buffers to the ONE running
  -- rust-analyzer client (an added workspace folder) whose config.root_dir stays
  -- the first workspace's: apply(second_root, ctx) must still reach it.

  it("a stored csr choice is applied on a fresh server start", function()
    H.known_issue({ "windows" }, "live servers need bacon_ls / rust-analyzer (windows-latest run 39647013043); the state-file sanitising failure is not diagnosed")
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
      H.eq({ "--workspace", "--features", "csr", "--no-deps", "--keep-going" }, bacon.settings.bacon_ls.cargo.extraArgs)
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
        return vim.deep_equal(bacon_args(), { "--workspace", "--all-features", "--target", wasm, "--no-deps", "--keep-going" })
      end, 30000, "bacon_ls restarted with --target " .. wasm)
    end

    vim.api.nvim_set_current_buf(s.buf)
    vim.cmd("RustContext reset")
    H.is_nil(ra_cargo().target)
    H.is_nil(state()[s.root])
    if s.bacon then
      H.wait_for(function()
        return vim.deep_equal(bacon_args(), { "--workspace", "--all-features", "--no-deps", "--keep-going" })
      end, 30000, "bacon_ls restarted without --target")
    end
  end)
end)
