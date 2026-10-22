-- Clipboard for tmux / ssh / herdr sessions (OSC 52 copy, Wayland paste where there is one), from the
-- xyno-clipboard.nvim plugin. Not lazy: the provider has to exist before the first yank, as the old
-- require("config.remote_clipboard").setup() in options.lua made it. No :XynoClipboardStatus
-- (commands = false): xynovim never had it. The provider is now named XynoClipboard.
return {
  "xynorash/xyno-clipboard.nvim",
  lazy = false,
  config = function()
    require("xyno_clipboard").setup({ commands = false })
    -- the old switch stays honoured at run time: vim.g.xynovim_remote_clipboard_osc52 = false stops the
    -- OSC 52 emit, which the plugin spells vim.g.xyno_clipboard_osc52 = false (the Wayland copy still happens)
    local clip = vim.g.clipboard
    if not clip then
      return
    end
    local function honour_old_switch(copy)
      return function(lines)
        if vim.g.xynovim_remote_clipboard_osc52 ~= false then
          return copy(lines)
        end
        local prev = vim.g.xyno_clipboard_osc52
        vim.g.xyno_clipboard_osc52 = false
        local ok, err = pcall(copy, lines)
        vim.g.xyno_clipboard_osc52 = prev
        if not ok then
          error(err, 0)
        end
      end
    end
    clip.copy = { ["+"] = honour_old_switch(clip.copy["+"]), ["*"] = honour_old_switch(clip.copy["*"]) }
    vim.g.clipboard = clip
  end,
}
