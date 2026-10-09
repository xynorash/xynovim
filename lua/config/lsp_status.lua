-- Server-readiness indicator for the statusline: rust-analyzer (starting /
-- indexing N% / ready, plus its health) and bacon-ls (clippy running / stale
-- / fresh). Purely event driven (LspProgress, experimental/serverStatus,
-- TextChanged) - no timers, nothing runs at idle.
--
-- rustaceanvim handles experimental/serverStatus itself but keeps no state, so
-- the client's handler is wrapped once on attach. bacon-ls reports each clippy
-- run as $/progress; "stale" means the buffer changed after the last finished
-- run started, i.e. the clippy diagnostics on screen predate your edit.
local M = {}

---@type table<integer, { tokens: table<string, table>, last: string?, health: string?, quiescent: boolean?, stale: boolean?, edited: boolean? }>
local state = {}

local function st(id)
  state[id] = state[id] or { tokens = {} }
  return state[id]
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

function M.rust_analyzer(bufnr)
  local c = vim.lsp.get_clients({ bufnr = bufnr or 0, name = "rust-analyzer" })[1]
  if not c then
    return nil
  end
  local s = st(c.id)
  local busy = progress_text(s)
  if s.quiescent == nil then
    return "RA " .. (busy or "starting")
  elseif not s.quiescent or busy then
    return "RA " .. (busy or "loading")
  elseif s.health == "error" then
    return "RA error"
  elseif s.health == "warning" then
    return "RA ready (warn)"
  end
  return "RA ready"
end

function M.bacon(bufnr)
  local c = vim.lsp.get_clients({ bufnr = bufnr or 0, name = "bacon_ls" })[1]
  if not c then
    return nil
  end
  local s = st(c.id)
  if next(s.tokens) then
    return "clippy running"
  elseif s.stale then
    return "clippy stale"
  end
  return "clippy ok"
end

--- Combined lualine string ("" hides the component outside Rust buffers).
function M.component()
  local parts = {}
  for _, f in ipairs({ M.rust_analyzer, M.bacon }) do
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
      if client.name == "bacon_ls" then
        vim.b[ev.buf].xynovim_bacon = client.id
      elseif client.name == "rust-analyzer" and not st(client.id).wrapped then
        local s = st(client.id)
        s.wrapped = true
        local orig = client.handlers["experimental/serverStatus"] or vim.lsp.handlers["experimental/serverStatus"]
        client.handlers["experimental/serverStatus"] = function(err, result, ctx, config)
          if result then
            s.health, s.quiescent = result.health, result.quiescent
            redraw()
          end
          if orig then
            return orig(err, result, ctx, config)
          end
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
        if client.name == "bacon_ls" and not s.edited then
          s.stale = false
        end
      else
        if v.kind == "begin" and client.name == "bacon_ls" then
          s.edited = false
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
      local id = vim.b[ev.buf].xynovim_bacon
      if not id then
        return
      end
      local s = st(id)
      s.edited = true
      if not s.stale then
        s.stale = true
        redraw()
      end
    end,
  })
end

return M
