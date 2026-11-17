-- Vendored fallback for xyno_rust.trust (the workspace-trust list of xyno-rust.nvim): used by
-- config.workspace_trust ONLY when require("xyno_rust.trust") does not exist, i.e. while lazy-lock.json pins an
-- xyno-rust.nvim older than the trust module. Without it the fail-closed gate would keep every Cargo workspace
-- restricted for ever (no build scripts, no proc macros) and refuse every run command. Same API and the same
-- file (stdpath("state")/xyno-rust-trust.json, same entry format and fingerprint), so the entries carry over
-- when the plugin is updated, and a plugin with the module always wins. This is a COPY of
-- xyno-rust.nvim/lua/xyno_rust/trust.lua (api 1.3) with the plugin-internal requires removed; tests/
-- trust-fallback_spec.lua keeps the two behaving alike. Delete this file once the pin has the module.
--
-- Workspace trust for the Rust tooling, in the manner of VS Code's Workspace
-- Trust: running a target, a test, a cargo tool or `act` executes code that
-- comes with the project (build.rs, proc macros, tests, workflow steps), so in
-- a workspace nobody said they trust the plugin asks first. The answer is
-- remembered per workspace root in stdpath("state")/xyno-rust-trust.json,
-- listed and revoked with :RustTrust, and shared by every nvim instance.
--
-- What needs trust and what does not:
--   * Reading `cargo metadata --no-deps` and `cargo locate-project` is allowed
--     in any workspace: neither builds, runs build.rs / proc macros nor
--     resolves dependencies (checked with a canary build.rs and a canary
--     `build.rustc` in .cargo/config.toml, see tests/trust_spec.lua).
--   * Running a target / test / bench / doctest, samply / flamegraph, any
--     :RustTools entry and :ActJob needs trust.
--   * Starting rust-analyzer and bacon-ls is NOT done by this plugin (it only
--     supplies their settings): `ra_overrides(root)` returns the rust-analyzer
--     settings that keep an untrusted workspace from running build scripts and
--     proc macros, for a config to merge in. Nothing applies it by default.
--
-- Trust follows the content that runs code. A trust entry of its own (not "everything under <parent>")
-- stores a fingerprint of what cargo executes or obeys in that workspace: every Cargo.toml and build.rs
-- below the root, a build script at a custom path (`build = "x/gen.rs"`) and its modules, path
-- dependencies and workspace members outside the root (manifest, build script), every source file of a
-- proc-macro crate, .cargo/config(.toml) and rust-toolchain(.toml) in the tree and in the parent
-- directories (cargo and rustup read those upward). The list comes from `cargo metadata --no-deps
-- --offline` (read in the background, `prime`) plus a bounded manifest scan that needs no cargo; files are
-- hashed whole up to 32 MiB (see the fingerprint section). Entries recorded by an older version re-ask once
-- for a workspace that has such files. When the content differs (a `git pull`, a checkout
-- of another branch, an unseen edit by another tool) the workspace is untrusted again and the next
-- action asks once more, naming the files. Not part of it: .rs sources, Cargo.lock, target/, .git/
-- (ordinary edits and a lockfile refresh never ask). Edits made inside nvim call `rehash`, so the
-- editor's own saves are not re-asked. direnv works this way (re-asks after .envrc changes); VS Code's
-- Workspace Trust asks once per folder and never again, which is why a pulled build.rs runs there
-- unannounced. "Trust everything under <parent>" is one explicit decision about a whole tree and keeps
-- no fingerprint.
--
-- API for other plugins (stable within api_version 1.x, see xyno_rust.api_version):
--   trust.is_trusted(root)               -> boolean, trusted_by_root?
--   trust.require(root, what, cb)        cb(true|false); asks once if needed; may call cb before it returns
--   trust.trust(root, { recursive? })    remember (recursive: everything below root)
--   trust.revoke(root) / trust.revoke_all()
--   trust.list()                         -> { { root, recursive, at } ... } sorted by root
--   trust.drift(root)                    -> nil, or the files whose content differs from what was trusted (api 1.3)
--   trust.rehash(root, saved?)           -> boolean: record the current content of root's own entry (only `saved`, a path or a list of paths, may differ) (api 1.3)
--   trust.fingerprint(root)              -> { hash, files = { [rel|abs path] = short hash }, truncated? } (api 1.3)
--   trust.prime(root, cb?)               read what runs code from `cargo metadata --no-deps --offline` in the background (additive to api 1.3)
--   trust.ra_overrides(root)             -> rust-analyzer settings table ({} for a trusted workspace)
local statefile = (function()
  local function rename(from, to)
    local ok, fsutil = pcall(require, "xyno_rust.fsutil")
    if ok and type(fsutil.rename) == "function" then
      return fsutil.rename(from, to)
    end
    return vim.uv.fs_rename(from, to)
  end

  local M = {}

  --- The decoded table of `file`, {} when it is missing or not a JSON object/array.
  function M.read(file)
    local f = io.open(file)
    if not f then
      return {}
    end
    local ok, data = pcall(vim.json.decode, f:read("*a"))
    f:close()
    return ok and type(data) == "table" and data or {}
  end

  --- Write aside and rename: a reader (another nvim) never sees a truncated file.
  function M.write(file, data)
    vim.fn.mkdir(vim.fs.dirname(file), "p")
    local tmp = ("%s.%d.tmp"):format(file, vim.uv.os_getpid())
    local f = assert(io.open(tmp, "w"))
    f:write(vim.json.encode(data))
    f:close()
    assert(rename(tmp, file))
  end

  M.lock_tries = 400 -- x 5 ms: how long a writer waits for the lock before it writes anyway
  M.stale_after = 5 -- seconds: an older lock is a dead owner's

  local seq = 0
  local function new_token()
    seq = seq + 1
    return ("%d.%d.%d.%d"):format(vim.uv.os_getpid(), seq, vim.uv.hrtime() % 1e9, math.random(1, 1e9))
  end

  local function read_all(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local s = f:read("*a")
    f:close()
    return s
  end

  --- Remove a lock that looks stale. Waiters used to stat, then unlink: between the two another waiter could
  --- have deleted the stale lock and created its own, and the first waiter then deleted THAT live lock. Now:
  --- one reaper at a time (an O_EXCL guard file), the staleness and the owner token are checked again under
  --- the guard, and the lock is moved aside (atomic) and compared with the token before it is dropped; a live
  --- lock that was moved by mistake goes back.
  local function reap(lock, seen_token)
    local guard = lock .. ".reap"
    local gfd = vim.uv.fs_open(guard, "wx", 420)
    if not gfd then
      local gst = vim.uv.fs_stat(guard)
      if gst and os.time() - gst.mtime.sec > M.stale_after * 2 then
        vim.uv.fs_unlink(guard) -- a reaper that died
      end
      return
    end
    vim.uv.fs_close(gfd)
    local st = vim.uv.fs_stat(lock)
    if st and os.time() - st.mtime.sec > M.stale_after and read_all(lock) == seen_token then
      local dead = lock .. ".dead." .. new_token()
      if vim.uv.fs_rename(lock, dead) then
        if read_all(dead) == seen_token then
          vim.uv.fs_unlink(dead)
        elseif not vim.uv.fs_link(dead, lock) then
          vim.uv.fs_unlink(dead) -- somebody already took the lock again: theirs stands
        else
          vim.uv.fs_unlink(dead)
        end
      end
    end
    vim.uv.fs_unlink(guard)
  end

  --- Read, let `fn(all)` change the table, write - under a lock file (it holds its owner's token). A lock
  --- older than 5 s is a dead owner's; after ~2 s without it the write goes on anyway.
  function M.update(file, fn)
    local lock = file .. ".lock"
    -- (mkdir "p" raises E739 when another nvim creates the dir between its stat and mkdir)
    pcall(vim.fn.mkdir, vim.fs.dirname(file), "p")
    local fd
    local token = new_token()
    for _ = 1, M.lock_tries do
      fd = vim.uv.fs_open(lock, "wx", 420)
      if fd then
        vim.uv.fs_write(fd, token)
        break
      end
      local st = vim.uv.fs_stat(lock)
      if st and os.time() - st.mtime.sec > M.stale_after then
        local seen = read_all(lock)
        if seen then
          reap(lock, seen)
        end
        if vim.uv.fs_stat(lock) then
          vim.uv.sleep(5) -- still there (a live lock the stat was too old for): do not spin
        end
      else
        vim.uv.sleep(5)
      end
    end
    local ok, err = pcall(function()
      local all = M.read(file)
      fn(all)
      M.write(file, all)
    end)
    if fd then
      vim.uv.fs_close(fd)
      if read_all(lock) == token then -- only our own lock: after a reap it may be somebody else's now
        vim.uv.fs_unlink(lock)
      end
    end
    if not ok then
      error(err, 0)
    end
  end

  return M
end)()

local M = {}

local function file()
  return vim.fn.stdpath("state") .. "/xyno-rust-trust.json"
end
M.file = file

--- One spelling per directory: symlinks resolved (a link into a trusted tree is
--- that tree), Windows drive letters / slashes unified, no trailing slash.
function M.normalize(root)
  if type(root) ~= "string" or root == "" then
    return nil
  end
  local real = vim.uv.fs_realpath(root) or root
  local okc, rc = pcall(require, "xyno_rust.rust_context")
  if okc and type(rc.canon) == "function" then
    real = rc.canon(real)
  elseif vim.fn.has("win32") == 1 then
    real = real:gsub("\\", "/"):gsub("^(%a):", string.lower)
  end
  real = real:gsub("[/\\]+$", "")
  return real ~= "" and real or "/"
end

-- ------------------------------------------------------------ fingerprint
--
-- What is watched (api 1.4). Two sources, merged:
--   * `cargo metadata --no-deps --offline` (async, `M.prime`): every workspace member's manifest, build script
--     targets (`custom-build`, also a custom `package.build = "x/gen.rs"`), proc-macro targets (every .rs file
--     beside the crate's lib: it runs inside the compiler) and the manifests of path dependencies (their own
--     build.rs and proc-macro sources too, followed up to MAX_MANIFESTS manifests). `cargo metadata --no-deps`
--     does not run rustc, a wrapper or a build script (checked with canaries); `RUSTUP_AUTO_INSTALL=0` keeps
--     a rust-toolchain file from making rustup download a toolchain.
--   * a bounded fallback that needs no cargo and is what the synchronous calls use until the metadata is
--     there (and when cargo fails): the old directory walk (depth 6, 2500 directories) plus a scan of the
--     manifests it found for `build = "path"`, `path = "..."` dependencies, workspace `members` outside the
--     root and `[lib] proc-macro = true` crates, followed up to MAX_MANIFESTS manifests; modules of a build
--     script (`mod x;`, `#[path]`, `include!`) one level deep.
-- Files are hashed whole up to MAX_BYTES (32 MiB, in 1 MiB chunks); a larger file is hashed over its first
-- 32 MiB, its last MiB and its size. At most MAX_FILES (400) files are watched: more sets `truncated`.

local SKIP_DIR = { target = true, [".git"] = true, [".hg"] = true, [".svn"] = true, node_modules = true }
local WATCHED =
  { ["Cargo.toml"] = true, ["build.rs"] = true, ["rust-toolchain"] = true, ["rust-toolchain.toml"] = true }
local MAX_FILES, MAX_DEPTH = 400, 6
local CHUNK, MAX_BYTES = 1024 * 1024, 32 * 1024 * 1024
local MAX_DIRS = 2500 -- directories scanned per fingerprint: a huge tree is cut off (`truncated`), never walked for ever
local MAX_MANIFESTS = 64 -- manifests followed through path dependencies / members
local MAX_PM_FILES = 200 -- .rs files watched per proc-macro crate

M._max_dirs = MAX_DIRS
M._max_bytes = MAX_BYTES

local function stamp(path)
  local st = vim.uv.fs_stat(path)
  return st and ("%d.%d:%d"):format(st.mtime.sec, st.mtime.nsec, st.size) or "-"
end

-- fingerprint memo: path -> { fp, stamps = { [dir or file] = stamp } }. A memoised result is used while every
-- directory it scanned and every file it read still has the stat stamp it had (an added or removed entry
-- changes the directory's mtime), so the callers that ask often (statuslines, FocusGained, every command)
-- stat the tree instead of scanning and hashing it, and a real change is still seen at once.
local memo = {}
-- cargo metadata results: path -> { files = { full path, ... }, stamps = { [manifest] = stamp } }; dropped when
-- a manifest it was made from changes
local meta = {}
local meta_busy = {}

local function memo_valid(m)
  for path, st in pairs(m.stamps) do
    if stamp(path) ~= st then
      return false
    end
  end
  return true
end

local function digest(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local parts, total = {}, 0
  while total < MAX_BYTES do
    local chunk = f:read(CHUNK)
    if not chunk then
      break
    end
    total = total + #chunk
    parts[#parts + 1] = vim.fn.sha256(chunk)
  end
  local size = f:seek("end") or total
  if size > MAX_BYTES then
    f:seek("set", size - CHUNK)
    parts[#parts + 1] = vim.fn.sha256(f:read(CHUNK) or "")
    parts[#parts + 1] = tostring(size)
  end
  f:close()
  return #parts == 1 and parts[1] or vim.fn.sha256(table.concat(parts, ":"))
end

local function read_text(path, max)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read(max or 262144)
  f:close()
  return s
end

local function is_file(p)
  local st = vim.uv.fs_stat(p)
  return st and st.type == "file"
end

local function is_dir(p)
  local st = vim.uv.fs_stat(p)
  return st and st.type == "directory"
end

local function join(dir, rel)
  if rel:sub(1, 1) == "/" then
    return vim.fs.normalize(rel)
  end
  return vim.fs.normalize(dir .. "/" .. rel)
end

--- The text of the `[section]` table of a manifest (up to the next table header), or "".
local function section(text, name)
  local s, e = text:find("\n%[" .. name:gsub("%p", "%%%0") .. "%]%s*\n")
  if not s then
    if text:find("^%[" .. name:gsub("%p", "%%%0") .. "%]") then
      s, e = 1, text:find("\n") or #text
    else
      return ""
    end
  end
  local nxt = text:find("\n%[", e)
  return "\n" .. text:sub(e, nxt and nxt or #text)
end

--- Every .rs file under `dir` (depth 4, at most `limit`), sorted.
local function rs_files(dir, limit)
  local out = {}
  local function go(d, depth)
    local h = vim.uv.fs_scandir(d)
    if not h then
      return
    end
    local subs = {}
    while true do
      local name, kind = vim.uv.fs_scandir_next(h)
      if not name then
        break
      end
      if kind == "file" and name:sub(-3) == ".rs" then
        out[#out + 1] = d .. "/" .. name
      elseif kind == "directory" and depth < 4 and not SKIP_DIR[name] then
        subs[#subs + 1] = d .. "/" .. name
      end
    end
    table.sort(subs)
    for _, s in ipairs(subs) do
      if #out < limit then
        go(s, depth + 1)
      end
    end
  end
  go(dir, 0)
  table.sort(out)
  while #out > limit do
    out[#out] = nil
  end
  return out
end

--- The modules a build script pulls in beside it: `mod x;`, `#[path = "p"] mod x;`, `include!("p")`.
local function script_modules(script)
  local text = read_text(script)
  local out = {}
  if not text then
    return out
  end
  text = "\n" .. text
  local dir = vim.fs.dirname(script)
  for name in text:gmatch("\nmod%s+([%w_]+)%s*;") do
    for _, cand in ipairs({ dir .. "/" .. name .. ".rs", dir .. "/" .. name .. "/mod.rs" }) do
      if is_file(cand) then
        out[#out + 1] = cand
      end
    end
  end
  for p in text:gmatch('#%[path%s*=%s*"([^"]+)"%]') do
    out[#out + 1] = join(dir, p)
  end
  for p in text:gmatch('include!%(%s*"([^"]+)"') do
    out[#out + 1] = join(dir, p)
  end
  return out
end

--- Files of the manifests that matter, found from the manifest text alone (the bounded fallback) and, for each
--- manifest, the manifests of what it points at. `add(full)` records a file; returns the manifest list.
local function scan_manifests(seed, add, stamps)
  local queue, seen, n = {}, {}, 0
  for _, m in ipairs(seed) do
    if not seen[m] then
      seen[m] = true
      queue[#queue + 1] = m
    end
  end
  local function push(manifest)
    if not seen[manifest] and is_file(manifest) and #queue < MAX_MANIFESTS * 4 then
      seen[manifest] = true
      queue[#queue + 1] = manifest
    end
  end
  local i = 1
  while queue[i] and n < MAX_MANIFESTS do
    local manifest = queue[i]
    i = i + 1
    n = n + 1
    add(manifest)
    local dir = vim.fs.dirname(manifest)
    stamps[dir] = stamp(dir)
    local text = read_text(manifest)
    if text then
      -- a build script: `build = "x/gen.rs"` (a custom path), `build = false` (none), else build.rs
      local pkg = section(text, "package")
      local custom = pkg:match('\nbuild%s*=%s*"([^"]+)"')
      local script
      if custom then
        script = join(dir, custom)
      elseif not pkg:find("\nbuild%s*=%s*false") then
        script = dir .. "/build.rs"
      end
      if script and is_file(script) then
        add(script)
        for _, mod in ipairs(script_modules(script)) do
          if is_file(mod) then
            add(mod)
          end
        end
      end
      -- a proc-macro crate: every .rs file of it runs inside the compiler
      local lib = section(text, "lib")
      if lib:find("proc[-_]macro%s*=%s*true") then
        local lp = lib:match('\npath%s*=%s*"([^"]+)"') or "src/lib.rs"
        local src = vim.fs.dirname(join(dir, lp))
        stamps[src] = stamp(src)
        for _, f in ipairs(rs_files(src, MAX_PM_FILES)) do
          add(f)
        end
      end
      -- path dependencies, patches, workspace members outside the tree
      for p in text:gmatch('path%s*=%s*"([^"]+)"') do
        local target = join(dir, p)
        if is_dir(target) then
          push(target .. "/Cargo.toml")
        end
      end
      for list in text:gmatch("members%s*=%s*(%b[])") do
        for p in list:gmatch('"([^"]+)"') do
          if p:sub(-2) == "/*" then
            local base = join(dir, p:sub(1, -3))
            local h = vim.uv.fs_scandir(base)
            while h do
              local name, kind = vim.uv.fs_scandir_next(h)
              if not name then
                break
              end
              if kind == "directory" then
                push(base .. "/" .. name .. "/Cargo.toml")
              end
            end
          elseif not p:find("[%*%?%[]") then
            push(join(dir, p) .. "/Cargo.toml")
          end
        end
      end
    end
  end
  return seen
end

--- What `cargo metadata` names that runs code, as full paths; nil when it is unavailable or failed.
local function files_of_metadata(data)
  local out, manifests = {}, {}
  for _, pkg in ipairs(data.packages or {}) do
    if pkg.manifest_path then
      out[#out + 1] = pkg.manifest_path
      manifests[#manifests + 1] = pkg.manifest_path
    end
    for _, t in ipairs(pkg.targets or {}) do
      local kinds = table.concat(t.kind or {}, ",")
      if t.src_path and kinds:find("custom%-build") then
        out[#out + 1] = t.src_path
        vim.list_extend(out, script_modules(t.src_path))
      elseif t.src_path and kinds:find("proc%-macro") then
        vim.list_extend(out, rs_files(vim.fs.dirname(t.src_path), MAX_PM_FILES))
      end
    end
    for _, dep in ipairs(pkg.dependencies or {}) do
      if dep.path then
        manifests[#manifests + 1] = dep.path .. "/Cargo.toml"
      end
    end
  end
  return out, manifests
end

--- Run `cargo metadata --no-deps --offline` for `root` in the background and remember what it names; `cb(ok,
--- err)` when done. Afterwards `fingerprint(root)` includes those files (the memo is dropped). Never runs a
--- build script, proc macro or rustc wrapper (`--no-deps` is a manifest read); nothing is downloaded.
function M.prime(root, cb)
  local path = M.normalize(root)
  cb = cb or function() end
  if not path or not is_file(path .. "/Cargo.toml") then
    return cb(false, "no Cargo.toml")
  end
  if vim.fn.executable("cargo") ~= 1 then
    return cb(false, "no cargo")
  end
  if meta_busy[path] then
    return cb(false, "busy")
  end
  meta_busy[path] = true
  local ok, err = pcall(vim.system, {
    "cargo",
    "metadata",
    "--no-deps",
    "--offline",
    "--format-version",
    "1",
    "--manifest-path",
    path .. "/Cargo.toml",
  }, { text = true, cwd = path, timeout = 20000, env = { RUSTUP_AUTO_INSTALL = "0" } }, function(res)
    vim.schedule(function()
      meta_busy[path] = nil
      if res.code ~= 0 or not res.stdout or res.stdout == "" then
        return cb(false, (res.stderr or ""):sub(1, 200))
      end
      local dok, data = pcall(vim.json.decode, res.stdout)
      if not dok or type(data) ~= "table" then
        return cb(false, "bad metadata")
      end
      local files, manifests = files_of_metadata(data)
      -- the path dependencies' own build scripts / proc-macro crates, from their manifests
      local extra, stamps = {}, {}
      scan_manifests(manifests, function(f)
        extra[#extra + 1] = f
      end, stamps)
      vim.list_extend(files, extra)
      for _, m in ipairs(manifests) do
        stamps[m] = stamp(m)
      end
      stamps[path .. "/Cargo.toml"] = stamp(path .. "/Cargo.toml")
      meta[path] = { files = files, stamps = stamps }
      memo[path] = nil
      cb(true)
    end)
  end)
  if not ok then
    meta_busy[path] = nil
    cb(false, tostring(err))
  end
end

--- true while the metadata of `root` is known and still valid
function M.primed(root)
  local path = M.normalize(root)
  local m = path and meta[path]
  return m ~= nil and memo_valid({ stamps = m.stamps })
end

--- What cargo executes or obeys under `root`: { hash = combined, files = { [name] = first 12 hex digits } }.
--- Names are relative to root, or absolute for files outside it (parent directories, path dependencies).
--- opts.fresh: ignore the memo. opts.assume: a `files` table of a stored entry; its names are watched too (so
--- the answer matches an entry recorded with the metadata before the metadata of this session is there).
function M.fingerprint(root, opts)
  local path = M.normalize(root)
  local cached = path and memo[path]
  local want_key = opts and opts.assume and (opts.key or false) or nil
  if cached and not (opts and opts.fresh) and cached.key == want_key and memo_valid(cached) then
    return cached.fp
  end
  local files, n, truncated, ndirs = {}, 0, false, 0
  local stamps = {}
  local function name_of(full)
    if path and full:sub(1, #path + 1) == path .. "/" then
      return full:sub(#path + 2)
    end
    return full
  end
  local function add(full, name)
    name = name or name_of(full)
    if files[name] then
      return
    end
    if n >= MAX_FILES then
      truncated = true
      return
    end
    local d = digest(full)
    if d then
      n = n + 1
      files[name] = d:sub(1, 12)
      stamps[full] = stamp(full)
    end
  end
  local manifests = {}
  local function walk(dir, rel, depth)
    if ndirs >= MAX_DIRS then
      truncated = true
      return
    end
    ndirs = ndirs + 1
    stamps[dir] = stamp(dir)
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
      return
    end
    local sub = {}
    while true do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local relname = rel == "" and name or (rel .. "/" .. name)
      if kind == "file" then
        if
          WATCHED[name]
          or ((name == "config" or name == "config.toml") and vim.fs.basename(dir) == ".cargo")
          or (name == "run.toml" and vim.fs.basename(dir) == ".xynovim")
        then
          add(dir .. "/" .. name, relname)
          if name == "Cargo.toml" then
            manifests[#manifests + 1] = dir .. "/" .. name
          end
        end
      elseif kind == "directory" and not SKIP_DIR[name] and depth < MAX_DEPTH then
        sub[#sub + 1] = { dir .. "/" .. name, relname }
      end
    end
    table.sort(sub, function(a, b)
      return a[2] < b[2]
    end)
    for _, d in ipairs(sub) do
      walk(d[1], d[2], depth + 1)
    end
  end
  if path then
    walk(path, "", 0)
    -- build scripts at custom paths, path dependencies and members outside the tree, proc-macro crates
    table.sort(manifests)
    scan_manifests(manifests, function(full)
      add(full)
    end, stamps)
    -- what cargo metadata named, while it is still valid
    local m = meta[path]
    if m and memo_valid({ stamps = m.stamps }) then
      for _, full in ipairs(m.files) do
        add(full)
      end
    else
      meta[path] = nil
    end
    if opts and opts.assume then
      local names = vim.tbl_keys(opts.assume)
      table.sort(names)
      for _, name in ipairs(names) do
        add(name:sub(1, 1) == "/" and name or (path .. "/" .. name), name)
      end
    end
    -- cargo reads .cargo/config(.toml) and rustup rust-toolchain(.toml) of every parent directory
    local dir = vim.fs.dirname(path)
    local guard = 0
    while dir and dir ~= "" and guard < 64 do
      guard = guard + 1
      stamps[dir] = stamp(dir) -- a new .cargo/config or rust-toolchain here changes the directory
      if vim.uv.fs_stat(dir .. "/.cargo") then
        stamps[dir .. "/.cargo"] = stamp(dir .. "/.cargo")
      end
      for _, name in ipairs({ ".cargo/config", ".cargo/config.toml", "rust-toolchain", "rust-toolchain.toml" }) do
        add((dir == "/" and "" or dir) .. "/" .. name, dir == "/" and ("/" .. name) or (dir .. "/" .. name))
      end
      local up = vim.fs.dirname(dir)
      if up == dir then
        break
      end
      dir = up
    end
  end
  local names = vim.tbl_keys(files)
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do
    parts[#parts + 1] = name .. "\0" .. files[name]
  end
  local fp = { hash = vim.fn.sha256(table.concat(parts, "\n")), files = files, truncated = truncated or nil }
  if path then
    memo[path] = { fp = fp, stamps = stamps, key = opts and opts.assume and (opts.key or false) or nil }
  end
  return fp
end

--- Forget the memoised fingerprints and metadata (specs; the stat check makes it unnecessary otherwise).
function M._forget()
  memo = {}
  meta = {}
  meta_busy = {}
end

local function changed_files(old, new)
  local out = {}
  for name, h in pairs(new) do
    if old[name] ~= h then
      out[#out + 1] = name
    end
  end
  for name in pairs(old) do
    if new[name] == nil then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

--- The fingerprint to compare an entry with: before this session's metadata is there, the names the entry
--- recorded are watched too.
local function current_fp(path, e)
  if e.files and not M.primed(path) then
    return M.fingerprint(path, { assume = e.files, key = e.hash })
  end
  return M.fingerprint(path)
end

local function entry_of(path)
  local e = statefile.read(file())[path]
  return type(e) == "table" and e or nil
end

local function entries()
  local out = {}
  for root, e in pairs(statefile.read(file())) do
    if type(root) == "string" and type(e) == "table" then
      out[root] = {
        recursive = e.recursive == true,
        at = tonumber(e.at) or 0,
        hash = type(e.hash) == "string" and e.hash or nil,
        files = type(e.files) == "table" and e.files or nil,
      }
    end
  end
  return out
end

local function inside(path, dir)
  if dir == "/" then
    return true
  end
  return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

--- The entry of `path` itself is trusted only while the content it was trusted for is unchanged.
--- An entry without a fingerprint (stored by an older version) takes the current one on first sight.
local function entry_current(path, e)
  if e.recursive then
    return true
  end
  if not e.hash then
    pcall(function()
      local f = M.fingerprint(path)
      statefile.update(file(), function(all)
        if type(all[path]) == "table" and not all[path].hash then
          all[path].hash, all[path].files = f.hash, f.files
        end
      end)
    end)
    return true
  end
  return current_fp(path, e).hash == e.hash
end

--- Whether `root` (a workspace root or any path in it) is trusted. Second result: the entry that trusts it.
--- A workspace whose manifests / build scripts / cargo config / toolchain changed since it was trusted is
--- not (see the header; `drift` names the files).
function M.is_trusted(root)
  local path = M.normalize(root)
  if not path then
    return false
  end
  local all = entries()
  if all[path] and entry_current(path, all[path]) then
    return true, path
  end
  for dir, e in pairs(all) do
    if e.recursive and inside(path, dir) then
      return true, dir
    end
  end
  return false
end

--- nil when `root` has no entry of its own or nothing changed; else the names of the changed files.
function M.drift(root)
  local path = M.normalize(root)
  local e = path and entries()[path]
  if not e or e.recursive or not e.hash then
    return nil
  end
  local f = current_fp(path, e)
  if f.hash == e.hash then
    return nil
  end
  local names = e.files and changed_files(e.files, f.files) or {}
  return #names > 0 and names or { "(content)" }
end

--- Record the current content for the entry of `root` itself. Returns whether it was recorded.
--- With `saved` (an edit made inside nvim: the path that was saved) only that file may differ from what
--- was trusted: if something else changed too (a pulled build.rs next to the Cargo.toml you just
--- saved), nothing is recorded and the workspace stays untrusted.
function M.rehash(root, saved)
  local path = M.normalize(root)
  local e = path and entries()[path]
  if not e or e.recursive then
    return false
  end
  local f = M.fingerprint(path, { fresh = true, assume = e.files })
  if saved and e.files then
    local only = {}
    for _, one in ipairs(type(saved) == "table" and saved or { saved }) do
      only[vim.fs.normalize(vim.uv.fs_realpath(one) or one)] = true
    end
    for _, name in ipairs(changed_files(e.files, f.files)) do
      local full = name:sub(1, 1) == "/" and name or (path .. "/" .. name)
      if not only[vim.fs.normalize(vim.uv.fs_realpath(full) or full)] then
        return false
      end
    end
  end
  local had = false
  statefile.update(file(), function(all)
    local cur = all[path]
    if type(cur) == "table" and not cur.recursive then
      cur.hash, cur.files = f.hash, f.files
      had = true
    end
  end)
  return had
end

function M.trust(root, opts)
  local path = M.normalize(root)
  assert(path, "trust.trust: a directory is required")
  local fp = not (opts and opts.recursive) and M.fingerprint(path, { fresh = true }) or nil
  statefile.update(file(), function(all)
    local recursive = (opts and opts.recursive) == true
    all[path] = { recursive = recursive, at = os.time() }
    if not recursive then
      all[path].hash, all[path].files = fp.hash, fp.files
    end
  end)
  if not (opts and opts.recursive) and not (opts and opts.no_prime) then
    -- read what cargo says runs code (in the background); the files it adds to the ones just recorded
    -- belong to this decision, so they are recorded too when nothing recorded has changed meanwhile
    local at = statefile.read(file())[path]
    at = type(at) == "table" and at.at or nil
    M.prime(path, function(ok)
      if not ok then
        return
      end
      statefile.update(file(), function(all)
        local cur = all[path]
        if type(cur) == "table" and not cur.recursive and cur.at == at and cur.files then
          local f = M.fingerprint(path, { fresh = true })
          for name, h in pairs(cur.files) do
            if f.files[name] ~= h then
              return -- something recorded changed: leave the entry, the drift is real
            end
          end
          cur.hash, cur.files = f.hash, f.files
        end
      end)
    end)
  end
  return path
end

--- Returns whether an entry was removed.
function M.revoke(root)
  local path = M.normalize(root)
  local had = false
  if path then
    statefile.update(file(), function(all)
      had = all[path] ~= nil
      all[path] = nil
    end)
  end
  return had
end

function M.revoke_all()
  statefile.update(file(), function(all)
    for k in pairs(all) do
      all[k] = nil
    end
  end)
end

function M.list()
  local out = {}
  for root, e in pairs(entries()) do
    out[#out + 1] = { root = root, recursive = e.recursive, at = e.at }
  end
  table.sort(out, function(a, b)
    return a.root < b.root
  end)
  return out
end

local asking = {} -- root -> { cb ... } : one prompt per root at a time
local ask_timers = {} -- root -> uv timer that gives up on a prompt nobody answers
M.float_prompt = nil -- nil: the float when a UI is attached, vim.ui.select otherwise; true / false force one
M.ask_timeout_ms = 300000 -- a prompt vim.ui.select never answers (a broken UI plugin) is dropped after this long

local function drop_asking()
  for path, t in pairs(ask_timers) do
    pcall(function()
      t:stop()
      t:close()
    end)
    ask_timers[path] = nil
  end
  asking = {}
end

--- Ask whether to trust `root` for `what` (a short description of the action).
--- cb(true) after "trust" or "run once", cb(false) otherwise. Nothing is stored
--- for "run once" and "do not run": the next action asks again.
function M.ask(root, what, cb)
  local path = M.normalize(root)
  if not path then
    return cb(false)
  end
  if asking[path] then
    table.insert(asking[path], cb)
    return
  end
  asking[path] = { cb }
  local parent = vim.fs.dirname(path)
  local drifted = M.drift(path)
  local choices = {
    { "Trust this workspace", "trust" },
    { "Trust everything under " .. parent, "parent" },
    { "Run this once", "once" },
    { "Do not run", "no" },
  }
  if parent == path or parent == "." then
    table.remove(choices, 2)
  end
  local mine = asking[path] -- a late answer of a prompt that already timed out must not touch a newer one
  local function finish(answer)
    if asking[path] ~= mine then
      return
    end
    asking[path] = nil
    local t = ask_timers[path]
    if t then
      ask_timers[path] = nil
      pcall(function()
        t:stop()
        t:close()
      end)
    end
    for _, f in ipairs(mine) do
      f(answer)
    end
  end
  if not M._leave_hooked then
    M._leave_hooked = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("xynovim_trust_ask", { clear = true }),
      callback = drop_asking, -- no callbacks at exit: the refusal would only notify into a closing UI
    })
  end
  local timer = vim.uv.new_timer()
  ask_timers[path] = timer
  timer:start(
    M.ask_timeout_ms,
    0,
    vim.schedule_wrap(function()
      if asking[path] == mine then
        vim.notify(
          ("xyno-rust: the trust prompt for %s got no answer and was dropped (treated as 'do not run')"):format(path),
          vim.log.levels.WARN
        )
        finish(false)
      end
    end)
  )
  local body = ("Trust %s?\n%s can run code from it (build.rs, proc macros, tests, workflow steps)."):format(path, what)
    .. (
      drifted
        and ("\nTrusted before, but changed since: %s%s"):format(
          table.concat(vim.list_slice(drifted, 1, 6), ", "),
          #drifted > 6 and (" and " .. (#drifted - 6) .. " more") or ""
        )
      or ""
    )
  local function answered(choice)
    local kind = choice and choice[2]
    if kind == "trust" or kind == "parent" then
      local tok, terr = pcall(M.trust, kind == "parent" and parent or path, { recursive = kind == "parent" })
      if not tok then
        vim.notify("xyno-rust: could not remember the choice: " .. tostring(terr), vim.log.levels.WARN)
      end
      return finish(true)
    end
    finish(kind == "once")
  end
  local ok, err
  if M.float_prompt ~= false and (#vim.api.nvim_list_uis() > 0 or M.float_prompt == true) then
    -- a wrapped float of our own: vim.ui.select shows the text as a one-line picker title (cut off on a
    -- narrow terminal) and its input line left the editor in insert mode
    ok, err = pcall(function()
      require("xynovim.trust_prompt").open({ title = "Workspace trust", body = body, choices = choices }, answered)
    end)
  else
    ok, err = pcall(vim.ui.select, choices, {
      prompt = body,
      format_item = function(c)
        return c[1]
      end,
    }, answered)
  end
  if not ok then
    if asking[path] ~= mine then
      error(err, 0) -- the prompt answered and a callback raised: that is the caller's error, not the prompt's
    end
    vim.notify("xyno-rust: the trust prompt failed: " .. tostring(err), vim.log.levels.WARN)
    finish(false)
  end
end

--- cb(true) when `root` is trusted or the user agrees; cb(false) otherwise (a refusal is notified).
function M.require(root, what, cb)
  if M.is_trusted(root) then
    return cb(true)
  end
  M.ask(root, what, function(ok)
    if not ok then
      vim.notify(
        ("xyno-rust: %s not run: %s is not a trusted workspace (:RustTrust add)"):format(what, tostring(root)),
        vim.log.levels.WARN
      )
    end
    cb(ok)
  end)
end

--- rust-analyzer settings that stop an untrusted workspace from running code:
--- no build scripts, no proc macros (rust-analyzer then reports less, it does not fail).
function M.ra_overrides(root)
  if M.is_trusted(root) then
    return {}
  end
  return {
    cargo = { buildScripts = { enable = false } },
    procMacro = { enable = false },
  }
end

local function target_dir(arg)
  if arg and arg ~= "" then
    return vim.fn.fnamemodify(vim.fn.expand(arg), ":p")
  end
  return (function()
    local ok, rc = pcall(require, "xyno_rust.rust_context")
    return ok and rc.root() or nil
  end)() or vim.uv.cwd()
end

local function fmt(e)
  return ("%s%s  (%s)"):format(e.root, e.recursive and "/**" or "", e.at > 0 and os.date("%Y-%m-%d", e.at) or "?")
end

--- :RustTrust [list | add [dir] | revoke [dir] | revoke-all | status]
function M.command(args)
  local sub, rest = args:match("^(%S*)%s*(.-)%s*$")
  if sub == "" or sub == "list" then
    local list = M.list()
    if #list == 0 then
      return vim.notify("xyno-rust: no trusted workspaces", vim.log.levels.INFO)
    end
    if sub == "" then -- the bare command lists and offers to revoke
      return vim.ui.select(
        list,
        { prompt = "Trusted Rust workspaces (select one to revoke)", format_item = fmt },
        function(e)
          if e then
            M.revoke(e.root)
            vim.notify("xyno-rust: revoked " .. e.root)
          end
        end
      )
    end
    return vim.notify("xyno-rust trusted workspaces:\n" .. table.concat(vim.tbl_map(fmt, list), "\n"))
  elseif sub == "add" then
    local dir = target_dir(rest)
    vim.notify("xyno-rust: trusted " .. M.trust(dir))
  elseif sub == "revoke" then
    local dir = target_dir(rest)
    vim.notify(
      M.revoke(dir) and ("xyno-rust: revoked " .. M.normalize(dir))
        or ("xyno-rust: " .. dir .. " had no entry of its own"),
      vim.log.levels.INFO
    )
  elseif sub == "revoke-all" then
    M.revoke_all()
    vim.notify("xyno-rust: all trust entries revoked")
  elseif sub == "status" then
    local dir = target_dir(rest)
    local ok, by = M.is_trusted(dir)
    vim.notify(
      ("xyno-rust: %s is %s%s"):format(
        M.normalize(dir),
        ok and "trusted" or "NOT trusted",
        ok and by ~= M.normalize(dir) and (" (under " .. by .. ")") or ""
      )
    )
  else
    vim.notify(
      "RustTrust: unknown argument '" .. sub .. "' (list, add, revoke, revoke-all, status)",
      vim.log.levels.WARN
    )
  end
end

--- opts.commands = false: do not define :RustTrust.
function M.setup(opts)
  if (opts and opts.commands == false) or vim.fn.exists(":RustTrust") == 2 then
    return
  end
  vim.api.nvim_create_user_command("RustTrust", function(a)
    M.command(a.args)
  end, {
    nargs = "*",
    complete = function(lead, line)
      if line:match("^%S+%s+%S*$") then
        return vim.tbl_filter(function(s)
          return s:find(lead, 1, true) == 1
        end, { "list", "add", "revoke", "revoke-all", "status" })
      end
      return vim.fn.getcompletion(lead, "dir")
    end,
    desc = "Workspace trust for running Rust targets and tools: list, add, revoke",
  })
end

return M
