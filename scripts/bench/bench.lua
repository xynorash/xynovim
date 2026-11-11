-- Orchestrator of the xynovim benchmark harness. Run through bench.sh (nvim -l).
-- Spawns separate headless nvim processes (one per metric group) in an isolated
-- environment and merges their JSON into one result file plus a readable table.
local uv = vim.uv
local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
local repo = vim.fs.dirname(vim.fs.dirname(here))

-- ------------------------------------------------------------------ options
local opts = { n = 10, trials = 5, only = nil, out = nil, md = nil, large_lines = "40000,100000", timeout = 240, label = nil }
do
  local a, i = _G.arg, 1
  local function val()
    i = i + 1
    return a[i]
  end
  while a[i] do
    local x = a[i]
    if x == "--out" then opts.out = val()
    elseif x == "--md" then opts.md = val()
    elseif x == "--label" then opts.label = val()
    elseif x == "--report" then opts.report = val()
    elseif x == "-n" then opts.n = tonumber(val())
    elseif x == "--trials" then opts.trials = tonumber(val())
    elseif x == "--large-lines" then opts.large_lines = val()
    elseif x == "--timeout" then opts.timeout = tonumber(val())
    elseif x == "--only" then opts.only = vim.split(val(), ",", { plain = true })
    elseif x == "-h" or x == "--help" then
      print(table.concat({
        "usage: scripts/bench/bench.sh [--out FILE.json] [--md FILE.md] [--label NAME] [--only startup,plugins,lsp,large]",
        "                              [-n STARTUPS] [--trials DIAG_TRIALS] [--large-lines N] [--timeout SEC]",
        "env: NVIM_APPNAME (default nvim), BENCH_CONFIG (config dir, default this repo),",
        "     XDG_CONFIG_HOME / XDG_DATA_HOME / XDG_STATE_HOME / XDG_CACHE_HOME (used as given when set),",
        "     BENCH_PROJECT (Cargo project to copy, default demo/netwatch), BENCH_NVIM (nvim binary)",
      }, "\n"))
      os.exit(0)
    else
      io.stderr:write("bench: unknown option " .. x .. "\n")
      os.exit(2)
    end
    i = i + 1
  end
end
local function want(name)
  if opts.report then return false end
  if not opts.only then return true end
  return vim.tbl_contains(opts.only, name)
end

-- -------------------------------------------------------------- environment
local nvim_bin = vim.env.BENCH_NVIM or "nvim"
local appname = vim.env.NVIM_APPNAME
if not appname or appname == "" then appname = "nvim" end
local config_src = vim.env.BENCH_CONFIG or repo
local work = vim.fn.tempname() -- /tmp/nvim.xxx/N: per-run private dir
vim.fn.mkdir(work, "p")

local env = { NVIM_APPNAME = appname }
local isolation = {}
if vim.env.XDG_CONFIG_HOME and vim.env.XDG_CONFIG_HOME ~= "" then
  env.XDG_CONFIG_HOME = vim.env.XDG_CONFIG_HOME
  isolation.config = "as given: " .. env.XDG_CONFIG_HOME .. "/" .. appname
else
  env.XDG_CONFIG_HOME = work .. "/config"
  vim.fn.mkdir(env.XDG_CONFIG_HOME, "p")
  uv.fs_symlink((vim.fn.fnamemodify(config_src, ":p"):gsub("/$", "")), env.XDG_CONFIG_HOME .. "/" .. appname)
  isolation.config = "symlink " .. config_src .. " -> temp XDG_CONFIG_HOME/" .. appname
end
for _, k in ipairs({ "STATE", "CACHE" }) do
  local v = vim.env["XDG_" .. k .. "_HOME"]
  if v and v ~= "" then
    env["XDG_" .. k .. "_HOME"] = v
    isolation[k:lower()] = "as given: " .. v
  else
    env["XDG_" .. k .. "_HOME"] = work .. "/" .. k:lower()
    vim.fn.mkdir(env["XDG_" .. k .. "_HOME"], "p")
    isolation[k:lower()] = "temp (fresh per run)"
  end
