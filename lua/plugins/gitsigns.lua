-- Show gitsigns for untracked files too (e.g. a fresh repo with no commits,
-- where every file is untracked and would otherwise get no signs at all).
return {
  "lewis6991/gitsigns.nvim",
  opts = { attach_to_untracked = true },
}
