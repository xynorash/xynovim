-- Rust project plumbing, from the xyno-rust.nvim plugin: the Cargo context (:RustContext), the targets /
-- tools / routes pickers, :RustRestart and the server supervision, the statusline readiness indicator.
-- Not lazy: the supervision and statusline autocmds have to be there from startup (a rust-analyzer that
-- dies is restarted in every session), and the modules are required by rustaceanvim.lua, bacon-ls.lua,
-- lualine.lua and the crate / import / macro modules. keymaps = false: the <leader>r keys stay in
-- config/keymaps.lua (set when rust-analyzer attaches). No xynovim global fed these modules.
return {
  "xynorash/xyno-rust.nvim",
  lazy = false,
  dependencies = { "folke/snacks.nvim" },
  config = function()
    require("xyno_rust").setup({ commands = true, keymaps = false })
  end,
}
