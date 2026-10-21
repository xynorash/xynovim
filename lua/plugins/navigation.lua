-- Orientation / navigation add-ons (roadmap step 7). The extras for sticky
-- context, breadcrumbs, surround, doc stubs and rename preview are enabled in
-- lazyvim.json; this file tunes them and adds the rest.
return {
  -- Error stripe: diagnostics, git hunks, search hits and marks on the
  -- scrollbar, inspired by the JetBrains right gutter.
  {
    "lewis6991/satellite.nvim",
    event = "VeryLazy",
    opts = {
      current_only = false,
      winblend = 60, -- the theme is transparent
      excluded_filetypes = { "neo-tree", "snacks_dashboard", "snacks_picker_list", "help", "lazy", "mason" },
    },
  },

  -- Persistent call hierarchy (same idea as Ctrl+Alt+H in the JetBrains IDEs): gai/gao are flat lists.
  -- auto_refresh=false: the lsp_* sources refresh on CursorHold/BufEnter, which blanked the tree.
  {
    "folke/trouble.nvim",
    keys = {
      { "<leader>cI", "<cmd>Trouble lsp_incoming_calls toggle focus=true auto_refresh=false<cr>", desc = "Incoming calls (tree)" },
      { "<leader>cO", "<cmd>Trouble lsp_outgoing_calls toggle focus=true auto_refresh=false<cr>", desc = "Outgoing calls (tree)" },
    },
  },

  -- Rust-flavoured surroundings on top of the coding.mini-surround extra
  -- (gsa/gsd/gsr): e.g. `gsaiwS` wraps the word in `Some(...)`.
  {
    "nvim-mini/mini.surround",
    opts = {
      -- Two-step patterns: a balanced match first (a lazy `.-` stopped at the
      -- first `)`: `gsdO` on Ok(vec![f(1), g(2)]) left `vec![f(1, g(2)])`), then
      -- the empty captures mark where the wrapper ends and begins.
      custom_surroundings = {
        S = { input = { "Some%b()", "^Some%(().*()%)$" }, output = { left = "Some(", right = ")" } },
        O = { input = { "Ok%b()", "^Ok%(().*()%)$" }, output = { left = "Ok(", right = ")" } },
        N = { input = { "Box::new%b()", "^Box::new%(().*()%)$" }, output = { left = "Box::new(", right = ")" } },
        D = { input = { "dbg!%b()", "^dbg!%(().*()%)$" }, output = { left = "dbg!(", right = ")" } },
        U = { input = { "unsafe%s*%b{}", "^unsafe%s*{ ?().-() ?}$" }, output = { left = "unsafe { ", right = " }" } },
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
