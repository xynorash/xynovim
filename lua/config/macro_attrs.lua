-- Completion INSIDE the arguments of helper attributes (#[serde(...)], #[arg(...)],
-- #[command(...)], #[error(...)], #[tokio::main(...)], ...) and of #[derive(...)],
-- as a blink.cmp source driven by data (plan items 2.1, 2.2; gaps G1, G2).
-- rust-analyzer returns nothing there, so keys, enumerated values and derive names
-- were typed from memory.
--
-- Data: data/macro_attrs/<crate>.json (format in data/macro_attrs/README.md),
-- overridden per attribute by <workspace>/.xynovim/macro_attrs/*.json.
--
-- How a request is answered (items(), the pure core the specs drive):
--   1. A small lexer reads the attribute from its `#[` to the cursor (strings,
--      nesting, `key = value` entries) and says: which attribute path, which key or
--      value is being typed, which keys are already there. Nothing is parsed with
--      treesitter here: the attribute is unfinished by definition.
--   2. The buffer is parsed with the attribute REPAIRED (closing quote and brackets
--      appended) so treesitter can say what it is attached to (container struct or
--      enum, field, variant, fn, fn parameter) and which derives that item has.
--   3. Only schemas of crates that are dependencies are used (cargo metadata once it
--      is cached, a scan of Cargo.toml until then; never blocks), version-gated, and
--      only when the helper is in scope (a derive providing it is on the item, or the
--      attribute macro is named in full or imported).
--   4. Attributes of dependency crates WITHOUT a schema: keys the workspace and the
--      crate's own sources already write inside that attribute, by frequency.
-- #[derive( completes the builtin derives plus the derive macros found in the
-- dependencies' proc-macro sources (#[proc_macro_derive(Name, attributes(...))]);
-- accepting one that is not imported calls M.on_derive_accepted(name, info).
local M = {}

local cm = require("config.crate_meta")

M.config = {
  shipped_glob = "data/macro_attrs/*.json",
  user_dir = ".xynovim/macro_attrs", -- under the workspace root
  context_lines = 15, -- how far above the cursor an attribute may start
  window_min = 1500, -- files longer than this are parsed around the cursor only
  window_lines = 300,
  learn_ttl = 120, -- seconds a learn-from-usage scan stays cached
  learn_max_files = 300, -- per scanned directory tree
  learn_max_bytes = 2 * 1024 * 1024,
  derive_max_files = 80, -- per proc-macro crate
  derive_max_bytes = 2 * 1024 * 1024,
  import_attempts = 10, -- rust-analyzer needs a moment to know the new name
  import_interval = 500,
}

M.load_errors = {} -- problems found while loading schemas (strings), for :MacroAttrs and specs

local function norm(name)
  return (tostring(name):gsub("%-", "_"))
end

-- Regular files up to `max` bytes only (default 2 MB): the files read here are the project's or
-- a dependency's and a huge one, a FIFO or a link to /dev/zero must not block the editor.
local function read_file(path, max)
  local st = vim.uv.fs_stat(path)
  if not st or st.type ~= "file" or st.size > (max or 2 * 1024 * 1024) then
    return nil
  end
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function mtime(path)
  local st = vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. "." .. st.mtime.nsec) or "-"
end

-- ------------------------------------------------------------------ semver

local function partial(v)
  local a, b, c = tostring(v):match("^%s*(%d+)%.?(%d*)%.?(%d*)")
  if not a then
    return nil
  end
  return { tonumber(a), b ~= "" and tonumber(b) or nil, c ~= "" and tonumber(c) or nil }
end

local function ver_str(p)
  return ("%d.%d.%d"):format(p[1], p[2] or 0, p[3] or 0)
end

--- Does `version` satisfy a cargo-style requirement (">=1.0.0, <2", "^1.2", "~1.2",
--- "1", "=1.2.3", "*")? Unknown or unparsable input is satisfied (never hide a
--- schema because of data we cannot read).
function M.satisfies(version, range)
  if not version or not range or range == "" or range == "*" then
    return true
  end
  if not cm.valid_version(version) then
    return true
  end
  for comp in range:gmatch("[^,]+") do
    local op, rest = comp:match("^%s*([<>=~^]*)%s*(.-)%s*$")
    local p = partial(rest)
    if rest == "*" or rest == "" then
      p = nil
    elseif not p then
      return true
    end
    if p then
      local lo = ver_str(p)
      local c = cm.compare_versions(version, lo)
      local upper
      if op == "" or op == "^" then
        if p[1] > 0 or not p[2] then
          upper = ("%d.0.0"):format(p[1] + 1)
        elseif p[2] > 0 or not p[3] then
          upper = ("0.%d.0"):format(p[2] + 1)
        else
          upper = ("0.0.%d"):format(p[3] + 1)
        end
        if c < 0 or cm.compare_versions(version, upper) >= 0 then
          return false
        end
      elseif op == "~" then
        upper = p[2] and ("%d.%d.0"):format(p[1], p[2] + 1) or ("%d.0.0"):format(p[1] + 1)
        if c < 0 or cm.compare_versions(version, upper) >= 0 then
          return false
        end
      elseif op == ">=" then
        if c < 0 then
          return false
        end
      elseif op == ">" then
        if c <= 0 then
          return false
        end
      elseif op == "<=" then
        if c > 0 then
          return false
        end
      elseif op == "<" then
        if c >= 0 then
          return false
        end
      elseif op == "=" then
        -- a partial version pins only the parts it names
        local v = partial(version)
        for i = 1, 3 do
          if p[i] and v[i] ~= p[i] then
            return false
          end
        end
      end
    end
  end
  return true
end

-- ------------------------------------------------------------------ schemas

local KINDS = { flag = true, string = true, ident = true, path = true, int = true, bool = true, enum = true, expr = true }

local LIST_FIELDS = { "applies_to", "derives", "conflicts", "requires", "values", "nested", "needs_attr", "alt" }

--- A hand-written schema may give "field" where a list is expected: make it a list.
local function lists(t)
  for _, k in ipairs(LIST_FIELDS) do
    if t[k] ~= nil and type(t[k]) ~= "table" then
      t[k] = { t[k] }
    end
  end
end

local function check_schema(file, source)
  local errs = {}
  local function bad(msg)
    errs[#errs + 1] = ("%s: %s"):format(source, msg)
  end
  if type(file) ~= "table" or type(file.crate) ~= "string" or not cm.valid_name(file.crate) then
    bad("`crate` must be a crate name")
    return nil, errs
  end
  if type(file.attributes) ~= "table" then
    bad("`attributes` must be a list")
    file.attributes = {}
  end
  local attrs = {}
  for i, a in ipairs(file.attributes) do
    if type(a) ~= "table" or type(a.name) ~= "string" or not a.name:match("^[%w_:]+$") then
      bad(("attributes[%d] needs a `name`"):format(i))
    else
      lists(a)
      local args = {}
      for j, arg in ipairs(type(a.args) == "table" and a.args or {}) do
        if type(arg) ~= "table" or type(arg.key) ~= "string" then
          bad(("%s.args[%d] needs a `key`"):format(a.name, j))
        elseif not KINDS[arg.kind or "flag"] then
          bad(("%s.%s: unknown kind %s"):format(a.name, arg.key, tostring(arg.kind)))
        else
          arg.kind = arg.kind or "flag"
          lists(arg)
          args[#args + 1] = arg
        end
      end
      a.args = args
      attrs[#attrs + 1] = a
    end
  end
  file.attributes = attrs
  return file, errs
end

local function load_json(path)
  local text = read_file(path, 1024 * 1024)
  if not text then
    return nil, path .. ": cannot read (missing or over 1 MB)"
  end
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok then
    return nil, path .. ": invalid JSON (" .. tostring(data):gsub("\n.*", "") .. ")"
  end
  return data
end

local shipped_cache
--- crate -> schema file, from data/macro_attrs of the config.
function M.shipped()
  if shipped_cache then
    return shipped_cache
  end
  local out = {}
  for _, path in ipairs(vim.api.nvim_get_runtime_file(M.config.shipped_glob, true)) do
    if not path:match("README") then
      local data, err = load_json(path)
      local file, errs
      if data then
        file, errs = check_schema(data, vim.fs.basename(path))
      end
      if err then
        M.load_errors[#M.load_errors + 1] = err
      end
      for _, e in ipairs(errs or {}) do
        M.load_errors[#M.load_errors + 1] = e
      end
      if file and not out[file.crate] then
        file.source = path
        out[file.crate] = file
      end
    end
  end
  shipped_cache = out
  return out
end

local user_cache = {}
--- Shipped schemas with the workspace's .xynovim/macro_attrs/*.json applied: a user
--- attribute replaces every shipped attribute of the same crate and name; a user file
--- for another crate is added. Cached until a file's mtime changes.
function M.schemas(root)
  local base = M.shipped()
  if not root then
    return base
  end
  local dir = root .. "/" .. M.config.user_dir
  local files = vim.fn.glob(dir .. "/*.json", true, true)
  if #files == 0 then
    return base
  end
  table.sort(files)
  local stamp = {}
  for _, f in ipairs(files) do
    stamp[#stamp + 1] = f .. mtime(f)
  end
  stamp = table.concat(stamp, "|")
  local hit = user_cache[root]
  if hit and hit.stamp == stamp then
    return hit.set
  end
  local set = {}
  for crate, file in pairs(base) do
    set[crate] = vim.tbl_extend("force", {}, file, { attributes = vim.list_slice(file.attributes) })
  end
  for _, f in ipairs(files) do
    local data, err = load_json(f)
    local file, errs
    if data then
      file, errs = check_schema(data, f)
    end
    if err then
      M.load_errors[#M.load_errors + 1] = err
    end
    for _, e in ipairs(errs or {}) do
      M.load_errors[#M.load_errors + 1] = e
    end
    if file then
      local target = set[file.crate]
      if not target then
        set[file.crate] = file
      else
        local names = {}
        for _, a in ipairs(file.attributes) do
          names[a.name] = true
        end
        local kept = vim.tbl_filter(function(a)
          return not names[a.name]
        end, target.attributes)
        vim.list_extend(kept, file.attributes)
        target.attributes = kept
        target.docs_url = file.docs_url or target.docs_url
        target.versions = file.versions or target.versions
      end
    end
  end
  user_cache[root] = { stamp = stamp, set = set }
  return set
end

-- ---------------------------------------------------------------- the lexer

local CLOSER = { ["("] = ")", ["["] = "]", ["{"] = "}" }

local function new_state(inner)
  return {
    inner = inner,
    phase = "path", -- path | args | after
    path = "",
    frames = {},
    bstack = inner and { "]", ")" } or { "]" },
    closed = false,
    pending = nil, -- identifier being read (not yet a token)
    str = nil, -- { buf = "", entry = entry|nil, frame = frame|nil }
    comment = nil,
  }
end

local function push_frame(st, key)
  st.frames[#st.frames + 1] = { key = key, seen = {}, entry = nil }
end

local function finish_entry(f)
  local e = f.entry
  if e and e.key ~= "" then
    f.seen[e.key] = true
    local last = e.key:match("([%w_]+)$")
    if last then
      f.seen_last = f.seen_last or {}
      f.seen_last[last] = e.key
    end
  end
  f.entry = nil
end

--- One token. kind: ident | string | punct | other.
local function token(st, kind, text, off)
  if st.phase == "path" then
    if kind == "ident" then
      st.path = st.path .. text
    elseif text == "::" then
      st.path = st.path .. "::"
    elseif text == "(" then
      st.phase = "args"
      push_frame(st, st.path)
    elseif text == "=" then
      st.phase = "after"
    elseif text == ")" and st.inner then
      st.phase = "after"
    end
    return
  end
  if st.phase ~= "args" then
    return
  end
  local f = st.frames[#st.frames]
  local e = f.entry
  -- cfg_attr(cond, inner(...)): where the inner attribute starts
  if text == "," and kind == "punct" and #st.frames == 1 and st.path == "cfg_attr" and not f.first_comma then
    if not e or e.state ~= "value" or e.depth == 0 then
      f.first_comma = off
    end
  end
  if kind == "string" then
    if not e then
      f.entry = { key = '"…"', state = "after", depth = 0, vtokens = 1 }
    elseif e.state == "value" then
      e.vtokens = e.vtokens + 1
      e.vtext = (e.vtext or "") .. text
    end
    return
  end
  if not e then
    if kind == "ident" then
      f.entry = { key = text, state = "key", depth = 0, vtokens = 0 }
    elseif text == ")" then
      table.remove(st.frames)
      if #st.frames == 0 then
        st.phase = "after"
      end
    elseif text == "," then
      -- empty entry
    elseif text == "(" or text == "[" or text == "{" then
      f.entry = { key = "", state = "value", depth = 1, vtokens = 1 }
    else
      f.entry = { key = "", state = "value", depth = 0, vtokens = 1 }
    end
    return
  end
  if e.state == "key" then
    if kind == "ident" then
      if e.key:sub(-2) == "::" then
        e.key = e.key .. text
      end
    elseif text == "::" then
      e.key = e.key .. "::"
    elseif text == "=" then
      e.state, e.vtokens, e.vtext = "value", 0, nil
    elseif text == "(" then
      e.state = "nested"
      push_frame(st, e.key)
      st.frames[#st.frames].parent_entry = e
    elseif text == "," then
      finish_entry(f)
    elseif text == ")" then
      finish_entry(f)
      table.remove(st.frames)
      if #st.frames == 0 then
        st.phase = "after"
      end
    end
  elseif e.state == "value" then
    if text == "(" or text == "[" or text == "{" then
      e.depth = e.depth + 1
      e.vtokens = e.vtokens + 1
    elseif text == ")" or text == "]" or text == "}" then
      if e.depth > 0 then
        e.depth = e.depth - 1
        e.vtokens = e.vtokens + 1
      elseif text == ")" then
        finish_entry(f)
        table.remove(st.frames)
        if #st.frames == 0 then
          st.phase = "after"
        end
      end
    elseif text == "," and e.depth == 0 then
      finish_entry(f)
    else
      e.vtokens = e.vtokens + 1
      e.vtext = (e.vtext or "") .. text
    end
  elseif e.state == "nested" or e.state == "after" then
    if text == "," then
      finish_entry(f)
    elseif text == ")" then
      finish_entry(f)
      table.remove(st.frames)
      if #st.frames == 0 then
        st.phase = "after"
      end
    end
  end
end

local function flush(st, off)
  if st.pending then
    local p = st.pending
    st.pending = nil
    token(st, "ident", p, off)
  end
end

-- a nested frame that just closed completes its parent entry
local function after_pop(st)
  local f = st.frames[#st.frames]
  if f and f.entry and f.entry.state == "nested" then
    f.entry.state = "after"
  end
end

--- Feed text[i..j] (1-based, inclusive) to the lexer.
local function run(st, text, i, j)
  while i <= j and not st.closed do
    local c = text:sub(i, i)
    if st.comment == "line" then
      if c == "\n" then
        st.comment = nil
      end
    elseif st.comment == "block" then
      if c == "*" and text:sub(i + 1, i + 1) == "/" then
        st.comment = nil
        i = i + 1
      end
    elseif st.str then
      if c == "\\" then
        st.str.buf = st.str.buf .. text:sub(i, i + 1)
        i = i + 1
      elseif c == '"' then
        local s = st.str
        st.str = nil
        token(st, "string", s.buf, i)
      else
        st.str.buf = st.str.buf .. c
      end
    elseif c:match("[%w_]") then
      st.pending = (st.pending or "") .. c
    else
      flush(st, i)
      if c == '"' then
        st.str = { buf = "" }
      elseif c == "/" and text:sub(i + 1, i + 1) == "/" then
        st.comment = "line"
        i = i + 1
      elseif c == "/" and text:sub(i + 1, i + 1) == "*" then
        st.comment = "block"
        i = i + 1
      elseif c == ":" and text:sub(i + 1, i + 1) == ":" then
        token(st, "punct", "::", i)
        i = i + 1
      elseif CLOSER[c] then
        st.bstack[#st.bstack + 1] = CLOSER[c]
        token(st, "punct", c, i)
      elseif c == ")" or c == "]" or c == "}" then
        if st.bstack[#st.bstack] == c then
          st.bstack[#st.bstack] = nil
          if c == ")" then
            token(st, "punct", c, i)
            after_pop(st)
          elseif c == "]" and st.bstack[1] == nil then
            st.closed = true
          else
            token(st, "punct", c, i)
          end
          if #st.bstack == 0 then
            st.closed = true
          end
        else
          st.broken = true -- a closer that does not match: stop reading
          st.closed = true
        end
      elseif c == "," or c == "=" then
        token(st, "punct", c, i)
      elseif not c:match("%s") then
        token(st, "other", c, i)
      end
    end
    i = i + 1
  end
end

--- What the cursor is on, from the lexer state at the cursor.
local function snapshot(st)
  if st.closed or st.comment then
    return nil
  end
  if st.phase ~= "args" then
    return { mode = "path", path = st.path .. (st.pending or "") }
  end
  local f = st.frames[#st.frames]
  local e = f.entry
  local ctx = {
    path = st.frames[1].key,
    keys = {}, -- attribute path, then the keys of the nested frames
    seen = f.seen,
    seen_last = f.seen_last or {},
    in_string = false,
    first_comma = st.frames[1].first_comma,
    base = st.frames[1],
  }
  for _, fr in ipairs(st.frames) do
    ctx.keys[#ctx.keys + 1] = fr.key
  end
  ctx.nested = #st.frames > 1 and st.frames[#st.frames].key or nil
  ctx.entries = vim.tbl_count(f.seen) + (e and 1 or 0)
  if st.str then
    if e and e.state == "value" and e.vtokens == 0 and e.depth == 0 then
      ctx.mode, ctx.key, ctx.prefix, ctx.in_string = "value", e.key, st.str.buf, true
      return ctx
    end
    return nil
  end
  if not e then
    ctx.mode, ctx.prefix = "key", st.pending or ""
  elseif e.state == "key" then
    if e.key:sub(-2) == "::" then
      ctx.mode, ctx.prefix, ctx.qualifier = "key", st.pending or "", e.key:sub(1, -3)
    else
      return nil
    end
  elseif e.state == "value" and e.vtokens == 0 and e.depth == 0 then
    ctx.mode, ctx.key, ctx.prefix = "value", e.key, st.pending or ""
  else
    return nil
  end
  return ctx
end

local function line_offsets(lines)
  local offs, o = {}, 0
  for i, l in ipairs(lines) do
    offs[i] = o
    o = o + #l + 1
  end
  return offs
end

--- Lex an attribute that starts at `start` (just after `#[`), up to the cursor offset
--- `cur`, then forward over the rest of the cursor line and over following lines that
--- still read like attribute arguments. Returns ctx, st, closed_at, end_off (offset of
--- the end of the last line read, where closers are inserted when it is unclosed).
local function lex_attr(text, lines, offs, start, cur, row, inner)
  local st = new_state(inner)
  run(st, text, start, cur)
  if st.closed then
    return nil
  end
  local ctx = snapshot(st)
  local last = row
  local function line_end(r)
    return offs[r] + #lines[r]
  end
  run(st, text, cur + 1, line_end(row))
  while not st.closed and last < #lines and last - row < 20 do
    local nxt = lines[last + 1]
    local cont = nxt:match("^%s*[%a_][%w_:]*%s*[=,()%]]")
      or nxt:match('^%s*"')
      or nxt:match("^%s*%)")
      or nxt:match("^%s*%]")
    if not cont or nxt:match("^%s*[%a_][%w_]*%s+[%a_]") then
      break
    end
    run(st, text, offs[last + 1] - 0, line_end(last + 1)) -- the newline itself is not needed
    last = last + 1
  end
  return ctx, st, st.closed and not st.broken, line_end(last)
end

--- The attribute under the cursor: ctx (see snapshot) plus what is needed to repair
--- the text for treesitter. nil when the cursor is not inside an attribute.
local function attribute_at(lines, row, col)
  local offs = line_offsets(lines)
  local text = table.concat(lines, "\n")
  local cur = offs[row] + col
  local tried = 0
  for r = row, math.max(1, row - M.config.context_lines), -1 do
    local line = lines[r]
    local limit = r == row and col or #line
    local from = 1
    local starts = {}
    while true do
      local s, e = line:find("#!?%[", from)
      if not s or e > limit then
        break
      end
      starts[#starts + 1] = { s, e }
      from = s + 1
    end
    for k = #starts, 1, -1 do
      tried = tried + 1
      if tried > 4 then
        return nil
      end
      local start = offs[r] + starts[k][2] + 1
      local ctx, st, closed, end_off = lex_attr(text, lines, offs, start, cur, row, false)
      if ctx then
        local res = { ctx = ctx, text = text, offs = offs, attr_off = offs[r] + starts[k][1] - 1, attr_row = r, attr_col = starts[k][1] - 1 }
        if ctx.mode == "path" then
          return res
        end
        -- #[cfg_attr(cond, derive(...))]: after the first comma it is a new attribute
        if ctx.path == "cfg_attr" then
          if not ctx.first_comma then
            return nil
          end
          local ictx, ist, iclosed, iend = lex_attr(text, lines, offs, ctx.first_comma + 1, cur, row, true)
          if not ictx then
            return nil
          end
          ctx, st, closed, end_off = ictx, ist, iclosed, iend
          res.ctx = ictx
        end
        res.closed = closed
        res.end_off = end_off
        res.closers = (st.str and '"' or "") .. table.concat(vim.fn.reverse(vim.deepcopy(st.bstack)))
        -- the cursor line's own forward scan may have consumed some closers already:
        -- st.bstack is the state at the end of the last line read
        return res
      end
      return nil
    end
  end
  return nil
end

-- ------------------------------------------------------------ dependencies

local SKIP_KEYS = {
  version = true, features = true, optional = true, ["default-features"] = true, default_features = true,
  path = true, git = true, branch = true, tag = true, rev = true, package = true, workspace = true,
  registry = true, ["public"] = true, artifact = true, lib = true, target = true,
}

--- Dependency names of a Cargo.toml text: { { alias, name } ... } (name = package);
--- skip_dev leaves out [dev-dependencies] (a registry crate's dev-dependencies are not built).
local function manifest_deps(toml, skip_dev)
  local out, seen = {}, {}
  local function add(alias, name, path)
    alias = alias:gsub("[\"']", "")
    if not seen[alias] then
      seen[alias] = true
      out[#out + 1] = { alias = alias, name = name or alias, path = path }
    end
  end
  local in_deps, last
  for line in (toml .. "\n"):gmatch("(.-)\n") do
    local sec = line:match("^%s*%[([^%[%]]-)%]%s*$")
    if sec and skip_dev and sec:match("dev%-dependencies") then
      in_deps, last = false, nil
    elseif sec then
      in_deps, last = false, nil
      local single = sec:match("dependencies%.([%w_%-\"']+)$")
      if single then
        add(single)
        last = out[#out]
      elseif sec:match("dependencies$") then
        in_deps = true
      end
    elseif in_deps then
      local k = line:match("^%s*([%w_%-]+)%s*[=.]")
      if k and not SKIP_KEYS[k] then
        add(k, line:match('package%s*=%s*"([^"]+)"'), line:match('path%s*=%s*"([^"]+)"'))
      end
    elseif last then
      local pkg = line:match('^%s*package%s*=%s*"([^"]+)"')
      if pkg then
        last.name = pkg
      end
      last.path = last.path or line:match('^%s*path%s*=%s*"([^"]+)"')
    end
  end
  return out
end
M._manifest_deps = manifest_deps

local metas = {} -- root -> { meta, stamp }
local inflight = {}
local failed = {} -- root -> os.time() of the last failed metadata run

local function meta_stamp(root, meta)
  local parts = { mtime(root .. "/Cargo.toml"), mtime(root .. "/Cargo.lock") }
  for _, m in ipairs(meta and meta.members or {}) do
    parts[#parts + 1] = mtime(m.manifest_path)
  end
  return table.concat(parts, "|")
end

local function nearest_manifest(path, root)
  local dir = vim.fs.dirname(path)
  while dir and #dir >= #root do
    if vim.uv.fs_stat(dir .. "/Cargo.toml") then
      return dir .. "/Cargo.toml"
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return root .. "/Cargo.toml"
end

--- Start (or reuse) a cargo metadata run for `root`; cb() when it is cached.
function M.refresh_dependencies(root, cb)
  cm.metadata_async(root, function(meta)
    inflight[root] = nil
    if meta then
      metas[root] = { meta = meta, stamp = meta_stamp(root, meta) }
      failed[root] = nil
    else
      failed[root] = os.time()
    end
    if cb then
      cb(meta ~= nil)
    end
  end)
end

--- Dependencies of the crate that owns `path`: { by_name = { [crate_ident] = { name,
--- alias, version, dir } }, meta, from = "metadata"|"scan" }. Never blocks: before the
--- metadata is cached it scans Cargo.toml (no versions) and starts the metadata run.
function M.dependencies(path, root)
  root = root or cm.root(path)
  if not root then
    return { by_name = {}, from = "none" }
  end
  local hit = metas[root]
  if hit and hit.stamp == meta_stamp(root, hit.meta) then
    local meta = hit.meta
    local member = cm.member_of(meta, path)
    local by_name = {}
    for _, d in ipairs(meta.dependencies) do
      if not member or d.member == member.name then
        local r = d.resolved
        local rec = { name = d.name, alias = d.alias, version = r and r.version, dir = r and r.dir, kind = d.kind }
        by_name[norm(d.name)] = by_name[norm(d.name)] or rec
        by_name[d.alias] = by_name[d.alias] or rec
      end
    end
    return { by_name = by_name, meta = meta, from = "metadata", root = root }
  end
  if not inflight[root] and (not failed[root] or os.time() - failed[root] > 60) then
    inflight[root] = true
    M.refresh_dependencies(root)
  end
  local by_name = {}
  local seen_file = {}
  for _, manifest in ipairs({ root .. "/Cargo.toml", nearest_manifest(path, root) }) do
    if not seen_file[manifest] then
      seen_file[manifest] = true
      for _, d in ipairs(manifest_deps(read_file(manifest) or "")) do
        -- a path dependency has its sources next to the manifest (no registry needed)
        local dir = d.path and vim.fs.normalize(vim.fs.dirname(manifest) .. "/" .. d.path) or nil
        local rec = { name = d.name, alias = norm(d.alias), dir = dir }
        by_name[norm(d.name)] = by_name[norm(d.name)] or rec
        by_name[rec.alias] = by_name[rec.alias] or rec
      end
    end
  end
  return { by_name = by_name, from = "scan", root = root }
end

-- -------------------------------------------------------- derive discovery

M.builtin_derives = { "Clone", "Copy", "Debug", "Default", "Eq", "Hash", "Ord", "PartialEq", "PartialOrd" }

local function balanced(text, open_at)
  -- text[open_at] == "("; returns the inside of the parentheses
  local depth, in_str = 0, false
  local i = open_at
  while i <= #text and i - open_at < 600 do
    local c = text:sub(i, i)
    if in_str then
      if c == "\\" then
        i = i + 1
      elseif c == '"' then
        in_str = false
      end
    elseif c == '"' then
      in_str = true
    elseif c == "(" then
      depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
      if depth == 0 then
        return text:sub(open_at + 1, i - 1)
      end
    end
    i = i + 1
  end
  return nil
end

--- Derive macros declared in one proc-macro crate directory (bounded scan):
--- { { name, helpers = {..} } }.
local proc_memo = {}
local function proc_macro_derives(dir)
  if proc_memo[dir] then
    return proc_memo[dir]
  end
  local out, seen = {}, {}
  local manifest = read_file(dir .. "/Cargo.toml") or ""
  local is_proc = manifest:match("proc%-macro%s*=%s*true") or manifest:match("proc_macro%s*=%s*true")
  if is_proc then
    local files, bytes = 0, 0
    for name, kind in vim.fs.dir(dir .. "/src", { depth = 3 }) do
      if kind == "file" and name:sub(-3) == ".rs" and files < M.config.derive_max_files and bytes < M.config.derive_max_bytes then
        local text = read_file(dir .. "/src/" .. name, 400 * 1024)
        if text then
          files, bytes = files + 1, bytes + #text
          local from = 1
          while true do
            local s, e, nm = text:find("proc_macro_derive%s*%(%s*([%a_][%w_]*)", from)
            if not s then
              break
            end
            local open = text:find("(", s, true)
            local inside = balanced(text, open) or ""
            local helpers = {}
            local attrs = inside:match("attributes%s*%((.-)%)")
            for h in (attrs or ""):gmatch("[%a_][%w_]*") do
              helpers[#helpers + 1] = h
            end
            if not seen[nm] then
              seen[nm] = true
              out[#out + 1] = { name = nm, helpers = helpers }
            end
            from = e + 1
          end
        end
      end
    end
  end
  proc_memo[dir] = out
  return out
end

local function dep_dir(deps, dep)
  if dep.dir and vim.uv.fs_stat(dep.dir) then
    return dep.dir
  end
  return (cm.registry_dir(dep.name))
end

local function pkg_dir(deps, name)
  local meta = deps.meta
  if meta then
    for _, key in ipairs({ name, (name:gsub("_", "-")) }) do
      for _, p in ipairs(meta.by_name[key] or {}) do
        if p.dir and vim.uv.fs_stat(p.dir) then
          return p.dir
        end
      end
    end
    return nil -- resolved graph is known: a crate that is not in it is not enabled
  end
  return (cm.registry_dir(name))
end

local catalog_memo = {}
--- The derive macros the dependencies provide: { { name, crate (the dependency a
--- user imports it from), helpers, path = "crate::Name" } }. Found in the dependency's
--- own proc-macro source or in the proc-macro crates its manifest depends on.
function M.derive_catalog(deps)
  local out = {}
  local done = {}
  for _, dep in pairs(deps.by_name) do
    if not done[dep.name] then
      done[dep.name] = true
      local dir = dep_dir(deps, dep)
      if dir then
        local key = dir .. "|" .. (deps.meta and "m" or "s")
        local list = catalog_memo[key]
        if not list then
          list = {}
          local crate = norm(dep.name)
          local dirs = { dir }
          for _, d in ipairs(manifest_deps(read_file(dir .. "/Cargo.toml") or "", true)) do
            local pd = pkg_dir(deps, d.name)
            if pd and pd ~= dir then
              dirs[#dirs + 1] = pd
            end
          end
          local names = {}
          for _, d in ipairs(dirs) do
            for _, der in ipairs(proc_macro_derives(d)) do
              if not names[der.name] then
                names[der.name] = true
                list[#list + 1] = { name = der.name, crate = crate, helpers = der.helpers, path = crate .. "::" .. der.name }
              end
            end
          end
          catalog_memo[key] = list
        end
        vim.list_extend(out, list)
      end
    end
  end
  table.sort(out, function(a, b)
    return a.name == b.name and a.crate < b.crate or a.name < b.name
  end)
  return out
end

-- ------------------------------------------------------------- treesitter

local ITEM_NODES = { struct_item = "struct", union_item = "struct", enum_item = "enum" }
local SKIP_SIBLINGS = { attribute_item = true, line_comment = true, block_comment = true }

local function attr_run(node, text)
  -- the attributes of `node`: contiguous attribute_item siblings before it
  local derives, paths = {}, {}
  local n = node and node:prev_named_sibling()
  while n and SKIP_SIBLINGS[n:type()] do
    if n:type() == "attribute_item" then
      local t = vim.treesitter.get_node_text(n, text)
      paths[#paths + 1] = t:match("^#!?%[%s*([%w_:]+)") or ""
      for inside in t:gmatch("derive%s*%(([^)]*)%)") do
        for entry in inside:gmatch("[^,]+") do
          local q = vim.trim(entry)
          local name = q:match("([%a_][%w_]*)$")
          if name then
            derives[#derives + 1] = { name = name, qual = q:match("^(.-)::[%a_][%w_]*$") }
          end
        end
      end
    end
    n = n:prev_named_sibling()
  end
  return derives, paths
end

local function skip_error(n)
  while n and n:type() == "ERROR" do
    n = n:parent()
  end
  return n
end

--- What the attribute that starts at (row0, col0) of `text` is attached to:
--- { kind = container|field|variant|fn|param|item|nil, sub = "struct"|"enum"|nil,
---   derives = { {name, qual} }, attrs = { path... } of the item }.
function M.target_of(text, row0, col0)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, "rust")
  if not ok or not parser then
    return {}
  end
  local ok2, trees = pcall(function()
    return parser:parse()
  end)
  if not ok2 or not trees[1] then
    return {}
  end
  local node = trees[1]:root():named_descendant_for_range(row0, col0, row0, col0 + 1)
  while node and node:type() ~= "attribute_item" do
    node = node:parent()
  end
  if not node then
    return {}
  end
  local parent = skip_error(node:parent())
  local ptype = parent and parent:type()
  local item, kind
  if ptype == "field_declaration_list" or ptype == "ordered_field_declaration_list" then
    kind = "field"
    item = skip_error(parent:parent())
    if item and item:type() == "enum_variant" then
      item = skip_error(skip_error(item:parent()):parent())
    end
  elseif ptype == "enum_variant_list" then
    kind = "variant"
    item = skip_error(parent:parent())
  elseif ptype == "parameters" then
    kind = "param"
    item = skip_error(parent:parent())
  else
    local sib = node:next_named_sibling()
    while sib and SKIP_SIBLINGS[sib:type()] do
      sib = sib:next_named_sibling()
    end
    item = sib
    local t = sib and sib:type()
    if t and ITEM_NODES[t] then
      kind = "container"
    elseif t == "function_item" or t == "function_signature_item" then
      kind = "fn"
    elseif t then
      kind = "item"
    end
  end
  local out = { kind = kind }
  if item and ITEM_NODES[item:type()] then
    out.sub = ITEM_NODES[item:type()]
  end
  if item then
    out.derives, out.attrs = attr_run(item, text)
  end
  out.derives = out.derives or {}
  out.attrs = out.attrs or {}
  return out
end

local function applies(list, target)
  if not list or #list == 0 or not target.kind then
    return true
  end
  for _, a in ipairs(list) do
    if a == target.kind or (target.sub and a == target.kind .. ":" .. target.sub) then
      return true
    end
  end
  return false
end

-- ----------------------------------------------------------- scope checks

local function use_statements(text)
  local out = {}
  for stmt in text:gmatch("%f[%w_]use%s+([^;{}]-%b{}[^;]-);") do
    out[#out + 1] = stmt
  end
  for stmt in text:gmatch("%f[%w_]use%s+([^;{}]-);") do
    out[#out + 1] = stmt
  end
  return out
end

local function word_in(s, w)
  return s:find("%f[%w_]" .. w .. "%f[^%w_]") ~= nil
end

--- Where is `name` imported from, per the buffer's use statements? set of first path
--- segments (empty when it is not imported).
local function imported_from(uses, name)
  local set = {}
  for _, stmt in ipairs(uses) do
    if word_in(stmt, name) then
      local first = stmt:match("^%s*:?:?([%w_]+)")
      if first then
        set[norm(first)] = true
      end
    end
  end
  return set
end

--- Is `name` usable unqualified in the buffer (imported or glob-imported from `crate`)?
local function in_scope(uses, name, crate)
  for _, stmt in ipairs(uses) do
    if word_in(stmt, name) then
      return true
    end
    if crate and stmt:match("^%s*" .. crate .. "::%*%s*$") then
      return true
    end
  end
  return false
end

--- Does the item carry a derive that belongs to crate `crate` and is listed in `names`?
local function derive_ok(crate, names, target, uses)
  if not target.kind then
    return true -- treesitter could not place the attribute: do not hide anything
  end
  for _, d in ipairs(target.derives) do
    if vim.tbl_contains(names, d.name) then
      if d.qual then
        if norm(d.qual:match("^%s*:?:?([%w_]+)") or "") == crate then
          return true
        end
      else
        local from = imported_from(uses, d.name)
        if next(from) == nil or from[crate] then
          return true
        end
      end
    end
  end
  return false
end

local function path_matches(attr_name, path, uses)
  path = path:gsub("^::", "")
  if attr_name == path then
    return true
  end
  local crate, last = attr_name:match("^([%w_]+)::([%w_]+)$")
  if crate and path == last then
    for _, stmt in ipairs(uses) do
      if stmt:match("^%s*" .. crate .. "::") and word_in(stmt, last) then
        return true
      end
    end
  end
  return false
end

-- ------------------------------------------------------------------ items

local KIND = vim.lsp.protocol.CompletionItemKind

local function hint(arg)
  local k = arg.kind
  if k == "flag" then
    return "flag"
  elseif k == "string" then
    return '= "…"'
  elseif k == "enum" then
    return "= " .. (arg.quoted and '"one of …"' or "one of …")
  elseif k == "bool" then
    return "bool"
  elseif k == "int" then
    return "= number"
  end
  return "= " .. k
end

local function snippet_for(arg)
  if arg.snippet then
    return arg.snippet
  end
  local k = arg.kind
  if k == "flag" or k == "bool" then
    return arg.key
  elseif k == "string" then
    return arg.key .. ' = "$1"'
  elseif k == "enum" then
    if arg.quoted then
      return arg.key .. ' = "$1"'
    end
    return arg.key .. " = $1"
  elseif k == "int" then
    return arg.key .. " = ${1:0}"
  elseif k == "path" or k == "ident" then
    return arg.key .. " = ${1:path}"
  end
  return arg.key .. " = ${1:expr}"
end

local function doc_text(arg, attr, file)
  local lines = { ("**%s**"):format(arg.key:gsub("%*", "")) .. (arg.doc and arg.doc ~= "" and (" — " .. arg.doc) or "") }
  local meta = {}
  if arg.applies_to then
    meta[#meta + 1] = "applies to: " .. table.concat(arg.applies_to, ", ")
  end
  if arg.since then
    meta[#meta + 1] = "since " .. file.crate .. " " .. arg.since
  end
  if arg.conflicts and #arg.conflicts > 0 then
    meta[#meta + 1] = "conflicts with: " .. table.concat(arg.conflicts, ", ")
  end
  if arg.requires and #arg.requires > 0 then
    meta[#meta + 1] = "requires: " .. table.concat(arg.requires, ", ")
  end
  if arg.kind == "enum" and arg.values then
    local vs = {}
    for _, v in ipairs(arg.values) do
      vs[#vs + 1] = type(v) == "table" and v.value or v
    end
    meta[#meta + 1] = "values: " .. table.concat(vs, ", ")
  end
  if #meta > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = table.concat(meta, "  \n")
  end
  local url = arg.doc_url or attr.docs_url or file.docs_url
  if url then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("[docs](%s)"):format(url)
  end
  return table.concat(lines, "\n")
end

local function key_item(arg, attr, file, order, label, snippet, doc, unmet)
  local sort = arg.positional and "0" or (unmet and "9" or "5")
  return {
    label = label or arg.key,
    kind = KIND.Property,
    detail = ("%s · %s"):format(file.crate, hint(arg)),
    documentation = { kind = "markdown", value = doc or doc_text(arg, attr, file) },
    insertText = snippet or snippet_for(arg),
    insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet,
    sortText = ("%s%06d"):format(sort, math.floor(order * 100)),
    filterText = (label or arg.key):match("^[%w_]+") or arg.key,
    data = { macro_attrs = "key", retrigger = arg.kind == "enum" and arg.quoted or nil },
  }
end

--- Is `arg` allowed here: target, version, derive, and the keys already present.
local function arg_allowed(arg, target, version, uses, file)
  if not applies(arg.applies_to, target) then
    return false
  end
  if arg.since and version and cm.valid_version(version) and cm.compare_versions(version, arg.since) < 0 then
    return false
  end
  if arg.derives and target.kind and target.kind ~= "param" and #target.derives > 0 then
    if not derive_ok(norm(file.crate), arg.derives, target, uses) then
      return false
    end
  end
  return true
end

local function conflicts_with_seen(arg, attr, seen)
  if seen[arg.key] and not arg.repeatable then
    return true
  end
  for _, c in ipairs(arg.conflicts or {}) do
    if seen[c] then
      return true
    end
  end
  for _, other in ipairs(attr.args) do
    if seen[other.key] and other.conflicts and vim.tbl_contains(other.conflicts, arg.key) then
      return true
    end
  end
  return false
end

--- Keys (or values) of the schema attributes that match the cursor's attribute.
local function schema_items(ctx, target, deps, schemas, uses, path)
  local items, matched = {}, {}
  for crate, file in pairs(schemas) do
    local dep = deps.by_name[norm(crate)]
    if dep and M.satisfies(dep.version, file.versions) then
      for _, attr in ipairs(file.attributes) do
        if path_matches(attr.name, path, uses) and applies(attr.applies_to, target) then
          local scope = true
          if attr.derives then
            scope = derive_ok(norm(crate), attr.derives, target, uses)
          end
          if scope and attr.needs_attr then
            scope = false
            for _, p in ipairs(target.attrs or {}) do
              scope = scope or vim.tbl_contains(attr.needs_attr, p)
            end
          end
          if scope and target.kind == "param" and not attr.needs_attr then
            scope = false
          end
          if scope then
            matched[#matched + 1] = { attr = attr, file = file, dep = dep }
          end
        end
      end
    end
  end
  table.sort(matched, function(a, b)
    return a.file.crate < b.file.crate
  end)
  local order = 0
  local dedupe = {}
  for _, m in ipairs(matched) do
    local attr, file = m.attr, m.file
    if ctx.mode == "key" then
      if ctx.nested then
        local parent = vim.tbl_filter(function(a)
          return a.key == ctx.nested
        end, attr.args)[1]
        for _, k in ipairs(parent and parent.nested or {}) do
          if not ctx.seen[k] and not dedupe["n" .. k] then
            dedupe["n" .. k] = true
            order = order + 1
            items[#items + 1] = key_item({ key = k, kind = "string", doc = ("Applies to %s only."):format(k) }, attr, file, order, k, k .. ' = "$1"')
            items[#items].documentation.value = ("**%s(%s = …)** — %s"):format(parent.key, k, parent.doc or "")
          end
        end
      else
        for _, arg in ipairs(attr.args) do
          order = order + 1
          if
            not dedupe[arg.key]
            and arg_allowed(arg, target, m.dep.version, uses, file)
            and not conflicts_with_seen(arg, attr, ctx.seen)
            and not (arg.positional and ctx.entries > 0)
          then
            dedupe[arg.key] = true
            local unmet = false
            for _, r in ipairs(arg.requires or {}) do
              unmet = unmet or not ctx.seen[r]
            end
            items[#items + 1] = key_item(arg, attr, file, order, nil, nil, nil, unmet)
            for n, alt in ipairs(arg.alt or {}) do
              items[#items + 1] = key_item(arg, attr, file, order + n / 100, alt.label, alt.snippet, alt.doc and ("**%s** — %s"):format(alt.label, alt.doc), unmet)
            end
          end
        end
      end
    else -- value
      for _, arg in ipairs(attr.args) do
        local def
        if ctx.nested then
          if arg.key == ctx.nested and vim.tbl_contains(arg.nested or {}, ctx.key) then
            def = { key = ctx.key, kind = "string" }
          end
        elseif arg.key == ctx.key then
          def = arg
        end
        if def and not dedupe[def.key] then
          dedupe[def.key] = true
          local values = def.values
          if def.kind == "bool" then
            values = { "true", "false" }
          end
          for i, v in ipairs(values or {}) do
            local value = type(v) == "table" and v.value or v
            local vdoc = type(v) == "table" and v.doc or nil
            local text = value
            if def.quoted and not ctx.in_string then
              text = '"' .. value .. '"'
            end
            items[#items + 1] = {
              label = value,
              kind = KIND.EnumMember,
              detail = ("%s · %s"):format(file.crate, def.key),
              documentation = { kind = "markdown", value = ("`%s = %s`%s"):format(def.key, def.quoted and ('"' .. value .. '"') or value, vdoc and ("\n\n" .. vdoc) or "") },
              insertText = text,
              insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
              sortText = ("%04d"):format(i),
              data = { macro_attrs = "value" },
            }
          end
        end
      end
    end
  end
  return items, #matched > 0
end

-- ----------------------------------------------------- learn from usage

local SCAN_SKIP = { target = true, [".git"] = true, node_modules = true, [".cargo"] = true }

local function scan_files(dir, exts, max_files, max_bytes)
  local out, bytes = {}, 0
  local function walk(d, depth)
    if depth > 6 or #out >= max_files or bytes >= max_bytes then
      return
    end
    local sub = {}
    for name, kind in vim.fs.dir(d) do
      if kind == "file" and exts[name:match("%.(%w+)$") or ""] then
        local st = vim.uv.fs_stat(d .. "/" .. name)
        if st and st.size < 400 * 1024 and #out < max_files and bytes < max_bytes then
          out[#out + 1] = d .. "/" .. name
          bytes = bytes + st.size
        end
      elseif kind == "directory" and not SCAN_SKIP[name] then
        sub[#sub + 1] = d .. "/" .. name
      end
    end
    for _, s in ipairs(sub) do
      walk(s, depth + 1)
    end
  end
  walk(dir, 0)
  return out
end

--- Top-level keys of an attribute body `a = 1, b(c), d`: { "a", "b", "d" }.
local function body_keys(body)
  local keys = {}
  local depth, in_str, at_start = 0, false, true
  local i = 1
  while i <= #body do
    local c = body:sub(i, i)
    if in_str then
      if c == "\\" then
        i = i + 1
      elseif c == '"' then
        in_str = false
      end
    elseif c == '"' then
      in_str = true
      at_start = false
    elseif c == "(" or c == "[" or c == "{" then
      depth = depth + 1
    elseif c == ")" or c == "]" or c == "}" then
      depth = depth - 1
    elseif c == "," and depth == 0 then
      at_start = true
    elseif at_start and depth == 0 and c:match("[%a_]") then
      local id = body:match("^[%w_]+", i)
      keys[#keys + 1] = id
      at_start = false
      i = i + #id - 1
    elseif not c:match("%s") then
      at_start = false
    end
    i = i + 1
  end
  return keys
end

local function count_keys(files, path, counts)
  local needle = "#[" .. path
  for _, f in ipairs(files) do
    local text = read_file(f)
    if text then
      local from = 1
      while true do
        local s, e = text:find(needle, from, true)
        if not s then
          break
        end
        local open = text:match("^%s*()%(", e + 1)
        if open then
          local body = balanced(text, open)
          if body then
            for _, k in ipairs(body_keys(body)) do
              counts[k] = (counts[k] or 0) + 1
            end
          end
        end
        from = e + 1
      end
    end
  end
end

local learned = {}
--- Keys written inside #[path(...)] in the workspace and in the sources of
--- `dep_dirs`, by frequency: { { key, ws, dep } } (cached, bounded scans).
function M.learn(root, path, dep_dirs, member_dirs)
  local key = root .. "\0" .. path
  local hit = learned[key]
  if hit and os.time() - hit.at < M.config.learn_ttl then
    return hit.list
  end
  local ws, dp = {}, {}
  for _, d in ipairs(member_dirs) do
    count_keys(scan_files(d, { rs = true }, M.config.learn_max_files, M.config.learn_max_bytes), path, ws)
  end
  for _, d in ipairs(dep_dirs) do
    count_keys(scan_files(d, { rs = true, md = true }, M.config.learn_max_files, M.config.learn_max_bytes), path, dp)
  end
  local list = {}
  for k, n in pairs(ws) do
    list[#list + 1] = { key = k, ws = n, dep = dp[k] or 0 }
  end
  for k, n in pairs(dp) do
    if not ws[k] then
      list[#list + 1] = { key = k, ws = 0, dep = n }
    end
  end
  table.sort(list, function(a, b)
    local sa, sb = a.ws * 2 + a.dep, b.ws * 2 + b.dep
    return sa == sb and a.key < b.key or sa > sb
  end)
  learned[key] = { at = os.time(), list = list }
  return list
end

local function learn_items(ctx, target, deps, catalog, uses, path, root)
  local dirs, crates = {}, {}
  -- the dependency that owns this attribute: the derive helper (derive in scope) or the
  -- crate named by a path-qualified attribute macro
  local qual = path:match("^([%w_]+)::")
  if qual and deps.by_name[norm(qual)] then
    crates[#crates + 1] = deps.by_name[norm(qual)]
  else
    for _, der in ipairs(catalog) do
      if vim.tbl_contains(der.helpers, path) and derive_ok(der.crate, { der.name }, target, uses) then
        crates[#crates + 1] = deps.by_name[der.crate]
      end
    end
  end
  if #crates == 0 then
    return {}
  end
  for _, dep in ipairs(crates) do
    local d = dep_dir(deps, dep)
    if d then
      dirs[#dirs + 1] = d
    end
  end
  local members = {}
  for _, m in ipairs(deps.meta and deps.meta.members or {}) do
    members[#members + 1] = m.dir
  end
  if #members == 0 then
    members[1] = root
  end
  local list = M.learn(root, path, dirs, members)
  local items = {}
  for i, e in ipairs(list) do
    if not ctx.seen[e.key] and not (e.key == ctx.prefix and e.ws + e.dep <= 1) then
      items[#items + 1] = {
        label = e.key,
        kind = KIND.Property,
        detail = ("%s · seen %d×"):format(crates[1].name, e.ws + e.dep),
        documentation = { kind = "markdown", value = ("`%s` is used %d× in this workspace and %d× in the sources of `%s` (no schema for this attribute; learned from usage)."):format(e.key, e.ws, e.dep, crates[1].name) },
        insertText = e.key,
        sortText = ("%04d"):format(i),
        data = { macro_attrs = "learned" },
      }
    end
  end
  return items
end

-- ------------------------------------------------------------------ derives

local function derive_items(ctx, target, deps, uses)
  local items = {}
  local seen = ctx.seen_last
  local function add(name, crate, path, helpers, builtin, order)
    if seen[name] then
      return
    end
    local doc = ("`#[derive(%s)]`%s"):format(name, builtin and " — standard library derive." or (" — derive macro of `" .. crate .. "`."))
    if helpers and #helpers > 0 then
      doc = doc .. "\n\nHelper attributes: " .. table.concat(vim.tbl_map(function(h)
        return "`#[" .. h .. "]`"
      end, helpers), ", ")
    end
    items[#items + 1] = {
      label = name,
      kind = KIND.Class,
      detail = crate,
      documentation = { kind = "markdown", value = doc },
      insertText = name,
      sortText = ("%s%04d%s"):format(builtin and "5" or "3", order, name),
      data = { macro_attrs = "derive", crate = crate, path = path, builtin = builtin or nil, qualified = ctx.qualifier ~= nil or nil },
    }
  end
  if not ctx.qualifier then
    for i, name in ipairs(M.builtin_derives) do
      add(name, "std", name, nil, true, i)
    end
  end
  local qual = ctx.qualifier and norm(ctx.qualifier:match("^%s*:?:?([%w_]+)") or "")
  for i, der in ipairs(M.derive_catalog(deps)) do
    if not qual or qual == der.crate then
      add(der.name, der.crate, der.path, der.helpers, false, i)
    end
  end
  return items
end

-- ------------------------------------------------------------ the main entry

--- Items for the cursor at (row 1-based, col 0-based byte) of `bufnr`.
--- Returns items, info; info = { ctx, target, deps_from, matched } for :MacroAttrs and specs.
--- A slice of a big file around `row` that starts and ends at item boundaries (items
--- start at column 0 and end with a `}` at column 0), so treesitter does not parse
--- tens of thousands of lines per keystroke. Returns first, last (1-based).
local function window(lines, row)
  local first = math.max(1, row - M.config.window_lines)
  while first < row and (lines[first] == "" or lines[first]:match("^[%s}]")) do
    first = first + 1
  end
  local last = math.min(#lines, row + M.config.window_lines)
  while last > row and not lines[last]:match("^}") do
    last = last - 1
  end
  return first, math.max(last, row)
end

function M.items(bufnr, row, col)
  local all = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if not all[row] then
    return {}, {}
  end
  local lines, import_text = all, nil
  if #all > M.config.window_min then
    local first, last = window(all, row)
    lines = vim.list_slice(all, first, last)
    -- imports sit at the top of the file, outside the window
    import_text = table.concat(all, "\n", 1, math.min(#all, 400))
    row = row - first + 1
  end
  local at = attribute_at(lines, row, col)
  if not at or at.ctx.mode == "path" then
    return {}, { ctx = at and at.ctx }
  end
  local ctx = at.ctx
  local path = ctx.path
  local name = vim.api.nvim_buf_get_name(bufnr)
  local root = name ~= "" and cm.root(name) or nil
  local deps = root and M.dependencies(name, root) or { by_name = {}, from = "none" }
  local info = { ctx = ctx, deps_from = deps.from, root = root }

  -- the item the attribute belongs to, with the attribute repaired for treesitter
  local text = at.text
  if not at.closed then
    text = text:sub(1, at.end_off) .. at.closers .. text:sub(at.end_off + 1)
  end
  local target = M.target_of(text, at.attr_row - 1, at.attr_col)
  info.target = target
  local uses = use_statements(import_text and (import_text .. "\n" .. text) or text)

  if path == "derive" and #ctx.keys == 1 then
    return derive_items(ctx, target, deps, uses), info
  end
  if #ctx.keys > 2 or not root then
    return {}, info
  end
  local schemas = M.schemas(root)
  local items, matched = schema_items(ctx, target, deps, schemas, uses, path)
  info.matched = matched
  if not matched and ctx.mode == "key" and not ctx.nested then
    items = learn_items(ctx, target, deps, M.derive_catalog(deps), uses, path, root)
    info.learned = #items > 0
  end
  return items, info
end

-- ----------------------------------------------------- the blink.cmp source

local Source = {}
Source.__index = Source

local known_cache
--- Attribute paths some shipped schema describes (full and last segment).
local function known_paths()
  if not known_cache then
    known_cache = {}
    for _, file in pairs(M.shipped()) do
      for _, a in ipairs(file.attributes) do
        known_cache[a.name] = true
        known_cache[a.name:match("([%w_]+)$")] = true
      end
    end
  end
  return known_cache
end

function M.new(_)
  return setmetatable({}, Source)
end

function Source:enabled()
  return vim.bo.filetype == "rust"
end

--- Trigger characters only where this source can answer, so rust-analyzer's own
--- triggers (e.g. inside #[cfg(...)]) are not suppressed elsewhere. Measured in a real
--- terminal: without the `)` rule below, typing `#[serde(` opened no menu at all.
function Source:get_trigger_characters()
  local ok, chars = pcall(function()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local path = vim.api.nvim_get_current_line():sub(1, col):match("#!?%[%s*([%w_:]+)%s*%(")
    if path and (path == "derive" or known_paths()[path]) then
      local chars = { "(", ",", " ", '"', "=", ":" }
      -- an auto-pair types `()` and blink only sees the LAST character typed: the `)`.
      -- Between the two, that closing paren has to be the trigger.
      local line = vim.api.nvim_get_current_line()
      if line:sub(col, col) == "(" and line:sub(col + 1, col + 1) == ")" then
        chars[#chars + 1] = ")"
      end
      return chars
    end
    return {}
  end)
  return ok and chars or {}
end

function Source:get_completions(ctx, callback)
  local ok, items = pcall(M.items, ctx.bufnr, ctx.cursor[1], ctx.cursor[2])
  callback({
    items = ok and items or {},
    is_incomplete_forward = true, -- the answer depends on the keys already written
    is_incomplete_backward = true,
  })
end

-- ---------------------------------------------------------- accepting a derive

--- Hook: a derive that is not in scope was accepted. `info` = { bufnr, row, col (just
--- after the inserted name), path = "crate::Name", crate }. The default asks the
--- import engine (config.import_engine.resolve, which ranks the candidates and knows
--- the remembered choice of the project): it applies the remembered or only import,
--- else the single candidate that comes from the derive's own crate. Replace it to
--- plug in something else.
M.on_derive_accepted = function(name, info)
  local engine = require("config.import_engine")
  local attempts = 0
  local function try()
    attempts = attempts + 1
    if not vim.api.nvim_buf_is_valid(info.bufnr) then
      return
    end
    engine.resolve(name, {
      bufnr = info.bufnr,
      pos = { info.row - 1, info.col - #name },
      derive = true,
      sources = false, -- the derive comes from a dependency: no crates to add
      cb = function(res)
        local pick = res.choice
        if not pick then
          local mine = vim.tbl_filter(function(c)
            return (info.path and c.path == info.path) or (info.crate and c.crate == info.crate:gsub("%-", "_"))
          end, res.candidates)
          pick = #mine == 1 and mine[1] or nil
        end
        if pick then
          return engine.apply_candidate(info.bufnr, pick, function(done, err)
            if not done then
              vim.notify("macro_attrs: importing " .. name .. " failed: " .. tostring(err), vim.log.levels.WARN)
            end
          end)
        end
        if #res.candidates > 1 then
          return vim.notify(("macro_attrs: %d import candidates for %s, none unambiguous (:ImportName %s)"):format(#res.candidates, name, name), vim.log.levels.INFO)
        end
        if attempts < M.config.import_attempts then
          vim.defer_fn(try, M.config.import_interval)
        end
      end,
    })
  end
  try()
end

--- blink calls this when an item of this source is accepted.
function Source:execute(ctx, item, callback, default_implementation)
  default_implementation(ctx, item)
  local data = item.data or {}
  if data.retrigger then
    vim.schedule(function()
      pcall(function()
        require("blink.cmp").show()
      end)
    end)
  end
  if data.macro_attrs == "derive" and not data.builtin and not data.qualified then
    local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()
    vim.defer_fn(function()
      local ok = pcall(function()
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local uses = use_statements(table.concat(lines, "\n"))
        if in_scope(uses, item.label, data.crate) then
          return
        end
        local cur = vim.api.nvim_win_get_cursor(0)
        M.on_derive_accepted(item.label, { bufnr = bufnr, row = cur[1], col = cur[2], path = data.path, crate = data.crate })
      end)
      if not ok then
        return
      end
    end, 30)
  end
  callback()
end

-- ----------------------------------------------------------------- setup

--- :MacroAttrs shows what this source sees at the cursor (attribute, target, schemas,
--- dependency source), for debugging a missing completion.
function M.setup()
  vim.api.nvim_create_user_command("MacroAttrs", function()
    local pos = vim.api.nvim_win_get_cursor(0)
    local items, info = M.items(0, pos[1], pos[2])
    local ctx = info.ctx or {}
    local lines = {
      ("attribute: %s  mode: %s  key: %s  prefix: %q"):format(ctx.path or "(none)", ctx.mode or "-", ctx.key or "-", ctx.prefix or ""),
      ("target: %s%s  derives: %s"):format(
        info.target and info.target.kind or "?",
        info.target and info.target.sub and (":" .. info.target.sub) or "",
        table.concat(vim.tbl_map(function(d)
          return d.name
        end, info.target and info.target.derives or {}), ", ")
      ),
      ("dependencies: %s  schema matched: %s  items: %d"):format(info.deps_from or "-", tostring(info.matched), #items),
    }
    if #M.load_errors > 0 then
      lines[#lines + 1] = "schema problems: " .. table.concat(M.load_errors, "; ")
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "MacroAttrs" })
  end, { desc = "Show what the attribute-argument completion sees at the cursor" })
end

return M
