return {
  "ThePrimeagen/harpoon",
  branch = "harpoon2",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {},
  -- add key is <leader>H: <leader>a is the AI (claudecode) prefix.
  -- static keys table with requires deferred into the callbacks: a keys
  -- FUNCTION that requires harpoon at spec-build time force-loads
  -- harpoon+plenary during startup, defeating lazy-loading entirely.
  keys = {
    { "<leader>H", function() require("harpoon"):list():add() end, desc = "Harpoon: Add file" },
    {
      "<C-e>",
      function()
        local harpoon = require("harpoon")
        harpoon.ui:toggle_quick_menu(harpoon:list())
      end,
      desc = "Harpoon: Quick menu",
    },
    { "<M-1>", function() require("harpoon"):list():select(1) end, desc = "Harpoon: Jump to file 1" },
    { "<M-2>", function() require("harpoon"):list():select(2) end, desc = "Harpoon: Jump to file 2" },
    { "<M-3>", function() require("harpoon"):list():select(3) end, desc = "Harpoon: Jump to file 3" },
    { "<M-4>", function() require("harpoon"):list():select(4) end, desc = "Harpoon: Jump to file 4" },
  },
}
