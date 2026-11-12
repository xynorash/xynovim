-- run inside nvim: RB_SCENE=off|on|light|cb|scope|restrain|vars|mismatch|high, RB_READY=<file>
local scene = vim.env.RB_SCENE or "on"
vim.g.xynovim_workspace_trust = false
local file = (scene == "mismatch") and vim.env.RB_DIR .. "/mismatch.rs" or vim.env.RB_DIR .. "/demo.rs"
vim.cmd("edit " .. file)
vim.o.cursorline = true
vim.defer_fn(function()
  require("lazy").load({ plugins = { "xynovim-rainbow" } })
  local R = require("config.rainbow")
  if scene == "light" or scene == "lightcb" then
    vim.cmd("colorscheme island-light")
  elseif scene == "high" then
    vim.g.xynovim_contrast = "high"
    vim.cmd("colorscheme island-dark")
  else
    vim.cmd("colorscheme island-dark")
  end
  if scene == "off" then
    R.set("enabled", false)
  elseif scene == "cb" or scene == "lightcb" then
    R.set("palette", "colorblind")
  elseif scene == "vars" then
    R.set("variables.enabled", true)
  end
  vim.cmd("redraw!")
  vim.defer_fn(function()
    if scene == "scope" or scene == "restrain" then
      local lnum = vim.fn.search("(a + b)", "nw")
      vim.api.nvim_win_set_cursor(0, { lnum, vim.fn.stridx(vim.fn.getline(lnum), "a + b") })
      require("config.rainbow_scope").at_cursor(scene)
    elseif scene == "mismatch" then
      vim.api.nvim_win_set_cursor(0, { 6, 0 })
    else
      vim.api.nvim_win_set_cursor(0, { 14, 0 })
    end
    vim.cmd("redraw!")
    vim.defer_fn(function()
      pcall(function() vim.cmd("LspStop") end)
      pcall(function() Snacks.notifier.hide() end)
      pcall(function() require("noice").cmd("dismiss") end)
      vim.cmd("redraw!")
      vim.defer_fn(function()
        vim.fn.writefile({ ("ready %dx%d"):format(vim.o.columns, vim.o.lines) }, vim.env.RB_READY)
      end, 700)
    end, 1500)
  end, 2500)
end, 600)
