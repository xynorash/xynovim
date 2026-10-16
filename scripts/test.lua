-- Portable spec runner: the same job as scripts/test.sh, in Lua, so it runs
-- wherever Neovim does (Windows included, no bash needed).
--
--   nvim --clean -l scripts/test.lua [options] [pattern...]
--
--   pattern       only spec files whose path contains it (several = any of them)
--   --list        print the spec files and exit
--   --timeout N   hard timeout per spec file in seconds (default 120, or $TEST_TIMEOUT);
--                 a "-- xyno-timeout: N" line in a spec raises it for that file
--   -v            print the full output of every spec file, not only failures
--
-- Same isolation and protocol as test.sh: each spec file runs in its own
-- `nvim --headless -S tests/runner.lua` (XYNO_SPEC=<file>) with the checkout
-- linked as the config under a temp XDG_CONFIG_HOME, temp XDG_STATE_HOME /
-- XDG_CACHE_HOME / TMPDIR, the REAL plugin data dir (bootstrap first), and the
-- XYNO_RESULT line of the runner parsed. Exit status: 0 all passed (skips
-- allowed), 1 any failure / timeout / crash, 2 usage or setup. No coverage mode
-- (use test.sh --coverage on Linux).
local uv = vim.uv

-- (print() goes to stderr under `nvim -l`)
local function out_line(s)
  io.stdout:write(s, "\n")
  io.stdout:flush()
end
local is_win = vim.fn.has("win32") == 1

local script = vim.fs.normalize(arg[0] or "scripts/test.lua")
local repo = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(script, ":p")))

