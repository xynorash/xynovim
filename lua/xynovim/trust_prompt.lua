-- (Copy of xyno_rust.trust_prompt for the vendored fallback, lua/xynovim/trust_fallback.lua.)
-- The workspace-trust question as a small float: the text is wrapped to the window (vim.ui.select shows a
-- multi-line `prompt` as a one-line title of the picker, which cut the start of the question off on narrow
-- terminals), the choices are numbered lines, and the mode the editor was in is restored when it closes
-- (a picker's input line left the buffer behind it in INSERT mode).
--
--   open({ title = "Workspace trust", body = "text, \n separates paragraphs", choices = { { "Label", value } ... } },
--         function(choice_or_nil) end)
--
-- Keys: j/k/<Down>/<Up>/<Tab> move, <CR> chooses, 1-9 choose that line, q/<Esc>/<C-c> cancel (nil).
-- Losing the window (another window focused, the buffer wiped) cancels as well. Resizing the terminal
-- re-wraps and re-centres it.
local M = {}

M.max_width = 78

local function geometry(buf, win, nchoices, nbody)
  local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local width = math.max(24, math.min(M.max_width, cols - 4))
  vim.api.nvim_win_set_config(win, { width = width })
  local height = vim.api.nvim_win_text_height(win, {}).all
  height = math.max(1, math.min(height, rows - 4))
  vim.api.nvim_win_set_config(win, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((rows - height - 2) / 2)),
    col = math.max(0, math.floor((cols - width - 2) / 2)),
  })
  return height
end

function M.open(spec, cb)
  local prev_win = vim.api.nvim_get_current_win()
  local was_insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
  if was_insert then
    vim.cmd.stopinsert()
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  local lines = {}
  for _, para in ipairs(vim.split(spec.body or "", "\n", { plain = true })) do
    lines[#lines + 1] = para
  end
  lines[#lines + 1] = ""
  local first = #lines + 1
  for i, c in ipairs(spec.choices) do
    lines[#lines + 1] = ("%d  %s"):format(i, c[1])
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = 40,
    height = 3,
    row = 1,
    col = 1,
    style = "minimal",
    border = "rounded",
    title = " " .. (spec.title or "Workspace trust") .. " ",
    title_pos = "center",
    footer = " 1-" .. #spec.choices .. "  Enter choose  Esc cancel ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].cursorline = true
  vim.wo[win].scrolloff = 0 -- a global 'scrolloff' scrolled the first wrapped line out of a window that fits everything
  vim.wo[win].sidescrolloff = 0
  vim.wo[win].smoothscroll = false
  vim.wo[win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder,CursorLine:PmenuSel"
  geometry(buf, win, #spec.choices, first - 1)
  local last = first + #spec.choices - 1
  vim.api.nvim_win_set_cursor(win, { first, 0 })
  -- once more after the first redraw (the text height of a freshly opened float can be one row short of what
  -- gets drawn), and the view back to the top
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      geometry(buf, win, #spec.choices, first - 1)
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview({ topline = 1, skipcol = 0 })
      end)
    end
  end)

  local done = false
  local group = vim.api.nvim_create_augroup("xynovim_trust_prompt_" .. buf, { clear = true })
  local function finish(choice)
    if done then
      return
    end
    done = true
    pcall(vim.api.nvim_del_augroup_by_id, group)
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_win_is_valid(prev_win) then
      pcall(vim.api.nvim_set_current_win, prev_win)
    end
    if was_insert then
      vim.cmd.startinsert()
    else
      vim.cmd.stopinsert()
    end
    cb(choice)
  end
  local function move(d)
    local l = vim.api.nvim_win_get_cursor(win)[1] + d
    l = l < first and last or (l > last and first or l)
    vim.api.nvim_win_set_cursor(win, { l, 0 })
  end
  local function map(keys, fn)
    for _, k in ipairs(type(keys) == "table" and keys or { keys }) do
      vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true })
    end
  end
  map({ "j", "<Down>", "<Tab>", "<C-n>" }, function()
    move(1)
  end)
  map({ "k", "<Up>", "<S-Tab>", "<C-p>" }, function()
    move(-1)
  end)
  map("<CR>", function()
    local l = vim.api.nvim_win_get_cursor(win)[1]
    finish(spec.choices[l - first + 1])
  end)
  for i = 1, math.min(9, #spec.choices) do
    map(tostring(i), function()
      finish(spec.choices[i])
    end)
  end
  map({ "q", "<Esc>", "<C-c>" }, function()
    finish(nil)
  end)
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        finish(nil)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    callback = function()
      vim.schedule(function()
        finish(nil)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if not done and vim.api.nvim_win_is_valid(win) then
        geometry(buf, win, #spec.choices, first - 1)
      end
    end,
  })
  return { win = win, buf = buf }
end

return M
