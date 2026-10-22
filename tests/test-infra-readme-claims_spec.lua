-- The test infrastructure itself (scripts/test.sh, scripts/coverage.lua,
-- tests/{harness,helpers,runner,coverage_hook}.lua, Makefile) and the claims
-- README.md / CHANGELOG.md make about it and about the config.
--
-- scripts/test.sh is exercised for real: a throwaway checkout ("fake repo":
-- symlinks to the real lua/, colors/, ... plus COPIES of the scripts, tests
-- helpers, lazy-lock.json and lazyvim.json, so nothing here can write into the
-- real checkout) gets throwaway specs, and test.sh is run against it. Runs are
-- memoised, each `it` asserts one claim of the output. The hanging spec is
-- killed after --timeout 30.
-- xyno-os: linux (runs scripts/test.sh, which needs GNU timeout and process groups)
local H = require("xynotest.helpers")
local harness = require("xynotest.harness")

local repo = H.repo
local uv = vim.uv

-- ------------------------------------------------------------------ helpers

local function read(path)
  local f = assert(io.open(path, "rb"), "cannot read " .. path)
  local s = f:read("*a")
  f:close()
  return s
end

local function write(path, s)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

local function sh(cmd, opts)
  opts = opts or {}
  opts.text = true
  local obj = vim.system(cmd, opts)
  local r = obj:wait(opts.wait or 240000)
  r.pid = obj.pid
  r.out = (r.stdout or "") .. (r.stderr or "")
  return r
end

--- nested test.sh runs must not inherit the outer run's per-process state
local CLEAN = { "/usr/bin/env", "-u", "XYNO_SPEC", "-u", "XYNO_COV_OUT", "-u", "XYNO_TMUX_PREFIX", "-u", "XYNO_COV_ROOTS" }

--- bash <script> [args...] with the clean environment; returns the sh() result
local function bash(script, args, env, cwd)
  local cmd = vim.list_extend({}, CLEAN)
  vim.list_extend(cmd, { "/usr/bin/bash", script })
  vim.list_extend(cmd, args or {})
  return sh(cmd, { env = env, cwd = cwd or "/" })
end

local function alive(pid)
  local f = io.open("/proc/" .. pid .. "/stat")
  if not f then
    return false
  end
  local s = f:read("*a")
  f:close()
  return s:match("%) (%a)") ~= "Z"
end

local function wait_dead(pid)
  return vim.wait(4000, function()
    return not alive(pid)
  end, 50)
end

--- A throwaway checkout of the config with its own scripts/ and tests/ files.
--- copy_lua: real copies of lua/ colors/ plugin/ after/ (scripts/coverage.lua
--- uses `find`, which does not follow symlinks).
local function build_fake(copy_lua)
  local dir = H.tmpdir() .. "/xynovim"
  vim.fn.mkdir(dir .. "/scripts", "p")
  vim.fn.mkdir(dir .. "/tests", "p")
  local copy = { lua = true, colors = true, plugin = true, after = true }
  for _, name in ipairs(vim.fn.readdir(repo)) do
    if not vim.tbl_contains({ ".git", ".github", ".remember", "tests", "scripts", "lazy-lock.json", "lazyvim.json" }, name) then
      if copy_lua and copy[name] then
        assert(sh({ "cp", "-a", repo .. "/" .. name, dir .. "/" .. name }).code == 0)
      else
        assert(uv.fs_symlink(repo .. "/" .. name, dir .. "/" .. name))
      end
    end
  end
  for _, f in ipairs({ "lazy-lock.json", "lazyvim.json" }) do
    assert(uv.fs_copyfile(repo .. "/" .. f, dir .. "/" .. f))
  end
  for _, f in ipairs({ "test.sh", "coverage.lua" }) do
    assert(uv.fs_copyfile(repo .. "/scripts/" .. f, dir .. "/scripts/" .. f))
  end
  for _, f in ipairs({ "runner.lua", "harness.lua", "helpers.lua", "coverage_hook.lua" }) do
    assert(uv.fs_copyfile(repo .. "/tests/" .. f, dir .. "/tests/" .. f))
  end
  assert(uv.fs_symlink(repo .. "/tests/fixtures", dir .. "/tests/fixtures"))
  return dir
end

local fake_dir
local function fake_repo()
  fake_dir = fake_dir or build_fake(false)
  return fake_dir
end

--- tmux leaves the socket file of a server that was killed by a signal behind
local function rm_socket(name)
  local uid = vim.trim(vim.fn.system({ "id", "-u" }))
  vim.fn.delete(((vim.env.TMUX_TMPDIR or "/tmp") .. "/tmux-" .. uid .. "/" .. name))
end

--- parse "STATUS tests/x_spec.lua  N passed, N failed, N skipped (Ns)" rows
local function rows(out)
  local t = {}
  for line in out:gmatch("[^\n]+") do
    local st, f, p, fl, sk = line:match("^(%u+)%s+(tests/%S+)%s+(%d+) passed, (%d+) failed, (%d+) skipped %(%d+s%)$")
    if st then
      t[vim.fs.basename(f)] = { status = st, passed = tonumber(p), failed = tonumber(fl), skipped = tonumber(sk), line = line }
    end
  end
  return t
end

-- Run A: every kind of spec through test.sh -------------------------------

