-- Visual diff / merge-conflict / file-history UI (RustRover's Git tool
-- windows). Merge conflicts: :DiffviewOpen during a merge opens the 3-way
-- view; <leader>co / ct / cb / ca pick ours / theirs / base / all in a hunk.
return {
  "sindrets/diffview.nvim",
  cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory", "DiffviewToggleFiles" },
  keys = {
    { "<leader>gv", "<cmd>DiffviewOpen<cr>", desc = "Diffview: working tree / conflicts" },
    {
      "<leader>gV",
      function()
        -- origin/HEAD only exists after a clone (or `git remote set-head`)
        local root = vim.fs.root(0, ".git") or vim.uv.cwd()
        for _, base in ipairs({ "origin/HEAD", "origin/main", "origin/master" }) do
          vim.fn.system({ "git", "-C", root, "rev-parse", "-q", "--verify", base })
          if vim.v.shell_error == 0 then
            return vim.cmd("DiffviewOpen " .. base .. "...HEAD")
          end
        end
        vim.notify(
          "no origin/HEAD, origin/main or origin/master here (git remote set-head origin -a sets it)",
          vim.log.levels.WARN
        )
      end,
      desc = "Diffview: branch vs origin",
    },
    { "<leader>gF", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: file history" },
    { "<leader>gF", ":DiffviewFileHistory<cr>", mode = "x", desc = "Diffview: selection history" },
    { "<leader>gq", "<cmd>DiffviewClose<cr>", desc = "Diffview: close" },
  },
  opts = {
    enhanced_diff_hl = true,
    view = { merge_tool = { layout = "diff3_mixed" } },
  },
}
