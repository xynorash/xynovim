-- Local history, inspired by the JetBrains feature of that name: every (throttled) save also writes the
-- whole worktree - untracked files included, .gitignore respected, target/
-- excluded - as a commit on refs/lochist/<key>, using a private index file
-- so the real index/stash/branches are never touched. Survives what
-- undofile can't: deleted files, `git reset --hard`, edits made by an agent.
--
-- <key> is the branch with "%" -> "%25" and "/" -> "%2F" (so refs/lochist/foo
-- and refs/lochist/foo%2Fbar can never collide as file vs directory), or
-- "%detached-<short HEAD sha>" for a detached HEAD ("%" never starts an encoded
-- branch, so the two cannot clash). Old-style refs (refs/lochist/<raw branch>,
-- refs/lochist/detached) are no longer written. Old-style refs containing a
-- "/" are renamed to the encoded form on first use (they could block new
-- branches); the old "detached" ref is left alone and still read by
-- :LocalHistory.
-- Saves inside the throttle window are not lost: one trailing snapshot is
-- scheduled for the end of the window (and one more on exit if still pending
-- or still in flight: the running git is killed and the snapshot redone
-- synchronously).
-- Every nvim process uses its own index file (.git/lochist-index.<pid>), so
-- concurrent instances never fight over one index.lock; leftovers of dead
-- processes are cleaned up (the newest seeds the next one, so the first
-- `git add -A` stays incremental). Untracked files over
-- vim.g.xynovim_lochist_max_bytes (default 10 MB, <= 0 disables the cap) are
-- left out, and so are the largest files of a snapshot beyond
-- vim.g.xynovim_lochist_max_total_bytes (default 200 MB: thirty files just under the
-- per-file cap would add about 285 MB to .git). :LocalHistoryPrune trims old snapshots.
local M = {}

local THROTTLE_S = 60
local FAIL_BACKOFF_S = 10
local EXIT_BUDGET_MS = 5000
local MAX_BYTES = 10 * 1024 * 1024
local MAX_TOTAL_BYTES = 200 * 1024 * 1024
local last = {} ---@type table<string, number> time of the last SUCCESSFUL snapshot
local failed = {} ---@type table<string, number> time of the last failed one
local running = {} ---@type table<string, boolean>
local runs = {} ---@type table<string, { dead: boolean, child: vim.SystemObj? }>
local indexes = {} ---@type table<string, string> root -> this process's index file
local prepared = {} ---@type table<string, boolean>
local warned = {} ---@type table<string, boolean> notify-once keys
local timers = {} ---@type table<string, uv.uv_timer_t>
local deadline ---@type number? set (hrtime ms) only during the synchronous exit snapshot

--- `run` (optional) lets a caller abandon the chain: once run.dead is set the
--- callback never fires, and run.child is the git process to kill.
local function git(args, root, env, cb, raw, run)
  local cmd = vim.list_extend({ "git" }, args)
  local function done(o)
    cb(o.code == 0 and (raw and (o.stdout or "") or vim.trim(o.stdout or "")) or nil, o)
  end
  if deadline then
    local left = deadline - vim.uv.hrtime() / 1e6
    if left <= 0 then
      return cb(nil, { code = 124, stderr = "exit budget exhausted" })
    end
    return done(vim.system(cmd, { cwd = root, env = env, text = true }):wait(math.floor(left)))
  end
  local child = vim.system(cmd, { cwd = root, env = env, text = true }, function(o)
    vim.schedule(function()
      if not (run and run.dead) then
        done(o)
      end
    end)
  end)
  if run then
    run.child = child
  end
end

--- Abandon the snapshot chain of `root`: no further callbacks, git child killed.
local function abort(root, wait)
  local run = runs[root]
  if not run then
    return
  end
  run.dead = true
  runs[root] = nil
  if run.child then
    pcall(run.child.kill, run.child, 9)
    if wait then
      pcall(run.child.wait, run.child, 1000)
    end
  end
end

local function warn_once(key, msg, level)
  if not warned[key] then
    warned[key] = true
    vim.notify(msg, level or vim.log.levels.WARN)
  end
end

local function encode(branch)
  return (branch:gsub("[%%/]", { ["%"] = "%25", ["/"] = "%2F" }))
end

