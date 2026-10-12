-- Options are automatically loaded before lazy.nvim startup.
require("config.remote_clipboard").setup()

vim.opt.relativenumber = false
vim.g.autoformat = false

-- Floats (hover, signature help, diagnostics, completion docs) get a rounded
-- border: with a solid NormalFloat and a transparent editor they had no edge.
-- Plugins that set their own border are unaffected.
vim.o.winborder = "rounded"
-- LazyVim blends the popup menu by 10%, which let the buffer text show
-- through the menu rows (right-click menu, wildmenu).
vim.o.pumblend = 0

-- No remote-plugin hosts are in use: skip provider probing entirely
-- (removes startup/health overhead; zero effect on UI or LSP).
vim.g.loaded_python3_provider = 0
vim.g.loaded_ruby_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_node_provider = 0

-- Rust diagnostics via bacon-ls (lua/plugins/bacon-ls.lua): its native cargo
-- backend runs clippy itself on every buffer change (no bacon process) and
-- sends the results as LSP diagnostics. The lang.rust extra reads this and
-- turns off rust-analyzer's checkOnSave and diagnostics so cargo runs once;
-- rustaceanvim.lua switches the native in-memory diagnostics back on.
vim.g.lazyvim_rust_diagnostics = "bacon-ls"

-- Local History: shadow-ref snapshots on every (throttled) save.
require("config.local_history").setup()

-- Auto-save safety: no writes into dependency sources or over files that
-- changed on disk; save everything a multi-file rename touched.
require("config.disk_guard").setup()

-- :RustContext (cargo features / target for both diagnostic tiers).
require("config.rust_context").setup()
require("config.rust_tasks").setup()
require("config.rust_routes").setup()

-- Rust server readiness in the statusline, right-click menu, Neovide,
-- opt-in colourblind palette.
require("config.lsp_status").setup()
require("config.rust_restart").setup()
require("config.ux").setup()
