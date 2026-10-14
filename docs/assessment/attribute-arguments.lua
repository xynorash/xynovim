local function out(...) local t={} for i=1,select('#',...) do t[#t+1]=tostring((select(i,...))) end io.stdout:write(table.concat(t," ").."\n") io.stdout:flush() end
vim.cmd("edit src/main.rs"); vim.cmd("doautocmd User VeryLazy")
vim.wait(60000, function() return #vim.lsp.get_clients({bufnr=0,name="rust-analyzer"})>0 end, 200)
local c = vim.lsp.get_clients({bufnr=0,name="rust-analyzer"})[1]
vim.wait(20000)
local main = vim.api.nvim_get_current_buf()
local orig = vim.api.nvim_buf_get_lines(main,0,-1,false)
local function req(m,p) local r=c:request_sync(m,p,30000,main); return r and r.result end
local function try(label, lnum_pat, newline, col)
  local lines = vim.deepcopy(orig)
  local ln
  for i,l in ipairs(lines) do if l:find(lnum_pat,1,true) then ln=i-1 lines[i]=newline break end end
  vim.api.nvim_buf_set_lines(main,0,-1,false,lines); vim.wait(2500)
  local r = req("textDocument/completion",{textDocument=vim.lsp.util.make_text_document_params(main),position={line=ln,character=col},context={triggerKind=1}}) or {}
  local items = r.items or r
  local t={} for i=1,math.min(#items,16) do t[#t+1]=items[i].label end
  out("T:", label, "n="..#items, table.concat(t," | "))
  vim.api.nvim_buf_set_lines(main,0,-1,false,orig); vim.wait(800)
end
try("derive(Debug, S|)", "#[derive(Debug, Serialize", "#[derive(Debug, S)]", 18)
try("derive(Debug, |)", "#[derive(Debug, Serialize", "#[derive(Debug, )]", 17)
try("derive(Error) -> #[error(|", "    #[error(", '    #[error(', 12)
try("serde(rename_all = \"|\")", "#[serde(rename_all", '#[serde(rename_all = "")]', 22)
try("serde(|) on struct", "#[serde(rename_all", '#[serde()]', 8)
try("arg(|) on field", "    #[arg(short", '    #[arg()]', 9)
try("command(|)", "#[command(version)]", '#[command()]', 10)
