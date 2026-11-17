-- Start of the rainbow brackets (lua/config/rainbow.lua), called once from lua/config/options.lua. It is not a
-- lazy.nvim plugin spec on purpose: a spec would count as a plugin that lazy-lock.json has no entry for. What
-- runs at startup is this file only (a command and one autocmd); the engine loads at VeryLazy, after the first
-- screen, or on the first :XynoRainbow.
local M = {}

local booted = false

local function engine()
  local R = require("config.rainbow")
  if not R._state.ready then
    R.setup()
  end
  return R
end

function M.setup()
  if booted then
    return
  end
  booted = true
  vim.api.nvim_create_user_command("XynoRainbow", function(c)
    engine()
    require("config.rainbow_cmd").run(c)
  end, {
    nargs = "*",
    desc = "Rainbow brackets: status, switches, palette, scope",
    complete = function(a, c)
      engine()
      return require("config.rainbow_cmd").complete(a, c)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    pattern = "VeryLazy",
    once = true,
    group = vim.api.nvim_create_augroup("xynovim_rainbow_boot", { clear = true }),
    callback = function()
      engine()
      local function scope(mode)
        return function()
          local ok, msg = require("config.rainbow_scope").at_cursor(mode)
          if not ok then
            vim.notify("rainbow brackets: " .. msg)
          end
        end
      end
      vim.keymap.set("n", "<leader>uk", function()
        local _, on = engine().toggle("enabled")
        vim.notify("rainbow brackets " .. (on and "on" or "off"))
      end, { desc = "Toggle rainbow brackets" })
      vim.keymap.set("n", "<leader>uj", scope("scope"), { desc = "Rainbow brackets: highlight scope (Esc clears)" })
      vim.keymap.set(
        "n",
        "<leader>uJ",
        scope("restrain"),
        { desc = "Rainbow brackets: restrain outside the scope (Esc clears)" }
      )
    end,
  })
end

return M
