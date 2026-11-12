-- Workspace trust for the language servers (restricted mode).
--
-- Opening a Rust project is running its code: rust-analyzer runs build.rs and proc macros while it loads
-- the workspace, `cargo check` / clippy (bacon-ls) compile them again, and `cargo metadata` honours the
-- rustc wrappers of .cargo/config.toml. RustRover (Safe Mode), Zed (Restricted Mode: language servers are
-- not spawned) and VS Code (Restricted Mode) all hold that back until the folder is trusted; this module
-- does the same on top of the trust list of xyno-rust.nvim (xyno_rust.trust, `:RustTrust`):
--
--   * untrusted workspace -> rust-analyzer still starts (navigation, syntax, types work) but with
--     procMacro.enable = false, cargo.buildScripts.enable = false, checkOnSave = false and the rustc
--     wrappers cleared through cargo.extraEnv; bacon-ls (clippy compiles everything) is not started.
--   * one prompt per workspace and session when a UI exists: trust / trust everything under the parent /
--     run this once / stay restricted. "Trust" is remembered in xyno_rust.trust's file for ever (shared by
--     all Neovim instances), "once" for this session, a refusal leaves the status bar marker and a
--     notification with the command.
--   * trusting (`:RustTrust add`, the prompt, another Neovim instance) restarts rust-analyzer with the
--     full settings and starts bacon-ls; revoking restricts both again. A trusted workspace gets exactly
--     the settings it always had.
--   * `vim.g.xynovim_workspace_trust = false` switches the gate off. Without a UI (headless) nothing is
--     asked and the workspace stays restricted until trusted.
--   * Without xyno_rust.trust (an older plugin checkout) the gate FAILS CLOSED where it matters: a
--     workspace with a Cargo.toml up the tree is restricted and nothing can run its code (there is no
--     trust list to ask), with one notice naming the fix (update the xyno-rust.nvim pin) and the
--     switch-off. A path with no Cargo.toml (a lone .rs file) has nothing to build and stays allowed.
--   * Trust follows the content (xyno_rust.trust api 1.3): a workspace trusted by its own entry is
--     untrusted again when a Cargo.toml, build.rs, .cargo/config(.toml) or rust-toolchain(.toml) differs
--     from what was trusted (a pull, a checkout), once per session and workspace, with the changed files
--     named in the prompt. Saving such a file inside Neovim is not a surprise and re-records it, unless
--     another trusted-content file changed too. Detected at start, on every command, on FocusGained
--     (back from the terminal where `git pull` ran) and on those saves; between a pull and the next
--     focus rust-analyzer may already have reloaded the workspace (a limit of watching without a
--     file-system hook in the server). "Everything under <parent>" keeps no fingerprint.
--
-- ONE check for everything that runs project code (`require("config.workspace_trust")`):
--   .allowed(root)                 fresh, no prompt: may this workspace run code now?
--   .require(root, what, cb)       cb(true|false); asks once when needed (never without a UI)
--   .system(cmd, opts, on_exit, what)   vim.system behind .require (on_exit gets { denied = true })
--   .install()                     guards rustaceanvim's executors (runnables, testables) and dap.start
--   .guard_neotest(client)         guards neotest's Client:run_tree (every neotest run)
--   .trusted(root)                 cached answer for statuslines / linters
-- tests/trust-gate-commands_spec.lua scans lua/ for any spawn of cargo / rustc / a variable command that
-- is neither behind these nor annotated `-- trust: read-only <why>`.
--
-- Limits (also in docs/comparison/security-and-features.md): `cargo.extraEnv` clears the wrappers and
-- RUSTC for rust-analyzer's own cargo calls; a `rust-toolchain.toml` still makes rustup fetch a toolchain;
-- other plugins that run cargo are gated by xyno-rust.nvim itself, not here.
local M = {}

local session = {} -- workspace key -> true: "run this once" answers
local asked = {} -- workspace key -> true: prompted in this session
local applied = {} -- workspace key -> true|false: what rust-analyzer's settings were built for
local cache = {} -- workspace key -> boolean (is_trusted reads a file: not on every redraw)
local watcher

local function plugin()
  local ok, t = pcall(require, "xyno_rust.trust")
  if ok and type(t) == "table" and type(t.is_trusted) == "function" and type(t.ra_overrides) == "function" then
    return t
  end
end

--- Whether the gate has a trust store to ask (switched on, and the plugin has one).
function M.enabled()
  return vim.g.xynovim_workspace_trust ~= false and plugin() ~= nil
end

