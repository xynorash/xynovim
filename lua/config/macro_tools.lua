-- Macro tools (plan items 2.3, 2.4, 2.5):
--   * macro call help: signature popup for macro_rules! calls (the matcher arms
--     of the definition, found with go-to-definition), format-string and sqlx
--     bind hints, blink snippets for select!/matches!/vec![x; n]
--   * macro lens: :MacroExpand (rust-analyzer/expandMacro in a read-only split,
--     nested stepping, generated items, cargo expand fallback)
--   * proc-macro health: :ProcMacroStatus
--
-- Layout: the pure parts first (lexer, format strings, matcher), then the UI.
-- The pure parts take strings and tables and are what tests/macro-tools_spec.lua
-- drives table-wise. Everything that runs a program uses argv lists; crate
-- names that reach a path or a file are validated first.
local M = {}

local uv = vim.uv or vim.loop

-- ===================================================================== lexer
-- A Rust token lexer that is only as exact as macro help needs: strings (raw,
-- byte, c), chars vs lifetimes, comments, numbers, groups. Groups nest; a
-- group that is not closed (the text ends while typing) has open = true.
--
-- token = { t = "id"|"lit"|"str"|"life"|"p"|"group", s = text, sr, sc, er, ec }
-- (0-based row, byte col, end exclusive); a group adds d = "(" | "[" | "{",
-- kids, open, and cr, cc = the position of its closing delimiter.

