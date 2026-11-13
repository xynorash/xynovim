-- Layouts that adapt to the terminal width. The window of a side panel is paid for by the code window:
-- a 48-column neotest summary plus a 40..60-column dap-ui sidebar left ~30 columns for the code at the
-- 93 columns a default Ghostty window opens with. Below `threshold` columns (vim.g.xynovim_narrow_columns,
-- default 120) the neotest summary opens as a float over the right edge (it closes when the cursor leaves it)
-- and dap-ui puts its panels in one strip at the bottom, with the rest one float away; wide windows
-- keep the sidebars.
local M = {}

function M.threshold()
  local v = vim.g.xynovim_narrow_columns
  return type(v) == "number" and v or 120
end

---@return boolean
function M.is_narrow()
  return vim.o.columns < M.threshold()
end

-- neotest `summary.open`: returns the window that gets the summary buffer.
function M.summary_open()
  if not M.is_narrow() then
    vim.cmd("botright vsplit | vertical resize 48")
    return vim.api.nvim_get_current_win()
  end
  local width = math.max(30, math.min(48, vim.o.columns - 36))
  -- not the whole height: the dap-ui strip below it stays readable
  local height = math.max(8, math.min(vim.o.lines - vim.o.cmdheight - 4, math.floor(vim.o.lines * 0.6)))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 1,
    col = vim.o.columns - width - 2,
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
    title = " Tests (q: close) ",
    title_pos = "center",
    zindex = 45,
  })
  -- neotest swaps its buffer in right after this returns: "q" closes the float (and gives the key back
  -- the moment the same buffer is shown in a split)
  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    local b = vim.api.nvim_win_get_buf(win)
    vim.keymap.set("n", "q", function()
      if vim.api.nvim_win_get_config(0).relative ~= "" then
        pcall(vim.api.nvim_win_close, 0, true)
      else
        pcall(vim.keymap.del, "n", "q", { buffer = b })
        vim.api.nvim_feedkeys("q", "n", false)
      end
    end, { buffer = b, nowait = true, desc = "Close the test summary float" })
  end)
  -- leaving the float (jumping to a test, clicking the code) puts it away again; it is never in the way
  vim.api.nvim_create_autocmd("WinLeave", {
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then
        return true -- the float is gone: drop this autocmd
      end
      if vim.api.nvim_get_current_win() == win then
        vim.schedule(function()
          if vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() ~= win then
            pcall(vim.api.nvim_win_close, win, true)
          end
        end)
      end
    end,
  })
  return win
end

-- dap-ui layouts for the current width.
function M.dapui_layouts()
  if M.is_narrow() then
    return {
      {
        elements = {
          { id = "scopes", size = 0.4 },
          { id = "console", size = 0.4 },
          { id = "stacks", size = 0.2 },
        },
        position = "bottom",
        size = 12,
      },
    }
  end
  local width = math.max(40, math.min(60, math.floor(vim.o.columns * 0.35)))
  return {
    {
      elements = {
        { id = "scopes", size = 0.4 },
        { id = "breakpoints", size = 0.15 },
        { id = "stacks", size = 0.25 },
        { id = "watches", size = 0.2 },
      },
      position = "left",
      size = width,
    },
    {
      elements = {
        { id = "repl", size = 0.5 },
        { id = "console", size = 0.5 },
      },
      position = "bottom",
      size = 10,
    },
  }
end

-- dap-ui reads its layouts at setup(). The window may have been resized (or a session started in a
-- tmux pane of another size) since: set the layouts up again, while closed, before open/toggle when the
-- narrow/wide class changed.
function M.follow_dapui()
  local ok, dapui = pcall(require, "dapui")
  if not ok or dapui._xyno_narrow then
    return
  end
  dapui._xyno_narrow = true
  local applied = M.is_narrow()
  local function any_open()
    local okw, windows = pcall(require, "dapui.windows")
    for _, l in ipairs(okw and windows.layouts or {}) do
      if l:is_open() then
        return true
      end
    end
    return false
  end
  local function refresh()
    if M.is_narrow() == applied then
      return false
    end
    applied = M.is_narrow()
    local was_open = any_open()
    pcall(dapui.close, {})
    pcall(dapui.setup, { wrap = true, layouts = M.dapui_layouts() })
    return was_open
  end
  local open, toggle = dapui.open, dapui.toggle
  dapui.open = function(...)
    refresh()
    return open(...)
  end
  dapui.toggle = function(...)
    if refresh() then
      return -- it was open: this press closes it (done above), the next one opens the new layout
    end
    return toggle(...)
  end
end

return M
