local function out(...) local t={} for i=1,select('#',...) do t[#t+1]=tostring((select(i,...))) end io.stdout:write(table.concat(t," ").."\n") io.stdout:flush() end
vim.cmd("edit src/main.rs"); vim.cmd("doautocmd User VeryLazy")
vim.wait(60000, function() return #vim.lsp.get_clients({bufnr=0,name="rust-analyzer"})>0 end, 200)
local c = vim.lsp.get_clients({bufnr=0,name="rust-analyzer"})[1]
vim.wait(20000)
local main = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(main,0,-1,false)
for i, l in ipairs(lines) do if l:find("Ok(())", 1, true) then table.insert(lines, i, "    let _r: u8 = rand::random();"); break end end
vim.api.nvim_buf_set_lines(main,0,-1,false,lines); vim.cmd("silent write")
local function bacon_msgs() local t={} for _,d in ipairs(vim.diagnostic.get(main)) do if d.source=="bacon-ls" then t[#t+1]=d.message:match("^[^\n]*"):sub(1,80) end end return table.concat(t," || ") end
local function ra_msgs() local t={} for _,d in ipairs(vim.diagnostic.get(main)) do if d.source=="rust-analyzer" then t[#t+1]=d.message:match("^[^\n]*"):sub(1,60) end end return table.concat(t," || ") end
local l0 for i,s in ipairs(vim.api.nvim_buf_get_lines(main,0,-1,false)) do if s:find("rand::random",1,true) then l0=i-1 end end
local function hover() local r=c:request_sync("textDocument/hover",{textDocument=vim.lsp.util.make_text_document_params(main),position={line=l0,character=24}},8000,main); local h=r and r.result; return h and (h.contents.value or ""):gsub("%s+"," "):sub(1,60) or "nil" end
vim.wait(25000, function() return bacon_msgs():find("rand") ~= nil end, 500)
out("T: BEFORE adding dep: bacon=", bacon_msgs(), " ra=", ra_msgs(), " hover=", hover())
vim.cmd("edit Cargo.toml")
vim.api.nvim_buf_set_lines(0,-1,-1,false,{'rand = "0.9"'}); vim.cmd("silent write")
local t0=vim.uv.now(); vim.cmd("buffer "..main)
local fired=false
for step=1,40 do
  vim.wait(3000)
  local s=(vim.uv.now()-t0)/1000
  out(string.format("T: t=%3.0fs bacon=[%s] ra=[%s] hover=%s", s, bacon_msgs():sub(1,110), ra_msgs():sub(1,60), hover()))
  if step==20 and not fired then fired=true; out("T: -- doautocmd FocusGained"); vim.cmd("doautocmd FocusGained") end
  if not bacon_msgs():find("rand") and hover():find("rand") then out("T: RECOGNISED at", s); break end
end
