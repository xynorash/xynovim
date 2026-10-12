local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

-- Omarchy manages lua/plugins/theme.lua as a symlink into
-- ~/.local/state/omarchy. Island Dark is the permanent theme, so that spec is
-- answered with an empty one (it would pick Omarchy's colorscheme) unless
-- `vim.g.xynovim_follow_omarchy = true` (lua/config/options.lua, which LazyVim
-- loads before the spec files). A dangling symlink (no Omarchy) also yields an
-- empty spec instead of lazy's "Failed to load plugins.theme". lazy reads spec
-- files with loadfile(), so the answer is given there; the function runs at
-- import time, after options.lua.
local theme_link = vim.fn.stdpath("config") .. "/lua/plugins/theme.lua"
if vim.uv.fs_lstat(theme_link) then
  local loadfile = _G.loadfile
  _G.loadfile = function(filename, ...)
    if filename == theme_link then
      local chunk = vim.uv.fs_stat(theme_link) and loadfile(filename, ...)
      return function(...)
        if vim.g.xynovim_follow_omarchy and chunk then
          return chunk(...)
        end
        return {}
      end
    end
    return loadfile(filename, ...)
  end
end

require("lazy").setup({
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
  checker = {
    -- OFF: the periodic checker spawns background git fetches AND pulls
    -- lazy's whole management machinery (lazy.manage, view.commands,
    -- runner, task, process - ~6-10ms) into every startup. Update
    -- manually with :Lazy sync instead.
    enabled = false,
    notify = false,
  },
  performance = {
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