local PUNCT3 = { ["..="] = true, ["..."] = true, ["<<="] = true, [">>="] = true }
local PUNCT2 = {}
for _, p in ipairs({ "=>", "::", "->", "..", "==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "^=", "&=", "|=", "<<", ">>" }) do
  PUNCT2[p] = true
end
local CLOSER = { ["("] = ")", ["["] = "]", ["{"] = "}" }

--- Tokens of `text`. opts.row0 / opts.col0 shift the reported positions (the
--- text starts there in its buffer).
function M.lex(text, opts)
  opts = opts or {}
  local n = #text
  local starts = { 1 }
  for i in text:gmatch("()\n") do
    starts[#starts + 1] = i + 1
  end
  local row0, col0 = opts.row0 or 0, opts.col0 or 0
  --- byte index (1-based) -> row, col (0-based)
  local function rc(i)
    local lo, hi = 1, #starts
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if starts[mid] <= i then
        lo = mid
      else
        hi = mid - 1
      end
    end
    local col = i - starts[lo]
    if lo == 1 then
      col = col + col0
    end
    return lo - 1 + row0, col
  end

  local function tok(t, i, j, extra) -- j exclusive
    local sr, sc = rc(i)
    local er, ec = rc(j)
    local o = { t = t, s = text:sub(i, j - 1), sr = sr, sc = sc, er = er, ec = ec }
    if extra then
      for k, v in pairs(extra) do
        o[k] = v
      end
    end
    return o
  end

  --- index after the string starting at i (a `"`), honouring `\`
  local function skip_string(i)
    local j = i + 1
    while true do
      local p = text:find('[\\"]', j)
      if not p then
        return n + 1
      end
      if text:sub(p, p) == "\\" then
        j = p + 2
      else
        return p + 1
      end
    end
  end

  local run
  run = function(i, close)
    local kids = {}
    while i <= n do
      local c = text:sub(i, i)
      if c:find("%s") then
        i = text:find("[^%s]", i) or (n + 1)
      elseif text:sub(i, i + 1) == "//" then
        i = (text:find("\n", i, true) or n) + 1
      elseif text:sub(i, i + 1) == "/*" then
        local depth, j = 1, i + 2
        while depth > 0 do
          local a, b = text:find("[/*]", j)
          if not a then
            j = n + 1
            break
          end
          local two = text:sub(a, a + 1)
          if two == "/*" then
            depth, j = depth + 1, a + 2
          elseif two == "*/" then
            depth, j = depth - 1, a + 2
          else
            j = b + 1
          end
        end
        i = j
      elseif c == '"' then
        local j = skip_string(i)
        kids[#kids + 1] = tok("str", i, j)
        i = j
      elseif c:find("[%a_\128-\255]") then
        local id = text:match("^[%w_\128-\255]+", i)
        local j = i + #id
        local nx = text:sub(j, j)
        if (id == "b" or id == "c") and nx == '"' then
          j = skip_string(j)
          kids[#kids + 1] = tok("str", i, j)
        elseif (id == "r" or id == "br" or id == "cr") and (nx == '"' or (nx == "#" and text:find('^#*"', j))) then
          local hashes = text:match("^#*", j)
          local body = j + #hashes + 1
          local a, b = text:find('"' .. hashes, body, true)
          j = a and (b + 1) or (n + 1)
          kids[#kids + 1] = tok("str", i, j)
        elseif id == "b" and nx == "'" then
          local a = text:find("'", j + 2 + (text:sub(j + 1, j + 1) == "\\" and 1 or 0), true)
          j = a and (a + 1) or (n + 1)
          kids[#kids + 1] = tok("lit", i, j)
        elseif id == "r" and nx == "#" and text:find("^#[%a_]", j) then
          j = j + #text:match("^#[%w_]+", j)
          kids[#kids + 1] = tok("id", i, j)
        else
          kids[#kids + 1] = tok("id", i, j)
        end
        i = j
      elseif c == "'" then
        local j
        if text:sub(i + 1, i + 1) == "\\" then
          local a = text:find("'", i + 3, true)
          j = a and (a + 1) or (n + 1)
          kids[#kids + 1] = tok("lit", i, j)
        elseif text:find("^'[%z\1-\127]'", i) then
          j = i + 3
          kids[#kids + 1] = tok("lit", i, j)
        elseif text:find("^'[\194-\244][\128-\191]*'", i) then
          j = i + #text:match("^'[\194-\244][\128-\191]*'", i)
          kids[#kids + 1] = tok("lit", i, j)
        elseif text:find("^'[%a_]", i) then
          j = i + #text:match("^'[%w_]+", i)
          kids[#kids + 1] = tok("life", i, j)
        else
          j = i + 1
          kids[#kids + 1] = tok("p", i, j)
        end
        i = j
      elseif c:find("%d") then
        local j = i + #text:match("^%d[%w_]*", i)
        while text:find("^%.%d", j) do
          j = j + #text:match("^%.%d[%w_]*", j)
        end
        kids[#kids + 1] = tok("lit", i, j)
        i = j
      elseif CLOSER[c] then
        local inner, j, closed = run(i + 1, CLOSER[c])
        local g = tok("group", i, closed and j or (n + 1), { d = c, kids = inner, open = not closed })
        if closed then
          g.cr, g.cc = rc(j - 1)
        end
        kids[#kids + 1] = g
        i = j
      elseif c == ")" or c == "]" or c == "}" then
        if c == close then
          return kids, i + 1, true
        end
        kids[#kids + 1] = tok("p", i, i + 1)
        i = i + 1
      else
        local w = 1
        if PUNCT3[text:sub(i, i + 2)] then
          w = 3
        elseif PUNCT2[text:sub(i, i + 1)] then
          w = 2
        end
        kids[#kids + 1] = tok("p", i, i + w)
        i = i + w
      end
    end
    return kids, n + 1, false
  end
  return (run(1, nil))
end

local function is_p(t, s)
  return t ~= nil and t.t == "p" and t.s == s
end

local function is_str(t)
  return t ~= nil and t.t == "str" and t.s:find('^[bcr]*#*"') ~= nil
end

--- The text of a string literal token without quotes and, for non-raw strings,
--- without `\u{...}` escapes (their braces are not placeholders).
function M.string_content(s)
  local prefix, hashes = s:match('^([bcr]*)(#*)"')
  if not prefix then
    return nil
  end
  local body = s:sub(#prefix + #hashes + 2)
  local tail = '"' .. hashes
  if body:sub(-#tail) == tail then
    body = body:sub(1, -#tail - 1)
  end
  if not prefix:find("r", 1, true) then
    body = body:gsub("\\u%b{}", "")
  end
  return body
end

--- Split the tokens of a group at top-level commas: { {tok, ...}, ... }. A
--- trailing comma adds no empty argument.
function M.split_args(kids)
  local args, cur = {}, {}
  for _, t in ipairs(kids) do
    if is_p(t, ",") then
      args[#args + 1] = cur
      cur = {}
    else
      cur[#cur + 1] = t
    end
  end
  if #cur > 0 then
    args[#args + 1] = cur
  end
  return args
end

--- Every `name!(...)` call of a token list, nested ones included:
--- cb({ name, path (first segment of `a::b::name!` or nil), id = token, group = token })
local function each_call(tokens, cb)
  for k, t in ipairs(tokens) do
    if t.t == "id" and is_p(tokens[k + 1], "!") and tokens[k + 2] and tokens[k + 2].t == "group" then
      local path
      if is_p(tokens[k - 1], "::") and tokens[k - 2] and tokens[k - 2].t == "id" then
        local j = k - 2
        while is_p(tokens[j - 1], "::") and tokens[j - 2] and tokens[j - 2].t == "id" do
          j = j - 2
        end
        path = tokens[j].s
      end
      cb({ name = t.s, path = path, id = t, group = tokens[k + 2] })
    end
    if t.t == "group" then
      each_call(t.kids, cb)
    end
  end
end
M.each_call = each_call

-- ============================================================ format strings

--- The placeholders of a format string (the content, not the literal):
--- { count, implicit (arguments taken by `{}` / `.*`), explicit = set of
--- indexes, names = set, max_explicit, needs } or nil, reason when the string
--- is malformed (rustc reports those itself).
function M.parse_format(s)
  local info = { count = 0, implicit = 0, explicit = {}, names = {}, max_explicit = -1 }
  local i = 1
  while true do
    local p = s:find("[{}]", i)
    if not p then
      break
    end
    local c = s:sub(p, p)
    if c == "{" and s:sub(p + 1, p + 1) == "{" then
      i = p + 2
    elseif c == "}" then
      if s:sub(p + 1, p + 1) ~= "}" then
        return nil, "unmatched }"
      end
      i = p + 2
    else
      local q = s:find("}", p + 1, true)
      if not q then
        return nil, "unmatched {"
      end
      local inner = s:sub(p + 1, q - 1)
      local arg, spec = inner:match("^([^:]*):?(.*)$")
      arg = vim.trim(arg)
      info.count = info.count + 1
      for ref in spec:gmatch("([%w_]+)%$") do
        if ref:find("^%d+$") then
          local ix = tonumber(ref)
          info.explicit[ix] = true
          info.max_explicit = math.max(info.max_explicit, ix)
        else
          info.names[ref] = true
        end
      end
      if spec:find(".*", 1, true) then
        info.implicit = info.implicit + 1
      end
      if arg == "" then
        info.implicit = info.implicit + 1
      elseif arg:find("^%d+$") then
        local ix = tonumber(arg)
        info.explicit[ix] = true
        info.max_explicit = math.max(info.max_explicit, ix)
      elseif arg:find("^[%a_][%w_]*$") then
        info.names[arg] = true
      end
      i = q + 1
    end
  end
  info.needs = math.max(info.implicit, info.max_explicit + 1)
  return info
end

-- macro -> index of the format string among its top-level arguments
local FORMAT_AT = {
  println = 0, print = 0, eprintln = 0, eprint = 0, format = 0, format_args = 0, panic = 0,
  unreachable = 0, todo = 0, unimplemented = 0,
  write = 1, writeln = 1, assert = 1, debug_assert = 1,
  assert_eq = 2, assert_ne = 2, debug_assert_eq = 2, debug_assert_ne = 2,
}
-- tracing/log: fields first, the message is the first argument that is only a
-- string literal
local TRACING = { trace = true, debug = true, info = true, warn = true, error = true }
local SQLX_AT = {
  query = 0, query_unchecked = 0, query_scalar = 0, query_scalar_unchecked = 0,
  query_as = 1, query_as_unchecked = 1,
}

--- Where the format string of `call` is among its arguments (0-based index),
--- or nil when the macro has none.
local function format_index(call, args)
  if FORMAT_AT[call.name] and (call.path == nil or call.path == "std" or call.path == "core") then
    return FORMAT_AT[call.name]
  end
  if TRACING[call.name] and (call.path == nil or call.path == "tracing" or call.path == "log") then
    for k, a in ipairs(args) do
      if #a == 1 and is_str(a[1]) then
        return k - 1
      end
    end
  end
end

local function range_of(tokens)
  local a, b = tokens[1], tokens[#tokens]
  return { sr = a.sr, sc = a.sc, er = b.er, ec = b.ec }
end

--- Placeholder count against the arguments of a call. Returns nil when the
--- macro has no format string (or it is not a plain literal), else
--- { idx, info, positional = {arg...}, named = {{name, arg}...}, given, needs }.
function M.format_info(call)
  local args = M.split_args(call.group.kids)
  local idx = format_index(call, args)
  local fa = idx and args[idx + 1]
  if not fa or #fa ~= 1 or not is_str(fa[1]) or fa[1].s:find("^b") then
    return nil
  end
  local info = M.parse_format(M.string_content(fa[1].s))
  if not info then
    return nil
  end
  local positional, named = {}, {}
  for k = idx + 2, #args do
    local a = args[k]
    if #a >= 3 and a[1].t == "id" and is_p(a[2], "=") then
      named[#named + 1] = { name = a[1].s, arg = a }
    else
      positional[#positional + 1] = a
    end
  end
  return {
    idx = idx,
    info = info,
    fmt = fa[1],
    positional = positional,
    named = named,
    given = #positional + #named,
    needs = info.needs,
  }
end

--- Hints for one call: { kind = "missing"|"unused"|"sql", message, needs, given,
--- sr, sc, er, ec, fixable }.
local function call_hints(call)
  local out = {}
  local fi = M.format_info(call)
  if fi then
    local P, Nn = #fi.positional, #fi.named
    if fi.needs > P + Nn then
      local miss = fi.needs - P - Nn
      out[#out + 1] = vim.tbl_extend("force", range_of({ fi.fmt }), {
        kind = "missing",
        needs = fi.needs,
        given = P + Nn,
        add = miss,
        fixable = Nn == 0,
        message = ("format string needs %d argument%s, %d given"):format(fi.needs, fi.needs == 1 and "" or "s", P + Nn),
      })
    else
      for i = 0, P - 1 do
        if i >= fi.info.implicit and not fi.info.explicit[i] then
          out[#out + 1] = vim.tbl_extend("force", range_of(fi.positional[i + 1]), {
            kind = "unused",
            needs = fi.needs,
            given = P + Nn,
            message = "argument is never used by the format string",
          })
        end
      end
      for k, nm in ipairs(fi.named) do
        local pos = P + k - 1
        if not fi.info.names[nm.name] and not (pos < fi.info.implicit or fi.info.explicit[pos]) then
          out[#out + 1] = vim.tbl_extend("force", range_of(nm.arg), {
            kind = "unused",
            needs = fi.needs,
            given = P + Nn,
            message = ("named argument `%s` is never used by the format string"):format(nm.name),
          })
        end
      end
    end
    return out
  end
  -- sqlx::query!("... $1 ... $2", a, b) / query_as!(T, "...", a)
  local sql_at = SQLX_AT[call.name]
  if sql_at and (call.path == nil or call.path == "sqlx") then
    local args = M.split_args(call.group.kids)
    local sa = args[sql_at + 1]
    if sa and #sa == 1 and is_str(sa[1]) then
      local binds = M.sql_binds(M.string_content(sa[1].s))
      local given = #args - sql_at - 1
      if binds ~= given then
        out[#out + 1] = vim.tbl_extend("force", range_of(sa), {
          kind = "sql",
          needs = binds,
          given = given,
          message = ("SQL binds %d parameter%s, %d argument%s given"):format(binds, binds == 1 and "" or "s", given, given == 1 and "" or "s"),
        })
      end
    end
  end
  return out
end

--- Bind parameters of an SQL text: the highest `$n` (postgres), else the
--- number of `?` (mysql, sqlite). Quoted text and `--` comments are ignored.
function M.sql_binds(sql)
  sql = sql:gsub("%-%-[^\n]*", ""):gsub("'[^']*'", "''")
  local max = 0
  for d in sql:gmatch("%$(%d+)") do
    max = math.max(max, tonumber(d))
  end
  if max > 0 then
    return max
  end
  local _, q = sql:gsub("%?", "")
  return q
end

--- All hints of a Rust text (a whole buffer): see call_hints. Each hint also
--- has the closing position of its call (cr, cc) and `trailing` (the call
--- ends in a comma), which the fix needs.
function M.hints(text)
  local out = {}
  each_call(M.lex(text), function(call)
    for _, h in ipairs(call_hints(call)) do
      h.macro = call.name
      h.cr, h.cc = call.group.cr, call.group.cc
      local last = call.group.kids[#call.group.kids]
      h.trailing = is_p(last, ",")
      -- where an added argument goes: right after the last token, not before
      -- a closing delimiter that sits on a line of its own
      h.lr, h.lc = last and last.er or h.cr, last and last.ec or h.cc
      out[#out + 1] = h
    end
  end)
  return out
end

-- ================================================================ diagnostics

local ns = vim.api.nvim_create_namespace("xynovim_macro_hints")
M.ns = ns
local MAX_SCAN_BYTES = 400000

--- Run the scan of `bufnr` now and publish the hint diagnostics.
function M.refresh_hints(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "rust" then
    return
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  if #text > MAX_SCAN_BYTES then
    return vim.diagnostic.reset(ns, bufnr)
  end
  local ds = {}
  for _, h in ipairs(M.hints(text)) do
    ds[#ds + 1] = {
      lnum = h.sr,
      col = h.sc,
      end_lnum = h.er,
      end_col = h.ec,
      severity = vim.diagnostic.severity.HINT,
      source = "xynovim-macro",
      code = h.kind,
      message = h.message .. (h.fixable and " (:MacroFormatFix adds it)" or ""),
      user_data = { hint = h },
    }
  end
  vim.diagnostic.set(ns, bufnr, ds)
end

local timers = {}
local function schedule_hints(bufnr)
  local t = timers[bufnr]
  if not t then
    t = uv.new_timer()
    timers[bufnr] = t
  end
  t:stop()
  t:start(
    300,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.refresh_hints(bufnr)
      end
    end)
  )
end

--- :MacroFormatFix - append the missing arguments (`todo!()`) of the format
--- macro call around the cursor. Returns the number of arguments added.
function M.format_fix(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  M.refresh_hints(bufnr)
  local cur = vim.api.nvim_win_get_cursor(0)
  local row = cur[1] - 1
  local best
  for _, d in ipairs(vim.diagnostic.get(bufnr, { namespace = ns })) do
    local h = d.user_data and d.user_data.hint
    if h and h.kind == "missing" and h.fixable and h.cr then
      -- the call spans from the format string's line to its closing delimiter
      if row >= h.sr and row <= h.cr then
        if not best or h.sr >= best.sr then
          best = h
        end
      end
    end
  end
  if not best then
    vim.notify("no missing format argument at the cursor", vim.log.levels.INFO)
    return 0
  end
  local fill = {}
  for _ = 1, best.add do
    fill[#fill + 1] = "todo!()"
  end
  local text = table.concat(fill, ", ")
  text = best.trailing and (" " .. text .. ",") or (", " .. text)
  vim.api.nvim_buf_set_text(bufnr, best.lr, best.lc, best.lr, best.lc, { text })
  M.refresh_hints(bufnr)
  return best.add
end

-- ============================================================== macro_rules!
-- Matcher arms parsed with treesitter, matched against the typed arguments.

local FRAGMENT_DOC = {
  expr = "an expression",
  ty = "a type",
  ident = "an identifier",
  path = "a path (a::b)",
  pat = "a pattern",
  pat_param = "a pattern without a top-level |",
  stmt = "a statement",
  block = "a { block }",
  item = "an item (fn, struct, impl, ...)",
  meta = "the inside of an attribute",
  tt = "one token tree (a token or a delimited group)",
  lifetime = "a lifetime ('a)",
  literal = "a literal",
  vis = "a visibility (pub, may be empty)",
}
M.fragment_doc = FRAGMENT_DOC

-- Definitions of std macros for when the definition cannot be found (no
-- rust-src component): the arms only, enough for the popup.
local FALLBACK = {
  vec = "macro_rules! vec { () => (); ($elem:expr; $n:expr) => (); ($($x:expr),+ $(,)?) => (); }",
  matches = "macro_rules! matches { ($expression:expr, $pattern:pat $(if $guard:expr)? $(,)?) => {}; }",
  dbg = "macro_rules! dbg { () => {}; ($val:expr $(,)?) => {}; ($($val:expr),+ $(,)?) => {}; }",
}

local function same_tok(a, b)
  return a.t == b.t and a.s == b.s
end

--- Matcher tokens -> elements { k = "frag"|"lit"|"group"|"rep" }.
local function compile(toks)
  local out, i = {}, 1
  while i <= #toks do
    local t = toks[i]
    local nx = toks[i + 1]
    if is_p(t, "$") and nx and nx.t == "id" and is_p(toks[i + 2], ":") and toks[i + 3] and toks[i + 3].t == "id" then
      out[#out + 1] = { k = "frag", name = nx.s, spec = toks[i + 3].s }
      i = i + 4
    elseif is_p(t, "$") and nx and nx.t == "group" and nx.d == "(" then
      local j = i + 2
      local a, b = toks[j], toks[j + 1]
      local function op(x)
        return x and x.t == "p" and (x.s == "*" or x.s == "+" or x.s == "?") and x.s or nil
      end
      local sep, o
      if op(a) then
        o, j = op(a), j + 1
      elseif a and op(b) then
        sep, o, j = a, op(b), j + 2
      end
      if o then
        out[#out + 1] = { k = "rep", inner = compile(nx.kids), sep = sep, op = o }
        i = j
      else
        out[#out + 1] = { k = "lit", tok = t }
        i = i + 1
      end
    elseif t.t == "group" then
      out[#out + 1] = { k = "group", d = t.d, kids = compile(t.kids) }
      i = i + 1
    else
      out[#out + 1] = { k = "lit", tok = t }
      i = i + 1
    end
  end
  return out
end
M.compile_matcher = function(text)
  return compile(M.lex(text))
end

local function nullable(e)
  if e.k == "rep" then
    if e.op ~= "+" then
      return true
    end
    for _, x in ipairs(e.inner) do
      if not nullable(x) then
        return false
      end
    end
    return true
  end
  return e.k == "frag" and e.spec == "vis"
end

local function rest_nullable(elems, ei)
  for k = ei, #elems do
    if not nullable(elems[k]) then
      return false
    end
  end
  return true
end

local function is_literal_tok(t)
  return t.t == "lit" or t.t == "str" or (t.t == "id" and (t.s == "true" or t.s == "false"))
end

-- run-length fragments: the tokens one may contain, per fragment kind
local TYPE_PUNCT = { ["::"] = true, ["<"] = true, [">"] = true, [">>"] = true, ["&"] = true, ["*"] = true, ["!"] = true, [","] = true, ["->"] = true, ["?"] = true, ["+"] = true, ["="] = true, ["dyn"] = true }
local function run_ok(spec, t, depth)
  if (spec == "ty" or spec == "path") and (t.t == "str" or (t.t == "group" and t.d == "{") or (t.t == "p" and not TYPE_PUNCT[t.s])) then
    return false
  end
  if t.t == "p" then
    if spec ~= "item" then
      if t.s == ";" or t.s == "=>" then
        return false
      end
      if t.s == "," and depth <= 0 then
        return false
      end
    end
  end
  return true
end

local match_seq

--- 2 complete, 1 viable (more input may complete it), 0 no.
local function match_elem_group(e, tok, budget)
  if tok.t ~= "group" or tok.d ~= e.d then
    return 0
  end
  local r = match_seq(e.kids, 1, tok.kids, 1, function(ti)
    return ti == #tok.kids + 1 and 2 or 0
  end, budget)
  if tok.open then
    return r > 0 and 1 or 0
  end
  return r == 2 and 2 or 0
end

local RUN = { expr = true, ty = true, pat = true, pat_param = true, path = true, stmt = true, item = true, meta = true }

match_seq = function(elems, ei, toks, ti, cont, budget)
  budget.n = budget.n - 1
  if budget.n < 0 then
    return 1
  end
  if ei > #elems then
    return cont(ti)
  end
  if ti > #toks then
    if rest_nullable(elems, ei) then
      return cont(ti)
    end
    return 1
  end
  local e, t = elems[ei], toks[ti]
  if e.k == "lit" then
    if same_tok(e.tok, t) then
      return match_seq(elems, ei + 1, toks, ti + 1, cont, budget)
    end
    return 0
  elseif e.k == "group" then
    local r = match_elem_group(e, t, budget)
    if r == 0 then
      return 0
    elseif r == 1 then
      return 1
    end
    return match_seq(elems, ei + 1, toks, ti + 1, cont, budget)
  elseif e.k == "frag" then
    local spec = e.spec
    local single
    if spec == "tt" then
      single = true
    elseif spec == "ident" then
      single = t.t == "id"
    elseif spec == "lifetime" then
      single = t.t == "life"
    elseif spec == "block" then
      single = t.t == "group" and t.d == "{"
    elseif spec == "literal" then
      if is_p(t, "-") and toks[ti + 1] then
        if is_literal_tok(toks[ti + 1]) then
          return match_seq(elems, ei + 1, toks, ti + 2, cont, budget)
        end
        return 0
      end
      single = is_literal_tok(t)
    elseif spec == "vis" then
      local best = match_seq(elems, ei + 1, toks, ti, cont, budget)
      if best < 2 and t.t == "id" and t.s == "pub" then
        local used = (toks[ti + 1] and toks[ti + 1].t == "group" and toks[ti + 1].d == "(") and 2 or 1
        best = math.max(best, match_seq(elems, ei + 1, toks, ti + used, cont, budget))
      end
      return best
    end
    if single ~= nil then
      if single then
        return match_seq(elems, ei + 1, toks, ti + 1, cont, budget)
      end
      return 0
    end
    if RUN[spec] then
      local best, depth = 0, 0
      for len = 1, #toks - ti + 1 do
        local tk = toks[ti + len - 1]
        if spec == "ty" or spec == "path" then
          if is_p(tk, "<") then
            depth = depth + 1
          elseif is_p(tk, ">") then
            depth = depth - 1
          elseif is_p(tk, ">>") then
            depth = depth - 2
          end
        end
        if not run_ok(spec, tk, depth) then
          break
        end
        local r = match_seq(elems, ei + 1, toks, ti + len, cont, budget)
        if r > best then
          best = r
          if best == 2 then
            break
          end
        end
      end
      return best
    end
    -- an unknown fragment kind: take one token
    return match_seq(elems, ei + 1, toks, ti + 1, cont, budget)
  else -- rep
    local best = 0
    if e.op ~= "+" then
      best = match_seq(elems, ei + 1, toks, ti, cont, budget)
      if best == 2 then
        return 2
      end
    end
    local function iter(tj)
      return match_seq(e.inner, 1, toks, tj, function(tk)
        local r = match_seq(elems, ei + 1, toks, tk, cont, budget)
        if r == 2 or e.op == "?" or tk > #toks then
          return r
        end
        local nxt = tk
        if e.sep then
          if toks[tk] and same_tok(toks[tk], e.sep) then
            nxt = tk + 1
          else
            return r
          end
        end
        if nxt == tj then
          return r
        end
        return math.max(r, iter(nxt))
      end, budget)
    end
    return math.max(best, iter(ti))
  end
end

--- How the typed argument tokens fit one compiled arm: 2, 1 or 0.
function M.match_arm(elems, toks)
  return match_seq(elems, 1, toks, 1, function(ti)
    return ti == #toks + 1 and 2 or 0
  end, { n = 20000 })
end

--- Which arms fit `toks`: { results = {0|1|2 per arm}, best = index|nil }.
--- best is the first complete arm, else the first viable one.
function M.match_arms(def, toks)
  local results, best, viable = {}, nil, nil
  for i, arm in ipairs(def.arms) do
    local r = M.match_arm(arm.elems, toks)
    results[i] = r
    if r == 2 and not best then
      best = i
    end
    if r >= 1 and not viable then
      viable = i
    end
  end
  return { results = results, best = best or viable }
end

local function macro_def_at(root, src, row, col)
  local node = root:named_descendant_for_range(row, col, row, col)
  while node and node:type() ~= "macro_definition" do
    node = node:parent()
  end
  return node
end

local function def_of_node(node, src)
  local name_node = node:field("name")[1]
  local def = { name = name_node and vim.treesitter.get_node_text(name_node, src) or "?", arms = {}, row = node:range() }
  for child in node:iter_children() do
    if child:type() == "macro_rule" then
      local left = child:field("left")[1]
      if left then
        local text = vim.treesitter.get_node_text(left, src)
        local open, inner = text:sub(1, 1), text:sub(2, -2)
        def.arms[#def.arms + 1] = {
          delim = CLOSER[open] and open or "(",
          matcher = vim.trim((inner:gsub("%s+", " "))),
          elems = compile(M.lex(inner)),
        }
      end
    end
  end
  return def
end

--- The macro_rules! definition whose name is at row, col (0-based) of the
--- Rust text `src`; with row nil, the first definition named `name`. Returns
--- { name, arms = { {delim, matcher, elems} }, row } or nil.
function M.parse_macro_def(src, row, col, name)
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, "rust")
  if not ok then
    return nil
  end
  local root = parser:parse()[1]:root()
  if row then
    local node = macro_def_at(root, src, row, col or 0)
    return node and def_of_node(node, src) or nil
  end
  local function find(n)
    if n:type() == "macro_definition" then
      local nn = n:field("name")[1]
      if nn and vim.treesitter.get_node_text(nn, src) == name then
        return n
      end
    end
    for c in n:iter_children() do
      local f = find(c)
      if f then
        return f
      end
    end
  end
  local node = find(root)
  return node and def_of_node(node, src) or nil
end

--- Fragments `$name:kind` of an arm matcher: { {name, spec}... } (unique by
--- name, in order).
function M.fragments(matcher)
  local out, seen = {}, {}
  for name, spec in matcher:gmatch("%$([%w_]+)%s*:%s*([%w_]+)") do
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = { name = name, spec = spec }
    end
  end
  return out
end

-- ================================================================ call context

--- The macro call the text ends in (the text is everything before the
--- cursor): { name, path, id, group (open) | nil when only `name!` was typed,
--- innermost (the macro's group is the innermost open group), pending }.
function M.context_before(text, opts)
  local toks = M.lex(text, opts)
  local chain = {} -- open groups, outermost first, with the token list they sit in
  local list = toks
  while true do
    local last = list[#list]
    if last and last.t == "group" and last.open then
      chain[#chain + 1] = { group = last, list = list, index = #list }
      list = last.kids
    else
      break
    end
  end
  -- `name!` typed, nothing after it yet
  local last = list[#list]
  if is_p(last, "!") and list[#list - 1] and list[#list - 1].t == "id" then
    local id = list[#list - 1]
    return { name = id.s, id = id, pending = true, innermost = true }
  end
  for depth = #chain, 1, -1 do
    local link = chain[depth]
    local k = link.index
    local sib = link.list
    if is_p(sib[k - 1], "!") and sib[k - 2] and sib[k - 2].t == "id" then
      local id = sib[k - 2]
      local path
      if is_p(sib[k - 3], "::") and sib[k - 4] and sib[k - 4].t == "id" then
        local j = k - 4
        while is_p(sib[j - 1], "::") and sib[j - 2] and sib[j - 2].t == "id" do
          j = j - 2
        end
        path = sib[j].s
      end
      return { name = id.s, path = path, id = id, group = link.group, innermost = depth == #chain }
    end
  end
  return nil
end

-- ================================================================ popup text

--- Popup lines for a macro definition and the typed tokens: { lines, active
--- (line index of the best arm, 1-based) | nil, arms = lines of arms }.
function M.popup(name, def, toks, extra)
  local m = M.match_arms(def, toks or {})
  local lines, marks = {}, {}
  local any = false
  for i, arm in ipairs(def.arms) do
    local close = ({ ["("] = ")", ["["] = "]", ["{"] = "}" })[arm.delim]
    local body = arm.matcher == "" and "" or (" " .. arm.matcher .. " ")
    local viable = m.results[i] >= 1
    any = any or viable
    lines[#lines + 1] = (i == m.best and "> " or "  ") .. name .. "!" .. arm.delim .. body .. close
    marks[#marks + 1] = { line = #lines, best = i == m.best, viable = viable }
  end
  local arms_n = #lines
  -- fragment legend: the best arm's; every viable arm when that one has no
  -- fragments (the empty arm of vec!) or nothing fits yet
  local best_has = m.best and #M.fragments(def.arms[m.best].matcher) > 0
  local seen, legend = {}, {}
  for i, arm in ipairs(def.arms) do
    if (best_has and i == m.best) or (not best_has and (m.results[i] >= 1 or not m.best)) then
      for _, f in ipairs(M.fragments(arm.matcher)) do
        local key = f.name .. ":" .. f.spec
        if not seen[key] then
          seen[key] = true
          legend[#legend + 1] = ("$%s: %s - %s"):format(f.name, f.spec, FRAGMENT_DOC[f.spec] or "fragment")
        end
      end
    end
  end
  if #legend > 0 then
    lines[#lines + 1] = ""
    vim.list_extend(lines, legend)
  end
  if extra then
    lines[#lines + 1] = ""
    vim.list_extend(lines, extra)
  end
  if not m.best and #toks > 0 and not any then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "no arm fits the arguments typed so far"
  end
  return { lines = lines, marks = marks, best = m.best, arms = arms_n }
end

-- ============================================================= signature help

local LSP_DEF_TIMEOUT = 5000
local sig = { win = nil, buf = nil, seq = 0, key = nil, def = nil, label = nil }

local function close_popup()
  if sig.win and vim.api.nvim_win_is_valid(sig.win) then
    pcall(vim.api.nvim_win_close, sig.win, true)
  end
  sig.win = nil
  sig.key = nil
  sig.def = nil
end
M.close_popup = close_popup

--- The popup window while it is open (specs read it).
function M.popup_win()
  return sig.win and vim.api.nvim_win_is_valid(sig.win) and sig.win or nil
end

local function lsp_character(bufnr, row, col, enc)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local ok, ch = pcall(vim.str_utfindex, line, enc, math.min(col, #line), false)
  return ok and ch or col
end

local function ra_client(bufnr)
  return require("config.code_actions").clients(bufnr)[1]
end

--- Lines of a file (an open buffer wins over the disk), nil when unreadable or huge.
local function file_text(fname)
  local b = vim.fn.bufnr(fname)
  if b > 0 and vim.api.nvim_buf_is_loaded(b) then
    return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  end
  local st = uv.fs_stat(fname)
  if not st or st.type ~= "file" or st.size > 3000000 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, fname)
  return ok and table.concat(lines, "\n") or nil
end

--- Resolve the macro_rules! definition behind the name at (row, col) of
--- `bufnr` through textDocument/definition. cb(def, where) or cb(nil, reason).
function M.find_definition(bufnr, row, col, name, cb)
  local client = ra_client(bufnr)
  local function fallback(reason)
    if FALLBACK[name] then
      return cb(M.parse_macro_def(FALLBACK[name], nil, nil, name), "built-in table")
    end
    cb(nil, reason)
  end
  if not client then
    return fallback("no rust-analyzer client")
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = row, character = lsp_character(bufnr, row, col, client.offset_encoding or "utf-16") },
  }
  client:request("textDocument/definition", params, function(err, result)
    if err or not result or (vim.islist(result) and #result == 0) then
      return fallback("no definition found")
    end
    local loc = vim.islist(result) and result[1] or result
    local uri = loc.targetUri or loc.uri
    local range = loc.targetSelectionRange or loc.range
    if not uri or not range then
      return fallback("no definition found")
    end
    local fname = vim.uri_to_fname(uri)
    local src = file_text(fname)
    if not src then
      return fallback("cannot read " .. fname)
    end
    local def = M.parse_macro_def(src, range.start.line, range.start.character)
    if not def or #def.arms == 0 then
      return fallback("not a macro_rules! macro (a proc macro has no matcher arms)")
    end
    local home = vim.env.HOME or ""
    local short = fname:gsub("^" .. vim.pesc(home), "~"):gsub("^.*/library/", "")
    cb(def, ("%s:%d"):format(short, def.row + 1))
  end, bufnr)
end

local function open_popup(lines, marks)
  if not (sig.buf and vim.api.nvim_buf_is_valid(sig.buf)) then
    sig.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[sig.buf].bufhidden = "wipe"
  end
  vim.bo[sig.buf].modifiable = true
  vim.api.nvim_buf_set_lines(sig.buf, 0, -1, false, lines)
  vim.bo[sig.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(sig.buf, ns, 0, -1)
  for _, mk in ipairs(marks or {}) do
    vim.api.nvim_buf_set_extmark(sig.buf, ns, mk.line - 1, 0, {
      line_hl_group = mk.best and "PmenuSel" or nil,
      end_row = mk.line - 1,
      hl_group = (not mk.best and not mk.viable) and "Comment" or nil,
      end_col = (not mk.best and not mk.viable) and #lines[mk.line] or nil,
    })
  end
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width, math.max(30, vim.o.columns - 6))
  local height = math.min(#lines, 14)
  local below = vim.fn.winline() + height + 3 < vim.o.lines
  local cfg = {
    relative = "cursor",
    row = below and 1 or 0,
    col = 0,
    width = width,
    height = height,
    anchor = below and "NW" or "SW",
    style = "minimal",
    focusable = false,
    noautocmd = true,
    border = vim.o.winborder ~= "" and vim.o.winborder or "rounded",
  }
  if sig.win and vim.api.nvim_win_is_valid(sig.win) then
    vim.api.nvim_win_set_config(sig.win, cfg)
    vim.api.nvim_win_set_buf(sig.win, sig.buf)
  else
    sig.win = vim.api.nvim_open_win(sig.buf, false, cfg)
    vim.wo[sig.win].wrap = false
    vim.wo[sig.win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder"
  end
end

local function extra_lines(ctx, toks)
  -- a format/sql macro also tells how its placeholders and arguments line up
  local g = ctx.group
  if not g then
    return nil
  end
  local call = { name = ctx.name, path = ctx.path, group = g }
  local fi = M.format_info(call)
  if fi then
    return { ("format: %d placeholder%s, %d argument%s given"):format(fi.needs, fi.needs == 1 and "" or "s", fi.given, fi.given == 1 and "" or "s") }
  end
end

--- Show (or refresh) the macro popup for the call before the cursor.
--- opts.manual: <C-k> / :MacroSignature (also reports why nothing shows).
function M.signature(bufnr, opts)
  opts = opts or {}
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1] - 1, cur[2]
  local first = math.max(0, row - 300)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first, row + 1, false)
  if #lines == 0 then
    return
  end
  lines[#lines] = lines[#lines]:sub(1, col)
  local ctx = M.context_before(table.concat(lines, "\n"), { row0 = first })
  if not ctx or not (ctx.innermost or opts.manual) then
    if opts.manual and not ctx then
      return vim.lsp.buf.signature_help()
    end
    return close_popup()
  end
  local toks = ctx.group and ctx.group.kids or {}
  local key = ("%d:%d:%d:%s"):format(bufnr, ctx.id.sr, ctx.id.sc, ctx.name)
  local function render(def, where)
    if sig.key ~= key then
      return
    end
    local view = M.popup(ctx.name, def, toks, extra_lines(ctx, toks))
    local head = ctx.name .. "!" .. (where and ("  " .. where) or "")
    table.insert(view.lines, 1, head)
    for _, mk in ipairs(view.marks) do
      mk.line = mk.line + 1
    end
    open_popup(view.lines, view.marks)
  end
  if sig.key == key and sig.def then
    return render(sig.def, sig.where)
  end
  sig.key, sig.def = key, nil
  sig.seq = sig.seq + 1
  local seq = sig.seq
  local function request()
    if seq ~= sig.seq or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    M.find_definition(bufnr, ctx.id.sr, math.max(ctx.id.ec - 1, ctx.id.sc), ctx.name, function(def, where)
      if seq ~= sig.seq then
        return
      end
      if not def then
        if opts.manual then
          vim.notify(ctx.name .. "!: " .. tostring(where), vim.log.levels.INFO)
        end
        return close_popup()
      end
      sig.def, sig.where = def, where
      render(def, where)
    end)
  end
  -- rust-analyzer must have seen the typed `name!` before it can resolve it
  if opts.manual then
    request()
  else
    vim.defer_fn(request, 200)
  end
end

-- ================================================================== snippets
-- A blink.cmp source (provider "macro_tools") for macro arms that rust-analyzer
-- does not complete: tokio::select!, matches!, vec![x; n].

local SNIPPETS = {
  {
    label = "select!",
    filter = "select",
    detail = "tokio::select! with two branches",
    text = "tokio::select! {\n\t${1:res} = ${2:future} => ${3:handler},\n\t${4:other} = ${5:future2} => ${0:handler2},\n}",
  },
  {
    label = "select! (shutdown loop)",
    filter = "select",
    detail = "tokio::select! { cancelled => break, recv => ... }",
    text = "tokio::select! {\n\t_ = ${1:token}.cancelled() => break,\n\t${2:msg} = ${3:rx}.recv() => {\n\t\t${0:todo!()}\n\t}\n}",
  },
  {
    label = "select! (biased)",
    filter = "select",
    detail = "tokio::select! with biased; order",
    text = "tokio::select! {\n\tbiased;\n\t${1:res} = ${2:future} => ${3:handler},\n\t${4:other} = ${5:future2} => ${0:handler2},\n}",
  },
  {
    label = "matches!",
    filter = "matches",
    detail = "matches!(expr, Pattern)",
    text = "matches!(${1:expr}, ${2:Pattern})",
  },
  {
    label = "matches! (guard)",
    filter = "matches",
    detail = "matches!(expr, Pattern if guard)",
    text = "matches!(${1:expr}, ${2:Pattern} if ${3:cond})",
  },
  {
    label = "vec![x; n]",
    filter = "vec",
    detail = "vec![value; len]",
    text = "vec![${1:value}; ${2:len}]",
  },
}
M.snippets = SNIPPETS

local Source = {}
Source.__index = Source

--- blink.cmp calls module.new(opts) for a provider with module = "config.macro_tools".
function M.new(opts)
  return setmetatable({ opts = opts or {} }, Source)
end

function Source:enabled()
  return vim.bo.filetype == "rust"
end

function Source:get_completions(ctx, callback)
  local ok, ux = pcall(require, "config.ux")
  if ok and ux.snippets_allowed and not ux.snippets_allowed(ctx) then
    return callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
  end
  local kinds = vim.lsp.protocol.CompletionItemKind
  local items = {}
  for _, s in ipairs(SNIPPETS) do
    items[#items + 1] = {
      label = s.label,
      filterText = s.filter,
      kind = kinds.Snippet,
      insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet,
      insertText = s.text,
      detail = s.detail,
      documentation = { kind = "markdown", value = "```rust\n" .. s.text:gsub("%${%d:([^}]*)}", "%1"):gsub("%${0}", "") .. "\n```" },
    }
  end
  callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
  return function() end
end

--- blink.cmp opts: the provider registered and listed as a default source.
function M.blink_opts(_, opts)
  opts.sources = opts.sources or {}
  opts.sources.providers = opts.sources.providers or {}
  opts.sources.providers.macro_tools = {
    name = "Macro",
    module = "config.macro_tools",
    score_offset = -1,
  }
  if type(opts.sources.default) == "table" and not vim.tbl_contains(opts.sources.default, "macro_tools") then
    table.insert(opts.sources.default, "macro_tools")
  end
  return opts
end

-- ====================================================================== lens
-- :MacroExpand - rust-analyzer/expandMacro in a read-only split.

local lens = { win = nil, buf = nil, stack = {}, origin = nil }

--- Top-level items of an expansion: { {label, row (0-based), kind} ... }.
function M.items_of(text)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, "rust")
  if not ok then
    return {}
  end
  local root = parser:parse()[1]:root()
  local out = {}
  local KINDS = {
    function_item = "fn", impl_item = "impl", struct_item = "struct", enum_item = "enum",
    trait_item = "trait", const_item = "const", static_item = "static", type_item = "type", mod_item = "mod",
  }
  local function label(node, src)
    local t = node:type()
    if t == "impl_item" then
      local body = node:field("body")[1]
      local srow, scol = node:range()
      local erow, ecol = (body or node):range()
      local head = vim.split(src, "\n", { plain = true })
      local parts = {}
      for r = srow, erow do
        local l = head[r + 1] or ""
        if r == erow then
          l = l:sub(1, ecol)
        end
        if r == srow then
          l = l:sub(scol + 1)
        end
        parts[#parts + 1] = l
      end
      return vim.trim((table.concat(parts, " "):gsub("%s+", " ")))
    end
    local nm = node:field("name")[1]
    return KINDS[t] .. " " .. (nm and vim.treesitter.get_node_text(nm, src) or "_")
  end
  local function walk(node, depth)
    for c in node:iter_children() do
      if KINDS[c:type()] then
        out[#out + 1] = { label = label(c, text), row = (c:range()), kind = KINDS[c:type()], depth = depth }
        local t = c:type()
        if t == "impl_item" or t == "mod_item" or t == "trait_item" then
          walk(c, depth + 1)
        elseif t == "const_item" then
          walk(c, depth) -- `const _: () = { ... };` (serde) wraps the items
        end
      elseif c:named_child_count() > 0 and c:type() ~= "function_item" then
        walk(c, depth)
      end
    end
  end
  walk(root, 0)
  -- a `const _: () = { ... };` wrapper (serde) is not an item worth listing
  return vim.tbl_filter(function(it)
    return not it.label:find("^const _")
  end, out)
end

--- The first generated item whose name is `word` (fn name, impl for/of it).
function M.find_symbol(items, word)
  if not word or word == "" then
    return nil
  end
  local pat = "%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]"
  for _, it in ipairs(items) do
    if it.kind == "fn" and it.label == "fn " .. word then
      return it
    end
  end
  for _, it in ipairs(items) do
    if it.label:find(pat) then
      return it
    end
  end
end

--- Normalised text of a call's group, for matching the same call elsewhere.
local function call_key(call, lines)
  local g = call.group
  local parts = {}
  for r = g.sr, g.er do
    local l = lines[r + 1] or ""
    local a = r == g.sr and g.sc + 1 or 1
    local b = r == g.er and g.ec or #l
    parts[#parts + 1] = l:sub(a, b)
  end
  return call.name .. "!" .. table.concat(parts, "\n"):gsub("%s+", "")
end

--- The innermost macro call of `text` that contains (row, col) (0-based).
function M.call_at(text, row, col)
  local lines = vim.split(text, "\n", { plain = true })
  local best
  each_call(M.lex(text), function(call)
    local a, b = call.id, call.group
    local before = row > a.sr or (row == a.sr and col >= a.sc)
    local after = row < b.er or (row == b.er and col < b.ec)
    if before and after then
      best = { name = call.name, id = a, group = b, key = call_key(call, lines) } -- inner calls come last
    end
  end)
  return best
end

--- A source call (any call of `text`) with the same name and arguments as
--- `key`, nearest to `near_row`.
function M.find_same_call(text, key, near_row)
  local lines = vim.split(text, "\n", { plain = true })
  local best, dist
  each_call(M.lex(text), function(call)
    if call_key(call, lines) == key then
      local d = math.abs(call.id.sr - near_row)
      if not dist or d < dist then
        best, dist = call, d
      end
    end
  end)
  return best
end

local function winbar_text(parts)
  return table.concat(
    vim.tbl_map(function(p)
      return (p:gsub("%%", "%%%%"))
    end, parts),
    "  |  "
  )
end

local function lens_items()
  return lens.buf and vim.api.nvim_buf_is_valid(lens.buf)
      and M.items_of(table.concat(vim.api.nvim_buf_get_lines(lens.buf, 0, -1, false), "\n"))
    or {}
end

local function lens_render()
  local lvl = lens.stack[#lens.stack]
  if not lvl then
    return
  end
  if not (lens.buf and vim.api.nvim_buf_is_valid(lens.buf)) then
    lens.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[lens.buf].buftype = "nofile"
    vim.bo[lens.buf].bufhidden = "wipe"
    vim.bo[lens.buf].swapfile = false
    local saved = vim.o.eventignore
    vim.o.eventignore = "FileType" -- no rustaceanvim attach on a scratch buffer
    vim.bo[lens.buf].filetype = "rust"
    vim.o.eventignore = saved
    pcall(vim.treesitter.start, lens.buf, "rust")
    M.lens_keys(lens.buf)
  end
  if not (lens.win and vim.api.nvim_win_is_valid(lens.win)) then
    vim.cmd("botright vsplit")
    lens.win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_win_set_buf(lens.win, lens.buf)
  vim.bo[lens.buf].modifiable = true
  vim.api.nvim_buf_set_lines(lens.buf, 0, -1, false, lvl.lines)
  vim.bo[lens.buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, lens.buf, "macro-expansion://" .. lvl.label)
  vim.wo[lens.win].number = false
  vim.wo[lens.win].wrap = false
  vim.wo[lens.win].foldenable = false
  local crumbs = {}
  for _, l in ipairs(lens.stack) do
    crumbs[#crumbs + 1] = l.label
  end
  local items = M.items_of(table.concat(lvl.lines, "\n"))
  local gen = {}
  for i = 1, math.min(3, #items) do
    gen[#gen + 1] = items[i].label
  end
  local parts = { table.concat(crumbs, " > "), ("expanded to %d line%s"):format(#lvl.lines, #lvl.lines == 1 and "" or "s") }
  if lvl.note then
    parts[#parts + 1] = lvl.note
  end
  if #gen > 0 then
    parts[#parts + 1] = "items: " .. table.concat(gen, ", ") .. (#items > 3 and (", +" .. (#items - 3)) or "")
  end
  parts[#parts + 1] = "<CR> step in  <BS> back  gi items  q close"
  vim.wo[lens.win].winbar = winbar_text(parts)
  if lvl.cursor_row then
    pcall(vim.api.nvim_win_set_cursor, lens.win, { math.min(lvl.cursor_row + 1, #lvl.lines), 0 })
  else
    pcall(vim.api.nvim_win_set_cursor, lens.win, { 1, 0 })
  end
end

local function lens_push(level)
  lens.stack[#lens.stack + 1] = level
  lens_render()
  vim.notify(("%s: expanded to %d lines"):format(level.label, #level.lines), vim.log.levels.INFO)
end

function M.lens_back()
  if #lens.stack <= 1 then
    return vim.notify("already at the outermost expansion", vim.log.levels.INFO)
  end
  table.remove(lens.stack)
  lens_render()
end

function M.lens_close()
  if lens.win and vim.api.nvim_win_is_valid(lens.win) then
    pcall(vim.api.nvim_win_close, lens.win, true)
  end
  lens.win, lens.stack = nil, {}
end

function M.lens_items()
  local items = lens_items()
  if #items == 0 then
    return vim.notify("no generated items in this expansion", vim.log.levels.INFO)
  end
  vim.ui.select(items, {
    prompt = "Generated items",
    format_item = function(it)
      return ("%s%s  (line %d)"):format(("  "):rep(it.depth or 0), it.label, it.row + 1)
    end,
  }, function(it)
    if it and lens.win and vim.api.nvim_win_is_valid(lens.win) then
      vim.api.nvim_set_current_win(lens.win)
      vim.api.nvim_win_set_cursor(lens.win, { it.row + 1, 0 })
      vim.cmd("normal! zz")
    end
  end)
end

--- <CR> in the lens: expand the macro call under the cursor of the expansion
--- by finding the same call in the source (rust-analyzer expands from source
--- positions only).
function M.lens_step()
  local origin = lens.origin
  if not (origin and vim.api.nvim_buf_is_valid(origin.bufnr)) then
    return vim.notify("the source buffer is gone", vim.log.levels.WARN)
  end
  local cur = vim.api.nvim_win_get_cursor(0)
  local text = table.concat(vim.api.nvim_buf_get_lines(lens.buf, 0, -1, false), "\n")
  local call = M.call_at(text, cur[1] - 1, cur[2])
  if not call then
    return vim.notify("no macro call under the cursor in the expansion", vim.log.levels.INFO)
  end
  local src = table.concat(vim.api.nvim_buf_get_lines(origin.bufnr, 0, -1, false), "\n")
  local found = M.find_same_call(src, call.key, origin.row)
  if not found then
    return vim.notify(
      ("%s! was generated by the expansion: rust-analyzer only expands macro calls written in the source"):format(call.name),
      vim.log.levels.INFO
    )
  end
  M.expand({
    bufnr = origin.bufnr,
    row = found.id.sr,
    col = found.id.sc + 1,
    push = true,
    step = true,
  })
end

function M.lens_keys(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  map("q", M.lens_close, "Close macro expansion")
  map("<BS>", M.lens_back, "Back to the outer expansion")
  map("<CR>", M.lens_step, "Step into the macro call under the cursor")
  map("gi", M.lens_items, "Generated items")
end

--- Result of rust-analyzer/expandMacro at a position: cb(name, text) or cb(nil, err).
local function request_expand(bufnr, row, col, cb, retry_nil)
  local client = ra_client(bufnr)
  if not client then
    return cb(nil, "no rust-analyzer client attached")
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = row, character = lsp_character(bufnr, row, col, client.offset_encoding or "utf-16") },
  }
  local ask
  local function handle(err, result)
    if err then
      return cb(nil, err.message or "expandMacro failed")
    end
    if not result or not result.expansion or result.expansion == "" then
      -- right after a reload rust-analyzer may answer null for a call it
      -- expands a moment later
      if (retry_nil or 0) > 0 then
        retry_nil = retry_nil - 1
        return vim.defer_fn(ask, 300)
      end
      return cb(nil, nil)
    end
    -- rust-analyzer answers with this text when a proc macro cannot run
    if result.expansion:find("^Expansion had errors") then
      return cb(nil, "rust-analyzer could not expand it: " .. vim.trim((result.expansion:gsub("^Expansion had errors:%s*", ""))) .. " (see :ProcMacroStatus)")
    end
    cb(result.name or "macro", result.expansion)
  end
  -- rust-analyzer answers "content modified" while it reloads after an edit
  local tries = 0
  ask = function()
    client:request("rust-analyzer/expandMacro", params, function(err, result)
      if err and (err.code == -32801 or err.code == -32802) and tries < 8 then
        tries = tries + 1
        return vim.defer_fn(ask, 250)
      end
      handle(err, result)
    end, bufnr)
  end
  ask()
end
M.request_expand = request_expand

--- Positions of the attribute macros / derives of the item at the cursor:
--- { {row, col, label} ... } (the cursor is on the item itself, not on a call).
function M.item_macro_positions(bufnr, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "rust")
  if not ok or not parser then
    return {}
  end
  parser:parse()
  local node = vim.treesitter.get_node({ bufnr = bufnr, pos = { row, col } })
  local ITEM = {
    struct_item = true, enum_item = true, union_item = true, function_item = true, impl_item = true,
    trait_item = true, mod_item = true,
  }
  while node and not ITEM[node:type()] do
    if node:type() == "attribute_item" then
      local nxt = node:next_named_sibling()
      while nxt and nxt:type() == "attribute_item" do
        nxt = nxt:next_named_sibling()
      end
      node = nxt
      break
    end
    node = node:parent()
  end
  if not node then
    return {}
  end
  local out = {}
  local prev = node:prev_named_sibling()
  local attrs = {}
  while prev and (prev:type() == "attribute_item" or prev:type() == "line_comment" or prev:type() == "block_comment") do
    if prev:type() == "attribute_item" then
      table.insert(attrs, 1, prev)
    end
    prev = prev:prev_named_sibling()
  end
  local BUILTIN = {
    allow = true, warn = true, deny = true, forbid = true, cfg = true, cfg_attr = true, doc = true, test = true,
    inline = true, must_use = true, repr = true, derive = false, deprecated = true, expect = true, non_exhaustive = true,
    ["automatically_derived"] = true, no_mangle = true, export_name = true, cold = true, track_caller = true,
  }
  for _, a in ipairs(attrs) do
    local attr = a:named_child(0)
    local path = attr and attr:named_child(0)
    local pname = path and vim.treesitter.get_node_text(path, bufnr) or ""
    if pname == "derive" then
      local tt = attr:named_child(1)
      for c in (tt and tt:iter_children()) or function() end do
        if c:type() == "identifier" or c:type() == "scoped_identifier" then
          local r, cc = c:end_()
          -- end of the name: its last segment is where rust-analyzer finds the derive
          out[#out + 1] = { row = r, col = math.max(cc - 1, 0), label = "derive(" .. vim.treesitter.get_node_text(c, bufnr) .. ")" }
        end
      end
    elseif pname ~= "" and not BUILTIN[pname] then
      local r, cc = path:end_()
      out[#out + 1] = { row = r, col = math.max(cc - 1, 0), label = "#[" .. pname .. "]" }
    end
  end
  return out
end

--- `cargo expand` arguments for a file of a workspace member (nil, reason when
--- the file is no target of the member): { argv, scope }.
function M.expand_argv(member, file)
  local lib, bin
  for _, t in ipairs(member.targets or {}) do
    for _, k in ipairs(t.kind or {}) do
      if k == "lib" or k == "proc-macro" then
        lib = lib or t
      elseif k == "bin" then
        if t.src_path == file then
          bin = t
        end
      end
    end
  end
  local manifest = member.manifest_path
  local base = { "cargo", "expand", "--color", "never", "--manifest-path", manifest }
  local srcdir = lib and vim.fs.dirname(lib.src_path)
  if lib and file == lib.src_path then
    vim.list_extend(base, { "--lib" })
    return base, "the whole library crate"
  end
  if bin then
    vim.list_extend(base, { "--bin", bin.name })
    return base, "the whole binary crate"
  end
  if lib and srcdir and vim.startswith(file, srcdir .. "/") then
    local rel = file:sub(#srcdir + 2):gsub("%.rs$", ""):gsub("/mod$", "")
    local mod = rel:gsub("/", "::")
    if mod:find("^[%w_:]+$") then
      vim.list_extend(base, { "--lib", mod })
      return base, "module " .. mod
    end
  end
  return nil, "the file is not a target of the package"
end

local function cargo_expand_fallback(bufnr, push)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if vim.fn.executable("cargo-expand") ~= 1 then
    return vim.notify("rust-analyzer expanded nothing here and cargo-expand is not installed (cargo install cargo-expand)", vim.log.levels.WARN)
  end
  local cm = require("config.crate_meta")
  cm.metadata_async(file, function(meta, err)
    if not meta then
      return vim.notify("cargo expand fallback: " .. tostring(err), vim.log.levels.WARN)
    end
    local member = cm.member_of(meta, file)
    if not member then
      return vim.notify("cargo expand fallback: the file is not in a workspace member", vim.log.levels.WARN)
    end
    local argv, scope = M.expand_argv(member, file)
    if not argv then
      return vim.notify("cargo expand fallback: " .. scope, vim.log.levels.WARN)
    end
    vim.notify("rust-analyzer expanded nothing: running cargo expand for " .. scope .. " ...", vim.log.levels.INFO)
    vim.system(argv, { text = true, cwd = meta.root, timeout = 180000 }, vim.schedule_wrap(function(r)
      if r.code ~= 0 then
        local msg = vim.trim(r.stderr or "")
        if msg:find("nightly", 1, true) or msg:find("-Z", 1, true) then
          msg = "cargo expand needs a nightly toolchain for this (rustup toolchain install nightly): " .. msg:sub(1, 200)
        end
        return vim.notify("cargo expand failed: " .. msg:sub(1, 400), vim.log.levels.WARN)
      end
      local lines = vim.split(r.stdout, "\n", { plain = true })
      lens.origin = lens.origin or { bufnr = bufnr, row = 0 }
      lens.origin.bufnr = bufnr
      local level = { label = "cargo expand", lines = lines, note = "FALLBACK (cargo expand, " .. scope .. ")" }
      if not push then
        lens.stack = {}
      end
      lens_push(level)
    end))
  end)
end

--- :MacroExpand - expand the macro under the cursor. opts: bufnr, row, col
--- (0-based), push (keep the stack: stepping), step.
function M.expand(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local row, col = opts.row, opts.col
  local word
  if not row then
    local cur = vim.api.nvim_win_get_cursor(0)
    row, col = cur[1] - 1, cur[2]
    word = vim.fn.expand("<cword>")
  end
  if not ra_client(bufnr) then
    return vim.notify("MacroExpand: no rust-analyzer attached to this buffer", vim.log.levels.WARN)
  end
  if not opts.push then
    lens.origin = { bufnr = bufnr, row = row }
    lens.stack = {}
  end
  -- on a literal or identifier inside the arguments rust-analyzer finds no call at the cursor
  -- token's own macro-name position: ask at the start of the enclosing call (nearest ancestor)
  local ask_row, ask_col = row, col
  do
    local okp, parser = pcall(vim.treesitter.get_parser, bufnr, "rust")
    if okp and parser then
      pcall(function()
        parser:parse()
        local n = vim.treesitter.get_node({ bufnr = bufnr, pos = { row, col } })
        while n and n:type() ~= "macro_invocation" do
          n = n:parent()
        end
        if n then
          ask_row, ask_col = n:start()
        end
      end)
    end
  end
  local function show(name, text, note)
    local lines = vim.split((text:gsub("\n+$", "")), "\n", { plain = true })
    local level = { label = name:find("!$") and name or name .. "!", lines = lines, note = note }
    local sym = M.find_symbol(M.items_of(text), word)
    level.cursor_row = sym and sym.row or nil
    lens_push(level)
  end
  -- the cursor's own position first (a nested call inside println!'s arguments is no
  -- macro_invocation node: the ancestor would be the outer call), then the enclosing call
  local function request(cb)
    request_expand(bufnr, row, col, function(name, text)
      if name or (ask_row == row and ask_col == col) or opts.step then
        return cb(name, text)
      end
      request_expand(bufnr, ask_row, ask_col, function(n2, t2)
        if n2 then
          return cb(n2, t2)
        end
        cb(name, text or t2)
      end, 2)
    end, 2)
  end
  request(function(name, text)
    if name then
      return show(name, text)
    end
    if text then
      vim.notify("MacroExpand: " .. text, vim.log.levels.WARN)
    end
    if opts.step then
      return vim.notify("rust-analyzer returned no expansion for that call", vim.log.levels.INFO)
    end
    -- not on a call: the item's own derives and attribute macros
    local cands = M.item_macro_positions(bufnr, row, col)
    if #cands == 0 then
      -- cargo expand builds the crate: only for a cursor that is on a macro
      local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      local node = vim.treesitter.get_node({ bufnr = bufnr, pos = { row, col } })
      local on_macro = M.call_at(text, row, col) ~= nil
      while node and not on_macro do
        on_macro = node:type() == "attribute_item" or node:type() == "macro_definition" or node:type() == "macro_invocation"
        node = node:parent()
      end
      if not on_macro then
        return vim.notify("MacroExpand: no macro call, derive or attribute under the cursor", vim.log.levels.INFO)
      end
      return cargo_expand_fallback(bufnr, opts.push)
    end
    local parts, left = {}, #cands
    for i, c in ipairs(cands) do
      request_expand(bufnr, c.row, c.col, function(n, t)
        parts[i] = n and ("// ---- " .. c.label .. "\n" .. t) or false
        left = left - 1
        if left == 0 then
          local got = vim.tbl_filter(function(p)
            return p
          end, parts)
          if #got == 0 then
            return cargo_expand_fallback(bufnr, opts.push)
          end
          show("item", table.concat(got, "\n\n"), ("%d macro%s on this item"):format(#got, #got == 1 and "" or "s"))
        end
      end)
    end
  end)
end

-- ============================================================ proc-macro status

local MACRO_CODES = {
  ["macro-error"] = true,
  ["proc-macro-disabled"] = true,
  ["unresolved-proc-macro"] = true,
  ["unresolved-macro-call"] = true,
  ["macro-def-error"] = true,
}

--- Diagnostics (vim.Diagnostic list) about macros that were not expanded.
function M.macro_diagnostics(diags)
  local out = {}
  for _, d in ipairs(diags) do
    local code = d.code ~= nil and tostring(d.code) or ""
    local msg = (d.message or ""):lower()
    if MACRO_CODES[code] or msg:find("proc.macro") or msg:find("macro expansion") or msg:find("not expanded", 1, true) then
      out[#out + 1] = d
    end
  end
  return out
end

--- Crates of an analyzerStatus text: { { name, proc_macro = bool } ... } plus
--- settings found in the config dump.
function M.parse_analyzer_status(text)
  local crates, cur = {}, nil
  for line in (text or ""):gmatch("[^\n]+") do
    local name = line:match("^Crate: ([%w_%-]+)")
    if name then
      cur = { name = name, proc_macro = false }
      crates[#crates + 1] = cur
    end
    local pm = line:match("Is a proc macro crate: (%a+)")
    if pm and cur then
      cur.proc_macro = pm == "true"
    end
  end
  return {
    crates = crates,
    enabled = text and text:match("procMacro_enable: (%a+)"),
    attributes = text and text:match("procMacro_attributes_enable: (%a+)"),
  }
end

local function dylib_built(target_dir, crate)
  if not target_dir then
    return false
  end
  local lib = crate:gsub("%-", "_")
  -- target/ is cargo's own; target/rust-analyzer is where rust-analyzer builds
  -- (cargo.targetDir = true in plugins/rustaceanvim.lua)
  for _, sub in ipairs({ "", "/rust-analyzer" }) do
    for _, profile in ipairs({ "debug", "release" }) do
      for _, ext in ipairs({ "so", "dylib", "dll" }) do
        if #vim.fn.glob(("%s%s/%s/deps/lib%s-*.%s"):format(target_dir, sub, profile, lib, ext), true, true) > 0 then
          return true
        end
      end
    end
  end
  return false
end

--- Proc-macro crates of the metadata: { { name, version, member, dir, built } }.
function M.proc_macro_crates(meta, target_dir)
  local cm = require("config.crate_meta")
  local out = {}
  for _, p in ipairs(meta.packages) do
    local toml = p.dir and cm.read_manifest(p.dir)
    if toml and (toml:match("%[lib%].-\nproc[-_]macro%s*=%s*true") or toml:match("%[lib%]\nproc[-_]macro%s*=%s*true")) then
      out[#out + 1] = {
        name = p.name,
        version = p.version,
        member = p.is_member,
        dir = p.dir,
        built = dylib_built(target_dir, p.name),
      }
    end
  end
  table.sort(out, function(a, b)
    if a.member ~= b.member then
      return a.member
    end
    return a.name < b.name
  end)
  return out
end

--- Names a proc-macro crate exports (derives, attributes, function-like), read
--- from its source text.
function M.proc_macro_names(text)
  local names, seen = {}, {}
  local function add(n)
    if n and not seen[n] and n:find("^[%w_]+$") then
      seen[n] = true
      names[#names + 1] = n
    end
  end
  for n in text:gmatch("#%[%s*proc_macro_derive%s*%(%s*([%w_]+)") do
    add(n)
  end
  for n in text:gmatch("#%[%s*proc_macro_attribute%s*%]%s*[^\n]-fn%s+([%w_]+)") do
    add(n)
  end
  for n in text:gmatch("#%[%s*proc_macro%s*%]%s*[^\n]-fn%s+([%w_]+)") do
    add(n)
  end
  for n in text:gmatch("#%[%s*proc_macro_attribute%s*%]%s*\n%s*pub%s+fn%s+([%w_]+)") do
    add(n)
  end
  return names
end

--- The report: lines + a map line -> { kind, ... } for <CR>.
--- data = { root, crates = {...}, status = parse_analyzer_status | nil,
---          diags = vim.Diagnostic[], ignored = {name=...}, server = string|nil }
function M.report_lines(data)
  local lines, targets = {}, {}
  local function add(l, target)
    lines[#lines + 1] = l
    if target then
      targets[#lines] = target
    end
  end
  add("Proc macros  " .. (data.root or "(no workspace)"))
  add("")
  if data.status then
    if data.status.enabled == "false" then
      add("! rust-analyzer.procMacro.enable is false: no proc macro is expanded")
    end
    if data.status.attributes == "false" then
      add("! procMacro.attributes.enable is false: attribute macros (tokio::main, ...) are not expanded")
    end
  end
  if data.server then
    add("server: " .. data.server)
  end
  add("")
  add("Proc-macro crates (" .. #data.crates .. ")")
  if #data.crates == 0 then
    add("  none in this workspace's dependency graph")
  end
  local problems = {}
  for _, d in ipairs(data.diags) do
    local c = (d.message or ""):match("`([%w_%-]+)`")
    if c then
      problems[c] = (problems[c] or 0) + 1
    end
  end
  for _, c in ipairs(data.crates) do
    local ign = data.ignored and data.ignored[c.name]
    local state = ign and "ignored" or (c.built and "built" or "NOT BUILT")
    local note = problems[c.name] and ("  " .. problems[c.name] .. " problem(s)") or ""
    add(("  %-28s %-9s %s%s%s"):format(c.name, c.version or "", state, c.member and "  (workspace)" or "", note), { kind = "crate", name = c.name })
  end
  add("")
  add("Macros not expanded (" .. #data.diags .. " in open buffers)")
  if #data.diags == 0 then
    add("  none")
  end
  for _, d in ipairs(data.diags) do
    local file = vim.fn.fnamemodify(vim.api.nvim_buf_is_valid(d.bufnr) and vim.api.nvim_buf_get_name(d.bufnr) or "?", ":t")
    add(("  %s:%d  [%s] %s"):format(file, d.lnum + 1, tostring(d.code or "?"), (d.message or ""):gsub("\n.*", "")), { kind = "diag", diag = d })
  end
  add("")
  add("r rebuild proc macros   i ignore a slow proc macro   <CR> jump / ignore   R refresh   q close")
  return lines, targets
end

--- A rust-analyzer.toml text with `crate` added to [procMacro.ignored]:
--- returns the new text, or nil + why when the file declares the setting in a
--- form that is not edited blindly (dotted keys, inline tables).
function M.toml_ignore(text, crate, names)
  local items = {}
  for _, n in ipairs(names or {}) do
    if n:find("^[%w_]+$") then
      items[#items + 1] = '"' .. n .. '"'
    end
  end
  if #items == 0 then
    items = { '"*"' } -- every macro of the crate
  end
  local entry = ('"%s" = [%s]'):format(crate, table.concat(items, ", "))
  local lines = vim.split(text, "\n", { plain = true })
  local header, header_i, key_i, key_j, last_i
  for i, l in ipairs(lines) do
    local h = l:match("^%s*%[%s*([%w_.%s\"-]-)%s*%]%s*$") or l:match("^%s*%[%s*([%w_.%s\"-]-)%s*%]%s*#.*$")
    if h then
      header = h:gsub("%s", "")
      if header == "procMacro.ignored" then
        header_i = i
        last_i = i
      end
    elseif header == "procMacro.ignored" then
      if l:match("^%s*[\"']?" .. vim.pesc(crate) .. "[\"']?%s*=") then
        key_i = i
        key_j = i
        -- a multi-line array: the entry replaces every line up to the closing bracket
        local v = l:gsub("#.*$", "")
        if v:find("[", 1, true) and not v:find("]", 1, true) then
          key_j = nil
          for j = i + 1, #lines do
            if (lines[j]:gsub("#.*$", "")):find("]", 1, true) then
              key_j = j
              break
            end
          end
          if not key_j then
            return nil, "rust-analyzer.toml has an array for this crate that is not closed: fix it by hand"
          end
        end
      end
      if l:match("%S") then
        last_i = i
      end
    elseif l:match("^%s*procMacro%.ignored") or (header == "procMacro" and l:match("^%s*ignored%s*=")) then
      return nil, "rust-analyzer.toml sets procMacro.ignored in a form that is not edited automatically: add the crate by hand"
    end
  end
  if key_i then
    lines[key_i] = entry
    for _ = key_i + 1, key_j do
      table.remove(lines, key_i + 1)
    end
  elseif header_i then
    table.insert(lines, last_i + 1, entry)
  else
    if #lines > 0 and lines[#lines] == "" then
      table.remove(lines)
    end
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "[procMacro.ignored]"
    lines[#lines + 1] = entry
  end
  local out = table.concat(lines, "\n")
  -- cheap sanity check in place of a TOML parser: the table must still be declared once
  local heads = 0
  for _, l in ipairs(lines) do
    local h = l:match("^%s*%[%s*([%w_.%s\"-]-)%s*%]")
    if h and h:gsub("%s", "") == "procMacro.ignored" then
      heads = heads + 1
    end
  end
  if heads ~= 1 then
    return nil, "rust-analyzer.toml has an unusual [procMacro.ignored] layout: add the crate by hand"
  end
  return out:sub(-1) == "\n" and out or (out .. "\n")
end

--- Add `crate` to procMacro.ignored in <root>/rust-analyzer.toml, the
--- project-level settings file rust-analyzer reads itself (.rust-analyzer.toml
--- when that is the one that exists). Returns the path, or nil + error.
function M.ignore_proc_macro(root, crate, names)
  if not crate:find("^[%w_.%-]+$") then
    return nil, "refusing an odd crate name"
  end
  local path = root .. "/rust-analyzer.toml"
  if not uv.fs_stat(path) and uv.fs_stat(root .. "/.rust-analyzer.toml") then
    path = root .. "/.rust-analyzer.toml"
  end
  local text = ""
  local fh = io.open(path, "r")
  if fh then
    text = fh:read("*a")
    fh:close()
  end
  local new, why = M.toml_ignore(text, crate, names)
  if not new then
    return nil, why
  end
  -- atomic (tmp + rename) onto the real file, so a symlinked settings file stays one
  local real = uv.fs_realpath(path) or path
  local tmp = ("%s.%d.tmp"):format(real, uv.os_getpid())
  local out, err = io.open(tmp, "w")
  if not out then
    return nil, err
  end
  out:write(new)
  out:close()
  local st = uv.fs_stat(real)
  if st then
    pcall(uv.fs_chmod, tmp, st.mode % 4096)
  end
  local okr, rerr = uv.fs_rename(tmp, real)
  if not okr then
    uv.fs_unlink(tmp)
    return nil, rerr
  end
  return path
end

--- Crate names under [procMacro.ignored] of the project's rust-analyzer.toml.
local function ignored_of(root)
  local out = {}
  for _, name in ipairs({ "rust-analyzer.toml", ".rust-analyzer.toml" }) do
    local fh = io.open(root .. "/" .. name, "r")
    if fh then
      local header
      for l in fh:lines() do
        local h = l:match("^%s*%[%s*([%w_.%s\"-]-)%s*%]%s*$") or l:match("^%s*%[%s*([%w_.%s\"-]-)%s*%]%s*#.*$")
        if h then
          header = h:gsub("%s", "")
        elseif header == "procMacro.ignored" then
          local k = l:match("^%s*[\"']?([%w_.%-]+)[\"']?%s*=")
          if k then
            out[k] = true
          end
        end
      end
      fh:close()
    end
  end
  return out
end

local report = { buf = nil, win = nil, targets = {}, data = nil, src = nil }

local function reload_settings()
  -- rust-analyzer watches the toml itself; this also covers a client that
  -- was started with a stale copy of the settings
  pcall(vim.cmd, "RustAnalyzer reloadSettings")
end

local function ignore_crate(root, crate, crates)
  local names
  for _, c in ipairs(crates or {}) do
    if c.name == crate and c.dir then
      names = {}
      for _, rel in ipairs(vim.fn.glob(c.dir .. "/src/**/*.rs", true, true)) do
        local f = io.open(rel, "r")
        if f then
          local t = f:read("*a")
          f:close()
          vim.list_extend(names, M.proc_macro_names(t))
        end
      end
    end
  end
  local path, err = M.ignore_proc_macro(root, crate, names)
  if not path then
    return vim.notify("ProcMacroStatus: " .. tostring(err), vim.log.levels.ERROR)
  end
  reload_settings()
  vim.notify(("proc macros of `%s` are ignored (%s); settings reloaded"):format(crate, path), vim.log.levels.INFO)
end

local function report_draw()
  local lines, targets = M.report_lines(report.data)
  report.targets = targets
  vim.bo[report.buf].modifiable = true
  vim.api.nvim_buf_set_lines(report.buf, 0, -1, false, lines)
  vim.bo[report.buf].modifiable = false
end

local function report_keys(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  map("q", function()
    if report.win and vim.api.nvim_win_is_valid(report.win) then
      vim.api.nvim_win_close(report.win, true)
    end
  end, "Close")
  map("r", function()
    vim.cmd("RustLsp rebuildProcMacros")
  end, "Rebuild proc macros")
  map("R", function()
    M.proc_macro_status({ reuse = true })
  end, "Refresh")
  local function pick_ignore()
    local names = vim.tbl_map(function(c)
      return c.name
    end, report.data.crates)
    vim.ui.select(names, { prompt = "Ignore the proc macros of" }, function(n)
      if n then
        ignore_crate(report.data.root, n, report.data.crates)
        M.proc_macro_status({ reuse = true })
      end
    end)
  end
  map("i", pick_ignore, "Ignore a slow proc macro")
  map("<CR>", function()
    local t = report.targets[vim.api.nvim_win_get_cursor(0)[1]]
    if not t then
      return
    end
    if t.kind == "crate" then
      ignore_crate(report.data.root, t.name, report.data.crates)
      M.proc_macro_status({ reuse = true })
    elseif t.kind == "diag" and vim.api.nvim_buf_is_valid(t.diag.bufnr) then
      vim.cmd("wincmd p")
      vim.api.nvim_set_current_buf(t.diag.bufnr)
      vim.api.nvim_win_set_cursor(0, { t.diag.lnum + 1, t.diag.col })
    end
  end, "Ignore the crate / jump to the diagnostic")
end

--- :ProcMacroStatus
function M.proc_macro_status(opts)
  opts = opts or {}
  local src = opts.reuse and report.src or vim.api.nvim_get_current_buf()
  report.src = src
  local cm = require("config.crate_meta")
  local file = vim.api.nvim_buf_get_name(src)
  local root = cm.root(file)
  if not root then
    return vim.notify("ProcMacroStatus: not in a cargo workspace", vim.log.levels.WARN)
  end
  cm.metadata_async(root, function(meta, err)
    if not meta then
      return vim.notify("ProcMacroStatus: " .. tostring(err), vim.log.levels.WARN)
    end
    local target = vim.env.CARGO_TARGET_DIR or ((meta.workspace_root or root) .. "/target")
    local data = {
      root = root,
      crates = M.proc_macro_crates(meta, target),
      diags = M.macro_diagnostics(vim.diagnostic.get(nil)),
      ignored = ignored_of(root),
    }
    local function finish()
      if not (report.buf and vim.api.nvim_buf_is_valid(report.buf)) then
        report.buf = vim.api.nvim_create_buf(false, true)
        vim.bo[report.buf].buftype = "nofile"
        vim.bo[report.buf].bufhidden = "wipe"
        vim.bo[report.buf].swapfile = false
        report_keys(report.buf)
      end
      report.data = data
      if not (report.win and vim.api.nvim_win_is_valid(report.win)) then
        vim.cmd("botright 18split")
        report.win = vim.api.nvim_get_current_win()
      end
      vim.api.nvim_win_set_buf(report.win, report.buf)
      pcall(vim.api.nvim_buf_set_name, report.buf, "proc-macro-status")
      report_draw()
    end
    local client = vim.api.nvim_buf_is_valid(src) and ra_client(src)
    if not client then
      data.server = "no rust-analyzer client attached to " .. (file ~= "" and vim.fs.basename(file) or "this buffer")
      return finish()
    end
    client:request("rust-analyzer/analyzerStatus", { textDocument = { uri = vim.uri_from_bufnr(src) } }, function(e, text)
      if not e and type(text) == "string" then
        data.status = M.parse_analyzer_status(text)
        local pmc = vim.tbl_filter(function(c)
          return c.proc_macro
        end, data.status.crates)
        -- a count of 0 would contradict the list below when the status text has no crate graph
        data.server = #pmc == 0 and ("rust-analyzer " .. client.name)
          or ("rust-analyzer %s; %d proc-macro crate%s in this file's crates"):format(client.name, #pmc, #pmc == 1 and "" or "s")
      else
        data.server = "analyzerStatus failed: " .. tostring(e and e.message)
      end
      finish()
    end, src)
  end)
end

-- ====================================================================== setup

local function buf_keys(buf)
  local function map(mode, lhs, rhs, desc, force)
    local existing = vim.fn.maparg(lhs, mode, false, true)
    if not force and existing and existing.buffer == 1 and existing.desc and existing.desc ~= desc then
      return
    end
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc })
  end
  map("n", "<leader>rx", "<cmd>MacroExpand<cr>", "Expand macro under cursor (lens)")
  map("n", "<leader>rq", "<cmd>ProcMacroStatus<cr>", "Proc-macro status")
  -- the insert-mode <C-k> of LazyVim is vim.lsp.buf.signature_help: the macro
  -- popup first, that one when the cursor is not in a macro call
  map("i", "<C-k>", function()
    M.signature(buf, { manual = true })
  end, "Macro / signature help", true)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("xynovim_macro_tools", { clear = true })
  vim.api.nvim_create_user_command("MacroExpand", function()
    M.expand()
  end, { desc = "Expand the macro under the cursor in a read-only split" })
  vim.api.nvim_create_user_command("MacroFormatFix", function()
    M.format_fix()
  end, { desc = "Add the missing arguments of the format macro at the cursor" })
  vim.api.nvim_create_user_command("MacroSignature", function()
    M.signature(nil, { manual = true })
  end, { desc = "Show the matcher arms of the macro call at the cursor" })
  vim.api.nvim_create_user_command("ProcMacroStatus", function()
    M.proc_macro_status()
  end, { desc = "Proc-macro crates, macros that were not expanded, rebuild / ignore" })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "rust",
    callback = function(ev)
      schedule_hints(ev.buf)
      vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave", "BufWritePost" }, {
        group = group,
        buffer = ev.buf,
        callback = function()
          schedule_hints(ev.buf)
        end,
      })
    end,
  })
  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = group,
    callback = function(ev)
      if vim.bo[ev.buf].filetype ~= "rust" or not ra_client(ev.buf) then
        return
      end
      local ch = vim.v.char
      if ch == "(" or ch == "[" or ch == "{" or ch == "!" then
        vim.schedule(function()
          if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
            M.signature(ev.buf)
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    callback = function(ev)
      if sig.win and vim.api.nvim_win_is_valid(sig.win) and vim.bo[ev.buf].filetype == "rust" then
        M.signature(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    callback = close_popup,
  })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(ev)
      -- any client: LazyVim's LSP keys (<C-k>) are set again on every attach,
      -- so the maps follow the same events, after them
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(ev.buf) and #require("config.code_actions").clients(ev.buf) > 0 then
          buf_keys(ev.buf)
        end
      end, 120)
    end,
  })
  -- buffers that attached before the setup ran
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].filetype == "rust" then
      schedule_hints(b)
      if #require("config.code_actions").clients(b) > 0 then
        buf_keys(b)
      end
    end
  end
end

return M
