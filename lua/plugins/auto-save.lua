return {
  "okuuva/auto-save.nvim",
  event = { "InsertLeave", "TextChanged", "TextChangedI" },
  -- the guard behind `condition` below (not lazy itself, see plugins/xyno-guard.lua)
  dependencies = { "xynorash/xyno-guard.nvim" },
  config = function()
    -- noautocmd (below) skips BufWritePre/BufWritePost for autosaves so
    -- conform's format-on-save doesn't fire on every debounced autosave -
    -- but that also silently skips the LSP clients' BufWritePost-triggered
    -- `textDocument/didSave` (confirmed directly: `noautocmd write` sends
    -- zero LSP notifications, a normal `write` sends didSave). bacon-ls
    -- relies on didSave to restore its shadow-workspace hardlinks, and any
    -- save-aware LSP behavior needs it.
    --
    -- auto-save.nvim fires its own `User AutoSaveWritePost` autocmd AFTER
    -- the (noautocmd) write completes, with the buffer in data.saved_buffer
    -- - a supported hook, so send didSave from there. (This replaced an
    -- earlier vim.cmd proxy that pattern-matched the plugin's internal
    -- command string; the User event survives plugin refactors, the string
    -- match didn't.)
    --
    -- Neotest's watch mode (<leader>tw) reruns tests from a BufWritePost
    -- autocmd, which noautocmd writes skip too. So while a watcher exists the
    -- event is re-emitted here (it also reaches neotest's rediscovery of
    -- tests). Not otherwise: it would run every BufWritePost handler (and
    -- local history's) on each autosave for nothing.
    local function neotest_watching()
      if not package.loaded["neotest.consumers.watch.watcher"] then
        return false
      end
      for _, a in ipairs(vim.api.nvim_get_autocmds({ event = "BufWritePost" })) do
        local src = type(a.callback) == "function" and debug.getinfo(a.callback, "S").source or ""
        if src:find("neotest/consumers/watch/watcher.lua", 1, true) then
          return true
        end
      end
      return false
    end

    local group = vim.api.nvim_create_augroup("user_autosave_didsave", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      pattern = "AutoSaveWritePost",
      group = group,
      callback = function(ev)
        -- the write closed the insert-mode undo block: join what is typed next to it
        if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
          pcall(vim.cmd, "undojoin")
        end
        local buf = ev.data and ev.data.saved_buffer
        -- still modified: the write was refused (see plugins/xyno-guard.lua)
        if not (buf and vim.api.nvim_buf_is_valid(buf)) or vim.bo[buf].modified then
          return
        end
        for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
          if client:supports_method("textDocument/didSave", buf) then
            client:notify("textDocument/didSave", {
              textDocument = { uri = vim.uri_from_bufnr(buf) },
            })
          end
        end
        -- nvim-lint (group nvim-lint, LazyVim) lints on BufWritePost, which the noautocmd write
        -- skipped: the InsertLeave lint fires ~1 s before this save and read the old disk text, so
        -- Cargo.toml's cargo-deny / cargo-machete diagnostics stayed stale until a manual :w
        if vim.bo[buf].filetype ~= "rust" and package.loaded["lint"] then
          pcall(vim.api.nvim_exec_autocmds, "BufWritePost", { group = "nvim-lint", buffer = buf, modeline = false })
        end
        if neotest_watching() then
          vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf, modeline = false })
        elseif vim.bo[buf].filetype == "rust" and package.loaded["neotest.client"] then
          -- only neotest's own rediscovery (group neotest.Client): the tree kept the old
          -- tests after an autosave, so <leader>tr on a new test ran another one
          pcall(vim.api.nvim_exec_autocmds, "BufWritePost", { group = "neotest.Client", buffer = buf, modeline = false })
        end
      end,
    })

    require("auto-save").setup({
      enabled = true,
      noautocmd = true,
      -- never into dependency sources, never over a file that changed on disk
      condition = require("xyno_guard").can_save,
      trigger_events = {
        immediate_save = { "BufLeave", "FocusLost", "QuitPre", "VimSuspend" },
        -- TextChanged only fires for edits made OUTSIDE insert mode; its
        -- insert-mode counterpart is TextChangedI. Without it, the debounced
        -- save (and the didSave notify above that rides on it) never fires
        -- while still actively typing - only once you leave insert mode.
        defer_save = { "InsertLeave", "TextChanged", "TextChangedI" },
        cancel_deferred_save = { "InsertEnter" },
      },
      debounce_delay = 1000,
    })
  end,
}
