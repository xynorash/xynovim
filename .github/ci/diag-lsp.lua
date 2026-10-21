-- Diagnostic for the platforms workflow: which language clients attach to a
-- fresh crate, and what the LSP log says when one does not. Prints only.
local dir = vim.fs.joinpath(vim.uv.os_tmpdir(), "xyno-diag-" .. vim.uv.os_getpid())
vim.fn.mkdir(dir .. "/src", "p")
vim.fn.writefile({ '[package]', 'name = "diag"', 'version = "0.1.0"', 'edition = "2021"' }, dir .. "/Cargo.toml")
vim.fn.writefile({ "fn main() {}" }, dir .. "/src/main.rs")
print("exepath bacon-ls: " .. vim.fn.exepath("bacon-ls"))
print("exepath bacon: " .. vim.fn.exepath("bacon"))
print("exepath rust-analyzer: " .. vim.fn.exepath("rust-analyzer"))
vim.cmd.edit(dir .. "/src/main.rs")
vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy" })
vim.wait(90000, function()
  return #vim.lsp.get_clients({ name = "bacon_ls" }) > 0
end, 500)
for _, c in ipairs(vim.lsp.get_clients()) do
  print(("client %s id=%d root=%s cmd=%s initialized=%s"):format(c.name, c.id, tostring(c.root_dir), vim.inspect(c.config.cmd), tostring(c.initialized)))
end
local log = vim.lsp.log.get_filename()
print("lsp log: " .. log)
if vim.uv.fs_stat(log) then
  local lines = vim.fn.readfile(log)
  for i = math.max(1, #lines - 40), #lines do
    print((lines[i]:gsub("\r", "")):sub(1, 300))
  end
end
local m = vim.trim(vim.api.nvim_exec2("messages", { output = true }).output)
print("messages: " .. m)
vim.cmd("qa!")
