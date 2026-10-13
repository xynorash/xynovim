-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Global <leader>r<key> stubs: the r* maps below are buffer-local (rust-analyzer attached), so
-- in Cargo.toml / Lua / markdown buffers (and for a key nothing binds) Vim parsed <Space>rv as
-- `l` + `rv`, replaced a character and auto-save wrote it. A real buffer-local map wins. These
-- are per-key stubs, not one `<leader>r` leaf blocking in getcharstr(): such a leaf made which-key
-- skip its popup when `Space r` was typed at normal speed. which_key_ignore keeps them out of it.
local function not_bound(key)
  return function()
    local what = vim.bo.filetype == "rust" and " is not bound" or ": Rust maps work in Rust buffers only"
    vim.notify("<leader>r" .. key .. what, vim.log.levels.INFO)
  end
end
for _, key in ipairs(vim.split("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+[]{};:'\",.<>/?|~`", "")) do
  vim.keymap.set({ "n", "x" }, "<leader>r" .. key, not_bound(key), { desc = "which_key_ignore" })
end

-- rust-analyzer commands that rustaceanvim exposes but nothing bound.
-- Buffer-local, set on rust-analyzer attach (scheduled so we also win over
-- the lang.rust extra's own on_attach maps). <leader>r is free: the
-- editor.refactoring extra is not enabled.
-- lang.rust's on_attach rebinds <leader>cR to RustLsp codeAction, LazyVim's LSP keys bind it to
-- Snacks' rename (an fs rename that overwrote an existing destination). Ours asks first; it is set
-- again when another client (bacon-ls) attaches later, because LazyVim's keys follow every attach.
local function set_rename(buf)
  vim.keymap.set("n", "<leader>cR", function()
    require("config.rust_assist").rename_file()
  end, { buffer = buf, desc = "Rename File" })
end

vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("xynovim_rust_keymaps", { clear = true }),
  callback = function(ev)
    local client = vim.lsp.get_client_by_id(ev.data.client_id)
    if client and client.name ~= "rust-analyzer" and #vim.lsp.get_clients({ bufnr = ev.buf, name = "rust-analyzer" }) > 0 then
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(ev.buf) then
          set_rename(ev.buf)
        end
      end)
    end
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
      -- rust-analyzer offers Extract Module only for a selection, so visual only.
      map("x", "<leader>rM", assist("^Extract [Mm]odule"), "Extract module (visual)")
      -- Without a mapping `<leader>r` + `M` is cursor-right plus `r M`: it
      -- replaced the character under the cursor and auto-save wrote it.
      map("n", "<leader>rM", function()
        vim.notify("Extract module: select code first (visual mode)", vim.log.levels.INFO)
      end, "Extract module (visual only)")
      -- "Inline macro" (cursor on println!) expanded silently: not matched.
      -- "Inline into all callers" (cursor on the fn declaration) deletes the definition and
      -- rewrote every call site silently (`helper(1) as usize` became `1 + 1 as usize`: rust-analyzer
      -- does not parenthesise), so that variant asks first.
      map({ "n", "x" }, "<leader>ri", function()
        vim.lsp.buf.code_action({
          apply = true,
          filter = function(a)
            if a.title:find("^Inline [^m]") == nil then
              return false
            end
            if a.title:find("all callers", 1, true) then
              return vim.fn.confirm(a.title .. "? The definition is deleted.", "&Yes\n&No", 2) == 1
            end
            return true
          end,
        })
      end, "Inline")
      -- Own prompt (rustaceanvim's reads the query before Snacks answers).
      map("n", "<leader>rs", function()
        require("config.rust_assist").ssr()
      end, "Structural search & replace")
      map("x", "<leader>rs", function()
        require("config.rust_assist").ssr(true)
      end, "Structural search & replace (selection)")
      map("n", "<leader>rj", rust("joinLines"), "Join lines (semantic)")
      map("x", "<leader>rj", ":RustLsp joinLines<CR>", "Join lines (semantic)")
      -- own request: :RustLsp moveItem expanded `$name` in the moved item as snippet variables
      map("n", "<A-j>", function()
        require("config.rust_assist").move_item("Down")
      end, "Move item down")
      map("n", "<A-k>", function()
        require("config.rust_assist").move_item("Up")
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
      end, "Open docs (local rustup, else docs.rs)")
      map("n", "<leader>rE", function()
        require("config.rust_assist").open_docs()
      end, "Open docs (same as rd)")
      map("x", "<leader>rk", function()
        vim.cmd.RustLsp({ "hover", "range" })
      end, "Hover range (type of selection)")
      map("n", "<leader>rk", function()
        vim.notify("Hover range: select code first (visual mode)", vim.log.levels.INFO)
      end, "Hover range (visual only)")

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

      -- (code actions: <leader>ca)
      set_rename(ev.buf)

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