local timeout_s = tonumber(vim.env.TEST_TIMEOUT) or 120
local list, verbose, patterns = false, false, {}
do
  local i = 1
  while i <= #arg do
    local a = arg[i]
    if a == "--list" then
      list = true
    elseif a == "--timeout" then
      i = i + 1
      timeout_s = tonumber(arg[i])
      if not timeout_s then
        io.stderr:write("test.lua: --timeout needs seconds\n")
        os.exit(2)
      end
    elseif a == "-v" or a == "--verbose" then
      verbose = true
    elseif a:sub(1, 1) == "-" then
      io.stderr:write("test.lua: unknown option " .. a .. "\n")
      os.exit(2)
    else
      patterns[#patterns + 1] = a
    end
    i = i + 1
  end
end

local specs = {}
for name, kind in vim.fs.dir(repo .. "/tests") do
  if kind == "file" and name:match("_spec%.lua$") then
    local rel = "tests/" .. name
    local hit = #patterns == 0
    for _, p in ipairs(patterns) do
      hit = hit or rel:find(p, 1, true) ~= nil
    end
    if hit then
      specs[#specs + 1] = rel
    end
  end
end
table.sort(specs)

if list then
  out_line(table.concat(specs, "\n"))
  os.exit(0)
end
if #specs == 0 then
  io.stderr:write("test.lua: no spec file matches " .. table.concat(patterns, " ") .. "\n")
  os.exit(2)
end

local nvim = vim.v.progpath
local data = vim.fn.stdpath("data")
if not uv.fs_stat(data .. "/lazy/lazy.nvim") then
  io.stderr:write("test.lua: no plugins in " .. data .. "/lazy. Run scripts/bootstrap first\n")
  os.exit(2)
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local work = assert(uv.fs_mkdtemp((vim.env.TMPDIR or vim.env.RUNNER_TEMP or vim.fn.fnamemodify(vim.fn.tempname(), ":h")) .. "/xynotest.XXXXXX"))
work = vim.fs.normalize(work)
for _, d in ipairs({ "config", "state", "cache", "tmp" }) do
  vim.fn.mkdir(work .. "/" .. d, "p")
end
local lock_before = read(repo .. "/lazy-lock.json")

-- The checkout as <XDG_CONFIG_HOME>/nvim: a symlink, or a junction on Windows (no admin rights needed).
local link = work .. "/config/nvim"
if is_win then
  local r = vim.system({ "cmd", "/c", "mklink", "/J", (link:gsub("/", "\\")), (repo:gsub("/", "\\")) }, { text = true }):wait()
  if r.code ~= 0 then
    io.stderr:write("test.lua: mklink /J failed: " .. (r.stderr or r.stdout or "") .. "\n")
    os.exit(2)
  end
else
  assert(uv.fs_symlink(repo, link))
end

local prefix = "xynotest-" .. uv.os_getpid()
local env = {
  XDG_CONFIG_HOME = work .. "/config",
  XDG_STATE_HOME = work .. "/state",
  XDG_CACHE_HOME = work .. "/cache",
  XYNO_TEST_TMP = work .. "/tmp",
  TMPDIR = work .. "/tmp",
  XYNO_TMUX_PREFIX = prefix,
  XYNO_COV_ROOTS = work .. "/config/nvim:" .. repo,
}
if is_win then
  env.TEMP, env.TMP = work .. "/tmp", work .. "/tmp"
end

local function cleanup()
  if not is_win and vim.fn.executable("tmux") == 1 then
    local pw = uv.os_get_passwd()
    local dir = (vim.env.TMUX_TMPDIR or "/tmp") .. "/tmux-" .. (pw and pw.uid or 0)
    if uv.fs_stat(dir) then
      for name in vim.fs.dir(dir) do
        if name:sub(1, #prefix) == prefix then
          vim.system({ "tmux", "-L", name, "kill-server" }):wait(5000)
          uv.fs_unlink(dir .. "/" .. name)
        end
      end
    end
  end
  vim.fn.delete(work, "rf")
end

local function kill_tree(obj)
  if is_win then
    vim.system({ "taskkill", "/T", "/F", "/PID", tostring(obj.pid) }):wait(10000)
  else
    pcall(obj.kill, obj, 9)
  end
end

out_line(("xynovim tests: %d spec file(s), timeout %ds each (portable runner, %s)"):format(#specs, timeout_s, uv.os_uname().sysname))
if vim.env.XYNO_TEST_SKIP_RUST == "1" then
  out_line("  XYNO_TEST_SKIP_RUST=1 (Rust specs will skip)")
elseif vim.fn.executable("cargo") == 1 and vim.fn.executable("rust-analyzer") == 1
  and vim.system({ "rust-analyzer", "--version" }):wait(10000).code == 0 then
  out_line("  rust-analyzer + cargo: found (Rust specs run)")
else
  out_line("  rust-analyzer/cargo: NOT usable (Rust specs will skip)")
end

local tot = { passed = 0, failed = 0, skipped = 0 }
local failed_files = {}
local t_all = uv.now()

for _, rel in ipairs(specs) do
  local head = {}
  local fh = io.open(repo .. "/" .. rel, "rb")
  if fh then
    for _ = 1, 15 do
      head[#head + 1] = fh:read("*l") or ""
    end
    fh:close()
  end
  local eff = timeout_s
  for _, l in ipairs(head) do
    local n = l:match("^%-%- xyno%-timeout: *(%d+)")
    if n and tonumber(n) > eff then
      eff = tonumber(n)
    end
  end

  local chunks, seen_at, done, code = {}, nil, false, nil
  local function on_data(_, d)
    if d then
      chunks[#chunks + 1] = d
      if not seen_at and d:find("XYNO_RESULT ", 1, true) then
        seen_at = uv.now()
      end
    end
  end
  local e = vim.tbl_extend("force", env, { XYNO_SPEC = repo .. "/" .. rel })
  local t0 = uv.now()
  local obj = vim.system({ nvim, "--headless", "-S", repo .. "/tests/runner.lua" }, {
    env = e,
    stdin = false,
    stdout = on_data,
    stderr = on_data,
    text = true,
  }, function(o)
    code, done = o.code, true
  end)
  local timed_out, hung = false, false
  while not done do
    vim.wait(500, function()
      return done
    end, 100)
    local now = uv.now()
    if not done and now - t0 > eff * 1000 then
      timed_out = true
      kill_tree(obj)
      vim.wait(10000, function()
        return done
      end, 100)
      break
    end
    -- the result line was printed but nvim does not exit: 30 s of grace, then it is killed
    if not done and seen_at and now - seen_at > 30000 then
      hung = true
      kill_tree(obj)
      vim.wait(10000, function()
        return done
      end, 100)
      break
    end
  end
  local secs = math.floor((uv.now() - t0) / 1000)
  local out = table.concat(chunks)
  local res
  for line in out:gmatch("[^\r\n]+") do
    if line:find("^XYNO_RESULT ") then
      res = line
    end
  end
  local status, p, f, s
  if timed_out then
    status, p, f, s = "TIMEOUT", 0, 1, 0
  elseif not res then
    status, p, f, s = "CRASH", 0, 1, 0
  else
    p, f, s = tonumber(res:match("passed=(%d+)")), tonumber(res:match("failed=(%d+)")), tonumber(res:match("skipped=(%d+)"))
    if hung then
      code = 0
    end
    if f > 0 or code ~= 0 then
      status = "FAIL"
      f = math.max(f, 1)
    else
      status = "PASS"
    end
  end
  tot.passed, tot.failed, tot.skipped = tot.passed + p, tot.failed + f, tot.skipped + s
  out_line(("%-7s %s  %d passed, %d failed, %d skipped (%ds)"):format(status, rel, p, f, s, secs))
  if hung then
    out_line("    NOTE: nvim did not exit 30 s after the result line and was killed (the result above counts)")
  end
  if status ~= "PASS" then
    failed_files[#failed_files + 1] = rel
  end
  local lines = vim.split(out, "\r?\n")
  if verbose then
    for _, l in ipairs(lines) do
      out_line("    | " .. l)
    end
  else
    for _, l in ipairs(lines) do
      if l:find("^SKIP") or l:find("^FAIL") or l:find("^       ") then
        out_line("    " .. l)
      end
    end
    if status == "TIMEOUT" or status == "CRASH" then
      out_line(("    (%s, exit %s; last output)"):format(status, tostring(code)))
      for i = math.max(1, #lines - 15), #lines do
        out_line("    | " .. lines[i])
      end
    end
  end
  io.stdout:flush()
end

if read(repo .. "/lazy-lock.json") ~= lock_before then
  out_line("WARNING: lazy-lock.json changed during the run (git diff lazy-lock.json)")
end
cleanup()
out_line(("\ntotal: %d passed, %d failed, %d skipped in %ds"):format(tot.passed, tot.failed, tot.skipped, math.floor((uv.now() - t_all) / 1000)))
if #failed_files > 0 then
  out_line("failed: " .. table.concat(failed_files, " "))
  os.exit(1)
end
os.exit(0)
