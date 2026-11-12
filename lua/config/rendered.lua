-- Readable compiler output (docs/comparison/ui-community.md item 13): the diagnostic under the cursor as
-- rustc prints it, in a float with the parts coloured (`error[E0308]:` in the severity colour, the `-->`
-- location, the line-number gutter, the `^^^^` carets, `note:` / `help:`), instead of the plain-text
-- `vim.diagnostic.open_float`.
--
-- The text comes from rust-analyzer's flycheck diagnostics (`user_data.lsp.data.rendered`) or, for a
-- tier that sends the whole rendered message as its message (bacon-ls / clippy), from the message
-- itself. A diagnostic with neither (rust-analyzer's own instant tier: one sentence) is shown as its
-- message, uncoloured, with a note saying so.
--
--   :DiagnosticRendered    <leader>cD
local M = {}

local ns = vim.api.nvim_create_namespace("xyno_rendered")

--- ANSI escape sequences removed (some servers keep rustc's colour codes).
function M.strip_ansi(s)
  return (s:gsub("\27%[[%d;]*m", ""))
end

--- The text rustc would have printed for this diagnostic, or nil when the diagnostic only has a one-line
--- message.
--- @param d vim.Diagnostic
--- @return string? text, boolean rendered  rendered = the text is rustc's own rendering
function M.rendered_text(d)
  local lsp = type(d.user_data) == "table" and d.user_data.lsp or nil
  local data = lsp and lsp.data
  if type(data) == "table" and type(data.rendered) == "string" and data.rendered ~= "" then
    return M.strip_ansi(data.rendered):gsub("%s+$", ""), true
  end
  local msg = M.strip_ansi(d.message or "")
  if msg:find("\n") and (msg:find("^%a+%[?%w*%]?:") or msg:find("%-%->")) then
    return (msg:gsub("%s+$", "")), true
  end
  return msg, false
end

local KIND_HL = {
  error = "XynoRenderedError",
  warning = "XynoRenderedWarn",
  note = "XynoRenderedNote",
  help = "XynoRenderedHelp",
}

--- Highlight spans for the lines of a rendered message.
--- @param lines string[]
--- @param severity integer vim.diagnostic.severity of the diagnostic (colours the `^^^` carets)
--- @return { row: integer, col: integer, end_col: integer, hl: string }[] 0-based rows, byte columns
function M.spans(lines, severity)
  local caret = severity == vim.diagnostic.severity.ERROR and "XynoRenderedError"
    or severity == vim.diagnostic.severity.WARN and "XynoRenderedWarn"
    or "XynoRenderedNote"
  local out = {}
  local function add(row, s, e, hl)
    if s and e and e >= s then
      out[#out + 1] = { row = row, col = s - 1, end_col = e, hl = hl }
    end
  end
  local label_hl -- colour of the labels hanging under the previous underline row (heuristic: a row with a
  -- `-` run means secondary labels; otherwise the primary colour)
  for i, line in ipairs(lines) do
    local row = i - 1
    local kind, rest_at = line:match("^(%a+)()")
    if kind and KIND_HL[kind] and (line:sub(rest_at, rest_at) == ":" or line:sub(rest_at, rest_at) == "[") then
      -- "error[E0308]: message"
      local close = line:find(":", rest_at, true)
      add(row, 1, close - 1, KIND_HL[kind])
      add(row, close + 1, #line, "XynoRenderedMessage")
    elseif line:find("^%s*%-%->") then
      local a, b = line:find("%-%->")
      add(row, a, b, "XynoRenderedGutter")
      add(row, b + 1, #line, "XynoRenderedPath")
    else
      local gs, ge = line:find("^%s*%d*%s*|")
      local es, ee = line:find("^%s*=")
      if gs then
        add(row, gs, ge, "XynoRenderedGutter")
        if line:find("^%s*%d") then
          label_hl = nil
        end
        local rest = line:sub(ge + 1)
        -- underline row: runs of ^ (primary, severity colour) and - (secondary), then the label, which
        -- takes the colour of the last run
        local text_at = not line:find("^%s*%d") and rest:find("^[%s|]*()%a")
        if text_at and label_hl and not rest:find("^[%s%^%-|]*[%^%-]") then
          -- a label line under the carets: "  |            expected due to this"
          add(row, ge + rest:find("%a"), ge + #rest, label_hl)
        elseif not line:find("^%s*%d") and rest:find("^[%s%^%-|]*[%^%-]") then
          local pos, last_hl = 1, nil
          label_hl = rest:find("%-") and "XynoRenderedNote" or caret
          if rest:find("%^") and rest:find("%-") then
            label_hl = "XynoRenderedNote" -- carets + dashes: the hanging labels belong to the dashes
          end
          while pos <= #rest do
            local ch = rest:sub(pos, pos)
            if ch == "^" or ch == "-" then
              local _, e = rest:find("^" .. (ch == "^" and "%^+" or "%-+"), pos)
              last_hl = ch == "^" and caret or "XynoRenderedNote"
              add(row, ge + pos, ge + e, last_hl)
              pos = e + 1
            elseif ch == " " or ch == "|" then
              pos = pos + 1
            else
              if last_hl then
                add(row, ge + pos, ge + #rest, last_hl)
              end
              break
            end
          end
        end
      elseif es then
        add(row, es, ee, "XynoRenderedGutter")
        local word = line:match("^%s*=%s*(%a+):")
        if word and KIND_HL[word] then
          local ws = line:find(word, ee, true)
          add(row, ws, ws + #word - 1, KIND_HL[word])
        end
      end
    end
  end
  return out
end

local last = { win = nil }

--- Open the float for `d` (the diagnostic under the cursor when nil). Returns the window, or nil when
--- there is no diagnostic.
--- @param d? vim.Diagnostic
function M.open(d)
  if not d then
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local best
    for _, x in ipairs(vim.diagnostic.get(0, { lnum = row })) do
      local covers = x.col <= col and col < (x.end_col or x.col + 1)
      if not best or (covers and not best.covers) or (covers == best.covers and x.severity < best.d.severity) then
        best = { d = x, covers = covers }
      end
    end
    d = best and best.d
  end
  if not d then
    vim.notify("No diagnostic on this line", vim.log.levels.INFO)
    return nil
  end
  if last.win and vim.api.nvim_win_is_valid(last.win) then
    pcall(vim.api.nvim_win_close, last.win, true)
  end
  local text, rendered = M.rendered_text(d)
  local lines = vim.split(text, "\n", { plain = true })
  if not rendered then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "(one-line message: rust-analyzer's instant tier has no rustc rendering for this problem)"
  end
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width, math.max(vim.o.columns - 6, 20))
  local rows = 0 -- wrapped rows: the window must be tall enough for them or the last lines are cut
  for _, l in ipairs(lines) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  local height = math.min(rows, math.max(vim.o.lines - 6, 3))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "xyno-rendered"
  if rendered then
    for _, s in ipairs(M.spans(lines, d.severity)) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, s.row, s.col, { end_col = math.min(s.end_col, #lines[s.row + 1]), hl_group = s.hl })
    end
  end
  local title = (d.code and (" " .. tostring(d.code) .. " ") or " diagnostic ")
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    footer = " " .. (d.source or "?") .. "  q: close ",
    footer_pos = "right",
    focusable = true,
  })
  vim.wo[win].wrap = true
  vim.wo[win].winhighlight =
    "NormalFloat:XynoPopupNormal,FloatBorder:XynoPopupBorder,FloatTitle:XynoPopupTitle,FloatFooter:XynoPopupFooter"
  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true })
  -- the float follows the cursor away: close it when the cursor moves in the source window
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    once = true,
    callback = function()
      if vim.api.nvim_get_current_win() ~= win then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end,
  })
  last.win = win
  return win
end

function M.setup()
  vim.api.nvim_create_user_command("DiagnosticRendered", function()
    M.open()
  end, { desc = "The diagnostic under the cursor as rustc prints it, coloured" })
  vim.keymap.set("n", "<leader>cD", function()
    M.open()
  end, { desc = "Diagnostic as rustc prints it (coloured)" })
end

return M
