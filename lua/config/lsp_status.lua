-- Server-readiness indicator for the statusline: rust-analyzer (starting /
-- indexing N% / ready, plus its health) and bacon-ls (clippy running / failed
-- / stale / fresh). Purely event driven (LspProgress, experimental/serverStatus,
-- window/showMessage, TextChanged) - nothing runs at idle. The one exception is
-- "deps resolving" (below), which arms a grace timer and a 120 s ceiling while it is shown.
--
-- rustaceanvim handles experimental/serverStatus itself but keeps no state, so
-- the client's handler is wrapped once on attach. bacon-ls reports each clippy
-- run as $/progress; "stale" means the buffer's text changed after the last
-- finished run started, i.e. the clippy diagnostics on screen predate your
-- edit. Edits are counted with nvim_buf_attach (not b:changedtick, which a
-- write also bumps: every auto-save would have left "stale" up for good). When cargo cannot run at all (broken manifest, cyclic
-- dependency) bacon-ls ends the run normally and only sends an error
-- window/showMessage: that is "failed". "stopped" is a server that exited
-- (rust_restart.lua records it and restarts it).
-- "deps resolving" is shown from the save of a Cargo.toml/Cargo.lock (rust_restart.lua calls
-- deps_begin) until rust-analyzer's workspace load finishes: during that window the new
-- dependency is unknown to both servers and a red "cannot find crate" is transient. It ends
-- at the first quiescent=true report after a busy one, 6 s after the write when rust-analyzer
-- never went busy (nothing to reload), at 120 s, on a restart or when the buffer is wiped.
local M = {}

local DEPS_GRACE_MS, DEPS_TIMEOUT_MS = 6000, 120000
---@type table<string, { buf: integer?, busy: boolean, token: table }>
local deps = {} -- workspace root -> pending resolution

---@type table<integer, { tokens: table<string, table>, last: string?, health: string?, quiescent: boolean?, message: string?, failed: boolean?, begin_ticks: table<integer, integer>?, ticks: table<integer, integer>?, wrapped: boolean? }>
local state = {}

local function st(id)
  state[id] = state[id] or { tokens = {} }
  return state[id]
end

--- buf -> number of text changes seen since the buffer was first attached.
--- Only ever grows: the remembered tick of the last clippy run is compared to
--- it, and a counter that restarted at 0 after `:edit!` (which detaches the
--- buffer) hid "stale" for the next N edits.
---@type table<integer, integer>
local edits = {}
---@type table<integer, boolean>
local counting = {}

local function count_edits(buf)
  if counting[buf] then
    return
  end
  counting[buf] = true
  edits[buf] = edits[buf] or 0
  local function bump()
    edits[buf] = (edits[buf] or 0) + 1
  end
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = bump,
    on_reload = bump,
    on_detach = function()
      counting[buf] = nil
    end,
  })
end

local function redraw()
  vim.schedule(function()
    vim.cmd.redrawstatus()
  end)
end

--- "Indexing 42%" / "Fetching" for the newest progress item of a client.
local function progress_text(s)
  local p = s.last and s.tokens[s.last]
  if not p then
    return nil
  end
  local text = p.title or p.message or "working"
  if p.percentage then
    text = text .. " " .. p.percentage .. "%"
  end
  return text
end

--- True when the server `name` exited under this buffer (see rust_restart.lua).
local function stopped(bufnr, name)
  local flags = vim.b[bufnr].xynovim_stopped
  return flags ~= nil and flags[name] == true
end

function M.rust_analyzer(bufnr)
  local c = vim.lsp.get_clients({ bufnr = bufnr or 0, name = "rust-analyzer" })[1]
  if not c then
    return stopped(bufnr or 0, "rust-analyzer") and "RA stopped" or nil
  end
  local s = st(c.id)
  local busy = progress_text(s)
  if s.quiescent == nil then
    return "RA " .. (busy or "starting")
  elseif not s.quiescent or busy then
    return "RA " .. (busy or "loading")
  elseif s.health == "error" then
    -- a standalone script (rust-script, a lone .rs): no workspace to load is not a failure
    if (s.message or ""):find("Failed to discover workspace", 1, true) then
      return "RA detached"
    end
    return "RA error"
  elseif s.health == "warning" then
    return "RA ready (warn)"
  end
  return "RA ready"
end

--- Whether the last bacon-ls run of client `id` failed (cargo exited with an error).
function M.bacon_failed(id)
  return st(id).failed == true
end

function M.bacon(bufnr)
  local c = vim.lsp.get_clients({ bufnr = bufnr or 0, name = "bacon_ls" })[1]
  if not c then
    return stopped(bufnr or 0, "bacon_ls") and "clippy stopped" or nil
  end
  local s = st(c.id)
  if next(s.tokens) then
    return "clippy running"
  elseif s.failed then
    return "clippy failed"
  end
  local buf = bufnr and bufnr ~= 0 and bufnr or vim.api.nvim_get_current_buf()
  local seen = s.ticks and s.ticks[buf]
  if seen and (edits[buf] or 0) > seen then
    return "clippy stale"
  end
  -- "ok" meant "finished", also with errors on screen: say how many
  local ERROR = vim.diagnostic.severity.ERROR
  local has_ns, ns = pcall(vim.lsp.diagnostic.get_namespace, c.id)
  local errors = has_ns and vim.api.nvim_buf_is_valid(buf) and vim.diagnostic.count(buf, { namespace = ns, severity = ERROR })[ERROR] or 0
  if errors > 0 then
    return ("clippy %dE"):format(errors)
  end
  return "clippy ok"
end