local SPECS_A = {
  ["a_hang_spec.lua"] = [[
local dump = vim.env.XYNO_DUMP
it("hangs", function()
  local f = io.open(dump .. "/hang.pid", "w")
  f:write(vim.fn.getpid())
  f:close()
  while true do end
end)
]],
  ["b_fail_spec.lua"] = [[
local H = require("xynotest.helpers")
describe("grp", function()
  it("fine", function() end)
  it("breaks", function() H.eq(1, 2, "numbers") end)
end)
]],
  ["c_load_spec.lua"] = [[
error("boom at load")
]],
  ["d_pass_spec.lua"] = [[
describe("grp", function()
  it("a", function() end)
  it("b", function() end)
  it("skipper", function() skip("no gizmo") end)
  pending("pend", "not ready")
end)
]],
  ["e_skipfile_spec.lua"] = [[
require("xynotest.helpers").skip_file("nothing to do here")
it("never registered", function() error("must not run") end)
]],
  ["f_crash_spec.lua"] = [[
it("dies", function() os.exit(3) end)
]],
  ["g_lock_spec.lua"] = [[
it("touches the lockfile", function()
  local f = assert(io.open(vim.fn.stdpath("config") .. "/lazy-lock.json", "a"))
  f:write("\n")
  f:close()
end)
]],
  ["h_leak_spec.lua"] = [[
it("leaves a process and a tmux server behind", function()
  local dump = vim.env.XYNO_DUMP
  os.execute(("sleep 303 </dev/null >/dev/null 2>&1 & echo $! > %s/sleep.pid"):format(dump))
  if vim.fn.executable("tmux") == 1 then
    local sock = vim.env.XYNO_TMUX_PREFIX .. "-raw"
    os.execute(("tmux -L %s new-session -d 'sleep 304' </dev/null >/dev/null 2>&1"):format(sock))
    local f = io.open(dump .. "/tmux.sock", "w")
    f:write(sock)
    f:close()
  end
end)
]],
  ["i_iso_spec.lua"] = [[
local H = require("xynotest.helpers")
it("dumps its environment", function()
  vim.cmd("wshada!")
  local t = { env = {}, std = {} }
  for _, k in ipairs({ "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "TMPDIR", "XYNO_TMUX_PREFIX", "XYNO_TEST_TMP", "XYNO_SPEC" }) do
    t.env[k] = vim.env[k]
  end
  for _, k in ipairs({ "config", "state", "cache", "data", "log" }) do
    t.std[k] = vim.fn.stdpath(k)
  end
  t.link = vim.uv.fs_readlink(vim.env.XDG_CONFIG_HOME .. "/nvim")
  t.shada = vim.fn.filereadable(vim.fn.stdpath("state") .. "/shada/main.shada")
  t.lsplog = vim.lsp.log.get_filename()
  t.tmpdir = H.tmpdir()
  local f = assert(io.open(vim.env.XYNO_DUMP .. "/iso.json", "w"))
  f:write(vim.json.encode(t))
  f:close()
end)
]],
}

local run_cache = {}
local function memo(key, fn)
  if run_cache[key] == nil then
    run_cache[key] = fn()
  end
  return run_cache[key]
end

local function run_a()
  return memo("A", function()
    local fake = fake_repo()
    for name, body in pairs(SPECS_A) do
      write(fake .. "/tests/" .. name, body)
    end
    local dump = H.tmpdir()
    local lock_before = read(fake .. "/lazy-lock.json")
    local obj_cmd = vim.list_extend({}, CLEAN)
    vim.list_extend(obj_cmd, { "/usr/bin/bash", fake .. "/scripts/test.sh", "--timeout", "30" })
    local obj = vim.system(obj_cmd, { text = true, cwd = "/", env = { XYNO_DUMP = dump, TEST_TIMEOUT = "33" } })
    local r = obj:wait(280000)
    r.pid = obj.pid
    r.out = (r.stdout or "") .. (r.stderr or "")
    r.dump = dump
    r.fake = fake
    r.rows = rows(r.out)
    r.lock_before = lock_before
    return r
  end)
end

-- Run C: one passing spec through --coverage, TEST_TIMEOUT, XYNO_TEST_SKIP_RUST
local function run_cov()
  return memo("C", function()
    local fake = build_fake(true) -- an own fake repo, so run A's specs are not picked up
    write(fake .. "/tests/ok_spec.lua", SPECS_A["d_pass_spec.lua"])
    local r = bash(fake .. "/scripts/test.sh", { "--coverage" }, { TEST_TIMEOUT = "77", XYNO_TEST_SKIP_RUST = "1" })
    r.rows = rows(r.out)
    return r
  end)
end

-- Run R: the real repo, the four original specs
local function run_real(env, patterns)
  return memo("R" .. vim.inspect(env) .. vim.inspect(patterns), function()
    local r = bash(repo .. "/scripts/test.sh", patterns, env)
    r.rows = rows(r.out)
    return r
  end)
end

-- ------------------------------------------------------ in-process harness

local function with_harness(register)
  local keys = { "describe", "it", "pending", "before_each", "after_each", "skip" }
  local saved = {}
  for _, k in ipairs(keys) do
    saved[k] = _G[k]
  end
  local mod = dofile(repo .. "/tests/harness.lua") -- a fresh instance, own state
  mod.install()
  local ok, err = pcall(register)
  local lines, n = {}, nil
  if ok then
    n = mod.run(function(s)
      lines[#lines + 1] = s
    end)
  end
  for _, k in ipairs(keys) do
    _G[k] = saved[k]
  end
  assert(ok, err)
  return n, lines
end

--- Run one spec text through tests/runner.lua directly (the full config).
local function runner(body, env)
  local fake = fake_repo()
  local spec = H.tmpdir() .. "/x_spec.lua"
  write(spec, body)
  local cfg, state, cache, tmp = H.tmpdir(), H.tmpdir(), H.tmpdir(), H.tmpdir()
  assert(uv.fs_symlink(fake, cfg .. "/nvim"))
  local e = vim.tbl_extend("force", {
    XYNO_SPEC = spec,
    XDG_CONFIG_HOME = cfg,
    XDG_STATE_HOME = state,
    XDG_CACHE_HOME = cache,
    TMPDIR = tmp,
    XYNO_TEST_TMP = tmp,
  }, env or {})
  local r = sh({ "nvim", "--headless", "-S", fake .. "/tests/runner.lua" }, { env = e, cwd = "/", wait = 120000 })
  return r
end

-- ============================================================ 1. --list etc.

describe("scripts/test.sh option handling", function()
  local script = repo .. "/scripts/test.sh"

  local function all_specs()
    local t = {}
    for _, f in ipairs(vim.fn.glob(repo .. "/tests/*_spec.lua", false, true)) do
      t[#t + 1] = "tests/" .. vim.fs.basename(f)
    end
    table.sort(t)
    return t
  end

  local function lines_of(s)
    local t = vim.split(vim.trim(s), "\n", { plain = true, trimempty = true })
    table.sort(t)
    return t
  end

  it("--list prints every tests/*_spec.lua and runs nothing (works without nvim and plugins)", function()
    local empty = H.tmpdir()
    vim.fn.mkdir(empty .. "/bin", "p")
    uv.fs_symlink("/usr/bin/dirname", empty .. "/bin/dirname")
    local before = vim.fn.glob(vim.env.TMPDIR .. "/xynotest.*", false, true)
    local r = bash(script, { "--list" }, { PATH = empty .. "/bin", XDG_DATA_HOME = empty .. "/nodata" })
    H.eq(0, r.code, r.out)
    H.eq(all_specs(), lines_of(r.stdout))
    H.no_match(r.stdout, "spec file(s)", true)
    H.eq("", r.stderr)
    H.eq(#before, #vim.fn.glob(vim.env.TMPDIR .. "/xynotest.*", false, true), "no work dir created")
  end)

  it("a pattern keeps only paths containing it; several patterns mean any", function()
    local r = bash(script, { "--list", "smoke_spec" })
    H.eq({ "tests/smoke_spec.lua" }, lines_of(r.stdout))
    local r2 = bash(script, { "--list", "smoke_spec", "/routes_spec", "harness_spec" })
    H.eq({ "tests/harness_spec.lua", "tests/routes_spec.lua", "tests/smoke_spec.lua" }, lines_of(r2.stdout))
    local r3 = bash(script, { "--list", "_spec" })
    H.eq(all_specs(), lines_of(r3.stdout))
    -- a pattern is a substring of the path, "tests/" matches every spec
    H.eq(all_specs(), lines_of(bash(script, { "tests/", "--list" }).stdout))
  end)

  it("no match exits 2 with 'no spec file matches <patterns>'", function()
    local r = bash(script, { "zzz-no-such-spec", "qqq" })
    H.eq(2, r.code)
    H.match(r.stderr, "no spec file matches zzz-no-such-spec qqq", true)
    H.eq("", vim.trim(r.stdout))
    -- also with --list
    local l = bash(script, { "--list", "zzz-no-such-spec" })
    H.eq(0, l.code, "--list prints the (empty) selection before the no-match check")
  end)

  it("an unknown option exits 2 with 'unknown option'", function()
    local r = bash(script, { "--bogus" })
    H.eq(2, r.code)
    H.match(r.stderr, "unknown option --bogus", true)
    local r2 = bash(script, { "-x", "smoke" })
    H.eq(2, r2.code)
    H.match(r2.stderr, "unknown option -x", true)
  end)

  it("-h and --help print the header usage and exit 0", function()
    local a = bash(script, { "-h" })
    local b = bash(script, { "--help" })
    H.eq(0, a.code)
    H.eq(0, b.code)
    H.eq(a.stdout, b.stdout)
    H.match(a.stdout, "Usage: scripts/test.sh [options] [pattern...]", true)
    for _, flag in ipairs({ "--list", "--coverage", "--timeout N", "-v, --verbose" }) do
      H.match(a.stdout, flag, true, "usage mentions " .. flag)
    end
    H.match(a.stdout, "Exit status: 0 all passed (skips allowed), 1 any failure/timeout, 2 usage/setup.", true)
    H.no_match(a.stdout, "set -uo", true)
    H.no_match(a.stdout, "^#", false)
    H.no_match(a.stdout, "\n#", false)
    H.eq("", a.stderr)
  end)

  it("--timeout without a value fails with a message", function()
    local r = bash(script, { "--timeout" })
    H.not_ok(r.code == 0, "must not succeed")
    H.match(r.stderr, "--timeout needs seconds", true)
    H.eq("", vim.trim(r.stdout), "ran nothing")
    H.eq(2, r.code, "usage errors are documented as exit status 2 (README Tests, header)")
  end)
end)

-- =========================================================== 3. setup errors

describe("scripts/test.sh setup errors", function()
  local script = repo .. "/scripts/test.sh"

  it("exits 2 'nvim not found' when nvim is not on PATH", function()
    local d = H.tmpdir()
    vim.fn.mkdir(d .. "/bin", "p")
    uv.fs_symlink("/usr/bin/dirname", d .. "/bin/dirname")
    local r = bash(script, { "smoke_spec" }, { PATH = d .. "/bin" })
    H.eq(2, r.code, r.out)
    H.match(r.stderr, "test.sh: nvim not found", true)
  end)

  it("exits 2 with the bootstrap hint when XDG_DATA_HOME holds no plugins", function()
    local d = H.tmpdir()
    local r = bash(script, { "smoke_spec" }, { XDG_DATA_HOME = d })
    H.eq(2, r.code, r.out)
    H.match(r.stderr, "no plugins in " .. d .. "/nvim/lazy. Run scripts/bootstrap.sh first", true)
    H.match(r.stderr, "ln -s", true)
    -- nothing was started
    H.no_match(r.stdout, "spec file(s)", true)
  end)
end)

-- ===================================================== 5-8 the full run (A)

describe("scripts/test.sh full run (throwaway specs)", function()
  it("prints a banner with the spec count and the timeout (--timeout beats $TEST_TIMEOUT)", function()
    local r = run_a()
    H.match(r.out, "xynovim tests: 9 spec file(s), timeout 30s each", true)
    H.match(r.out, "rust-analyzer", true)
  end)

  it("exits 1 when any file fails, times out or crashes", function()
    H.eq(1, run_a().code)
  end)

  it("a spec that hangs (busy loop) is reported TIMEOUT and the suite goes on", function()
    local r = run_a()
    local row = H.ok(r.rows["a_hang_spec.lua"], "no result row for the hanging spec:\n" .. r.out)
    H.eq("TIMEOUT", row.status)
    H.eq(0, row.passed)
    H.eq(1, row.failed)
    H.match(r.out, "%(TIMEOUT, exit 1[23][47]; last output%)", false, "busy loop ignores TERM: killed by -k")
    -- later files still ran
    H.eq("PASS", r.rows["d_pass_spec.lua"].status)
    H.eq("PASS", r.rows["i_iso_spec.lua"].status)
    -- the hung nvim is really gone
    local pid = tonumber(vim.trim(read(r.dump .. "/hang.pid")))
    H.ok(pid)
    H.ok(wait_dead(pid), "hung nvim " .. pid .. " still alive")
  end)

  it("a failing assertion is FAIL, echoed with a trimmed traceback", function()
    local r = run_a()
    local row = r.rows["b_fail_spec.lua"]
    H.eq("FAIL", row.status)
    H.eq(1, row.passed)
    H.eq(1, row.failed)
    H.match(r.out, "    FAIL grp > breaks", true)
    H.match(r.out, "numbers: expected 1", true)
    H.match(r.out, "actual   2", true)
    H.match(r.out, "b_fail_spec.lua:4:", true)
    H.match(r.out, "stack traceback:", true)
    -- the echoed block of this one failure: the indented lines after its FAIL line
    local block, on = {}, false
    for l in r.out:gmatch("[^\n]+") do
      if l == "    FAIL grp > breaks" then
        on = true
      elseif on and l:match("^       ") then
        block[#block + 1] = l
      elseif on then
        break
      end
    end
    local text = table.concat(block, "\n")
    H.ok(#block >= 3, "the failure detail was echoed")
    H.no_match(text, "tests/harness.lua", true, "harness frames trimmed")
    H.no_match(text, "tests/runner.lua", true, "runner frames trimmed")
    H.no_match(text, "[C]: in function 'xpcall'", true)
    H.match(text, "helpers.lua", true, "the helper frame is kept")
  end)

  it("an error at load time is FAIL 'loading' with the message", function()
    local r = run_a()
    local row = r.rows["c_load_spec.lua"]
    H.eq("FAIL", row.status)
    H.eq(0, row.passed)
    H.eq(1, row.failed)
    H.match(r.out, "    FAIL loading " .. r.fake .. "/tests/c_load_spec.lua", true)
    H.match(r.out, "boom at load", true)
  end)

  it("skip_file at load time is a PASS with 1 skipped and its reason echoed", function()
    local r = run_a()
    local row = r.rows["e_skipfile_spec.lua"]
    H.eq("PASS", row.status)
    H.eq(0, row.passed)
    H.eq(0, row.failed)
    H.eq(1, row.skipped)
    H.match(r.out, "    SKIP e_skipfile_spec.lua (nothing to do here)", true)
  end)

  it("skip(reason) and pending count as skipped with their reasons; the file is PASS", function()
    local r = run_a()
    local row = r.rows["d_pass_spec.lua"]
    H.eq("PASS", row.status)
    H.eq(2, row.passed)
    H.eq(0, row.failed)
    H.eq(2, row.skipped)
    H.match(r.out, "    SKIP grp > skipper (no gizmo)", true)
    H.match(r.out, "    SKIP grp > pend (not ready)", true)
  end)

  it("a process that dies without a result line is CRASH with its exit code", function()
    local r = run_a()
    local row = r.rows["f_crash_spec.lua"]
    H.eq("CRASH", row.status)
    H.eq(1, row.failed)
    H.match(r.out, "(CRASH, exit 3; last output)", true)
  end)

  it("every row has the documented shape and the total adds up", function()
    local r = run_a()
    local p, f, s = 0, 0, 0
    local n = 0
    for _, row in pairs(r.rows) do
      n = n + 1
      p, f, s = p + row.passed, f + row.failed, s + row.skipped
      H.match(row.line, "^%u+%s+tests/%S+_spec%.lua%s+%d+ passed, %d+ failed, %d+ skipped %(%d+s%)$")
    end
    H.eq(9, n)
    local tp, tf, ts = r.out:match("\ntotal: (%d+) passed, (%d+) failed, (%d+) skipped in %d+s\n")
    H.ok(tp, "no totals line:\n" .. r.out)
    H.eq({ p, f, s }, { tonumber(tp), tonumber(tf), tonumber(ts) })
    H.eq({ 6, 4, 3 }, { p, f, s })
  end)

  it("lists the failed files on a 'failed:' line, in run order", function()
    local r = run_a()
    H.match(
      r.out,
      "\nfailed: tests/a_hang_spec.lua tests/b_fail_spec.lua tests/c_load_spec.lua tests/f_crash_spec.lua\n",
      true
    )
  end)

  it("warns when lazy-lock.json changed during the run", function()
    local r = run_a()
    H.match(r.out, "WARNING: lazy-lock.json changed during the run", true)
    H.not_ok(read(r.fake .. "/lazy-lock.json") == r.lock_before, "the throwaway spec did change the lockfile")
  end)

  it("signals the process group of every nvim and kills tmux servers named xynotest-<pid>-*", function()
    local r = run_a()
    local pid = tonumber(vim.trim(read(r.dump .. "/sleep.pid")))
    H.ok(pid)
    H.ok(wait_dead(pid), "background sleep " .. pid .. " of a spec survived the run")
    if exists(r.dump .. "/tmux.sock") then
      local sock = vim.trim(read(r.dump .. "/tmux.sock"))
      H.eq("xynotest-" .. r.pid .. "-raw", sock, "prefix is xynotest-<pid of test.sh>")
      local t = sh({ "tmux", "-L", sock, "list-sessions" })
      rm_socket(sock)
      H.not_ok(t.code == 0, "tmux server " .. sock .. " still running")
    end
  end)

  it("isolates XDG_CONFIG/STATE/CACHE_HOME and TMPDIR in a temp work dir, keeps XDG_DATA_HOME real", function()
    local r = run_a()
    H.eq("PASS", r.rows["i_iso_spec.lua"].status)
    local d = vim.json.decode(read(r.dump .. "/iso.json"))
    local e, std = d.env, d.std
    local work = vim.fs.dirname(e.XDG_STATE_HOME)
    H.match(vim.fs.basename(work), "^xynotest%.")
    H.eq(work .. "/config", e.XDG_CONFIG_HOME)
    H.eq(work .. "/state", e.XDG_STATE_HOME)
    H.eq(work .. "/cache", e.XDG_CACHE_HOME)
    H.eq(work .. "/tmp", e.TMPDIR)
    H.eq(work .. "/tmp", e.XYNO_TEST_TMP)
    H.eq(r.fake, d.link, "XDG_CONFIG_HOME/nvim links to the checkout")
    H.eq(vim.env.XDG_DATA_HOME or (vim.env.HOME .. "/.local/share"), e.XDG_DATA_HOME, "data stays the real one")
    H.eq(e.XDG_DATA_HOME .. "/nvim", std.data)
    H.eq(work .. "/config/nvim", std.config)
    H.eq(work .. "/state/nvim", std.state)
    H.eq(work .. "/cache/nvim", std.cache)
    H.eq("xynotest-" .. r.pid, e.XYNO_TMUX_PREFIX)
    H.eq(r.fake .. "/tests/i_iso_spec.lua", e.XYNO_SPEC)
    -- state written by the spec (shada, lsp.log location) is inside the work dir
    H.eq(1, d.shada, "shada was written in the temp state dir")
    H.eq(work .. "/state/nvim/", d.lsplog:sub(1, #work + 12))
    H.eq(work .. "/tmp/", d.tmpdir:sub(1, #work + 5), "H.tmpdir() lives in the temp TMPDIR")
    local real_state = (vim.env.HOME or "") .. "/.local/state/nvim"
    H.not_ok(d.lsplog:sub(1, #real_state) == real_state)
  end)

  it("removes the work dir (and the spec's temp dirs) at the end", function()
    local r = run_a()
    local d = vim.json.decode(read(r.dump .. "/iso.json"))
    local work = vim.fs.dirname(d.env.XDG_STATE_HOME)
    H.not_ok(exists(work), work .. " still exists")
    H.not_ok(exists(d.tmpdir))
  end)
end)

-- =========================================== 7-9, 14 coverage run (C) + env

describe("scripts/test.sh --coverage and environment switches", function()
  it("$TEST_TIMEOUT sets the default timeout; XYNO_TEST_SKIP_RUST=1 and --coverage are announced", function()
    local r = run_cov()
    H.eq(0, r.code, r.out)
    H.match(r.out, "xynovim tests: 1 spec file(s), timeout 77s each", true)
    H.match(r.out, "  XYNO_TEST_SKIP_RUST=1 (Rust specs will skip)", true)
    H.match(r.out, "  coverage: on", true)
    H.eq("PASS", r.rows["ok_spec.lua"].status)
  end)

  it("a clean run does not warn about the lockfile", function()
    H.no_match(run_cov().out, "lazy-lock.json changed", true)
  end)

  it("prints per-file hit/exec/percent rows for lua/ colors/ plugin/ after/ and a TOTAL that adds up", function()
    local r = run_cov()
    local at = r.out:find("Line coverage (lines executed by the specs; executable lines estimated)", 1, true)
    H.ok(at, "no coverage report:\n" .. r.out)
    local report = r.out:sub(at):gsub("\r", "")
    local seen, total = {}, nil
    local sh_, se = 0, 0
    for line in report:gmatch("[^\n]+") do
      local rel, h, n, pct = line:match("^  (%S+)%s+(%d+)/(%d+)%s+([%d.]+)%%$")
      if rel == "TOTAL" then
        total = { tonumber(h), tonumber(n), tonumber(pct) }
      elseif rel then
        H.is_nil(seen[rel], "listed twice")
        seen[rel] = true
        seen[rel:match("^[^/]+")] = true
        sh_, se = sh_ + tonumber(h), se + tonumber(n)
        H.ok(tonumber(h) <= tonumber(n), rel)
        H.eq(("%5.1f"):format(tonumber(n) > 0 and 100 * h / n or 100), ("%5.1f"):format(tonumber(pct)), rel)
        H.no_match(rel, "^tests/")
      end
    end
    H.eq({ true, true, true, true }, { seen.lua, seen.colors, seen.plugin, seen.after }, report:sub(1, 600):gsub("\r", "\\r"))
    H.ok(total, "no TOTAL row")
    H.eq({ sh_, se }, { total[1], total[2] })
    H.ok(total[1] > 0, "the hook recorded executed lines")
    H.ok(total[3] > 1 and total[3] < 100, "TOTAL percent " .. total[3])
    H.match(report, "\n  lua/config/options.lua ", true)
    H.match(report, "\n  colors/island-dark.lua ", true)
    H.match(report, "\n  plugin/after/transparency.lua ", true)
    H.match(report, "\n  after/ftplugin/rust.lua ", true)
  end)
end)

describe("tests/coverage_hook.lua and scripts/coverage.lua", function()
  local hook_run
  local function hook()
    if hook_run then
      return hook_run
    end
    local root = H.tmpdir()
    local files = {
      ["lua/m.lua"] = "local a = 1\nlocal b = 2\nreturn a + b\n",
      ["colors/c.lua"] = "local c = 1\nreturn c\n",
      ["plugin/p.lua"] = "local p = 1\nreturn p\n",
      ["after/a.lua"] = "local x = 1\nreturn x\n",
      ["tests/t.lua"] = "local t = 1\nreturn t\n",
      ["other/o.lua"] = "local o = 1\nreturn o\n",
      ["lua/notlua.txt"] = "ignored",
    }
    for rel, body in pairs(files) do
      write(root .. "/" .. rel, body)
    end
    write(
      root .. "/run.lua",
      [[
local root = vim.env.XYNO_COV_ROOTS:match("[^:]+$")
for _, f in ipairs({ "lua/m.lua", "tests/t.lua", "colors/c.lua", "plugin/p.lua", "after/a.lua", "other/o.lua" }) do
  dofile(root .. "/" .. f)
end
__xyno_cov.dump(vim.env.XYNO_COV_OUT)
]]
    )
    local out = H.tmpdir() .. "/cov.json"
    local r = sh({
      "nvim", "--headless", "-u", "NONE", "--cmd", "luafile " .. repo .. "/tests/coverage_hook.lua",
      "-c", "luafile " .. root .. "/run.lua", "-c", "qa!",
    }, { env = { XYNO_COV_ROOTS = "/nonexistent/x:" .. root, XYNO_COV_OUT = out }, cwd = "/" })
    hook_run = { r = r, out = out, root = root }
    return hook_run
  end

  it("the hook writes XYNO_COV_OUT json with repo-relative keys and executed lines", function()
    local h = hook()
    H.ok(exists(h.out), "no dump written:\n" .. h.r.out)
    local d = vim.json.decode(read(h.out))
    H.eq({ 1, 2, 3 }, d["lua/m.lua"])
    H.eq({ 1, 2 }, d["colors/c.lua"])
    H.eq({ 1, 2 }, d["plugin/p.lua"])
    H.eq({ 1, 2 }, d["after/a.lua"])
  end)

  it("test files and other directories are not in the hook roots (only lua/ colors/ plugin/ after/)", function()
    local d = vim.json.decode(read(hook().out))
    local keys = vim.tbl_keys(d)
    table.sort(keys)
    H.eq({ "after/a.lua", "colors/c.lua", "lua/m.lua", "plugin/p.lua" }, keys)
  end)

  it("the hook's classifier names exactly those four directories", function()
    local src = read(repo .. "/tests/coverage_hook.lua")
    H.match(src, 'rel:match("^lua/") or rel:match("^colors/") or rel:match("^plugin/") or rel:match("^after/")', true)
    H.no_match(src, 'match("^tests/")', true)
  end)

  it("scripts/coverage.lua merges dumps and estimates the denominator (comments, blanks, closers excluded)", function()
    local root = H.tmpdir()
    write(
      root .. "/lua/m.lua",
      table.concat({
        "-- comment", -- 1
        "local x = 1", -- 2 *
        "", -- 3
        "if x then", -- 4 *
        "  print(x) -- tail", -- 5 *
        "else", -- 6
        "  y = 2", -- 7 *
        "end", -- 8
        "--[[ block", -- 9
        "still ]]", -- 10
        "local s = [[", -- 11 *
        "body", -- 12
        "body2]]", -- 13
        "return {", -- 14 *
        "  a = 1,", -- 15 *
        "}", -- 16
      }, "\n") .. "\n"
    )
    write(root .. "/lua/n.lua", "local z = 2\n")
    write(root .. "/tests/t.lua", "local t = 1\n")
    local dumps = H.tmpdir()
    write(dumps .. "/a.json", '{"lua/m.lua":[2,4,5,9,13,16],"lua/gone.lua":[1]}')
    write(dumps .. "/b.json", '{"lua/m.lua":[7,12]}')
    local r = sh({ "nvim", "-l", repo .. "/scripts/coverage.lua", root, dumps }, { cwd = "/" })
    H.eq(0, r.code, r.out)
    local got = {}
    local text = r.out:gsub("\r", "") -- nvim -l prints to stderr
    for line in text:gmatch("[^\n]+") do
      local rel, h, n, pct = line:match("^  (%S+)%s+(%d+)/(%d+)%s+([%d.]+)%%$")
      if rel then
        got[rel] = { tonumber(h), tonumber(n), pct }
      end
    end
    H.eq({ 4, 7, "57.1" }, got["lua/m.lua"])
    H.eq({ 0, 1, "0.0" }, got["lua/n.lua"])
    H.eq({ 4, 8, "50.0" }, got["TOTAL"])
    H.is_nil(got["tests/t.lua"])
    H.is_nil(got["lua/gone.lua"])
    H.match(text, "Line coverage (lines executed by the specs; executable lines estimated)", true)
  end)

  it("scripts/coverage.lua without arguments prints usage and exits 2", function()
    local r = sh({ "nvim", "-l", repo .. "/scripts/coverage.lua" }, { cwd = "/" })
    H.eq(2, r.code, r.out)
    H.match(r.stderr, "usage: nvim -l scripts/coverage.lua <repo> <dump dir>", true)
    local r1 = sh({ "nvim", "-l", repo .. "/scripts/coverage.lua", "/tmp" }, { cwd = "/" })
    H.eq(2, r1.code)
  end)
end)

-- =================================================== 9. XYNO_TEST_SKIP_RUST

describe("rust probes", function()
  local function with_path(path, fn)
    local old = vim.env.PATH
    vim.env.PATH = path
    local ok, e = pcall(fn)
    vim.env.PATH = old
    assert(ok, e)
  end

  local function stubs(ra_code, with_cargo)
    local d = H.tmpdir()
    write(d .. "/rust-analyzer", ("#!/bin/sh\nexit %d\n"):format(ra_code))
    uv.fs_chmod(d .. "/rust-analyzer", 493)
    if with_cargo then
      write(d .. "/cargo", "#!/bin/sh\nexit 0\n")
      uv.fs_chmod(d .. "/cargo", 493)
    end
    return d
  end

  it("XYNO_TEST_SKIP_RUST=1 makes rust_available false and need_rust skip with that reason", function()
    local old = vim.env.XYNO_TEST_SKIP_RUST
    vim.env.XYNO_TEST_SKIP_RUST = "1"
    local ok, why = H.rust_available()
    local pok, err = pcall(H.need_rust)
    vim.env.XYNO_TEST_SKIP_RUST = old
    H.eq(false, ok)
    H.eq("XYNO_TEST_SKIP_RUST=1", why)
    H.not_ok(pok)
    H.ok(harness.is_skip(err), "need_rust raised a skip, not an error: " .. vim.inspect(err))
    H.eq("XYNO_TEST_SKIP_RUST=1", err.reason)
  end)

  it("need_rust skips when rust-analyzer --version fails (rustup proxy) or cargo is missing", function()
    local old = vim.env.XYNO_TEST_SKIP_RUST
    vim.env.XYNO_TEST_SKIP_RUST = nil
    local ok1, why1, ok2, why2, ok3, why3, pok, err
    local ok_, e_ = pcall(function()
      with_path(stubs(1, true), function()
        ok1, why1 = H.rust_available()
        pok, err = pcall(H.need_rust)
      end)
      with_path(stubs(0, false), function()
        ok2, why2 = H.rust_available()
      end)
      with_path(stubs(0, true), function()
        ok3, why3 = H.rust_available()
      end)
    end)
    vim.env.XYNO_TEST_SKIP_RUST = old
    assert(ok_, e_)
    H.eq(false, ok1)
    H.match(why1, "rustup proxy", true)
    H.not_ok(pok)
    H.ok(harness.is_skip(err))
    H.match(err.reason, "rustup component add rust-analyzer", true)
    H.eq({ false, "cargo not found" }, { ok2, why2 })
    H.eq(true, ok3, "stub rust-analyzer --version succeeds: " .. tostring(why3))
  end)

  it("the real Rust spec skips (3 skipped, with the reason) under XYNO_TEST_SKIP_RUST=1", function()
    local r = run_real({ XYNO_TEST_SKIP_RUST = "1" }, { "/rust_spec" })
    H.eq(0, r.code, r.out)
    local row = r.rows["rust_spec.lua"]
    H.eq({ "PASS", 0, 0, 3 }, { row.status, row.passed, row.failed, row.skipped })
    H.match(r.out, "SKIP rust-analyzer on the fixtures > ", true)
    H.match(r.out, "(XYNO_TEST_SKIP_RUST=1)", true)
  end)
end)

-- ==================================================== 10. tests/harness.lua

describe("tests/harness.lua", function()
  it("runs hooks outer first / inner last around every test", function()
    local log = {}
    local function L(s)
      return function()
        log[#log + 1] = s
      end
    end
    local n = with_harness(function()
      describe("outer", function()
        before_each(L("outer before 1"))
        before_each(L("outer before 2"))
        after_each(L("outer after"))
        describe("inner", function()
          before_each(L("inner before"))
          after_each(L("inner after"))
          it("t1", L("t1"))
          it("t2", L("t2"))
        end)
        it("t3", L("t3"))
      end)
    end)
    H.eq({ passed = 3, failed = 0, skipped = 0 }, n)
    H.eq({
      "outer before 1", "outer before 2", "inner before", "t1", "inner after", "outer after",
      "outer before 1", "outer before 2", "inner before", "t2", "inner after", "outer after",
      "outer before 1", "outer before 2", "t3", "outer after",
    }, log)
  end)

  it("reports ok / FAIL / SKIP lines with ' > ' joined names, counts and indented failure detail", function()
    local n, lines = with_harness(function()
      describe("a", function()
        describe("b", function()
          it("good", function() end)
          it("bad", function()
            error("kaboom")
          end)
          it("skips", function()
            skip("because")
          end)
          it("skips bare", function()
            skip()
          end)
          pending("later", "not yet")
          pending("later bare")
        end)
      end)
    end)
    H.eq({ passed = 1, failed = 1, skipped = 4 }, n)
    H.eq("ok   a > b > good", lines[1])
    H.eq("FAIL a > b > bad", lines[2])
    H.match(lines[3], "^       .*kaboom")
    H.has(lines, "SKIP a > b > skips (because)")
    H.has(lines, "SKIP a > b > skips bare (skipped)")
    H.has(lines, "SKIP a > b > later (not yet)")
    H.has(lines, "SKIP a > b > later bare (pending)")
    for _, l in ipairs(lines) do
      H.no_match(l, "tests/harness.lua", true)
    end
  end)

  it("after_each runs after a failing test; a failing after_each fails a passing test; skip works in hooks", function()
    local log = {}
    local n, lines = with_harness(function()
      describe("g", function()
        after_each(function()
          log[#log + 1] = "after"
        end)
        it("fails", function()
          error("x")
        end)
        describe("h", function()
          after_each(function()
            error("after broke")
          end)
          it("passes alone", function() end)
        end)
        describe("s", function()
          before_each(function()
            skip("hook skip")
          end)
          it("body not run", function()
            log[#log + 1] = "BODY"
          end)
        end)
        describe("f", function()
          before_each(function()
            error("before broke")
          end)
          it("body not run either", function()
            log[#log + 1] = "BODY2"
          end)
        end)
      end)
    end)
    H.eq({ passed = 0, failed = 3, skipped = 1 }, n)
    -- the failing inner after_each aborts the remaining hooks of its own test
    H.eq({ "after", "after", "after" }, log, "no skipped/before-failed body ran")
    H.has(lines, "SKIP g > s > body not run (hook skip)")
    local joined = table.concat(lines, "\n")
    H.match(joined, "after broke", true)
    H.match(joined, "before broke", true)
  end)

  it("exposes describe/it/before_each/after_each/pending/skip as globals after install()", function()
    with_harness(function()
      for _, k in ipairs({ "describe", "it", "before_each", "after_each", "pending", "skip" }) do
        H.eq("function", type(_G[k]), k)
      end
    end)
  end)

  it("a describe that errors while registering raises with the group name", function()
    H.throws(function()
      with_harness(function()
        describe("broken group", function()
          error("no good")
        end)
      end)
    end, "describe 'broken group': .*no good")
  end)
end)

describe("tests/runner.lua", function()
  it("ends with 'XYNO_RESULT passed=N failed=N skipped=N' and exits 1 on failures (cquit 1)", function()
    local r = runner([[
describe("g", function()
  it("one", function() end)
  it("two", function() end)
  it("bad", function() error("nope") end)
  pending("p", "later")
end)
]])
    H.eq(1, r.code, r.out)
    local last
    for l in r.stdout:gmatch("[^\n]+") do
      last = l
    end
    H.eq("XYNO_RESULT passed=2 failed=1 skipped=1", last)
    H.match(r.stdout, "ok   g > one", true)
    H.match(r.stdout, "FAIL g > bad", true)
    H.match(r.stdout, "SKIP g > p (later)", true)
  end)

  it("exits 0 without failures", function()
    local r = runner('it("fine", function() end)')
    H.eq(0, r.code, r.out)
    H.match(r.stdout, "XYNO_RESULT passed=1 failed=0 skipped=0\n", true)
  end)

  it("skip_file at load: SKIP line, skipped=1, exit 0; a load error: FAIL loading, failed=1, exit 1", function()
    local r = runner('require("xynotest.helpers").skip_file("not today")')
    H.eq(0, r.code, r.out)
    H.match(r.stdout, "SKIP x_spec.lua (not today)", true)
    H.match(r.stdout, "XYNO_RESULT passed=0 failed=0 skipped=1\n", true)
    local e = runner('local x = nil\nx.y = 1')
    H.eq(1, e.code, e.out)
    H.match(e.stdout, "FAIL loading ", true)
    H.match(e.stdout, "XYNO_RESULT passed=0 failed=1 skipped=0\n", true)
  end)

  it("registers the helpers under 'xynotest.helpers', not 'tests.helpers'", function()
    H.eq("function", type(package.preload["xynotest.helpers"]))
    H.eq("function", type(package.preload["xynotest.harness"]))
    H.is_nil(package.preload["tests.helpers"])
    H.eq(H, package.loaded["xynotest.helpers"])
    local src = read(repo .. "/tests/runner.lua")
    H.match(src, 'package.preload["xynotest." .. name]', true)
  end)
end)

-- ==================================================== 11-13 helpers + fixtures

describe("tests/helpers.lua API", function()
  local names = {
    "eq", "ok", "not_ok", "is_nil", "match", "no_match", "has", "throws", "wait_for", "wait_lsp", "feed", "open",
    "clients", "diagnostics", "messages", "clear_messages", "capture_notify", "fixture", "open_fixture", "git",
    "git_init", "sandbox_sh", "tmux", "spawn", "tmpdir", "cleanup", "need_rust", "need_sandbox", "need_tmux",
    "skip_file", "rust_available", "sandbox_available", "tmux_available",
  }

  it("provides every documented function", function()
    for _, n in ipairs(names) do
      H.eq("function", type(H[n]), "H." .. n)
    end
  end)

  it("assertions pass on true and raise a descriptive error on false", function()
    H.throws(function() H.eq(1, 2) end, "expected 1")
    H.throws(function() H.eq({ 1 }, { 2 }, "lists") end, "^.-lists: expected")
    H.eq({ a = { 1, 2 } }, { a = { 1, 2 } })
    H.throws(function() H.ok(nil, "custom message") end, "custom message")
    H.eq("x", H.ok("x"))
    H.throws(function() H.not_ok(1) end, "falsy")
    H.throws(function() H.is_nil(0) end, "expected nil")
    H.throws(function() H.match("abc", "^b") end, "does not match")
    H.match("a.c", ".", true)
    H.throws(function() H.match("abc", ".", true) end)
    H.throws(function() H.no_match("abc", "b", true) end, "unexpectedly matches")
    H.has({ { 1 }, 2 }, { 1 })
    H.has("hello", "ell")
    H.throws(function() H.has({ 1 }, 2) end, "does not contain")
    H.throws(function() H.throws(function() end) end, "expected an error")
    H.throws(function() H.throws(function() error("zzz") end, "^yyy$") end, "does not match")
  end)

  it("wait_for returns the predicate's value and raises with the message on timeout", function()
    local n = 0
    H.eq("done", H.wait_for(function()
      n = n + 1
      return n > 3 and "done"
    end, 2000))
    H.throws(function()
      H.wait_for(function() return false end, 60, "the moon")
    end, "timed out waiting for the moon")
  end)

  it("tmpdir is fresh and empty, git/git_init make a one-commit repo, spawn registers a job", function()
    local a, b = H.tmpdir(), H.tmpdir()
    H.ok(a ~= b)
    H.eq({}, vim.fn.readdir(a))
    write(a .. "/f.txt", "x")
    H.git_init(a)
    H.eq("1", H.git(a, "rev-list", "--count", "HEAD"))
    H.eq("main", H.git(a, "branch", "--show-current"))
    H.eq("t", H.git(a, "log", "-1", "--format=%an"))
    H.throws(function() H.git(a, "no-such-subcommand") end, "failed")
    local job = H.spawn({ "sleep", "301" })
    H.ok(alive(job.pid))
    H.eq(job, H._jobs[#H._jobs])
    job:kill(15)
    H.ok(wait_dead(job.pid))
  end)

  it("capture_notify collects notifications and restore() puts vim.notify back", function()
    local orig = vim.notify
    local cap = H.capture_notify()
    vim.notify("hello", vim.log.levels.WARN)
    H.eq({ { msg = "hello", level = vim.log.levels.WARN } }, cap.list)
    H.ok(vim.notify ~= orig)
    cap.restore()
    H.eq(orig, vim.notify)
  end)

  it("diagnostics filters by source, messages/clear_messages wrap :messages", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local ns = vim.api.nvim_create_namespace("xyno-infra-test")
    vim.diagnostic.set(ns, buf, {
      { lnum = 0, col = 0, message = "m1", source = "rustc" },
      { lnum = 0, col = 0, message = "m2", source = "clippy::needless_return" },
    })
    H.eq(2, #H.diagnostics(nil, buf))
    H.eq({ "m1" }, vim.tbl_map(function(d) return d.message end, H.diagnostics("rustc", buf)))
    H.eq({ "m2" }, vim.tbl_map(function(d) return d.message end, H.diagnostics("clippy", buf)))
    vim.diagnostic.reset(ns, buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_echo({ { "an infra test message" } }, true, {})
    H.match(H.messages(), "an infra test message", true)
    H.clear_messages()
    H.eq("", vim.trim(H.messages()))
  end)

  it("feed types keys with mappings applied", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    H.feed("ihello<Esc>")
    H.eq({ "hello" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("tests/helpers.lua cleanup and open", function()
  it("cleanup removes temp dirs, kills jobs, tmux servers and LSP clients; open fires User VeryLazy", function()
    local out = H.tmpdir() .. "/result.json"
    local r = runner(
      [[
local H = require("xynotest.helpers")
local result = {}
it("does everything", function()
  -- H.open fires User VeryLazy (and edits the file)
  local fired = 0
  vim.api.nvim_create_autocmd("User", { pattern = "VeryLazy", callback = function() fired = fired + 1 end })
  local f = H.tmpdir() .. "/note.txt"
  vim.fn.writefile({ "x" }, f)
  H.open(f)
  result.fired = fired
  result.opened = vim.api.nvim_buf_get_name(0) == f

  local d = H.tmpdir()
  vim.fn.writefile({ "x" }, d .. "/f")
  local job = H.spawn({ "sleep", "300" })
  result.dir, result.pid = d, job.pid
  -- what a sandbox spec leaves in the real ~/.claude/projects: the project below the temp dir
  result.proj = vim.uv.os_homedir() .. "/.claude/projects/" .. (vim.uv.fs_realpath(d) or d):gsub("[^%w]", "-") .. "-basic"
  vim.fn.mkdir(result.proj .. "/memory", "p")
  if vim.fn.executable("tmux") == 1 then
    H.tmux({ "new-session", "-d", "sleep 300" }, "cl")
    result.sock = vim.env.XYNO_TMUX_PREFIX .. "-cl"
    result.tmux_before = vim.system({ "tmux", "-L", result.sock, "has-session" }):wait().code
  end
  local closing = false
  vim.lsp.start({
    name = "fakels",
    cmd = function(disp)
      return {
        request = function(m, _, cb)
          if m == "initialize" then cb(nil, { capabilities = {} }) elseif m == "shutdown" then cb(nil, nil) end
          return true, 1
        end,
        notify = function(m) if m == "exit" then closing = true end return true end,
        is_closing = function() return closing end,
        terminate = function() closing = true; disp.on_exit(0, 0) end,
      }
    end,
    root_dir = d,
  }, { bufnr = 0 })
  H.wait_for(function() return #vim.lsp.get_clients({ name = "fakels" }) > 0 end, 5000, "fake client")
  result.clients_before = #vim.lsp.get_clients({ name = "fakels" })

  H.cleanup()

  result.proj_exists = vim.uv.fs_stat(result.proj) ~= nil
  result.dir_exists = vim.uv.fs_stat(d) ~= nil
  result.file_exists = vim.uv.fs_stat(f) ~= nil
  result.job_alive = vim.uv.fs_stat("/proc/" .. job.pid) ~= nil
  if result.sock then
    result.tmux_after = vim.system({ "tmux", "-L", result.sock, "has-session" }):wait().code
  end
  result.clients_after = #vim.lsp.get_clients({ name = "fakels" })
  local w = assert(io.open("]] .. out .. [[", "w"))
  w:write(vim.json.encode(result))
  w:close()
end)
]],
      { XYNO_TMUX_PREFIX = "xynotest-selftest-" .. uv.os_getpid() }
    )
    H.eq(0, r.code, r.out)
    local d = vim.json.decode(read(out))
    H.eq(1, d.fired, "H.open fires User VeryLazy once")
    H.eq(true, d.opened)
    H.eq(1, d.clients_before)
    H.eq(0, d.clients_after, "LSP clients stopped")
    H.eq(false, d.proj_exists, "the empty ~/.claude/projects/<temp dir>-basic/memory a sandbox spec leaves is removed")
    H.eq(false, d.dir_exists, "temp dir removed")
    H.eq(false, d.file_exists, "files in temp dirs removed")
    H.eq(false, d.job_alive, "spawned job killed")
    if d.sock then
      H.eq(0, d.tmux_before, "tmux server was running")
      rm_socket(d.sock)
      H.not_ok(d.tmux_after == 0, "tmux server killed")
    end
  end)
end)

describe("fixtures", function()
  local fx = repo .. "/tests/fixtures"

  it("basic: lib + bin + integration test + trait + one clippy finding", function()
    for _, f in ipairs({ "Cargo.toml", "src/lib.rs", "src/main.rs", "tests/it.rs" }) do
      H.ok(exists(fx .. "/basic/" .. f), f)
    end
    local lib = read(fx .. "/basic/src/lib.rs")
    H.match(lib, "pub trait Shape", true)
    H.match(lib, "impl Shape for Square", true)
    H.match(lib, "return 42;", true, "needless_return, the one clippy finding")
    local cnt = select(2, lib:gsub("\n%s+return ", ""))
    H.eq(1, cnt)
    local toml = read(fx .. "/basic/Cargo.toml")
    H.match(toml, "[lib]", true)
    H.match(toml, "[[bin]]", true)
    H.match(read(fx .. "/basic/tests/it.rs"), "#[test]", true)
  end)

  it("workspace: core-lib + app, features ssr/csr, compile_error when both", function()
    H.match(read(fx .. "/workspace/Cargo.toml"), 'members = ["core", "app"]', true)
    local core = read(fx .. "/workspace/core/Cargo.toml")
    H.match(core, 'name = "core-lib"', true)
    H.match(core, "ssr = []", true)
    H.match(core, "csr = []", true)
    H.match(core, 'default = ["ssr"]', true)
    H.match(read(fx .. "/workspace/app/Cargo.toml"), 'core-lib = { path = "../core" }', true)
    H.match(read(fx .. "/workspace/core/src/lib.rs"), '#[cfg(all(feature = "ssr", feature = "csr"))]\ncompile_error!', true)
    H.ok(exists(fx .. "/workspace/app/src/main.rs"))
  end)

  it("broken has a type error; standalone.rs and sql_and_routes.rs exist", function()
    H.ok(exists(fx .. "/broken/Cargo.toml"))
    H.match(read(fx .. "/broken/src/main.rs"), 'let x: i32 = "not a number";', true)
    H.ok(exists(fx .. "/standalone.rs"))
    H.eq(1, vim.fn.filereadable(fx .. "/standalone.rs"))
    H.ok(not exists(fx .. "/standalone.rs/Cargo.toml"))
    local sr = read(fx .. "/sql_and_routes.rs")
    H.match(sr, "sqlx::query", true)
    H.match(sr, ".route(", true)
  end)

  it("a fixture copy is private per call; the source stays untouched", function()
    local before = read(fx .. "/basic/src/lib.rs")
    local a = H.fixture("basic")
    local b = H.fixture("basic")
    H.ok(a ~= b)
    H.eq("basic", vim.fs.basename(a))
    write(a .. "/src/lib.rs", "// changed\n")
    H.eq(before, read(b .. "/src/lib.rs"))
    H.eq(before, read(fx .. "/basic/src/lib.rs"))
    H.not_ok(exists(a .. "/.git"), "no git unless asked")
    local g = H.fixture("workspace", { git = true })
    H.ok(exists(g .. "/.git"))
    H.eq("1", H.git(g, "rev-list", "--count", "HEAD"))
    H.eq("", H.git(g, "status", "--porcelain"))
    local f = H.fixture("standalone.rs")
    H.eq("standalone.rs", vim.fs.basename(f))
    H.eq(read(fx .. "/standalone.rs"), read(f))
    H.throws(function() H.fixture("no-such-fixture") end, "copying fixture")
  end)
end)

-- ============================================= 14. the original four specs

describe("existing specs", function()
  it("smoke (6), harness (8), routes (1) pass; rust passes (3) or skips; CHANGELOG says 18 passed", function()
    local r = run_real({ TEST_TIMEOUT = "300" }, { "/smoke_spec", "/harness_spec", "/routes_spec", "/rust_spec" })
    local rs = r.rows
    H.eq({ "PASS", 6, 0 }, { rs["smoke_spec.lua"].status, rs["smoke_spec.lua"].passed, rs["smoke_spec.lua"].failed })
    -- a test that needs tmux skips (not passes) on a machine without it
    H.eq({ "PASS", 8, 0 }, { rs["harness_spec.lua"].status, rs["harness_spec.lua"].passed + rs["harness_spec.lua"].skipped, rs["harness_spec.lua"].failed })
    H.eq({ "PASS", 1, 0 }, { rs["routes_spec.lua"].status, rs["routes_spec.lua"].passed, rs["routes_spec.lua"].failed })
    local ra = rs["rust_spec.lua"]
    if ra.status == "FAIL" or ra.status == "TIMEOUT" then
      -- rust-analyzer under heavy machine load: look again once, alone
      local again = bash(repo .. "/scripts/test.sh", { "/rust_spec" }, { TEST_TIMEOUT = "300" })
      ra = rows(again.out)["rust_spec.lua"]
    end
    H.eq("PASS", ra.status, "rust_spec")
    H.eq(3, ra.passed + ra.skipped)
    H.eq(0, ra.failed)
    local cl = read(repo .. "/CHANGELOG.md")
    H.match(cl, "18 passed on this machine", true)
    H.eq(18, 6 + 8 + 1 + 3, "the CHANGELOG figure is the sum of the four files")
  end)
end)

-- =========================================================== Makefile + README

local readme = H.docs_text()
local changelog = read(repo .. "/CHANGELOG.md")

--- text of a "## <title>" section up to the next "## "
local function section(text, title)
  local s = text:find("\n## " .. title:gsub("%p", "%%%0") .. "\n")
  H.ok(s, "section " .. title)
  local e = text:find("\n## ", s + 4, true)
  return text:sub(s, (e or #text + 1) - 1)
end

describe("Makefile", function()
  it("make test / make coverage call scripts/test.sh (ARGS passed through)", function()
    if vim.fn.executable("make") ~= 1 then
      skip("make not installed")
    end
    local t = sh({ "make", "-n", "--no-print-directory", "-C", repo, "test", "ARGS=smoke --list" })
    H.eq(0, t.code, t.out)
    H.eq("scripts/test.sh smoke --list", vim.trim(t.stdout))
    local c = sh({ "make", "-n", "--no-print-directory", "-C", repo, "coverage", "ARGS=smoke" })
    H.eq("scripts/test.sh --coverage smoke", vim.trim(c.stdout))
    H.match(read(repo .. "/Makefile"), ".PHONY: test coverage", true)
  end)
end)

describe("README 'Tests' section", function()
  local sec = section(read(repo .. "/docs/TESTING.md"), "Tests")

  it("documents every flag test.sh implements, and test.sh implements each documented flag", function()
    local script = read(repo .. "/scripts/test.sh")
    for _, flag in ipairs({ "--list", "--coverage", "--timeout", "-v" }) do
      H.match(sec, flag, true, "README mentions " .. flag)
      H.match(script, flag, true, "test.sh handles " .. flag)
    end
    H.match(sec, "$TEST_TIMEOUT", true)
    H.match(script, "TEST_TIMEOUT", true)
    H.match(sec, "default 120 s", true)
    H.match(script, "timeout_s=${TEST_TIMEOUT:-120}", true)
    -- -v / --verbose really prints the whole log of every file
    local v = run_real({}, { "/routes_spec", "-v" })
    H.match(v.out, "    | ok   rust_routes.scan_source", true)
    H.match(v.out, "    | XYNO_RESULT passed=1 failed=0 skipped=0", true)
    local q = run_real({}, { "/routes_spec" })
    H.no_match(q.out, "    | ", true, "quiet by default")
  end)

  it("exit statuses 0 / 1 / 2 are the ones test.sh uses", function()
    H.match(sec, "0 = no failure (skips allowed), 1 = a failure, timeout or crash, 2 = nothing matched or the setup is missing", true)
    -- 0: skip run (C), 1: run (A), 2: no match / setup
    H.eq(0, run_cov().code)
    H.eq(1, run_a().code)
    H.eq(2, bash(repo .. "/scripts/test.sh", { "zzz-none" }).code)
  end)

  it("every spec file the README lists exists and every helper it names is in tests/helpers.lua", function()
    for _, f in ipairs({ "smoke_spec.lua", "harness_spec.lua", "routes_spec.lua", "rust_spec.lua" }) do
      H.match(sec, f, true)
      H.ok(exists(repo .. "/tests/" .. f), f)
    end
    H.match(sec, "assertions (`eq ok not_ok is_nil match no_match has throws`)", true)
    for _, n in ipairs({ "eq", "ok", "not_ok", "is_nil", "match", "no_match", "has", "throws" }) do
      H.eq("function", type(H[n]), n)
    end
    local named = {
      "wait_for", "wait_lsp", "feed", "open", "clients", "diagnostics", "messages", "capture_notify", "fixture",
      "open_fixture", "git", "sandbox_sh", "tmux", "spawn", "tmpdir", "cleanup", "need_rust", "need_sandbox",
      "need_tmux", "skip_file",
    }
    for _, n in ipairs(named) do
      H.match(sec, n, true, "README names " .. n)
      H.eq("function", type(H[n]), "H." .. n)
    end
    for _, k in ipairs({ "describe", "it", "before_each", "after_each", "pending", "skip(reason)" }) do
      H.match(sec, k, true)
    end
  end)

  it("every fixture named exists", function()
    for _, f in ipairs({ "basic", "workspace", "broken", "standalone.rs", "sql_and_routes.rs" }) do
      H.match(sec, "`" .. f .. "`", true)
      H.ok(exists(repo .. "/tests/fixtures/" .. f), f)
    end
  end)

  it("isolation claims match test.sh (temp XDG dirs, real data dir, bootstrap hint, tmux socket prefix)", function()
    local script = read(repo .. "/scripts/test.sh")
    H.match(sec, "`XDG_STATE_HOME`, `XDG_CACHE_HOME` and `TMPDIR` are temp dirs", true)
    H.match(script, "export XDG_CONFIG_HOME=$work/config XDG_STATE_HOME=$work/state XDG_CACHE_HOME=$work/cache", true)
    H.match(script, "export XDG_DATA_HOME=$data", true)
    H.match(script, "export TMPDIR=$work/tmp", true)
    H.match(sec, "`xynotest-<pid>-*`", true)
    H.match(script, "export XYNO_TMUX_PREFIX=xynotest-$$", true)
    H.match(script, "set -m", true)
    H.match(sec, "`scripts/bootstrap.sh`", true)
    H.ok(exists(repo .. "/scripts/bootstrap.sh"))
  end)

  it("the CI job runs bootstrap, then test.sh, then the lockfile check", function()
    local ci = read(repo .. "/.github/workflows/ci.yml")
    local b = ci:find("scripts/bootstrap.sh", 1, true)
    local t = ci:find("scripts/test.sh", 1, true)
    H.ok(b and t and b < t, "bootstrap before test.sh")
    H.match(ci:sub(t), "lazy-lock.json", true, "lockfile check after the suite")
    H.match(sec, "`ci` workflow runs `scripts/bootstrap.sh`, then `scripts/test.sh`, then the lockfile check", true)
  end)
end)

describe("README layout and path claims", function()
  local layout = readme:match("## Layout\n\n```\n(.-)\n```")

  it("every directory and file in the layout block exists", function()
    H.ok(layout, "layout block")
    local n = 0
    for line in layout:gmatch("[^\n]+") do
      local first = line:match("^(%S+)")
      local rel = first:gsub("/$", "")
      H.ok(exists(repo .. "/" .. rel), "layout entry " .. first)
      n = n + 1
    end
    H.eq(17, n, "layout lists 17 entries")
    for _, want in ipairs({
      "lua/config/", "lua/xynovim/", "snippets/", "lua/plugins/", "colors/", "lua/island/", "lua/lualine/", "tools/",
      "scripts/", "tests/", "Makefile", "plugin/after/", "after/ftplugin/", "queries/", "after/queries/", ".github/", "site/",
    }) do
      H.match("\n" .. layout, "\n" .. want, true, want)
    end
  end)

  it("file names inside the layout lines exist in their directory", function()
    for line in layout:gmatch("[^\n]+") do
      local dir = line:match("^(%S+)"):gsub("/$", "")
      if vim.fn.isdirectory(repo .. "/" .. dir) == 1 then
        for name in line:gmatch("[%w_%-]+%.%a%w*") do
          if name:sub(1, 1) ~= "_" then -- "*_spec.lua"
            H.ok(exists(repo .. "/" .. dir .. "/" .. name), ("%s/%s named in the README layout"):format(dir, name))
          end
        end
      end
    end
    -- the lua/plugins file names in the parentheses
    local list = layout:match("lua/plugins/%s+one spec per concern %((.-)%)")
    H.ok(list)
    for _, p in ipairs(vim.split(list, ",")) do
      p = vim.trim(p)
      if p ~= "" and p ~= "…" then
        H.ok(exists(repo .. "/lua/plugins/" .. p .. ".lua"), "lua/plugins/" .. p .. ".lua")
      end
    end
    for _, p in ipairs({ "bacon-ls", "rustaceanvim", "ninety-nine", "auto-save", "dap", "gitsigns", "telescope", "island-theme" }) do
      H.match(list, p, true)
    end
    H.ok(exists(repo .. "/after/queries/rust"))
    H.ok(exists(repo .. "/.github/workflows/ci.yml"))
  end)

  it("every file path the README names resolves (lua/plugins, lua/config, plugin/after, tools)", function()
    local want = {}
    for _, p in ipairs({
      "bacon-ls", "rustaceanvim", "dap", "auto-save", "ninety-nine", "editing-ui", "navigation", "supply-chain",
      "coverage", "diffview", "domain", "gitsigns", "telescope", "island-theme", "lualine", "no-ghost-text", "xyno-history", "xyno-sandbox", "xyno-clipboard", "xyno-guard", "xyno-rust",
    }) do
      want[#want + 1] = "lua/plugins/" .. p .. ".lua"
    end
    for _, p in ipairs({
      "rust_assist", "ux",
    }) do
      want[#want + 1] = "lua/config/" .. p .. ".lua"
    end
    vim.list_extend(want, { "plugin/after/transparency.lua", "plugin/after/unsafe-highlight.lua", "tools/icls2nvim.py" })
    for _, rel in ipairs(want) do
      H.ok(exists(repo .. "/" .. rel), rel)
      local stem = (vim.fs.basename(rel):gsub("%.%a+$", ""))
      local mentioned = readme:find(stem, 1, true) or changelog:find(stem, 1, true)
      if stem == "rust_assist" then
        mentioned = true -- neither README nor CHANGELOG spells the module name; existence is the claim
      end
      H.ok(mentioned, rel .. " is named in README or CHANGELOG")
    end
  end)

  it("no backticked repo path in the README points at a missing file (placeholders and removed files excepted)", function()
    local missing = {}
    for p in readme:gmatch("`([^` ]+)`") do
      if
        p:match("^lua/") or p:match("^plugin/") or p:match("^tools/") or p:match("^scripts/") or p:match("^tests/")
        or p:match("^after/") or p:match("^snippets/") or p:match("^colors/")
      then
        if
          not p:find("[<*{~]")
          and p:match("%.%a+$")
          and p ~= "lua/plugins/theme.lua" -- named as a historical finding of roadmap step 1
          and p ~= "tools/Dark.icls" -- named in the CHANGELOG as the removed scheme export
          -- named in docs/HISTORY.md as they were, now the plugins xyno-history.nvim and xyno-sandbox.nvim
          and p ~= "lua/config/local_history.lua"
          and p ~= "lua/config/agent_sandbox.lua"
          -- named in docs/HISTORY.md as they were, now the modules of xyno-rust.nvim
          and p ~= "lua/config/rust_nav.lua"
          and p ~= "lua/config/rust_tasks.lua"
          and p ~= "lua/config/rust_routes.lua"
          and p ~= "lua/config/lsp_status.lua"
          and not exists(repo .. "/" .. p)
        then
          missing[#missing + 1] = p
        end
      end
    end
    H.eq({}, missing)
  end)

  it("the named commands exist: :checkhealth xynovim, :Mason, :Lazy, :LazyExtras", function()
    H.very_lazy()
    H.eq(2, vim.fn.exists(":checkhealth"))
    H.eq(2, vim.fn.exists(":Lazy"))
    H.eq(2, vim.fn.exists(":Mason"))
    H.eq(2, vim.fn.exists(":LazyExtras"))
    H.ok(exists(repo .. "/lua/xynovim/health.lua"))
    H.eq("function", type(require("xynovim.health").check))
    for _, c in ipairs({ ":checkhealth xynovim", ":Mason", ":LazyExtras", ":Lazy sync" }) do
      H.match(readme, "`" .. c .. "`", true, c .. " named in README")
    end
    vim.cmd("checkhealth xynovim")
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    vim.cmd("bwipeout!")
    H.match(text, "xynovim", true)
  end)
end)

-- =================================================== 19. numeric claims

describe("README mechanical numeric claims", function()
  it("'N of M plugins loaded' matches the plugin count; lazy-lock.json has an entry per plugin", function()
    local C = require("lazy.core.config")
    local actual = 0
    for _ in pairs(C.plugins) do
      actual = actual + 1
    end
    local lock = vim.json.decode(read(repo .. "/lazy-lock.json"))
    local nlock = vim.tbl_count(lock)
    H.eq(actual, require("lazy").stats().count)
    H.eq(actual, nlock, "plugins vs lazy-lock.json entries")
    local loaded, total = readme:match("(%d+) of (%d+) plugins loaded")
    H.ok(loaded, "README states 'N of M plugins loaded'")
    H.ok(tonumber(loaded) < actual)
    H.eq(actual, tonumber(total), "README plugin count vs the installed plugin count")
  end)

  it("independent .icls parse (fixture rebuilt from the palette): group colours/italics of the loaded scheme match (>= 35 checks)", function()
    local script = H.tmpdir() .. "/icls.py"
    write(
      script,
      [[
import json, sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
raw = {}
for o in root.iter("option"):
    v = o.find("value")
    if v is None and o.get("baseAttributes") is None:
        continue
    d = {}
    if v is not None:
        for s in v.findall("option"):
            d[s.get("name")] = s.get("value")
    raw[o.get("name")] = (d, o.get("baseAttributes"))
def res(n, seen=()):
    if n not in raw or n in seen:
        return {}
    d, base = raw[n]
    out = dict(res(base, seen + (n,))) if base else {}
    out.update(d)
    return out
print(json.dumps({n: res(n) for n in raw}))
]]
    )
    local fixture = H.tmpdir() .. "/fixture.icls"
    H.write_icls(fixture)
    local r = sh({ "python3", "-I", script, fixture })
    H.eq(0, r.code, r.out)
    local attrs = vim.json.decode(r.stdout)
    local pairs_ = {
      { "Keyword", "DEFAULT_KEYWORD" }, { "Statement", "DEFAULT_KEYWORD" }, { "Conditional", "DEFAULT_KEYWORD" },
      { "Repeat", "DEFAULT_KEYWORD" }, { "Label", "DEFAULT_KEYWORD" }, { "Include", "DEFAULT_KEYWORD" },
      { "Exception", "DEFAULT_KEYWORD" }, { "StorageClass", "DEFAULT_KEYWORD" }, { "Boolean", "DEFAULT_KEYWORD" },
      { "@boolean", "DEFAULT_KEYWORD" }, { "@constant.builtin", "DEFAULT_KEYWORD" }, { "@module.builtin", "DEFAULT_KEYWORD" },
      { "@type.builtin", "DEFAULT_KEYWORD" },
      { "String", "DEFAULT_STRING" }, { "Character", "DEFAULT_STRING" }, { "@string", "DEFAULT_STRING" },
      { "@character", "DEFAULT_STRING" }, { "@string.special.path", "DEFAULT_STRING" },
      { "Number", "DEFAULT_NUMBER" }, { "Float", "DEFAULT_NUMBER" }, { "@number", "DEFAULT_NUMBER" },
      { "@number.float", "DEFAULT_NUMBER" },
      { "Function", "DEFAULT_FUNCTION_DECLARATION" },
      { "Constant", "DEFAULT_CONSTANT" }, { "@constant", "DEFAULT_CONSTANT" }, { "@string.special.symbol", "DEFAULT_CONSTANT" },
      { "Operator", "DEFAULT_OPERATION_SIGN" },
      { "PreProc", "DEFAULT_METADATA" }, { "PreCondit", "DEFAULT_METADATA" },
      { "Special", "DEFAULT_VALID_STRING_ESCAPE" }, { "SpecialChar", "DEFAULT_VALID_STRING_ESCAPE" },
      { "@string.escape", "DEFAULT_VALID_STRING_ESCAPE" }, { "@string.special", "DEFAULT_VALID_STRING_ESCAPE" },
      { "@character.special", "DEFAULT_VALID_STRING_ESCAPE" },
      { "Delimiter", "DEFAULT_BRACKETS" },
      { "SpecialComment", "DEFAULT_DOC_COMMENT_TAG" },
      { "@variable.member", "DEFAULT_INSTANCE_FIELD" },
    }
    vim.cmd("colorscheme island-dark")
    local checked, bad = 0, {}
    for _, p in ipairs(pairs_) do
      local a = attrs[p[2]]
      if a and a.FOREGROUND then
        checked = checked + 1
        local hl = vim.api.nvim_get_hl(0, { name = p[1], link = false })
        local got = hl.fg and ("%06x"):format(hl.fg) or "none"
        local font = tonumber(a.FONT_TYPE or "0")
        local want_italic = (font == 2 or font == 3)
        if got ~= a.FOREGROUND:lower() then
          bad[#bad + 1] = ("%s fg %s expected %s (%s)"):format(p[1], got, a.FOREGROUND:lower(), p[2])
        end
        if (hl.italic == true) ~= want_italic then
          bad[#bad + 1] = ("%s italic %s expected %s (%s)"):format(p[1], tostring(hl.italic), tostring(want_italic), p[2])
        end
      end
    end
    H.eq({}, bad)
    H.ok(checked >= 35, "only " .. checked .. " attribute checks had an .icls foreground")
    -- the README claim is "49 group/attribute checks"; this independent re-implementation does `checked`
    H.match(readme, "49 group/attribute checks against an independent parse of an `.icls` rebuilt from the palette", true)
  end)
end)

-- ============================================== 21. roadmap done-items

describe("README roadmap 'done' items that can be checked mechanically", function()
  local C
  local function cfg()
    C = C or require("lazy.core.config")
    return C
  end
  local function keys_of(plugin)
    local p = cfg().plugins[plugin]
    H.ok(p, "plugin " .. plugin)
    local t = {}
    for _, k in pairs(p._.handlers.keys or {}) do
      t[#t + 1] = k.lhs or k[1]
    end
    return t
  end
  local function opts_of(plugin)
    return require("lazy.core.plugin").values(cfg().plugins[plugin], "opts", false)
  end

  it("lazyvim.json enables exactly the extras the README lists, and their plugins are in the spec", function()
    local json = vim.json.decode(read(repo .. "/lazyvim.json"))
    local have = {}
    for _, e in ipairs(json.extras) do
      have[#have + 1] = e:gsub("^lazyvim%.plugins%.extras%.", "")
    end
    table.sort(have)
    local line = readme:match("LazyVim extras enabled %(`lazyvim.json`%): (.-)%.\n")
    H.ok(line, "README extras line")
    local listed = {}
    for e in line:gmatch("`([^`]+)`") do
      listed[#listed + 1] = e
    end
    table.sort(listed)
    H.eq(listed, have)
    for _, e in ipairs({ "ui.treesitter-context", "editor.navic", "coding.mini-surround", "coding.neogen", "editor.inc-rename", "util.rest", "dap.core", "test.core", "editor.overseer" }) do
      H.has(have, e)
    end
    for _, pl in ipairs({ "nvim-treesitter-context", "nvim-navic", "mini.surround", "neogen", "inc-rename.nvim", "kulala.nvim", "nvim-dap", "neotest", "overseer.nvim", "rustaceanvim", "neo-tree.nvim" }) do
      H.ok(cfg().plugins[pl], pl .. " from an extra is in the plugin spec")
    end
  end)

  it("codelens is enabled; harpoon's add key moved to <leader>H", function()
    H.eq(true, opts_of("nvim-lspconfig").codelens.enabled)
    local hk = keys_of("harpoon")
    H.has(hk, "<leader>H")
    for _, k in ipairs(hk) do
      H.ok(k ~= "<leader>a", "<leader>a stays the AI prefix")
    end
    H.match(readme, "<leader>H", true)
  end)

  it("every <leader>9 / <leader>t* / <leader>g* / <leader>c* key the README names is registered", function()
    local nine = keys_of("99")
    for k in readme:gmatch("<leader>9%a*") do
      if k ~= "<leader>9" then
        H.has(nine, k, "99 key " .. k)
      end
    end
    local cov = keys_of("nvim-coverage")
    for _, k in ipairs({ "<leader>tc", "<leader>tg", "<leader>tG" }) do
      H.has(cov, k)
      H.match(readme, k, true)
    end
    local dv = keys_of("diffview.nvim")
    for _, k in ipairs({ "<leader>gv", "<leader>gV", "<leader>gF", "<leader>gq" }) do
      H.has(dv, k)
      H.match(readme, k, true)
    end
    local tr = keys_of("trouble.nvim")
    H.has(tr, "<leader>cI")
    H.has(tr, "<leader>cO")
  end)

  it("snippet prefixes, treesitter parsers sql/wgsl, kulala pin and blink without search_paths", function()
    local snippets = vim.json.decode(read(repo .. "/snippets/rust.json"))
    local prefixes = {}
    for _, s in pairs(snippets) do
      prefixes[#prefixes + 1] = s.prefix
    end
    for _, p in ipairs({ "testmod", "testfn", "ttest", "tmain", "impldisp", "implfrom", "dcommon" }) do
      H.has(prefixes, p)
      H.match(readme, "`" .. p .. "`", true)
    end
    H.has(opts_of("nvim-treesitter").ensure_installed, "sql")
    H.has(opts_of("nvim-treesitter").ensure_installed, "wgsl")
    local k = cfg().plugins["kulala.nvim"]
    H.eq("v5.3.4", k.tag)
    H.eq(false, k.submodules)
    H.match(readme, "v5.3.4", true)
    local lock = vim.json.decode(read(repo .. "/lazy-lock.json"))
    H.ok(lock["kulala.nvim"], "kulala.nvim is in the lockfile")
    local blink = opts_of("blink.cmp")
    H.is_nil(blink.snippets.search_paths)
    local prov = blink.sources and blink.sources.providers and blink.sources.providers.snippets
    H.is_nil(prov and prov.opts and prov.opts.search_paths)
    H.ok(exists(repo .. "/snippets"), "blink's default search path stdpath('config')/snippets")
  end)

  it("which-key group names: '99 (agent)' is in the plugin spec, 'rust' for <leader>r is added", function()
    -- read from the plugin spec file: at runtime which-key has already
    -- consumed (and reshaped) opts.spec once it is loaded
    local src = read(repo .. "/lua/plugins/editing-ui.lua")
    H.match(src, '{ "<leader>9", group = "99 (agent)" }', true)
    H.match(read(repo .. "/lua/config/keymaps.lua"), '{ "<leader>r", group = "rust"', true)
  end)
end)

-- ================================================= 22-24 CHANGELOG, Omarchy

describe("CHANGELOG.md", function()
  it("starts with [Unreleased] holding Added (test infra) and Removed (Omarchy)", function()
    local first = changelog:match("\n## (%[[^\n]*)\n")
    H.eq("[Unreleased]", first)
    local unreleased = changelog:match("\n## %[Unreleased%]\n(.-)\n## %[1%.8%.0%]")
    H.ok(unreleased, "Unreleased section precedes 1.8.0")
    local added = unreleased:match("### Added\n(.-)\n### Removed")
    local removed = unreleased:match("### Removed\n(.*)$")
    H.ok(added and removed)
    H.match(added, "Test infrastructure", true)
    H.match(added, "scripts/test.sh", true)
    H.no_match(added:lower(), "omarchy", true)
    H.match(removed, "All Omarchy support", true)
    H.match(removed, "omarchy-theme-hotreload.lua", true)
  end)

  it("lists 1.8.0 down to 0.1.0 with descending versions", function()
    local versions = {}
    for h in changelog:gmatch("\n## %[(%d+%.%d+%.%d+)%]") do
      versions[#versions + 1] = h
    end
    H.eq({ "1.8.0", "1.7.0", "1.6.0", "1.5.0", "1.4.1", "1.4.0", "1.3.0", "1.2.0", "1.1.0", "1.0.0", "0.2.0", "0.1.0" }, versions)
    local function key(v)
      local a, b, c = v:match("(%d+)%.(%d+)%.(%d+)")
      return a * 1e6 + b * 1e3 + c
    end
    for i = 2, #versions do
      H.ok(key(versions[i - 1]) > key(versions[i]), versions[i - 1] .. " above " .. versions[i])
    end
    H.match(changelog, "## [Unreleased — Windows lineage, superseded by 1.0.0 on this branch]", true)
  end)

  it("1.8.0 is the latest release, dated 2026-10-13; 1.5.0 to 1.8.0 all carry dates", function()
    H.match(changelog, "\n## [1.8.0] — 2026-10-13\n", true)
    for _, v in ipairs({ "1.7.0", "1.6.0", "1.5.0" }) do
      H.match(changelog, "\n## %[" .. v:gsub("%.", "%%.") .. "%] — 20%d%d%-%d%d%-%d%d\n", false, v)
    end
    -- README does not claim a newer version than the CHANGELOG has
    for v in readme:gmatch("[Vv]ersion %[?(%d+%.%d+%.%d+)") do
      H.ok(changelog:find("[" .. v .. "]", 1, true), "README names version " .. v)
    end
  end)

  it("'Omarchy' appears only in the Removed section and in entries older than 1.8.0 or in 1.8.0's history", function()
    local unreleased = changelog:match("\n## %[Unreleased%]\n(.-)\n## %[1%.8%.0%]")
    local before_removed = unreleased:match("^(.-)### Removed")
    H.no_match(before_removed:lower(), "omarchy", true)
    -- historical entries keep their wording
    H.match(changelog:lower(), "omarchy", true)
  end)
end)

describe("Omarchy removal", function()
  it("the plugin files are gone", function()
    for _, f in ipairs({ "omarchy-theme-hotreload.lua", "theme.lua", "all-themes.lua" }) do
      H.not_ok(exists(repo .. "/lua/plugins/" .. f), "lua/plugins/" .. f)
      H.not_ok(uv.fs_lstat(repo .. "/lua/plugins/" .. f), "not even a dangling symlink: " .. f)
    end
    H.ok(exists(repo .. "/lua/plugins/island-theme.lua"))
  end)

  it("no code reads omarchy variables or the follow flag", function()
    local r = sh({
      "grep", "-rniI", "omarchy", repo .. "/lua", repo .. "/plugin", repo .. "/after", repo .. "/colors", repo .. "/init.lua",
      repo .. "/snippets", repo .. "/tools", repo .. "/scripts", repo .. "/lazy-lock.json", repo .. "/lazyvim.json", repo .. "/Makefile",
    })
    H.eq({ 1, "" }, { r.code, vim.trim(r.stdout) })
    H.is_nil(vim.g.xynovim_follow_omarchy)
    H.is_nil(vim.g.omarchy_remote_clipboard_osc52)
    local lazy_lua = read(repo .. "/lua/config/lazy.lua")
    H.no_match(lazy_lua, "theme.lua", true)
    -- the replacement names exist
    H.match(read(repo .. "/lua/plugins/xyno-clipboard.lua"), "xynovim_remote_clipboard_osc52", true)
    H.eq("island-dark", vim.g.colors_name)
  end)

  it("the README mentions Omarchy nowhere as a feature (no theme switching)", function()
    local hits = {}
    for line in readme:gmatch("[^\n]+") do
      if line:lower():find("omarchy", 1, true) then
        hits[#hits + 1] = line
      end
    end
    for _, l in ipairs(hits) do
      H.match(l:lower(), "renam", false, "only the clipboard rename note may mention it: " .. l)
    end
    H.match(readme, "no theme-switching machinery", true)
  end)
end)

-- ============================================================ 25. hygiene

describe("repo hygiene", function()
  local function git(...)
    return sh({ "git", "-C", repo, ... })
  end

  it("no tracked file is owned by root", function()
    local r = git("ls-files", "-z")
    H.eq(0, r.code, r.out)
    local root_owned = {}
    for f in r.stdout:gmatch("([^%z]+)") do
      local st = uv.fs_lstat(repo .. "/" .. f)
      if st and st.uid == 0 then
        root_owned[#root_owned + 1] = f
      end
    end
    H.eq({}, root_owned)
  end)

  it("no .DS_Store, *.log or editor leftovers in the checkout", function()
    local r = sh({
      "find", repo, "(", "-path", repo .. "/.git", "-o", "-path", repo .. "/.remember", ")", "-prune", "-o",
      "(", "-name", ".DS_Store", "-o", "-name", "*.log", "-o", "-name", "*.orig", "-o", "-name", "*.rej", "-o", "-name", "*.swp", "-o", "-name", "*~", ")",
      "-print",
    })
    H.eq("", vim.trim(r.stdout))
  end)

  it("tests/fixtures and the test infrastructure are committed", function()
    for _, f in ipairs({
      "tests/fixtures/basic/Cargo.toml", "tests/fixtures/basic/src/lib.rs", "tests/fixtures/basic/src/main.rs",
      "tests/fixtures/basic/tests/it.rs", "tests/fixtures/workspace/Cargo.toml", "tests/fixtures/workspace/core/src/lib.rs",
      "tests/fixtures/workspace/app/src/main.rs", "tests/fixtures/broken/src/main.rs", "tests/fixtures/standalone.rs",
      "tests/fixtures/sql_and_routes.rs", "scripts/test.sh", "scripts/coverage.lua", "tests/harness.lua", "tests/helpers.lua",
      "tests/runner.lua", "tests/coverage_hook.lua", "tests/smoke_spec.lua", "Makefile",
    }) do
      local r = git("ls-files", "--error-unmatch", f)
      H.eq(0, r.code, f .. " is not tracked: " .. r.out)
    end
  end)

  it("scripts are executable and bash-syntax clean", function()
    for _, f in ipairs({ "scripts/test.sh", "scripts/bootstrap.sh" }) do
      local st = assert(uv.fs_stat(repo .. "/" .. f))
      H.ok(bit.band(st.mode, 73) ~= 0, f .. " is executable")
      H.eq(0, sh({ "bash", "-n", repo .. "/" .. f }).code, f)
    end
  end)

  it("the suite (including the nested runs above) left lazy-lock.json and the fixtures unchanged", function()
    H.eq(0, git("diff", "--quiet", "HEAD", "--", "lazy-lock.json", "lazyvim.json").code, "lockfile/lazyvim.json changed")
    H.eq(0, git("diff", "--quiet", "HEAD", "--", "tests/fixtures").code, "tracked fixtures changed")
    H.eq("", vim.trim(git("status", "--porcelain", "--", "tests/fixtures/basic", "tests/fixtures/workspace", "tests/fixtures/broken").stdout))
  end)
end)
