-- xyno-timeout: 240
-- Every command of this config that runs cargo / rustc / build scripts / proc macros goes through ONE trust
-- check (config/workspace_trust.lua: allowed / require / system / guard_neotest / install) in a workspace
-- nobody trusted: coverage (<leader>tc), doc-tests into the panel, the debug build before a launch,
-- rustaceanvim's runnables / testables / debuggables, neotest runs, the cargo-deny / cargo-machete linters.
-- A source scan proves that no spawn of cargo/rustc exists that is neither gated nor listed as read-only,
-- and the fail-closed / re-ask rules of the gate itself (missing trust module, changed build.rs) are covered.
local H = require("xynotest.helpers")
H.need_rust()

-- The pinned xyno-rust.nvim (lazy-lock.json) predates xyno_rust.trust: the gate then uses the vendored
-- fallback (lua/xynovim/trust_fallback.lua, same API incl. content fingerprints), so these cases run in both modes.
local trust = require("config.workspace_trust").store()
local HAS_TRUST = type(trust) == "table" and type(trust.ra_overrides) == "function"
local HAS_DRIFT = HAS_TRUST and type(trust.drift) == "function" and type(trust.rehash) == "function"
local function needs_trust()
  if not HAS_TRUST then
    skip("the pinned xyno-rust.nvim has no workspace trust (XYNOVIM_DEV_PLUGINS or a newer lock runs this)")
  end
end

local wt = require("config.workspace_trust")
local base = vim.env.XYNO_TEST_TMP

