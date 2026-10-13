-- Editing and UI details from the field test: diagnostic virtual text, the
-- snippet source, Cargo.toml schema, which-key group names.
return {
  -- Virtual text: the first line plus [source] (config.ux.diagnostic_text);
  -- bacon-ls sends the whole rendered clippy message (about 14 lines).
  {
    "neovim/nvim-lspconfig",
    opts = {
      diagnostics = {
        -- LazyVim's default is false: rust-analyzer's instant tier only showed
        -- after <Esc>
        update_in_insert = true,
        virtual_text = {
          -- the source is part of the format ("if_many" put it in front)
          source = false,
          format = function(d)
            return require("config.ux").diagnostic_text(d)
          end,
        },
      },
      servers = {
        taplo = {
          -- Cargo.toml itself is a root (a lone crate without .git used to
          -- give no root: "this document has been excluded").
          root_markers = { ".taplo.toml", "taplo.toml", "Cargo.toml", ".git" },
          -- not for Cargo.lock (also filetype toml): taplo answered "this document
          -- has been excluded" there
          root_dir = function(bufnr, on_dir)
            if vim.fs.basename(vim.api.nvim_buf_get_name(bufnr)) == "Cargo.lock" then
              return
            end
            local root = vim.fs.root(bufnr, { ".taplo.toml", "taplo.toml", "Cargo.toml", ".git" })
            if root then
              on_dir(root)
            end
          end,
          settings = {
            evenBetterToml = {
              schema = {
                -- taplo 0.10.0 cannot parse the current SchemaStore catalog,
                -- and its default catalog URL is a 404. The "failed to fetch
                -- catalog" line in lsp.log stays: taplo fetches at initialize,
                -- before it reads these settings (init_options did not
                -- reach it). The one schema that matters is associated by
                -- hand: key completion, hover and `edtion = ...` errors.
                associations = {
                  ["^(.*/)?Cargo\\.toml$"] = "https://json.schemastore.org/cargo.json",
                },
              },
            },
          },
        },
      },
    },
  },

  -- Snippets: never after `.` (friendly-snippets' `if` outranked
  -- rust-analyzer's `.if` postfix and expanded to `ok.if condition {`) and
  -- never inside strings or comments.
  {
    "saghen/blink.cmp",
    opts = {
      sources = {
        providers = {
          snippets = {
            should_show_items = function(ctx)
              return require("config.ux").snippets_allowed(ctx)
            end,
          },
        },
      },
    },
  },

  {
    "folke/noice.nvim",
    opts = function(_, opts)
      -- noice renders hover and signature help itself, so winborder does not
      -- reach them; this preset gives those floats the rounded border too.
      opts.presets = opts.presets or {}
      opts.presets.lsp_doc_border = true

      -- The statusline "showcmd" component (pending keys) never cleared:
      -- noice drops an empty msg_showmode but only stores an empty
      -- msg_showcmd, and the status API reads the history, so the last
      -- pending key stayed in the statusline. Remove it like showmode does.
      local Msg = require("noice.ui.msg")
      if not Msg.xynovim_showcmd then
        Msg.xynovim_showcmd = true
        local on_showcmd = Msg.on_showcmd
        Msg.on_showcmd = function(event, content)
          on_showcmd(event, content)
          if vim.tbl_isempty(content) then
            require("noice.message.manager").remove(Msg.get(event))
          end
        end
      end
    end,
  },

  -- Dashboard: the stock layout (6 header lines, a blank line between the 10
  -- entries) needs 36 rows; at 80x24 the last entries and the footer were
  -- cut off. On a short window the entries sit on consecutive lines.
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      local function tall()
        return vim.o.lines >= 36
      end
      opts.dashboard = opts.dashboard or {}
      opts.dashboard.sections = {
        { section = "header" },
        { section = "keys", gap = 1, padding = 1, enabled = tall },
        {
          section = "keys",
          gap = 0,
          padding = 1,
          enabled = function()
            return not tall()
          end,
        },
        { section = "startup" },
      }
      -- Pickers: below 120 columns snacks uses its `vertical` layout, which asks for
      -- min_height = 30 and puts the preview in the lower 40%; at 80x24 the preview's
      -- last line overdrew the border row. A short window gets the preview-less
      -- `select` layout instead (snacks' `<A-p>` toggles the preview).
      opts.picker = opts.picker or {}
      opts.picker.layout = vim.tbl_deep_extend("force", opts.picker.layout or {}, {
        preset = function()
          if vim.o.columns >= 120 then
            return "default"
          end
          return vim.o.lines < 30 and "select" or "vertical"
        end,
      })
    end,
  },

  -- <leader>9 is the 99 agent (ninety-nine.lua); it had no group name.
  -- <leader>t (neotest) and <leader>a (claudecode) are groups only through
  -- lazy.nvim key stubs: typed fast (`Space t` in one send-keys, also with 0.1 to
  -- 0.2s gaps) no popup appeared in the field test, although the mappings fired.
  {
    "folke/which-key.nvim",
    opts = {
      spec = {
        { "<leader>9", group = "99 (agent)" },
        { "<leader>t", group = "test" },
        { "<leader>a", group = "ai" },
      },
    },
  },
}
