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
local function absent()
  LazyVim.treesitter.get_installed(true)
  return vim.tbl_filter(function(lang)
    return not LazyVim.treesitter.have(lang)
  end, want)
end
-- Loading nvim-treesitter makes LazyVim start the same installs itself, in the
-- background. A second, concurrent set makes two tree-sitter builds of one
-- parser fight over its lock file ("appears stale", seen on macOS) and ends this
-- script before the first set is done (seen on Windows): let the running
-- installs finish (no progress for 15 s), then install what is still missing.
local function settle(max_ms)
  local last, since = -1, vim.uv.now()
  vim.wait(max_ms, function()
    local n = #absent()
    if n == 0 then
      return true
    end
    if n ~= last then
      last, since = n, vim.uv.now()
    end
    return vim.uv.now() - since > 15000
  end, 1000)
end
settle(900000)
local missing
for round = 1, 3 do
  missing = absent()
  if #missing == 0 then
    break
  end
  say(("installing %d treesitter parsers (round %d): %s"):format(#missing, round, table.concat(missing, ", ")))
  TS.install(missing, { summary = true }):wait(900000)
  settle(300000)
end
local still = absent()

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
-- A package whose install was aborted or lost a race (seen: codelldb on Linux,
-- "Neovim is exiting while packages are still installing") is retried, waiting
-- on the install handles themselves.
for round = 1, 2 do
  local handles = {}
  for _, name in ipairs(TOOLS) do
    local ok, pkg = pcall(reg.get_package, name)
    if ok and not pkg:is_installed() then
      say(("retrying Mason package %s (round %d)"):format(name, round))
      local started, h = pcall(function()
        return pkg:install()
      end)
      if started and h then
        handles[#handles + 1] = h
      end
    end
  end
  if #handles == 0 then
    break
  end
  vim.wait(600000, function()
    for _, h in ipairs(handles) do
      if not h:is_closed() then
        return false
      end
    end
    return true
  end, 200)
end
say("mason packages: " .. table.concat(reg.get_installed_package_names(), ", "))
for _, name in ipairs(TOOLS) do
  local ok, pkg = pcall(reg.get_package, name)
  if not ok then
    say("Mason has no package " .. name .. " (not provided for this platform)")
  elseif not pkg:is_installed() then
    say("Mason package NOT installed: " .. name .. " (see :MasonLog; a Mason failure only warns)")
  end
end

if #still > 0 then
  say("FAILED, treesitter parsers still missing: " .. table.concat(still, ", "))
  vim.cmd("cquit 1")
end
say("done (" .. #want .. " parsers present)")
