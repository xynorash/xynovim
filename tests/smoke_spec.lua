-- Harness proof: the full config starts clean in a headless nvim.
local H = require("xynotest.helpers")

describe("startup", function()
  it("prints no messages", function()
    H.eq("", vim.trim(H.messages()))
  end)

  it("sets no error message", function()
    H.eq("", vim.v.errmsg)
  end)

  it("uses the island-dark colourscheme on a dark background", function()
    H.eq("island-dark", vim.g.colors_name)
    H.eq("dark", vim.o.background)
  end)

  it("loaded lazy.nvim with the plugin set", function()
    local stats = require("lazy").stats()
    H.ok(stats.count > 50, "plugin count " .. stats.count)
  end)

  it("has no spec notifications from lazy.nvim", function()
    H.eq({}, require("lazy.core.config").spec.notifs)
  end)

  it("opens a buffer and fires VeryLazy without messages", function()
    H.clear_messages()
    H.open(H.fixture("standalone.rs"))
    H.eq("rust", vim.bo.filetype)
    H.eq("", vim.trim(H.messages()))
  end)
end)
