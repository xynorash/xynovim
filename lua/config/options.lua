-- Options are automatically loaded before lazy.nvim startup.
require("config.remote_clipboard").setup()

-- rustup's proxies (rust-analyzer, cargo) live in ~/.cargo/bin: a start from a desktop launcher or
-- another non-login environment lacks it, and opening a .rs file raised a rustaceanvim error
local win = vim.fn.has("win32") == 1
local sep = win and ";" or ":"
local cargo_home = vim.env.CARGO_HOME
local cargo_bin = vim.fs.joinpath(cargo_home and cargo_home ~= "" and cargo_home or vim.fs.joinpath(vim.uv.os_homedir(), ".cargo"), "bin")
local function norm(p)
  p = vim.fs.normalize(p):gsub("/+$", "")
  return win and p:lower() or p
end
if vim.uv.fs_stat(cargo_bin) then
  local present = false
  for entry in vim.gsplit(vim.env.PATH or "", sep, { plain = true }) do
    if entry ~= "" and norm(entry) == norm(cargo_bin) then
      present = true
      break
    end
  end
  if not present then
    vim.env.PATH = (vim.env.PATH or "") .. sep .. cargo_bin
  end
end

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

-- neotest runs nextest in a pty, so nextest drew its live progress bar and the
-- output panel (<leader>to) held cursor-up/erase-line redraws instead of the
-- failure text. (The bar is also gone from nextest runs in a Snacks terminal.)
vim.env.NEXTEST_HIDE_PROGRESS_BAR = vim.env.NEXTEST_HIDE_PROGRESS_BAR or "1"

-- The lualine breadcrumb is LazyVim's editor.navic one (it shows
-- `impl Shape for Square`): with Trouble's symbols component (the default
-- when this is true) navic's insert is skipped, and Trouble's kind filter
-- drops impl blocks.
vim.g.trouble_lualine = false

-- Rust diagnostics via bacon-ls (lua/plugins/bacon-ls.lua): its native cargo
-- backend runs clippy itself on every buffer change (no bacon process) and
-- sends the results as LSP diagnostics. The lang.rust extra reads this and
-- turns off rust-analyzer's checkOnSave and diagnostics so cargo runs once;
-- rustaceanvim.lua switches the native in-memory diagnostics back on.
vim.g.lazyvim_rust_diagnostics = "bacon-ls"

-- Auto-save safety: no writes into dependency sources or over files that
-- changed on disk; save everything a multi-file rename touched.
require("config.disk_guard").setup()

-- :RustContext (cargo features / target for both diagnostic tiers).
require("config.rust_context").setup()
require("config.rust_tasks").setup()
require("config.rust_routes").setup()
require("config.egui_new").setup()
require("config.rust_new").setup()

-- Rust server readiness in the statusline, right-click menu, Neovide,
-- opt-in colourblind palette.
require("config.lsp_status").setup()
require("config.rust_restart").setup()
require("config.ux").setup()
