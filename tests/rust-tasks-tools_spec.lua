-- xyno_rust.rust_tasks (:RustTargets, :RustTools, :ActJob, :RustNew, doctests) and
-- lua/plugins/coverage.lua (<leader>tc, nvim-coverage opts, lcov backend).
-- Snacks.picker / Snacks.terminal / vim.ui / vim.system are stubbed where the
-- spec only needs to see what would run; real cargo is used for metadata,
-- `cargo new` and the one end-to-end coverage run.
local H = require("xynotest.helpers")
local rc = require("xyno_rust.rust_context")
local tasks = require("xyno_rust.rust_tasks")

-- ------------------------------------------------------------------- stubs

local restores = {}

--- Replace t[k] by v until the end of the test.
local function stub(t, k, v)
  local orig = t[k]
  t[k] = v
  restores[#restores + 1] = function()
    t[k] = orig
  end
end

local function unstub_all()
  for i = #restores, 1, -1 do
    pcall(restores[i])
  end
  restores = {}
end

after_each(function()
  unstub_all()
  pcall(vim.cmd, "silent! %bwipeout!")
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
end)

--- Stub the stored :RustContext of every root.
local function with_ctx(ctx)
  stub(rc, "get", function()
    return ctx
  end)
end

--- The item of a picker whose text starts with `prefix`.
local function item(opts, prefix)
  for _, it in ipairs(opts.items) do
    if it.text:sub(1, #prefix) == prefix then
      return it
    end
  end
  error(
    ("no picker item starting with %q in %s"):format(
      prefix,
      vim.inspect(vim.tbl_map(function(i)
        return i.text
      end, opts.items))
    ),
    2
  )
end

--- Copy of the `all` fixture (lib, bin `tool`, example, test, bench; features
--- default=[a], a, b) as the current directory and buffer.
local function open_all()
  return H.open_fixture("rust-tasks-tools-all", "src/main.rs")
end

--- A buffer in a directory with no Cargo.toml above it.
local function open_outside_crate()
  local dir = H.tmpdir()
  vim.cmd.cd(vim.fn.fnameescape(dir))
  vim.fn.writefile({ "x" }, dir .. "/note.txt")
  H.open(dir .. "/note.txt")
  return dir
end

local function wait_notify(cap, pat, ms)
  return H.wait_for(function()
    for _, n in ipairs(cap.list) do
      if n.msg:find(pat, 1, true) then
        return n
      end
    end
  end, ms or 5000, "notification " .. pat)
end

-- ============================================================ 1. commands

-- ===================================================== 2. targets: errors

-- ================================================ 3-6. targets: the items

-- ============================================================ 7. term()

-- ================================================================ 8. new

-- =========================================================== 9-10. tools

-- ============================================================== 11. act

-- ========================================================== 12. doctests

-- ==================================================== 13. <leader>tc run

describe("<leader>tc (coverage run)", function()
  local function tc()
    require("lazy").load({ plugins = { "nvim-coverage" } })
    local m = vim.fn.maparg("<leader>tc", "n", false, true)
    return H.ok(m.callback, "<leader>tc has no Lua callback")
  end

  --- Stub vim.system (captures cargo llvm-cov), vim.fn.executable (nextest) and
  --- vim.cmd (CoverageLoad/Show recorded, everything else real).
  local function harness(nextest)
    local cap = { cmds = {} }
    local real_system = vim.system
    stub(vim, "system", function(cmd, opts, cb)
      if cmd[1] ~= "cargo" or cmd[2] ~= "llvm-cov" then -- the LSP clients use vim.system too
        return real_system(cmd, opts, cb)
      end
      cap.sys = { cmd = cmd, opts = opts }
      cap.done = cb
      return {}
    end)
    local real_exec = vim.fn.executable
    stub(vim.fn, "executable", function(name)
      if name == "cargo-nextest" then
        return nextest and 1 or 0
      end
      return real_exec(name)
    end)
    local real_cmd = vim.cmd
    stub(
      vim,
      "cmd",
      setmetatable({}, {
        __call = function(_, c, ...)
          if c == "CoverageLoad" or c == "CoverageShow" then
            cap.cmds[#cap.cmds + 1] = c
            return
          end
          return real_cmd(c, ...)
        end,
        __index = real_cmd,
      })
    )
    return cap
  end

  --- Complete the stubbed cargo run. Noice replaces vim.notify from a scheduled
  --- callback queued by VeryLazy, so let the event queue drain and install the
  --- capture again before the run's own scheduled callback. Returns the capture.
  local function finish(cap, res)
    vim.wait(300)
    local n = H.capture_notify()
    cap.done(vim.tbl_extend("force", { code = 0, stdout = "", stderr = "" }, res or {}))
    return n
  end

  it("runs cargo llvm-cov nextest with the lcov output + context flags in the workspace root", function()
    H.need_rust()
    local fn = tc()
    with_ctx({ all = false, features = { "a" }, target = "x86_64-unknown-linux-gnu" })
    local dir = open_all()
    local n = H.capture_notify()
    local cap = harness(true)
    fn()
    local expected = {
      "cargo", "llvm-cov", "nextest", "--workspace", "--ignore-run-fail", "--lcov", "--output-path", "target/lcov.info",
      "--features", "a", "--target", "x86_64-unknown-linux-gnu",
    }
    H.eq(expected, cap.sys.cmd)
    H.eq(dir, cap.sys.opts.cwd)
    H.eq(true, cap.sys.opts.text)
    H.eq("coverage: running " .. table.concat(expected, " "), n.list[1].msg)
  end)

  it("leaves nextest out when cargo-nextest is not executable", function()
    H.need_rust()
    local fn = tc()
    with_ctx(nil)
    open_all()
    H.capture_notify()
    local cap = harness(false)
    fn()
    H.eq({
      "cargo", "llvm-cov", "--workspace", "--ignore-run-fail", "--lcov", "--output-path", "target/lcov.info", "--all-features",
    }, cap.sys.cmd)
  end)

  it("on exit 0 loads and shows the coverage and says where it came from", function()
    H.known_issue({ "macos" }, "coverage run specs hang on macos-latest (run 39655339161: file timed out after 240 s; cause not diagnosed)")
    H.need_rust()
    local fn = tc()
    with_ctx(nil)
    local dir = open_all()
    local n = H.capture_notify()
    local cap = harness(true)
    fn()
    n = finish(cap)
    wait_notify(n, "coverage loaded")
    H.eq({ "CoverageLoad", "CoverageShow" }, cap.cmds)
    H.eq("coverage loaded (" .. dir .. "/target/lcov.info)", n.list[#n.list].msg)
    for _, x in ipairs(n.list) do
      H.not_ok(x.level == vim.log.levels.WARN, "no warning when the tests passed: " .. x.msg)
    end
  end)

  it("warns that tests failed (nextest and cargo test wording) but still loads the report", function()
    H.known_issue({ "macos" }, "coverage run notification timed out after 183 s on macos-latest (run 39647013043; cause not diagnosed)")
    H.need_rust()
    local fn = tc()
    with_ctx(nil)
    open_all()
    local variants = {
      { stderr = "Summary 3 tests run: 2 passed, 1 failed, 0 skipped" },
      { stdout = "test result: FAILED. 0 passed; 2 failed; 0 ignored" },
    }
    for _, res in ipairs(variants) do
      local n = H.capture_notify()
      local cap = harness(true)
      fn()
      n = finish(cap, res)
      local w = wait_notify(n, "coverage: some tests FAILED (the report is still written)")
      H.eq(vim.log.levels.WARN, w.level)
      H.eq({ "CoverageLoad", "CoverageShow" }, cap.cmds)
      n.restore()
      unstub_all()
      with_ctx(nil)
    end
  end)

  it("does not warn for '0 failed'", function()
    H.known_issue({ "macos" }, "coverage run specs hang on macos-latest (run 39655339161: file timed out after 240 s; cause not diagnosed)")
    H.need_rust()
    local fn = tc()
    with_ctx(nil)
    open_all()
    local n = H.capture_notify()
    local cap = harness(true)
    fn()
    n = finish(cap, { stderr = "test result: ok. 3 passed; 0 failed; 0 ignored" })
    wait_notify(n, "coverage loaded")
    for _, x in ipairs(n.list) do
      H.no_match(x.msg, "FAILED", true)
    end
  end)

  it("a non-zero exit is an ERROR with the last 600 chars of stderr and loads nothing", function()
    H.known_issue({ "macos" }, "coverage run specs hang on macos-latest (run 39655339161: file timed out after 240 s; cause not diagnosed)")
    H.need_rust()
    local fn = tc()
    with_ctx(nil)
    open_all()
    local n = H.capture_notify()
    local cap = harness(true)
    fn()
    local err = ("x"):rep(500) .. ("0123456789"):rep(70) -- 1200 chars
    n = finish(cap, { code = 101, stderr = err })
    local e = wait_notify(n, "coverage run failed:")
    H.eq(vim.log.levels.ERROR, e.level)
    H.eq("coverage run failed:\n" .. err:sub(-600), e.msg)
    H.eq({}, cap.cmds)
  end)

  it("warns without a crate and runs nothing", function()
    local fn = tc()
    open_outside_crate()
    local n = H.capture_notify()
    local cap = harness(true)
    fn()
    H.is_nil(cap.sys)
    H.eq("no Cargo.toml found", n.list[1].msg)
    H.eq(vim.log.levels.WARN, n.list[1].level)
  end)
end)

-- ================================================== 14. plugin options

describe("nvim-coverage options", function()
  it("sets auto_reload, commands and the opaque, smaller summary window", function()
    require("lazy").load({ plugins = { "nvim-coverage" } })
    local o = require("coverage.config").opts
    H.eq(true, o.auto_reload)
    H.eq(true, o.commands)
    H.eq(0, o.summary.window.winblend)
    H.eq(0.6, o.summary.width_percentage)
    H.eq(0.4, o.summary.height_percentage)
  end)

  it("is lazy loaded on the seven Coverage commands and the <leader>tc/tg/tG keys", function()
    local plugin = require("lazy.core.config").plugins["nvim-coverage"]
    H.ok(plugin, "nvim-coverage is not in the lazy spec")
    local cmds = vim.deepcopy(plugin.cmd)
    table.sort(cmds)
    H.eq({ "Coverage", "CoverageClear", "CoverageHide", "CoverageLoad", "CoverageShow", "CoverageSummary", "CoverageToggle" }, cmds)
    local keys = {}
    for _, k in ipairs(plugin.keys or {}) do
      keys[k.lhs or k[1]] = true
    end
    for _, lhs in ipairs({ "<leader>tc", "<leader>tg", "<leader>tG" }) do
      H.ok(keys[lhs], lhs .. " missing from the plugin keys")
    end
  end)
end)

-- ================================================= 15. the rust backend

describe("coverage rust backend (lcov instead of grcov)", function()
  local function load_plugin()
    require("lazy").load({ plugins = { "nvim-coverage" } })
  end

  local function write_lcov(root, lines)
    local out = { "TN:", "SF:" .. root .. "/src/lib.rs" }
    local hit = 0
    for _, l in ipairs(lines) do
      out[#out + 1] = ("DA:%d,%d"):format(l[1], l[2])
      hit = hit + (l[2] > 0 and 1 or 0)
    end
    vim.list_extend(out, { "LF:" .. #lines, "LH:" .. hit, "end_of_record" })
    vim.fn.mkdir(root .. "/target", "p")
    vim.fn.writefile(out, root .. "/target/lcov.info")
  end

  local function placed(buf)
    return vim.fn.sign_getplaced(buf, { group = "coverage" })[1].signs
  end

  after_each(function()
    pcall(vim.cmd, "CoverageClear")
  end)

  it("replaces coverage.languages.rust with sign_list, summary and load", function()
    load_plugin()
    local m = package.loaded["coverage.languages.rust"]
    H.eq("function", type(m.sign_list))
    H.eq("function", type(m.summary))
    H.eq("function", type(m.load))
    local common = require("coverage.languages.common")
    H.eq(common.sign_list, m.sign_list)
    H.eq(common.summary, m.summary)
  end)

  it("coverage_file is <root>/target/lcov.info, or the cwd's when there is no crate", function()
    H.need_rust()
    load_plugin()
    local f = require("coverage.config").opts.lang.rust.coverage_file
    H.eq("function", type(f))
    local dir = open_all()
    H.eq(dir .. "/target/lcov.info", f())
    open_outside_crate()
    H.eq(vim.uv.cwd() .. "/target/lcov.info", f())
  end)

  it("a missing coverage file is an INFO hint, not an error", function()
    load_plugin()
    local dir = H.fixture("rust-tasks-tools-cov")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    H.open(dir .. "/src/lib.rs")
    H.eq("rust", vim.bo.filetype)
    local n = H.capture_notify()
    vim.cmd("CoverageLoad")
    H.eq(1, #n.list)
    H.eq("No coverage file (target/lcov.info); run <leader>tc", n.list[1].msg)
    H.eq(vim.log.levels.INFO, n.list[1].level)
  end)

  it("loads target/lcov.info: signs are placed on the covered lines and CoverageSummary shows 100%", function()
    load_plugin()
    local dir = H.fixture("rust-tasks-tools-cov")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/src/lib.rs")
    write_lcov(dir, { { 1, 1 }, { 2, 1 }, { 3, 1 }, { 9, 1 } })
    vim.cmd("Coverage") -- load + place
    local s = placed(buf)
    H.eq(4, #s)
    local lines = vim.tbl_map(function(x)
      return x.lnum
    end, s)
    table.sort(lines)
    H.eq({ 1, 2, 3, 9 }, lines)
    for _, x in ipairs(s) do
      H.eq("coverage_covered", x.name)
    end
    vim.cmd("CoverageSummary")
    local text
    H.wait_for(function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          local t = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
          if t:find("Total", 1, true) then
            text = t
            return true
          end
        end
      end
    end, 5000, "the summary float")
    H.match(text, "100%%")
    H.match(text, "lib.rs", true) -- the path is shortened to fit the column
  end)

  it("marks missed lines as uncovered", function()
    load_plugin()
    local dir = H.fixture("rust-tasks-tools-cov")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/src/lib.rs")
    write_lcov(dir, { { 1, 1 }, { 2, 0 } })
    vim.cmd("Coverage")
    local by = {}
    for _, x in ipairs(placed(buf)) do
      by[x.lnum] = x.name
    end
    H.eq({ [1] = "coverage_covered", [2] = "coverage_uncovered" }, by)
  end)
end)

-- ================================================== 16. end to end (slow)

describe("<leader>tc end to end (optional, slow)", function()
  it("a real cargo llvm-cov run writes target/lcov.info and places the signs", function()
    H.need_rust()
    if vim.system({ "cargo", "llvm-cov", "--version" }):wait(20000).code ~= 0 then
      H.skip_file("cargo-llvm-cov not installed")
    end
    if vim.fn.executable("cargo-nextest") ~= 1 then
      H.skip_file("cargo-nextest not installed")
    end
    require("lazy").load({ plugins = { "nvim-coverage" } })
    local dir = H.fixture("rust-tasks-tools-cov")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/src/lib.rs")
    local n = H.capture_notify()
    local m = vim.fn.maparg("<leader>tc", "n", false, true)
    H.ok(m.callback)
    m.callback()
    H.wait_for(function()
      for _, x in ipairs(n.list) do
        if x.msg:find("coverage loaded", 1, true) or x.msg:find("coverage run failed", 1, true) then
          return true
        end
      end
    end, 300000, "the coverage run to finish")
    for _, x in ipairs(n.list) do
      if x.msg:find("coverage run failed", 1, true) then
        if x.msg:find("llvm-tools", 1, true) or x.msg:find("llvm-profdata", 1, true) then
          H.skip_file("llvm-tools missing: " .. x.msg:sub(1, 200))
        end
        error(x.msg)
      end
    end
    H.eq(1, vim.fn.filereadable(dir .. "/target/lcov.info"))
    H.has(table.concat(vim.fn.readfile(dir .. "/target/lcov.info"), "\n"), dir .. "/src/lib.rs")
    local s = vim.fn.sign_getplaced(buf, { group = "coverage" })[1].signs
    H.ok(#s > 0, "signs were placed")
    local lines = vim.tbl_map(function(x)
      return x.lnum
    end, s)
    H.has(lines, 2, "the body of add() is covered")
    pcall(vim.cmd, "CoverageClear")
  end)
end)

-- ============================================ 17. profiling profile (info)

