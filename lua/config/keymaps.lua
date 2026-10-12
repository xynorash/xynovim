-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- rust-analyzer commands that rustaceanvim exposes but nothing bound.
-- Buffer-local, set on rust-analyzer attach (scheduled so we also win over
-- the lang.rust extra's own on_attach maps). <leader>r is free: the
-- editor.refactoring extra is not enabled.
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("xynovim_rust_keymaps", { clear = true }),
  callback = function(ev)
    local client = vim.lsp.get_client_by_id(ev.data.client_id)
    if not (client and client.name == "rust-analyzer") then
      return
    end
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(ev.buf) then
        return
      end
      local function map(mode, lhs, rhs, desc)
        vim.keymap.set(mode, lhs, rhs, { buffer = ev.buf, desc = desc })
      end
      local function rust(cmd)
        return function()
          vim.cmd.RustLsp(cmd)
        end
      end
      -- Apply a rust-analyzer assist by title (first match), no menu.
      local function assist(pattern)
        return function()
          vim.lsp.buf.code_action({
            apply = true,
            filter = function(a)
              return a.title:find(pattern) ~= nil
            end,
          })
        end
      end

      -- Refactor
      map({ "n", "x" }, "<leader>ra", function()
        vim.lsp.buf.code_action({ context = { only = { "refactor" }, diagnostics = {} } })
      end, "Refactor actions")
      map({ "n", "x" }, "<leader>rv", assist("^Extract into variable"), "Extract variable")
      map({ "n", "x" }, "<leader>rf", assist("^Extract into function"), "Extract function")
      map({ "n", "x" }, "<leader>rc", assist("^Extract into constant"), "Extract constant")
      map({ "n", "x" }, "<leader>rM", assist("^Extract [Mm]odule"), "Extract module")
      -- "Inline macro" (cursor on println!) expanded silently: not matched.
      map({ "n", "x" }, "<leader>ri", assist("^Inline [^m]"), "Inline")
      -- Own prompt (rustaceanvim's reads the query before Snacks answers).
      map("n", "<leader>rs", function()
        require("config.rust_assist").ssr()
      end, "Structural search & replace")
      map("x", "<leader>rs", function()
        require("config.rust_assist").ssr(true)
      end, "Structural search & replace (selection)")
      map("n", "<leader>rj", rust("joinLines"), "Join lines (semantic)")
      map("x", "<leader>rj", ":RustLsp joinLines<CR>", "Join lines (semantic)")
      map("n", "<A-j>", function()
        vim.cmd.RustLsp({ "moveItem", "down" })
      end, "Move item down")
      map("n", "<A-k>", function()
        vim.cmd.RustLsp({ "moveItem", "up" })
      end, "Move item up")

      -- Inspect
      map("n", "<leader>rm", rust("expandMacro"), "Expand macro (recursive)")
      map("n", "<leader>rh", function()
        vim.cmd.RustLsp({ "view", "hir" })
      end, "View HIR")
      map("n", "<leader>rH", function()
        vim.cmd.RustLsp({ "view", "mir" })
      end, "View MIR")
      map("n", "<leader>rS", function()
        require("config.rust_assist").syntax_tree()
      end, "Syntax tree")
      map("n", "<leader>rp", rust("parentModule"), "Parent module")
      map("n", "<leader>rt", rust("relatedTests"), "Related tests")
      map("n", "<leader>rC", rust("openCargo"), "Open Cargo.toml")
      map("n", "<leader>rd", function()
        require("config.rust_assist").open_docs()
      end, "Open docs.rs")
      map("n", "<leader>rE", function()
        require("config.rust_assist").open_docs()
      end, "External docs")
      map("x", "<leader>rk", function()
        vim.cmd.RustLsp({ "hover", "range" })
      end, "Hover range (type of selection)")

      -- Explain the E-code of any diagnostic on the line (rustc --explain)
      map("n", "<leader>re", function()
        require("config.rust_assist").explain_error()
      end, "Explain error code")

      -- Symbols: workspace only vs. including dependencies
      map("n", "<leader>rw", function()
        require("config.rust_assist").workspace_symbol()
      end, "Workspace symbol")
      map("n", "<leader>rW", function()
        require("config.rust_assist").workspace_symbol(true)
      end, "Workspace symbol (+ dependencies, all kinds)")

      -- neotest cannot run doctests (nextest): plain cargo test --doc
      map("n", "<leader>tD", function()
        require("config.rust_tasks").doctests()
      end, "Doctests (cargo test --doc)")

      -- Flip references.excludeTests live (rust-analyzer re-pulls config on
      -- didChangeConfiguration, answered from client.settings).
      map("n", "<leader>rT", function()
        local c = vim.lsp.get_clients({ bufnr = ev.buf, name = "rust-analyzer" })[1]
        if not c then
          return
        end
        local refs = c.settings["rust-analyzer"].references
        refs.excludeTests = not refs.excludeTests
        c:notify("workspace/didChangeConfiguration", { settings = c.settings })
        vim.notify("find usages: tests " .. (refs.excludeTests and "excluded" or "included"))
      end, "Toggle tests in find usages")

      map("n", "<leader>ru", function()
        require("config.rust_nav").goto_super()
      end, "Go to super method (trait item)")
      map("n", "<leader>rl", function()
        require("config.rust_nav").local_usages()
      end, "Usages in file (R/W)")

      map("n", "<leader>rF", "<cmd>RustContext<cr>", "Cargo features / target (both diagnostic tiers)")
      map("n", "<leader>rX", "<cmd>RustTargets<cr>", "Cargo targets: run / test / bench")

      map("n", "<leader>rZ", "<cmd>RustTools<cr>", "Cargo tools (deny, audit, bloat, timings, ...)")
      map("n", "<leader>rN", "<cmd>RustRoutes<cr>", "HTTP routes (axum / actix / rocket)")

      -- Server
      map("n", "<leader>rR", rust("reloadWorkspace"), "Reload workspace")
      map("n", "<leader>rP", rust("rebuildProcMacros"), "Rebuild proc macros")

      -- lang.rust's on_attach rebinds <leader>cR to RustLsp codeAction,
      -- shadowing LazyVim's file rename; restore it (code actions: <leader>ca).
      map("n", "<leader>cR", function()
        Snacks.rename.rename_file()
      end, "Rename File")

      pcall(function()
        require("which-key").add({ { "<leader>r", group = "rust", buffer = ev.buf } })
      end)
    end)
  end,
})

-- Safety net: built-in undotree (0.12) and the git-ref based local history.
vim.keymap.set("n", "<leader>uu", function()
  vim.cmd.packadd("nvim.undotree")
  require("undotree").open()
end, { desc = "Undotree" })
vim.keymap.set("n", "<leader>gH", "<cmd>LocalHistory<cr>", { desc = "Local history (file)" })

-- Okabe-Ito diagnostic colours (off by default; also :ColorblindDiagnostics).
Snacks.toggle({
  name = "Colourblind diagnostics",
  get = function()
    return require("config.ux").colorblind_enabled()
  end,
  set = function(state)
    require("config.ux").colorblind(state)
  end,
}):map("<leader>uB")
