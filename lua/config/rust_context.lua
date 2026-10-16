-- Per-project Cargo "context" (features / target), RustRover's Cargo tool
-- window toggles. rust-analyzer and bacon-ls (the clippy tier) must agree on
-- both, otherwise mutually exclusive features give bogus errors from one tier.
-- Stored per workspace root in stdpath("state"); applied at server start
-- (rustaceanvim `server.settings`, bacon_ls `before_init`) and live by
-- :RustContext.
--
-- ctx = { all = boolean, no_default = boolean, features = string[], target = string? }
-- Default (nothing stored): all features, host target - i.e. the old behaviour.
local M = {}

local state_file = vim.fn.stdpath("state") .. "/rust-context.json"

local function read_all()
  local f = io.open(state_file)
  if not f then
    return {}
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  return ok and type(data) == "table" and data or {}
end

local function write_all(data)
  vim.fn.mkdir(vim.fs.dirname(state_file), "p")
  -- write aside and rename: a reader (another nvim) never sees a truncated file
  local tmp = ("%s.%d.tmp"):format(state_file, vim.uv.os_getpid())
  local f = assert(io.open(tmp, "w"))
  f:write(vim.json.encode(data))
  f:close()
  assert(require("config.fsutil").rename(tmp, state_file))
end

local function mtime(path)
  local st = path and vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. "." .. st.mtime.nsec) or "-"
end

