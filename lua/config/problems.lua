-- Filters for the Trouble diagnostics list (<leader>xx, the project-wide Problems panel) that
-- Trouble's own `s` (exactly one severity, cycling) and `gb` (current buffer) do not give:
--   e   errors only                 w   errors and warnings (hides hints and info)
--   S   cycle through the sources present (rust-analyzer, rustc, clippy, bacon-ls, crates, ...)
--   a   clear the severity and source filters
-- Each is a view action: `view:filter(fn, { id = ... })`, ids "severity" / "source" so a new choice
-- replaces the previous one of its kind, and the header line says what is filtered.
local M = {}

local S = vim.diagnostic.severity

--- The diagnostic behind a Trouble item (items of other sources have none).
local function diag(item)
  return type(item.item) == "table" and item.item or nil
end

--- Whether the item passes "this severity or worse".
function M.at_least(severity)
  return function(item)
    local d = diag(item)
    return d ~= nil and d.severity ~= nil and d.severity <= severity
  end
end

function M.from_source(source)
  return function(item)
    local d = diag(item)
    return d ~= nil and (d.source or "?") == source
  end
end

--- Sorted distinct sources of every diagnostic right now.
function M.sources()
  local seen, out = {}, {}
  for _, d in ipairs(vim.diagnostic.get()) do
    local s = d.source or "?"
    if not seen[s] then
      seen[s] = true
      out[#out + 1] = s
    end
  end
  table.sort(out)
  return out
end

local function severity_action(level, text)
  return function(view)
    local cur = view:get_filter("severity")
    local same = cur and cur.data and cur.data.level == level
    view:filter(M.at_least(level), {
      id = "severity",
      data = { level = level },
      template = "{hl:Title}Filter:{hl} " .. text,
      del = same, -- pressing it again lifts it
    })
  end
end

M.actions = {
  errors = severity_action(S.ERROR, "errors only"),
  warnings = severity_action(S.WARN, "errors and warnings"),
  source = function(view)
    local list = M.sources()
    if #list == 0 then
      return
    end
    local cur = view:get_filter("source")
    local idx = 0
    for i, s in ipairs(list) do
      if cur and cur.data and cur.data.name == s then
        idx = i
      end
    end
    local nxt = list[idx + 1] -- past the last source: back to all
    view:filter(nxt and M.from_source(nxt) or function()
      return true
    end, {
      id = "source",
      data = { name = nxt },
      template = "{hl:Title}Source:{hl} " .. (nxt or "all"),
      del = nxt == nil,
    })
  end,
  clear = function(view)
    view:filter(function()
      return true
    end, { id = "severity", del = true })
    view:filter(function()
      return true
    end, { id = "source", del = true })
  end,
}

--- The `keys` table to merge into Trouble's diagnostics mode.
function M.keys()
  return {
    e = { action = M.actions.errors, desc = "Errors only (again: all)" },
    w = { action = M.actions.warnings, desc = "Errors and warnings (again: all)" },
    S = { action = M.actions.source, desc = "Next source (rust-analyzer, rustc, clippy, ...)" },
    a = { action = M.actions.clear, desc = "Clear severity and source filters" },
  }
end

return M