end
local data_home = vim.env.XDG_DATA_HOME
if data_home and data_home ~= "" then
  env.XDG_DATA_HOME = data_home
  isolation.data = "as given: " .. data_home
else
  data_home = vim.env.HOME .. "/.local/share"
  env.XDG_DATA_HOME = data_home
  isolation.data = "real " .. data_home .. " (plugins are not reinstalled)"
end
env.BENCH_APPNAME = appname

local function run(cmd, o)
  o = o or {}
  local e = vim.tbl_extend("force", env, o.env or {})
  local r = vim.system(cmd, { env = e, cwd = o.cwd, timeout = (o.timeout or opts.timeout) * 1000, text = true }):wait()
  return r
end

local function shq(x) return "'" .. tostring(x):gsub("'", "'\\''") .. "'" end

--- Run a command inside a private tmux server (a real pty: nvim gets a TUI, UIEnter and VeryLazy
--- fire, redraws happen). Waits until the command exits. Returns timed_out, pane_capture.
local project -- set below
local tmux_sock = "xynobench-" .. vim.fn.getpid()
local function run_tui(argv, o)
  o = o or {}
  local e = vim.tbl_extend("force", env, o.env or {})
  local parts = { "env" }
  for k, v in pairs(e) do table.insert(parts, k .. "=" .. shq(v)) end
  table.insert(parts, "BENCH_T0_MS=$(date +%s%3N)")
  for _, a in ipairs(argv) do table.insert(parts, shq(a)) end
  -- the trailing sleep keeps a fast-quitting nvim from closing the session before tmux returns
  local cmd = table.concat(parts, " ") .. "; sleep 0.3"
  local tm = { "tmux", "-L", tmux_sock, "-f", "/dev/null" }
  local function T(...) return vim.system(vim.list_extend(vim.deepcopy(tm), { ... }), { text = true }):wait() end
    local r = T("new-session", "-d", "-x", "200", "-y", "50", "-s", "b", "-c", o.cwd or project, "sh -c " .. shq(cmd))
  if r.code ~= 0 then return false, "tmux failed: " .. (r.stderr or "") end
  local deadline = uv.hrtime() / 1e9 + (o.timeout or opts.timeout)
  local capture
  while T("has-session", "-t", "b").code == 0 do
    if uv.hrtime() / 1e9 > deadline then
      capture = T("capture-pane", "-p", "-t", "b").stdout
      T("kill-server")
      return true, capture
    end
    vim.wait(100)
  end
  T("kill-server")
  return false, nil
end

local function first_line(cmd)
  local ok, r = pcall(function() return vim.system(cmd, { text = true }):wait() end)
  if not ok or r.code ~= 0 then return nil end
  return vim.trim((r.stdout or ""):match("[^\n]*"))
end

-- the project under test: a private copy (cargo target/ and bacon-ls shadow stay out of the repo)
local project_src = vim.env.BENCH_PROJECT or (repo .. "/demo/netwatch")
project = work .. "/project/" .. vim.fs.basename(project_src)
vim.fn.mkdir(vim.fs.dirname(project), "p")
vim.fn.system({ "cp", "-r", project_src, project })
vim.fn.system({ "rm", "-rf", project .. "/target" })
local target_file = project .. "/src/lib.rs"

local function read_file(p)
  local f = io.open(p)
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function mason_bin(name)
  local p = data_home .. "/" .. appname .. "/mason/bin/" .. name
  if uv.fs_stat(p) then return p end
  return vim.fn.exepath(name) ~= "" and vim.fn.exepath(name) or nil
end

