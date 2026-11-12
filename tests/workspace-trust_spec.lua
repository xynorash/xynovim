-- xyno-timeout: 240
-- Restricted mode for untrusted Rust workspaces (lua/config/workspace_trust.lua, wired into
-- plugins/rustaceanvim.lua server.settings and plugins/bacon-ls.lua root_dir): rust-analyzer starts
-- without build scripts / proc macros / cargo check, bacon-ls (clippy) does not start, one prompt per
-- workspace and session, trusting restarts both with the full settings, revoking restricts again. The
-- live part runs a real rust-analyzer on a crate whose build.rs writes a canary file.
local H = require("xynotest.helpers")

-- the trust store the gate uses: xyno_rust.trust, or the vendored fallback while the pinned plugin has none
local wt = require("config.workspace_trust")
local trust = wt.store()
if not trust then
  H.skip_file("neither xyno_rust.trust nor the vendored fallback loads")
end
local base = vim.env.XYNO_TEST_TMP

local undo = {}
local function on_undo(fn)
  undo[#undo + 1] = fn
end

local function plugin_opts(name)
  local plugin = require("lazy.core.config").plugins[name]
  return require("lazy.core.plugin").values(plugin, "opts", false)
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

--- A crate whose build.rs writes `canary` (so "build scripts ran" is observable).
local function canary_crate(canary)
  local dir = H.tmpdir() .. "/canary"
  write(dir .. "/Cargo.toml", '[package]\nname = "canary"\nversion = "0.1.0"\nedition = "2021"\nbuild = "build.rs"\n')
  write(dir .. "/build.rs", ('fn main() { std::fs::write(%q, "ran").unwrap(); }\n'):format(canary))
  write(dir .. "/src/lib.rs", "pub fn f() -> u32 { 1 }\n")
  return dir
end

--- What server.settings returned before restricted mode existed (the gate switched off).
local function ungated(o, ws)
  local prev = vim.g.xynovim_workspace_trust
  vim.g.xynovim_workspace_trust = false
  local s = o.settings(ws, vim.deepcopy(o.default_settings))["rust-analyzer"]
  vim.g.xynovim_workspace_trust = prev
  return s
end

local function stub_ui(choice)
  local calls = {}
  local orig_select, orig_uis = vim.ui.select, vim.api.nvim_list_uis
  local orig_float = trust.float_prompt
  trust.float_prompt = false -- these cases answer through vim.ui.select (the float has its own spec)
  vim.api.nvim_list_uis = function()
    return { {} }
  end
  vim.ui.select = function(items, opts, cb)
    calls[#calls + 1] = { items = items, opts = opts }
    cb(vim.tbl_filter(function(i)
      return i[2] == choice
    end, items)[1])
  end
  on_undo(function()
    vim.ui.select, vim.api.nvim_list_uis = orig_select, orig_uis
    trust.float_prompt = orig_float
  end)
  return calls
end

describe("workspace trust gate", function()
  before_each(function()
    wt._reset()
    -- the run's temp directory is trusted recursively by helpers.tmpdir() (on its first call): this
    -- spec needs it untrusted
    H.tmpdir()
    trust.revoke(base)
    vim.g.xynovim_workspace_trust = nil
  end)
  after_each(function()
    for i = #undo, 1, -1 do
      pcall(undo[i])
    end
    undo = {}
    wt._reset()
    vim.g.xynovim_workspace_trust = nil
    vim.cmd("silent! %bwipeout!")
    trust.trust(base, { recursive = true })
  end)

  describe("settings", function()
    it(
      "an untrusted workspace gets no build scripts, no proc macros, no check on save, cleared rustc wrappers",
      function()
        local o = plugin_opts("rustaceanvim").server
        local ws = H.fixture("workspace")
        local base_defaults = vim.deepcopy(o.default_settings)
        H.eq(false, trust.is_trusted(ws))
        local s = o.settings(ws, o.default_settings)["rust-analyzer"]
        H.eq(false, s.procMacro.enable)
        H.eq(false, s.cargo.buildScripts.enable)
        H.eq(false, s.checkOnSave)
        for _, k in ipairs({
          "RUSTC_WRAPPER",
          "RUSTC_WORKSPACE_WRAPPER",
          "CARGO_BUILD_RUSTC_WRAPPER",
          "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER",
        }) do
          H.eq("", s.cargo.extraEnv[k], k)
        end
        H.eq("rustc", s.cargo.extraEnv.RUSTC)
        -- everything else is as configured
        H.eq(8, s.numThreads)
        H.eq(true, s.cargo.targetDir)
        H.eq(true, s.completion.termSearch.enable)
        -- the shared defaults are not modified
        H.ok(vim.deep_equal(base_defaults["rust-analyzer"], o.default_settings["rust-analyzer"]), "defaults untouched")
      end
    )

    it("a trusted workspace gets exactly the settings it always had", function()
      local o = plugin_opts("rustaceanvim").server
      local ws = H.fixture("workspace")
      local before = o.settings(ws, vim.deepcopy(o.default_settings))
      wt._reset()
      trust.trust(ws)
      local after = o.settings(ws, vim.deepcopy(o.default_settings))
      H.is_nil(after["rust-analyzer"].cargo.extraEnv)
      local expect = { ["rust-analyzer"] = ungated(o, ws) }
      H.eq(expect["rust-analyzer"], after["rust-analyzer"])
      H.eq(false, before["rust-analyzer"].procMacro.enable, "precondition: it was restricted before")
      -- a member path resolves to the workspace root: same answer
      H.eq(expect["rust-analyzer"], o.settings(ws .. "/app", vim.deepcopy(o.default_settings))["rust-analyzer"])
    end)

    it("is off with vim.g.xynovim_workspace_trust = false and for a missing root", function()
      local o = plugin_opts("rustaceanvim").server
      local ws = H.fixture("workspace")
      vim.g.xynovim_workspace_trust = false
      local off = o.settings(ws, vim.deepcopy(o.default_settings))["rust-analyzer"]
      H.is_nil(off.cargo.extraEnv)
      H.ok(off.procMacro.enable ~= false and off.cargo.buildScripts.enable ~= false)
      vim.g.xynovim_workspace_trust = nil
      local nowhere = o.settings(nil, vim.deepcopy(o.default_settings))["rust-analyzer"]
      H.is_nil(nowhere.cargo.extraEnv)
      H.ok(nowhere.procMacro.enable ~= false)
    end)

    it("an 'everything under the parent' entry trusts the siblings; a revoked one restricts again", function()
      local a = H.fixture("basic")
      local sibling = vim.fs.dirname(a) .. "/sibling"
      write(sibling .. "/Cargo.toml", '[package]\nname = "s"\n')
      H.not_ok(wt.trusted(a))
      trust.trust(vim.fs.dirname(a), { recursive = true })
      wt._reset()
      H.ok(wt.trusted(a), "basic under the trusted parent")
      H.ok(wt.trusted(sibling), "and its sibling")
      trust.revoke(vim.fs.dirname(a))
      wt._reset()
      H.not_ok(wt.trusted(a))
    end)
  end)

  describe("bacon-ls", function()
    local function root_dir(path)
      local def = plugin_opts("nvim-lspconfig").servers.bacon_ls
      local b = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(b, path)
      vim.bo[b].buftype = ""
      local got
      def.root_dir(b, function(r)
        got = r
      end)
      vim.wait(10000, function()
        return got ~= nil
      end, 20)
      vim.api.nvim_buf_delete(b, { force = true })
      return got
    end

    it("root_dir yields no root for an untrusted workspace and the root for a trusted one", function()
      local ws = H.fixture("workspace")
      vim.wait(50)
      H.is_nil(root_dir(ws .. "/app/src/main.rs"))
      trust.trust(ws)
      wt._reset()
      H.eq(ws, root_dir(ws .. "/app/src/main.rs"))
    end)
  end)

  describe("prompt", function()
    it("asks once per workspace: 'run this once' trusts the session, not the list", function()
      local calls = stub_ui("once")
      local o = plugin_opts("rustaceanvim").server
      local ws = H.fixture("basic")
      o.settings(ws, vim.deepcopy(o.default_settings))
      o.settings(ws, vim.deepcopy(o.default_settings))
      vim.wait(200)
      H.eq(1, #calls, "one prompt")
      H.ok(calls[1].opts.prompt:find(ws, 1, true), "names the workspace")
      H.ok(wt.trusted(ws), "trusted for the session")
      H.eq(false, trust.is_trusted(ws), "but not remembered")
      H.eq(ungated(o, ws), o.settings(ws, vim.deepcopy(o.default_settings))["rust-analyzer"])
    end)

    it("'Trust this workspace' is remembered for later sessions; one prompt", function()
      local calls = stub_ui("trust")
      local o = plugin_opts("rustaceanvim").server
      local ws = H.fixture("basic")
      o.settings(ws, vim.deepcopy(o.default_settings))
      vim.wait(200)
      H.eq(1, #calls)
      H.eq(true, trust.is_trusted(ws))
      wt._reset() -- a new session
      H.eq(ungated(o, ws), o.settings(ws, vim.deepcopy(o.default_settings))["rust-analyzer"])
      vim.wait(100)
      H.eq(1, #calls, "no second prompt")
    end)

    it("'Do not run' keeps it restricted, tells how to trust and does not ask again", function()
      local calls = stub_ui("no")
      H.settle_notify()
      local cap = H.capture_notify()
      on_undo(cap.restore)
      local o = plugin_opts("rustaceanvim").server
      local ws = H.fixture("basic")
      o.settings(ws, vim.deepcopy(o.default_settings))
      vim.wait(200)
      H.eq(false, wt.trusted(ws))
      local told = false
      for _, n in ipairs(cap.list) do
        told = told or (n.msg:find("Restricted mode", 1, true) and n.msg:find(":RustTrust add", 1, true))
      end
      H.ok(told, "banner with the command")
      o.settings(ws, vim.deepcopy(o.default_settings))
      vim.wait(100)
      H.eq(1, #calls)
    end)

    it("asks nothing without a UI (headless), the workspace stays restricted", function()
      local called = false
      local orig = vim.ui.select
      vim.ui.select = function()
        called = true
      end
      on_undo(function()
        vim.ui.select = orig
      end)
      local o = plugin_opts("rustaceanvim").server
      local ws = H.fixture("basic")
      o.settings(ws, vim.deepcopy(o.default_settings))
      vim.wait(100)
      H.eq(false, called)
      H.eq(false, wt.trusted(ws))
    end)
  end)

  describe("status", function()
    it("marks a Rust buffer of an untrusted workspace in the lsp_status component, until it is trusted", function()
      local ws = H.fixture("basic")
      local o = plugin_opts("rustaceanvim").server
      o.settings(ws, vim.deepcopy(o.default_settings)) -- registers the part
      vim.cmd.cd(vim.fn.fnameescape(ws))
      local b = H.open(ws .. "/src/lib.rs")
      vim.bo[b].filetype = "rust"
      local status = require("xyno_rust.lsp_status")
      H.ok(status.component():find("RESTRICTED", 1, true), status.component())
      H.eq("RESTRICTED", wt.status(b))
      trust.trust(ws)
      vim.wait(100)
      H.eq("", wt.status(b))
      H.not_ok(status.component():find("RESTRICTED", 1, true))
    end)

    it(":checkhealth data: the report names the workspace and who trusts it", function()
      local ws = H.fixture("basic")
      local r = wt.report(ws .. "/src/lib.rs")
      H.eq(true, r.enabled)
      H.eq(false, r.trusted)
      trust.trust(ws)
      wt._reset()
      r = wt.report(ws .. "/src/lib.rs")
      H.eq(true, r.trusted)
      H.eq(ws, r.by)
    end)
  end)
end)

describe("workspace trust gate in :checkhealth xynovim", function()
  it("warns in an untrusted workspace, says ok in a trusted one", function()
    H.tmpdir()
    trust.revoke(base)
    local ws = H.fixture("basic")
    vim.cmd.cd(vim.fn.fnameescape(ws))
    local function run()
      local rows, section = {}, nil
      local orig = vim.health
      vim.health = setmetatable({
        start = function(name)
          section = name
        end,
        ok = function(m)
          rows[#rows + 1] = { section, "ok", m }
        end,
        warn = function(m)
          rows[#rows + 1] = { section, "warn", m }
        end,
        info = function() end,
        error = function() end,
      }, { __index = orig })
      package.loaded["xynovim.health"] = nil
      pcall(function()
        require("xynovim.health").check()
      end)
      vim.health = orig
      return vim.tbl_filter(function(r)
        return r[1] == "xynovim: workspace trust"
      end, rows)
    end
    wt._reset()
    local rows = run()
    H.eq(1, #rows)
    H.eq("warn", rows[1][2])
    H.ok(rows[1][3]:find("NOT trusted", 1, true))
    trust.trust(ws)
    wt._reset()
    rows = run()
    H.eq("ok", rows[1][2])
    H.ok(rows[1][3]:find("is trusted", 1, true))
    trust.trust(base, { recursive = true })
  end)
end)

describe("workspace trust gate with live servers", function()
  local function ra_client()
    return vim.lsp.get_clients({ name = "rust-analyzer" })[1]
  end

  local function stop_all()
    for _, c in ipairs(vim.lsp.get_clients()) do
      c:stop(true)
    end
    vim.wait(5000, function()
      return #vim.lsp.get_clients() == 0
    end, 20)
  end

  before_each(function()
    wt._reset()
    H.tmpdir()
    trust.revoke(base)
    vim.g.xynovim_workspace_trust = nil
  end)
  after_each(function()
    wt._reset()
    stop_all()
    vim.cmd("silent! %bwipeout!")
    trust.trust(base, { recursive = true })
  end)

  it(
    "an untrusted build.rs does not run; trusting restarts rust-analyzer and it runs; revoking restricts again",
    function()
      H.need_rust()
      stop_all()
      local canary = H.tmpdir() .. "/canary.txt"
      local dir = canary_crate(canary)
      vim.cmd.cd(vim.fn.fnameescape(dir))
      local buf = H.open(dir .. "/src/lib.rs")
      local ra = H.wait_lsp("rust-analyzer", buf)
      H.eq(false, ra.settings["rust-analyzer"].procMacro.enable)
      H.eq(false, ra.settings["rust-analyzer"].cargo.buildScripts.enable)
      H.eq(false, ra.settings["rust-analyzer"].checkOnSave)
      -- let it load the workspace, save the file (a check on save would compile build.rs), wait some more
      vim.wait(6000)
      vim.cmd("silent write")
      vim.wait(4000)
      H.is_nil(vim.uv.fs_stat(canary), "build.rs ran in an untrusted workspace")
      H.ok(require("xyno_rust.lsp_status").component():find("RESTRICTED", 1, true))
      if vim.fn.executable("bacon-ls") == 1 then
        H.eq(0, #H.clients(buf, "bacon_ls"), "no clippy in an untrusted workspace")
      end

      -- trust it: restarted with the full settings, build scripts run
      local old_id = ra.id
      trust.trust(dir)
      local fresh = H.wait_for(function()
        local c = ra_client()
        return c and c.id ~= old_id and c
      end, 30000, "rust-analyzer restarted after :RustTrust add")
      H.ok(fresh.settings["rust-analyzer"].procMacro.enable ~= false, "trusted settings")
      H.ok(fresh.settings["rust-analyzer"].cargo.extraEnv == nil, "trusted settings")
      H.wait_for(function()
        return vim.uv.fs_stat(canary)
      end, 90000, "build.rs to run once trusted")
      H.not_ok(require("xyno_rust.lsp_status").component():find("RESTRICTED", 1, true))
      if vim.fn.executable("bacon-ls") == 1 then
        H.wait_lsp("bacon_ls", buf, 30000)
      end

      -- revoke: restricted again, clippy stopped
      local trusted_id = fresh.id
      trust.revoke(dir)
      local again = H.wait_for(function()
        local c = ra_client()
        return c and c.id ~= trusted_id and c
      end, 30000, "rust-analyzer restarted after revoke")
      H.eq(false, again.settings["rust-analyzer"].procMacro.enable)
      if vim.fn.executable("bacon-ls") == 1 then
        H.wait_for(function()
          return #H.clients(buf, "bacon_ls") == 0
        end, 15000, "bacon-ls stopped after revoke")
      end
    end
  )

  it("a trusted workspace runs build.rs at once and has the full settings", function()
    H.need_rust()
    stop_all()
    local canary = H.tmpdir() .. "/canary.txt"
    local dir = canary_crate(canary)
    trust.trust(dir)
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/src/lib.rs")
    local ra = H.wait_lsp("rust-analyzer", buf)
    H.ok(ra.settings["rust-analyzer"].procMacro.enable ~= false)
    H.wait_for(function()
      return vim.uv.fs_stat(canary)
    end, 90000, "build.rs to run in a trusted workspace")
  end)
end)
