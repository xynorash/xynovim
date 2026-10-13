-- Replacements for rustaceanvim commands whose own keymap flow is broken or
-- unhelpful on nvim 0.12 / this setup (keys in keymaps.lua, group <leader>r).
local M = {}

--- Prompt, then hand the answer to `cb` (vim.ui.input is async with Snacks).
local function ask(prompt, cb)
  vim.ui.input({ prompt = prompt }, function(q)
    if q and q ~= "" then
      cb(q)
    end
  end)
end

--- <leader>rs: rustaceanvim reads the query right after vim.ui.input returns,
--- which is before Snacks' async input has an answer. Prompt here instead.
--- Visual: leave visual mode first so '< and '> hold the selection.
function M.ssr(visual)
  local l1, l2
  if visual then
    vim.cmd("normal! \27")
    l1, l2 = vim.fn.line("'<"), vim.fn.line("'>")
  end
  ask("SSR query (pattern ==>> replacement): ", function(q)
    -- rustaceanvim raises a raw traceback (ssr.lua:16) for a query without the arrow
    if not q:find("==>>", 1, true) then
      return vim.notify("SSR query needs `pattern ==>> replacement`", vim.log.levels.WARN)
    end
    local cmd = { cmd = "RustLsp", args = { "ssr", q } }
    if visual then
      cmd.range = { l1, l2 }
    end
    -- rust-analyzer's parse error (`nonsense ==>>`) reaches rustaceanvim's handler, which
    -- error()s inside a scheduled callback (traceback): intercept the reply for this request
    local ok, ra = pcall(require, "rustaceanvim.rust_analyzer")
    local orig = ok and ra.buf_request
    if orig then
      ra.buf_request = function(bufnr, method, params, handler, ...)
        return orig(bufnr, method, params, function(err, res, ctx, ...)
          if err then
            return vim.notify("SSR: " .. tostring(err.message or err), vim.log.levels.WARN)
          end
          -- a query that matches nothing answers an empty edit: say so
          if not res or (vim.tbl_isempty(res.changes or {}) and vim.tbl_isempty(res.documentChanges or {})) then
            return vim.notify("SSR: no matches", vim.log.levels.INFO)
          end
          return handler(err, res, ctx, ...)
        end, ...)
      end
    end
    local ran, e = pcall(vim.api.nvim_cmd, cmd, {})
    if orig then
      ra.buf_request = orig
    end
    if not ran then
      error(e, 0)
    end
  end)
end

--- <leader>rw / rW: rustaceanvim's own prompt asks twice when no query is
--- given, so ask once here. Results land in the quickfix list.
function M.workspace_symbol(deps)
  -- RustLsp only exists in a Rust buffer: from the quickfix list, a picker or
  -- a terminal run it in a Rust window of this tab.
  local win = vim.api.nvim_get_current_win()
  if vim.bo.filetype ~= "rust" then
    win = nil
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "rust" then
        win = w
        break
      end
    end
    if not win then
      return vim.notify("workspace symbol: no Rust window in this tab", vim.log.levels.WARN)
    end
  end
  ask("Symbol query: ", function(q)
    -- RustLsp splits its arguments on whitespace: the first word is the query ("Square area" became
    -- "Squarearea" when the blanks were stripped, and found nothing)
    local word = q:match("%S+")
    if not word then
      return
    end
    if word ~= vim.trim(q) then
      vim.notify("workspace symbol: only one word is searched (" .. word .. ")", vim.log.levels.INFO)
    end
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_cmd({ cmd = "RustLsp", args = { "workspaceSymbol", word }, bang = deps }, {})
    end)
  end)
end

--- <leader>re: rustaceanvim only explains rustc (flycheck) diagnostics, which
--- are off here. Take the E-code from any diagnostic on the line (the
--- rust-analyzer ones carry `code`, clippy/bacon ones only have it in the
--- message) and show `rustc --explain` in a float.
function M.explain_error()
  local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
  local code
  for _, d in ipairs(vim.diagnostic.get(0, { lnum = lnum })) do
    code = code or tostring(d.code or ""):match("^E%d%d%d%d$") or d.message:match("E%d%d%d%d")
  end
  if not code then
    return vim.notify("no E0000 error code in the diagnostics on this line", vim.log.levels.INFO)
  end
  vim.system({ "rustc", "--explain", code }, { text = true }, function(o)
    vim.schedule(function()
      if o.code ~= 0 then
        return vim.notify("rustc --explain " .. code .. " failed:\n" .. (o.stderr or ""), vim.log.levels.ERROR)
      end
      Snacks.win({
        text = vim.split(o.stdout, "\n"),
        ft = "markdown",
        title = " " .. code .. " ",
        width = 0.7,
        height = 0.8,
        border = "rounded",
        wo = { wrap = true, conceallevel = 2 },
      })
    end)
  end)
end

--- <leader>rd / rE: rustaceanvim's handler treats the `vim.NIL` that
--- rust-analyzer answers for an undocumented item as a URL and throws.
function M.open_docs()
  local ra = require("rustaceanvim.rust_analyzer")
  local client = ra.get_active_rustaceanvim_clients(0)[1]
  if not client then
    return
  end
  ra.buf_request(0, "experimental/externalDocs", vim.lsp.util.make_position_params(0, client.offset_encoding or "utf-8"), function(_, res)
    if type(res) ~= "table" then
      return vim.notify("no documentation for the item under the cursor", vim.log.levels.INFO)
    end
    local loc = res["local"] ~= nil and res["local"] ~= vim.NIL and tostring(res["local"]) or nil
    local url = (loc and vim.uv.fs_stat(vim.uri_to_fname(loc))) and loc or (res.web ~= vim.NIL and res.web and tostring(res.web))
    if url then
      require("rustaceanvim.config.internal").tools.open_url(url)
    else
      vim.notify("no documentation for the item under the cursor", vim.log.levels.INFO)
    end
  end)
