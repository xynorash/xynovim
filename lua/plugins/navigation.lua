-- Orientation / navigation add-ons (roadmap step 7). The extras for sticky
-- context, breadcrumbs, surround, doc stubs and rename preview are enabled in
-- lazyvim.json; this file tunes them and adds the rest.
return {
  -- Error stripe: diagnostics, git hunks, search hits and marks on the
  -- scrollbar, like RustRover's right gutter.
  {
    "lewis6991/satellite.nvim",
    event = "VeryLazy",
    opts = {
      current_only = false,
      winblend = 60, -- the theme is transparent
      excluded_filetypes = { "neo-tree", "snacks_dashboard", "snacks_picker_list", "help", "lazy", "mason" },
    },
  },

  -- Persistent call hierarchy (RustRover Ctrl+Alt+H): gai/gao are flat lists.
  {
    "folke/trouble.nvim",
    keys = {
      { "<leader>cI", "<cmd>Trouble lsp_incoming_calls toggle focus=true<cr>", desc = "Incoming calls (tree)" },
      { "<leader>cO", "<cmd>Trouble lsp_outgoing_calls toggle focus=true<cr>", desc = "Outgoing calls (tree)" },
    },
  },

  -- Rust-flavoured surroundings on top of the coding.mini-surround extra
  -- (gsa/gsd/gsr): e.g. `gsaiwS` wraps the word in `Some(...)`.
  {
    "nvim-mini/mini.surround",
    opts = {
      custom_surroundings = {
        S = { input = { "Some%(().-()%)" }, output = { left = "Some(", right = ")" } },
        O = { input = { "Ok%(().-()%)" }, output = { left = "Ok(", right = ")" } },
        N = { input = { "Box::new%(().-()%)" }, output = { left = "Box::new(", right = ")" } },
        D = { input = { "dbg!%(().-()%)" }, output = { left = "dbg!(", right = ")" } },
        U = { input = { "unsafe { ().-() }" }, output = { left = "unsafe { ", right = " }" } },
      },
    },
  },

  -- Syntax-aware split/join of argument lists, struct literals, match arms...
  {
    "Wansmer/treesj",
    dependencies = { "nvim-treesitter/nvim-treesitter" },
    keys = { { "<leader>cj", "<cmd>TSJToggle<cr>", desc = "Split/join (treesitter)" } },
    opts = { use_default_keymaps = false, max_join_length = 160 },
  },
}