--- cb(ref, legacy_ref?) : the ref to write and, for a detached HEAD, the
--- old-style shared "detached" ref (read-only).
local function ref_for(root, cb)
  git({ "symbolic-ref", "--short", "-q", "HEAD" }, root, nil, function(branch)
    if branch then
      return cb("refs/lochist/" .. encode(branch))
    end
    git({ "rev-parse", "--short=12", "-q", "--verify", "HEAD" }, root, nil, function(sha)
      cb("refs/lochist/%detached-" .. (sha or "none"), sha and "refs/lochist/detached" or nil)
    end)
  end)
end

--- cb(list of the given refs that exist)
local function existing(root, refs, cb)
  git({ "for-each-ref", "--format=%(refname)", "refs/lochist" }, root, nil, function(out)
    local have = {}
    for _, r in ipairs(vim.split(out or "", "\n", { plain = true })) do
      have[r] = true
    end
    cb(vim.tbl_filter(function(r)
      return r and have[r]
    end, refs))
  end)
end

local migrated = {} ---@type table<string, boolean>

--- Rename old-style refs/lochist/<a/b> to refs/lochist/<a%2Fb> (once per repo
--- per session), so stale directory-like refs cannot block a branch name.
local function migrate(root, cb)
  if migrated[root] then
    return cb()
  end
  migrated[root] = true
  git({ "for-each-ref", "--format=%(refname) %(objectname)", "refs/lochist" }, root, nil, function(out)
    local cmds = {}
    for _, l in ipairs(vim.split(out or "", "\n", { plain = true })) do
      local name, sha = l:match("^refs/lochist/(%S+) (%x+)$")
      if name and name:find("/", 1, true) then
        local new = "refs/lochist/" .. encode(name)
        -- encode() also escapes "%" in the name, matching what a branch of that name gets
        vim.list_extend(cmds, { ("create %s %s"):format(new, sha), ("delete refs/lochist/%s %s"):format(name, sha) })
      end
    end
    if #cmds == 0 then
      return cb()
    end
    local input = table.concat(cmds, "\n") .. "\n"
    -- one transaction; if the target already exists (create fails) nothing moves
    local function run()
      local cmd = { "git", "update-ref", "--stdin" }
      if deadline then
        vim.system(cmd, { cwd = root, stdin = input, text = true }):wait(2000)
        return cb()
      end
      vim.system(cmd, { cwd = root, stdin = input, text = true }, function()
        vim.schedule(cb)
      end)
    end
    run()
  end)
end

local function stop_timer(root)
  local t = timers[root]
  if t then
    timers[root] = nil
    t:stop()
    if not t:is_closing() then
      t:close()
    end
  end
end

--- Earliest time a non-forced snapshot of `root` may start.
local function next_ok(root)
  return math.max((last[root] or 0) + THROTTLE_S, (failed[root] or 0) + FAIL_BACKOFF_S)
end

-- Arm (once) the trailing-edge timer for `root`. It is unref'd so it never
-- keeps nvim alive, and does nothing if the repo vanished meanwhile.
local function arm(root)
  if timers[root] then
    return
  end
  local wait_ms = math.max(1000, (next_ok(root) - os.time()) * 1000 + 500)
  local t = assert(vim.uv.new_timer())
  timers[root] = t
  t:unref()
  t:start(
    wait_ms,
    0,
    vim.schedule_wrap(function()
      if timers[root] ~= t then
        return
      end
      stop_timer(root)
      if vim.uv.fs_stat(root .. "/.git") then
        M.snapshot({ path = root, force = true, retried = true })
      else
        last[root] = nil
      end
    end)
  )
end

local pending = {} ---@type table<string, boolean>

local function pid_alive(pid)
  return vim.uv.kill(pid, 0) == 0
end

