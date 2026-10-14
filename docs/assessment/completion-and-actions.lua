local function out(...) local t={} for i=1,select('#',...) do t[#t+1]=tostring((select(i,...))) end io.stdout:write(table.concat(t," ").."\n") io.stdout:flush() end
vim.cmd("edit src/main.rs"); vim.cmd("doautocmd User VeryLazy")
vim.wait(60000, function() return #vim.lsp.get_clients({bufnr=0,name="rust-analyzer"})>0 end, 200)
local c = vim.lsp.get_clients({bufnr=0,name="rust-analyzer"})[1]
vim.wait(25000)
local function req(m, p, t) local r = c:request_sync(m, p, t or 20000, 0); return r and r.result end
local function P(line, col) return {textDocument=vim.lsp.util.make_text_document_params(0), position={line=line,character=col}} end
local base = vim.api.nvim_buf_get_lines(0,0,-1,false)
local function with(extra, fn)
  local lines = vim.deepcopy(base); for _,l in ipairs(extra) do lines[#lines+1]=l end
  vim.api.nvim_buf_set_lines(0,0,-1,false,lines); vim.wait(1500)
  local r = fn(#base)
  vim.api.nvim_buf_set_lines(0,0,-1,false,base); vim.wait(800)
  return r
end
local function names(items, n) local t={} for i=1,math.min(#items,n or 12) do t[#t+1]=items[i].label end return table.concat(t," | ") end
local function compl(label, extra, dl, col)
  with(extra, function(n)
    local r = req("textDocument/completion", P(n+dl, col))
    local items = r and (r.items or r) or {}
    out("COMPL", label, "n="..#items, names(items))
  end)
end
compl("derive(", {"#[derive(", "struct Z;"}, 0, 9)
compl("derive(Se", {"#[derive(Se", "struct Z;"}, 0, 11)
compl("serde(  field attr", {"struct W {", "    #[serde(", "    f: u8,", "}"}, 1, 11)
compl("serde(  container attr", {"#[serde(", "struct Z;"}, 0, 8)
compl("arg(  clap field attr", {"struct W {", "    #[arg(", "    f: u8,", "}"}, 1, 10)
compl("command(  clap container", {"#[command(", "struct Z;"}, 0, 10)
compl("error(  thiserror", {"enum E {", "    #[error(", "    A,", "}"}, 1, 11)
compl("tokio::main(", {"#[tokio::main(", "async fn m() {}"}, 0, 14)
compl("fn body  serde_json::", {"fn m() {", "    serde_json::", "}"}, 1, 16)
compl("fn body  HashM  (autoimport)", {"fn m() {", "    let _x = HashM", "}"}, 1, 18)
compl("fn body  Dese  (autoimport external)", {"fn m() {", "    let _x: Dese", "}"}, 1, 16)
-- code actions for unresolved names
local function actions(label, extra, dl, col, endcol)
  with(extra, function(n)
    local ln = n+dl
    local ctx = {diagnostics = vim.diagnostic.get(0, {lnum = ln}), only = nil}
    local rng = {start={line=ln,character=col}, ["end"]={line=ln,character=endcol}}
    local r = req("textDocument/codeAction", {textDocument=vim.lsp.util.make_text_document_params(0), range=rng, context=ctx}) or {}
    local t={} for _,a in ipairs(r) do t[#t+1]=a.title end
    out("ACT", label, "n="..#r, table.concat(t," | "):sub(1,400))
  end)
end
actions("HashMap unresolved", {"fn m() {", "    let _x: HashMap<u8,u8> = HashMap::new();", "}"}, 1, 12, 19)
actions("Error unresolved", {"fn m() {", "    let _x: Option<Error> = None;", "}"}, 1, 19, 24)
actions("Rng (rand not a dep)", {"fn m() {", "    let _x = rand::random::<u8>();", "}"}, 1, 13, 17)
actions("derive Hash missing", {"#[derive(Debug, Hash)]", "struct Z;"}, 0, 17, 21)