--- Cargo's own answer for the workspace of `dir` (`cargo locate-project
--- --workspace`): knows `members` and `exclude`, so an excluded crate or one
--- with its own [workspace] is its own root. Cached per directory and the
--- modification time of the manifests it was computed from.
local located = {}
local function cargo_workspace(dir, stamp)
  local hit = located[dir]
  if hit and hit.stamp == stamp then
    return hit.root or nil
  end
  local root = false
  if vim.fn.executable("cargo") == 1 then
    local ok, o = pcall(function()
      return vim.system({ "cargo", "locate-project", "--workspace", "--message-format", "plain" }, { cwd = dir, text = true }):wait(5000)
    end)
    local manifest = ok and o and o.code == 0 and vim.trim(o.stdout or "") or ""
    if manifest:match("Cargo%.toml$") then
      root = vim.fs.dirname(manifest)
    end
  end
  located[dir] = { stamp = stamp, root = root }
  return root or nil
end

--- One spelling of a root per directory (the state file is keyed by it):
--- cargo prints backslashes and sometimes a \\?\ prefix, LSP gives file URIs with
--- a lowercase drive letter. Only on Windows; elsewhere the path is untouched.
local function canon(p)
  if p and vim.fn.has("win32") == 1 then
    p = vim.fs.normalize((p:gsub("^\\\\%?\\", "")), { expand_env = false })
    p = p:gsub("^(%a):", string.lower)
  end
  return p
end

--- Workspace root (dir holding the top Cargo.toml) for a path.
function M.root(path)
  return canon(M._root(path))
end

function M._root(path)
  path = path or vim.api.nvim_buf_get_name(0)
  local found = vim.fs.find("Cargo.toml", { upward = true, path = vim.fs.dirname(path) })
  local top
  -- Fallback when cargo cannot answer (no cargo, a manifest that does not
  -- parse): walk up to the outermost Cargo.toml that declares a [workspace]
  for _, f in ipairs(vim.fs.find("Cargo.toml", { upward = true, path = vim.fs.dirname(path), limit = math.huge })) do
    local fh = io.open(f)
    if fh then
      local txt = fh:read("*a")
      fh:close()
      if txt:find("%[workspace") then
        top = f
      end
    end
  end
  local f = top or found[1]
  if not found[1] then
    return nil
  end
  return cargo_workspace(vim.fs.dirname(path), mtime(found[1]) .. "|" .. mtime(top)) or vim.fs.dirname(f)
end

--- A hand-edited state file may hold anything (`{"features":5,"target":[]}` raised in describe()
--- and ra_cargo()): drop the fields of the wrong type, keep the rest as stored.
local function sanitize(ctx)
  if type(ctx) ~= "table" then
    return nil
  end
  local out = vim.deepcopy(ctx)
  for _, k in ipairs({ "all", "no_default" }) do
    if type(out[k]) ~= "boolean" then
      out[k] = nil
    end
  end
  if type(out.features) == "table" then
    out.features = vim.tbl_filter(function(f)
      return type(f) == "string" and f ~= ""
    end, vim.islist(out.features) and out.features or {})
  else
    out.features = nil
  end
  if type(out.target) ~= "string" or out.target == "" then
    out.target = nil
  end
  return out
end

function M.get(root)
  return root and sanitize(read_all()[root]) or nil
end

--- Settings.cargo table for rust-analyzer.
function M.ra_cargo(ctx)
  if not ctx then
    return nil
  end
  return {
    allFeatures = ctx.all == true,
    noDefaultFeatures = ctx.no_default == true,
    features = (ctx.all and {}) or ctx.features or {},
    target = ctx.target,
  }
end

--- Feature/target CLI flags of a context (nil = the defaults: all features,
--- host target), for the cargo commands the config runs itself.
function M.cargo_flags(ctx)
  local f = {}
  if not ctx or ctx.all then
    f[#f + 1] = "--all-features"
  else
    if ctx.no_default then
      f[#f + 1] = "--no-default-features"
    end
    if ctx.features and #ctx.features > 0 then
      vim.list_extend(f, { "--features", table.concat(ctx.features, ",") })
    end
  end
  if ctx and ctx.target then
    vim.list_extend(f, { "--target", ctx.target })
  end
  return f
end

--- cargo extraArgs for bacon-ls (replaces the hardcoded --all-features).
function M.bacon_args(ctx)
  return vim.list_extend(vim.list_extend({ "--workspace" }, M.cargo_flags(ctx)), { "--no-deps", "--keep-going" })
end

--- Human-readable summary, e.g. "features: ssr,csr | target: wasm32-unknown-unknown".
function M.describe(ctx)
  if not ctx or (ctx.all and not ctx.target) then
    return "all features, host target"
  end
  local parts = {}
  if ctx.all then
    parts[#parts + 1] = "all features"
  else
    parts[#parts + 1] = "features: " .. ((ctx.features and #ctx.features > 0) and table.concat(ctx.features, ",") or "(none)")
    if ctx.no_default then
      parts[#parts + 1] = "no default"
    end
  end
  parts[#parts + 1] = "target: " .. (ctx.target or "host")
  return table.concat(parts, " | ")
end

local function cargo_metadata(root)
  local o = vim.system({ "cargo", "metadata", "--format-version", "1", "--no-deps" }, { cwd = root, text = true }):wait(30000)
  if o.code ~= 0 then
    return nil, o.stderr
  end
  return vim.json.decode(o.stdout)
end

--- Push ctx into the running rust-analyzer and restart bacon-ls with matching args.
--- `ctx == nil` resets to the defaults (all features, host target) and forgets the stored choice.
--- Whether a client serves the workspace `root`: its root_dir, or any workspace
--- folder (rustaceanvim attaches a further workspace's buffers to the ONE
--- running rust-analyzer as an added folder; its root_dir stays the first's).
local function serves(c, root)
  local function is(dir)
    return dir ~= nil and M.root(dir .. "/x") == root
  end
  if is(c.config.root_dir) then
    return true
  end
  for _, wf in ipairs(c.workspace_folders or {}) do
    if is(wf.uri and vim.uri_to_fname(wf.uri)) then
      return true
    end
  end
  return false
end

--- Read, set one key, write, under a lock file: two nvims applying at once each read the
--- old file and the later rename dropped the other's key (8 nvims x 20 applies kept 79 of
--- 160). A lock older than 5s is a dead owner's; after ~2s without it the write goes on.
local function store(root, ctx)
  local lock = state_file .. ".lock"
  -- (mkdir "p" raises E739 when another nvim creates the dir between its stat and mkdir)
  pcall(vim.fn.mkdir, vim.fs.dirname(state_file), "p")
  local fd
  for _ = 1, 400 do
    fd = vim.uv.fs_open(lock, "wx", 420)
    if fd then
      break
    end
    local st = vim.uv.fs_stat(lock)
    if st and os.time() - st.mtime.sec > 5 then
      vim.uv.fs_unlink(lock)
    else
      vim.uv.sleep(5)
    end
  end
  local ok, err = pcall(function()
    local all = read_all()
    all[root] = ctx
    write_all(all)
  end)
  if fd then
    vim.uv.fs_close(fd)
    vim.uv.fs_unlink(lock)
  end
  if not ok then
    error(err, 0)
  end
end

function M.apply(root, ctx)
  store(root, ctx)
  local eff = ctx or { all = true, features = {} }
  for _, c in ipairs(vim.lsp.get_clients({ name = "rust-analyzer" })) do
    if serves(c, root) then
      local ra = c.settings["rust-analyzer"]
      ra.cargo = vim.tbl_extend("force", ra.cargo or {}, M.ra_cargo(eff))
      ra.cargo.target = eff.target -- nil clears it
      c:notify("workspace/didChangeConfiguration", { settings = c.settings })
    end
  end
  vim.schedule(function()
    pcall(vim.cmd.RustLsp, "reloadWorkspace")
    for _, c in ipairs(vim.lsp.get_clients({ name = "bacon_ls" })) do
      if serves(c, root) then
        vim.cmd("lsp restart bacon_ls")
        break
      end
    end
  end)
  vim.notify("Rust context: " .. M.describe(eff))
end

--- Interactive picker: features (multi-select with <Tab>), then target.
function M.pick()
  local root = M.root()
  if not root then
    return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
  end
  local meta, err = cargo_metadata(root)
  if not meta then
    return vim.notify("cargo metadata failed: " .. tostring(err), vim.log.levels.ERROR)
  end
  local cur = M.get(root) or { all = true }
  local items = {
    { text = "* all features", special = "all" },
    { text = "* default features only (clears the list)", special = "default" },
    { text = "* no-default-features", special = "nodefault" },
  }
  local multi = #meta.packages > 1
  for _, p in ipairs(meta.packages) do
    local names = vim.tbl_keys(p.features)
    table.sort(names)
    for _, f in ipairs(names) do
      if f ~= "default" then
        local q = multi and (p.name .. "/" .. f) or f
        items[#items + 1] = { text = q, feature = q }
      end
    end
  end
  Snacks.picker({
    title = "Cargo features (<Tab> multi-select) - now: " .. M.describe(cur),
    items = items,
    format = "text",
    layout = { preset = "select" },
    confirm = function(picker)
      local sel = picker:selected({ fallback = true })
      picker:close()
      local ctx = { all = false, no_default = false, features = {}, target = cur.target }
      for _, it in ipairs(sel) do
        if it.special == "all" then
          ctx.all = true
        elseif it.special == "nodefault" then
          ctx.no_default = true
        elseif it.feature then
          ctx.features[#ctx.features + 1] = it.feature
        end
      end
      local targets = { "(host default)" }
      local o = vim.system({ "rustup", "target", "list", "--installed" }, { text = true }):wait(10000)
      for t in (o.stdout or ""):gmatch("[^\n]+") do
        targets[#targets + 1] = t
      end
      vim.schedule(function()
        vim.ui.select(targets, { prompt = "Target (currently " .. (cur.target or "host") .. ")" }, function(choice)
          if choice then
            ctx.target = choice ~= "(host default)" and choice or nil
            M.apply(root, ctx)
          end
        end)
      end)
    end,
  })
end

function M.reset()
  local root = M.root()
  if not root then
    return vim.notify("no Cargo.toml found: nothing to reset", vim.log.levels.WARN)
  end
  M.apply(root, nil)
end

function M.setup()
  vim.api.nvim_create_user_command("RustContext", function(a)
    if a.args == "reset" then
      M.reset()
    elseif a.args == "show" then
      local root = M.root()
      if not root then
        return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
      end
      vim.notify("Rust context: " .. M.describe(M.get(root)))
    elseif a.args ~= "" then
      vim.notify("RustContext: unknown argument '" .. a.args .. "' (use show or reset, or no argument for the picker)", vim.log.levels.WARN)
    else
      M.pick()
    end
  end, {
    nargs = "?",
    complete = function()
      return { "show", "reset" }
    end,
    desc = "Pick cargo features / target for rust-analyzer + bacon-ls",
  })
end

return M
