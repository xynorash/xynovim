-- Line-coverage collector (debug.sethook, stdlib only). Loaded with
-- `nvim --cmd 'luafile tests/coverage_hook.lua'` so it is active before the
-- config starts. Records which lines of the repo's own Lua files (lua/,
-- colors/, plugin/, after/) ran; tests/runner.lua dumps a JSON file at exit and
-- scripts/coverage.lua reports. Needs XYNO_COV_ROOTS (colon-separated path
-- prefixes under which the repo is visible; the first match is stripped to get
-- the repo-relative name).
--
-- Costs: a line hook disables LuaJIT's compiler for hooked code, so a covered
-- run is several times slower. Coroutines get their own hook (coroutine.create
-- and coroutine.wrap are wrapped). Code run in a separate nvim process (child
-- nvims) is not seen.
local roots = {}
for p in (vim.env.XYNO_COV_ROOTS or ""):gmatch("[^:]+") do
  roots[#roots + 1] = p:gsub("/+$", "") .. "/"
end

local getinfo = debug.getinfo
local files = {} -- rel -> { [line] = true }
local cache = {} -- source -> rel | false

local function classify(src)
  if src:sub(1, 1) ~= "@" then
    return false
  end
  local path = src:sub(2)
  for _, r in ipairs(roots) do
    if path:sub(1, #r) == r then
      local rel = path:sub(#r + 1)
      if rel:match("^lua/") or rel:match("^colors/") or rel:match("^plugin/") or rel:match("^after/") then
        return rel:match("%.lua$") and rel or false
      end
      return false
    end
  end
  return false
end

local function hook(_, line)
  local src = getinfo(2, "S").source
  local rel = cache[src]
  if rel == nil then
    rel = classify(src)
    cache[src] = rel
  end
  if rel then
    local f = files[rel]
    if not f then
      f = {}
      files[rel] = f
    end
    f[line] = true
  end
end

local co_create = coroutine.create
coroutine.create = function(fn)
  local co = co_create(fn)
  debug.sethook(co, hook, "l")
  return co
end
coroutine.wrap = function(fn)
  local co = coroutine.create(fn)
  return function(...)
    local r = { coroutine.resume(co, ...) }
    if not r[1] then
      error(r[2], 0)
    end
    return unpack(r, 2)
  end
end

debug.sethook(hook, "l")

local M = {}
--- Write the lines seen so far to `path` as {"rel/file.lua":[1,2,...],...}.
function M.dump(path)
  local parts = {}
  for rel, lines in pairs(files) do
    local ls = {}
    for l in pairs(lines) do
      ls[#ls + 1] = l
    end
    table.sort(ls)
    parts[#parts + 1] = ("%q:[%s]"):format(rel, table.concat(ls, ","))
  end
  table.sort(parts)
  local f = assert(io.open(path, "w"))
  f:write("{", table.concat(parts, ","), "}\n")
  f:close()
end

_G.__xyno_cov = M
return M
