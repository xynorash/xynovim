return {
  "okuuva/auto-save.nvim",
  event = { "InsertLeave", "TextChanged", "TextChangedI" },
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
        local buf = ev.data and ev.data.saved_buffer
        -- still modified: the write was refused (see config/disk_guard.lua)
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
        if neotest_watching() then
          vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf, modeline = false })
        end
      end,
    })

    require("auto-save").setup({
      enabled = true,
      noautocmd = true,
      -- never into dependency sources, never over a file that changed on disk
      condition = require("config.disk_guard").can_save,
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
