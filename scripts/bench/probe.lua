-- Runs INSIDE the measured headless nvim (started by bench.lua with -S).
-- BENCH_MODE = plugins | lsp | large; writes JSON to BENCH_OUT, then quits.
local uv = vim.uv
local mode, out = vim.env.BENCH_MODE, vim.env.BENCH_OUT
local project = vim.env.BENCH_PROJECT_DIR
local R = { mode = mode }

local function now()
  return uv.hrtime() / 1e6
end
local function r1(v)
  return math.floor(v * 10 + 0.5) / 10
end
local function since(t0)
  return r1(now() - t0)
end

local function stats(samples)
  if #samples == 0 then
    return { n = 0 }
  end
  local s = vim.deepcopy(samples)
  table.sort(s)
  local n = #s
  local med = n % 2 == 1 and s[(n + 1) / 2] or (s[n / 2] + s[n / 2 + 1]) / 2
  return { n = n, median = r1(med), min = r1(s[1]), max = r1(s[n]), samples = samples }
end

local function finish()
  local f = io.open(out, "w")
  if f then
    f:write(vim.json.encode(R))
    f:close()
  end
  vim.cmd("silent! qa!")
end

-- ------------------------------------------------------ process tree (linux)
local CLK = tonumber(vim.trim(vim.fn.system({ "getconf", "CLK_TCK" }))) or 100
local function read(p)
  local f = io.open(p)
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function snapshot()
  local procs = {}
  local h = uv.fs_scandir("/proc")
  while h do
    local name = uv.fs_scandir_next(h)
    if not name then
      break
    end
    if name:match("^%d+$") then
      local s = read("/proc/" .. name .. "/stat")
      local pid, comm, rest = (s or ""):match("^(%d+) %((.*)%) (.*)$")
      if pid then
        local f = vim.split(rest, " ", { plain = true })
        procs[tonumber(pid)] = { comm = comm, ppid = tonumber(f[2]), ticks = tonumber(f[12]) + tonumber(f[13]) }
      end
    end
  end
  local me = vim.fn.getpid()
  local tree, kids = { [me] = true }, {}
  for pid, p in pairs(procs) do
    kids[p.ppid] = kids[p.ppid] or {}
    table.insert(kids[p.ppid], pid)
  end
  local stack = { me }
  while #stack > 0 do
    local pid = table.remove(stack)
    for _, k in ipairs(kids[pid] or {}) do
      if not tree[k] then
        tree[k] = true
        table.insert(stack, k)
      end
    end
  end
  local snap = { pids = {}, by_comm = {}, total_kb = 0, nvim_kb = 0 }
  for pid in pairs(tree) do
    local st = read("/proc/" .. pid .. "/status")
    local kb = tonumber((st or ""):match("VmRSS:%s*(%d+)")) or 0
    local p = procs[pid]
    if p then
      snap.pids[pid] = { comm = p.comm, ticks = p.ticks, kb = kb }
      snap.total_kb = snap.total_kb + kb
      if pid == me then
        snap.nvim_kb = kb
      end
      local c = snap.by_comm[p.comm] or { n = 0, kb = 0 }
      c.n, c.kb = c.n + 1, c.kb + kb
      snap.by_comm[p.comm] = c
    end
  end
  return snap
end

local function mem_summary(s)
  local by = {}
  for comm, c in pairs(s.by_comm) do
    by[comm] = r1(c.kb / 1024)
  end
  return { total_mb = r1(s.total_kb / 1024), nvim_mb = r1(s.nvim_kb / 1024), by_comm_mb = by }
end

local function cpu_between(a, b, secs)
  local total, nv, by = 0, 0, {}
  local me = vim.fn.getpid()
  for pid, pb in pairs(b.pids) do
    local pa = a.pids[pid]
    if pa then
      local d = (pb.ticks - pa.ticks) / CLK / secs * 100
      total = total + d
      if pid == me then
        nv = d
      end
      by[pb.comm] = (by[pb.comm] or 0) + d
    end
  end
  for k, v in pairs(by) do
    by[k] = r1(v)
  end
  return r1(total), r1(nv), by
end

-- --------------------------------------------------------------- diagnostics
local function lsp_diags(buf)
  -- {client_name = {source=, code=, message=}[]} for every diagnostics namespace of the buffer
  local res = {}
  local nss = vim.diagnostic.get_namespaces()
  for ns, info in pairs(nss) do
    local cname = (info.name or ""):match("lsp%.(.-)%.%d+")
      or (info.name or ""):match("lsp%.(.+)$")
      or info.name
      or tostring(ns)
    for _, d in ipairs(vim.diagnostic.get(buf, { namespace = ns })) do
      res[cname] = res[cname] or {}
      table.insert(res[cname], { source = d.source, code = d.code, message = d.message })
    end
  end
  return res
