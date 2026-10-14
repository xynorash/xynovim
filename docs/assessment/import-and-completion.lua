local function out(...) local t={} for i=1,select('#',...) do t[#t+1]=tostring((select(i,...))) end io.stdout:write(table.concat(t," ").."\n") io.stdout:flush() end
vim.cmd("edit src/main.rs"); vim.cmd("doautocmd User VeryLazy")
vim.wait(60000, function() return #vim.lsp.get_clients({bufnr=0,name="rust-analyzer"})>0 end, 200)
local c = vim.lsp.get_clients({bufnr=0,name="rust-analyzer"})[1]
vim.wait(25000)
local function req(m, p, t) local r = c:request_sync(m, p, t or 30000, 0); return r and r.result, r and r.err end
local function P(line, col) return {textDocument=vim.lsp.util.make_text_document_params(0), position={line=line,character=col}} end
local base = vim.api.nvim_buf_get_lines(0,0,-1,false)
local function with(extra, fn)
  local lines = vim.deepcopy(base); for _,l in ipairs(extra) do lines[#lines+1]=l end
  vim.api.nvim_buf_set_lines(0,0,-1,false,lines); vim.wait(3000)
  local r = fn(#base)
  vim.api.nvim_buf_set_lines(0,0,-1,false,base); vim.wait(800)
  return r
end
-- A. code actions on an unresolved ident, zero-width range, plenty of wait
for _, case in ipairs({
  {"HashMap::new()", {"fn m() {", "    let _x = HashMap::new();", "}"}, 1, 14},
  {"Error::new", {"fn m() {", "    let _e = Error::new(1);", "}"}, 1, 14},
  {"Serialize in derive (use removed)", {"mod q {", "    #[derive(Serialize)]", "    struct S;", "}"}, 1, 14},
}) do
  with(case[2], function(n)
    local ln = n + case[3]
    local r = req("textDocument/codeAction", {textDocument=vim.lsp.util.make_text_document_params(0),
      range={start={line=ln,character=case[4]},["end"]={line=ln,character=case[4]}}, context={diagnostics={}}}) or {}
    local t={} for _,a in ipairs(r) do t[#t+1]=(a.kind or "?")..":"..a.title end
    out("ACT", case[1], "n="..#r, table.concat(t," | "):sub(1,500))
  end)
end
-- B. completion item carries auto-import edits? resolve HashMap
with({"fn m() {", "    let _x = HashM", "}"}, function(n)
  local r = req("textDocument/completion", P(n+1, 18)) or {}
  local items = r.items or r
  for _, it in ipairs(items) do
    if it.label == "HashMap" then
      local res = req("completionItem/resolve", it)
      local edits = res and res.additionalTextEdits
      out("COMPL-RESOLVE HashMap detail="..tostring(it.detail).." edits="..(edits and vim.inspect(edits[1] and edits[1].newText) or "none"))
      break
    end
  end
  -- derive( completion raw
end)
with({"#[derive(", "struct Z;"}, function(n)
  local r = req("textDocument/completion", P(n, 9)) or {}
  local items = r.items or r
  local t={} for i=1,math.min(#items,15) do t[#t+1]=items[i].label end
  out("COMPL derive( n="..#items.." "..table.concat(t," | "))
end)
with({"#[derive(Ser", "struct Z;"}, function(n)
  local r = req("textDocument/completion", P(n, 12)) or {}
  local items = r.items or r
  local t={} for i=1,math.min(#items,15) do t[#t+1]=items[i].label end
  out("COMPL derive(Ser n="..#items.." "..table.concat(t," | "))
  for _, it in ipairs(items) do if it.label == "Serialize" then local res = req("completionItem/resolve", it); out("COMPL-RESOLVE Serialize edits="..(res and res.additionalTextEdits and vim.inspect(res.additionalTextEdits[1].newText) or "none")) break end end
end)
