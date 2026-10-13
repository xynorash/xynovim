-- config/local_history.lua (snapshots of the worktree on refs/lochist/*, the
-- :LocalHistory* commands) and its 99 integration (plugins/ninety-nine.lua).
-- Hermetic: temp repos, a private GIT_CONFIG_GLOBAL, a logging/fault-injecting
-- `git` wrapper first in PATH (hangs, failures, lock errors, delays), timers
-- and os.time are shimmed where the real thing would take a minute.
local H = require("xynotest.helpers")
local LH = require("config.local_history")

local REAL_GIT = vim.fn.exepath("git")
local uv = vim.uv

-- LazyVim's keymaps/autocmds hang off VeryLazy, which never fires headless
-- (before any vim.notify shim: noice complains about a replaced vim.notify)
H.very_lazy()

-- ------------------------------------------------------------------ plumbing

local base = H.tmpdir()
local ctl = base .. "/ctl" -- XYNO_FAKE: fault injection + log of the fake git
local time_offset, timer_scale, scale_watchdog = 0, nil, false
local deferred, timer_starts, timer_news = {}, {}, 0

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
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

-- the fake git: logs "<GIT_INDEX_FILE>\t<args>", then does what ctl/<subcommand> says
write(
  base .. "/bin/git",
  [[#!/bin/bash
d="$XYNO_FAKE"
if [ -n "$d" ] && [ -d "$d" ]; then
  printf '%s\t%s\n' "$GIT_INDEX_FILE" "$*" >> "$d/log"
  if [ -f "$d/$1" ]; then
    mode=$(head -n1 "$d/$1")
    case "$mode" in
      hang) echo $$ > "$d/$1.pid"; exec sleep 600 ;;
      fail) echo "fatal: injected failure" >&2; exit 128 ;;
      failonce) rm -f "$d/$1"; echo "fatal: injected failure" >&2; exit 128 ;;
      lockindex) echo "fatal: Unable to create '$GIT_INDEX_FILE.lock': File exists." >&2; exit 128 ;;
      lockonce:*) rm -f "$d/$1"; echo "fatal: Unable to create '${mode#lockonce:}': File exists." >&2; exit 128 ;;
      slowonce:*) rm -f "$d/$1"; echo $$ > "$d/$1.pid"; sleep "${mode#slowonce:}" ;;
      failif:*) case "$*" in *"${mode#failif:}"*) echo "fatal: injected failure" >&2; exit 128 ;; esac ;;
      slow:*) echo $$ > "$d/$1.pid"; sleep "${mode#slow:}" ;;
      snapindex) cp "$GIT_INDEX_FILE" "$d/index-before" 2>/dev/null ;;
    esac
  fi
fi
exec "]] .. REAL_GIT .. [[" "$@"
]]
)
vim.fn.setfperm(base .. "/bin/git", "rwxr-xr-x")
write(base .. "/global_ignore", "*.globalignored\n")
write(base .. "/gitconfig", "[core]\n\texcludesFile = " .. base .. "/global_ignore\n")

do
  local saved = {}
  for _, k in ipairs({ "PATH", "XYNO_FAKE", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM" }) do
    saved[k] = vim.env[k]
  end
  vim.env.PATH = base .. "/bin:" .. vim.env.PATH
  vim.env.XYNO_FAKE = ctl
  vim.env.GIT_CONFIG_GLOBAL = base .. "/gitconfig"
  vim.env.GIT_CONFIG_NOSYSTEM = "1"

  local real_time, real_defer, real_new_timer = os.time, vim.defer_fn, uv.new_timer
  os.time = function(t)
    if t then
      return real_time(t)
    end
    return real_time() + time_offset
  end
  vim.defer_fn = function(fn, ms)
    deferred[#deferred + 1] = ms
    if scale_watchdog and ms == 30000 then
      ms = 300
    end
    return real_defer(fn, ms)
  end
  -- proxy: records start() timeouts, divides them by timer_scale when set
  uv.new_timer = function()
    local real = real_new_timer()
    -- only the timers of local_history.lua (vim.defer_fn makes timers too)
    local src = debug.getinfo(2, "S").source
    if not src:find("local_history.lua", 1, true) then
      return real
    end
    timer_news = timer_news + 1
    return setmetatable({ real = real }, {
      __index = function(self, k)
        return function(_, ...)
          local args = { ... }
          if k == "start" then
            timer_starts[#timer_starts + 1] = args[1]
            if timer_scale then
              args[1] = math.max(1, math.floor(args[1] / timer_scale))
            end
          end
          return self.real[k](self.real, unpack(args))
        end
      end,
    })
  end
  H._restore[#H._restore + 1] = function()
    os.time, vim.defer_fn, uv.new_timer = real_time, real_defer, real_new_timer
    for k, v in pairs(saved) do
      vim.env[k] = v
    end
  end
end

--- Find an upvalue by name through the closures of `fn` (module state).
local function upv(fn, name, seen)
  seen = seen or {}
  if seen[fn] then
    return nil
  end
  seen[fn] = true
  local i = 1
  while true do
    local n, v = debug.getupvalue(fn, i)
    if not n then
      break
    end
    if n == name then
      return v
    end
    i = i + 1
  end
  i = 1
  while true do
    local n, v = debug.getupvalue(fn, i)
    if not n then
      break
    end
    if type(v) == "function" then
      local r = upv(v, name, seen)
      if r ~= nil then
        return r
      end
    end
    i = i + 1
  end
end
local function state(name)
  return upv(LH.snapshot, name)
end

local function run(dir, args, stdin)
  local cmd = { REAL_GIT, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "core.quotepath=false" }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { cwd = dir, text = true, stdin = stdin }):wait(60000)
end
--- real git, trimmed stdout, raises on failure
local function G(dir, ...)
  local r = run(dir, { ... })
  if r.code ~= 0 then
    error(("git %s failed (%d): %s"):format(table.concat({ ... }, " "), r.code, r.stderr), 2)
  end
  return vim.trim(r.stdout)
end
local function tip(root, ref)
  local r = run(root, { "rev-parse", "-q", "--verify", ref })
  return r.code == 0 and vim.trim(r.stdout) or nil
end
local function names(root, rev)
  local out = {}
  for _, n in ipairs(vim.split(G(root, "ls-tree", "-r", "--name-only", "-z", rev), "\0", { plain = true })) do
    if n ~= "" then
      out[#out + 1] = n
    end
  end
  return out
end
local function blob(root, rev, rel)
  local r = run(root, { "show", rev .. ":" .. rel })
  return r.code == 0 and r.stdout or nil
end
local function count(root, ref)
  return tonumber(G(root, "rev-list", "--count", ref))
end
local function subject(root, ref)
  return G(root, "log", "-1", "--format=%s", ref)
end
local function lochist_refs(root)
  local out = {}
  for _, r in ipairs(vim.split(G(root, "for-each-ref", "--format=%(refname)", "refs/lochist"), "\n", { plain = true })) do
    if r ~= "" then
      out[#out + 1] = r
    end
  end
  table.sort(out)
  return out
end
local function fsck_clean(root)
  local r = run(root, { "fsck", "--strict" })
  H.eq(0, r.code, "git fsck: " .. (r.stderr or "") .. (r.stdout or ""))
  H.no_match((r.stderr or "") .. (r.stdout or ""), "error", true)
  H.no_match((r.stderr or "") .. (r.stdout or ""), "missing", true)
end
local function dirsize(path)
  local total = 0
  local h = uv.fs_scandir(path)
  while h do
    local name, t = uv.fs_scandir_next(h)
    if not name then
      break
    end
    local p = path .. "/" .. name
    if t == "directory" then
      total = total + dirsize(p)
    else
      local st = uv.fs_lstat(p)
      total = total + (st and st.size or 0)
    end
  end
  return total
end

local function mkrepo(files)
  local dir = H.tmpdir()
  local root = uv.fs_realpath(dir) .. "/repo"
  vim.fn.mkdir(root, "p")
  G(root, "init", "-q", "-b", "main")
  for rel, text in pairs(files or { ["a.txt"] = "a\n" }) do
    write(root .. "/" .. rel, text)
  end
  G(root, "add", "-A")
  G(root, "commit", "-q", "-m", "init")
  return root
end

--- Synchronous snapshot: forced by default; returns the commit (nil when nothing changed or failed).
local function snap(root, opts)
  opts = vim.tbl_extend("force", { path = root, force = true }, opts or {})
  local called, commit = false, nil
  local user_done = opts.done
  opts.done = function(c)
    called, commit = true, c
    if user_done then
      user_done(c)
    end
  end
  LH.snapshot(opts)
  H.wait_for(function()
    return called
  end, 30000, "snapshot done callback")
  return commit
end

-- fake git control
local function fake(sub, mode)
  write(ctl .. "/" .. sub, mode .. "\n")
end
local function fake_log()
  local ok, lines = pcall(vim.fn.readfile, ctl .. "/log")
  return ok and lines or {}
end
local function log_count(pat)
  local n = 0
  for _, l in ipairs(fake_log()) do
    if l:find(pat) then
      n = n + 1
    end
  end
  return n
end
local function wait_pidfile(sub)
  local pid = H.wait_for(function()
    return tonumber(read(ctl .. "/" .. sub .. ".pid"))
  end, 10000, "fake git " .. sub .. " started")
  return pid
end
local function pid_alive(pid)
  return uv.kill(pid, 0) == 0
end

-- notifications
local notes, orig_notify = {}, vim.notify
local function note_matching(pat)
  local out = {}
  for _, n in ipairs(notes) do
    if n.msg:find(pat, 1, true) then
      out[#out + 1] = n
    end
  end
  return out
end

-- vim.ui.select
local orig_select, sel_calls = vim.ui.select, {}
local function mock_select(pick_fn)
  sel_calls = {}
  vim.ui.select = function(items, opts, cb)
    sel_calls[#sel_calls + 1] = { items = items, opts = opts }
    local idx = pick_fn(items, opts, #sel_calls)
    if idx then
      cb(items[idx], idx)
    else
      cb(nil)
    end
  end
end

local function open_file(root, rel)
  vim.cmd.cd(vim.fn.fnameescape(root))
  return H.open(root .. "/" .. rel)
end

--- Commits on `ref` (oldest first) through fast-import: items = { {days=age, content=, msg=} }.
local function chain(root, ref, items, file)
  file = file or "f.txt"
  local now = os.time()
  local s = {}
  for i, it in ipairs(items) do
    local msg = it.msg or ("snap" .. i)
    s[#s + 1] = ("commit %s\nmark :%d\ncommitter xynovim <lochist@xynovim> %d +0000\ndata %d\n%s\n"):format(
      ref, i, now - (it.days or 0) * 86400, #msg, msg
    )
    if i > 1 then
      s[#s + 1] = ("from :%d\n"):format(i - 1)
    end
    s[#s + 1] = ("M 100644 inline %s\ndata %d\n%s\n\n"):format(file, #it.content, it.content)
  end
  local r = run(root, { "fast-import", "--quiet" }, table.concat(s))
  H.eq(0, r.code, "fast-import: " .. (r.stderr or ""))
end

local function select_nth(n)
  return function()
    return n
  end
end

-- --------------------------------------------------------------------- hooks

local function reset_module_state()
  for _, n in ipairs({ "last", "failed", "running", "pending", "runs" }) do
    local t = state(n)
    if t then
      for k in pairs(t) do
        t[k] = nil
      end
    end
  end
  local timers = state("timers")
  for k, t in pairs(timers or {}) do
    pcall(function()
      t:stop()
      if not t:is_closing() then
        t:close()
      end
    end)
    timers[k] = nil
  end
end

before_each(function()
  vim.cmd("silent! %bwipeout!")
  vim.cmd("enew")
  vim.cmd.cd(vim.fn.fnameescape(base))
  vim.fn.delete(ctl, "rf")
  vim.fn.mkdir(ctl, "p")
  vim.g.xynovim_lochist_max_bytes = nil
  time_offset, timer_scale, scale_watchdog = 0, nil, false
  deferred, timer_starts, timer_news = {}, {}, 0
  notes = {}
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  pcall(function()
    require("auto-save").off()
  end)
end)

after_each(function()
  vim.notify = orig_notify
  vim.ui.select = orig_select
  time_offset, timer_scale, scale_watchdog = 0, nil, false
  for _, f in ipairs(vim.fn.glob(ctl .. "/*.pid", true, true)) do
    local pid = tonumber(read(f))
    if pid then
      uv.kill(pid, 9)
    end
  end
  reset_module_state()
end)

-- ------------------------------------------------------------ 1. wiring

describe("wiring", function()
  it("defines :LocalHistory, :LocalHistoryPrune[!] and :LocalHistoryRestore with the documented arities", function()
    local cmds = vim.api.nvim_get_commands({})
    H.eq("0", cmds.LocalHistory.nargs)
    H.eq("?", cmds.LocalHistoryPrune.nargs)
    H.eq(true, cmds.LocalHistoryPrune.bang)
    H.eq("0", cmds.LocalHistoryRestore.nargs)
  end)

  it("maps <leader>gH to :LocalHistory", function()
    local m = vim.fn.maparg(vim.g.mapleader .. "gH", "n", false, true)
    H.eq("<cmd>localhistory<cr>", (m.rhs or ""):lower())
  end)

  it("registers the xynovim_local_history autocmds (User AutoSaveWritePost, BufWritePost, VimLeavePre)", function()
    local seen = {}
    for _, a in ipairs(vim.api.nvim_get_autocmds({ group = "xynovim_local_history" })) do
      seen[a.event] = a.pattern
    end
    H.eq("AutoSaveWritePost", seen.User)
    H.ok(seen.BufWritePost, "BufWritePost")
    H.ok(seen.VimLeavePre, "VimLeavePre")
  end)

  it("a :write of a buffer takes a snapshot (BufWritePost)", function()
    local root = mkrepo()
    open_file(root, "a.txt")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "saved" })
    vim.cmd.write()
    local ref = "refs/lochist/main"
    H.wait_for(function()
      return tip(root, ref)
    end, 15000, "snapshot after :write")
    H.eq("saved\n", blob(root, ref, "a.txt"))
    H.eq("autosave", subject(root, ref))
  end)
end)

-- --------------------------------------------------------- 2-8. snapshots

describe("snapshot", function()
  it("outside a git repository returns silently and creates nothing", function()
    local dir = H.tmpdir()
    write(dir .. "/x.txt", "x\n")
    local called = false
    local ok, err = pcall(LH.snapshot, { path = dir .. "/x.txt", force = true, done = function() called = true end })
    H.ok(ok, tostring(err))
    vim.wait(400)
    H.not_ok(called, "done must not be called without a repo")
    H.is_nil(uv.fs_stat(dir .. "/.git"))
    H.eq({ "x.txt" }, vim.fn.readdir(dir))
    H.eq(0, log_count("add"), "no git add was run")
    H.eq({}, notes)
    -- an unnamed buffer is no path either
    H.ok(pcall(LH.snapshot, { path = "", force = true }))
  end)

  it("commits the whole worktree incl. untracked files; real index, stash, branches, HEAD, status untouched", function()
    local root = mkrepo({ ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
    write(root .. "/a.txt", "a changed unstaged\n")
    write(root .. "/b.txt", "b staged\n")
    G(root, "add", "b.txt")
    write(root .. "/new.txt", "untracked\n")
    G(root, "stash", "push", "-q", "-m", "mine")
    write(root .. "/a.txt", "a changed again\n")
    write(root .. "/new.txt", "untracked\n")
    local before = {
      status = G(root, "status", "--porcelain"),
      head = G(root, "rev-parse", "HEAD"),
      stash = G(root, "stash", "list"),
      branches = G(root, "for-each-ref", "refs/heads", "refs/stash", "refs/tags"),
    }
    local c = snap(root)
    H.ok(c, "a commit")
    H.eq(c, tip(root, "refs/lochist/main"))
    H.eq(before.status, G(root, "status", "--porcelain"))
    H.eq(before.head, G(root, "rev-parse", "HEAD"))
    H.eq(before.stash, G(root, "stash", "list"))
    H.eq(before.branches, G(root, "for-each-ref", "refs/heads", "refs/stash", "refs/tags"))
    H.eq({ "refs/lochist/main" }, lochist_refs(root))
    H.eq("a changed again\n", blob(root, c, "a.txt"))
    H.eq("b\n", blob(root, c, "b.txt"))
    H.eq("untracked\n", blob(root, c, "new.txt"))
    H.eq(
      "xynovim|lochist@xynovim|xynovim|lochist@xynovim|autosave",
      G(root, "log", "-1", "--format=%an|%ae|%cn|%ce|%s", c)
    )
    -- label override + the parent chain
    write(root .. "/new.txt", "untracked 2\n")
    local c2 = snap(root, { label = "before 99 request" })
    H.ok(c2 and c2 ~= c)
    H.eq("before 99 request", subject(root, c2))
    H.eq(c, G(root, "rev-parse", c2 .. "^"))
  end)

  it("uses a private index (GIT_INDEX_FILE=.git/lochist-index.<pid>), the real .git/index is not modified", function()
    local root = mkrepo({ ["a.txt"] = "a\n" })
    write(root .. "/new.txt", "n\n")
    G(root, "status", "--porcelain") -- refreshes the real index first
    local real = root .. "/.git/index"
    local bytes, st = read(real), uv.fs_stat(real)
    H.ok(snap(root))
    H.eq(bytes, read(real), "real index content")
    local st2 = uv.fs_stat(real)
    H.eq(st.mtime.sec, st2.mtime.sec)
    H.eq(st.mtime.nsec, st2.mtime.nsec)
    local mine = root .. "/.git/lochist-index." .. uv.os_getpid()
    H.ok(uv.fs_stat(mine) and uv.fs_stat(mine).size > 0, "private index exists")
    local seen = {}
    for _, l in ipairs(fake_log()) do
      local idx, args = l:match("^(.-)\t(%S+)")
      if args == "add" or args == "write-tree" or args == "commit-tree" then
        H.eq(mine, idx, args .. " must run with the private index")
      end
      seen[args or ""] = true
    end
    H.ok(seen.add and seen["write-tree"] and seen["commit-tree"], "add, write-tree, commit-tree ran")
  end)

  it("a snapshot with no change since the last one creates no commit (done gets nil)", function()
    local root = mkrepo()
    local c = snap(root)
    H.ok(c)
    H.is_nil(snap(root), "second snapshot")
    H.eq(1, count(root, "refs/lochist/main"))
    H.eq(c, tip(root, "refs/lochist/main"))
    -- and one more change makes a new one again
    write(root .. "/a.txt", "changed\n")
    H.ok(snap(root))
    H.eq(2, count(root, "refs/lochist/main"))
  end)

  it("done(commit) is called with the commit hash; M.snapshot takes the current buffer when no path is given", function()
    local root = mkrepo()
    open_file(root, "a.txt")
    local got, called = nil, false
    LH.snapshot({ force = true, done = function(c) got, called = c, true end })
    H.wait_for(function() return called end, 15000, "done")
    H.eq(tip(root, "refs/lochist/main"), got)
  end)
end)

-- ----------------------------------------------------- 5-6. refs and branches

describe("refs", function()
  it("encodes % and / in branch names; foo and foo/bar get distinct plain files", function()
    local root = mkrepo()
    G(root, "checkout", "-q", "-b", "foo/bar")
    local c1 = snap(root)
    G(root, "checkout", "-q", "-b", "other")
    G(root, "branch", "-q", "-D", "foo/bar")
    G(root, "checkout", "-q", "-b", "foo")
    local c2 = snap(root)
    G(root, "checkout", "-q", "-b", "100%/x")
    local c3 = snap(root)
    H.eq({ "refs/lochist/100%25%2Fx", "refs/lochist/foo", "refs/lochist/foo%2Fbar" }, lochist_refs(root))
    H.eq(c1, tip(root, "refs/lochist/foo%2Fbar"))
    H.eq(c2, tip(root, "refs/lochist/foo"))
    H.eq(c3, tip(root, "refs/lochist/100%25%2Fx"))
    H.eq("file", uv.fs_stat(root .. "/.git/refs/lochist/foo").type)
    H.eq("file", uv.fs_stat(root .. "/.git/refs/lochist/foo%2Fbar").type)
  end)

  it("a detached HEAD uses refs/lochist/%detached-<12 char sha>", function()
    local root = mkrepo()
    G(root, "checkout", "-q", "--detach")
    local sha12 = G(root, "rev-parse", "--short=12", "HEAD")
    H.eq(12, #sha12)
    local c = snap(root)
    H.ok(c)
    H.eq({ "refs/lochist/%detached-" .. sha12 }, lochist_refs(root))
    H.eq(c, tip(root, "refs/lochist/%detached-" .. sha12))
  end)

  it("renames legacy refs/lochist/<a/b> once to the encoded form (create+delete, nothing lost)", function()
    local root = mkrepo()
    local c = G(root, "rev-parse", "HEAD")
    G(root, "update-ref", "refs/lochist/a/b", c)
    G(root, "update-ref", "refs/lochist/x%/y", c)
    H.ok(snap(root))
    H.eq(c, tip(root, "refs/lochist/a%2Fb"))
    H.eq(c, tip(root, "refs/lochist/x%25%2Fy"))
    H.is_nil(tip(root, "refs/lochist/a/b"))
    H.is_nil(tip(root, "refs/lochist/x%/y"))
    H.ok(tip(root, "refs/lochist/main"))
    -- once per session and repo: a legacy ref that shows up later stays
    G(root, "update-ref", "refs/lochist/late/one", c)
    write(root .. "/a.txt", "again\n")
    H.ok(snap(root))
    H.eq(c, tip(root, "refs/lochist/late/one"))
    H.is_nil(tip(root, "refs/lochist/late%2Fone"))
  end)

  it("a pre-existing encoded target aborts the whole rename transaction without losing anything", function()
    local root = mkrepo()
    local c1 = G(root, "rev-parse", "HEAD")
    write(root .. "/a.txt", "second\n")
    G(root, "commit", "-q", "-am", "second")
    local c2 = G(root, "rev-parse", "HEAD")
    G(root, "update-ref", "refs/lochist/c/d", c1)
    G(root, "update-ref", "refs/lochist/c%2Fd", c2)
    G(root, "update-ref", "refs/lochist/e/f", c1)
    H.ok(snap(root))
    H.eq(c1, tip(root, "refs/lochist/c/d"), "legacy c/d kept")
    H.eq(c2, tip(root, "refs/lochist/c%2Fd"), "existing target untouched")
    H.eq(c1, tip(root, "refs/lochist/e/f"), "the other rename of the transaction did not happen either")
    H.is_nil(tip(root, "refs/lochist/e%2Ff"))
  end)
end)

-- ------------------------------------------------------ 7. excludes

describe("excludes", function()
  it("keeps target/ out via one .git/info/exclude line (also from git status); .gitignore and the global ignore are honoured", function()
    local root = mkrepo({ ["keep.txt"] = "k\n", [".gitignore"] = "*.gitignored\n" })
    write(root .. "/.git/info/exclude", "# mine\n*.bak\n")
    write(root .. "/.git/lochist-exclude", "old\n")
    for rel, text in pairs({
      ["x.gitignored"] = "1",
      ["x.globalignored"] = "2",
      ["x.bak"] = "3",
      ["target/debug/a"] = "4",
      ["sub/target/b"] = "5",
      ["pkg/target-notes.txt"] = "6",
    }) do
      write(root .. "/" .. rel, text)
    end
    local c = snap(root)
    H.ok(c)
    H.eq({ ".gitignore", "keep.txt", "pkg/target-notes.txt" }, names(root, c))
    local ex = vim.fn.readfile(root .. "/.git/info/exclude")
    H.eq({ "# mine", "*.bak", "target/" }, ex)
    H.is_nil(uv.fs_stat(root .. "/.git/lochist-exclude"), "old lochist-exclude removed")
    H.no_match(G(root, "status", "--porcelain"), "target", true)
    -- a second session (prepare runs again): still a single line
    state("prepared")[root] = nil
    write(root .. "/keep.txt", "k2\n")
    H.ok(snap(root))
    H.eq({ "# mine", "*.bak", "target/" }, vim.fn.readfile(root .. "/.git/info/exclude"))
  end)

  it("does not add a second line when the user already excludes /target", function()
    local root = mkrepo()
    write(root .. "/.git/info/exclude", "/target\n")
    write(root .. "/target/x", "x")
    local c = snap(root)
    H.ok(c)
    H.eq({ "/target" }, vim.fn.readfile(root .. "/.git/info/exclude"))
    H.eq({ "a.txt" }, names(root, c))
  end)
end)

-- --------------------------------------------------------- 13. size cap

describe("size cap (vim.g.xynovim_lochist_max_bytes)", function()
  local MB = 1024 * 1024

  it("leaves untracked files over the cap out with an exclude pathspec and one INFO notice", function()
    vim.g.xynovim_lochist_max_bytes = MB
    local root = mkrepo()
    write(root .. "/big.bin", string.rep("x", 2 * MB))
    write(root .. "/small.txt", "s\n")
    local c = snap(root)
    H.eq({ "a.txt", "small.txt" }, names(root, c))
    H.ok(log_count(vim.pesc("add -A --ignore-errors -- . :(exclude,literal)big.bin")) == 1, "pathspec in git add")
    local n = note_matching("local history: skipping big.bin")
    H.eq(1, #n)
    H.eq("local history: skipping big.bin (2 MB, over the 1 MB cap; vim.g.xynovim_lochist_max_bytes)", n[1].msg)
    H.eq(vim.log.levels.INFO, n[1].level)
    write(root .. "/small.txt", "s2\n")
    H.ok(snap(root))
    H.eq(1, #note_matching("local history: skipping big.bin"), "notice only once")
  end)

  it("many untracked files: the size check runs in slices across event-loop turns and still finds a big file in the last slice", function()
    vim.g.xynovim_lochist_max_bytes = MB
    local root = mkrepo()
    vim.fn.mkdir(root .. "/many", "p")
    for i = 1, 4500 do
      write(("%s/many/f%05d.txt"):format(root, i), "x")
    end
    write(root .. "/zz-big.bin", string.rep("x", 2 * MB))
    local c = snap(root)
    H.ok(c, "snapshot made")
    local got = names(root, c)
    H.eq(4501, #got, "a.txt + 4500 small files")
    H.not_ok(vim.tbl_contains(got, "zz-big.bin"), "the big file in the last slice is skipped")
    H.eq(1, #note_matching("local history: skipping zz-big.bin"))
  end)

  it("defaults to 10 MB; 0 and negative disable the cap, a non-number keeps the default; a numeric string is honoured", function()
    local root = mkrepo()
    write(root .. "/big.bin", string.rep("x", 11 * MB))
    local c = snap(root)
    H.eq({ "a.txt" }, names(root, c), "11 MB over the 10 MB default")
    vim.g.xynovim_lochist_max_bytes = "abc" -- not a number: still the 10 MB default
    write(root .. "/a.txt", "abc\n")
    c = snap(root)
    H.not_ok(vim.tbl_contains(names(root, c), "big.bin"), "a non-numeric cap must not lift the cap")
    for _, v in ipairs({ 0, -1 }) do
      vim.g.xynovim_lochist_max_bytes = v
      write(root .. "/a.txt", "v" .. tostring(v) .. "\n")
      c = snap(root)
      H.has(names(root, c), "big.bin", "cap disabled by " .. vim.inspect(v))
    end
    -- reset: new repo, numeric string
    local root2 = mkrepo()
    write(root2 .. "/big.bin", string.rep("x", 2 * MB))
    vim.g.xynovim_lochist_max_bytes = tostring(MB)
    H.eq({ "a.txt" }, names(root2, snap(root2)), "numeric string cap")
  end)

  it("tracked files over the cap are still snapshotted; a file that grew past the cap leaves the private index", function()
    vim.g.xynovim_lochist_max_bytes = MB
    local root = mkrepo({ ["a.txt"] = "a\n", ["tracked.bin"] = string.rep("t", 2 * MB) })
    write(root .. "/grow.bin", "tiny\n")
    local c1 = snap(root)
    H.eq({ "a.txt", "grow.bin", "tracked.bin" }, names(root, c1))
    write(root .. "/grow.bin", string.rep("g", 2 * MB))
    local c2 = snap(root)
    H.ok(c2, "a new commit (the file dropped out)")
    H.eq({ "a.txt", "tracked.bin" }, names(root, c2))
    H.ok(log_count("rm %-%-cached %-r %-q %-f %-%-ignore%-unmatch %-%- grow%.bin") == 1, "git rm --cached ran")
  end)
end)

describe("size cap and tracked files", function()
  local MB = 1024 * 1024

  it("a MODIFIED tracked file over the cap is left out of the snapshot (its blob would add its size each time)", function()
    vim.g.xynovim_lochist_max_bytes = MB
    local root = mkrepo({ ["a.txt"] = "a\n", ["data.db"] = string.rep("t", 2 * MB) })
    local c1 = snap(root)
    H.eq({ "a.txt", "data.db" }, names(root, c1), "unchanged tracked file: same blob as HEAD, kept")
    write(root .. "/data.db", "X" .. string.rep("t", 2 * MB - 1))
    write(root .. "/a.txt", "a2\n")
    local c2 = snap(root)
    H.ok(c2)
    H.eq({ "a.txt" }, names(root, c2))
    H.eq(1, #note_matching("local history: skipping data.db"))
  end)
end)

-- ---------------------------------------------------- 14. nested repos

describe("nested repositories", function()
  it("skips a nested repo without commits, records one with commits as a gitlink, indexes the rest", function()
    local root = mkrepo({ ["top.txt"] = "t\n" })
    write(root .. "/empty/x.txt", "x\n")
    G(root .. "/empty", "init", "-q", "-b", "main")
    write(root .. "/withc/y.txt", "y\n")
    G(root .. "/withc", "init", "-q", "-b", "main")
    G(root .. "/withc", "add", "-A")
    G(root .. "/withc", "commit", "-q", "-m", "c")
    write(root .. "/after.txt", "a\n")
    local c = snap(root)
    H.ok(c, "snapshot done")
    local files = names(root, c)
    H.has(files, "top.txt")
    H.has(files, "after.txt")
    H.not_ok(vim.tbl_contains(files, "empty/x.txt"))
    H.match(G(root, "ls-tree", c, "withc"), "^160000 commit " .. G(root .. "/withc", "rev-parse", "HEAD"))
    H.eq("", G(root, "ls-tree", c, "empty"))
  end)
end)

-- ------------------------------------------------------ 19. linked worktree

describe("linked worktree", function()
  it("snapshots on the worktree's own branch ref, index in its gitdir, exclude shared", function()
    local root = mkrepo()
    local wt = uv.fs_realpath(vim.fs.dirname(root)) .. "/wt"
    G(root, "worktree", "add", "-q", "-b", "feat", wt)
    write(wt .. "/a.txt", "from the worktree\n")
    local c = snap(wt)
    H.ok(c)
    H.eq({ "refs/lochist/feat" }, lochist_refs(root))
    H.eq("from the worktree\n", blob(root, "refs/lochist/feat", "a.txt"))
    local gitdir = root .. "/.git/worktrees/wt"
    H.ok(uv.fs_stat(gitdir .. "/lochist-index." .. uv.os_getpid()), "index in the worktree gitdir")
    H.eq({}, vim.fn.glob(root .. "/.git/lochist-index*", true, true), "none in the main gitdir")
    local ex = vim.fn.readfile(root .. "/.git/info/exclude")
    H.eq("target/", ex[#ex])
    H.eq(1, #vim.tbl_filter(function(l) return l == "target/" end, ex))
    -- the main worktree keeps its own ref
    write(root .. "/a.txt", "main side\n")
    H.ok(snap(root))
    H.eq({ "refs/lochist/feat", "refs/lochist/main" }, lochist_refs(root))
  end)
end)

-- ----------------------------------- 20. unicode, deleted files, fsck, git

describe("content", function()
  it("captures unicode paths, a deleted file stays recoverable, git fsck is clean", function()
    local root = mkrepo()
    local u1, u2 = "ünï/日本語 file.txt", "emoji🙂.txt"
    write(root .. "/" .. u1, "unicode\n")
    write(root .. "/" .. u2, "e\n")
    local c1 = snap(root)
    H.has(names(root, c1), u1)
    H.has(names(root, c1), u2)
    os.remove(root .. "/" .. u1)
    local c2 = snap(root)
    H.ok(c2)
    H.not_ok(vim.tbl_contains(names(root, c2), u1))
    H.eq("unicode\n", blob(root, c1, u1), "recoverable from the earlier snapshot")
    fsck_clean(root)
  end)

  it("README: snapshots accumulate until pruned; update-ref -d resets; shows in git log --all; push --mirror transfers it", function()
    local root = mkrepo()
    for i = 1, 4 do
      write(root .. "/a.txt", "v" .. i .. "\n")
      H.ok(snap(root))
    end
    H.eq(4, count(root, "refs/lochist/main"))
    H.has(vim.split(G(root, "log", "--all", "--format=%s"), "\n", { plain = true }), "autosave")
    local bare = H.tmpdir() .. "/remote.git"
    G(root, "init", "-q", "--bare", bare)
    G(root, "push", "-q", "--mirror", bare)
    H.eq(tip(root, "refs/lochist/main"), tip(bare, "refs/lochist/main"), "push --mirror carries refs/lochist")
    G(root, "update-ref", "-d", "refs/lochist/main")
    H.is_nil(tip(root, "refs/lochist/main"))
    write(root .. "/a.txt", "after reset\n")
    H.ok(snap(root))
    H.eq(1, count(root, "refs/lochist/main"), "history starts over")
  end)

  it("README: git restore --source=refs/lochist/<branch> --worktree -- <path> recovers a file without touching the index", function()
    local root = mkrepo()
    write(root .. "/a.txt", "precious\n")
    H.ok(snap(root))
    os.remove(root .. "/a.txt")
    G(root, "status", "--porcelain")
    local idx = read(root .. "/.git/index")
    G(root, "restore", "--source=refs/lochist/main", "--worktree", "--", "a.txt")
    H.eq("precious\n", read(root .. "/a.txt"))
    H.eq(idx, read(root .. "/.git/index"), "index untouched")
    G(root, "diff", "--cached", "--quiet")
  end)
end)

-- --------------------------------- 9-10. throttle, timers, retry, watchdog

describe("throttle and timers", function()
  it("THROTTLE_S=60: a non-forced save 59 s after the last snapshot waits, at 60 s it runs", function()
    local root = mkrepo()
    H.ok(snap(root, { force = false }))
    local c1 = tip(root, "refs/lochist/main")
    write(root .. "/a.txt", "v2\n")
    time_offset = 59
    LH.snapshot({ path = root })
    H.eq(true, state("pending")[root])
    H.ok(state("timers")[root], "trailing timer armed")
    vim.wait(300)
    H.eq(c1, tip(root, "refs/lochist/main"), "no commit inside the window")
    time_offset = 60
    local c2 = snap(root, { force = false })
    H.ok(c2 and c2 ~= c1, "runs once the window is over")
    H.is_nil(state("timers")[root], "running a snapshot cancels the trailing timer")
    H.is_nil(state("pending")[root])
  end)

  it("a save inside the window arms ONE unref'd trailing timer for ~61 s that snapshots the last save's content", function()
    local root = mkrepo()
    H.ok(snap(root, { force = false }))
    local c1 = tip(root, "refs/lochist/main")
    timer_scale = 50
    local before_news = timer_news
    for i = 2, 4 do
      write(root .. "/a.txt", "save " .. i .. "\n")
      LH.snapshot({ path = root })
    end
    H.eq(1, timer_news - before_news, "one timer for three saves")
    H.eq(1, #timer_starts)
    H.ok(timer_starts[1] >= 59000 and timer_starts[1] <= 61000, "due in " .. timer_starts[1] .. " ms")
    H.eq(false, state("timers")[root].real:has_ref(), "unref'd, never keeps nvim alive")
    H.eq(c1, tip(root, "refs/lochist/main"))
    H.wait_for(function()
      return tip(root, "refs/lochist/main") ~= c1
    end, 15000, "trailing snapshot")
    H.eq("save 4\n", blob(root, "refs/lochist/main", "a.txt"))
    H.is_nil(state("timers")[root])
    H.is_nil(state("pending")[root])
    H.eq(2, count(root, "refs/lochist/main"))
  end)

  it("a forced snapshot ignores the throttle window", function()
    local root = mkrepo()
    H.ok(snap(root, { force = false }))
    write(root .. "/a.txt", "forced\n")
    H.ok(snap(root, { force = true }), "commit right away")
    H.eq(2, count(root, "refs/lochist/main"))
  end)

  it("FAIL_BACKOFF_S=10: after a failure the retry is pending behind a ~10 s timer, one retry only", function()
    local root = mkrepo()
    fake("add", "failonce")
    timer_scale = 6
    H.is_nil(snap(root, { force = false }), "first attempt fails")
    H.eq(true, state("pending")[root], "unrecorded save is pending")
    H.eq(1, #timer_starts)
    H.ok(timer_starts[1] >= 9000 and timer_starts[1] <= 11000, "retry due in " .. timer_starts[1] .. " ms")
    H.eq(1, log_count("^[^\t]*\tadd "))
    -- a save inside the backoff does not run git
    write(root .. "/a.txt", "inside\n")
    LH.snapshot({ path = root })
    H.eq(1, log_count("^[^\t]*\tadd "), "no add inside the backoff")
    H.wait_for(function()
      return tip(root, "refs/lochist/main")
    end, 15000, "retry")
    H.eq("inside\n", blob(root, "refs/lochist/main", "a.txt"))
    H.eq(2, log_count("^[^\t]*\tadd "))
  end)

  it("the backoff lapses after 10 s (9 s waits, 10 s runs); a failing retried snapshot schedules nothing", function()
    local root = mkrepo()
    fake("add", "fail")
    H.is_nil(snap(root, { force = true, retried = true }))
    H.is_nil(state("timers")[root], "retried=true: no further retry")
    H.is_nil(state("pending")[root])
    os.remove(ctl .. "/add")
    time_offset = 9
    LH.snapshot({ path = root })
    H.eq(true, state("pending")[root])
    H.eq(1, log_count("^[^\t]*\tadd "))
    time_offset = 10
    H.ok(snap(root, { force = false }), "runs at 10 s")
    -- a forced failure that is not marked retried arms the retry
    fake("add", "fail")
    write(root .. "/a.txt", "x\n")
    H.is_nil(snap(root, { force = true }))
    H.ok(state("timers")[root], "retry timer armed")
    H.eq(true, state("pending")[root])
  end)

  it("a forced snapshot that finds another running retries after 500 ms instead of being dropped", function()
    local root = mkrepo()
    fake("commit-tree", "slowonce:1")
    local a_commit, b_commit, a_done, b_done
    LH.snapshot({ path = root, force = true, done = function(c) a_commit, a_done = c, true end })
    wait_pidfile("commit-tree")
    write(root .. "/a.txt", "second\n")
    LH.snapshot({ path = root, force = true, done = function(c) b_commit, b_done = c, true end })
    H.has(deferred, 500)
    H.not_ok(b_done, "not run yet")
    H.is_nil(state("pending")[root], "a forced one does not go through pending")
    H.wait_for(function() return a_done and b_done end, 20000, "both snapshots")
    H.ok(a_commit and b_commit and a_commit ~= b_commit)
    H.eq(a_commit, G(root, "rev-parse", b_commit .. "^"))
    H.eq("second\n", blob(root, b_commit, "a.txt"))
  end)

  it("a non-forced snapshot that finds another running marks pending and arms the timer", function()
    local root = mkrepo()
    fake("commit-tree", "slowonce:1")
    local done
    LH.snapshot({ path = root, force = true, done = function() done = true end })
    wait_pidfile("commit-tree")
    LH.snapshot({ path = root })
    H.eq(true, state("pending")[root])
    H.ok(state("timers")[root])
    H.wait_for(function() return done end, 20000, "first snapshot")
  end)

  it("the 30 s watchdog aborts a hung git (kills the child), clears the running state, done fires once", function()
    local root = mkrepo()
    scale_watchdog = true
    fake("add", "hang")
    local calls = 0
    local commit
    LH.snapshot({ path = root, force = true, done = function(c) calls, commit = calls + 1, c end })
    local pid = wait_pidfile("add")
    H.ok(pid_alive(pid), "git is hanging")
    H.eq(true, state("running")[root])
    H.wait_for(function() return calls > 0 end, 10000, "watchdog")
    H.has(deferred, 30000, "watchdog armed for 30 s")
    H.is_nil(commit)
    H.wait_for(function() return not pid_alive(pid) end, 5000, "hung git killed")
    H.is_nil(state("running")[root])
    H.is_nil(state("runs")[root])
    vim.wait(600)
    H.eq(1, calls, "finish() is idempotent: done called once")
    -- history works again
    scale_watchdog = false
    os.remove(ctl .. "/add")
    H.ok(snap(root), "next snapshot runs")
  end)
end)

-- -------------------------------------------------- 16-18. locks and failures

describe("locks and failures", function()
  it("removes its own leftover index.lock before add", function()
    local root = mkrepo()
    local lock = root .. "/.git/lochist-index." .. uv.os_getpid() .. ".lock"
    write(lock, "")
    H.ok(snap(root))
    H.is_nil(uv.fs_stat(lock))
  end)

  it("a ref lock older than 60 s named in git's stderr is removed and the snapshot lands; a fresh one stays", function()
    local root = mkrepo()
    vim.fn.mkdir(root .. "/.git/refs/lochist", "p")
    local lock = root .. "/.git/refs/lochist/main.lock"
    write(lock, "")
    local old = os.time() - 120
    uv.fs_utime(lock, old, old)
    H.ok(snap(root), "snapshot after clearing the stale lock")
    H.is_nil(uv.fs_stat(lock), "stale lock removed")
    H.ok(tip(root, "refs/lochist/main"))
    -- a fresh lock (held by someone) is left alone, the snapshot gives up with a warning
    write(root .. "/a.txt", "next\n")
    write(lock, "")
    H.is_nil(snap(root))
    H.ok(uv.fs_stat(lock), "fresh lock kept")
    H.eq(1, #note_matching("local history: update-ref failed: "))
  end)

  it("a stale lock named by a failing git add is cleared and add retried", function()
    local root = mkrepo()
    local lock = root .. "/.git/index.lock"
    write(lock, "")
    local old = os.time() - 120
    uv.fs_utime(lock, old, old)
    fake("add", "lockonce:" .. lock)
    H.ok(snap(root))
    H.is_nil(uv.fs_stat(lock), "stale lock removed")
    H.eq(2, log_count("^[^\t]*\tadd "))
  end)

  it("a lasting lock error notifies once ('local history: git lock error, snapshots skipped')", function()
    local root = mkrepo()
    fake("add", "lockindex")
    H.is_nil(snap(root))
    H.is_nil(snap(root))
    local n = note_matching("local history: git lock error, snapshots skipped")
    H.eq(1, #n)
    H.eq(vim.log.levels.WARN, n[1].level)
    H.is_nil(tip(root, "refs/lochist/main"))
  end)

  it("update-ref failing after 10 jittered attempts warns and does not count as a snapshot", function()
    local root = mkrepo()
    fake("update-ref", "fail")
    local c = snap(root)
    H.is_nil(c)
    H.eq(10, log_count("^[^\t]*\tupdate%-ref refs/lochist/main "), "10 attempts")
    local jitter = vim.tbl_filter(function(ms)
      return ms >= 30 and ms <= 150
    end, deferred)
    H.ok(#jitter >= 9, "jittered delays 30-150 ms: " .. vim.inspect(deferred))
    local n = note_matching("local history: update-ref failed: fatal: injected failure")
    H.eq(1, #n)
    H.eq(vim.log.levels.WARN, n[1].level)
    H.is_nil(state("last")[root], "not recorded as a successful snapshot")
    H.ok(state("failed")[root], "recorded as failure")
    H.is_nil(tip(root, "refs/lochist/main"))
  end)

  it("moves the ref with compare-and-swap (update-ref <ref> <new> <old>) and rebuilds the tree after reading the parent", function()
    local root = mkrepo()
    local c1 = snap(root)
    write(root .. "/a.txt", "two\n")
    local c2 = snap(root)
    local first, second
    for _, l in ipairs(fake_log()) do
      local args = l:match("^[^\t]*\t(update%-ref refs/lochist/main .*)$")
      if args then
        if not first then
          first = args
        else
          second = args
        end
      end
    end
    H.eq(("update-ref refs/lochist/main %s "):format(c1), first, "first: old value empty")
    H.eq(("update-ref refs/lochist/main %s %s"):format(c2, c1), second)
    -- order: the parent is read (rev-parse -q --verify ref) before add runs
    local ver, add
    for i, l in ipairs(fake_log()) do
      if not ver and l:find("rev-parse -q --verify refs/lochist/main", 1, true) then
        ver = i
      end
      if not add and l:find("\tadd ", 1, true) then
        add = i
      end
    end
    H.ok(ver and add and ver < add, "parent read before the tree is built")
  end)
end)

-- ------------------------------------------------------- 17. stale indexes

describe("stale index files", function()
  it("deletes leftovers of dead pids (and .lock) and the old shared index, seeds ours from the newest, spares a live pid", function()
    local root = mkrepo({ ["a.txt"] = "a\n" })
    local gd = root .. "/.git"
    local function dead_pid()
      local o = vim.system({ "true" })
      local pid = o.pid
      o:wait()
      return pid
    end
    local da, db = dead_pid(), dead_pid()
    local live = H.spawn({ "sleep", "120" })
    local function mkindex(path)
      local r = vim.system({ REAL_GIT, "add", "-A" }, { cwd = root, env = { GIT_INDEX_FILE = path } }):wait(30000)
      H.eq(0, r.code, r.stderr)
    end
    local A, B = gd .. "/lochist-index." .. da, gd .. "/lochist-index." .. db
    mkindex(A)
    write(root .. "/b.txt", "b\n")
    mkindex(B)
    os.remove(root .. "/b.txt")
    local shared, livep = gd .. "/lochist-index", gd .. "/lochist-index." .. live.pid
    vim.fn.writefile(vim.fn.readfile(A, "b"), shared, "b")
    vim.fn.writefile(vim.fn.readfile(A, "b"), livep, "b")
    write(B .. ".lock", "")
    local now = os.time()
    uv.fs_utime(A, now - 200, now - 200)
    uv.fs_utime(shared, now - 100, now - 100)
    uv.fs_utime(livep, now - 300, now - 300)
    uv.fs_utime(B, now - 10, now - 10)
    local b_bytes, live_bytes = read(B), read(livep)
    fake("add", "snapindex")
    H.ok(snap(root))
    H.is_nil(uv.fs_stat(A))
    H.is_nil(uv.fs_stat(B))
    H.is_nil(uv.fs_stat(B .. ".lock"))
    H.is_nil(uv.fs_stat(shared), "old shared index removed")
    H.eq(live_bytes, read(livep), "a live pid's index is left alone")
    H.eq(b_bytes, read(ctl .. "/index-before"), "our index was seeded with the newest leftover")
    H.ok(uv.fs_stat(gd .. "/lochist-index." .. uv.os_getpid()))
  end)
end)

-- --------------------------------------------- 12 + 15. child nvim processes

local child_script = [[
package.path = vim.env.XYNO_REPO .. "/lua/?.lua;" .. package.path
local LH = require("config.local_history")
LH.setup()
local root, mode = vim.env.XYNO_ROOT, vim.env.XYNO_MODE
if mode == "pending" then
  vim.cmd.edit(root .. "/f.txt")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "v1" })
  vim.cmd.write()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "final" })
  vim.cmd.write()
  vim.cmd("qa!")
elseif mode == "inflight" then
  vim.cmd.edit(root .. "/f.txt")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "v1" })
  vim.cmd.write()
  vim.wait(10000, function()
    return vim.uv.fs_stat(vim.env.XYNO_FAKE .. "/commit-tree.pid") ~= nil
  end, 10)
  vim.cmd("qa!")
elseif mode == "concurrent" then
  local id = vim.env.XYNO_ID
  local out = {}
  for i = 1, 3 do
    vim.fn.writefile({ id .. "/" .. i }, root .. "/c" .. id .. "_" .. i .. ".txt")
    local done, commit = false, nil
    LH.snapshot({ path = root, force = true, done = function(c) done, commit = true, c end })
    vim.wait(60000, function() return done end, 10)
    out[#out + 1] = commit or "nil"
  end
  vim.fn.writefile(out, vim.env.XYNO_OUT)
  vim.cmd("qa!")
end
]]

local function child(root, mode, env)
  local script = base .. "/child.lua"
  if not uv.fs_stat(script) then
    write(script, child_script)
  end
  local e = vim.tbl_extend("force", { XYNO_REPO = H.repo, XYNO_ROOT = root, XYNO_MODE = mode }, env or {})
  return vim.system(
    { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-c", "luafile " .. script },
    { env = e, text = true }
  )
end

describe("exit and concurrency (child nvim processes)", function()
  it("save then qa!: VimLeavePre records the final content with ONE snapshot and nvim exits quickly", function()
    local root = mkrepo()
    local t0 = uv.hrtime()
    local r = child(root, "pending"):wait(30000)
    local ms = (uv.hrtime() - t0) / 1e6
    H.eq(0, r.code, r.stderr)
    H.ok(ms < 4000, ("nvim took %d ms to exit"):format(ms))
    H.eq("final\n", blob(root, "refs/lochist/main", "f.txt"))
    H.eq(1, count(root, "refs/lochist/main"), "one synchronous snapshot")
    H.eq("autosave", subject(root, "refs/lochist/main"))
  end)

  it("quitting with a snapshot in flight kills the running git and redoes it synchronously", function()
    local root = mkrepo()
    fake("commit-tree", "slowonce:3")
    local t0 = uv.hrtime()
    local r = child(root, "inflight"):wait(30000)
    local ms = (uv.hrtime() - t0) / 1e6
    H.eq(0, r.code, r.stderr)
    H.ok(ms < 2900, ("nvim waited for the slow git (%d ms)"):format(ms))
    local pid = tonumber(read(ctl .. "/commit-tree.pid"))
    H.ok(pid, "the slow git ran")
    H.wait_for(function() return not pid_alive(pid) end, 4000, "in-flight git killed")
    H.eq("v1\n", blob(root, "refs/lochist/main", "f.txt"))
    H.eq(1, count(root, "refs/lochist/main"))
  end)

  it("6 concurrent nvims x 3 snapshots: compare-and-swap loses no snapshot, every reported commit is on the ref", function()
    -- NOTE: not "18 commits" strictly: a snapshot whose tree an earlier racer's commit already contains
    -- (it saw the file in its own `git add`) is a legitimate no-op (done(nil)), so the count depends on timing.
    local root = mkrepo()
    local procs = {}
    for id = 1, 6 do
      procs[id] = child(root, "concurrent", { XYNO_ID = tostring(id), XYNO_OUT = base .. "/out" .. id .. ".txt" })
    end
    for id, p in ipairs(procs) do
      local r = p:wait(100000)
      H.eq(0, r.code, ("child %d: %s%s"):format(id, r.stdout or "", r.stderr or ""))
    end
    local seen, nils = {}, 0
    for id = 1, 6 do
      local lines = vim.fn.readfile(base .. "/out" .. id .. ".txt")
      H.eq(3, #lines)
      for _, c in ipairs(lines) do
        if c == "nil" then
          nils = nils + 1
        else
          seen[c] = true
        end
      end
    end
    local n = count(root, "refs/lochist/main")
    H.eq(n, vim.tbl_count(seen), "every commit on the ref was reported by exactly one snapshot")
    H.ok(n >= 3 and n <= 18, "commits: " .. n .. " (no-ops: " .. nils .. ")")
    H.eq(18, n + nils, "each of the 18 snapshots either committed or found its content already recorded")
    H.eq("", G(root, "rev-list", "--merges", "refs/lochist/main"), "one linear chain")
    local files = names(root, "refs/lochist/main")
    H.eq(19, #files, "a.txt + all 18 files are in the tip: nothing was overwritten")
    fsck_clean(root)
  end)
end)

-- ------------------------------------------------ 21-22. browse and restore

local function hash_of(item)
  return vim.split(item, "\t", { plain = true })[1]
end

local function history(root, rel, versions)
  for _, v in ipairs(versions) do
    write(root .. "/" .. rel, v)
    H.ok(snap(root))
  end
end

describe(":LocalHistory", function()
  it("lists the snapshots of the current file (newest first, '<age>  <message>') and opens a vertical scratch diff", function()
    local root = mkrepo({ ["notes.txt"] = "base\n" })
    history(root, "notes.txt", { "v1\n", "v2\n", "v3\n" })
    open_file(root, "notes.txt")
    local origwin = vim.api.nvim_get_current_win()
    mock_select(select_nth(2))
    vim.cmd("LocalHistory")
    H.wait_for(function() return vim.api.nvim_buf_get_name(0):find("notes.txt@", 1, true) end, 15000, "scratch buffer")
    H.eq(1, #sel_calls)
    local c = sel_calls[1]
    H.eq("Local history: notes.txt", c.opts.prompt)
    H.eq(3, #c.items)
    H.match(c.opts.format_item(c.items[1]), "ago  autosave", true)
    local h2 = hash_of(c.items[2])
    H.eq(G(root, "rev-list", "--max-count=3", "refs/lochist/main"), table.concat({ hash_of(c.items[1]), h2, hash_of(c.items[3]) }, "\n"))
    H.match(vim.api.nvim_buf_get_name(0), "notes.txt@" .. h2:sub(1, 8) .. "$")
    H.eq("nofile", vim.bo.buftype)
    H.eq("wipe", vim.bo.bufhidden)
    H.eq(false, vim.bo.swapfile)
    H.eq(vim.filetype.match({ filename = root .. "/notes.txt" }) or "", vim.bo.filetype)
    H.eq({ "v2" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    H.eq("row", vim.fn.winlayout()[1], "vertical split")
    H.ok(vim.wo.diff and vim.wo[origwin].diff, "both windows in diff mode")
  end)

  it("lists at most 100 snapshots", function()
    local root = mkrepo({ ["notes.txt"] = "base\n" })
    local items = {}
    for i = 1, 120 do
      items[i] = { days = 0, content = "version " .. i .. "\n" }
    end
    chain(root, "refs/lochist/main", items, "notes.txt")
    open_file(root, "notes.txt")
    mock_select(function() return nil end)
    vim.cmd("LocalHistory")
    H.wait_for(function() return #sel_calls > 0 end, 15000, "picker")
    H.eq(100, #sel_calls[1].items)
  end)

  it("leaves out the snapshots in which the file was deleted (--diff-filter=d)", function()
    local root = mkrepo({ ["notes.txt"] = "base\n" })
    history(root, "notes.txt", { "v1\n", "v2\n" })
    os.remove(root .. "/notes.txt")
    H.ok(snap(root))
    open_file(root, "notes.txt")
    mock_select(function() return nil end)
    vim.cmd("LocalHistory")
    H.wait_for(function() return #sel_calls > 0 end, 15000, "picker")
    H.eq(2, #sel_calls[1].items)
  end)

  it("outside a worktree: WARN 'not in a git worktree'", function()
    local dir = H.tmpdir()
    write(dir .. "/x.txt", "x\n")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    H.open(dir .. "/x.txt")
    vim.cmd("LocalHistory")
    H.eq({ { msg = "not in a git worktree", level = vim.log.levels.WARN } }, notes)
  end)

  it("without history: INFO 'no local history for <rel>'", function()
    local root = mkrepo({ ["sub/f.txt"] = "x\n" })
    open_file(root, "sub/f.txt")
    vim.cmd("LocalHistory")
    H.wait_for(function() return #notes > 0 end, 15000, "notice")
    H.eq({ { msg = "no local history for sub/f.txt", level = vim.log.levels.INFO } }, notes)
    -- history exists, but not for this file
    write(root .. "/other.txt", "o\n")
    H.ok(snap(root))
    write(root .. "/sub/f.txt", "x\n") -- unchanged content: not in the log of the file beyond the first snapshot
    notes = {}
    mock_select(function() return nil end)
    vim.cmd("LocalHistory")
    H.wait_for(function() return #sel_calls > 0 end, 15000, "picker")
  end)

  it("a detached HEAD lists its own ref and the legacy refs/lochist/detached", function()
    local root = mkrepo({ ["f.txt"] = "base\n" })
    G(root, "checkout", "-q", "--detach")
    chain(root, "refs/lochist/detached", { { content = "legacy\n", msg = "legacy autosave" } })
    write(root .. "/f.txt", "now\n")
    H.ok(snap(root))
    open_file(root, "f.txt")
    mock_select(function() return nil end)
    vim.cmd("LocalHistory")
    H.wait_for(function() return #sel_calls > 0 end, 15000, "picker")
    H.eq(2, #sel_calls[1].items)
    local msgs = {}
    for _, it in ipairs(sel_calls[1].items) do
      msgs[#msgs + 1] = vim.split(it, "\t", { plain = true })[3]
    end
    table.sort(msgs)
    H.eq({ "autosave", "legacy autosave" }, msgs)
  end)
end)

describe(":LocalHistoryRestore", function()
  local function setup_restore()
    local root = mkrepo({ ["notes.txt"] = "base\n" })
    history(root, "notes.txt", { "v1\n", "v2\n", "v3\n" })
    local buf = open_file(root, "notes.txt")
    return root, buf
  end

  it("Restore replaces the buffer text (modified, not saved), leaves disk and index alone, notifies", function()
    local root, buf = setup_restore()
    local idx = read(root .. "/.git/index")
    mock_select(function(items, opts, n)
      if n == 1 then
        return 3 -- oldest: v1
      end
      return 1 -- Restore
    end)
    vim.cmd("LocalHistoryRestore")
    H.wait_for(function() return #notes > 0 end, 15000, "restore notice")
    local h = hash_of(sel_calls[1].items[3]):sub(1, 8)
    H.eq({ "Restore", "Cancel" }, sel_calls[2].items)
    H.eq(("Replace notes.txt with snapshot %s? (undo with u)"):format(h), sel_calls[2].opts.prompt)
    H.eq({ "v1" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    H.eq(true, vim.bo[buf].modified)
    H.eq("v3\n", read(root .. "/notes.txt"), "file on disk not saved")
    H.eq(idx, read(root .. "/.git/index"), "real index untouched")
    H.eq(("restored notes.txt from %s (buffer modified, not saved)"):format(h), notes[1].msg)
    -- `u` brings the previous text back (headless, full config)
    vim.api.nvim_set_current_buf(buf)
    H.feed("u")
    H.eq({ "v3" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("Cancel leaves the buffer alone", function()
    local _, buf = setup_restore()
    mock_select(function(_, _, n)
      return n == 1 and 3 or 2
    end)
    vim.cmd("LocalHistoryRestore")
    H.wait_for(function() return #sel_calls >= 2 end, 15000, "second prompt")
    vim.wait(100)
    H.eq({ "v3" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    H.eq(false, vim.bo[buf].modified)
    H.eq({}, notes)
  end)

  it("a snapshot without the file warns 'file did not exist in that snapshot'", function()
    local root = mkrepo({ ["notes.txt"] = "base\n" })
    history(root, "notes.txt", { "v1\n" })
    os.remove(root .. "/notes.txt")
    local gone = snap(root)
    open_file(root, "notes.txt")
    mock_select(function(items)
      items[1] = gone .. "\tnow\tautosave" -- a snapshot taken after the delete
      return 1
    end)
    vim.cmd("LocalHistoryRestore")
    H.wait_for(function() return #notes > 0 end, 15000, "warning")
    H.eq({ { msg = "file did not exist in that snapshot", level = vim.log.levels.WARN } }, notes)
    H.eq(1, #sel_calls, "no Restore prompt")
    -- the same through :LocalHistory
    notes = {}
    vim.cmd("LocalHistory")
    H.wait_for(function() return #notes > 0 end, 15000, "warning from browse")
    H.eq("file did not exist in that snapshot", notes[1].msg)
  end)
end)

-- --------------------------------------------------------------- 23-24 prune

--- :LocalHistoryPrune, then wait for gc (or the early notice)
local function prune(root, arg, bang)
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.cmd("enew")
  notes = {}
  vim.cmd("LocalHistoryPrune" .. (bang and "! " or " ") .. (arg or ""))
  H.wait_for(function()
    for _, n in ipairs(notes) do
      if n.msg:find("git gc done", 1, true) or n.msg:find("git gc failed", 1, true) or n.msg:find("nothing to prune", 1, true)
        or n.msg:find("usage:", 1, true) then
        return true
      end
    end
  end, 60000, "prune finished")
end

local function six(root)
  local items = {}
  for i = 1, 6 do
    items[i] = { days = 6 - i, content = "content " .. i .. "\n", msg = "snap" .. i }
  end
  chain(root, "refs/lochist/main", items)
end

describe(":LocalHistoryPrune", function()
  it("N keeps the newest N per branch: 6 commits with 2 keeps 2, with 1 keeps 1; trees, messages, dates unchanged; fsck clean", function()
    local root = mkrepo()
    six(root)
    local before = vim.split(G(root, "log", "--format=%T|%s|%ct|%H", "refs/lochist/main"), "\n", { plain = true })
    local old_tip = tip(root, "refs/lochist/main")
    prune(root, "2")
    H.eq(2, count(root, "refs/lochist/main"))
    local after = vim.split(G(root, "log", "--format=%T|%s|%ct|%H", "refs/lochist/main"), "\n", { plain = true })
    for i = 1, 2 do
      local bt, bs, bc = before[i]:match("^(%x+)|(.-)|(%d+)|")
      local at, as, ac = after[i]:match("^(%x+)|(.-)|(%d+)|")
      H.eq({ bt, bs, bc }, { at, as, ac }, "kept snapshot " .. i)
    end
    H.eq(1, #vim.split(G(root, "rev-list", "--max-parents=0", "refs/lochist/main"), "\n", { plain = true }), "re-rooted")
    H.is_nil(tip(root, "refs/xynovim-prune"), "temp ref deleted")
    H.ok(note_matching("local history: dropped 4 of 6 snapshots")[1])
    fsck_clean(root)
    -- same call order as documented
    local order = {}
    for _, l in ipairs(fake_log()) do
      local a = l:match("^[^\t]*\t(.*)$")
      if a:find("^fast%-import") then
        order[#order + 1] = "fast-import"
      elseif a:find("rev-parse refs/xynovim-prune", 1, true) then
        order[#order + 1] = "rev-parse"
      elseif a:find("^update%-ref refs/lochist/main %x+ " .. old_tip) then
        order[#order + 1] = "update-ref-cas"
        H.eq(tip(root, "refs/lochist/main"), a:match("^update%-ref refs/lochist/main (%x+)"))
      elseif a:find("update-ref -d refs/xynovim-prune", 1, true) then
        order[#order + 1] = "delete-temp"
      elseif a:find("^gc ") then
        order[#order + 1] = "gc " .. a
      end
    end
    H.eq({ "fast-import", "rev-parse", "update-ref-cas", "delete-temp", "gc gc --quiet --prune=1.hour.ago" }, order)
    -- and with 1
    prune(root, "1")
    H.eq(1, count(root, "refs/lochist/main"))
    H.eq("snap6", subject(root, "refs/lochist/main"))
    fsck_clean(root)
  end)

  it("Nd keeps the last N days (default 30d); at least the newest always stays", function()
    local root = mkrepo()
    chain(root, "refs/lochist/main", {
      { days = 100, content = "1\n" },
      { days = 50, content = "2\n" },
      { days = 20, content = "3\n" },
      { days = 10, content = "4\n" },
      { days = 2, content = "5\n" },
    })
    prune(root, "") -- default 30d
    H.eq(3, count(root, "refs/lochist/main"))
    prune(root, "5d")
    H.eq(1, count(root, "refs/lochist/main"))
    H.eq("5\n", blob(root, "refs/lochist/main", "f.txt"))
    -- everything older than the window: the newest stays
    local r2 = mkrepo()
    chain(r2, "refs/lochist/main", { { days = 90, content = "o1\n" }, { days = 80, content = "o2\n" } })
    prune(r2, "7d")
    H.eq(1, count(r2, "refs/lochist/main"))
    H.eq("o2\n", blob(r2, "refs/lochist/main", "f.txt"))
  end)

  it("rejects 0, 0d, -1 and text with the usage WARN and changes nothing", function()
    local root = mkrepo()
    six(root)
    local t = tip(root, "refs/lochist/main")
    for _, arg in ipairs({ "0", "0d", "-1", "abc", "5x", "3 4" }) do
      prune(root, arg)
      H.eq(1, #notes, arg)
      H.eq("usage: :LocalHistoryPrune [N | Nd]  (keep the newest N snapshots per branch, or N days)", notes[1].msg, arg)
      H.eq(vim.log.levels.WARN, notes[1].level)
    end
    H.eq(t, tip(root, "refs/lochist/main"))
    H.eq(0, log_count("fast%-import"))
  end)

  it("says 'nothing to prune (N snapshots)' when nothing is dropped; counts all lochist refs", function()
    local root = mkrepo()
    chain(root, "refs/lochist/main", { { days = 1, content = "1\n" }, { days = 0, content = "2\n" } })
    chain(root, "refs/lochist/foo%2Fbar", { { days = 3, content = "1\n" }, { days = 2, content = "2\n" }, { days = 1, content = "3\n" } })
    prune(root, "10")
    H.eq("local history: nothing to prune (5 snapshots)", notes[1].msg)
    H.eq(0, log_count("^[^\t]*\tgc "))
    prune(root, "1")
    H.ok(note_matching("local history: dropped 3 of 5 snapshots")[1], vim.inspect(notes))
    H.eq(1, count(root, "refs/lochist/main"))
    H.eq(1, count(root, "refs/lochist/foo%2Fbar"))
  end)

  it("a ref that moved meanwhile makes the update-ref fail: 'could not prune', ref untouched, temp ref removed", function()
    local root = mkrepo()
    six(root)
    local t = tip(root, "refs/lochist/main")
    fake("update-ref", "failif:refs/lochist/main")
    prune(root, "2")
    H.ok(note_matching("local history: could not prune refs/lochist/main")[1], vim.inspect(notes))
    H.eq(t, tip(root, "refs/lochist/main"))
    os.remove(ctl .. "/update-ref")
    H.is_nil(tip(root, "refs/xynovim-prune"))
  end)

  it("! uses --prune=now and frees the space of a big deleted blob", function()
    local root = mkrepo()
    local f = assert(io.open("/dev/urandom", "rb"))
    local random = f:read(3 * 1024 * 1024)
    f:close()
    write(root .. "/big.bin", random)
    local c1 = snap(root)
    H.ok(c1)
    os.remove(root .. "/big.bin")
    write(root .. "/a.txt", "changed\n")
    H.ok(snap(root))
    local bigblob = G(root, "rev-parse", c1 .. ":big.bin")
    local before = dirsize(root .. "/.git")
    H.ok(before > 3 * 1024 * 1024, "the blob is in .git: " .. before)
    prune(root, "1", true)
    H.eq(1, count(root, "refs/lochist/main"))
    H.eq(1, log_count("^[^\t]*\tgc %-%-quiet %-%-prune=now$"))
    local after = dirsize(root .. "/.git")
    H.ok(after < before - 2.5 * 1024 * 1024, ("shrunk from %d to %d"):format(before, after))
    H.eq(1, run(root, { "cat-file", "-e", bigblob }).code, "blob gone")
    fsck_clean(root)
    local last_note = notes[#notes]
    H.eq("local history: pruned, git gc done", last_note.msg)
  end)
end)

describe(":LocalHistoryPrune! with nothing left to drop", function()
  it("still runs git gc --prune=now (the follow-up the notice recommends)", function()
    local root = mkrepo()
    six(root)
    prune(root, "2")
    H.eq(0, log_count("^[^\t]*\tgc %-%-quiet %-%-prune=now$"))
    prune(root, "2", true)
    H.eq(1, log_count("^[^\t]*\tgc %-%-quiet %-%-prune=now$"), "gc --prune=now ran")
    H.eq(2, count(root, "refs/lochist/main"))
    H.eq("local history: pruned, git gc done", notes[#notes].msg)
    H.ok(note_matching("nothing to drop")[1], "says so")
    fsck_clean(root)
  end)
end)

-- --------------------------------------------------- 26. autosave, 27. 99

describe("integrations", function()
  it("User AutoSaveWritePost snapshots only when the buffer is no longer modified (a refused write leaves none)", function()
    local root = mkrepo()
    local buf = open_file(root, "a.txt")
    -- refused write (disk_guard): still modified -> no snapshot
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
    H.eq(true, vim.bo[buf].modified)
    vim.api.nvim_exec_autocmds("User", { pattern = "AutoSaveWritePost", data = { saved_buffer = buf } })
    vim.wait(700)
    H.is_nil(tip(root, "refs/lochist/main"))
    H.eq(0, log_count("\tadd "))
    -- written: snapshot (content of the disk file)
    write(root .. "/a.txt", "on disk\n")
    vim.cmd("silent! checktime")
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent! edit!")
    end)
    H.eq(false, vim.bo[buf].modified)
    vim.api.nvim_exec_autocmds("User", { pattern = "AutoSaveWritePost", data = { saved_buffer = buf } })
    H.wait_for(function() return tip(root, "refs/lochist/main") end, 15000, "snapshot")
    H.eq("on disk\n", blob(root, "refs/lochist/main", "a.txt"))
    -- no data / invalid buffer: no error
    H.ok(pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AutoSaveWritePost" }))
    H.ok(pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AutoSaveWritePost", data = { saved_buffer = 99999 } }))
  end)

  it("99 guard: a forced snapshot labelled 'before 99 request' is taken before every request, throttle or not", function()
    local ok = pcall(function()
      require("lazy").load({ plugins = { "99" } })
    end)
    local ok2, _99 = pcall(require, "99")
    if not (ok and ok2) then
      skip("the 99 plugin cannot be loaded here")
    end
    local providers = require("99.providers")
    local provider = _99.get_provider()
    H.ok(provider ~= providers.OpenCodeProvider, "the guarded provider is configured")
    local Claude = providers.ClaudeCodeProvider
    local orig = Claude.make_request
    local observers = {}
    Claude.make_request = function(_, _, _, obs)
      observers[#observers + 1] = obs
    end
    H._restore[#H._restore + 1] = function()
      Claude.make_request = orig
    end
    local root = mkrepo()
    open_file(root, "a.txt")
    H.ok(snap(root, { force = false }), "normal autosave first: the throttle window is open")
    for i = 1, 2 do
      write(root .. "/a.txt", "request " .. i .. "\n")
      local before = tip(root, "refs/lochist/main")
      provider:make_request("prompt", {}, { on_complete = function() end })
      H.eq(i - 1, #observers, "the agent must not start before its checkpoint")
      H.wait_for(function()
        return tip(root, "refs/lochist/main") ~= before
      end, 15000, "labelled snapshot " .. i)
      H.wait_for(function()
        return #observers == i
      end, 15000, "the real provider got the request, after the snapshot")
      H.eq("before 99 request", subject(root, "refs/lochist/main"))
      H.eq("request " .. i .. "\n", blob(root, "refs/lochist/main", "a.txt"))
      observers[i].on_complete()
    end
    pcall(function()
      require("auto-save").off()
    end)
  end)
end)

-- ----------------------------------------------------------- 30. not verified

pending("picker UI (vim.ui.select with the real telescope/snacks picker)", "the tests drive vim.ui.select with a stub; the visual picker was not exercised")
pending("undo of :LocalHistoryRestore in a real interactive session", "only `u` through feedkeys in headless nvim is covered")
pending("the 30 s watchdog with a real 30 s wait", "the test shortens the 30000 ms defer to 300 ms and asserts the requested delay was 30000")
pending("the 60 s stale ref-lock rule against a lock aged exactly 60 s", "only a 120 s old (removed) and a fresh (kept) lock are tested")
pending("a repository with a submodule", "not tested; only nested repos with and without commits")
pending("thousands of snapshots (performance of log/prune)", "the largest history built is 120 commits")
