-- Everything the dependency and macro features need to know about crates, in
-- one place (no UI here):
--   * cargo metadata of a workspace (cached, members + dependencies + the
--     resolved package of each dependency with its full [features] table)
--   * the unpacked sources of a crate (~/.cargo/registry/src, git checkouts
--     and path deps through the metadata manifest_path)
--   * a small crates.io client (sparse index for exact names, the web API for
--     search), curl with an argv list, cached on disk, offline-tolerant
--   * is_known_path_head(): is this first path segment something that exists
--
-- Conventions: functions that can wait come in pairs, `foo_async(..., cb)` and
-- a blocking `foo(...)` built on it. They return `result, err` (never raise
-- for network, tool or file problems); `err` is a plain string. Names and
-- versions that come from the network or from files are validated before they
-- reach an argv or a path.
local M = {}

M.config = {
  timeout_ms = 5000, -- one curl call (curl --max-time)
  metadata_timeout_ms = 60000, -- cargo metadata (may have to resolve)
  index_ttl = 3600, -- seconds a cached index answer is fresh
  search_ttl = 600,
  index_url = "https://index.crates.io",
  api_url = "https://crates.io/api/v1",
  proto = "=https", -- curl --proto; specs point the URLs at file:// and set "=file"
  user_agent = "xynovim (github.com/xynorash/xynovim)",
  cache_dir = nil, -- default stdpath("cache")/xynovim/crates
  cargo_home = nil, -- default $CARGO_HOME or ~/.cargo
}

-- JSON null -> nil (vim.NIL is truthy and breaks `x or default`)
local JSON_OPTS = { luanil = { object = true, array = true } }

-- ------------------------------------------------------------- validation

--- A crate name as crates.io allows it (and nothing a shell or a path could
--- misread).
function M.valid_name(name)
  return type(name) == "string" and #name > 0 and #name <= 64 and name:match("^[A-Za-z0-9_-]+$") ~= nil
end

--- semver-ish: 1.2.3, 1.2.3-rc.1, 1.2.3+build
function M.valid_version(v)
  return type(v) == "string" and #v <= 64 and v:match("^%d+%.%d+%.%d+[A-Za-z0-9.+-]*$") ~= nil
end

local function parse_version(v)
  local a, b, c, pre = tostring(v):match("^(%d+)%.(%d+)%.(%d+)(.*)$")
  if not a then
    return nil
  end
  pre = pre:match("^%-([^+]*)")
  return { tonumber(a), tonumber(b), tonumber(c), pre }
end

--- -1 / 0 / 1; a release is newer than its pre-releases; unparsable sorts first.
function M.compare_versions(x, y)
  local a, b = parse_version(x), parse_version(y)
  if not a or not b then
    return (a and 1 or 0) - (b and 1 or 0)
  end
  for i = 1, 3 do
    if a[i] ~= b[i] then
      return a[i] < b[i] and -1 or 1
    end
  end
  if a[4] == b[4] then
    return 0
  end
  if not a[4] then
    return 1
  end
  if not b[4] then
    return -1
  end
  return a[4] < b[4] and -1 or 1
end

-- ------------------------------------------------------------ processes

--- Run argv. With `cb` it is asynchronous (cb(result) on the main loop),
--- without it blocks. result = { code, stdout, stderr } (code -1 on a spawn
--- failure or timeout). Specs replace this to fake cargo and curl.
function M.exec(argv, opts, cb)
  opts = opts or {}
  local function finish(r)
    return { code = r.code, stdout = r.stdout or "", stderr = r.stderr or "" }
  end
  local ok, res = pcall(vim.system, argv, { text = true, cwd = opts.cwd, timeout = opts.timeout }, cb and vim.schedule_wrap(function(r)
    cb(finish(r))
  end) or nil)
  if not ok then
    local r = { code = -1, stdout = "", stderr = tostring(res) }
    if cb then
      vim.schedule(function()
        cb(r)
      end)
      return
    end
    return r
  end
  if not cb then
    return finish(res:wait())
  end
end

-- ---------------------------------------------------------------- files

local MAX_READ = 2 * 1024 * 1024 -- source and manifest files; bigger is not a real one

