-- No inline / ghost-text completion anywhere (deliberate, see README).
-- LazyVim's blink extra turns ghost text on for the selected item in the
-- cmdline menu and when vim.g.ai_cmp is set; force both off.
return {
  "saghen/blink.cmp",
  opts = {
    completion = { ghost_text = { enabled = false } },
    cmdline = { completion = { ghost_text = { enabled = false } } },
  },
}