end

--- Indented JSON (vim.json.encode has no indent option).
local function pretty(v, ind, out)
  ind = ind or ""
  local t = type(v)
  if t ~= "table" then
    out[#out + 1] = vim.json.encode(v)
  elseif vim.islist(v) then
    if #v == 0 or type(v[1]) ~= "table" then -- scalars (positions): one line
      out[#out + 1] = vim.json.encode(v)
    else
      out[#out + 1] = "[\n"
      for i, x in ipairs(v) do
        out[#out + 1] = ind .. "  "
        pretty(x, ind .. "  ", out)
        out[#out + 1] = i < #v and ",\n" or "\n"
      end
      out[#out + 1] = ind .. "]"
    end
  else
    local keys = vim.tbl_keys(v)
    table.sort(keys)
    if #keys == 0 then
      out[#out + 1] = "{}"
    else
      out[#out + 1] = "{\n"
      for i, k in ipairs(keys) do
        out[#out + 1] = ("%s  %s: "):format(ind, vim.json.encode(k))
        pretty(v[k], ind .. "  ", out)
        out[#out + 1] = i < #keys and ",\n" or "\n"
      end
      out[#out + 1] = ind .. "}"
    end
  end
  return out
end

--- <leader>rS: newer rust-analyzer answers viewSyntaxTree with one long JSON
--- line; pretty-print it into a json scratch split.
function M.syntax_tree()
  local ra = require("rustaceanvim.rust_analyzer")
  local client = ra.get_active_rustaceanvim_clients(0)[1]
  if not client then
    return
  end
  local params = vim.lsp.util.make_range_params(0, client.offset_encoding or "utf-8")
  ra.buf_request(0, "rust-analyzer/viewSyntaxTree", params, function(err, result)
    if err or result == nil then
      return vim.notify("rust-analyzer: " .. ((err and err.message) or "viewSyntaxTree failed"), vim.log.levels.ERROR)
    end
    local ok, tree = pcall(vim.json.decode, result)
    local text = ok and table.concat(pretty(tree, "", {})) or result -- older servers: plain text
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
    vim.bo[buf].filetype = ok and "json" or "rust"
    vim.bo[buf].modifiable = false
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, buf)
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf })
  end)
end

--- <leader>cR: Snacks' rename (fs rename) overwrote an existing destination: ask for the
--- name here (same prompt and default), refuse when it exists, then let Snacks do the rest.
function M.rename_file()
  local from = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local root = vim.fs.normalize(vim.fn.getcwd(0))
  if from:find(root, 1, true) ~= 1 then
    root = vim.fs.dirname(from)
  end
  local extra = from:sub(#root + 2)
  vim.ui.input({ prompt = "New File Name: ", default = extra, completion = "file" }, function(value)
    if not value or value == "" or value == extra then
      return
    end
    local to = vim.fs.normalize(root .. "/" .. value)
    if vim.uv.fs_stat(to) then
      return vim.notify("Rename: " .. to .. " already exists", vim.log.levels.ERROR)
    end
    Snacks.rename.rename_file({ from = from, to = to })
  end)
end

--- <A-j>/<A-k>: `experimental/moveItem` answers snippet edits whose text is NOT
--- escaped (only the `$0` cursor marker is meant), and rustaceanvim expanded them as
--- snippets: `$e` in a macro_rules item became empty and auto-save wrote it. The edits
--- are applied as plain text here, only the first `$0` marker is dropped (it places
--- the cursor, same arithmetic as rustaceanvim's move_item.lua).
--- @param direction "Up"|"Down"
function M.move_item(direction)
  local ok, ra = pcall(require, "rustaceanvim.rust_analyzer")
  if not ok or #ra.get_active_rustaceanvim_clients(0) == 0 then
    return
  end
  local client = ra.get_active_rustaceanvim_clients(0)[1]
  local params = vim.lsp.util.make_range_params(0, client.offset_encoding or "utf-8")
  params.direction = direction
  ra.buf_request(0, "experimental/moveItem", params, function(_, edits, ctx)
    if not edits or #edits == 0 or not vim.api.nvim_buf_is_valid(ctx.bufnr) then
      return
    end
    local cursor = { edits[1].range.start.line }
    local prev
    for _, e in ipairs(edits) do
      if e.insertTextFormat == 2 and e.newText then
        local at = e.newText:find("$0", 1, true)
        if not cursor[2] then
          if prev then
            cursor[1] = cursor[1]
              + math.max(0, e.range.start.line - prev.range["end"].line - 1)
              - (prev.range.start.line == e.range.start.line and 1 or 0)
          end
          local lines = vim.split(e.newText:sub(1, at or #e.newText), "\n")
          cursor[1] = cursor[1] + #lines
          if at then
            cursor[2] = (#lines == 1 and e.range.start.character or 0) + #lines[#lines] - 1
          end
        end
        if at then
          e.newText = e.newText:sub(1, at - 1) .. e.newText:sub(at + 2)
        end
      end
      e.insertTextFormat = nil
      prev = e
    end
    vim.lsp.util.apply_text_edits(edits, ctx.bufnr, client.offset_encoding or "utf-8")
    pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, cursor[1]), cursor[2] or 0 })
  end)
end

return M
