-- Rainbow brackets (lua/config/rainbow.lua; options and commands in docs/RAINBOW.md). A virtual spec, so
-- nothing is installed: the code is this config's own, loaded at VeryLazy (after the first screen), or on
-- the first :XynoRainbow / key.
return {
  "xynovim/rainbow",
  name = "xynovim-rainbow",
  virtual = true,
  event = "VeryLazy",
  cmd = "XynoRainbow",
  keys = {
    {
      "<leader>uk",
      function()
        local _, on = require("config.rainbow").toggle("enabled")
        vim.notify("rainbow brackets " .. (on and "on" or "off"))
      end,
      desc = "Toggle rainbow brackets",
    },
    {
      "<leader>uj",
      function()
        local ok, msg = require("config.rainbow_scope").at_cursor("scope")
        if not ok then
          vim.notify("rainbow brackets: " .. msg)
        end
      end,
      desc = "Rainbow brackets: highlight scope (Esc clears)",
    },
    {
      "<leader>uJ",
      function()
        local ok, msg = require("config.rainbow_scope").at_cursor("restrain")
        if not ok then
          vim.notify("rainbow brackets: " .. msg)
        end
      end,
      desc = "Rainbow brackets: restrain outside the scope (Esc clears)",
    },
  },
  config = function()
    require("config.rainbow").setup()
  end,
}
