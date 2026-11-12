-- Branding and the icon fallback (docs/comparison/ui-community.md items 9 and 12): the dashboard
-- header is xynovim's own (no LazyVim banner), and with vim.g.xynovim_icons = "ascii" (or
-- $XYNOVIM_ICONS=ascii, or "auto" on a console that cannot draw glyphs) the dashboard, the
-- bufferline, the file tree, the file icons (mini.icons), dap-ui and the statusline separators use plain text;
-- `:XynoIcons` rebuilds them at run time (config/ui_chrome.lua).
local ui = function()
  return require("config.ui")
end

local HEADER = [[
                         ▀
▀▄▄▀ █  █ █▀▀▄ ▄▀▀▄ █  █ █ █▀█▀▄
▄▀▀▄  ▀▀█ █  █ ▀▄▄▀ ▀▄▄▀ █ █ █ █
      ▀▀
  Rust in Neovim, AI agent sandboxed]]

local HEADER_ASCII = [[
 x y n o v i m
 Rust in Neovim, AI agent sandboxed]]

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
      -- snacks' own sections (header, keys, startup) with the startup line's "⚡ " dropped in ascii mode
      opts.dashboard.sections = {
        { section = "header" },
        { section = "keys", gap = 1, padding = 1 },
        { section = "startup", icon = ascii and "" or "⚡ " },
      }
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
      else
        -- bufferline keeps the options of an earlier setup(): say the defaults again when switching back
        opts.options = opts.options or {}
        local o = opts.options
        o.show_buffer_icons = true
        o.show_buffer_close_icons = true
        o.show_close_icon = true
        o.modified_icon = "●"
        o.left_trunc_marker = "\xef\x82\xa8" -- bufferline's defaults (U+F0A8, U+F0A9)
        o.right_trunc_marker = "\xef\x82\xa9"
      end
    end,
  },

  -- mini.icons draws every file icon (nvim-web-devicons is its mock): its style must be set when it loads
  {
    "nvim-mini/mini.icons",
    opts = function(_, opts)
      if ui().ascii_active() then
        opts.style = "ascii"
      end
    end,
  },

  {
    "rcarriga/nvim-dap-ui",
    opts = function(_, opts)
      if ui().ascii_active() then
        opts.icons = { expanded = "v", collapsed = ">", current_frame = ">" }
        opts.controls = opts.controls or {}
        opts.controls.icons = {
          pause = "||",
          play = ">",
          step_into = "v",
          step_over = ">>",
          step_out = "^",
          step_back = "<",
          run_last = "@",
          terminate = "x",
          disconnect = "-",
        }
      end
    end,
  },

  {
    "nvim-neo-tree/neo-tree.nvim",
    opts = function(_, opts)
      -- icons that follow the icon mode when they are drawn (:XynoIcons without a restart)
      opts.default_component_configs = vim.tbl_deep_extend("force", opts.default_component_configs or {}, {
        icon = {
          provider = function(icon, node)
            return require("config.ui_chrome").tree_icon(icon, node)
          end,
        },
      })
      -- a file or folder with an error in it is drawn in the error colour (ui-community #14)
      opts.filesystem = opts.filesystem or {}
      opts.filesystem.components = vim.tbl_extend("force", opts.filesystem.components or {}, {
        name = function(config, node, state)
          return require("config.ui_chrome").tree_name(config, node, state)
        end,
      })
      if ui().ascii_active() then
        local sym = require("config.ui").SEVERITY_GLYPHS.ascii
        opts.default_component_configs = vim.tbl_deep_extend("force", opts.default_component_configs or {}, {
          diagnostics = { symbols = { error = sym[1], warn = sym[2], info = sym[3], hint = sym[4] } },
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