--- Whether the gate is switched on at all (`vim.g.xynovim_workspace_trust = false` is the one switch-off).
local function active()
  return vim.g.xynovim_workspace_trust ~= false
end

--- One spelling of a workspace root (what xyno_rust.trust stores), or nil for no workspace.
local function key_of(root)
  if not root then
    return nil
  end
  local t = plugin()
  if t then
    return t.normalize(root)
  end
  return vim.uv.fs_realpath(root) or root
end

--- The cargo workspace root of a path (the key trust entries use), nil outside a crate.
function M.workspace(path)
  if not path then
    return nil
  end
  local ok, ctx = pcall(require, "xyno_rust.rust_context")
  if ok and type(ctx.root) == "function" then
    return ctx.root(path)
  end
  -- no rust_context (a broken checkout): the nearest Cargo.toml still says "this is a crate"
  local found = vim.fs.find("Cargo.toml", { path = vim.fs.dirname(path), upward = true, type = "file" })[1]
  return found and vim.fs.dirname(found) or nil
end

--- The workspace of a file or a directory (a directory is looked at from inside).
local function workspace_of(path)
  if not path or path == "" then
    return nil
  end
  local st = vim.uv.fs_stat(path)
  if st and st.type == "directory" then
    return M.workspace(path .. "/x")
  end
  return M.workspace(path)
end

--- Whether the workspace `root` may run code (cached for the session: statuslines, linters). A path
--- outside any workspace (nil) always may: a lone script has no build.rs and no proc-macro crate to run.
--- Without a trust store (older xyno-rust.nvim) a workspace is NOT trusted: nothing could have asked.
function M.trusted(root)
  if not active() or not root then
    return true
  end
  local t = plugin()
  if not t then
    return workspace_of(root) == nil
  end
  local key = key_of(root)
  if not key then
    return true
  end
  if session[key] then
    return true
  end
  if cache[key] == nil then
    cache[key] = t.is_trusted(key) == true
  end
  return cache[key]
end

--- Like `trusted` for a file or directory, but read afresh (no cache): what a command asks before it
--- runs code. Files and directories are resolved to their workspace; none means nothing to run.
function M.allowed(path)
  if not active() or not path then
    return true
  end
  local root = workspace_of(path)
  if not root then
    return true
  end
  local t = plugin()
  if not t then
    return false
  end
  local key = key_of(root)
  if not key then
    return true
  end
  if session[key] then
    return true
  end
  cache[key] = t.is_trusted(key) == true
  return cache[key]
end

local function has_ui()
  return #vim.api.nvim_list_uis() > 0
end

local no_store_told = false

--- Run `cb(true)` when the workspace of `path` may run code, else ask (once; a UI is needed) and call
--- `cb(true|false)`. `what` names the action in the prompt. "Trust" is remembered by xyno_rust.trust,
--- "run this once" runs this action only. Never blocks; `cb` may run before this returns.
function M.require(path, what, cb)
  if M.allowed(path) then
    return cb(true)
  end
  local root = workspace_of(path)
  local t = plugin()
  local key = key_of(root)
  if not t then
    if not no_store_told then
      no_store_told = true
      vim.notify(
        "xynovim: this xyno-rust.nvim has no workspace trust, so nothing may run the code of "
          .. key
          .. " (update the xyno-rust.nvim pin in lazy-lock.json, or vim.g.xynovim_workspace_trust = false)",
        vim.log.levels.WARN,
        { title = "xynovim" }
      )
    end
    return cb(false)
  end
  local function denied()
    vim.notify(
      ("%s not run: %s is not a trusted workspace (:RustTrust add)"):format(what, key),
      vim.log.levels.WARN,
      { title = "xynovim" }
    )
    cb(false)
  end
  if not has_ui() then
    return denied()
  end
  t.ask(key, what, function(answer)
    cache[key] = nil
    if not answer then
      return denied()
    end
    cb(true)
  end)
end