--- Once per repo and session: keep /target/ (and the members') out via .git/info/exclude (additive
--- to .gitignore AND the user's global ignore, unlike core.excludesFile=),
--- drop the index files of dead nvim processes (the newest one seeds ours so
--- the first `git add -A` is incremental) and the old shared index.
local function prepare(root, gitdir, exclude)
  if prepared[root] then
    return
  end
  prepared[root] = true
  local mine = indexes[root]
  local lines = vim.uv.fs_stat(exclude) and vim.fn.readfile(exclude) or {}
  -- Anchored: a bare `target/` matched at any depth and hid `src/target/mod.rs` from git
  -- status, `git add -A` and the snapshots. The root and the workspace members (depth <= 2)
  -- get their own line; the unanchored line of an older version is migrated.
  local want = { "/target/" }
  for _, c in ipairs(vim.list_extend(vim.fn.glob(root .. "/*/Cargo.toml", true, true), vim.fn.glob(root .. "/*/*/Cargo.toml", true, true))) do
    want[#want + 1] = "/" .. vim.fs.dirname(c):sub(#root + 2) .. "/target/"
  end
  local have, changed = {}, false
  for i, l in ipairs(lines) do
    if l == "target/" then
      lines[i], changed = "/target/", true
    end
    have[lines[i]] = true
    if lines[i]:match("^/target/?$") or lines[i] == "target" then
      have["/target/"] = true -- the user's own line already covers the root
    end
  end
  for _, w in ipairs(want) do
    if not have[w] then
      have[w] = true
      lines[#lines + 1] = w
      changed = true
    end
  end
  if changed then
    vim.fn.mkdir(vim.fs.dirname(exclude), "p")
    pcall(vim.fn.writefile, lines, exclude)
  end
  os.remove(gitdir .. "/lochist-exclude") -- replaced by info/exclude

  local seed, seed_t = nil, -1
  local stale = {}
  for _, p in ipairs(vim.fn.glob(gitdir .. "/lochist-index*", true, true)) do
    local base = p:gsub("%.lock$", "")
    local pid = base:match("lochist%-index%.(%d+)$")
    if base ~= mine and not (pid and pid_alive(tonumber(pid))) then
      stale[#stale + 1] = p
      local st = base == p and vim.uv.fs_stat(p) or nil
      if st and st.mtime.sec > seed_t then
        seed, seed_t = p, st.mtime.sec
      end
    end
  end
  if seed and not vim.uv.fs_stat(mine) then
    vim.uv.fs_copyfile(seed, mine)
  end
  for _, p in ipairs(stale) do
    os.remove(p)
  end
end

--- A stale lock (killed git) older than a minute: remove it. `err` is git's stderr.
local function clear_stale_lock(err)
  local lock = (err or ""):match("Unable to create '([^']-%.lock)'")
  local st = lock and vim.uv.fs_stat(lock)
  if st and os.time() - st.mtime.sec > 60 then
    return os.remove(lock) ~= nil
  end
  return false
end

local function lock_error(err)
  return (err or ""):find(".lock'", 1, true) ~= nil or (err or ""):find("File exists", 1, true) ~= nil
end

local function size_cap()
  local v = vim.g.xynovim_lochist_max_bytes
  if v == nil then
    return MAX_BYTES
  end
  v = tonumber(v)
  if v == nil then
    return MAX_BYTES -- not a number: keep the default cap rather than silently lifting it
  end
  return v > 0 and v or nil
end

--- Per-snapshot budget for the files that pass the per-file cap (nil: no budget).
local function total_cap()
  local v = tonumber(vim.g.xynovim_lochist_max_total_bytes)
  if v == nil then
    return MAX_TOTAL_BYTES
  end
  return v > 0 and v or nil
end

local STAT_SLICE = 2000

--- cb(list of files bigger than the cap). Untracked = not in the user's real
--- index (the private index is empty in a new session); modified tracked files
--- count too: each snapshot of a changed large file would add its whole size
--- to .git (an unchanged tracked file is the same blob as in HEAD).
local function big_untracked(root, run, cb)
  local cap = size_cap()
  if not cap then
    return cb({})
  end
  git({ "ls-files", "-o", "-m", "--exclude-standard", "-z" }, root, nil, function(out)
    local big = {}
    local kept = {} -- files under the per-file cap: { rel, size }
    local files = vim.split(out or "", "\0", { plain = true })
    -- one fs_stat per listed file: 100k untracked files froze the editor for ~0.5 to 1s
    -- in one go, so a slice of STAT_SLICE files per event-loop turn (not on exit, where
    -- `deadline` is set and nothing may be left for later)
    local function step(from)
      local to = deadline and #files or math.min(from + STAT_SLICE - 1, #files)
      for i = from, to do
        local rel = files[i]
        local st = rel ~= "" and vim.uv.fs_stat(root .. "/" .. rel) or nil
        if st and st.type == "file" and st.size > cap and #big < 2000 then
          big[#big + 1] = rel
          warn_once(
            "big:" .. root .. "/" .. rel,
            ("local history: skipping %s (%.0f MB, over the %.0f MB cap; vim.g.xynovim_lochist_max_bytes)"):format(
              rel,
              st.size / 1048576,
              cap / 1048576
            ),
            vim.log.levels.INFO
          )
        elseif st and st.type == "file" then
          kept[#kept + 1] = { rel, st.size }
        end
      end
      if to < #files then
        return vim.schedule(function()
          step(to + 1)
        end)
      end
      -- the snapshot as a whole: leave out the largest files until it fits the budget
      local budget, total = total_cap(), 0
      for _, f in ipairs(kept) do
        total = total + f[2]
      end
      if budget and total > budget then
        table.sort(kept, function(a, b)
          if a[2] ~= b[2] then
            return a[2] > b[2]
          end
          return a[1] > b[1]
        end)
        for _, f in ipairs(kept) do
          if total <= budget or #big >= 2000 then
            break
          end
          total = total - f[2]
          big[#big + 1] = f[1]
          warn_once(
            "big:" .. root .. "/" .. f[1],
            ("local history: skipping %s (%.0f MB; the snapshot is over %.0f MB, vim.g.xynovim_lochist_max_total_bytes)"):format(
              f[1],
              f[2] / 1048576,
              budget / 1048576
            ),
            vim.log.levels.INFO
          )
        end
      end
      cb(big)
    end
    step(1)
  end, true, run)
end

--- Second half of a snapshot: commit the tree from `build(cb)` on top of the
--- branch's lochist ref. The ref moves with a compare-and-swap, so concurrent
--- nvims never overwrite each other's snapshot: on a mismatch or a lock the
--- parent is read again and the tree rebuilt (it is built after the parent is
--- read, so a stale tree cannot land on top of another instance's newer one).
local function commit_tree(root, build, env, opts, g, finish)
  migrate(root, function()
    ref_for(root, function(ref)
      local function attempt(n)
        g({ "rev-parse", "-q", "--verify", ref }, env, function(parent)
          local tree
          local function commit()
            local args = { "commit-tree", tree, "-m", opts.label or "autosave" }
            if parent then
              vim.list_extend(args, { "-p", parent })
            end
            g(args, env, function(c)
              if not c then
                return finish()
              end
              g({ "update-ref", ref, c, parent or "" }, env, function(_, uo)
                if uo.code == 0 then
                  return finish(c, true)
                end
                clear_stale_lock(uo.stderr)
                if n < 10 then
                  if deadline then
                    return attempt(n + 1)
                  end
                  return vim.defer_fn(function()
                    attempt(n + 1)
                  end, math.random(30, 150)) -- jitter: racers must not retry in lockstep
                end
                migrated[root] = nil -- retry the old-ref migration next time
                vim.notify("local history: update-ref failed: " .. vim.trim(uo.stderr or ""), vim.log.levels.WARN)
                finish()
              end)
            end)
          end
          build(function(t)
            tree = t
            if not parent then
              return commit()
            end
            g({ "rev-parse", parent .. "^{tree}" }, env, function(prev_tree)
              if prev_tree == tree then
                finish(nil, true) -- nothing changed since the last snapshot
              else
                commit()
              end
            end)
          end)
        end)
      end
      attempt(1)
    end)
  end)
end

--- Snapshot the worktree containing `path` (a file or dir).
--- @param opts? { path?: string, force?: boolean, label?: string, retried?: boolean, done?: fun(commit?: string) }
function M.snapshot(opts)
  opts = opts or {}
  local path = opts.path or vim.api.nvim_buf_get_name(0)
  local root = path ~= "" and vim.fs.root(path, ".git") or nil
  if not root then
    return
  end
  if running[root] then
    -- A forced snapshot must not be dropped: retry once the running one ends
    -- (it gets 30 seconds at most, see the watchdog below).
    if opts.force then
      vim.defer_fn(function()
        M.snapshot(opts)
      end, 500)
    else
      -- only note it: finish() arms the timer once `last` is set. Armed here, the timer used the
      -- previous snapshot's age and forced one about 1 s later (a second commit within the throttle)
      pending[root] = true
    end
    return
  end
  if not opts.force and os.time() < next_ok(root) then
    pending[root] = true
    arm(root)
    return
  end
  pending[root] = nil
  stop_timer(root)
  running[root] = true
  local run = { dead = false }
  runs[root] = run
  local finished = false
  --- @param ok? boolean the snapshot was taken or nothing had changed
  local function finish(commit, ok)
    if finished then
      return
    end
    finished = true
    running[root] = nil
    if runs[root] == run then
      runs[root] = nil
    end
    if ok then
      last[root] = os.time()
      failed[root] = nil
      if pending[root] then
        arm(root)
      end
    else
      failed[root] = os.time()
      -- one retry of the unrecorded save once the backoff is over
      if not deadline and not opts.retried then
        pending[root] = true
        arm(root)
      end
    end
    if opts.done then
      opts.done(commit)
    end
  end
  local function g(args, env, cb, raw)
    git(args, root, env, cb, raw, run)
  end

  -- A hung git must not disable history for this repo until restart: kill it.
  if not deadline then
    vim.defer_fn(function()
      if not finished then
        abort(root)
        finish()
      end
    end, 30000)
  end

  g({ "rev-parse", "--absolute-git-dir", "--path-format=absolute", "--git-path", "info/exclude" }, nil, function(out)
    local gitdir, exclude = unpack(vim.split(out or "", "\n", { plain = true }))
    if not gitdir or not exclude then
      return finish()
    end
    local index = gitdir .. "/lochist-index." .. vim.uv.os_getpid()
    indexes[root] = index
    prepare(root, gitdir, exclude)
    os.remove(index .. ".lock") -- ours alone: a leftover of a killed git
    local env = {
      GIT_INDEX_FILE = index,
      GIT_AUTHOR_NAME = "xynovim",
      GIT_AUTHOR_EMAIL = "lochist@xynovim",
      GIT_COMMITTER_NAME = "xynovim",
      GIT_COMMITTER_EMAIL = "lochist@xynovim",
    }
    big_untracked(root, run, function(big)
      -- --ignore-errors: a nested repo without commits ("adding embedded
      -- repository") makes plain `add -A` abort and index nothing; with it the
      -- rest is indexed, that repo is skipped, and git exits 1 (tolerated).
      local add = { "add", "-A", "--ignore-errors" }
      if #big > 0 then
        vim.list_extend(add, { "--", "." })
        for _, rel in ipairs(big) do
          add[#add + 1] = ":(exclude,literal)" .. rel
        end
      end
      local function add_all(tries, cb)
        g(add, env, function(_, o)
          if o.code ~= 0 and o.code ~= 1 then
            if lock_error(o.stderr) and tries < 2 then
              os.remove(index .. ".lock")
              clear_stale_lock(o.stderr)
              return add_all(tries + 1, cb)
            end
            if lock_error(o.stderr) then
              warn_once("lock:" .. root, "local history: git lock error, snapshots skipped: " .. vim.trim(o.stderr or ""))
            end
            return finish()
          end
          g({ "write-tree" }, env, function(tree)
            if not tree then
              return finish()
            end
            cb(tree)
          end)
        end)
      end
      local function build(cb)
        add_all(1, cb)
      end
      local function go()
        commit_tree(root, build, env, opts, g, finish)
      end
      if #big > 0 and vim.uv.fs_stat(index) then
        -- indexed while it was still small: drop the stale copy
        local rm = { "rm", "--cached", "-r", "-q", "-f", "--ignore-unmatch", "--" }
        g(vim.list_extend(rm, big), env, go)
      else
        go()
      end
    end)
  end)
end

--- Let the user pick a snapshot of the current file.
--- @param cb fun(sel: { root: string, rel: string, file: string, hash: string })
local function pick(cb)
  local file = vim.api.nvim_buf_get_name(0)
  local root = file ~= "" and vim.fs.root(file, ".git") or nil
  if not root then
    return vim.notify("not in a git worktree", vim.log.levels.WARN)
  end
  local rel = vim.fs.relpath(root, file)
  migrate(root, function()
  ref_for(root, function(ref, legacy)
    existing(root, { ref, legacy }, function(refs)
      if #refs == 0 then
        return vim.notify("no local history for " .. rel, vim.log.levels.INFO)
      end
      local args = vim.list_extend({ "log" }, refs)
      vim.list_extend(args, { "--format=%H%x09%ar%x09%s", "-n", "100", "--diff-filter=d", "--", rel })
      git(args, root, nil, function(out)
        if not out or out == "" then
          return vim.notify("no local history for " .. rel, vim.log.levels.INFO)
        end
        local items = vim.split(out, "\n", { plain = true })
        vim.ui.select(items, {
          prompt = "Local history: " .. rel,
          format_item = function(l)
            local _, age, msg = unpack(vim.split(l, "\t", { plain = true }))
            return ("%s  %s"):format(age, msg)
          end,
        }, function(choice)
          if choice then
            cb({ root = root, rel = rel, file = file, hash = vim.split(choice, "\t", { plain = true })[1] })
          end
        end)
      end)
    end)
  end)
  end)
end

local function lines_of(content)
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- Pick an earlier snapshot of the current file and diff against it.
function M.browse()
  pick(function(s)
    git({ "show", s.hash .. ":" .. s.rel }, s.root, nil, function(content)
      if not content then
        return vim.notify("file did not exist in that snapshot", vim.log.levels.WARN)
      end
      vim.cmd("diffthis")
      vim.cmd("vertical new")
      vim.bo.buftype, vim.bo.bufhidden, vim.bo.swapfile = "nofile", "wipe", false
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines_of(content))
      vim.bo.filetype = vim.filetype.match({ filename = s.file }) or ""
      vim.api.nvim_buf_set_name(0, ("%s@%s"):format(s.rel, s.hash:sub(1, 8)))
      vim.cmd("diffthis")
    end, true)
  end)
end

--- Pick a snapshot and replace the current buffer's text with that version.
--- Never touches the git index; the buffer is left modified (undo with `u`).
function M.restore()
  local buf = vim.api.nvim_get_current_buf()
  pick(function(s)
    git({ "show", s.hash .. ":" .. s.rel }, s.root, nil, function(content)
      if not content then
        return vim.notify("file did not exist in that snapshot", vim.log.levels.WARN)
      end
      vim.ui.select({ "Restore", "Cancel" }, {
        prompt = ("Replace %s with snapshot %s? (undo with u)"):format(s.rel, s.hash:sub(1, 8)),
      }, function(ans)
        if ans ~= "Restore" or not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines_of(content))
        vim.notify(("restored %s from %s (buffer modified, not saved)"):format(s.rel, s.hash:sub(1, 8)))
      end)
    end, true)
  end)
end

--- Drop old snapshots of every branch of the current repo. `arg`: "N" keeps the
--- newest N per branch, "Nd" keeps the last N days (default "30d"); at least
--- the newest snapshot always stays. The kept commits are re-created without
--- the cut-off parent (one `git fast-import`), then unreachable objects older
--- than an hour are collected with `git gc`, which is what frees the space
--- (`now` = `:LocalHistoryPrune!`: every unreachable object, also younger ones
--- and other tools' dangling commits, and a snapshot being written right now).
--- @param arg? string
--- @param now? boolean
function M.prune(arg, now)
  arg = vim.trim(arg or "")
  if arg == "" then
    arg = "30d"
  end
  local days, keep = arg:match("^(%d+)d$"), arg:match("^(%d+)$")
  if not ((days or keep) and tonumber(days or keep) > 0) then
    return vim.notify("usage: :LocalHistoryPrune [N | Nd]  (keep the newest N snapshots per branch, or N days)", vim.log.levels.WARN)
  end
  local name = vim.api.nvim_buf_get_name(0)
  local root = vim.fs.root(name ~= "" and name or vim.uv.cwd(), ".git")
  if not root then
    return vim.notify("not in a git worktree", vim.log.levels.WARN)
  end
  local function sgit(args, stdin)
    local o = vim.system(vim.list_extend({ "git" }, args), { cwd = root, text = true, stdin = stdin }):wait(60000)
    return o.code == 0 and vim.trim(o.stdout or "") or nil, o
  end
  local cutoff = days and os.time() - tonumber(days) * 86400
  local dropped, total = 0, 0
  for _, ref in ipairs(vim.split(sgit({ "for-each-ref", "--format=%(refname)", "refs/lochist" }) or "", "\n", { plain = true })) do
    local log = ref ~= "" and sgit({ "log", ref, "--format=%H%x09%T%x09%ct%x09%s" }) or nil
    if log then
      local commits = {} -- newest first
      for _, l in ipairs(vim.split(log, "\n", { plain = true })) do
        local h, t, ct, msg = l:match("^(%x+)\t(%x+)\t(%d+)\t(.*)$")
        if h then
          commits[#commits + 1] = { h = h, t = t, ct = tonumber(ct), msg = msg }
        end
      end
      local n = #commits
      if keep then
        n = math.min(n, tonumber(keep))
      else
        n = 0
        for _, c in ipairs(commits) do
          n = n + (c.ct >= cutoff and 1 or 0)
        end
      end
      n = math.max(n, 1)
      total = total + #commits
      if n < #commits then
        local stream = {}
        for i = n, 1, -1 do
          local c = commits[i]
          local from = i < n and "from :" .. (n - i) .. "\n" or ""
          vim.list_extend(stream, {
            ("commit refs/xynovim-prune\nmark :%d\ncommitter xynovim <lochist@xynovim> %d +0000\ndata %d\n%s\n%sM 040000 %s \"\"\n"):format(
              n - i + 1, c.ct, #c.msg, c.msg, from, c.t
            ),
          })
        end
        local tip = sgit({ "fast-import", "--quiet" }, table.concat(stream)) and sgit({ "rev-parse", "refs/xynovim-prune" })
        if tip and sgit({ "update-ref", ref, tip, commits[1].h }) then
          dropped = dropped + #commits - n
        else
          vim.notify("local history: could not prune " .. ref, vim.log.levels.WARN)
        end
        sgit({ "update-ref", "-d", "refs/xynovim-prune" })
      end
    end
  end
  if dropped == 0 and not now then
    return vim.notify(("local history: nothing to prune (%d snapshots)"):format(total))
  end
  -- also with nothing left to drop when forced: the follow-up bang of an
  -- earlier prune still has the dangling commits to collect
  vim.notify(
    dropped == 0 and ("local history: nothing to drop (%d snapshots), collecting garbage..."):format(total)
      or ("local history: dropped %d of %d snapshots, collecting garbage..."):format(dropped, total)
  )
  vim.system({ "git", "gc", "--quiet", now and "--prune=now" or "--prune=1.hour.ago" }, { cwd = root, text = true }, function(o)
    vim.schedule(function()
      vim.notify(
        o.code == 0 and ("local history: pruned, git gc done" .. (now and "" or " (objects younger than an hour: next gc, or :LocalHistoryPrune!)"))
          or "local history: git gc failed: " .. vim.trim(o.stderr or ""),
        o.code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
      )
    end)
  end)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("xynovim_local_history", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AutoSaveWritePost",
    callback = function(ev)
      local buf = ev.data and ev.data.saved_buffer
      -- still modified: the write was refused (see config/disk_guard.lua)
      if buf and vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
        M.snapshot({ path = vim.api.nvim_buf_get_name(buf) })
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      M.snapshot({ path = ev.file })
    end,
  })
  -- Exit: drop timers; take one bounded synchronous snapshot per repo that
  -- still has an unrecorded save OR a snapshot in flight (that one's git is
  -- killed first: the async chain would die with nvim).
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for _, root in ipairs(vim.tbl_keys(timers)) do
        stop_timer(root)
      end
      deadline = vim.uv.hrtime() / 1e6 + EXIT_BUDGET_MS
      local roots = vim.deepcopy(pending)
      for root in pairs(runs) do
        roots[root] = true
      end
      for root in pairs(roots) do
        abort(root, true)
        running[root] = nil
        if vim.uv.fs_stat(root .. "/.git") then
          pcall(M.snapshot, { path = root, force = true })
        end
      end
      pending = {}
      deadline = nil
    end,
  })
  vim.api.nvim_create_user_command("LocalHistory", M.browse, { desc = "Browse local history of this file" })
  vim.api.nvim_create_user_command("LocalHistoryPrune", function(c)
    M.prune(c.args, c.bang)
  end, { nargs = "?", bang = true, desc = "Drop old local-history snapshots: [N] newest per branch or [N]d days (default 30d)" })
  vim.api.nvim_create_user_command(
    "LocalHistoryRestore",
    M.restore,
    { desc = "Replace this buffer with a local-history snapshot (index untouched)" }
  )
end

return M