end

local MARKERS = {
  -- rust-analyzer's own (native) diagnostic: a type mismatch it finds without running cargo
  ra = {
    body = { "", "pub fn bench_marker() {", '    let _bench_x: u32 = "x";', "}" },
    -- rust-analyzer words it "expected u32, found &str", rustc/cargo "mismatched types"; both are E0308
    match = function(d)
      local m = (d.message or ""):lower()
      return tostring(d.code or "") == "E0308"
        or m:find("mismatched types", 1, true) ~= nil
        or m:match("^expected .+, found ") ~= nil
    end,
  },
  -- a clippy lint (clippy::len_zero): only a clippy run can produce it
  clippy = {
    body = {
      "",
      "pub fn bench_marker() {",
      "    let bench_v: Vec<u8> = Vec::new();",
      "    if bench_v.len() == 0 {}",
      "}",
    },
    match = function(d)
      local t = ((d.message or "") .. " " .. tostring(d.code or "")):lower()
      return t:find("len_zero", 1, true) or t:find("length comparison to zero", 1, true) or t:find("clippy", 1, true)
    end,
  },
}

local function matching(buf, marker)
  local out_ = {}
  for cname, ds in pairs(lsp_diags(buf)) do
    for _, d in ipairs(ds) do
      if marker.match(d) then
        out_[cname] = d
        break
      end
    end
  end
  return out_
end

-- ------------------------------------------------------------------ helpers
local function wait_started()
  -- hook.lua starts this file only after VeryLazy (or its UIEnter fallback): the config is up
  R.ready_ms = _G.bench_marks and _G.bench_marks.very_lazy_idle
end

