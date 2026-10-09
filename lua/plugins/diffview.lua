-- Visual diff / merge-conflict / file-history UI (RustRover's Git tool
-- windows). Merge conflicts: :DiffviewOpen during a merge opens the 3-way
-- view; <leader>co / ct / cb / ca pick ours / theirs / base / all in a hunk.
return {
  "sindrets/diffview.nvim",
  cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory", "DiffviewToggleFiles" },
  keys = {
    { "<leader>gv", "<cmd>DiffviewOpen<cr>", desc = "Diffview: working tree / conflicts" },
    { "<leader>gV", "<cmd>DiffviewOpen origin/HEAD...HEAD<cr>", desc = "Diffview: branch vs origin" },
    { "<leader>gF", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: file history" },
    { "<leader>gF", ":DiffviewFileHistory<cr>", mode = "x", desc = "Diffview: selection history" },
    { "<leader>gq", "<cmd>DiffviewClose<cr>", desc = "Diffview: close" },
  },
  opts = {
    enhanced_diff_hl = true,
    view = { merge_tool = { layout = "diff3_mixed" } },
  },
}
