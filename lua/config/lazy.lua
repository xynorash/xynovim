local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    if #vim.api.nvim_list_uis() > 0 then
      vim.fn.getchar()
    end
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

-- vim.loader (lazy's module cache) creates stdpath("cache")/luac; an
-- unwritable XDG_CACHE_HOME raised E739 and init.lua aborted, leaving nvim
-- without any config. Without a writable cache dir run uncached.
local function writable_dir(dir)
  pcall(vim.fn.mkdir, dir, "p")
  return vim.fn.filewritable(dir) == 2
end
local cache_ok = writable_dir(vim.fn.stdpath("cache"))

-- Run xynovim against local clones of the xyno-* plugins instead of the
-- commits pinned in lazy-lock.json:
--   XYNOVIM_DEV_PLUGINS=~/projects/xyno-plugins nvim
-- Every "xynorash/xyno-*" plugin is then loaded from <dir>/<name> (e.g.
-- <dir>/xyno-rust.nvim) and is no longer tracked by the lock file or by
-- :Lazy update/restore. A missing clone falls back to the normal checkout.
-- Unset (the default), nothing changes. See docs/DEV-PLUGINS.md.
local dev_dir = vim.env.XYNOVIM_DEV_PLUGINS
local dev = { path = "~/projects", patterns = {}, fallback = true }
if dev_dir and dev_dir ~= "" then
  dev_dir = vim.fs.normalize(dev_dir)
  if vim.fn.isdirectory(dev_dir) == 1 then
    dev = { path = dev_dir, patterns = { "xynorash/xyno-" }, fallback = true }
  else
    vim.schedule(function()
      vim.notify(
        "XYNOVIM_DEV_PLUGINS is not a directory: " .. dev_dir .. " (using the pinned plugins)",
        vim.log.levels.WARN
      )
    end)
  end
end

-- LazyVim (the pinned commit) still calls vim.lsp.codelens.refresh(), deprecated in Neovim 0.12 (removed in
-- 0.13): every code-lens attach printed a vim.deprecate notice (tests/warnings-guard_spec.lua found it).
-- The replacement is what Neovim's own wrapper forwards to; this runs before LazyVim's spec is read, so
-- its <leader>cC key and the attach autocmd both get the shim. Delete it when LazyVim moves to enable().
do
  local lens = vim.lsp and vim.lsp.codelens
  if lens and type(lens.enable) == "function" then
    lens.refresh = function(opts)
      lens.enable(true, { bufnr = type(opts) == "table" and opts.bufnr or nil })
    end
  end
end

require("lazy").setup({
  dev = dev,
  spec = {
    -- add LazyVim and import its plugins
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    -- import/override with your plugins
    { import = "plugins" },
  },
  defaults = {
    -- By default, only LazyVim plugins will be lazy-loaded. Your custom plugins will load during startup.
    -- If you know what you're doing, you can set this to `true` to have all your custom plugins lazy-loaded by default.
    lazy = false,
    -- It's recommended to leave version=false for now, since a lot the plugin that support versioning,
    -- have outdated releases, which may break your Neovim install.
    version = false, -- always use the latest git commit
    -- version = "*", -- try installing the latest stable version for plugins that support semver
  },
  install = { colorscheme = { "island-dark", "tokyonight", "habamax" } },
  -- No plugin needs luarocks; without this `:checkhealth lazy` reports an
  -- ERROR for the missing hererocks/luarocks.
  rocks = { enabled = false },
  checker = {
    -- OFF: the periodic checker spawns background git fetches AND pulls
    -- lazy's whole management machinery (lazy.manage, view.commands,
    -- runner, task, process - ~6-10ms) into every startup. Update
    -- manually with :Lazy sync instead.
    enabled = false,
    notify = false,
  },
  performance = {
    cache = { enabled = cache_ok },
    rtp = {
      -- disable some rtp plugins
      disabled_plugins = {
        "gzip",
        -- "matchit",
        -- "matchparen",
        -- "netrwPlugin",
        "tarPlugin",
        "tohtml",
        "tutor",
        "zipPlugin",
      },
    },
  },
})