local undo = {}
local function on_undo(fn)
  undo[#undo + 1] = fn
end
local function stub(t, k, v)
  local orig = t[k]
  t[k] = v
  on_undo(function()
    t[k] = orig
  end)
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

--- Answer the trust prompt with the choice tagged `choice` (nil: Esc); a UI is "attached".
local function ui(choice)
  local calls = { n = 0, prompts = {} }
  if trust then
    stub(trust, "float_prompt", false) -- answered through vim.ui.select here
  end
  stub(vim.api, "nvim_list_uis", function()
    return { {} }
  end)
  stub(vim.ui, "select", function(items, opts, cb)
    -- the language server's own restricted-mode prompt (a Rust buffer is open) is another question
    if opts.prompt:find("rust-analyzer (build scripts, proc macros) and clippy", 1, true) then
      calls.ra = (calls.ra or 0) + 1
    else
      calls.n = calls.n + 1
      calls.prompts[#calls.prompts + 1] = opts.prompt
    end
    cb(vim.tbl_filter(function(i)
      return i[2] == choice
    end, items)[1])
  end)
  return calls
end

--- Record (and fake) every vim.system that would build or run code; cargo metadata & co. run for real.
local READ_ONLY = { metadata = true, ["locate-project"] = true, ["--version"] = true, version = true }
local function spy()
  local ran = {}
  local real = vim.system
  stub(vim, "system", function(cmd, opts, cb)
    local head = type(cmd) == "table" and vim.fs.basename(cmd[1] or "") or ""
    if
      (head == "cargo" or head == "rustc")
      and not READ_ONLY[cmd[2] or ""]
      and not (head == "rustc" and cmd[2] == "--print")
    then
      ran[#ran + 1] = table.concat(cmd, " ")
      local res = { code = 0, stdout = "", stderr = "" }
      if cb then
        vim.schedule(function()
          cb(res)
        end)
      end
      return {
        wait = function()
          return res
        end,
      }
    end
    return real(cmd, opts, cb)
  end)
  return ran
end

local function crate()
  local ws = H.fixture("basic")
  vim.cmd.cd(vim.fn.fnameescape(ws))
  vim.cmd.edit(vim.fn.fnameescape(ws .. "/src/main.rs"))
  return ws
end

before_each(function()
  wt._reset()
  H.tmpdir()
  if HAS_TRUST then
    trust.revoke(base)
  end -- helpers.tmpdir() trusts the run's temp dir recursively; these specs need it untrusted
  vim.g.xynovim_workspace_trust = nil
end)
after_each(function()
  for i = #undo, 1, -1 do
    pcall(undo[i])
  end
  undo = {}
  wt._reset()
  vim.g.xynovim_workspace_trust = nil
  pcall(vim.cmd, "silent! %bwipeout!")
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
  if HAS_TRUST then
    trust.trust(base, { recursive = true })
  end
end)

-- ------------------------------------------------------------------ the commands

describe("coverage (<leader>tc)", function()
  before_each(needs_trust)
  local function run_key()
    local keys = require("lazy.core.config").plugins["nvim-coverage"].keys
    for _, k in ipairs(keys) do
      if k[1] == "<leader>tc" then
        return k[2]
      end
    end
    error("no <leader>tc")
  end

  it("untrusted + refused: cargo llvm-cov does not run", function()
    local ws = crate()
    local ran = spy()
    local calls = ui("no")
    run_key()()
    vim.wait(300)
    H.eq({}, ran)
    H.eq(1, calls.n, "asked once")
    H.match(calls.prompts[1], ws, true)
  end)

  it("untrusted + headless: nothing runs and nothing is asked", function()
    crate()
    local ran = spy()
    local calls = { n = 0 }
    stub(vim.ui, "select", function()
      calls.n = calls.n + 1
    end)
    run_key()()
    vim.wait(200)
    H.eq({}, ran)
    H.eq(0, calls.n)
  end)

  it("untrusted + 'trust': runs, and the next run does not ask", function()
    crate()
    local ran = spy()
    local calls = ui("trust")
    run_key()()
    H.wait_for(function()
      return #ran == 1
    end, 3000, "cargo llvm-cov ran")
    H.match(ran[1], "cargo llvm-cov", true)
    run_key()()
    H.wait_for(function()
      return #ran == 2
    end, 3000)
    -- one question in all (the open Rust buffer's own prompt may have been the one that was answered)
    H.eq(1, calls.n + (calls.ra or 0))
  end)

  it("a trusted workspace runs at once, no prompt", function()
    local ws = crate()
    trust.trust(ws)
    local ran = spy()
    local calls = ui("no")
    run_key()()
    H.wait_for(function()
      return #ran == 1
    end, 3000)
    H.eq(0, calls.n)
  end)
end)

describe("doc-tests into the panel (run_doctests)", function()
  before_each(needs_trust)
  it("untrusted + refused: cargo test --doc does not run; trusted: it does", function()
    local ws = crate()
    local ran = spy()
    local calls = ui("no")
    require("config.test_ui").run_doctests()
    vim.wait(300)
    H.eq({}, ran)
    H.eq(1, calls.n)
    trust.trust(ws)
    wt._reset()
    require("config.test_ui").run_doctests()
    H.wait_for(function()
      return #ran == 1
    end, 3000)
    H.match(ran[1], "cargo test --doc", true)
    H.eq(1, calls.n, "no second prompt")
  end)
end)

describe("the debug build before a launch (dap.lua build_current_binary)", function()
  before_each(needs_trust)
  local function program()
    local h = require("lazy.core.plugin").values(
      require("lazy.core.config").plugins["mason-nvim-dap.nvim"],
      "opts",
      false
    ).handlers
    stub(require("mason-nvim-dap"), "default_setup", function() end)
    h.codelldb({})
    for _, c in ipairs(require("dap").configurations.rust) do
      if c.name == "Rust: run current package binary (args prompt)" then
        return c.program
      end
    end
    error("configuration not found")
  end

  it("untrusted, outside a coroutine: aborts without building (no way to ask there)", function()
    crate()
    local ran = spy()
    local prog = program()
    H.eq(require("dap").ABORT, prog())
    H.eq({}, ran)
  end)

  it("untrusted, inside nvim-dap's coroutine: asks, refused aborts, 'trust' builds", function()
    local ws = crate()
    local ran = spy()
    local prog = program()
    local calls = ui("no")
    local out
    local co = coroutine.create(function()
      out = prog()
    end)
    assert(coroutine.resume(co))
    H.wait_for(function()
      return coroutine.status(co) == "dead"
    end, 3000, "coroutine finished")
    H.eq(require("dap").ABORT, out)
    H.eq({}, ran)
    H.eq(1, calls.n)
    undo[#undo]() -- restore the prompt stub
    undo[#undo - 1]()
    ui("trust")
    out = nil
    co = coroutine.create(function()
      out = prog()
    end)
    assert(coroutine.resume(co))
    H.wait_for(function()
      return coroutine.status(co) == "dead"
    end, 3000, "second coroutine finished")
    H.eq(1, #ran)
    H.match(ran[1], "cargo build --package", true)
    H.ok(trust.is_trusted(ws))
  end)

  it("trusted: builds without a prompt, in or out of a coroutine", function()
    local ws = crate()
    trust.trust(ws)
    local ran = spy()
    local prog = program()
    prog()
    H.eq(1, #ran)
  end)
end)

describe("rustaceanvim runnables / testables / debuggables", function()
  before_each(needs_trust)
  it("the executors and dap.start are wrapped: untrusted + refused runs nothing, trusted runs", function()
    local ws = crate()
    wt.install()
    local jobs = {}
    stub(vim.fn, "jobstart", function(cmd)
      jobs[#jobs + 1] = cmd
      return 1
    end)
    local ran = spy()
    local calls = ui("no")
    local ex = require("rustaceanvim.executors")
    ex.termopen.execute_command("cargo", { "test", "--package", "basic" }, ws, {})
    ex.background.execute_command("cargo", { "build" }, ws, {})
    require("rustaceanvim.dap").start({ cargoArgs = { "build" }, workspaceRoot = ws }, false, function() end)
    vim.wait(300)
    H.eq({}, jobs)
    H.eq({}, ran)
    H.ok(calls.n >= 1, "asked")
    for _, name in ipairs({ "termopen", "quickfix", "toggleterm", "vimux", "background" }) do
      H.ok(wt.is_guarded(ex[name].execute_command), name .. " is guarded")
    end
    H.ok(wt.is_guarded(require("rustaceanvim.dap").start), "dap.start is guarded")
    -- trusted: through
    trust.trust(ws)
    wt._reset()
    ex.termopen.execute_command("cargo", { "test" }, ws, {})
    H.wait_for(function()
      return #jobs == 1
    end, 2000, "the executor ran after trust")
  end)

  it("install is idempotent", function()
    crate()
    wt.install()
    local f = require("rustaceanvim.executors").termopen.execute_command
    wt.install()
    H.eq(f, require("rustaceanvim.executors").termopen.execute_command)
  end)
end)

describe("neotest runs", function()
  before_each(needs_trust)
  local function fake_client(ran)
    return {
      run_tree = function(_, tree)
        ran[#ran + 1] = tree:data().path
      end,
    }
  end
  local function tree(path)
    return {
      data = function()
        return { path = path, id = path }
      end,
    }
  end
  local function in_nio(fn)
    local done = false
    require("nio").run(function()
      fn()
      done = true
    end)
    H.wait_for(function()
      return done
    end, 3000, "nio task finished")
  end

  it("the neotest consumer list contains the guard", function()
    local opts = require("lazy.core.plugin").values(require("lazy.core.config").plugins["neotest"], "opts", false)
    H.eq("function", type(opts.consumers.xyno_trust), "plugins/neotest.lua registers consumers.xyno_trust")
  end)

  it("untrusted + refused: the run is not started; 'trust': started; trusted: no prompt", function()
    local ws = crate()
    local ran = {}
    local client = fake_client(ran)
    wt.guard_neotest(client)
    local calls = ui("no")
    in_nio(function()
      client:run_tree(tree(ws .. "/src/lib.rs"), {})
    end)
    H.eq({}, ran)
    H.eq(1, calls.n)
    undo[#undo]()
    undo[#undo - 1]()
    ui("trust")
    in_nio(function()
      client:run_tree(tree(ws .. "/src/lib.rs"), {})
    end)
    H.eq({ ws .. "/src/lib.rs" }, ran)
    local calls3 = ui("no")
    in_nio(function()
      client:run_tree(tree(ws .. "/src/lib.rs"), {})
    end)
    H.eq(2, #ran)
    H.eq(0, calls3.n)
  end)

  it("a path outside any cargo workspace runs without asking", function()
    local ran = {}
    local client = fake_client(ran)
    wt.guard_neotest(client)
    local calls = ui("no")
    local lone = H.tmpdir() .. "/lone.rs"
    write(lone, "fn main() {}\n")
    in_nio(function()
      client:run_tree(tree(lone), {})
    end)
    H.eq(1, #ran)
    H.eq(0, calls.n)
  end)
end)

describe("cargo-deny / cargo-machete linters (they run `cargo metadata` with the project's rustc wrapper)", function()
  before_each(needs_trust)
  it("are skipped in an untrusted workspace, run in a trusted one", function()
    local ws = crate()
    write(ws .. "/deny.toml", "")
    local linters =
      require("lazy.core.plugin").values(require("lazy.core.config").plugins["nvim-lint"], "opts", false).linters
    local ctx = { filename = ws .. "/Cargo.toml", dirname = ws }
    H.eq(false, linters.cargo_deny.condition(ctx))
    H.eq(false, linters.cargo_machete.condition(ctx))
    trust.trust(ws)
    wt._reset()
    H.eq(true, linters.cargo_deny.condition(ctx))
    H.eq(true, linters.cargo_machete.condition(ctx))
  end)
end)

-- ------------------------------------------------------------------ S3: the gate itself

describe("the gate decides per case", function()
  it("no cargo workspace (a lone .rs file): allowed, nothing to run", function()
    H.ok(wt.trusted(nil))
    H.ok(wt.allowed(nil))
    local dir = H.tmpdir() .. "/lone"
    write(dir .. "/x.rs", "fn main() {}\n")
    H.eq(nil, wt.workspace(dir .. "/x.rs"))
  end)

  it(
    "no trust store at all (plugin module and vendored fallback missing) + a Cargo.toml up the tree: UNTRUSTED (fail closed); without Cargo.toml: trusted",
    function()
      local ws = H.fixture("basic")
      for _, name in ipairs({ "xyno_rust.trust", "xynovim.trust_fallback" }) do
        local saved = package.loaded[name]
        package.loaded[name] = nil
        local preload = package.preload[name]
        package.preload[name] = function()
          error("module '" .. name .. "' not found")
        end
        on_undo(function()
          package.loaded[name], package.preload[name] = saved, preload
        end)
      end
      wt._reset()
      H.eq(false, wt.trusted(ws), "restricted: the gate cannot ask, so it holds back")
      H.eq(false, wt.allowed(ws))
      local ran = spy()
      local denied
      wt.require(ws, "cargo test", function(ok)
        denied = not ok
      end)
      H.eq(true, denied)
      local s = wt.settings_for(ws, { ["rust-analyzer"] = {} })["rust-analyzer"]
      H.eq(false, s.procMacro.enable)
      H.eq(false, s.cargo.buildScripts.enable)
      H.eq(false, wt.allow_bacon(ws))
      H.eq({}, ran)
      local lone = H.tmpdir() .. "/lone"
      write(lone .. "/x.rs", "fn main() {}\n")
      H.ok(wt.trusted(lone))
      vim.g.xynovim_workspace_trust = false
      H.ok(wt.trusted(ws), "the explicit switch-off still wins")
    end
  )

  describe("content changes", function()
    before_each(function()
      if not HAS_DRIFT then
        skip("the pinned xyno-rust.nvim has no content fingerprint (api 1.3); runs with XYNOVIM_DEV_PLUGINS")
      end
    end)
    local function trusted_ws()
      local ws = H.fixture("basic")
      trust.trust(ws)
      wt._reset()
      return ws
    end

    it("a changed build.rs / Cargo.toml / .cargo/config.toml / rust-toolchain asks again, naming the file", function()
      for _, case in ipairs({
        { "build.rs", 'fn main() { println!("cargo:warning=x"); }\n' },
        { ".cargo/config.toml", '[build]\nrustc-wrapper = "/bin/true"\n' },
        { "rust-toolchain.toml", '[toolchain]\nchannel = "stable"\n' },
        { "Cargo.toml", '[package]\nname = "basic"\nversion = "9.9.9"\nedition = "2021"\n' },
      }) do
        local ws = trusted_ws()
        H.ok(wt.allowed(ws), "trusted before " .. case[1])
        write(ws .. "/" .. case[1], case[2])
        wt._reset()
        H.eq(false, wt.allowed(ws), case[1] .. " changed -> not allowed")
        local calls = ui("no")
        local verdict
        wt.require(ws, "cargo test", function(ok)
          verdict = ok
        end)
        H.eq(false, verdict)
        H.eq(1, calls.n)
        H.match(calls.prompts[1], "changed since", true)
        H.match(calls.prompts[1], case[1], true)
        undo[#undo]()
        undo[#undo - 1]()
        trust.revoke(ws)
      end
    end)

    it("rust-analyzer restarts restricted on focus after a pull changed build.rs (drift while trusted)", function()
      local ws = trusted_ws()
      local o =
        require("lazy.core.plugin").values(require("lazy.core.config").plugins["rustaceanvim"], "opts", false).server
      local s = o.settings(ws, vim.deepcopy(o.default_settings))["rust-analyzer"]
      H.ok(s.procMacro.enable ~= false, "trusted: full settings")
      write(ws .. "/build.rs", "fn main() {}\n")
      H.eq(false, wt.recheck(ws), "recheck reports the workspace as no longer trusted")
      local s2 = o.settings(ws, vim.deepcopy(o.default_settings))["rust-analyzer"]
      H.eq(false, s2.procMacro.enable)
    end)

    it("saving Cargo.toml in nvim does not ask; a pulled build.rs next to it still does", function()
      local ws = trusted_ws()
      wt.setup()
      vim.cmd.edit(vim.fn.fnameescape(ws .. "/Cargo.toml"))
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(
        buf,
        0,
        -1,
        false,
        { "[package]", 'name = "basic"', 'version = "0.5.0"', 'edition = "2021"' }
      )
      vim.cmd("silent write")
      wt._reset()
      H.ok(wt.allowed(ws), "an in-editor save is not a surprise")
      write(ws .. "/build.rs", "fn main() {}\n")
      vim.api.nvim_buf_set_lines(
        buf,
        0,
        -1,
        false,
        { "[package]", 'name = "basic"', 'version = "0.6.0"', 'edition = "2021"' }
      )
      vim.cmd("silent write")
      wt._reset()
      H.eq(false, wt.allowed(ws), "build.rs changed behind the editor's back")
    end)
  end)
end)

-- ------------------------------------------------------------------ the proof: no spawn is missed

describe("source scan: every spawn of cargo / rustc / an unknown command is gated or listed as read-only", function()
  local function lua_files()
    return vim.fn.glob(H.repo .. "/lua/**/*.lua", true, true)
  end

  -- a spawn call
  local SPAWN = {
    "vim%.system%(",
    "jobstart%(",
    "termopen%(",
    "Snacks%.terminal",
    "fn%.system%(",
    "fn%.systemlist%(",
    "io%.popen%(",
    "os%.execute%(",
    "uv%.spawn%(",
    "vim%.cmd%.terminal",
    "vim%.cmd%([\"']%s*:?terminal",
    "nvim_open_term",
  }
  -- the tools that run project code
  local RUNS_CODE =
    { "cargo", "rustc", "rustup", "rust%-analyzer", "bacon", "cargo%-[%w%-]+", "rustfmt", "clippy%-driver" }

  local function spawns(line)
    for _, p in ipairs(SPAWN) do
      if line:find(p) then
        return true
      end
    end
    return false
  end

  --- A line that starts a process which is not obviously a non-Rust tool: cargo/rustc/... as the literal
  --- command, or a command held in a variable.
  local function suspicious(line)
    if line:match("^%s*%-%-") or line:find('{ "--version" }', 1, true) then
      return false -- a comment, or a table row of `--version` probes (health.lua)
    end
    if spawns(line) then
      local literal = line:match("%(%s*{%s*[\"']([^\"']+)[\"']")
      if literal then
        for _, t in ipairs(RUNS_CODE) do
          if literal:match("^" .. t .. "$") then
            return true
          end
        end
        return false
      end
      -- a command in a variable / a string command line
      return true
    end
    -- a command table built for a later spawn
    for _, t in ipairs(RUNS_CODE) do
      if line:match("{%s*[\"']" .. t .. "[\"']%s*[,}]") or line:match("cmd%s*=%s*[\"']" .. t .. "[\"']") then
        return true
      end
    end
    return false
  end

  it("scans every Lua source and finds the known call sites (the scan itself is not vacuous)", function()
    local seen = {}
    for _, f in ipairs(lua_files()) do
      local lines = vim.fn.readfile(f)
      for _, l in ipairs(lines) do
        if suspicious(l) then
          seen[vim.fs.basename(f)] = (seen[vim.fs.basename(f)] or 0) + 1
        end
      end
    end
    for _, must in ipairs({ "coverage.lua", "test_ui.lua", "dap.lua", "supply-chain.lua", "rust_assist.lua" }) do
      H.ok(seen[must], must .. " has spawns the scan sees")
    end
  end)

  it(
    "each one is routed through config.workspace_trust (within 60 lines above / 40 below) or says `trust: read-only <why>`",
    function()
      local offenders = {}
      for _, f in ipairs(lua_files()) do
        local rel = f:sub(#H.repo + 2)
        if rel ~= "lua/config/workspace_trust.lua" then
          local lines = vim.fn.readfile(f)
          for i, l in ipairs(lines) do
            if suspicious(l) then
              local annotated = l:find("trust: read%-only") or (lines[i - 1] or ""):find("trust: read%-only")
              local gated = false
              for j = math.max(1, i - 60), math.min(#lines, i + 40) do
                if (lines[j] or ""):find("workspace_trust") then
                  gated = true
                end
              end
              if not (annotated or gated) then
                offenders[#offenders + 1] = ("%s:%d: %s"):format(rel, i, vim.trim(l))
              end
            end
          end
        end
      end
      H.eq(
        {},
        offenders,
        "ungated spawns of cargo/rustc (gate with config.workspace_trust or annotate `-- trust: read-only <why>`)"
      )
    end
  )

  it("read-only annotations carry a reason and only appear on tools that do not build", function()
    for _, f in ipairs(lua_files()) do
      for i, l in ipairs(f:match("workspace_trust%.lua$") and {} or vim.fn.readfile(f)) do
        local why = l:match("trust: read%-only%s*(.*)$")
        if why then
          H.ok(#vim.trim(why) >= 10, ("%s:%d: say why it is read-only"):format(f, i))
          H.no_match(l, 'cargo", "build', true)
          H.no_match(l, '"test"', true)
        end
      end
    end
  end)

  it("a spawn added behind the gate's back is caught (the scan flags a synthetic offender)", function()
    H.ok(suspicious('  vim.system({ "cargo", "build" }, { cwd = root })'))
    H.ok(suspicious("  vim.fn.jobstart(cmd, {})"))
    H.ok(suspicious('  local cmd = { "cargo", "test" }'))
    H.not_ok(suspicious('  vim.system({ "git", "status" }, {})'))
    H.not_ok(suspicious('  -- vim.system({ "cargo", "build" })'))
  end)
end)