--- Whether some rust-analyzer client that covers `root` is idle (quiescent) right now.
local function ra_idle(root)
  local any = false
  for _, c in ipairs(vim.lsp.get_clients({ name = "rust-analyzer" })) do
    local r = c.config and c.config.root_dir
    if not r or root:sub(1, #r + 1) == r .. "/" or r:sub(1, #root + 1) == root .. "/" or r == root then
      any = true
      if state[c.id] == nil or state[c.id].quiescent ~= true then
        return false
      end
    end
  end
  return any
end

--- Ends the pending resolution of `root` (all of them without argument).
function M.deps_clear(root)
  if root then
    deps[root] = nil
  else
    deps = {}
  end
  redraw()
end

--- A Cargo.toml/Cargo.lock under `root` was saved: show "deps resolving" until
--- rust-analyzer has reloaded the workspace. Never sticks: see the header.
---@param root string workspace root
---@param buf integer? the manifest buffer (its wipe ends the wait)
function M.deps_begin(root, buf)
  local token = {}
  local busy = false
  for _, c in ipairs(vim.lsp.get_clients({ name = "rust-analyzer" })) do
    if state[c.id] and state[c.id].quiescent == false then
      busy = true -- already loading: its next quiescent=true is the end
    end
  end
  deps[root] = { buf = buf, busy = busy, token = token }
  local function alive()
    return deps[root] and deps[root].token == token
  end
  vim.defer_fn(function()
    if alive() and not deps[root].busy and (ra_idle(root) or #vim.lsp.get_clients({ name = "rust-analyzer" }) == 0) then
      M.deps_clear(root)
    end
  end, DEPS_GRACE_MS)
  vim.defer_fn(function()
    if alive() then
      M.deps_clear(root)
    end
  end, DEPS_TIMEOUT_MS)
  redraw()
end

--- "deps resolving" while a manifest below which `bufnr`'s file lives is being resolved.
function M.deps(bufnr)
  if next(deps) == nil then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  for root in pairs(deps) do
    if name:sub(1, #root + 1) == root .. "/" then
      return "deps resolving"
    end
  end
  return nil
end

--- rust-analyzer reported its status: ends the waits it has finished.
local function deps_status(client, quiescent)
  for root, d in pairs(deps) do
    local r = client.config and client.config.root_dir
    if not r or root:sub(1, #r + 1) == r .. "/" or r:sub(1, #root + 1) == root .. "/" or r == root then
      if quiescent == false then
        d.busy = true
      elseif quiescent == true and d.busy then
        M.deps_clear(root)
      end
    end
  end
end

--- Combined lualine string ("" hides the component outside Rust buffers).
function M.component()
  local parts = {}
  for _, f in ipairs({ M.deps, M.rust_analyzer, M.bacon }) do
    parts[#parts + 1] = f()
  end
  return table.concat(parts, " | ")
end

function M.setup()
  local group = vim.api.nvim_create_augroup("xynovim_lsp_status", { clear = true })

  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if not client then
        return
      end
      -- a restarted/attached server is no longer "stopped"
      local flags = vim.b[ev.buf].xynovim_stopped
      if flags and flags[client.name] then
        flags[client.name] = nil
        vim.b[ev.buf].xynovim_stopped = flags
      end
      if client.name == "bacon_ls" then
        local s = st(client.id)
        s.ticks = s.ticks or {}
        count_edits(ev.buf)
        s.ticks[ev.buf] = s.ticks[ev.buf] or edits[ev.buf]
        if not s.wrapped then
          s.wrapped = true
          local orig = client.handlers["window/showMessage"] or vim.lsp.handlers["window/showMessage"]
          client.handlers["window/showMessage"] = function(err, result, ctx, config)
            -- type 1 = Error: "cargo exited with exit status: 101: ..."
            if result and result.type == vim.lsp.protocol.MessageType.Error then
              s.failed = true
              redraw()
            end
            if orig then
              return orig(err, result, ctx, config)
            end
          end
        end
      elseif client.name == "rust-analyzer" and not st(client.id).wrapped then
        local s = st(client.id)
        s.wrapped = true
        local orig = client.handlers["experimental/serverStatus"] or vim.lsp.handlers["experimental/serverStatus"]
        client.handlers["experimental/serverStatus"] = function(err, result, ctx, config)
          if result then
            s.health, s.quiescent, s.message = result.health, result.quiescent, result.message
            deps_status(client, result.quiescent)
            redraw()
          end
          if orig then
            return orig(err, result, ctx, config)
          end
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      for root, d in pairs(deps) do
        if d.buf == ev.buf then
          M.deps_clear(root)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("LspProgress", {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if not (client and (client.name == "rust-analyzer" or client.name == "bacon_ls")) then
        return
      end
      local s = st(client.id)
      local token, v = tostring(ev.data.params.token), ev.data.params.value
      if v.kind == "end" then
        s.tokens[token] = nil
        if s.last == token then
          s.last = next(s.tokens)
        end
        -- the finished run saw every buffer as of its begin
        if client.name == "bacon_ls" and not next(s.tokens) and s.begin_ticks then
          s.ticks = s.begin_ticks
        end
      else
        if v.kind == "begin" and client.name == "bacon_ls" then
          s.failed = false
          s.begin_ticks = {}
          for b in pairs(client.attached_buffers) do
            s.begin_ticks[b] = edits[b] or 0
          end
        end
        local p = s.tokens[token] or {}
        p.title = v.title or p.title
        p.message = v.message or p.message
        p.percentage = v.percentage or p.percentage
        s.tokens[token] = p
        s.last = token
      end
      redraw()
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(ev)
      -- "stale" is derived from the edit counter when drawn
      if #vim.lsp.get_clients({ bufnr = ev.buf, name = "bacon_ls" }) > 0 then
        redraw()
      end
    end,
  })
end

return M
