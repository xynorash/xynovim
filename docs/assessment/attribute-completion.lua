local function out(...) local t={} for i=1,select('#',...) do t[#t+1]=tostring((select(i,...))) end io.stdout:write(table.concat(t," ").."\n") io.stdout:flush() end
vim.cmd("edit src/main.rs"); vim.cmd("doautocmd User VeryLazy")
vim.wait(60000, function() return #vim.lsp.get_clients({bufnr=0,name="rust-analyzer"})>0 end, 200)
local c = vim.lsp.get_clients({bufnr=0,name="rust-analyzer"})[1]
vim.wait(20000)
local main = vim.api.nvim_get_current_buf()
local function req(m,p) local r=c:request_sync(m,p,30000,main); return r and r.result end
local function typed(keys, label)
  vim.cmd("normal! G")
  vim.api.nvim_feedkeys(vim.keycode("o"..keys), "xt", false)  -- stays in insert via 'x' flag? ends insert
  vim.wait(2500)
end
-- type "#[derive(Se" then ask completion at the cursor, then undo
local function probe(label, text)
  vim.cmd("normal! G")
  vim.api.nvim_buf_set_lines(main, -1, -1, false, {text, "struct Zz;"})
  vim.wait(300)
  vim.api.nvim_win_set_cursor(0, {vim.api.nvim_buf_line_count(main)-1, #text})
  vim.cmd("doautocmd TextChangedI") ; vim.wait(2500)
  local r = req("textDocument/completion",{textDocument=vim.lsp.util.make_text_document_params(main),position={line=vim.api.nvim_buf_line_count(main)-2,character=#text},context={triggerKind=1}}) or {}
  local items = r.items or r
  local t={} for i=1,math.min(#items,14) do t[#t+1]=items[i].label end
  out("T:", label, "n="..#items, table.concat(t," | "))
  vim.cmd("silent! undo")
  local n = vim.api.nvim_buf_line_count(main)
  vim.api.nvim_buf_set_lines(main, n-2, n, false, {})
  vim.wait(500)
end
probe("derive(Se", "#[derive(Se")
probe("derive(", "#[derive(")
probe("derive(Debug, C", "#[derive(Debug, C")
probe("cfg(", "#[cfg(")
probe("allow(", "#[allow(")
probe("repr(", "#[repr(")