-- ---------------------------------------------------------------- modes
local function mode_plugins()
  wait_started()
  vim.wait(500)
  local function lazy_snapshot()
    local ok, Config = pcall(require, "lazy.core.config")
    if not ok then
      return nil
    end
    local list, loaded = {}, 0
    for name, p in pairs(Config.plugins) do
      local l = p._ and p._.loaded
      if l then
        loaded = loaded + 1
        local ns = tonumber(l.time) or 0
        table.insert(list, {
          name = name,
          ms = r1(ns / 1e6),
          phase = l.start and "start" or (l.source or l.plugin and ("lazy:" .. tostring(l.plugin)) or "lazy"),
        })
      end
    end
    table.sort(list, function(a, b)
      return a.ms > b.ms
    end)
    return list, loaded, vim.tbl_count(Config.plugins)
  end
  local list, loaded, count = lazy_snapshot()
  if not list then
    R.lazy_note = "lazy.nvim is not loaded in this config"
  else
    R.lazy = { count = count, loaded_at_start = loaded, top = {} }
    -- "phase": plugins loaded by the init (start) vs on demand; l.time is lazy's own profile (ns)
    for i = 1, math.min(25, #list) do
      R.lazy.top[i] = list[i]
    end
    local sum = 0
    for _, p in ipairs(list) do
      sum = sum + p.ms
    end
    R.lazy.sum_load_ms = r1(sum)
    local file = project .. "/src/lib.rs"
    vim.cmd("silent edit " .. vim.fn.fnameescape(file))
    vim.wait(4000)
    local list2, loaded2 = lazy_snapshot()
    R.lazy.loaded_after_rs = loaded2
    local top2 = {}
    local seen = {}
    for _, p in ipairs(list) do
      seen[p.name] = true
    end
    for _, p in ipairs(list2) do
      if not seen[p.name] then
        table.insert(top2, p)
      end
    end
    R.lazy.loaded_by_rs_file = {}
    for i = 1, math.min(15, #top2) do
      R.lazy.loaded_by_rs_file[i] = top2[i]
    end
  end
  R.clipboard = {
    provider = (function()
      local ok, v = pcall(vim.fn["provider#clipboard#Executable"])
      return ok and (v ~= "" and v or "none") or "error"
    end)(),
    option = vim.o.clipboard,
    g_clipboard = type(vim.g.clipboard) == "table" and vim.g.clipboard.name or nil,
    has_clipboard = vim.fn.has("clipboard") == 1,
  }
end

local function mode_lsp()
  wait_started()
  local file = project .. "/src/lib.rs"
  local attach, active, last_event = {}, {}, now()
  local t_open = now()
  vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(a)
      local c = vim.lsp.get_client_by_id(a.data.client_id)
      local name = c and c.name or tostring(a.data.client_id)
      if not attach[name] then
        attach[name] = since(t_open)
      end
      last_event = now()
    end,
  })
  vim.api.nvim_create_autocmd("LspProgress", {
    callback = function(a)
      local d = a.data or {}
      local v = d.params and d.params.value or {}
      local key = tostring(d.client_id) .. ":" .. tostring(d.params and d.params.token)
      if v.kind == "end" then
        active[key] = nil
      else
        active[key] = true
      end
      last_event = now()
    end,
  })
  vim.cmd("silent edit " .. vim.fn.fnameescape(file))
  local buf = vim.api.nvim_get_current_buf()
  vim.wait(120000, function()
    return next(attach) ~= nil
  end, 20)
  -- settled: no progress token open and no LSP event for 3 s
  local ok = vim.wait(240000, function()
    return next(active) == nil and now() - last_event > 3000 and now() - t_open > 5000
  end, 50)
  R.settled_ms = since(t_open) - 3000
  R.settled_timeout = not ok
  R.attach_ms = attach
  R.clients = vim.tbl_map(function(c)
    return c.name
  end, vim.lsp.get_clients())
  -- which server binary each client really runs (a config may use Mason's copy instead of PATH's)
  R.client_cmds = {}
  for _, c in ipairs(vim.lsp.get_clients()) do
    local cmd = c.config and c.config.cmd
    if type(cmd) == "table" and cmd[1] then
      R.client_cmds[c.name] = vim.fn.exepath(cmd[1]) ~= "" and vim.fn.exepath(cmd[1]) or cmd[1]
    end
  end
  local ra = R.client_cmds["rust-analyzer"] or R.client_cmds["rust_analyzer"]
  if ra then
    R.rust_analyzer_version = vim.trim(vim.fn.system({ ra, "--version" }))
  end
  R.diagnostics_on_open = vim.tbl_map(function(ds)
    return #ds
  end, lsp_diags(buf))

  -- idle memory and CPU after indexing
  local s1 = snapshot()
  R.memory_idle = mem_summary(s1)
  local win = 10
  vim.wait(win * 1000)
  local s2 = snapshot()
  R.cpu_window_s = win
  R.cpu_idle_pct, R.cpu_idle_nvim_pct, R.cpu_idle_by_comm_pct = cpu_between(s1, s2, win)

  -- edit -> first diagnostic
  local orig = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local n_trials = tonumber(vim.env.BENCH_TRIALS) or 5
  local timeout_ms = 20000
  R.trials = {}
  for _, kind in ipairs({ "ra", "clippy" }) do
    for _, emode in ipairs({ "type", "save" }) do
      local marker = MARKERS[kind]
      local cell = { kind = kind, mode = emode, attempts = 0, timeout_ms = timeout_ms, by_client = {}, firsts = {} }
      local per = {}
      for i = 0, n_trials do -- i = 0 is a discarded warm-up
        local arrivals = {}
        local t0 = now()
        local lines = vim.deepcopy(orig)
        vim.list_extend(lines, marker.body)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        if emode == "save" then
          vim.cmd("silent write")
        end
        local function poll()
          for cname, d in pairs(matching(buf, marker)) do
            if not arrivals[cname] then
              arrivals[cname] = { ms = now() - t0, source = d.source, code = d.code }
            end
          end
          return next(arrivals) ~= nil
        end
        local got = vim.wait(timeout_ms, poll, 5)
        if got then
          vim.wait(4000, function()
            poll()
            return false
          end, 5)
        end -- let the other tier arrive too
        if i > 0 then
          cell.attempts = cell.attempts + 1
          local first
          for cname, a in pairs(arrivals) do
            per[cname] = per[cname] or { vals = {}, source = a.source, code = a.code }
            table.insert(per[cname].vals, r1(a.ms))
            if not first or a.ms < first then
              first = a.ms
            end
          end
          if first then
            table.insert(cell.firsts, r1(first))
          end
        end
        -- revert and let the diagnostics clear before the next trial
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, orig)
        if emode == "save" then
          vim.cmd("silent write")
        end
        local cleared = vim.wait(15000, function()
          return next(matching(buf, marker)) == nil
        end, 20)
        if not cleared then
          cell.stale_after_revert = true
        end
        vim.wait(1500)
        if i == 0 and not got then
          break
        end -- nothing arrives at all: skip the remaining trials
      end
      for cname, p in pairs(per) do
        local st = stats(p.vals)
        st.source, st.code = p.source, p.code
        cell.by_client[cname] = st
      end
      cell.first = stats(cell.firsts)
      cell.firsts = nil
      table.insert(R.trials, cell)
    end
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, orig)
  vim.cmd("silent! write")
  R.memory_after_trials = mem_summary(snapshot())
