-- run inside nvim: NR_READY=<file>, NR_DIR=<dir with a copy of the crate>. neotest summary + dap-ui open at once
-- (what a debugging session of a test looks like), then the ready file is written.
vim.g.xynovim_workspace_trust = false
vim.cmd("cd " .. vim.env.NR_DIR .. "/crate")
vim.cmd("edit " .. vim.env.NR_DIR .. "/crate/src/lib.rs")
vim.defer_fn(function()
  vim.cmd("colorscheme island-dark")
  pcall(function()
    require("lazy").load({ plugins = { "nvim-dap", "nvim-dap-ui", "neotest" } })
  end)
  vim.defer_fn(function()
    pcall(function()
      require("neotest").summary.open()
    end)
    pcall(function()
      require("dapui").open({})
    end)
    vim.defer_fn(function()
      local wins = {}
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local b = vim.api.nvim_win_get_buf(w)
        wins[#wins + 1] = ("%s:%d"):format(vim.bo[b].filetype, vim.api.nvim_win_get_width(w))
      end
      local f = io.open(vim.env.NR_READY, "w")
      f:write(("cols=%d wins=%s"):format(vim.o.columns, table.concat(wins, ",")))
      f:close()
    end, 2500)
  end, 2500)
end, 800)
