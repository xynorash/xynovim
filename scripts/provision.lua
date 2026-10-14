-- Downloads what LazyVim would otherwise fetch lazily on the first start:
-- treesitter parsers and Mason packages, and waits until they are there.
-- Run by scripts/bootstrap.sh as
--   nvim --headless "+luafile scripts/provision.lua" +qa
-- Exit code 1 when a treesitter parser is missing afterwards (tests need them);
-- Mason failures only warn (they need the network and the specs skip without).
local function say(msg)
  io.stdout:write("provision: " .. msg .. "\n")
end

require("lazy").load({ plugins = { "nvim-treesitter", "mason.nvim", "nvim-lspconfig", "mason-lspconfig.nvim" } })

-- 1. treesitter parsers (opts.ensure_installed of LazyVim, its extras and ours)
local TS = require("nvim-treesitter")
local want = LazyVim.opts("nvim-treesitter").ensure_installed or {}
LazyVim.treesitter.get_installed(true)
local missing = vim.tbl_filter(function(lang)
  return not LazyVim.treesitter.have(lang)
end, want)
if #missing > 0 then
  say("installing " .. #missing .. " treesitter parsers: " .. table.concat(missing, ", "))
  TS.install(missing, { summary = true }):wait(900000)
end
LazyVim.treesitter.get_installed(true)
local still = vim.tbl_filter(function(lang)
  return not LazyVim.treesitter.have(lang)
end, want)

-- 2. Mason packages (installed by LazyVim's own ensure_installed hooks once the
--    registry is loaded: wait until nothing is installing any more)
local reg = require("mason-registry")
local refreshed = false
reg.refresh(function()
  refreshed = true
end)
vim.wait(120000, function()
  return refreshed
end, 100)
-- Language servers and tools the README promises. LazyVim only installs the
-- server of a filetype when you first open such a file; do it up front so the
-- specs (and a first Rust session) do not wait for downloads.
local TOOLS = { "bacon-ls", "taplo", "yaml-language-server", "marksman", "lua-language-server", "json-lsp", "codelldb", "wgsl-analyzer", "tree-sitter-cli", "shfmt", "stylua", "markdownlint-cli2", "markdown-toc" }
for _, name in ipairs(TOOLS) do
  local ok, pkg = pcall(reg.get_package, name)
  if ok and not pkg:is_installed() and not pkg:is_installing() then
    say("installing Mason package " .. name)
    pkg:install()
  end
end
local quiet_since
vim.wait(900000, function()
  local busy = false
  for _, pkg in ipairs(reg.get_all_packages()) do
    if pkg:is_installing() then
      busy = true
      break
    end
  end
  if busy then
    quiet_since = nil
    return false
  end
  quiet_since = quiet_since or vim.uv.now()
  return vim.uv.now() - quiet_since > 5000 -- no new install started for 5 s
end, 200)
say("mason packages: " .. table.concat(reg.get_installed_package_names(), ", "))

if #still > 0 then
  say("FAILED, treesitter parsers still missing: " .. table.concat(still, ", "))
  vim.cmd("cquit 1")
end
say("done (" .. #want .. " parsers present)")
