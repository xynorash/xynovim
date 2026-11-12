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
--   * Without xyno_rust.trust (an older plugin checkout) nothing is gated.
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

--- Whether the gate is active (switched on, and the plugin has a trust store).
function M.enabled()
  return vim.g.xynovim_workspace_trust ~= false and plugin() ~= nil
end

--- One spelling of a workspace root (what xyno_rust.trust stores), or nil for no workspace.
local function key_of(root)
  local t = plugin()
  return t and root and t.normalize(root) or nil
end

--- The cargo workspace root of a path (the key trust entries use), nil outside a crate.
function M.workspace(path)
  local ok, ctx = pcall(require, "xyno_rust.rust_context")
  if not ok or not path then
    return nil
  end
  return ctx.root(path)
end

--- Whether the workspace `root` may run code. A path outside any workspace (nil) always may: a lone
--- script has no build.rs and no proc-macro crate to run.
function M.trusted(root)
  if not M.enabled() or not root then
    return true
  end
  local key = key_of(root)
  if not key then
    return true
  end
  if session[key] then
    return true
  end
  if cache[key] == nil then
    cache[key] = plugin().is_trusted(key) == true
  end
  return cache[key]
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
  local key = M.enabled() and key_of(root) or nil
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

local function has_ui()
  return #vim.api.nvim_list_uis() > 0
end

local function banner(key)
  vim.notify(
    (
      "Restricted mode: %s is not a trusted workspace. rust-analyzer runs without build scripts and proc macros, "
      .. "clippy (bacon-ls) is off. :RustTrust add trusts it."
    ):format(key),
    vim.log.levels.WARN,
    { title = "xynovim" }
  )
end

--- Ask once per workspace and session (never twice, never without a UI).
function M.prompt(key)
  if asked[key] or not has_ui() then
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

--- Hook the trust store (so `:RustTrust add` / revoke restart the servers at once) and the statusline.
--- Idempotent; does nothing without xyno_rust.trust.
function M.setup()
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
