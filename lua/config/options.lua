-- Options are automatically loaded before lazy.nvim startup.
require("config.remote_clipboard").setup()

vim.opt.relativenumber = false
vim.g.autoformat = false

-- No remote-plugin hosts are in use: skip provider probing entirely
-- (removes startup/health overhead; zero effect on UI or LSP).
vim.g.loaded_python3_provider = 0
vim.g.loaded_ruby_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_node_provider = 0

-- Rust diagnostics via bacon-ls: bacon watches the filesystem and re-runs
-- clippy on every (auto)save, bacon-ls streams the results in as LSP
-- diagnostics. The lang.rust extra reads this and disables rust-analyzer's
-- own checkOnSave/diagnostics so nothing is reported twice.
vim.g.lazyvim_rust_diagnostics = "bacon-ls"

-- Local History: shadow-ref snapshots on every (throttled) save.
require("config.local_history").setup()