local function collect_env()
  local cpu = (read_file("/proc/cpuinfo") or ""):match("model name%s*:%s*([^\n]+)")
  local mem = (read_file("/proc/meminfo") or ""):match("MemTotal:%s*(%d+)")
  local bacon = mason_bin("bacon-ls")
  local sha = first_line({ "git", "-C", config_src, "rev-parse", "--short", "HEAD" })
  -- (the harness's own files and its results do not make a config "dirty")
  local dirty = first_line({ "git", "-C", config_src, "status", "--porcelain", "--", ".", ":!scripts/bench", ":!docs/bench" })
  return {
    date_utc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    nvim_appname = appname,
    config_dir = config_src,
    config_git = sha and (sha .. ((dirty and dirty ~= "") and " (dirty)" or "")) or "not a git checkout",
    machine = {
      kernel = first_line({ "uname", "-sr" }),
      cpu = cpu,
      logical_cpus = #(vim.uv.cpu_info() or {}),
      mem_total_mb = mem and math.floor(tonumber(mem) / 1024) or nil,
      cpu_governor = vim.trim(read_file("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor") or "n/a"),
      loadavg_at_start = vim.trim(read_file("/proc/loadavg") or ""),
    },
    tools = {
      nvim = first_line({ nvim_bin, "--version" }),
      rust_analyzer = first_line({ "rust-analyzer", "--version" }),
      cargo = first_line({ "cargo", "--version" }),
      clippy = first_line({ "cargo", "clippy", "--version" }),
      bacon_ls = bacon and first_line({ bacon, "--version" }) or "not found",
    },
    isolation = isolation,
    project = project_src,
    settings = { startup_runs = opts.n, diag_trials = opts.trials, large_lines = opts.large_lines },
  }
end

-- --------------------------------------------------------------- statistics
local function stats(samples)
  if #samples == 0 then return { n = 0 } end
  local s = vim.deepcopy(samples)
  table.sort(s)
  local n = #s
  local med = n % 2 == 1 and s[(n + 1) / 2] or (s[n / 2] + s[n / 2 + 1]) / 2
  local sum = 0
  for _, v in ipairs(s) do sum = sum + v end
  local function r(v) return math.floor(v * 10 + 0.5) / 10 end
  return { n = n, median = r(med), min = r(s[1]), max = r(s[n]), mean = r(sum / n), samples = samples }
end

local result = { env = collect_env(), notes = {}, metrics = {} }
local M = result.metrics
local logdir = (opts.out and vim.fs.dirname(opts.out) or work) .. "/"
local function note(s) table.insert(result.notes, s) end

local function probe(mode, extra_env, timeout)
  local out = work .. "/" .. mode .. ".json"
  local e = vim.tbl_extend("force", {
    BENCH_MODE = mode,
    BENCH_PROBE = here .. "/probe.lua",
    BENCH_OUT = out,
    BENCH_PROJECT_DIR = project,
    BENCH_TRIALS = tostring(opts.trials),
    BENCH_WORK = work,
    BENCH_LARGE_LINES = tostring(opts.large_lines),
    CARGO_TARGET_DIR = project .. "/target",
  }, extra_env or {})
  local t0 = uv.hrtime()
  os.remove(out)
  local timed_out, capture = run_tui(
    { nvim_bin, "-n", "--cmd", "luafile " .. here .. "/hook.lua" },
    { env = e, cwd = project, timeout = timeout }
  )
  local log = work .. "/" .. mode .. ".log"
  local lf = io.open(log, "w")
  if lf then lf:write("timed_out=", tostring(timed_out), "\nscreen at end:\n", capture or "(nvim exited)", "\n") lf:close() end
  local r = { code = timed_out and "timeout" or 0 }
  local raw = read_file(out)
  local ok, data = pcall(vim.json.decode, raw or "")
  if not ok or type(data) ~= "table" then
    return nil, ("%s probe produced no result (exit %s, signal %s, %.0fs); stderr: %s"):format(
      mode, tostring(r.code), "-", (uv.hrtime() - t0) / 1e9, vim.trim((capture or ""):sub(1, 300)))
  end
  return data
end

-- ---------------------------------------------------------------- startup
local function startup()
  local function one(file_arg)
    local out, tf = work .. "/startup.json", work .. "/startuptime.log"
    os.remove(out)
    os.remove(tf)
    local argv = { nvim_bin, "-n", "--startuptime", tf, "--cmd", "luafile " .. here .. "/hook.lua" }
    if file_arg then table.insert(argv, file_arg) end
    local timed_out = run_tui(argv, { env = { BENCH_MODE = "startup", BENCH_OUT = out }, timeout = 90 })
    local ok, marks = pcall(vim.json.decode, read_file(out) or "")
    if not ok or timed_out then return nil end
    for line in (read_file(tf) or ""):gmatch("[^\n]+") do
      local t = line:match("^%s*(%d+%.%d+)%s+%d+%.%d+:%s+%-%-%- NVIM STARTED")
      if t then marks.nvim_started = tonumber(t) end
    end
    return marks
  end
  local first = one(nil) -- first run: fresh state and cache dirs (lazy's module cache is cold)
  local function series(file_arg)
    local acc = { nvim_started = {}, vimenter = {}, uienter = {}, very_lazy = {}, very_lazy_idle = {} }
    for _ = 1, opts.n do
      local m = one(file_arg)
      if m then
        for k, list in pairs(acc) do
          if m[k] then table.insert(list, m[k]) end
        end
      end
    end
    local res = {}
    for k, list in pairs(acc) do res[k] = stats(list) end
    return res
  end
  M.startup = {
    first_run_cold_cache = first,
    tui = series(nil),
    tui_open_rs_file = series(target_file),
    method = "nvim -n --startuptime F in a tmux pty (real TUI); nvim_started = 'NVIM STARTED' in the startuptime log; "
      .. "vimenter/uienter/very_lazy = wall clock from the shell right before exec to that event (includes exec, 'env', tmux pty setup excluded). "
      .. "Run 1 is discarded as cold-cache and reported separately.",
  }
end

-- ----------------------------------------------------------------- driver
local function pre_warm()
  -- compile dependencies once so the first LSP flycheck measures analysis, not downloads/compiles
  local r = vim.system({ "cargo", "clippy", "--all-targets" }, { cwd = project, env = { CARGO_TARGET_DIR = project .. "/target" }, text = true, timeout = 600000 }):wait()
  if r.code ~= 0 then note("cargo clippy pre-warm failed: " .. vim.trim((r.stderr or ""):sub(-300))) end
end

if want("startup") then startup() end
local do_proj = want("plugins") or want("lsp")
if do_proj then pre_warm() end
if want("plugins") then
  local d, err = probe("plugins", nil, 120)
  if d then M.plugins = d else note(err) end
end
if want("lsp") then
  local d, err = probe("lsp", nil, opts.timeout * 3)
  if d then M.lsp = d else note(err) end
end
if want("large") then
  M.large_file = {}
  for _, n in ipairs(vim.split(tostring(opts.large_lines), ",", { plain = true })) do
    local d, err = probe("large", { BENCH_LARGE_LINES = n }, opts.timeout)
    if d then table.insert(M.large_file, d) else note(err) end
  end
end

-- ----------------------------------------------------------------- report
local function f1(v) return v == nil and "n/a" or (type(v) == "number" and string.format("%.1f", v) or tostring(v)) end
local function cell(s)
  if not s or s.n == 0 then return "n/a" end
  return string.format("%s (min %s, max %s, n=%d)", f1(s.median), f1(s.min), f1(s.max), s.n)
end

local function insp(v)
  local t = vim.inspect(v or {}):gsub("%s+", " ")
  return (t:gsub("vim%.empty_dict%(%)", "none"))
end

local function table_text()
  local L = {}
  local function add(...) table.insert(L, string.format(...)) end
  local e = result.env
  add("Benchmark: %s   config=%s (%s)   %s", opts.label or appname, e.nvim_appname, e.config_git, e.date_utc)
  add("%s | %s CPUs | %s MB | %s", e.machine.cpu or "?", e.machine.logical_cpus, e.machine.mem_total_mb, e.tools.nvim or "?")
  add("rust-analyzer: %s | bacon-ls: %s", e.tools.rust_analyzer or "n/a", e.tools.bacon_ls or "n/a")
  add("")
  if M.startup then
    add("== Startup (ms, real TUI in a tmux pty) ==")
    local fr = M.startup.first_run_cold_cache
    add("  first run, cold cache: NVIM STARTED %s, ready %s", f1(fr and fr.nvim_started), f1(fr and fr.very_lazy_idle))
    for _, v in ipairs({ { "tui", "no file     " }, { "tui_open_rs_file", "with .rs file" } }) do
      local t = M.startup[v[1]]
      add("  %s NVIM STARTED  %s", v[2], cell(t.nvim_started))
      add("  %s UIEnter       %s", v[2], cell(t.uienter))
      add("  %s VeryLazy fired  %s", v[2], cell(t.very_lazy))
      add("  %s ready (VeryLazy plugins loaded) %s", v[2], cell(t.very_lazy_idle))
    end
    add("")
  end
  local P = M.plugins
  if P then
    if P.lazy then
      add("== Plugins (lazy.nvim) ==")
      add("  plugins %s, loaded once the config is up (after VeryLazy) %s; after opening a .rs file: %s; sum of load times %s ms",
        f1(P.lazy.count), f1(P.lazy.loaded_at_start), f1(P.lazy.loaded_after_rs), f1(P.lazy.sum_load_ms))
      add("  slowest to load (ms, all phases):")
      for i, p in ipairs(P.lazy.top or {}) do
        if i > 12 then break end
        add("    %-34s %7.1f  (%s)", p.name, p.ms, p.phase)
      end
      local by = P.lazy.loaded_by_rs_file or {}
      if #by > 0 then
        add("  loaded by opening a .rs file (top):")
        for i, p in ipairs(by) do
          if i > 8 then break end
          add("    %-34s %7.1f", p.name, p.ms)
        end
      end
    else
      add("== Plugins == not measured: %s", tostring(P.lazy_note))
    end
    add("  clipboard: provider=%s, vim.o.clipboard=%q", tostring(P.clipboard and P.clipboard.provider), tostring(P.clipboard and P.clipboard.option))
    add("")
  end
  local D = M.lsp
  if D then
    add("== LSP on %s ==", vim.fs.basename(result.env.project))
    if D.error then add("  ERROR: %s", D.error) end
    add("  clients attached (ms after :edit): %s", insp(D.attach_ms))
    add("  settled after (ms, quiet 3 s)    : %s%s", f1(D.settled_ms), D.settled_timeout and " (TIMED OUT, never quiet)" or "")
    if D.memory_idle then
      add("  idle RSS MB: total %s, nvim %s; by process: %s", f1(D.memory_idle.total_mb), f1(D.memory_idle.nvim_mb), insp(D.memory_idle.by_comm_mb))
      add("  idle CPU (%% of 1 core, %ss window): total %s; nvim %s; %s", f1(D.cpu_window_s), f1(D.cpu_idle_pct), f1(D.cpu_idle_nvim_pct), insp(D.cpu_idle_by_comm_pct))
    end
    if D.memory_after_trials then add("  RSS MB after the trials: total %s", f1(D.memory_after_trials.total_mb)) end
    add("  edit -> first matching diagnostic (ms; per cell: fastest source overall / per client):")
    for _, c in ipairs(D.trials or {}) do
      local per = {}
      for name, s in pairs(c.by_client or {}) do table.insert(per, string.format("%s %s [%d/%d]", name, f1(s.median), s.n, c.attempts)) end
      table.sort(per)
      add("    %-7s %-6s first=%-9s %s", c.kind, c.mode, c.first and c.first.n > 0 and f1(c.first.median) or "none", #per > 0 and table.concat(per, "; ") or ("no diagnostic within " .. c.timeout_ms .. " ms"))
    end
    add("")
  end
  for _, Lg in ipairs(M.large_file or {}) do
    add("== Large file (%s lines, %.1f MB, outside a crate) ==", f1(Lg.lines), (Lg.bytes or 0) / 1048576)
    if Lg.error then add("  ERROR: %s", Lg.error) end
    add("  open: %s ms | max main-loop stall while idle 5 s: %s ms | clients: %s | treesitter hl: %s | bigfile mode: %s | filetype=%s",
      f1(Lg.open_ms), f1(Lg.idle_max_stall_ms), insp(Lg.clients), tostring(Lg.treesitter), tostring(Lg.bigfile), tostring(Lg.filetype))
    local ops = {}
    for _, k in ipairs({ "goto_end", "goto_start", "jump_20000_lines", "search", "page_down_x200", "edit_middle", "write" }) do
      if Lg.ops and Lg.ops[k] then table.insert(ops, string.format("%s %s", k, f1(Lg.ops[k]))) end
    end
    add("  ops (ms, each ends with :redraw to a tmux pty): %s", table.concat(ops, " | "))
    add("  RSS MB: before open %s, after open %s, after ops %s", f1(Lg.rss_before_mb), f1(Lg.rss_after_open_mb), f1(Lg.rss_after_ops_mb))
    add("")
  end
  if #result.notes > 0 then
    add("== Notes ==")
    for _, n in ipairs(result.notes) do add("  - %s", n) end
  end
  return table.concat(L, "\n")
end

-- pretty json with sorted keys (deterministic diffs)
local function encode(v, ind)
  ind = ind or ""
  if type(v) ~= "table" then return vim.json.encode(v) end
  local nxt = ind .. "  "
  if vim.islist(v) and #v > 0 then
    local flat = true
    for _, x in ipairs(v) do if type(x) == "table" then flat = false end end
    if flat then return vim.json.encode(v) end
    local parts = {}
    for _, x in ipairs(v) do table.insert(parts, nxt .. encode(x, nxt)) end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "]"
  end
  local keys = vim.tbl_keys(v)
  if #keys == 0 then return "{}" end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do table.insert(parts, nxt .. vim.json.encode(tostring(k)) .. ": " .. encode(v[k], nxt)) end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "}"
end

if opts.report then
  -- re-render a saved result: no measuring
  local ok, saved = pcall(vim.json.decode, read_file(opts.report) or "")
  assert(ok and type(saved) == "table", "cannot read " .. opts.report)
  result, M = saved, saved.metrics
end
local txt = table_text()
print(txt)
if opts.out then
  vim.fn.mkdir(vim.fs.dirname(opts.out), "p")
  local f = assert(io.open(opts.out, "w"))
  f:write(encode(result), "\n")
  f:close()
  if #result.notes > 0 then
    -- a probe failed: keep its log (tmux screen at the end) next to the results
    local logs = (opts.out:gsub("%.json$", "")) .. ".logs"
    vim.fn.system({ "sh", "-c", ("mkdir -p '%s' && cp '%s'/plugins.log '%s'/lsp.log '%s'/large.log '%s'/ 2>/dev/null"):format(logs, work, work, work, logs) })
  end
end
if opts.md then
  local e = result.env
  local f = assert(io.open(opts.md, "w"))
  f:write(("# Benchmark: %s\n\nMeasured %s with `scripts/bench/bench.sh` (see `scripts/bench/README.md`). Raw data: `%s`.\n\n"):format(
    opts.label or e.nvim_appname, e.date_utc, opts.out and vim.fs.basename(opts.out) or "the .json next to this file"))
  f:write("## Machine and tools\n\n")
  f:write(("- CPU: %s, %s logical CPUs, %s MB RAM, governor `%s`, load average at start `%s`\n"):format(
    e.machine.cpu or "?", e.machine.logical_cpus, e.machine.mem_total_mb, e.machine.cpu_governor, e.machine.loadavg_at_start))
  f:write(("- Kernel: %s\n- %s\n- %s\n- %s\n- %s\n- bacon-ls %s\n"):format(
    e.machine.kernel, e.tools.nvim, e.tools.rust_analyzer, e.tools.cargo, e.tools.clippy, e.tools.bacon_ls))
  f:write(("- Config: `%s` at git %s, NVIM_APPNAME `%s`\n- Project: `%s`\n"):format(e.config_dir, e.config_git, e.nvim_appname, e.project))
  f:write(("- Isolation: config %s; state %s; cache %s; data %s\n\n"):format(e.isolation.config, e.isolation.state, e.isolation.cache, e.isolation.data))
  f:write("## Results\n\n```\n", txt, "\n```\n")
  f:close()
end
vim.fn.system({ "rm", "-rf", work })
