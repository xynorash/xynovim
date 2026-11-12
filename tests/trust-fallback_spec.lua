-- xyno-timeout: 120
-- The pinned xyno-rust.nvim (lazy-lock.json) has no trust module: config/workspace_trust.lua then uses the
-- vendored lua/xynovim/trust_fallback.lua (same API, same file). Runs in BOTH modes (default and dev plugins):
-- the plugin's module is hidden for the cases that need "the pin has no trust module". Also the "run this once"
-- answer, which has to end when the content it was given for changes.
local H = require("xynotest.helpers")
local wt = require("config.workspace_trust")

local undo = {}
local function on_undo(fn)
  undo[#undo + 1] = fn
end

--- Make `require("xyno_rust.trust")` fail like the pinned plugin's missing module, and start the gate afresh.
local function hide_plugin_trust()
  local saved = package.loaded["xyno_rust.trust"]
  package.loaded["xyno_rust.trust"] = nil
  local preload = package.preload["xyno_rust.trust"]
  package.preload["xyno_rust.trust"] = function()
    error("module 'xyno_rust.trust' not found")
  end
  on_undo(function()
    package.loaded["xyno_rust.trust"], package.preload["xyno_rust.trust"] = saved, preload
    wt._reset()
  end)
  wt._reset()
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

describe("vendored trust fallback", function()
  before_each(function()
    vim.g.xynovim_workspace_trust = nil
    hide_plugin_trust()
  end)
  after_each(function()
    for i = #undo, 1, -1 do
      pcall(undo[i])
    end
    undo = {}
    pcall(vim.api.nvim_del_user_command, "RustTrustFallbackProbe")
    vim.g.xynovim_workspace_trust = nil
  end)

  it("without xyno_rust.trust the gate has a store (not fail-closed for ever) and it is the fallback", function()
    H.ok(wt.store(), "a store")
    H.ok(wt.using_fallback())
    H.ok(wt.enabled())
    local fb = require("xynovim.trust_fallback")
    for _, fn in ipairs({
      "is_trusted",
      "trust",
      "revoke",
      "revoke_all",
      "list",
      "drift",
      "rehash",
      "fingerprint",
      "ra_overrides",
      "ask",
      "require",
      "normalize",
      "file",
      "command",
    }) do
      H.eq("function", type(fb[fn]), fn)
    end
    H.eq(vim.fn.stdpath("state") .. "/xyno-rust-trust.json", fb.file())
  end)

  it("a Cargo workspace can be trusted: full settings, run commands go through, :RustTrust exists", function()
    local ws = H.fixture("basic")
    local fb = wt.store()
    fb.revoke_all()
    H.eq(false, wt.allowed(ws))
    local ra = wt.settings_for(ws, { ["rust-analyzer"] = {} })["rust-analyzer"]
    H.eq(false, ra.procMacro.enable, "restricted until trusted")
    fb.trust(ws)
    wt._reset()
    wt.store() -- (decided again after the reset)
    H.ok(wt.allowed(ws), "trusted")
    H.is_nil(wt.settings_for(ws, { ["rust-analyzer"] = {} })["rust-analyzer"].procMacro)
    local ran
    wt.require(ws, "cargo test", function(ok)
      ran = ok
    end)
    H.eq(true, ran, "no 'update the pin' refusal")
    H.eq(2, vim.fn.exists(":RustTrust"), ":RustTrust is defined")
    fb.revoke_all()
  end)

  it("keeps the storage format of xyno_rust.trust: an entry written by one is read by the other", function()
    local okp, plugin = pcall(function()
      package.preload["xyno_rust.trust"] = nil
      package.loaded["xyno_rust.trust"] = nil
      return require("xyno_rust.trust")
    end)
    if not okp then
      -- the pinned plugin has no module: the format is checked against the documented JSON instead
      local fb = require("xynovim.trust_fallback")
      local ws = H.fixture("basic")
      fb.trust(ws)
      local raw = vim.json.decode(table.concat(vim.fn.readfile(fb.file()), "\n"))
      local e = raw[fb.normalize(ws)]
      H.ok(e and e.hash and e.files and e.at and e.recursive == false, vim.inspect(e))
      fb.revoke_all()
      return
    end
    local fb = require("xynovim.trust_fallback")
    local ws = H.fixture("basic")
    fb.trust(ws)
    H.ok(plugin.is_trusted(ws), "the plugin reads the fallback's entry (same fingerprint)")
    H.eq(fb.fingerprint(ws).hash, plugin.fingerprint(ws).hash)
    fb.revoke_all()
    plugin.trust(ws)
    H.ok(fb.is_trusted(ws), "the fallback reads the plugin's entry")
    plugin.revoke_all()
  end)

  it("the fingerprint walk is capped and memoised (no uncached directory walk on every call)", function()
    local fb = require("xynovim.trust_fallback")
    H.ok(fb._max_dirs and fb._max_dirs >= 1000)
    local ws = H.fixture("basic")
    local a = fb.fingerprint(ws)
    H.ok(rawequal(a, fb.fingerprint(ws)), "unchanged tree: the memo answers")
    write(ws .. "/sub/build.rs", "fn main() {}\n")
    H.not_ok(rawequal(a, fb.fingerprint(ws)), "a new file is seen at once")
  end)
end)

describe("'run this once' honours drift", function()
  local fb
  local ws
  before_each(function()
    vim.g.xynovim_workspace_trust = nil
    wt._reset()
    fb = wt.store()
    ws = H.fixture("basic")
    H.tmpdir()
    fb.revoke(vim.env.XYNO_TEST_TMP)
    fb.revoke(ws)
    wt._reset()
  end)
  after_each(function()
    wt._reset()
    fb.trust(vim.env.XYNO_TEST_TMP, { recursive = true })
  end)

  it("an answer of 'once' ends when a manifest changes behind the editor; a saved manifest keeps it", function()
    local orig_select, orig_uis, orig_float = vim.ui.select, vim.api.nvim_list_uis, fb.float_prompt
    fb.float_prompt = false
    vim.api.nvim_list_uis = function()
      return { {} }
    end
    vim.ui.select = function(items, _, cb)
      cb(vim.tbl_filter(function(i)
        return i[2] == "once"
      end, items)[1])
    end
    local o =
      require("lazy.core.plugin").values(require("lazy.core.config").plugins["rustaceanvim"], "opts", false).server
    o.settings(ws, vim.deepcopy(o.default_settings))
    vim.wait(200)
    vim.ui.select, vim.api.nvim_list_uis, fb.float_prompt = orig_select, orig_uis, orig_float
    H.eq(true, wt.trusted(ws), "run once: trusted for the session")
    H.eq(false, fb.is_trusted(ws), "and remembered nowhere")

    -- the editor's own save of the manifest is not a surprise
    local manifest = ws .. "/Cargo.toml"
    local text = table.concat(vim.fn.readfile(manifest), "\n")
    write(manifest, text .. "\n# edited in nvim\n")
    wt.note_saved(ws, manifest, fb)
    vim.wait(1100)
    H.eq(true, wt.allowed(ws), "a manifest saved in the editor keeps the once-answer")

    -- a pulled build.rs (a file changed behind the editor's back) ends it
    write(ws .. "/build.rs", 'fn main() { println!("cargo:rerun-if-changed=build.rs"); }\n')
    vim.wait(1100) -- the check is rate limited to once a second
    H.eq(false, wt.allowed(ws), "the once-answer does not cover content that changed since")
  end)
end)

describe("the editor's own cargo add (pinned xyno-crates.nvim has no trust call of its own)", function()
  it("wrap_crates re-records the trust after a successful add, and a pulled build.rs still asks", function()
    vim.g.xynovim_workspace_trust = nil
    wt._reset()
    local store = wt.store()
    local ok, ca = pcall(require, "xyno_crates.crate_add")
    if not ok then
      return H.skip_file("xyno_crates is not installed")
    end
    local ws = H.fixture("basic")
    H.tmpdir()
    store.revoke(vim.env.XYNO_TEST_TMP) -- the run's temp dir is trusted recursively: that would hide the check
    store.trust(ws)
    local orig = ca.run_add
    local wrapped_before = ca._xynovim_trust_wrapped
    ca.run_add = function(_, _, cb) -- stands for cargo add: it edits the manifest, then reports success
      write(ws .. "/Cargo.toml", table.concat(vim.fn.readfile(ws .. "/Cargo.toml"), "\n") .. "\n# cargo add\n")
      cb(true, "added")
    end
    ca._xynovim_trust_wrapped = nil
    local has_own = pcall(require, "xyno_crates.trust_rehash") -- a newer plugin does it itself
    local did = wt.wrap_crates()
    local done
    ca.run_add(ws, { name = "x", manifest = ws .. "/Cargo.toml" }, function(v)
      done = v
    end)
    if not has_own then
      H.ok(did)
      H.eq(true, done)
      H.ok(store.is_trusted(ws), "the manifest cargo add wrote is the editor's own edit")
    end
    write(ws .. "/build.rs", "fn main() {}\n")
    H.not_ok(store.is_trusted(ws), "a pulled build.rs next to it is not")
    ca.run_add, ca._xynovim_trust_wrapped = orig, wrapped_before
    store.revoke(ws)
    store.trust(vim.env.XYNO_TEST_TMP, { recursive = true })
  end)
end)