-- Regular files only: a symlink to /dev/zero exhausts memory and a FIFO blocks the main thread
-- (dependency sources, git and path ones included, are untrusted).
local function read_file(path)
  local st = vim.uv.fs_stat(path)
  if not st or st.type ~= "file" or st.size > MAX_READ then
    return nil
  end
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_file(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
  local f = io.open(tmp, "wb")
  if not f then
    return false
  end
  f:write(data)
  f:close()
  return require("config.fsutil").rename(tmp, path) and true or false
end

local function mtime(path)
  local st = path and vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. "." .. st.mtime.nsec) or "-"
end

-- ------------------------------------------------------- cargo metadata

local cache = {} -- root -> { stamp = string, meta = table }
local pending = {} -- root -> { callbacks }

--- Workspace root of a directory or file (a directory holding Cargo.toml is
--- taken as is, which also covers a path outside any workspace of its own).
function M.root(path)
  path = path or vim.api.nvim_buf_get_name(0)
  local st = vim.uv.fs_stat(path)
  local rc = require("config.rust_context")
  if st and st.type == "directory" and vim.uv.fs_stat(path .. "/Cargo.toml") then
    return rc.canon(path) -- one spelling of a root (Windows drive letter / slashes)
  end
  return rc.root(path)
end

local function stamp_of(root, meta)
  local parts = { mtime(root .. "/Cargo.toml"), mtime(root .. "/Cargo.lock") }
  if meta then
    for _, m in ipairs(meta.members) do
      parts[#parts + 1] = m.manifest_path .. "=" .. mtime(m.manifest_path)
    end
  end
  return table.concat(parts, "|")
end

local function dir_of(manifest)
  return manifest and vim.fs.dirname(manifest)
end

local function alias_of(dep)
  return (dep.rename or dep.name):gsub("%-", "_")
end

local LIB_KINDS = { lib = true, rlib = true, dylib = true, cdylib = true, staticlib = true, ["proc-macro"] = true }

--- cargo's JSON -> { root, members, dependencies, packages, by_name }
function M.normalize(raw, root)
  local by_id, nodes = {}, {}
  local member_ids = {}
  for _, id in ipairs(raw.workspace_members or {}) do
    member_ids[id] = true
  end
  local packages, by_name = {}, {}
  for _, p in ipairs(raw.packages or {}) do
    local rec = {
      name = p.name,
      version = p.version,
      id = p.id,
      manifest_path = p.manifest_path,
      dir = dir_of(p.manifest_path),
      source = p.source,
      features = p.features or {},
      is_member = member_ids[p.id] or false,
      _raw = p,
    }
    by_id[p.id] = rec
    packages[#packages + 1] = rec
    by_name[p.name] = by_name[p.name] or {}
    table.insert(by_name[p.name], rec)
  end
  for _, n in ipairs(raw.resolve and raw.resolve.nodes or {}) do
    nodes[n.id] = n
  end

  local members, dependencies = {}, {}
  for _, p in ipairs(packages) do
    if p.is_member then
      local m = {
        name = p.name,
        version = p.version,
        id = p.id,
        manifest_path = p.manifest_path,
        dir = p.dir,
        features = p.features,
        targets = {},
        lib_name = nil,
      }
      for _, t in ipairs(p._raw.targets or {}) do
        m.targets[#m.targets + 1] = { name = t.name, kind = t.kind, src_path = t.src_path, edition = t.edition }
        for _, k in ipairs(t.kind or {}) do
          if LIB_KINDS[k] then
            m.lib_name = t.name:gsub("%-", "_")
          end
        end
      end
      members[#members + 1] = m
      local node = nodes[p.id]
      for _, d in ipairs(p._raw.dependencies or {}) do
        local alias = alias_of(d)
        local kind = d.kind or "normal"
        local resolved
        for _, e in ipairs(node and node.deps or {}) do
          if e.name == alias then
            local dk_ok = #(e.dep_kinds or {}) == 0
            for _, dk in ipairs(e.dep_kinds or {}) do
              if (dk.kind or "normal") == kind then
                dk_ok = true
              end
            end
            local target = by_id[e.pkg]
            if dk_ok and target and target.name == d.name then
              resolved = vim.tbl_extend("force", {}, target, {
                enabled_features = nodes[e.pkg] and nodes[e.pkg].features or {},
              })
              resolved._raw = nil
              break
            end
          end
        end
        dependencies[#dependencies + 1] = {
          name = d.name,
          alias = alias,
          rename = d.rename,
          req = d.req,
          kind = kind,
          optional = d.optional or false,
          features = d.features or {},
          uses_default_features = d.uses_default_features ~= false,
          target = d.target,
          source = d.source,
          member = p.name,
          member_manifest = p.manifest_path,
          resolved = resolved,
        }
      end
    end
  end
  for _, p in ipairs(packages) do
    p._raw = nil
  end
  return {
    root = root,
    workspace_root = raw.workspace_root,
    members = members,
    dependencies = dependencies,
    packages = packages,
    by_name = by_name,
  }
end

local function run_metadata(root, cb)
  local manifest = root .. "/Cargo.toml"
  local base = { "cargo", "metadata", "--format-version", "1", "--manifest-path", manifest }
  local function parse(r)
    if r.code ~= 0 then
      return nil, vim.trim(r.stderr) ~= "" and vim.trim(r.stderr) or ("cargo metadata exited " .. r.code)
    end
    local ok, raw = pcall(vim.json.decode, r.stdout, JSON_OPTS)
    if not ok or type(raw) ~= "table" then
      return nil, "cargo metadata printed no JSON"
    end
    local ok2, meta = pcall(M.normalize, raw, root)
    if not ok2 then
      return nil, "cannot read cargo metadata: " .. tostring(meta)
    end
    return meta
  end
  local opts = { cwd = root, timeout = M.config.metadata_timeout_ms }
  -- offline first: deterministic and fast when the registry already has the
  -- crates; the online run only happens when that cannot resolve
  local offline = vim.list_extend(vim.deepcopy(base), { "--offline" })
  M.exec(offline, opts, function(r1)
    local meta, err = parse(r1)
    if meta then
      return cb(meta)
    end
    M.exec(base, opts, function(r2)
      local m2, e2 = parse(r2)
      cb(m2, e2 or err)
    end)
  end)
end

--- cargo metadata of the workspace at `root` (a directory or any file in it);
--- cached until a Cargo.toml (workspace or member) or Cargo.lock changes.
--- cb(meta) or cb(nil, err).
function M.metadata_async(root, cb, opts)
  opts = opts or {}
  root = M.root(root)
  if not root then
    return vim.schedule(function()
      cb(nil, "not in a cargo workspace")
    end)
  end
  local hit = cache[root]
  if hit and not opts.refresh and hit.stamp == stamp_of(root, hit.meta) then
    return vim.schedule(function()
      cb(hit.meta)
    end)
  end
  if pending[root] then
    table.insert(pending[root], cb)
    return
  end
  pending[root] = { cb }
  run_metadata(root, function(meta, err)
    local cbs = pending[root]
    pending[root] = nil
    if meta then
      cache[root] = { stamp = stamp_of(root, meta), meta = meta }
    end
    for _, f in ipairs(cbs) do
      f(meta, err)
    end
  end)
end

function M.metadata(root, opts)
  opts = opts or {}
  local done, meta, err
  M.metadata_async(root, function(m, e)
    done, meta, err = true, m, e
  end, opts)
  if not vim.wait(opts.timeout or (M.config.metadata_timeout_ms + 5000), function()
    return done
  end, 10) then
    return nil, "timed out"
  end
  return meta, err
end

function M.invalidate(root)
  if root then
    cache[root] = nil
  else
    cache = {}
  end
end

--- Dependencies filtered by { member = name, kind = "normal"|"dev"|"build", name = crate }.
function M.dependencies(meta, filter)
  filter = filter or {}
  return vim.tbl_filter(function(d)
    return (not filter.member or d.member == filter.member)
      and (not filter.kind or d.kind == filter.kind)
      and (not filter.name or d.name == filter.name or d.alias == filter.name)
  end, meta.dependencies)
end

--- The member whose directory contains `path` (the longest match).
function M.member_of(meta, path)
  -- cargo's manifest paths and a buffer name may spell one Windows path
  -- differently (drive letter case, slashes): compare one spelling
  local win = vim.fn.has("win32") == 1
  local function key(p)
    p = require("config.rust_context").canon(p)
    return win and p:lower() or p
  end
  local want = key(path)
  local best
  for _, m in ipairs(meta.members) do
    local dir = key(m.dir)
    if (want == dir or vim.startswith(want, dir .. "/")) and (not best or #m.dir > #best.dir) then
      best = m
    end
  end
  return best
end

-- ------------------------------------------------- registry and sources

local function cargo_home()
  return M.config.cargo_home or vim.env.CARGO_HOME or (vim.fs.joinpath(vim.uv.os_homedir() or "", ".cargo"))
end

--- Unpacked registry source of `name` (exact `version`, else the highest one
--- that is unpacked), or nil.
function M.registry_dir(name, version)
  if not M.valid_name(name) or (version and not M.valid_version(version)) then
    return nil
  end
  local best, best_v
  for _, d in ipairs(vim.fn.glob(cargo_home() .. "/registry/src/*/" .. name .. "-*", true, true)) do
    local v = vim.fs.basename(d):sub(#name + 2)
    -- "serde-1.0.1" but not "serde_json-1.0.1" (the glob needs the dash) nor
    -- "foo-bar-1.0.0" when asking for "foo" (v would not start like a version)
    if M.valid_version(v) and (not version or v == version) and (not best_v or M.compare_versions(v, best_v) > 0) then
      best, best_v = d, v
    end
  end
  return best, best_v
end

--- Source directory of a dependency `name` of the workspace `root`: the
--- metadata's manifest_path (registry, git and path deps alike), else the
--- registry. `version` picks one when several are resolved.
function M.source_dir(root, name, version)
  if not M.valid_name(name) then
    return nil
  end
  local meta = M.metadata(root)
  if meta then
    for _, p in ipairs(meta.by_name[name] or meta.by_name[(name:gsub("_", "-"))] or {}) do
      if not version or p.version == version then
        if p.dir and vim.uv.fs_stat(p.dir) then
          return p.dir, p.version
        end
      end
    end
  end
  return M.registry_dir(name, version)
end

--- Manifest text of a source directory.
function M.read_manifest(dir)
  return dir and read_file(dir .. "/Cargo.toml")
end

--- Crate root source: the [lib] path of the manifest, else src/lib.rs.
--- Returns text, path.
function M.read_lib(dir)
  if not dir then
    return nil
  end
  local toml = M.read_manifest(dir) or ""
  local path
  local lib = toml:match("%[lib%]\n(.-)\n%[") or toml:match("%[lib%]\n(.*)$")
  if lib then
    path = lib:match('\npath%s*=%s*"([^"]+)"') or lib:match('^path%s*=%s*"([^"]+)"')
  end
  -- a path out of the crate is not something to open
  if path and (path:find("..", 1, true) or path:sub(1, 1) == "/") then
    path = nil
  end
  path = dir .. "/" .. (path or "src/lib.rs")
  local text = read_file(path)
  return text, text and path or nil
end

--- The [features] table of a Cargo.toml text (single and multi-line arrays),
--- for crates that are in the registry but not in the metadata:
--- { name = { "dep:x", "y/z", ... } }
function M.parse_features(toml)
  local out = {}
  local body = toml:match("\n%[features%]\n(.-)\n%[") or toml:match("\n%[features%]\n(.*)$") or toml:match("^%[features%]\n(.*)$")
  if not body then
    return out
  end
  body = body:gsub("#[^\n]*", "")
  local pos = 1
  while true do
    local s, e, name = body:find('([%w_%-"]+)%s*=%s*%[', pos)
    if not s then
      break
    end
    local close = body:find("%]", e + 1)
    if not close then
      break
    end
    local list = {}
    for item in body:sub(e + 1, close - 1):gmatch('"([^"]*)"') do
      list[#list + 1] = item
    end
    out[(name:gsub('"', ""))] = list
    pos = close + 1
  end
  return out
end

-- ------------------------------------------------------ crates.io client

local function cache_dir()
  return M.config.cache_dir or (vim.fn.stdpath("cache") .. "/xynovim/crates")
end

local function cache_get(file, ttl)
  local path = cache_dir() .. "/" .. file
  local st = vim.uv.fs_stat(path)
  if not st then
    return nil
  end
  local text = read_file(path)
  if not text then
    return nil
  end
  return text, (os.time() - st.mtime.sec) <= ttl
end

local function pct(s)
  return (s:gsub("[^%w%-_.~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

--- GET `url` through curl. cb(body) or cb(nil, err, kind) with kind "offline"
--- (no network), "notfound" or "http".
local function http_get(url, cb)
  local argv = {
    "curl", "--silent", "--show-error",
    "--max-time", tostring(math.max(1, math.floor(M.config.timeout_ms / 1000))),
    "--proto", M.config.proto, "--proto-redir", M.config.proto,
    "-A", M.config.user_agent,
    "-H", "Accept: application/json",
    "--write-out", "\n%{http_code}",
    url,
  }
  M.exec(argv, { timeout = M.config.timeout_ms + 2000 }, function(r)
    if r.code ~= 0 then
      -- 6 host, 7 connect, 28 timeout, 35 TLS, 52/56 network, -1 no curl
      local offline = ({ [6] = 1, [7] = 1, [28] = 1, [35] = 1, [52] = 1, [56] = 1, [-1] = 1 })[r.code]
      return cb(nil, (offline and "offline: " or "request failed: ") .. vim.trim(r.stderr), offline and "offline" or "http")
    end
    local body, status = r.stdout:match("^(.*)\n(%d+)$")
    status = tonumber(status) or 0
    if status == 0 and url:sub(1, 7) == "file://" then
      status = 200 -- file:// has no status; --write-out prints 000
    end
    if status == 404 or status == 403 then
      return cb(nil, "not found", "notfound")
    end
    if status < 200 or status >= 300 then
      return cb(nil, "http " .. status, "http")
    end
    cb(body)
  end)
end

--- Path of a crate in the sparse index.
function M.index_path(name)
  name = name:lower()
  local n = #name
  if n == 1 then
    return "1/" .. name
  elseif n == 2 then
    return "2/" .. name
  elseif n == 3 then
    return "3/" .. name:sub(1, 1) .. "/" .. name
  end
  return name:sub(1, 2) .. "/" .. name:sub(3, 4) .. "/" .. name
end

--- cached-or-fetched text with the TTL / stale / offline rules. cb(text, err, meta)
--- where meta = { from_cache, stale }.
local function cached_get(file, ttl, url, refresh, cb)
  local text, fresh = cache_get(file, ttl)
  if text and fresh and not refresh then
    return vim.schedule(function()
      cb(text, nil, { from_cache = true })
    end)
  end
  http_get(url, function(body, err, kind)
    if body then
      write_file(cache_dir() .. "/" .. file, body)
      return cb(body, nil, {})
    end
    if text and kind ~= "notfound" then
      return cb(text, nil, { from_cache = true, stale = true, offline = kind == "offline", note = err })
    end
    cb(nil, err, { offline = kind == "offline" })
  end)
end

--- Merge `features` and `features2` of an index line and add the implicit
--- feature of every optional dependency that no `dep:` mentions.
local function index_features(line)
  local feats = {}
  for _, tbl in ipairs({ line.features or {}, line.features2 or {} }) do
    for k, v in pairs(tbl) do
      feats[k] = v
    end
  end
  local explicit = {}
  for _, list in pairs(feats) do
    for _, item in ipairs(list) do
      local d = item:match("^dep:(.+)$")
      if d then
        explicit[d] = true
      end
    end
  end
  for _, d in ipairs(line.deps or {}) do
    local key = d.name
    if d.optional and not explicit[key] and not feats[key] then
      feats[key] = { "dep:" .. key }
    end
  end
  return feats
end

--- The JSON lines of an index file -> versions, oldest first.
function M.parse_index(text)
  local versions = {}
  for l in text:gmatch("[^\n]+") do
    local ok, v = pcall(vim.json.decode, l, JSON_OPTS)
    if ok and type(v) == "table" and M.valid_name(v.name) and M.valid_version(v.vers) then
      versions[#versions + 1] = {
        version = v.vers,
        yanked = v.yanked or false,
        features = index_features(v),
        deps = v.deps or {},
        rust_version = v.rust_version,
      }
    end
  end
  return versions
end

--- Exact-name lookup. cb(info) or cb(nil, err). info = { name, versions
--- (oldest first), newest (newest non-yanked), features (of the newest),
--- description, downloads, recent_downloads (when the API answered),
--- from_cache, stale }.
function M.info_async(name, cb, opts)
  opts = opts or {}
  if not M.valid_name(name) then
    return vim.schedule(function()
      cb(nil, "invalid crate name")
    end)
  end
  local lname = name:lower()
  cached_get("index-" .. lname .. ".jsonl", M.config.index_ttl, M.config.index_url .. "/" .. M.index_path(name), opts.refresh, function(text, err, how)
    if not text then
      return cb(nil, err)
    end
    local versions = M.parse_index(text)
    if #versions == 0 then
      return cb(nil, "no versions in the index answer")
    end
    local newest
    for _, v in ipairs(versions) do
      if not v.yanked and (not newest or M.compare_versions(v.version, newest.version) > 0) then
        newest = v
      end
    end
    newest = newest or versions[#versions]
    local info = {
      name = name,
      versions = versions,
      newest = newest.version,
      features = newest.features,
      deps = newest.deps,
      from_cache = how.from_cache,
      stale = how.stale,
    }
    if opts.index_only then
      return cb(info)
    end
    -- description and downloads are only in the web API (`?include=` leaves out
    -- the 400 KB of version rows, which time out a 5 s call); its failure does not
    -- fail the lookup
    cached_get("crate-" .. lname .. ".json", M.config.index_ttl, M.config.api_url .. "/crates/" .. lname .. "?include=", opts.refresh, function(api)
      if api then
        local ok, j = pcall(vim.json.decode, api, JSON_OPTS)
        local c = ok and type(j) == "table" and j.crate
        if type(c) == "table" then
          info.description = type(c.description) == "string" and c.description or nil
          info.downloads = tonumber(c.downloads)
          info.recent_downloads = tonumber(c.recent_downloads)
          info.repository = type(c.repository) == "string" and c.repository or nil
        end
      end
      cb(info)
    end)
  end)
end

function M.info(name, opts)
  local done, r, e
  M.info_async(name, function(a, b)
    done, r, e = true, a, b
  end, opts)
  if not vim.wait(M.config.timeout_ms * 2 + 3000, function()
    return done
  end, 10) then
    return nil, "timed out"
  end
  return r, e
end

--- Search. cb(list) or cb(nil, err); list items = { name, version,
--- description, downloads, recent_downloads }, with .stale / .from_cache set
--- on the list.
function M.search_async(query, cb, opts)
  opts = opts or {}
  query = type(query) == "string" and vim.trim(query) or ""
  if query == "" or #query > 100 or query:find("%c") then
    return vim.schedule(function()
      cb(nil, "invalid search query")
    end)
  end
  local url = M.config.api_url .. "/crates?q=" .. pct(query) .. "&per_page=10"
  cached_get("search-" .. vim.fn.sha256(query):sub(1, 32) .. ".json", M.config.search_ttl, url, opts.refresh, function(text, err, how)
    if not text then
      return cb(nil, err)
    end
    local ok, j = pcall(vim.json.decode, text, JSON_OPTS)
    if not ok or type(j) ~= "table" or type(j.crates) ~= "table" then
      return cb(nil, "unexpected search answer")
    end
    local list = { from_cache = how.from_cache, stale = how.stale }
    for _, c in ipairs(j.crates) do
      if type(c) == "table" and M.valid_name(c.name) then
        list[#list + 1] = {
          name = c.name,
          version = M.valid_version(c.max_stable_version) and c.max_stable_version or (M.valid_version(c.max_version) and c.max_version or nil),
          description = type(c.description) == "string" and c.description or nil,
          downloads = tonumber(c.downloads),
          recent_downloads = tonumber(c.recent_downloads),
        }
      end
    end
    cb(list)
  end)
end

function M.search(query, opts)
  local done, r, e
  M.search_async(query, function(a, b)
    done, r, e = true, a, b
  end, opts)
  if not vim.wait(M.config.timeout_ms + 3000, function()
    return done
  end, 10) then
    return nil, "timed out"
  end
  return r, e
end

-- ------------------------------------------------------- known path heads

M.std_crates = { "std", "core", "alloc", "proc_macro", "test" }
local STD = {}
for _, n in ipairs(M.std_crates) do
  STD[n] = true
end
local KEYWORDS = { crate = true, self = true, super = true, Self = true }

local function file_text(path)
  local b = vim.fn.bufnr(path)
  if b > 0 and vim.api.nvim_buf_is_loaded(b) then
    return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  end
  return read_file(path)
end

--- Does `text` declare `mod name` (any visibility, outline or inline)?
local function declares(text, kw, name)
  for l in (text or ""):gmatch("[^\n]+") do
    local rest = l:match("^%s*pub%s*%b()%s*(.*)$") or l:match("^%s*pub%s+(.*)$") or l:match("^%s*(.*)$")
    local got = rest:match("^" .. kw .. "%s+([%w_]+)")
    if got == name then
      return true
    end
  end
  return false
end

local function macro_declared(text, name)
  return (text or ""):find("macro_rules!%s*" .. name .. "%f[^%w_]") ~= nil
end

--- Directory in which the child modules of `file` live.
local function module_dir(file)
  local base = vim.fs.basename(file)
  local dir = vim.fs.dirname(file)
  if base == "mod.rs" or base == "lib.rs" or base == "main.rs" then
    return dir
  end
  return dir .. "/" .. base:gsub("%.rs$", "")
end

local function has_file(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function rs_files(dir, limit)
  local out = {}
  for name, t in vim.fs.dir(dir, { depth = 8 }) do
    if t == "file" and name:match("%.rs$") then
      out[#out + 1] = dir .. "/" .. name
      if #out >= limit then
        break
      end
    end
  end
  return out
end

--- Is `name` the first segment of a path that resolves to something that
--- exists? Returns the kind ("keyword", "std", "dependency", "own_crate",
--- "module", "local_item", "macro") and a detail, or nil when it is unknown.
---
--- A cheap heuristic, not name resolution: dependencies and the crate's own
--- lib name come from cargo metadata (renames and `-` / `_` handled); local
--- modules from `mod name` in the file, `name.rs` / `name/mod.rs` next to it
--- (or under the member's src/); items from a `struct|enum|trait|type|fn|
--- const|static|union name` declaration in the file; macro_rules! names from
--- the file or any .rs of the member (the textual `#[macro_use]` scope is not
--- modelled). Names that arrive by a `use` of another module are NOT
--- recognised, so call it for the head of `use` paths and for heads that start
--- an expression path, not for every identifier.
--- opts.file: the file the path is in (default the current buffer).
function M.is_known_path_head(root, name, opts)
  opts = opts or {}
  if type(name) ~= "string" or name == "" then
    return nil
  end
  if KEYWORDS[name] then
    return "keyword"
  end
  if STD[name] then
    return "std"
  end
  local file = opts.file or vim.api.nvim_buf_get_name(0)
  local meta = opts.meta
  if not meta then
    meta = M.metadata(root)
  end
  local member = meta and file ~= "" and M.member_of(meta, file) or nil
  if meta then
    for _, d in ipairs(meta.dependencies) do
      if d.alias == name and (not member or d.member == member.name) then
        return "dependency", d.name
      end
    end
    -- workspace-wide fallback when the file is not in a member (a scratch file)
    for _, m in ipairs(meta.members) do
      if (not member or m == member) and m.lib_name == name then
        return "own_crate", m.name
      end
    end
  end
  if file ~= "" then
    local text = file_text(file)
    if declares(text, "mod", name) then
      return "module", file
    end
    local mdir = module_dir(file)
    if has_file(mdir .. "/" .. name .. ".rs") or has_file(mdir .. "/" .. name .. "/mod.rs") then
      return "module", mdir .. "/" .. name
    end
    for _, kw in ipairs({ "struct", "enum", "trait", "type", "fn", "const", "static", "union" }) do
      if declares(text, kw, name) then
        return "local_item", kw
      end
    end
    if macro_declared(text, name) then
      return "macro", file
    end
    local src = member and (member.dir .. "/src")
    if src and (has_file(src .. "/" .. name .. ".rs") or has_file(src .. "/" .. name .. "/mod.rs")) then
      return "module", src .. "/" .. name
    end
    if src and vim.fn.isdirectory(src) == 1 then
      for _, f in ipairs(rs_files(src, 300)) do
        if f ~= file and macro_declared(read_file(f), name) then
          return "macro", f
        end
      end
    end
  end
  return nil
end

return M
