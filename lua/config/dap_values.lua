-- Debugger value UX on top of nvim-dap / nvim-dap-ui (see lua/plugins/dap.lua):
--   * preview_script(): lldb summaries that add container contents (scripts/lldb/xyno_rust_preview.py),
--   * the call stack: runtime frames marked "subtle" (nvim-dap-ui's stacks element hides those, `t`
--     there shows them again; nvim-dap's own up/down still walk every frame), closures / async fns named,
--   * <leader>dv: the full value of the expression under the cursor in a wrapped float with its children,
--     `K` does the same while the debuggee is stopped (LSP hover otherwise),
--   * formatter health: a warning when the Rust formatters did not load (CodeLLDB #1166),
--   * logpoints, hit counts, exception breakpoints (cpp_throw / cpp_catch / rust_panic from the adapter).
local M = {}

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "dap" })
end

--- Absolute path of the preview script, nil when the checkout lacks it.
function M.preview_script()
  local p = root .. "/scripts/lldb/xyno_rust_preview.py"
  return vim.uv.fs_stat(p) and p or nil
end

-- ------------------------------------------------------------------ names

--- `alloc::vec::Vec<int, alloc::alloc::Global>` -> `Vec<int>`: module paths and the default
--- allocator / hasher parameters are noise in a variables pane.
function M.type_short(t)
  if not t then
    return t
  end
  t = t:gsub(", alloc::alloc::Global", ""):gsub(", std::hash::random::RandomState", "")
  t = t:gsub("[%a_][%w_]*::", "")
  return t
end

--- Closures and async blocks get readable names; returns the name and whether it is async.
function M.frame_name(name)
  local async = false
  local n = name
  n = n:gsub("::{async_fn#%d+}", function()
    async = true
    return "::<async fn>"
  end)
  n = n:gsub("::{async_block#%d+}", function()
    async = true
    return "::<async block>"
  end)
  n = n:gsub("::{closure#%d+}", "::<closure>")
  return n, async
end

--- Mark the runtime frames of a stack subtle and rename closures / async frames in place.
---@return integer async_frames
function M.process_frames(frames)
  local is_runtime = require("config.dap_panic").is_runtime
  local async_n = 0
  for _, f in ipairs(frames or {}) do
    if is_runtime(f) then
      f.presentationHint = "subtle"
    else
      local n, async = M.frame_name(f.name or "")
      f.name = n
      if async then
        async_n = async_n + 1
      end
    end
  end
  return async_n
end

--- Text of a variable's inline virtual text: `= value` (or `name = value` at end of line), one line,
--- cut at `max` characters.
function M.inline_text(variable, options, max)
  max = max or 60
  local v = (variable.value or ""):gsub("%s+", " ")
  if vim.fn.strchars(v) > max then
    v = vim.fn.strcharpart(v, 0, max - 1) .. "\226\128\166"
  end
  if options and options.virt_text_pos == "inline" then
    return " = " .. v
  end
  return variable.name .. " = " .. v
end

-- ------------------------------------------------------------------ value float

