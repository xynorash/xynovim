-- Stale lock files of the tree-sitter CLI, for scripts/provision.lua.
--
-- `tree-sitter build` takes a lock file per parser under <cache>/tree-sitter/lock and, when it cannot get
-- the lock for about 20 s, fails with "Lock file ... appears stale" (macOS runs 39746701940 and
-- 39756026137: 7 to 30 parsers failed that way in one provisioning round). A lock left behind by a
-- build that was killed with its nvim does the same to every later build of that parser. Locks older
-- than a build can take are removed before a retry round; a younger one may belong to a build that is
-- still running and is kept.
local M = {}

--- Directories the CLI may keep its locks in.
---@return string[]
function M.dirs()
  local home = vim.uv.os_homedir() or ""
  local cache = vim.env.XDG_CACHE_HOME
  local dirs = {}
  if cache and cache ~= "" then
    dirs[#dirs + 1] = cache .. "/tree-sitter/lock"
  end
  dirs[#dirs + 1] = home .. "/.cache/tree-sitter/lock"
  dirs[#dirs + 1] = home .. "/Library/Caches/tree-sitter/lock"
  dirs[#dirs + 1] = (vim.env.LOCALAPPDATA or (home .. "/AppData/Local")) .. "/tree-sitter/lock"
  return dirs
end

--- Remove regular files in `dir` whose mtime is older than `max_age` seconds. Returns the removed names.
---@param dir string
---@param max_age number
---@param now? number seconds, for tests
---@return string[]
function M.clear(dir, max_age, now)
  now = now or os.time()
  local removed = {}
  if vim.uv.fs_stat(dir) == nil then
    return removed
  end
  for name, kind in vim.fs.dir(dir) do
    local path = dir .. "/" .. name
    local st = kind == "file" and vim.uv.fs_stat(path)
    if st and now - st.mtime.sec > max_age and vim.uv.fs_unlink(path) then
      removed[#removed + 1] = name
    end
  end
  return removed
end

--- Clear every candidate directory; returns the number of locks removed.
---@param max_age number
---@return integer
function M.clear_all(max_age)
  local n = 0
  for _, dir in ipairs(M.dirs()) do
    n = n + #M.clear(dir, max_age)
  end
  return n
end

return M
