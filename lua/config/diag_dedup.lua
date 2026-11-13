-- De-duplication of diagnostics a language server publishes more than once. bacon-ls (cargo backend)
-- publishes one identical diagnostic per span of a lint: a single `unused imports` warning arrives three
-- times, which drew three glyphs on the line and inflated the statusline count. Two diagnostics are the same
-- when range, severity, code, source and message are equal; the first is kept (order preserved). Anything that
-- differs in one of those stays (two lints of one line, one lint with two ranges).
local M = {}

local function key(d)
  local r = d.range or {}
  local s, e = r.start or {}, r["end"] or {}
  local code = d.code
  if type(code) == "table" then
    code = vim.inspect(code)
  end
  return table.concat({
    s.line or "",
    s.character or "",
    e.line or "",
    e.character or "",
    d.severity or "",
    code ~= nil and tostring(code) or "",
    d.source or "",
    d.message or "",
  }, "\0")
end

--- A copy of the LSP diagnostics list without exact duplicates, and how many were dropped.
---@param diagnostics lsp.Diagnostic[]
---@return lsp.Diagnostic[] kept, integer dropped
function M.dedupe(diagnostics)
  local seen, out = {}, {}
  for _, d in ipairs(diagnostics or {}) do
    local k = key(d)
    if not seen[k] then
      seen[k] = true
      out[#out + 1] = d
    end
  end
  return out, #(diagnostics or {}) - #out
end

--- textDocument/publishDiagnostics handler: the built-in one, fed the de-duplicated list.
function M.publish_handler(err, result, ctx)
  if type(result) == "table" and type(result.diagnostics) == "table" then
    result = vim.tbl_extend("force", result, { diagnostics = (M.dedupe(result.diagnostics)) })
  end
  return vim.lsp.diagnostic.on_publish_diagnostics(err, result, ctx)
end

return M