--- A string value `"a\nb"` as the text it stands for, else the value unchanged.
function M.unquote(v)
  local body = v:match('^"(.*)"$')
  if not body or not body:find("\\", 1, true) then
    return v
  end
  return (body:gsub("\\(.)", { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", ["'"] = "'", ["0"] = "\0" }))
end

--- Lines for the float: header, the value (multi-line strings unescaped, long values wrapped by the window),
--- then the children as an indented tree. `node` = { name, type, value, children = { node... }, more = n }.
function M.render_value(node)
  local lines = {}
  local head = node.name and (node.name .. " : ") or ""
  lines[#lines + 1] = head .. (M.type_short(node.type) or "?")
  lines[#lines + 1] = ""
  local text = M.unquote(node.value or "")
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    lines[#lines + 1] = l
  end
  local function walk(n, depth)
    for _, c in ipairs(n.children or {}) do
      local v = (c.value or ""):gsub("\n", "\\n")
      lines[#lines + 1] = ("%s%s: %s"):format(string.rep("  ", depth), c.name, v)
      walk(c, depth + 1)
    end
    if n.more and n.more > 0 then
      lines[#lines + 1] = ("%s... %d more"):format(string.rep("  ", depth), n.more)
    end
  end
  if node.children and #node.children > 0 then
    lines[#lines + 1] = ""
    walk(node, 0)
  end
  return lines
end

local MAX_CHILDREN, MAX_DEPTH = 40, 2

--- Fetch `ref`'s children (depth levels) through the session.
local function fetch_children(session, ref, depth, done)
  session:request("variables", { variablesReference = ref, count = MAX_CHILDREN + 1 }, function(err, resp)
    if err or not resp then
      return done({}, 0)
    end
    local vars = resp.variables or {}
    local more = 0
    local out, pending = {}, 0
    local kept = {}
    for _, v in ipairs(vars) do
      -- codelldb's `[raw]` child is the unformatted object (huge, and the pane keeps it)
      if v.name ~= "[raw]" then
        kept[#kept + 1] = v
      end
    end
    vars = kept
    more = math.max(0, #vars - MAX_CHILDREN)
    for i = 1, math.min(#vars, MAX_CHILDREN) do
      out[i] = { name = vars[i].name, type = vars[i].type, value = vars[i].value }
      if depth > 1 and (vars[i].variablesReference or 0) > 0 then
        pending = pending + 1
        fetch_children(session, vars[i].variablesReference, depth - 1, function(ch, m)
          out[i].children, out[i].more = ch, m
          pending = pending - 1
          if pending == 0 then
            done(out, more)
          end
        end)
      end
    end
    if pending == 0 then
      done(out, more)
    end
  end)
end

local float_win

local function open_float(lines, title)
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    pcall(vim.api.nvim_win_close, float_win, true)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "xynodapvalue"
  local width = math.min(100, math.max(40, math.floor(vim.o.columns * 0.6)))
  local height = math.min(#lines + 1, math.max(5, math.floor(vim.o.lines * 0.5)))
  float_win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "left",
  })
  vim.wo[float_win].wrap = true
  vim.wo[float_win].linebreak = true
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, "<cmd>close<cr>", { buffer = buf, nowait = true })
  end
  return float_win
end

--- The expression for the float: the visual selection, else the identifier (with a field path) under the cursor.
local function expression_at_cursor()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" then
    local s, e = vim.fn.getpos("v"), vim.fn.getpos(".")
    local lines = vim.fn.getregion(s, e, { type = mode })
    vim.cmd("normal! \27")
    return table.concat(lines, " ")
  end
  local word = vim.fn.expand("<cexpr>")
  return word ~= "" and word or vim.fn.expand("<cword>")
end

--- Evaluate `expr` in the stopped frame and show the full value and its children.
---@param expr string?
function M.show_value(expr)
  local dap = require("dap")
  local session = dap.session()
  if not session then
    return notify("no debug session", vim.log.levels.WARN)
  end
  expr = expr or expression_at_cursor()
  if not expr or expr == "" then
    return notify("no expression under the cursor", vim.log.levels.WARN)
  end
  local frame = session.current_frame
  session:request(
    "evaluate",
    { expression = expr, context = "hover", frameId = frame and frame.id },
    function(err, resp)
      if err or not resp then
        return notify(("cannot evaluate %s: %s"):format(expr, err and err.message or "no answer"), vim.log.levels.WARN)
      end
      local node = { name = expr, type = resp.type, value = resp.result }
      local function finish()
        vim.schedule(function()
          open_float(M.render_value(node), "value")
        end)
      end
      -- a string's children are its characters: the unquoted text above is the whole content
      if (resp.variablesReference or 0) > 0 and not (resp.result or ""):match('^"') then
        fetch_children(session, resp.variablesReference, MAX_DEPTH, function(ch, more)
          node.children, node.more = ch, more
          finish()
        end)
      else
        finish()
      end
    end
  )
end

--- `K`: the value float while the debuggee is stopped, LSP hover otherwise.
function M.hover()
  local session = require("dap").session()
  if session and session.stopped_thread_id then
    return M.show_value()
  end
  vim.lsp.buf.hover()
end

-- ------------------------------------------------------------------ breakpoints

--- Set a logpoint at the cursor line (`{expr}` in the message is evaluated by codelldb).
function M.logpoint(msg)
  local function set(m)
    if m and m ~= "" then
      require("dap").set_breakpoint(nil, nil, m)
    end
  end
  if msg then
    return set(msg)
  end
  vim.ui.input({ prompt = "Log message ({expr} is evaluated): " }, set)
end

--- Break on the Nth hit (`3`, `>= 3`, `% 10`: the adapter's hit condition syntax).
function M.hit_count(cond)
  local function set(c)
    if c and c ~= "" then
      require("dap").set_breakpoint(nil, c)
    end
  end
  if cond then
    return set(cond)
  end
  vim.ui.input({ prompt = "Hit count (3, >= 3, % 10): " }, set)
end

--- Exception filters the adapter offers (codelldb: cpp_throw, cpp_catch, rust_panic ...), as a pick list.
---@return table[]|nil
function M.exception_filters()
  local s = require("dap").session()
  return s and s.capabilities and s.capabilities.exceptionBreakpointFilters or nil
end

function M.exception_breakpoints()
  local dap = require("dap")
  local filters = M.exception_filters()
  if not filters or #filters == 0 then
    return notify("start a debug session first: the adapter says which exceptions it can break on", vim.log.levels.WARN)
  end
  vim.ui.select(filters, {
    prompt = "Break on (toggle)",
    format_item = function(f)
      local on = M.active_exceptions and M.active_exceptions[f.filter]
      return ("%s %s%s"):format(
        on and "[x]" or "[ ]",
        f.label or f.filter,
        f.description and ("  - " .. f.description) or ""
      )
    end,
  }, function(choice)
    if not choice then
      return
    end
    M.active_exceptions = M.active_exceptions or {}
    M.active_exceptions[choice.filter] = not M.active_exceptions[choice.filter] or nil
    local list = {}
    for _, f in ipairs(filters) do
      if M.active_exceptions[f.filter] then
        list[#list + 1] = f.filter
      end
    end
    dap.set_exception_breakpoints(list)
    notify("break on: " .. (#list > 0 and table.concat(list, ", ") or "nothing"))
  end)
end

-- ------------------------------------------------------------------ health

--- Wording for the "formatters missing" warning (also used by the spec).
M.FORMATTER_WARNING =
  "Rust formatters did not load: String, Vec, Option... will show raw fields (CodeLLDB issue 1166). Check `rustc --print sysroot`/lib/rustlib/etc/lldb_lookup.py."

local function rust_session(session)
  local c = session and session.config
  return c and c.type == "codelldb" and vim.tbl_contains(c.sourceLanguages or {}, "rust")
end

--- Wire the listeners (idempotent: keyed).
function M.setup()
  local dap = require("dap")
  dap.listeners.before.stackTrace["xynovim_frames"] = function(session, err, body)
    if err or not body or not rust_session(session) then
      return
    end
    local n = M.process_frames(body.stackFrames)
    session.xyno_async_frames = n
  end
  -- variables pane: `alloc::vec::Vec<int, alloc::alloc::Global>` -> `Vec<int>` (vim.g.xynovim_dap_full_types = true keeps them)
  dap.listeners.before.variables["xynovim_types"] = function(session, err, body)
    if err or not body or vim.g.xynovim_dap_full_types or not rust_session(session) then
      return
    end
    for _, v in ipairs(body.variables or {}) do
      if v.type then
        v.type = M.type_short(v.type)
      end
    end
  end
  -- codelldb prints "Loading Rust formatters from ..." when the lldb_lookup.py import worked
  dap.listeners.after.event_output["xynovim_formatters"] = function(session, body)
    if body and body.output and body.output:find("Loading Rust formatters", 1, true) then
      session.xyno_formatters = true
    end
  end
  dap.listeners.after.event_stopped["xynovim_formatters"] = function(session)
    if rust_session(session) and not session.xyno_formatters and not session.xyno_formatter_warned then
      session.xyno_formatter_warned = true
      notify(M.FORMATTER_WARNING, vim.log.levels.WARN)
    end
  end
  -- stopped inside async code: say what the frames mean (a DAP adapter has no view of tokio tasks)
  dap.listeners.after.event_stopped["xynovim_async"] = function(session)
    vim.defer_fn(function()
      if (session.xyno_async_frames or 0) > 0 and not session.xyno_async_told then
        session.xyno_async_told = true
        notify(
          (
            "stopped in async code (%d async frame%s): locals of a suspended future are fields of `self` in its "
            .. "state machine; other tasks are not visible to a debugger (tokio-console lists them)"
          ):format(session.xyno_async_frames, session.xyno_async_frames == 1 and "" or "s")
        )
      end
    end, 200)
  end
  -- K: the value float while stopped
  local group = vim.api.nvim_create_augroup("xynovim_dap_hover", { clear = true })
  local function map(buf)
    if vim.bo[buf].filetype == "rust" then
      vim.keymap.set("n", "K", M.hover, { buffer = buf, desc = "Value (debugger) / hover" })
    end
  end
  dap.listeners.after.event_initialized["xynovim_hover"] = function()
    map(vim.api.nvim_get_current_buf())
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      callback = function(ev)
        map(ev.buf)
      end,
    })
  end
  -- the K map stays after the session: with nothing stopped it is vim.lsp.buf.hover, LazyVim's own K
  local function unmap()
    vim.api.nvim_clear_autocmds({ group = group })
  end
  dap.listeners.after.event_terminated["xynovim_hover"] = unmap
  dap.listeners.after.event_exited["xynovim_hover"] = unmap
end

return M
