-- Branding and the icon fallback (docs/comparison/ui-community.md items 9 and 12): the dashboard
-- header is xynovim's own (no LazyVim banner), and with vim.g.xynovim_icons = "ascii" (or
-- $XYNOVIM_ICONS=ascii, or "auto" on a console that cannot draw glyphs) the dashboard, the
-- bufferline, the file tree and the statusline separators use plain text.
local ui = function()
  return require("config.ui")
end

local HEADER = [[
                         ▀
▀▄▄▀ █  █ █▀▀▄ ▄▀▀▄ █  █ █ █▀█▀▄
▄▀▀▄  ▀▀█ █  █ ▀▄▄▀ ▀▄▄▀ █ █ █ █
      ▀▀
  Rust in Neovim, sandboxed by default]]

local HEADER_ASCII = [[
 x y n o v i m
 Rust in Neovim, sandboxed by default]]

return {
  {
    "LazyVim/LazyVim",
    opts = function()
      ui().apply_icons()
    end,
  },

  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      opts.dashboard = opts.dashboard or {}
      opts.dashboard.preset = opts.dashboard.preset or {}
      local ascii = ui().ascii_active()
      opts.dashboard.preset.header = ascii and HEADER_ASCII or HEADER
      if ascii then
        for _, key in ipairs(opts.dashboard.preset.keys or {}) do
          key.icon = "> "
        end
        opts.dashboard.formats = opts.dashboard.formats or {}
      end
    end,
  },

  {
    "akinsho/bufferline.nvim",
    opts = function(_, opts)
      if ui().ascii_active() then
        opts.options = opts.options or {}
        local o = opts.options
        o.show_buffer_icons = false
        o.show_buffer_close_icons = false
        o.show_close_icon = false
        o.modified_icon = "+"
        o.left_trunc_marker = "<"
        o.right_trunc_marker = ">"
        o.separator_style = "thin"
        o.get_element_icon = nil
      end
    end,
  },

  {
    "nvim-neo-tree/neo-tree.nvim",
    opts = function(_, opts)
      if ui().ascii_active() then
        opts.default_component_configs = vim.tbl_deep_extend("force", opts.default_component_configs or {}, {
          icon = { folder_closed = "+", folder_open = "-", folder_empty = "o", folder_empty_open = "o", default = "*" },
          modified = { symbol = "[+]" },
          indent = { with_expanders = true, expander_collapsed = ">", expander_expanded = "v" },
          git_status = {
            symbols = {
              added = "A",
              modified = "M",
              deleted = "D",
              renamed = "R",
              untracked = "?",
              ignored = "!",
              unstaged = "U",
              staged = "S",
              conflict = "C",
            },
          },
        })
      end
    end,
  },
}
