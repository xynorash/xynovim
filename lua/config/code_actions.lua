-- textDocument/codeAction as data, for features that want to find and apply
-- one specific rust-analyzer action without a menu (auto-import, "Add crate",
-- "Enable feature"): request, normalise, filter, apply, wait.
--
-- Positions are 0-based { row, col } with a byte column (nvim_win_get_cursor
-- minus one on the row). A range is { start = pos, ["end"] = pos }; a bare pos
-- is an empty range; nil is the cursor.
--
-- action = { title, kind, is_preferred, edit, command, data, raw, client_id,
--            client_name, bufnr }
local M = {}

M.client_name = "rust-analyzer"

-- ServerCancelled / ContentModified: rust-analyzer's "I was busy changing
-- state, ask again"
local RETRY_CODES = { [-32801] = true, [-32802] = true }

local function retryable(err)
  return type(err) == "table" and (RETRY_CODES[err.code] or tostring(err.message or ""):lower():find("content modified", 1, true)) and true or false
end

--- The rust-analyzer clients of a buffer. Specs replace this to fake a server.
function M.clients(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = M.client_name })
end

local function lsp_pos(bufnr, pos, enc)
  local line = vim.api.nvim_buf_get_lines(bufnr, pos[1], pos[1] + 1, false)[1] or ""
  local col = math.min(pos[2], #line)
  local ok, ch = pcall(vim.str_utfindex, line, enc, col, false)
  return { line = pos[1], character = ok and ch or col }
end

local function to_range(bufnr, range)
  if not range then
    local c = vim.api.nvim_win_get_cursor(0)
    range = { c[1] - 1, c[2] }
  end
  if range.start then
    return range.start, range["end"] or range.start
  end
  return range, range
end

--- vim.Diagnostic -> LSP Diagnostic (the original one when the diagnostic came
--- from an LSP server, so `data` survives).
local function lsp_diagnostic(bufnr, d, enc)
  local lsp = d.user_data and (d.user_data.lsp or d.user_data)
  if type(lsp) == "table" and lsp.range then
    return lsp
  end
  return {
    range = {
      start = lsp_pos(bufnr, { d.lnum, d.col }, enc),
      ["end"] = lsp_pos(bufnr, { d.end_lnum or d.lnum, d.end_col or d.col }, enc),
    },
    message = d.message,
    severity = d.severity,
    code = d.code,
    source = d.source,
  }
end

local function normalize(item, client, bufnr)
  if item.disabled then
    return nil
  end
  -- `command` is either a Command (title, command) or, in a CodeAction, the
  -- command to run besides the edit
  local command = item.command
  if type(command) == "string" then
    command = { title = item.title, command = item.command, arguments = item.arguments }
  end
  return {
    title = item.title,
    kind = item.kind or "",
    is_preferred = item.isPreferred or false,
    edit = item.edit,
    command = command,
    data = item.data,
    raw = item,
    client_id = client.id,
    client_name = client.name,
    bufnr = bufnr,
  }
end

--- Ask every rust-analyzer client of `bufnr`. cb(list, errs): `list` holds the
--- normalised actions of all clients (ordered as answered per client), `errs`
--- the raw LSP errors (nil when none), so a caller can tell "nothing to offer"
--- from "rust-analyzer was busy".
--- opts: diagnostics (vim.Diagnostic[]), only (kind prefixes), trigger
--- ("invoked" default | "automatic").
function M.request(bufnr, range, opts, cb)
  opts = opts or {}
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local clients = M.clients(bufnr)
  if #clients == 0 then
    return vim.schedule(function()
      cb({}, { { code = -1, message = "no " .. M.client_name .. " client attached" } })
    end)
  end
  local from, to = to_range(bufnr, range)
  local list, errs, left = {}, {}, #clients
  for _, client in ipairs(clients) do
    local enc = client.offset_encoding or "utf-16"
    local diags = {}
    for _, d in ipairs(opts.diagnostics or {}) do
      diags[#diags + 1] = lsp_diagnostic(bufnr, d, enc)
    end
    local params = {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      range = { start = lsp_pos(bufnr, from, enc), ["end"] = lsp_pos(bufnr, to, enc) },
      context = {
        diagnostics = diags,
        only = opts.only,
        triggerKind = opts.trigger == "automatic" and 2 or 1,
      },
    }
    client:request("textDocument/codeAction", params, function(err, result)
      if err then
        errs[#errs + 1] = err
      end
      for _, item in ipairs(result or {}) do
        local a = normalize(item, client, bufnr)
        if a then
          list[#list + 1] = a
        end
      end
      left = left - 1
      if left == 0 then
        cb(list, #errs > 0 and errs or nil)
      end
    end, bufnr)
  end
end

-- ----------------------------------------------------------------- filter

local function kind_matches(kind, want)
  return kind == want or vim.startswith(kind, want .. ".")
end

--- spec = { kind = "quickfix" | { "quickfix", "refactor" }, title = lua
--- pattern, plain = bool (title is a literal), preferred = true }
function M.filter(list, spec)
  spec = spec or {}
  local kinds = type(spec.kind) == "string" and { spec.kind } or spec.kind
  return vim.tbl_filter(function(a)
    if kinds then
      local hit = false
      for _, k in ipairs(kinds) do
        hit = hit or kind_matches(a.kind, k)
      end
      if not hit then
        return false
      end
    end
    if spec.title and not a.title:find(spec.title, 1, spec.plain) then
      return false
    end
    if spec.preferred and not a.is_preferred then
      return false
    end
    return true
  end, list)
end

-- ------------------------------------------------------------------ apply

local function client_of(action)
  return action.client_id and vim.lsp.get_client_by_id(action.client_id)
end

--- Resolve a lazily filled action (rust-analyzer sends the edit only on
--- codeAction/resolve). cb(action) or cb(nil, err); retries "content
--- modified" for up to `timeout` ms.
function M.resolve_async(action, cb, opts)
  opts = opts or {}
  if action.edit or action.command or not action.data then
    return vim.schedule(function()
      cb(action)
    end)
  end
  local client = client_of(action)
  if not client then
    return vim.schedule(function()
      cb(nil, "client is gone")
    end)
  end
  local deadline = vim.uv.now() + (opts.timeout or 10000)
  local function attempt()
    client:request("codeAction/resolve", action.raw, function(err, result)
      if err then
        if retryable(err) and vim.uv.now() < deadline then
          return vim.defer_fn(attempt, 200)
        end
        return cb(nil, err.message or "resolve failed")
      end
      local r = normalize(result or action.raw, client, action.bufnr)
      cb(r or action)
    end, action.bufnr)
  end
  attempt()
end

--- Apply an action: resolve, then its edit, then its command. cb(ok, err).
--- opts.join = true joins the edit to the previous undo step.
function M.apply_async(action, cb, opts)
  opts = opts or {}
  M.resolve_async(action, function(a, err)
    if not a then
      return cb(false, err)
    end
    local client = client_of(a)
    if a.edit then
      local enc = client and client.offset_encoding or "utf-16"
      if opts.join then
        pcall(vim.api.nvim_buf_call, a.bufnr or 0, function()
          vim.cmd("silent! undojoin")
        end)
      end
      local ok, e = pcall(vim.lsp.util.apply_workspace_edit, a.edit, enc)
      if not ok then
        return cb(false, tostring(e))
      end
    end
    if a.command and a.command.command then
      if not client then
        return cb(false, "client is gone")
      end
      client:request("workspace/executeCommand", {
        command = a.command.command,
        arguments = a.command.arguments,
      }, function(cerr)
        cb(not cerr, cerr and (cerr.message or "command failed") or nil)
      end, a.bufnr)
      return
    end
    cb(true)
  end, opts)
end

-- ----------------------------------------------------------- sync wrappers

local function await(start, timeout_ms)
  local done, r1, r2
  start(function(a, b)
    done, r1, r2 = true, a, b
  end)
  if not vim.wait(timeout_ms, function()
    return done
  end, 10) then
    return nil, "timed out"
  end
  return r1, r2
end

--- Blocking apply: true, or false + error.
function M.apply(action, opts)
  opts = opts or {}
  local ok, err = await(function(cb)
    M.apply_async(action, cb, opts)
  end, (opts.timeout or 10000) + 5000)
  return ok == true, err
end

--- Apply several actions as ONE undo step (undojoin between the edits of the
--- current buffer). Actions are applied in order and each one's edit must still
--- fit the buffer the earlier ones changed: pass non-overlapping actions, or
--- re-request between steps. Returns the number applied and the first error.
function M.apply_all(actions, opts)
  local n, first_err = 0, nil
  for i, a in ipairs(actions) do
    local o = vim.tbl_extend("force", opts or {}, { join = i > 1 })
    local ok, err = M.apply(a, o)
    if not ok then
      first_err = first_err or err
      break
    end
    n = n + 1
  end
  return n, first_err
end

-- --------------------------------------------------------------- waiting

--- Blocking request that retries while rust-analyzer answers "content
--- modified" (it does so while it reloads after an edit). Returns list, err
--- (err = the last LSP error message when the retries ran out).
function M.request_wait(bufnr, range, opts)
  opts = opts or {}
  local deadline = vim.uv.now() + (opts.timeout or 10000)
  local list, errs
  repeat
    list, errs = await(function(cb)
      M.request(bufnr, range, opts, cb)
    end, 15000)
    if errs ~= nil and type(errs) ~= "table" then
      return {}, tostring(errs or "request failed")
    end
    local busy = false
    for _, e in ipairs(errs or {}) do
      busy = busy or retryable(e)
    end
    if not busy then
      break
    end
    vim.wait(200)
  until vim.uv.now() >= deadline
  if errs and #(list or {}) == 0 then
    return list or {}, tostring(errs[1].message or "request failed")
  end
  return list or {}, nil
end

--- Poll until an action matching `spec` (see filter) is offered, e.g. an
--- "Import" that only appears once rust-analyzer has analysed the file.
--- Returns the matching list (possibly empty after `timeout`).
function M.wait_for(bufnr, range, spec, opts)
  opts = opts or {}
  local deadline = vim.uv.now() + (opts.timeout or 30000)
  local hits = {}
  repeat
    local list = M.request_wait(bufnr, range, opts)
    hits = M.filter(list, spec)
    if #hits > 0 then
      break
    end
    vim.wait(opts.interval or 500)
  until vim.uv.now() >= deadline
  return hits
end

return M
