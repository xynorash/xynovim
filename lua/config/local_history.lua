-- Poor man's JetBrains "Local History": every (throttled) save also writes the
-- whole worktree - untracked files included, .gitignore respected, target/
-- excluded - as a commit on refs/lochist/<branch>, using a private index file
-- so the real index/stash/branches are never touched. Survives what
-- undofile can't: deleted files, `git reset --hard`, edits made by an agent.
local M = {}

local THROTTLE_S = 60
local last = {} ---@type table<string, number>
local running = {} ---@type table<string, boolean>

local function git(args, root, env, cb)
  vim.system(vim.list_extend({ "git" }, args), { cwd = root, env = env, text = true }, function(o)
    vim.schedule(function()
      cb(o.code == 0 and vim.trim(o.stdout or "") or nil, o)
    end)
  end)
end

local function ref_for(root, cb)
  git({ "symbolic-ref", "--short", "-q", "HEAD" }, root, nil, function(branch)
    cb("refs/lochist/" .. (branch or "detached"))
  end)
end

--- Snapshot the worktree containing `path` (a file or dir).
--- @param opts? { path?: string, force?: boolean, label?: string, done?: fun(commit?: string) }
function M.snapshot(opts)
  opts = opts or {}
  local path = opts.path or vim.api.nvim_buf_get_name(0)
  local root = path ~= "" and vim.fs.root(path, ".git") or nil
  if not root or running[root] then
    return
  end
  if not opts.force and last[root] and os.time() - last[root] < THROTTLE_S then
    return
  end
  running[root] = true
  last[root] = os.time()
  local function finish(commit)
    running[root] = nil
    if opts.done then
      opts.done(commit)
    end
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
    git({ "add", "-A", "--", ".", ":(exclude)target", ":(exclude,glob)**/target" }, root, env, function(ok)
      if not ok then
        return finish()
      end
      git({ "write-tree" }, root, env, function(tree)
        if not tree then
          return finish()
        end
        ref_for(root, function(ref)
          git({ "rev-parse", "-q", "--verify", ref }, root, env, function(prev)
            local function commit()
              local args = { "commit-tree", tree, "-m", opts.label or "autosave" }
              if prev then
                vim.list_extend(args, { "-p", prev })
              end
              git(args, root, env, function(c)
                if not c then
                  return finish()
                end
                git({ "update-ref", ref, c }, root, env, function()
                  finish(c)
                end)
              end)
            end
            if not prev then
              return commit()
            end
            git({ "rev-parse", prev .. "^{tree}" }, root, env, function(prev_tree)
              if prev_tree == tree then
                finish() -- nothing changed since the last snapshot
              else
                commit()
              end
            end)
          end)
        end)
      end)
    end)
  end)
end

--- Pick an earlier snapshot of the current file and diff against it.
function M.browse()
  local file = vim.api.nvim_buf_get_name(0)
  local root = file ~= "" and vim.fs.root(file, ".git") or nil
  if not root then
    return vim.notify("not in a git worktree", vim.log.levels.WARN)
  end
  local rel = vim.fs.relpath(root, file)
  ref_for(root, function(ref)
    git({ "log", ref, "--format=%H%x09%ar%x09%s", "-n", "100", "--", rel }, root, nil, function(out)
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
        if not choice then
          return
        end
        local hash = vim.split(choice, "\t", { plain = true })[1]
        git({ "show", hash .. ":" .. rel }, root, nil, function(content)
          if not content then
            return vim.notify("file did not exist in that snapshot", vim.log.levels.WARN)
          end
          vim.cmd("diffthis")
          vim.cmd("vertical new")
          vim.bo.buftype, vim.bo.bufhidden, vim.bo.swapfile = "nofile", "wipe", false
          vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content, "\n", { plain = true }))
          vim.bo.filetype = vim.filetype.match({ filename = file }) or ""
          vim.api.nvim_buf_set_name(0, ("%s@%s"):format(rel, hash:sub(1, 8)))
          vim.cmd("diffthis")
        end)
      end)
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
  vim.api.nvim_create_user_command("LocalHistory", M.browse, { desc = "Browse local history of this file" })
end

return M
