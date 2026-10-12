-- Poor man's JetBrains "Local History": every (throttled) save also writes the
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
-- scheduled for the end of the window (and one more on exit if still pending).
local M = {}

local THROTTLE_S = 60
local EXIT_BUDGET_MS = 5000
local last = {} ---@type table<string, number>
local running = {} ---@type table<string, boolean>
local timers = {} ---@type table<string, uv.uv_timer_t>
local deadline ---@type number? set (hrtime ms) only during the synchronous exit snapshot

local function git(args, root, env, cb, raw)
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
  vim.system(cmd, { cwd = root, env = env, text = true }, function(o)
    vim.schedule(function()
      done(o)
    end)
  end)
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

-- Arm (once) the trailing-edge timer for `root`. It is unref'd so it never
-- keeps nvim alive, and does nothing if the repo vanished meanwhile.
local function arm(root)
  if timers[root] then
    return
  end
  local wait_ms = math.max(1000, ((last[root] or 0) + THROTTLE_S - os.time()) * 1000 + 500)
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
        M.snapshot({ path = root, force = true })
      else
        last[root] = nil
      end
    end)
  )
end

local pending = {} ---@type table<string, boolean>

--- Snapshot the worktree containing `path` (a file or dir).
--- @param opts? { path?: string, force?: boolean, label?: string, done?: fun(commit?: string) }
function M.snapshot(opts)
  opts = opts or {}
  local path = opts.path or vim.api.nvim_buf_get_name(0)
  local root = path ~= "" and vim.fs.root(path, ".git") or nil
  if not root then
    return
  end
  if running[root] then
    -- A forced snapshot must not be dropped: retry once the running one ends
    -- (it gets a few seconds at most, see the timeout below).
    if opts.force then
      vim.defer_fn(function()
        M.snapshot(opts)
      end, 500)
    else
      pending[root] = true
      arm(root)
    end
    return
  end
  if not opts.force and last[root] and os.time() - last[root] < THROTTLE_S then
    pending[root] = true
    arm(root)
    return
  end
  pending[root] = nil
  stop_timer(root)
  running[root] = true
  last[root] = os.time()
  local finished = false
  local function finish(commit)
    if finished then
      return
    end
    finished = true
    running[root] = nil
    if opts.done then
      opts.done(commit)
    end
  end

  -- A hung git must not disable history for this repo until restart.
  if not deadline then
    vim.defer_fn(function()
      finish()
    end, 30000)
  end

  git({ "rev-parse", "--absolute-git-dir" }, root, nil, function(gitdir)
    if not gitdir then
      return finish()
    end
    local env = {
      GIT_INDEX_FILE = gitdir .. "/lochist-index",
      GIT_AUTHOR_NAME = "xynovim",
      GIT_AUTHOR_EMAIL = "lochist@xynovim",
      GIT_COMMITTER_NAME = "xynovim",
      GIT_COMMITTER_EMAIL = "lochist@xynovim",
    }
    -- An extra excludes file (additive to .gitignore) keeps cargo's target/
    -- out even in projects that forgot to ignore it. A pathspec exclude would
    -- make `git add` fail whenever target/ IS already ignored.
    local excludes = gitdir .. "/lochist-exclude"
    if not vim.uv.fs_stat(excludes) then
      pcall(vim.fn.writefile, { "target/" }, excludes)
    end
    -- --ignore-errors: a nested repo without commits ("adding embedded
    -- repository") makes plain `add -A` abort and index nothing; with it the
    -- rest is indexed, that repo is skipped, and git exits 1 (tolerated).
    git({ "-c", "core.excludesFile=" .. excludes, "add", "-A", "--ignore-errors" }, root, env, function(_, o)
      if o.code ~= 0 and o.code ~= 1 then
        return finish()
      end
      git({ "write-tree" }, root, env, function(tree)
        if not tree then
          return finish()
        end
        migrate(root, function()
        ref_for(root, function(ref)
          git({ "rev-parse", "-q", "--verify", ref }, root, env, function(prev)
            do
              local parent = prev
              local function commit()
                local args = { "commit-tree", tree, "-m", opts.label or "autosave" }
                if parent then
                  vim.list_extend(args, { "-p", parent })
                end
                git(args, root, env, function(c)
                  if not c then
                    return finish()
                  end
                  git({ "update-ref", ref, c }, root, env, function(_, uo)
                    if uo.code ~= 0 then
                      migrated[root] = nil -- retry the old-ref migration next time
                      vim.notify("local history: update-ref failed: " .. vim.trim(uo.stderr or ""), vim.log.levels.WARN)
                      return finish()
                    end
                    finish(c)
                  end)
                end)
              end
              if not parent then
                return commit()
              end
              git({ "rev-parse", parent .. "^{tree}" }, root, env, function(prev_tree)
                if prev_tree == tree then
                  finish() -- nothing changed since the last snapshot
                else
                  commit()
                end
              end)
            end
          end)
        end)
        end)
      end)
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
      vim.list_extend(args, { "--format=%H%x09%ar%x09%s", "-n", "100", "--", rel })
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

function M.setup()
  local group = vim.api.nvim_create_augroup("xynovim_local_history", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AutoSaveWritePost",
    callback = function(ev)
      local buf = ev.data and ev.data.saved_buffer
      if buf and vim.api.nvim_buf_is_valid(buf) then
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
  -- still has an unrecorded save.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for _, root in ipairs(vim.tbl_keys(timers)) do
        stop_timer(root)
      end
      deadline = vim.uv.hrtime() / 1e6 + EXIT_BUDGET_MS
      for root in pairs(pending) do
        if vim.uv.fs_stat(root .. "/.git") then
          running[root] = nil
          pcall(M.snapshot, { path = root, force = true })
        end
      end
      pending = {}
      deadline = nil
    end,
  })
  vim.api.nvim_create_user_command("LocalHistory", M.browse, { desc = "Browse local history of this file" })
  vim.api.nvim_create_user_command(
    "LocalHistoryRestore",
    M.restore,
    { desc = "Replace this buffer with a local-history snapshot (index untouched)" }
  )
end

return M