--- vim.system behind `require`: `on_exit` (as vim.system's) gets { code = 126, denied = true } when the
--- workspace of opts.cwd may not run code. `opts.on_start()` runs once the run is allowed. Returns nothing (the process may not have started).
function M.system(cmd, opts, on_exit, what)
  local on_start = opts and opts.on_start -- called once the run is allowed, just before it starts
  if on_start then
    opts = vim.tbl_extend("force", {}, opts)
    opts.on_start = nil
  end
  M.require(opts and opts.cwd, what or table.concat(cmd, " "), function(ok)
    if ok then
      if on_start then
        on_start()
      end
      vim.system(cmd, opts, on_exit) -- trust: gated by the require above
    elseif on_exit then
      on_exit({ code = 126, signal = 0, stdout = "", stderr = "not run: the workspace is not trusted", denied = true })
    end
  end)
end

local guarded = setmetatable({}, { __mode = "k" }) -- wrapper function -> true

--- Whether `fn` is a wrapper installed by this module.
function M.is_guarded(fn)
  return guarded[fn] == true
end

--- Wrap `tbl[name]` (called as fn(...)) so it runs after M.require(root_of(...)). Idempotent.
local function guard(tbl, name, root_of, what_of)
  local orig = tbl[name]
  if type(orig) ~= "function" or guarded[orig] then
    return
  end
  local wrapper = function(...)
    local args = { ... }
    local n = select("#", ...)
    M.require(root_of(...), what_of(...), function(ok)
      if ok then
        orig(unpack(args, 1, n))
      end
    end)
  end
  guarded[wrapper] = true
  tbl[name] = wrapper
end

--- Guard what rustaceanvim runs for :RustLsp runnables / testables / debuggables / the debug-build step:
--- its executors and dap.start. Called when rust-analyzer's settings are built (rustaceanvim is loaded).
function M.install()
  local ok, ex = pcall(require, "rustaceanvim.executors")
  if ok then
    for _, e in pairs(ex) do
      if type(e) == "table" then
        guard(e, "execute_command", function(_, _, cwd)
          return cwd or vim.uv.cwd()
        end, function(cmd, args)
          return table.concat(vim.list_extend({ cmd }, args or {}), " ")
        end)
      end
    end
  end
  local okd, dap = pcall(require, "rustaceanvim.dap")
  if okd then
    guard(dap, "start", function(args)
      return args and args.workspaceRoot or vim.uv.cwd()
    end, function(args)
      return "cargo " .. table.concat(args and args.cargoArgs or {}, " ") .. " (debug build)"
    end)
  end
end

--- Guard a neotest client: every run (`Client:run_tree`, which all of neotest's run functions end in)
--- of a position inside an untrusted workspace asks first; a refusal starts nothing.
function M.guard_neotest(client)
  if client._xyno_trust_guard then
    return
  end
  client._xyno_trust_guard = true
  local orig = client.run_tree
  client.run_tree = function(self, tree, args)
    local data = tree and tree:data()
    local path = data and data.path
    if not path or M.allowed(path) then
      return orig(self, tree, args)
    end
    local fut = require("nio").control.future()
    M.require(path, "tests (neotest)", function(ok)
      fut.set(ok)
    end)
    if fut.wait() then
      return orig(self, tree, args)
    end
  end
end

--- The settings of a restricted workspace, merged into rust-analyzer's.
function M.overrides(root)
  local t = plugin()
  local o = t and t.ra_overrides(root) or {}
  if next(o) == nil then
    o = { cargo = { buildScripts = { enable = false } }, procMacro = { enable = false } }
  end
  o.checkOnSave = false -- `cargo check` compiles build.rs and proc macros too
  o.cargo = vim.tbl_deep_extend("force", o.cargo or {}, {
    loadOutDirsFromCheck = false,
    -- cargo reads rustc / wrappers from .cargo/config.toml of the project; the environment wins
    extraEnv = {
      RUSTC = "rustc",
      RUSTC_WRAPPER = "",
      RUSTC_WORKSPACE_WRAPPER = "",
      CARGO_BUILD_RUSTC = "rustc",
      CARGO_BUILD_RUSTC_WRAPPER = "",
      CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER = "",
    },
  })
  return o
end

--- rust-analyzer settings for `root`: `settings` unchanged when trusted, restricted otherwise.
--- Remembers which of the two the server was started with (restart on a change) and asks once.
function M.settings_for(root, settings)
  M.setup()
  local key = active() and key_of(root) or nil
  if not key then
    return settings
  end
  local ok = M.trusted(root)
  applied[key] = ok
  if ok then
    return settings
  end
  M.watch()
  M.prompt(key)
  local ra = settings["rust-analyzer"] or {}
  settings["rust-analyzer"] = vim.tbl_deep_extend("force", ra, M.overrides(root))
  return settings
end

--- Whether to start bacon-ls (clippy compiles the workspace) for `root`.
function M.allow_bacon(root)
  M.setup()
  if M.trusted(root) then
    return true
  end
  local key = key_of(root)
  if key then
    applied[key] = applied[key] == nil and false or applied[key]
    M.watch()
    M.prompt(key)
  end
  return false
end

local function banner(key)
  local t = plugin()
  local why = t and (t.drift and t.drift(key))
  vim.notify(
    (
      "Restricted mode: %s is not a trusted workspace%s. rust-analyzer runs without build scripts and proc macros, "
      .. "clippy (bacon-ls) is off. %s"
    ):format(
      key,
      why and (" (changed since it was trusted: " .. table.concat(vim.list_slice(why, 1, 4), ", ") .. ")") or "",
      t and ":RustTrust add trusts it."
        or "This xyno-rust.nvim has no workspace trust: update the pin in lazy-lock.json (or vim.g.xynovim_workspace_trust = false)."
    ),
    vim.log.levels.WARN,
    { title = "xynovim" }
  )
end

--- Ask once per workspace and session (never twice, never without a UI).
function M.prompt(key)
  if asked[key] then
    return
  end
  if not plugin() then
    asked[key] = true
    banner(key)
    return
  end
  if not has_ui() then
    return
  end
  asked[key] = true
  vim.schedule(function()
    local t = plugin()
    if not t or M.trusted(key) then
      return
    end
    t.ask(key, "rust-analyzer (build scripts, proc macros) and clippy", function(answer)
      if answer and not t.is_trusted(key) then
        session[key] = true -- "run this once": for this session
      end
      cache[key] = nil
      if answer then
        M.refresh()
      else
        banner(key)
      end
    end)
  end)
end

local function rust_buffers()
  return vim.tbl_filter(function(b)
    return vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "rust" and vim.bo[b].buftype == ""
  end, vim.api.nvim_list_bufs())
end

local function key_of_buf(b)
  local name = vim.api.nvim_buf_get_name(b)
  local root = name ~= "" and M.workspace(name)
  return root and key_of(root) or nil
end

local function restart_ra(keys)
  local clients = vim.lsp.get_clients({ name = "rust-analyzer" })
  if #clients == 0 then
    return
  end
  local ids = {}
  for _, c in ipairs(clients) do
    ids[#ids + 1] = c.id
    c:stop(true)
  end
  local tries = 0
  local timer = vim.uv.new_timer()
  timer:start(
    100,
    100,
    vim.schedule_wrap(function()
      tries = tries + 1
      local alive = false
      for _, id in ipairs(ids) do
        alive = alive or vim.lsp.get_client_by_id(id) ~= nil
      end
      if alive and tries < 50 then
        return
      end
      timer:stop()
      timer:close()
      local ok, lsp = pcall(require, "rustaceanvim.lsp")
      if not ok then
        return
      end
      for _, b in ipairs(rust_buffers()) do
        if vim.api.nvim_buf_is_valid(b) and #vim.lsp.get_clients({ bufnr = b, name = "rust-analyzer" }) == 0 then
          lsp.start(b)
        end
      end
    end)
  )
end

--- Compare what the servers were started with and what the trust list says now; restart rust-analyzer
--- when its workspaces changed side, start bacon-ls for newly trusted ones and stop it where trust is gone.
function M.refresh()
  cache = {}
  local changed = {}
  for key, was in pairs(applied) do
    local now = M.trusted(key)
    if now ~= was then
      changed[#changed + 1] = key
      applied[key] = now
    end
  end
  if #changed == 0 then
    vim.cmd.redrawstatus()
    return
  end
  table.sort(changed)
  for _, key in ipairs(changed) do
    if not M.trusted(key) then
      asked[key] = nil -- trust was lost (revoked, or the content changed): ask again, once
    end
    vim.notify(
      M.trusted(key)
          and ("Workspace trusted: %s. Restarting rust-analyzer with build scripts and proc macros, starting clippy."):format(
            key
          )
        or ("Workspace restricted: %s. Restarting rust-analyzer without build scripts and proc macros, stopping clippy."):format(
          key
        ),
      vim.log.levels.INFO,
      { title = "xynovim" }
    )
  end
  restart_ra(changed)
  for _, key in ipairs(changed) do
    if not M.trusted(key) then
      M.prompt(key)
    end
  end
  for _, c in ipairs(vim.lsp.get_clients({ name = "bacon_ls" })) do
    local root = c.config.root_dir
    if root and not M.trusted(root) then
      c:stop(true)
    end
  end
  -- bacon_ls: off and on re-evaluates root_dir for every buffer (enable() of an enabled config is a no-op)
  vim.lsp.enable("bacon_ls", false)
  vim.lsp.enable("bacon_ls")
  vim.cmd.redrawstatus()
end

--- Watch the trust file (another Neovim instance may trust or revoke) while some workspace is restricted.
function M.watch()
  local t = plugin()
  if watcher or not t then
    return
  end
  local file = t.file()
  local dir, name = vim.fs.dirname(file), vim.fs.basename(file)
  watcher = vim.uv.new_fs_event()
  if not watcher then
    return
  end
  local pending = false
  local ok = pcall(function()
    watcher:start(dir, {}, function(err, fname)
      if err or fname ~= name or pending then
        return
      end
      pending = true
      vim.defer_fn(function()
        pending = false
        M.refresh()
      end, 200)
    end)
  end)
  if not ok then
    watcher = nil
  end
end

--- The statusline part: "restricted" in a Rust buffer of an untrusted workspace.
function M.status(bufnr)
  if not M.enabled() or vim.bo[bufnr].filetype ~= "rust" then
    return ""
  end
  local key = key_of_buf(bufnr)
  if key and not M.trusted(key) then
    return "RESTRICTED"
  end
  return ""
end

--- Trust state for :checkhealth: { enabled, workspace?, trusted?, by?, restricted = {keys} }.
function M.report(path)
  local out = { enabled = M.enabled(), restricted = {} }
  local t = plugin()
  if not t then
    return out
  end
  local ws = M.workspace(path or vim.uv.cwd() .. "/x")
  if ws then
    out.workspace = key_of(ws)
    local ok, by = t.is_trusted(ws)
    out.trusted = ok or session[out.workspace] == true
    out.by = ok and by or (session[out.workspace] and "this session" or nil)
  end
  for key, ok in pairs(applied) do
    if not ok then
      out.restricted[#out.restricted + 1] = key
    end
  end
  table.sort(out.restricted)
  return out
end

local MANIFEST = { ["Cargo.toml"] = true, ["build.rs"] = true, ["rust-toolchain"] = true, ["rust-toolchain.toml"] = true }

local function is_trust_input(path)
  local name = vim.fs.basename(path)
  return MANIFEST[name] or ((name == "config" or name == "config.toml") and vim.fs.basename(vim.fs.dirname(path)) == ".cargo")
end

--- Look at the trust state again (files changed behind Neovim's back: a `git pull` in a terminal).
--- Restarts rust-analyzer restricted and asks once when a trusted workspace lost its trust.
--- Returns whether the workspace of `path` (default: every one in use) is still trusted.
function M.recheck(path)
  cache = {}
  M.refresh()
  if path then
    return M.trusted(workspace_of(path) or path)
  end
  for _, ok in pairs(applied) do
    if not ok then
      return false
    end
  end
  return true
end

--- Hook the trust store (so `:RustTrust add` / revoke restart the servers at once), the statusline, the
--- guards of rustaceanvim, and the content checks (saves inside Neovim re-record, FocusGained re-checks).
--- Idempotent. Without xyno_rust.trust only the guards are installed.
function M.setup()
  pcall(M.install)
  local t = plugin()
  if not t or t._xynovim_gate then
    return
  end
  t._xynovim_gate = true
  for _, fn in ipairs({ "trust", "revoke", "revoke_all" }) do
    local orig = t[fn]
    t[fn] = function(...)
      local r = { orig(...) }
      vim.schedule(M.refresh)
      return unpack(r)
    end
  end
  local ok, status = pcall(require, "xyno_rust.lsp_status")
  if ok and type(status.add_part) == "function" then
    status.add_part(M.status)
  end
  if type(t.rehash) == "function" then
    local group = vim.api.nvim_create_augroup("xynovim_workspace_trust", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      desc = "xynovim: a saved Cargo.toml / build.rs / cargo config is not a surprise to the trust gate",
      callback = function(ev)
        local file = vim.api.nvim_buf_get_name(ev.buf)
        if file == "" or not is_trust_input(file) then
          return
        end
        local root = M.workspace(file)
        if root then
          pcall(t.rehash, root, file)
          cache = {}
        end
      end,
    })
    local pending = false
    vim.api.nvim_create_autocmd("FocusGained", {
      group = group,
      desc = "xynovim: files changed while Neovim was in the background (git pull) re-check workspace trust",
      callback = function()
        if pending or next(applied) == nil then
          return
        end
        pending = true
        vim.defer_fn(function()
          pending = false
          M.recheck()
        end, 100)
      end,
    })
  end
end

--- Forget everything (specs).
function M._reset()
  session, asked, applied, cache = {}, {}, {}, {}
  if watcher then
    pcall(watcher.stop, watcher)
    pcall(watcher.close, watcher)
    watcher = nil
  end
end

return M