end

local function mode_large()
  wait_started()
  local lines = tonumber(vim.env.BENCH_LARGE_LINES) or 100000
  local dir = vim.env.BENCH_WORK .. "/large"
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/large.rs"
  local f = assert(io.open(path, "w"))
  f:write("//! generated by scripts/bench for large-file behaviour\n")
  local n, i = 1, 0
  while n < lines do
    i = i + 1
    f:write(
      ('/// item %d\n#[derive(Debug, Clone)]\npub struct Item%d { pub id: u64, pub name: String }\n\nimpl Item%d {\n    pub fn new(id: u64) -> Self {\n        Self { id, name: format!("item-{}", id) }\n    }\n\n    pub fn bench_target_%d(&self) -> u64 {\n        self.id.wrapping_mul(%d) + self.name.len() as u64\n    }\n}\n\n'):format(
        i,
        i,
        i,
        i,
        i
      )
    )
    n = n + 14
  end
  f:close()
  R.lines = n
  R.bytes = uv.fs_stat(path).size
  local lag_max, last = 0, now()
  local timer = uv.new_timer()
  local tick = 10
  local counting = false
  timer:start(tick, tick, function()
    local t = now()
    if counting then
      lag_max = math.max(lag_max, t - last - tick)
    end
    last = t
  end)
  R.rss_before_mb = mem_summary(snapshot()).total_mb
  local t0 = now()
  vim.cmd("silent edit " .. vim.fn.fnameescape(path))
  R.open_ms = since(t0)
  local buf = vim.api.nvim_get_current_buf()
  R.filetype = vim.bo[buf].filetype
  last, counting = now(), true
  vim.wait(5000)
  counting = false
  R.idle_max_stall_ms = r1(lag_max)
  R.clients = vim.tbl_map(function(c)
    return c.name
  end, vim.lsp.get_clients({ bufnr = buf }))
  R.treesitter = (
    vim.treesitter.highlighter
    and vim.treesitter.highlighter.active
    and vim.treesitter.highlighter.active[buf]
  )
      and true
    or false
  R.bigfile = (vim.bo[buf].filetype == "bigfile") or vim.b[buf].snacks_bigfile or vim.b[buf].bigfile or false
  R.syntax = vim.bo[buf].syntax
  R.rss_after_open_mb = mem_summary(snapshot()).total_mb
  R.ops = {}
  local function timed(name, fn)
    local t = now()
    local ok, err = pcall(fn)
    R.ops[name] = ok and since(t) or nil
    if not ok then
      R.ops[name .. "_error"] = tostring(err)
    end
  end
  -- every op ends with :redraw, so drawing to the tmux pty is part of the time
  timed("goto_end", function()
    vim.cmd("normal! G")
    vim.cmd("redraw")
  end)
  timed("goto_start", function()
    vim.cmd("normal! gg")
    vim.cmd("redraw")
  end)
  timed("jump_20000_lines", function()
    vim.cmd("normal! 20000j")
    vim.cmd("redraw")
  end)
  timed("search", function()
    vim.cmd("silent! /bench_target_" .. math.floor((n / 14) * 0.9))
    vim.cmd("redraw")
  end)
  timed("page_down_x200", function()
    vim.cmd("normal! gg")
    for _ = 1, 200 do
      vim.cmd("normal! \4")
      vim.cmd("redraw")
    end
  end)
  timed("edit_middle", function()
    vim.cmd("normal! " .. math.floor(lines / 2) .. "G")
    vim.cmd("normal! ofn bench_inserted() {}")
    vim.cmd("redraw")
  end)
  timed("write", function()
    vim.cmd("silent write")
  end)
  vim.wait(2000)
  R.rss_after_ops_mb = mem_summary(snapshot()).total_mb
  timer:stop()
end

local fns = { plugins = mode_plugins, lsp = mode_lsp, large = mode_large }
local ok, err = xpcall(fns[mode], debug.traceback)
if not ok then
  R.error = tostring(err)
end
finish()
