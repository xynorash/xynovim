-- Cargo features of dependencies, from the crate's own source:
--
--   * Missing-feature fix. rustc / rust-analyzer / bacon-ls report `cannot find
--     derive macro `Serialize` in this scope` when the feature that exports the
--     name is off. The name is looked up in the unpacked source of the
--     member's dependencies (lib.rs and the modules it declares, behind
--     `#[cfg(feature = "...")]`, `pub use`, `macro_rules!` and the crate's own
--     `cfg_xxx! { .. }` wrapper macros), the gate is resolved through the
--     crate's [features] table (derive = ["serde_derive"] where serde_derive
--     is an optional dependency) and the code action "Enable feature `derive`
--     of `serde`" edits Cargo.toml. The action lives in a small in-process
--     LSP client ("xynovim-features") so it shows in the normal code-action
--     menu (<leader>ca) next to rust-analyzer's own; <leader>rG applies the
--     fix for the diagnostics on the cursor line without the menu.
--   * Feature explorer :CrateFeatures [crate]: per dependency the declared
--     and effective features, what each feature unlocks (the gated pub items
--     of the same scan), the default set and an "unused?" hint for a declared
--     feature none of whose items appears in the workspace sources.
--
-- Cargo.toml edits: `cargo add <crate> --features ..` (argv, offline first) for
-- registry dependencies when a feature is switched on, a careful text edit
-- (formatting and comments kept) for everything else: switching off, renamed,
-- path and git dependencies, and when cargo add changed nothing. The member
-- that declares the dependency is edited; `workspace = true` stays and gets
-- the feature in the member's own entry (additive), the workspace table is not
-- touched. Everything that comes from the network or from files (crate and
-- feature names) is validated before it reaches an argv.
local cm = require("config.crate_meta")

local M = {}

M.config = {
  max_files = 150, -- source files read per crate scan
  max_file_bytes = 600 * 1024,
  max_unused_files = 400, -- workspace files read for the unused hint
  max_unused_bytes = 4 * 1024 * 1024,
  max_alts = 32, -- cap of the cfg alternatives of one item
}

M.client_name = "xynovim-features"
M.command = "xynovim.enable_feature"

-- ============================================================ cfg and gates
-- A gate is a DNF: a list of alternatives, each a set { feature = true } that
-- must all be on. {} (no alternative) is "never", { {} } is "always".

local ALWAYS = { {} }

local function alt_key(alt)
  local k = vim.tbl_keys(alt)
  table.sort(k)
  return table.concat(k, ",")
end

local function and_gate(a, b)
  local out, seen = {}, {}
  for _, x in ipairs(a) do
    for _, y in ipairs(b) do
      local u = vim.tbl_extend("force", {}, x, y)
      local k = alt_key(u)
      if not seen[k] and #out < M.config.max_alts then
        seen[k] = true
        out[#out + 1] = u
      end
    end
  end
  return out
end

local function or_gate(a, b)
  local out, seen = {}, {}
  for _, g in ipairs({ a, b }) do
    for _, x in ipairs(g) do
      local k = alt_key(x)
      if not seen[k] and #out < M.config.max_alts then
        seen[k] = true
        out[#out + 1] = x
      end
    end
  end
  return out
end

local function split_args(s)
  local out, depth, start, i = {}, 0, 1, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      i = s:find('"', i + 1, true) or #s
    elseif c == "(" then
      depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
    elseif c == "," and depth == 0 then
      out[#out + 1] = s:sub(start, i - 1)
      start = i + 1
    end
    i = i + 1
  end
  local last = s:sub(start)
  if last:match("%S") then
    out[#out + 1] = last
  end
  return out
end

--- The inside of a `cfg(...)` -> gate. Only `feature = ".."` matters; `not(..)`
--- and other predicates (unix, docsrs, target_*) are treated as true, `test`
--- as false (test modules are no API).
function M.parse_cfg(e)
  e = vim.trim(e)
  local f = e:match('^feature%s*=%s*"([^"]+)"$')
  if f then
    return { { [f] = true } }
  end
  local op, args = e:match("^(%a+)%s*(%b())$")
  if op == "all" then
    local g = ALWAYS
    for _, a in ipairs(split_args(args:sub(2, -2))) do
      g = and_gate(g, M.parse_cfg(a))
    end
    return g
  elseif op == "any" then
    local g = {}
    for _, a in ipairs(split_args(args:sub(2, -2))) do
      g = or_gate(g, M.parse_cfg(a))
    end
    return g
  elseif op == "not" then
    return ALWAYS
  end
  if e == "test" then
    return {}
  end
  return ALWAYS
end

-- ============================================================ source scanner

--- Comments removed (strings kept: the cfg features are in them).
local function strip(text)
  local out, last, i, n = {}, 1, 1, #text
  while i <= n do
    local j = text:find('[/"\'r]', i)
    if not j then
      break
    end
    i = j
    local c = text:sub(i, i)
    if c == "/" then
      local d = text:sub(i + 1, i + 1)
      if d == "/" then
        out[#out + 1] = text:sub(last, i - 1)
        i = text:find("\n", i, true) or n + 1
        last = i
      elseif d == "*" then
        out[#out + 1] = text:sub(last, i - 1)
        local depth, k = 1, i + 2
        while depth > 0 do
          local a = text:find("[/*]", k)
          if not a then
            k = n + 1
            break
          end
          local two = text:sub(a, a + 1)
          if two == "/*" then
            depth, k = depth + 1, a + 2
          elseif two == "*/" then
            depth, k = depth - 1, a + 2
          else
            k = a + 1
          end
        end
        out[#out + 1] = " "
        i, last = k, k
      else
        i = i + 1
      end
    elseif c == '"' then
      local k = i + 1
      while k <= n do
        local ch = text:sub(k, k)
        if ch == "\\" then
          k = k + 2
        elseif ch == '"' then
          break
        else
          k = k + 1
        end
      end
      i = k + 1
    elseif c == "r" then
      local hashes = text:match('^r(#*)"', i)
      local prev = i > 1 and text:sub(i - 1, i - 1) or ""
      if hashes and not prev:match("[%w_]") then
        local close = text:find('"' .. hashes, i + 2 + #hashes, true)
        i = close and close + 1 + #hashes or n + 1
      else
        i = i + 1
      end
    else -- a quote: char literal or lifetime
      if text:match("^'[^'\\\n]'", i) then
        i = i + 3
      elseif text:match("^'\\.[^'\n]*'", i) then
        i = text:find("'", i + 2, true) + 1
      else
        i = i + 1
      end
    end
  end
  out[#out + 1] = text:sub(last)
  return table.concat(out)
end

--- Index of the bracket that closes the one at `p` (strings and char
--- literals skipped), or nil.
local function close_of(t, p)
  local depth, i, n = 0, p, #t
  while i <= n do
    local j = t:find("[%(%)%[%]{}\"']", i)
    if not j then
      return nil
    end
    local c = t:sub(j, j)
    if c == '"' then
      local k = j + 1
      while k <= n do
        local ch = t:sub(k, k)
        if ch == "\\" then
          k = k + 2
        elseif ch == '"' then
          break
        else
          k = k + 1
        end
      end
      i = k + 1
    elseif c == "'" then
      if t:match("^'[^'\\\n]'", j) then
        i = j + 3
      elseif t:match("^'\\.[^'\n]*'", j) then
        i = t:find("'", j + 2, true) + 1
      else
        i = j + 1
      end
    else
      if c == "(" or c == "[" or c == "{" then
        depth = depth + 1
      else
        depth = depth - 1
        if depth == 0 then
          return j
        end
      end
      i = j + 1
    end
  end
  return nil
end

local function skip_ws(t, p, lim)
  local s = t:find("[^%s;]", p)
  return (s and s <= lim) and s or lim + 1
end

--- End (exclusive) of the item that starts at `p`: the first `;` or the end of
--- the first `{}` block at depth 0; for const/static only the `;` after `=`.
local function item_end(t, p, lim, is_const)
  local seen_eq = false
  while p <= lim do
    local q = t:find("[;{%(%[=\"']", p)
    if not q or q > lim then
      return lim + 1
    end
    local c = t:sub(q, q)
    if c == ";" then
      return q + 1
    elseif c == "(" or c == "[" then
      local e = close_of(t, q)
      if not e then
        return lim + 1
      end
      p = e + 1
    elseif c == "{" then
      local e = close_of(t, q)
      if not e then
        return lim + 1
      end
      if not (is_const and seen_eq) then
        return e + 1
      end
      p = e + 1
    elseif c == "=" then
      seen_eq = is_const
      p = q + 1
    elseif c == '"' then
      local e = t:match('^"[^"\\]*"', q) and select(2, t:find('^"[^"\\]*"', q))
      if not e then
        local k = q + 1
        while k <= lim do
          local ch = t:sub(k, k)
          if ch == "\\" then
            k = k + 2
          elseif ch == '"' then
            break
          else
            k = k + 1
          end
        end
        e = k
      end
      p = e + 1
    else
      p = q + 1
    end
  end
  return lim + 1
end

--- `use` tree (text between `use` and `;`) -> { {name, path} | {glob, path} }.
function M.parse_use(s)
  local out, pos = {}, 1
  local function ws()
    pos = s:find("%S", pos) or #s + 1
  end
  local function tree(prefix)
    local segs = vim.list_slice(prefix, 1, #prefix)
    while pos <= #s do
      ws()
      if s:sub(pos, pos + 1) == "::" then
        pos = pos + 2
        ws()
      end
      local c = s:sub(pos, pos)
      if c == "{" then
        pos = pos + 1
        while pos <= #s do
          ws()
          if s:sub(pos, pos) == "}" then
            pos = pos + 1
            break
          end
          local before = pos
          tree(segs)
          ws()
          if s:sub(pos, pos) == "," then
            pos = pos + 1
          end
          if pos == before then
            pos = pos + 1
          end
        end
        return
      elseif c == "*" then
        pos = pos + 1
        out[#out + 1] = { glob = true, path = segs }
        return
      end
      local id = s:match("^[%a_][%w_]*", pos)
      if not id then
        pos = pos + 1
        return
      end
      pos = pos + #id
      segs[#segs + 1] = id
      ws()
      if s:sub(pos, pos + 1) ~= "::" then
        local alias = s:match("^as%s+([%a_][%w_]*)", pos)
        if alias then
          pos = pos + #s:match("^as%s+[%a_][%w_]*", pos)
        end
        local name = alias or id
        if id == "self" and not alias then
          name = segs[#segs - 1]
        end
        if name and name ~= "_" then
          out[#out + 1] = { name = name, path = segs }
        end
        return
      end
    end
  end
  tree({})
  return out
end

local function read_file(path, max)
  local st = vim.uv.fs_stat(path)
  if not st or st.type ~= "file" or st.size > max then
    return nil, st and "big" or nil
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
  local st = path and vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. "." .. st.mtime.nsec) or "-"
end

--- The gate of a `cfg_xxx!` wrapper macro definition body (tokio style:
--- `($($item:item)*) => { $( #[cfg(feature = "x")] $item )* }`), or nil.
local function wrapper_gate(body)
  -- the transcriber's `$item` (the last one; the matcher has one too)
  local at
  for s in body:gmatch("()%$item") do
    at = s
  end
  if not at then
    return nil
  end
  local before = body:sub(1, at - 1)
  local from = 1
  while true do
    local s = before:find("$(", from, true)
    if not s then
      break
    end
    from = s + 2
  end
  local seg = before:sub(from)
  local g = ALWAYS
  local found = false
  for attr in seg:gmatch("#%s*(%b[])") do
    local cfg = attr:match("^%[%s*cfg%s*(%b())%s*%]$")
    if cfg then
      g = and_gate(g, M.parse_cfg(cfg:sub(2, -2)))
      found = true
    end
  end
  return found and g or nil
end

--- Scan a crate's source: { items = { name = { cand... } }, files, truncated }
--- cand = { gate, reach = bool, kind }. Not cached (see M.scan).
function M.scan_dir(dir)
  local ctx = {
    dir = dir,
    items = {},
    mod_items = {}, -- "a::b" -> { {name, gate} }
    globs = {},
    wrappers = {}, -- macro name -> gate
    pending = {}, -- { name, text, s, e, st }
    nfiles = 0,
    truncated = false,
  }
  local lib_text, lib_path = cm.read_lib(dir)
  if not lib_text then
    return { items = {}, files = 0, truncated = false, no_lib = true }
  end

  local function add(name, st, gate, kind, vis)
    if not name or #gate == 0 then
      return
    end
    local key = table.concat(st.mods, "::")
    ctx.mod_items[key] = ctx.mod_items[key] or {}
    table.insert(ctx.mod_items[key], { name = name, gate = gate, kind = kind })
    ctx.items[name] = ctx.items[name] or {}
    table.insert(ctx.items[name], { gate = gate, reach = vis and st.pubchain or false, kind = kind })
  end

  local parse_region

  local function load_file(path, st_parent, name, vis, gate, dir_for_children)
    if ctx.nfiles >= M.config.max_files then
      ctx.truncated = true
      return
    end
    local raw, why = read_file(path, M.config.max_file_bytes)
    if not raw then
      ctx.truncated = ctx.truncated or why == "big"
      return
    end
    ctx.nfiles = ctx.nfiles + 1
    local t = strip(raw)
    local mods = vim.list_slice(st_parent.mods, 1, #st_parent.mods)
    mods[#mods + 1] = name
    parse_region(t, 1, #t, {
      gate = gate,
      mods = mods,
      pubchain = st_parent.pubchain and vis,
      dir = dir_for_children,
    })
  end

  local function handle_mod(t, p, lim, st, name, vis, gate, path_attr)
    local q = t:find("[^%s]", p) or lim + 1
    if t:sub(q, q) == "{" and q <= lim then
      local e = close_of(t, q)
      if not e then
        return lim + 1
      end
      local mods = vim.list_slice(st.mods, 1, #st.mods)
      mods[#mods + 1] = name
      parse_region(t, q + 1, e - 1, { gate = gate, mods = mods, pubchain = st.pubchain and vis, dir = st.dir .. "/" .. name })
      return e + 1
    end
    local rel = path_attr and not path_attr:find("..", 1, true) and path_attr:sub(1, 1) ~= "/" and path_attr or nil
    local cands = rel and { st.dir .. "/" .. rel } or { st.dir .. "/" .. name .. ".rs", st.dir .. "/" .. name .. "/mod.rs" }
    for _, c in ipairs(cands) do
      if vim.uv.fs_stat(c) then
        local child_dir = c:match("/mod%.rs$") and vim.fs.dirname(c) or (st.dir .. "/" .. name)
        load_file(c, st, name, vis, gate, child_dir)
        break
      end
    end
    return q + 1
  end

  function parse_region(t, s, lim, st)
    local p = s
    local guard = 0
    while true do
      guard = guard + 1
      p = skip_ws(t, p, lim)
      if p > lim or guard > 20000 then
        break
      end
      local gate, macro_export, path_attr = st.gate, false, nil
      while t:sub(p, p) == "#" do
        local q = p + 1
        local inner = t:sub(q, q) == "!"
        if inner then
          q = q + 1
        end
        q = skip_ws(t, q, lim)
        if t:sub(q, q) ~= "[" then
          break
        end
        local close = close_of(t, q)
        if not close then
          return
        end
        local attr = t:sub(q + 1, close - 1)
        local cfg = attr:match("^%s*cfg%s*(%b())%s*$")
        if cfg and not inner then
          gate = and_gate(gate, M.parse_cfg(cfg:sub(2, -2)))
        elseif attr:match("^%s*macro_export") then
          macro_export = true
        else
          path_attr = attr:match('^%s*path%s*=%s*"([^"]+)"') or path_attr
        end
        p = skip_ws(t, close + 1, lim)
      end
      if p > lim then
        break
      end

      local vis = false
      if t:match("^pub%f[%W]", p) then
        local q = skip_ws(t, p + 3, lim)
        if t:sub(q, q) == "(" then
          p = (close_of(t, q) or lim) + 1
        else
          vis, p = true, q
        end
      end

      local word, wend = t:match("^([%a_][%w_]*)()", p)
      -- modifiers of fn / trait / impl / extern blocks
      local guard2 = 0
      while word and guard2 < 6 do
        guard2 = guard2 + 1
        local nxt = skip_ws(t, wend, lim)
        local nword = t:match("^([%a_][%w_]*)", nxt)
        if word == "async" or word == "unsafe" or word == "default" then
          p, word, wend = nxt, t:match("^([%a_][%w_]*)()", nxt)
        elseif word == "const" and (nword == "fn" or nword == "unsafe" or nword == "async" or nword == "extern") then
          p, word, wend = nxt, t:match("^([%a_][%w_]*)()", nxt)
        elseif word == "extern" and nword ~= "crate" then
          local q = nxt
          if t:sub(q, q) == '"' then
            q = skip_ws(t, (t:find('"', q + 1, true) or q) + 1, lim)
          end
          p, word, wend = q, t:match("^([%a_][%w_]*)()", q)
        else
          break
        end
      end

      if word == "use" then
        local e = item_end(t, wend, lim)
        if vis then
          for _, u in ipairs(M.parse_use(t:sub(wend, e - 2))) do
            if u.glob then
              table.insert(ctx.globs, { path = u.path, gate = gate, st = st, reach = st.pubchain })
            else
              add(u.name, st, gate, "use", true)
            end
          end
        end
        p = e
      elseif word == "mod" then
        local q = skip_ws(t, wend, lim)
        local name, nend = t:match("^([%a_][%w_]*)()", q)
        if name then
          if vis then
            add(name, st, gate, "mod", true)
          end
          p = handle_mod(t, nend, lim, st, name, vis, gate, path_attr)
        else
          p = item_end(t, wend, lim)
        end
      elseif word == "macro_rules" and t:sub(skip_ws(t, wend, lim), skip_ws(t, wend, lim)) == "!" then
        local q = skip_ws(t, skip_ws(t, wend, lim) + 1, lim)
        local name, nend = t:match("^([%a_][%w_]*)()", q)
        local b = name and skip_ws(t, nend, lim)
        local e = b and (t:sub(b, b):match("[{%(%[]") and close_of(t, b))
        if not e then
          p = item_end(t, wend, lim)
        else
          local wg = wrapper_gate(t:sub(b, e))
          if wg then
            ctx.wrappers[name] = wg
          end
          if macro_export then
            -- #[macro_export] puts it at the crate root, whatever the module
            ctx.items[name] = ctx.items[name] or {}
            table.insert(ctx.items[name], { gate = gate, reach = true, kind = "macro" })
          end
          p = e + 1
        end
      elseif word == "extern" or word == "impl" or word == "macro" then
        p = item_end(t, wend, lim)
      elseif word == "const" or word == "static" then
        local q = skip_ws(t, wend, lim)
        if t:match("^mut%f[%W]", q) then
          q = skip_ws(t, q + 3, lim)
        end
        local name = t:match("^([%a_][%w_]*)", q)
        if vis and name and name ~= "_" then
          add(name, st, gate, word, true)
        end
        p = item_end(t, wend, lim, true)
      elseif word == "fn" or word == "struct" or word == "enum" or word == "trait" or word == "type" or word == "union" then
        local name = t:match("^([%a_][%w_]*)", skip_ws(t, wend, lim))
        if vis and name then
          add(name, st, gate, word, true)
        end
        p = item_end(t, wend, lim)
      elseif word and t:sub(wend, wend) == "!" then
        -- a macro call; a wrapper macro's body is parsed with its gate (later,
        -- once every file is read: the definition may come after the use)
        local b = skip_ws(t, wend + 1, lim)
        local e = t:sub(b, b):match("[{%(%[]") and close_of(t, b)
        if e then
          ctx.pending[#ctx.pending + 1] = { name = word, t = t, s = b + 1, e = e - 1, st = st, gate = gate }
          p = e + 1
        else
          p = item_end(t, wend, lim)
        end
      else
        p = item_end(t, p, lim)
      end
    end
  end

  local t = strip(lib_text)
  ctx.nfiles = 1
  local root_st = { gate = ALWAYS, mods = {}, pubchain = true, dir = vim.fs.dirname(lib_path) }
  parse_region(t, 1, #t, root_st)

  -- wrapper-macro bodies, until no new ones turn up
  for _ = 1, 40 do
    local todo = ctx.pending
    ctx.pending = {}
    if #todo == 0 then
      break
    end
    for _, c in ipairs(todo) do
      local wg = ctx.wrappers[c.name]
      if wg then
        local st = vim.tbl_extend("force", {}, c.st, { gate = and_gate(c.gate, wg) })
        parse_region(c.t, c.s, c.e, st)
      end
    end
  end

  -- `pub use self::m::*` / `pub use m::*`: the module's pub items at this level
  for _, g in ipairs(ctx.globs) do
    local segs = vim.list_slice(g.path, 1, #g.path)
    local base = vim.list_slice(g.st.mods, 1, #g.st.mods)
    if segs[1] == "crate" then
      table.remove(segs, 1)
      base = {}
    elseif segs[1] == "self" then
      table.remove(segs, 1)
    elseif segs[1] == "super" then
      table.remove(segs, 1)
      base[#base] = nil
    end
    local key = table.concat(vim.list_extend(base, segs), "::")
    for _, it in ipairs(ctx.mod_items[key] or {}) do
      ctx.items[it.name] = ctx.items[it.name] or {}
      table.insert(ctx.items[it.name], { gate = and_gate(g.gate, it.gate), reach = g.reach, kind = it.kind })
    end
  end

  return { items = ctx.items, files = ctx.nfiles, truncated = ctx.truncated }
end

local scans = {} -- dir -> { stamp, idx }

--- Cached scan_dir (a crate in the registry never changes; a path dependency
--- is re-read when its lib.rs changes).
function M.scan(dir)
  local _, lib = cm.read_lib(dir)
  local stamp = mtime(lib)
  local hit = scans[dir]
  if hit and hit.stamp == stamp then
    return hit.idx
  end
  local idx = M.scan_dir(dir)
  scans[dir] = { stamp = stamp, idx = idx }
  return idx
end

function M.clear_cache()
  scans = {}
end

--- The gate (DNF) behind which `name` is exported by the scanned crate, or
--- nil, reason ("not found" | "ungated").
function M.gate_of(idx, name)
  local cands = idx.items[name]
  if not cands then
    return nil, "not found"
  end
  local pref = vim.tbl_filter(function(c)
    return c.reach
  end, cands)
  if #pref == 0 then
    pref = cands
  end
  local g = {}
  for _, c in ipairs(pref) do
    for _, alt in ipairs(c.gate) do
      if next(alt) == nil then
        return nil, "ungated"
      end
    end
    g = or_gate(g, c.gate)
  end
  return g
end

-- =========================================================== feature tables

local function is_implicit(ft, f)
  local v = ft[f]
  return v ~= nil and #v == 1 and v[1] == "dep:" .. f
end

--- Every feature switched on by enabling `f` (itself included).
function M.closure(ft, f, acc)
  acc = acc or {}
  if acc[f] then
    return acc
  end
  acc[f] = true
  for _, item in ipairs(ft[f] or {}) do
    if not item:match("^dep:") then
      local feat = item:match("^([^/?]+)[/?]") or item
      if ft[feat] or not item:find("/", 1, true) then
        M.closure(ft, feat, acc)
      end
    end
  end
  return acc
end

local function closure_set(ft, list)
  local acc = {}
  for _, f in ipairs(list) do
    M.closure(ft, f, acc)
  end
  return acc
end

local function count(set)
  local n = 0
  for _ in pairs(set) do
    n = n + 1
  end
  return n
end

--- Drop every feature another one of the list already implies.
local function reduce(ft, list)
  local out = {}
  for _, r in ipairs(list) do
    local implied = false
    for _, o in ipairs(list) do
      if o ~= r and M.closure(ft, o)[r] and not M.closure(ft, r)[o] then
        implied = true
      end
    end
    if not implied then
      out[#out + 1] = r
    end
  end
  table.sort(out)
  return out
end

--- The user-facing feature to switch on for the requirement `r`: `r` itself
--- unless it is only the implicit feature of an optional dependency and a
--- named feature (derive = ["serde_derive"]) switches it on.
local function nice_feature(ft, r)
  if ft[r] and not is_implicit(ft, r) then
    return r
  end
  local best, best_n
  for f in pairs(ft) do
    if f ~= r and f ~= "default" and not is_implicit(ft, f) then
      local c = M.closure(ft, f)
      if c[r] then
        local n = count(c)
        if not best or n < best_n or (n == best_n and f < best) then
          best, best_n = f, n
        end
      end
    end
  end
  return best or r
end

--- The minimal set of features to enable so that `gate` holds, given the
--- features that are on (`enabled` = set). nil when `gate` is already
--- satisfied (the name is not missing because of a feature) or cannot be.
--- Returns list, alternative-chosen.
function M.resolve(gate, ft, enabled)
  local best
  for _, alt in ipairs(gate) do
    local missing = {}
    for f in pairs(alt) do
      if not enabled[f] then
        missing[#missing + 1] = f
      end
    end
    if #missing == 0 then
      return nil, "enabled"
    end
    table.sort(missing)
    local mapped = {}
    for _, r in ipairs(missing) do
      mapped[#mapped + 1] = nice_feature(ft, r)
    end
    local list = reduce(ft, vim.fn.uniq(vim.fn.sort(mapped)))
    local key = string.format("%03d", #list) .. table.concat(list, ",")
    if not best or key < best.key then
      best = { key = key, list = list }
    end
  end
  if not best then
    return nil, "never"
  end
  return best.list
end

--- Features on for a declared dependency: the declared ones and what they
--- imply, plus the default set unless default-features = false.
function M.enabled_set(d, ft)
  local list = vim.deepcopy(d.features or {})
  if d.uses_default_features and ft.default then
    list[#list + 1] = "default"
  end
  return closure_set(ft, list)
end

--- The [features] table of a dependency (metadata first, the registry
--- manifest otherwise: the implicit features of optional deps are added).
function M.features_of(d)
  if d.resolved and d.resolved.features and next(d.resolved.features) ~= nil then
    return d.resolved.features
  end
  local dir = d.resolved and d.resolved.dir or cm.registry_dir(d.name)
  local toml = dir and cm.read_manifest(dir)
  if not toml then
    return (d.resolved and d.resolved.features) or {}
  end
  local ft = cm.parse_features(toml)
  local explicit = {}
  for _, list in pairs(ft) do
    for _, item in ipairs(list) do
      local x = item:match("^dep:(.+)$")
      if x then
        explicit[x] = true
      end
    end
  end
  local section
  for line in (toml .. "\n"):gmatch("(.-)\n") do
    local h = line:match("^%[(.-)%]")
    if h then
      section = h
      local n = h:match("^dependencies%.([%w_%-]+)$") or h:match("^target%..*%.dependencies%.([%w_%-]+)$")
      if n then
        section = { name = n }
      end
    end
    local name = type(section) == "string" and (section == "dependencies" or section:match("^target%..*%.dependencies$")) and line:match("^([%w_%-]+)%s*=.*optional%s*=%s*true")
    if type(section) == "table" and line:match("^optional%s*=%s*true") then
      name = section.name
    end
    if name and not explicit[name] and not ft[name] then
      ft[name] = { "dep:" .. name }
    end
  end
  return ft
end

-- ================================================== diagnostics -> names

local function ident(s)
  return s and s:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

--- Names a rustc / rust-analyzer message says it cannot find:
--- { { name, qual } } (qual: the path before the name, when the message has one).
function M.names_from_message(msg)
  local out, seen = {}, {}
  local function add(path, qual)
    path = path:gsub("^::", "")
    local head, last = path:match("^(.*)::([^:]+)$")
    local name = last or path
    qual = qual or (head and head:match("^([^:]+)")) or nil
    if ident(name) and not seen[name] then
      seen[name] = true
      out[#out + 1] = { name = name, qual = qual }
    end
  end
  for n in msg:gmatch("cannot find [%w%- ]-`([^`]+)`") do
    add(n)
  end
  for n, q in msg:gmatch("could not find `([^`]+)` in `([^`]+)`") do
    add(n, (q:match("^([^:]+)")))
  end
  for n, q in msg:gmatch("no `([^`]+)` in `([^`]+)`") do
    add(n, (q:match("^([^:]+)")))
  end
  for n in msg:gmatch("unresolved import `([^`]+)`") do
    add(n)
  end
  for n in msg:gmatch("unresolved macro `([^`]+)`") do
    add(n)
  end
  for n in msg:gmatch("no `([^`]+)` in the root") do
    add(n)
  end
  for n in msg:gmatch("failed to resolve: could not find `([^`]+)`") do
    add(n)
  end
  return out
end

local function vim_diag(d)
  return {
    message = d.message or "",
    lnum = d.lnum or (d.range and d.range.start.line) or 0,
    col = d.col or (d.range and d.range.start.character) or 0,
    end_lnum = d.end_lnum or (d.range and d.range["end"].line),
    end_col = d.end_col or (d.range and d.range["end"].character),
  }
end

local function diag_names(d, lines)
  local names = M.names_from_message(d.message)
  if #names > 0 or not (d.message:match("[Uu]nresolved") or d.message:match("cannot find") or d.message:match("could not find")) then
    return names
  end
  -- no name in the message: the identifier under the diagnostic, when it
  -- sits in an attribute (`#[derive(Serialize)]`, `#[tokio::main]`)
  local line = lines[d.lnum + 1] or ""
  if line:find("#%s*%[") and (d.end_lnum == nil or d.end_lnum == d.lnum) and d.end_col then
    local path = line:sub(d.col + 1, d.end_col):match("^[%a_][%w_:]*$")
    if path then
      local head, last = path:match("^(.*)::([^:]+)$")
      names[1] = { name = last or path, qual = head and head:match("^([^:]+)") or nil }
    end
  end
  return names
end

-- ================================================================ suggest

local function kind_of_file(file)
  if file:match("/build%.rs$") then
    return "build"
  end
  if file:match("/tests/") or file:match("/examples/") or file:match("/benches/") then
    return "dev"
  end
  return "normal"
end

--- Does `lines` mention `name` imported or written through the alias?
local function mentions_via(text, alias, name)
  for usepath in text:gmatch("use%s+" .. alias .. "%s*::(.-);") do
    if usepath:find("%f[%w_]" .. name .. "%f[^%w_]") then
      return true
    end
  end
  return text:find(alias .. "%s*::[%w_:%s{},]-%f[%w_]" .. name .. "%f[^%w_]") ~= nil
end

--- Suggestions for the diagnostics of a file, from the metadata of its
--- workspace. diags: vim.Diagnostic-like { message, lnum, col, end_lnum,
--- end_col } (0-based). Pure apart from the cached source scans.
--- Returns { { name, crate, alias, features, member, manifest, kind, truncated } }
function M.suggest(meta, file, lines, diags)
  local out, seen = {}, {}
  local member = cm.member_of(meta, file)
  local text = table.concat(lines, "\n")
  local want_kind = kind_of_file(file)
  local deps = {}
  for _, d in ipairs(meta.dependencies) do
    if not member or d.member == member.name then
      deps[#deps + 1] = d
    end
  end
  -- the kind the file belongs to first (a test file reads dev-dependencies too)
  table.sort(deps, function(a, b)
    local ra, rb = a.kind == want_kind and 0 or 1, b.kind == want_kind and 0 or 1
    return ra < rb
  end)
  for _, diag in ipairs(diags) do
    local dd = vim_diag(diag)
    for _, n in ipairs(diag_names(dd, lines)) do
      local cands = deps
      local hinted = {}
      for _, d in ipairs(deps) do
        if (n.qual and (n.qual == d.alias or n.qual == d.name)) or mentions_via(text, d.alias, n.name) then
          hinted[#hinted + 1] = d
        end
      end
      if #hinted > 0 then
        cands = hinted
      end
      for _, d in ipairs(cands) do
        local key = d.member .. "|" .. d.kind .. "|" .. d.name .. "|" .. n.name
        local dir = d.resolved and d.resolved.dir
        if not (dir and vim.uv.fs_stat(dir)) then
          dir = cm.registry_dir(d.name, d.resolved and d.resolved.version)
        end
        if dir and not seen[key] and cm.valid_name(d.name) then
          seen[key] = true
          local idx = M.scan(dir)
          local gate = M.gate_of(idx, n.name)
          if gate then
            local ft = M.features_of(d)
            local feats = M.resolve(gate, ft, M.enabled_set(d, ft))
            if feats and #feats > 0 then
              local dup = false
              for _, s in ipairs(out) do
                if s.member == d.member and s.kind == d.kind and s.crate == d.name and table.concat(s.features, ",") == table.concat(feats, ",") then
                  dup = true
                  s.names[#s.names + 1] = n.name
                end
              end
              if not dup then
                out[#out + 1] = {
                  name = n.name,
                  names = { n.name },
                  crate = d.name,
                  alias = d.alias,
                  features = feats,
                  member = d.member,
                  manifest = d.member_manifest,
                  kind = d.kind,
                  target = d.target,
                  truncated = idx.truncated,
                }
              end
            end
          end
        end
      end
    end
  end
  return out
end

function M.title(s)
  local q = vim.tbl_map(function(f)
    return "`" .. f .. "`"
  end, s.features)
  return ("Enable feature%s %s of `%s`"):format(#q > 1 and "s" or "", table.concat(q, ", "), s.crate)
end

-- ============================================================ Cargo.toml edit

local KIND_SECTION = { normal = "dependencies", dev = "dev-dependencies", build = "build-dependencies" }

local function norm_header(h)
  return (h:gsub("[%s\"']", ""))
end

local function key_pat(key)
  return (key:gsub("[%-%.]", "%%%0"))
end

local function split_lines(text)
  local lines, p = {}, 1
  while p <= #text + 1 do
    local nl = text:find("\n", p, true)
    local e = nl and nl - 1 or #text
    lines[#lines + 1] = { s = p, e = e, t = text:sub(p, e) }
    if not nl then
      break
    end
    p = nl + 1
  end
  return lines
end

--- Add (op = "add") or remove a feature in the array whose `[` is at `lb`.
--- Returns the new text, or nil when nothing changes.
local function array_edit(text, lb, op, feature)
  -- one walk over the array: `#` comments (which may hold `[` or `]`) are skipped, both
  -- "basic" and 'literal' strings are items
  local rb
  local items = {}
  local i = lb + 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == '"' or c == "'" then
      local e = text:find(c, i + 1, true) or #text
      items[#items + 1] = { s = i, e = e, v = text:sub(i + 1, e - 1) }
      i = e + 1
    elseif c == "#" then
      i = (text:find("\n", i, true) or #text) + 1
    elseif c == "]" then
      rb = i
      break
    else
      i = i + 1
    end
  end
  if not rb then
    return nil
  end
  local inner = text:sub(lb + 1, rb - 1)
  if op == "add" then
    for _, it in ipairs(items) do
      if it.v == feature then
        return nil
      end
    end
    local q = '"' .. feature .. '"'
    if #items == 0 then
      return text:sub(1, lb) .. q .. text:sub(rb)
    end
    local last = items[#items]
    local ins
    if inner:find("\n", 1, true) then
      local ls = last.s
      while ls > 1 and text:sub(ls - 1, ls - 1) ~= "\n" do
        ls = ls - 1
      end
      local indent = text:sub(ls, last.s - 1):match("^%s*") or "  "
      ins = ",\n" .. indent .. q
    else
      ins = ", " .. q
    end
    return text:sub(1, last.e) .. ins .. text:sub(last.e + 1)
  end
  for k, it in ipairs(items) do
    if it.v == feature then
      local s, e = it.s, it.e
      local after = text:match("^[ \t]*,[ \t]*()", e + 1)
      if after then
        e = after - 1
      else
        local before = text:sub(1, s - 1):match("(),[ \t\n]*$")
        if before then
          s = before
        end
      end
      return text:sub(1, s - 1) .. text:sub(e + 1)
    end
  end
  return nil
end

--- Add or remove `features` for dependency `spec.key` in the dependency table
--- of `spec.kind` (and `spec.target`) of a Cargo.toml text. spec = { key,
--- kind, target, workspace }. Returns new text or nil, reason.
function M.edit_manifest(text, spec, op, features)
  local lines = split_lines(text)
  local suffix = spec.workspace and "workspace.dependencies" or KIND_SECTION[spec.kind or "normal"]
  local want = suffix
  if spec.target and not spec.workspace then
    want = "target." .. norm_header(spec.target) .. "." .. suffix
  end
  local kp = key_pat(spec.key)
  local secs

  local result = text
  local function apply_one(f)
    local cur = result
    lines = split_lines(cur)
    -- recompute section ranges on the current text
    secs = {}
    for i, l in ipairs(lines) do
      local h = l.t:match("^%s*%[([%w_%-%.\"' ()%%=,:]-)%]%s*#?.*$")
      if h and not l.t:match("^%s*%[%[") then
        if #secs > 0 then
          secs[#secs].last = i - 1
        end
        secs[#secs + 1] = { name = norm_header(h), first = i }
      end
    end
    if #secs > 0 then
      secs[#secs].last = #lines
    end

    for _, sec in ipairs(secs) do
      if sec.name == want .. "." .. spec.key then
        -- [dependencies.serde]
        for i = sec.first + 1, sec.last do
          local l = lines[i]
          local lb = l.t:match("^%s*features%s*=%s*()%[")
          if lb then
            local new = array_edit(cur, l.s + lb - 1, op, f)
            return new, new == nil and (op == "add" and "already enabled in this manifest" or "feature not declared in this manifest") or nil
          end
        end
        if op == "remove" then
          return nil, "feature not declared in this manifest"
        end
        local at = sec.last
        while at > sec.first and lines[at].t:match("^%s*$") do
          at = at - 1
        end
        local ins = lines[at].e
        return cur:sub(1, ins) .. '\nfeatures = ["' .. f .. '"]' .. cur:sub(ins + 1)
      elseif sec.name == want then
        -- dotted keys: serde.workspace = true / serde.features = [..]
        local last_dotted
        for i = sec.first + 1, sec.last do
          local l = lines[i]
          local dk = l.t:match("^%s*[\"']?" .. kp .. "[\"']?%.([%w_%-]+)%s*=")
          if dk then
            last_dotted = i
            if dk == "features" then
              local lb = l.t:match("=%s*()%[")
              if lb then
                local new = array_edit(cur, l.s + lb - 1, op, f)
                return new, new == nil and (op == "add" and "already enabled in this manifest" or "feature not declared in this manifest") or nil
              end
            end
          end
        end
        if last_dotted then
          if op == "remove" then
            return nil, "feature not declared in this manifest"
          end
          local l = lines[last_dotted]
          local indent = l.t:match("^%s*")
          return cur:sub(1, l.e) .. "\n" .. indent .. spec.key .. '.features = ["' .. f .. '"]' .. cur:sub(l.e + 1)
        end
        for i = sec.first + 1, sec.last do
          local l = lines[i]
          local vstart = l.t:match("^%s*[\"']?" .. kp .. "[\"']?%s*=%s*()")
          if vstart then
            local abs = l.s + vstart - 1
            local c = cur:sub(abs, abs)
            if c == '"' then
              if op == "remove" then
                return nil, "feature not declared in this manifest"
              end
              local e = cur:find('"', abs + 1, true)
              local ver = cur:sub(abs + 1, (e or abs + 1) - 1)
              return cur:sub(1, abs - 1) .. '{ version = "' .. ver .. '", features = ["' .. f .. '"] }' .. cur:sub((e or abs) + 1)
            elseif c == "{" then
              local e = close_of(cur, abs)
              if not e then
                return nil, "cannot read the dependency entry"
              end
              local tbl = cur:sub(abs, e)
              local fl = tbl:match("[{,%s]features%s*=%s*()%[")
              if fl then
                local new = array_edit(cur, abs + fl - 1, op, f)
                return new, new == nil and (op == "add" and "already enabled in this manifest" or "feature not declared in this manifest") or nil
              end
              if op == "remove" then
                return nil, "feature not declared in this manifest"
              end
              local inner = tbl:sub(2, -2):gsub("%s+$", "")
              local ins
              if inner:match("^%s*$") then
                ins = '{ features = ["' .. f .. '"] }'
              else
                ins = "{" .. inner .. (inner:match(",$") and "" or ",") .. ' features = ["' .. f .. '"] }'
              end
              return cur:sub(1, abs - 1) .. ins .. cur:sub(e + 1)
            end
            return nil, "cannot read the dependency entry"
          end
        end
      end
    end
    return nil, "dependency `" .. spec.key .. "` is not declared in this manifest"
  end

  local changed, last_why = false, nil
  for _, f in ipairs(features) do
    local new, why = apply_one(f)
    if new then
      result, changed = new, true
    elseif why and (why:match("^dependency") or why:match("^cannot read")) then
      return nil, why
    else
      last_why = why
    end
  end
  if not changed then
    return nil, last_why or (op == "add" and "already enabled in this manifest" or "feature not declared in this manifest")
  end
  return result
end

-- ============================================================ applying edits

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_all(path, text)
  -- a symlinked Cargo.toml: rename onto the real file, or the link is replaced by a copy
  path = vim.uv.fs_realpath(path) or path
  local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
  local f = io.open(tmp, "wb")
  if not f then
    return false
  end
  f:write(text)
  f:close()
  local st = vim.uv.fs_stat(path)
  if st then
    pcall(vim.uv.fs_chmod, tmp, st.mode % 4096)
  end
  return vim.uv.fs_rename(tmp, path) and true or false
end

local function manifest_buffer_modified(manifest)
  local b = vim.fn.bufnr(manifest)
  return b > 0 and vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified
end

local function valid_features(list)
  if type(list) ~= "table" or #list == 0 then
    return false
  end
  for _, f in ipairs(list) do
    if type(f) ~= "string" or not f:match("^[A-Za-z0-9_.-]+$") or #f > 64 then
      return false
    end
  end
  return true
end

local function after_edit(manifest)
  cm.invalidate()
  -- the edit did not go through a buffer save: restart bacon-ls like a save of Cargo.toml would
  pcall(require("config.rust_restart").manifest_saved, manifest)
  -- an open, unmodified Cargo.toml buffer picks the new text up
  pcall(vim.cmd, "silent! checktime")
end

--- Switch features of the dependency entry `d` (a cargo metadata dependency of
--- crate_meta) on or off in its member's Cargo.toml. cb(ok, how_or_err), how =
--- "cargo add" | "text edit".
function M.set_features(d, features, on, cb)
  if not valid_features(features) or not cm.valid_name(d.name) then
    return vim.schedule(function()
      cb(false, "invalid crate or feature name")
    end)
  end
  local manifest = d.member_manifest
  if manifest_buffer_modified(manifest) then
    return vim.schedule(function()
      cb(false, manifest .. " has unsaved changes: save it first")
    end)
  end
  local before = read_all(manifest)
  if not before then
    return vim.schedule(function()
      cb(false, "cannot read " .. manifest)
    end)
  end
  local function text_edit()
    local spec = { key = d.rename or d.name, kind = d.kind, target = d.target }
    local cur = read_all(manifest) or before
    local new, why = M.edit_manifest(cur, spec, on and "add" or "remove", features)
    if not new then
      -- already in the manifest after cargo add changed it: fine
      return cb(false, why)
    end
    if not write_all(manifest, new) then
      return cb(false, "cannot write " .. manifest)
    end
    after_edit(manifest)
    cb(true, "text edit")
  end

  local registry = d.source and d.source:match("^registry") ~= nil
  if not on or d.rename or not registry then
    return vim.schedule(text_edit)
  end

  local function argv(offline)
    local a = { "cargo", "add", d.name, "--features", table.concat(features, ","), "--manifest-path", manifest }
    if d.kind == "dev" then
      a[#a + 1] = "--dev"
    elseif d.kind == "build" then
      a[#a + 1] = "--build"
    end
    if d.target then
      vim.list_extend(a, { "--target", d.target })
    end
    if offline then
      a[#a + 1] = "--offline"
    end
    return a
  end
  local function done_ok()
    local now = read_all(manifest) or ""
    local all = now ~= before
    for _, f in ipairs(features) do
      all = all and now:find('"' .. f .. '"', 1, true) ~= nil
    end
    if all then
      after_edit(manifest)
      return cb(true, "cargo add")
    end
    text_edit()
  end
  cm.exec(argv(true), { cwd = vim.fs.dirname(manifest), timeout = 60000 }, function(r1)
    if r1.code == 0 then
      return done_ok()
    end
    cm.exec(argv(false), { cwd = vim.fs.dirname(manifest), timeout = 60000 }, function(r2)
      if r2.code == 0 then
        return done_ok()
      end
      text_edit() -- cargo add refused or is missing: edit the text
    end)
  end)
end

--- Find the dependency entry of a suggestion (or command argument) again in
--- fresh metadata.
local function find_dep(meta, arg)
  for _, d in ipairs(meta.dependencies) do
    if d.member == arg.member and d.kind == arg.kind and d.name == arg.crate and d.target == arg.target then
      return d
    end
  end
end

--- Apply a suggestion: { root, member, kind, crate, features, target }.
--- cb(ok, how_or_err).
function M.apply(arg, cb)
  cm.metadata_async(arg.root, function(meta, err)
    if not meta then
      return cb(false, err or "no cargo metadata")
    end
    local d = find_dep(meta, arg)
    if not d then
      return cb(false, ("`%s` is not a dependency of `%s` any more"):format(arg.crate, arg.member))
    end
    M.set_features(d, arg.features, true, function(ok, how)
      if ok then
        vim.notify(("Enabled %s of `%s` in %s (%s)"):format(table.concat(arg.features, ", "), arg.crate, vim.fn.fnamemodify(d.member_manifest, ":~:."), how), vim.log.levels.INFO)
      else
        vim.notify(("Could not enable %s of `%s`: %s"):format(table.concat(arg.features, ", "), arg.crate, how or "?"), vim.log.levels.WARN)
      end
      cb(ok, how)
    end)
  end)
end

-- =========================================================== the code action

local function collect_diags(bufnr, from_line, to_line, extra)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr)) do
    if d.lnum <= to_line and (d.end_lnum or d.lnum) >= from_line then
      out[#out + 1] = d
    end
  end
  for _, d in ipairs(extra or {}) do
    out[#out + 1] = d
  end
  return out
end

--- cb(suggestions, root)
function M.suggest_async(bufnr, diags, cb)
  local file = vim.api.nvim_buf_get_name(bufnr)
  local root = file ~= "" and cm.root(file) or nil
  if not root or #diags == 0 then
    return vim.schedule(function()
      cb({}, root)
    end)
  end
  cm.metadata_async(root, function(meta)
    if not meta then
      return cb({}, root)
    end
    local ok, res = pcall(M.suggest, meta, file, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), diags)
    local list = ok and res or {}
    for _, s in ipairs(list) do
      s.root = root
    end
    cb(list, root)
  end)
end

local function action_of(s)
  return {
    title = M.title(s),
    kind = "quickfix",
    command = {
      title = M.title(s),
      command = M.command,
      arguments = { { root = s.root, member = s.member, kind = s.kind, crate = s.crate, features = s.features, target = s.target } },
    },
  }
end

local function make_server(dispatchers)
  local closing = false
  local next_id = 0
  local srv = {}
  -- on_exit exactly once, from exit and from terminate: a client that never
  -- reports it stays in vim.lsp.get_clients() as a stopped entry
  local function close()
    if not closing then
      closing = true
      dispatchers.on_exit(0, 0)
    end
  end
  function srv.request(method, params, callback)
    next_id = next_id + 1
    local id = next_id
    if method == "initialize" then
      callback(nil, {
        capabilities = {
          codeActionProvider = { codeActionKinds = { "quickfix" } },
          executeCommandProvider = { commands = { M.command } },
        },
        serverInfo = { name = M.client_name },
      })
    elseif method == "textDocument/codeAction" then
      local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
      local diags = collect_diags(bufnr, params.range.start.line, params.range["end"].line)
      M.suggest_async(bufnr, diags, function(list)
        callback(nil, vim.tbl_map(action_of, list))
      end)
    elseif method == "workspace/executeCommand" then
      local arg = params.arguments and params.arguments[1]
      if params.command ~= M.command or type(arg) ~= "table" or not valid_features(arg.features) or not cm.valid_name(arg.crate or "") then
        return callback({ code = -32602, message = "bad arguments" }), id
      end
      M.apply(arg, function(ok, how)
        callback(not ok and { code = -32603, message = tostring(how) } or nil, nil)
      end)
    else
      callback(nil, nil)
    end
    return true, id
  end
  function srv.notify(method)
    if method == "exit" then
      close()
    end
    return true
  end
  function srv.is_closing()
    return closing
  end
  function srv.terminate()
    close()
  end
  return srv
end

--- Start (or reuse) the in-process client for a Rust buffer.
function M.attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then
    return
  end
  local root = cm.root(file) or vim.fs.dirname(file)
  pcall(vim.lsp.start, { name = M.client_name, cmd = make_server, root_dir = root }, { bufnr = bufnr, silent = true })
end

--- Fix the diagnostics on the cursor line (all lines of a visual range) with
--- one command: no menu when there is a single suggestion.
function M.fix_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local l = vim.api.nvim_win_get_cursor(0)[1] - 1
  M.suggest_async(bufnr, collect_diags(bufnr, l, l), function(list)
    if #list == 0 then
      return vim.notify("No missing-feature fix for the diagnostics on this line", vim.log.levels.INFO)
    end
    if #list == 1 then
      return M.apply(list[1], function() end)
    end
    vim.ui.select(list, { prompt = "Enable feature", format_item = M.title }, function(choice)
      if choice then
        M.apply(choice, function() end)
      end
    end)
  end)
end

-- ============================================================ the explorer

--- Words of the workspace sources (cached for a few seconds).
local words_cache = {}
local function workspace_words(meta)
  local hit = words_cache[meta.root]
  if hit and os.time() - hit.at < 30 then
    return hit.words, hit.truncated
  end
  local words, files, bytes, truncated = {}, 0, 0, false
  for _, m in ipairs(meta.members) do
    for _, sub in ipairs({ "src", "tests", "examples", "benches", "build.rs" }) do
      local p = m.dir .. "/" .. sub
      local list = {}
      if sub == "build.rs" then
        list = { p }
      else
        for name, t in vim.fs.dir(p, { depth = 8 }) do
          if t == "file" and name:match("%.rs$") then
            list[#list + 1] = p .. "/" .. name
          end
        end
      end
      for _, f in ipairs(list) do
        if files >= M.config.max_unused_files or bytes >= M.config.max_unused_bytes then
          truncated = true
          break
        end
        local text = read_file(f, M.config.max_file_bytes)
        if text then
          files, bytes = files + 1, bytes + #text
          for w in strip(text):gmatch("[%a_][%w_]*") do
            words[w] = true
          end
        end
      end
    end
  end
  words_cache[meta.root] = { words = words, at = os.time(), truncated = truncated }
  return words, truncated
end

--- Everything the explorer shows about one dependency entry.
--- { crate, version, member, kind, default = {..}, truncated, scanned_files,
---   features = { { name, declared, on, implicit, in_default, implies = {..},
---   items = {..}, unused } } }
function M.explore(meta, d)
  local ft = M.features_of(d)
  local declared = {}
  for _, f in ipairs(d.features or {}) do
    declared[f] = true
  end
  local on = M.enabled_set(d, ft)
  for _, f in ipairs(d.resolved and d.resolved.enabled_features or {}) do
    on[f] = on[f] or "unified"
  end
  local default_set = ft.default and M.closure(ft, "default") or {}
  local dir = d.resolved and d.resolved.dir
  if not (dir and vim.uv.fs_stat(dir)) then
    dir = cm.registry_dir(d.name, d.resolved and d.resolved.version)
  end
  local idx = dir and M.scan(dir) or { items = {}, files = 0, truncated = false }

  -- item -> the features that unlock it (from scratch)
  local unlocks = {}
  for name in pairs(idx.items) do
    local gate = M.gate_of(idx, name)
    if gate then
      local feats = M.resolve(gate, ft, {})
      for _, f in ipairs(feats or {}) do
        unlocks[f] = unlocks[f] or {}
        table.insert(unlocks[f], name)
      end
    end
  end
  local words, words_truncated = workspace_words(meta)

  local list = {}
  for f, v in pairs(ft) do
    local items = unlocks[f] or {}
    table.sort(items)
    local implies = {}
    for g in pairs(M.closure(ft, f)) do
      if g ~= f then
        implies[#implies + 1] = g
      end
    end
    table.sort(implies)
    local used = false
    for _, it in ipairs(items) do
      used = used or words[it] == true
    end
    list[#list + 1] = {
      name = f,
      declared = declared[f] or false,
      on = on[f] and true or false,
      via_default = d.uses_default_features and default_set[f] and not declared[f] or false,
      unified = on[f] == "unified",
      implicit = is_implicit(ft, f),
      in_default = default_set[f] or false,
      implies = implies,
      items = items,
      unused = (declared[f] or false) and #items > 0 and not used,
    }
  end
  table.sort(list, function(a, b)
    if a.implicit ~= b.implicit then
      return not a.implicit
    end
    return a.name < b.name
  end)
  local default_list = vim.tbl_filter(function(f)
    return f ~= "default"
  end, vim.tbl_keys(default_set))
  table.sort(default_list)
  return {
    crate = d.name,
    alias = d.alias,
    version = d.resolved and d.resolved.version,
    member = d.member,
    kind = d.kind,
    uses_default_features = d.uses_default_features,
    default = default_list,
    features = list,
    truncated = idx.truncated,
    scanned_files = idx.files,
    words_truncated = words_truncated,
    dep = d,
  }
end

--- One line of the feature list.
function M.feature_line(f)
  local mark = f.declared and "[x]" or (f.on and "[~]" or "[ ]")
  local bits = {}
  if f.in_default then
    bits[#bits + 1] = "default"
  end
  if f.via_default then
    bits[#bits + 1] = "on by default"
  elseif f.on and not f.declared then
    bits[#bits + 1] = f.unified and "on (other crate)" or "on (implied)"
  end
  if #f.items > 0 then
    local shown = vim.list_slice(f.items, 1, 4)
    bits[#bits + 1] = "unlocks " .. table.concat(shown, ", ") .. (#f.items > 4 and (" +" .. (#f.items - 4)) or "")
  end
  if f.unused then
    bits[#bits + 1] = "unused?"
  end
  return mark .. " " .. f.name .. (#bits > 0 and ("  " .. table.concat(bits, "; ")) or "")
end

--- Preview text of a feature.
function M.feature_preview(info, f)
  local out = { "# " .. info.crate .. " " .. (info.version or "") .. " / " .. f.name, "" }
  out[#out + 1] = "declared in Cargo.toml: " .. (f.declared and "yes" or "no") .. "; effective: " .. (f.on and "yes" or "no")
  if #f.implies > 0 then
    out[#out + 1] = "implies: " .. table.concat(f.implies, ", ")
  end
  if f.implicit then
    out[#out + 1] = "(implicit feature of the optional dependency `" .. f.name .. "`)"
  end
  out[#out + 1] = ""
  if #f.items > 0 then
    out[#out + 1] = "unlocks (" .. #f.items .. "):"
    for i, it in ipairs(f.items) do
      if i > 200 then
        out[#out + 1] = "  ..."
        break
      end
      out[#out + 1] = "  " .. it
    end
  else
    out[#out + 1] = "no gated public item found by the source scan"
  end
  if f.unused then
    out[#out + 1] = ""
    out[#out + 1] = "unused?: none of these names appears in the workspace sources"
  end
  if info.truncated then
    out[#out + 1] = ""
    out[#out + 1] = ("(the source scan stopped after %d files: the list can be incomplete)"):format(info.scanned_files)
  end
  return out
end

--- The picker. Specs replace it. items = { { text, data } }, opts = { title,
--- preview = fn(item) -> lines, on_confirm = fn(item), on_toggle = fn(item) }.
function M.pick(items, opts)
  local Snacks = rawget(_G, "Snacks")
  if Snacks and Snacks.picker and Snacks.picker.pick then
    local snacks_items = {}
    for _, it in ipairs(items) do
      snacks_items[#snacks_items + 1] = { text = it.text, data = it.data }
    end
    local function toggle(picker, item)
      if item and opts.on_toggle then
        picker:close()
        vim.schedule(function()
          opts.on_toggle(item)
        end)
      end
    end
    return Snacks.picker.pick({
      title = opts.title,
      items = snacks_items,
      format = function(item)
        return { { item.text } }
      end,
      preview = opts.preview and function(ctx)
        ctx.preview:reset()
        ctx.preview:set_lines(opts.preview(ctx.item))
        ctx.preview:highlight({ ft = "markdown" })
      end or "none", -- the default previews item.file: an error plus a table dump for these
      confirm = function(picker, item)
        if not item then
          return
        end
        picker:close()
        vim.schedule(function()
          (opts.on_confirm or opts.on_toggle)(item)
        end)
      end,
      actions = { toggle_feature = toggle },
      win = {
        input = { keys = { ["<C-t>"] = { "toggle_feature", mode = { "i", "n" }, desc = "Toggle feature" } } },
        list = { keys = { ["t"] = "toggle_feature" } },
      },
    })
  end
  vim.ui.select(items, {
    prompt = opts.title,
    format_item = function(it)
      return it.text
    end,
  }, function(choice)
    if choice then
      (opts.on_confirm or opts.on_toggle)(choice)
    end
  end)
end

local open_features

local function toggle_feature(info, f)
  local d = info.dep
  local features = { f.name }
  -- declared in this manifest: remove it; anything else (off, on by default,
  -- implied, unified from another crate) is switched on by declaring it
  local turn_on = not f.declared
  M.set_features(d, features, turn_on, function(ok, how)
    if ok then
      vim.notify(("%s feature `%s` of `%s` (%s)"):format(turn_on and "Enabled" or "Disabled", f.name, info.crate, how), vim.log.levels.INFO)
    else
      vim.notify(("Cannot %s `%s`: %s"):format(turn_on and "enable" or "disable", f.name, how or "?"), vim.log.levels.WARN)
    end
    -- the manifest changed: show the list again with fresh metadata
    cm.metadata_async(info.root, function(meta)
      if meta then
        local nd = find_dep(meta, { member = d.member, kind = d.kind, crate = d.name, target = d.target })
        if nd then
          open_features(meta, nd, info.root)
        end
      end
    end, { refresh = true })
  end)
end

function open_features(meta, d, root)
  local info = M.explore(meta, d)
  info.root = root
  local items = {}
  for _, f in ipairs(info.features) do
    items[#items + 1] = { text = M.feature_line(f), data = f }
  end
  local title = ("%s %s  (%s%s)  default: %s%s"):format(
    info.crate,
    info.version or "",
    info.member,
    info.kind ~= "normal" and (", " .. info.kind) or "",
    info.uses_default_features and (#info.default > 0 and table.concat(info.default, ", ") or "none") or "off",
    info.truncated and "  [scan capped]" or ""
  )
  M.pick(items, {
    title = title .. "  <CR>/<C-t> toggle",
    preview = function(item)
      return M.feature_preview(info, item.data)
    end,
    on_toggle = function(item)
      toggle_feature(info, item.data)
    end,
  })
  return info
end

--- :CrateFeatures [crate]
function M.open(crate)
  local root = cm.root()
  if not root then
    return vim.notify("CrateFeatures: not in a cargo workspace", vim.log.levels.WARN)
  end
  cm.metadata_async(root, function(meta, err)
    if not meta then
      return vim.notify("CrateFeatures: " .. tostring(err), vim.log.levels.WARN)
    end
    local deps = vim.tbl_filter(function(d)
      return not crate or crate == "" or d.name == crate or d.alias == crate
    end, meta.dependencies)
    if #deps == 0 then
      return vim.notify(("CrateFeatures: no dependency %s"):format(crate and ("`" .. crate .. "`") or ""), vim.log.levels.WARN)
    end
    if #deps == 1 then
      return open_features(meta, deps[1], root)
    end
    local items = {}
    for _, d in ipairs(deps) do
      local declared = #d.features > 0 and table.concat(d.features, ", ") or "-"
      items[#items + 1] = {
        text = ("%s %s  %s%s  features: %s%s"):format(d.name, d.resolved and d.resolved.version or "", d.member, d.kind ~= "normal" and (" (" .. d.kind .. ")") or "", declared, d.uses_default_features and "" or "  (no default)"),
        data = d,
      }
    end
    M.pick(items, {
      title = "Dependencies  <CR> features",
      on_confirm = function(item)
        open_features(meta, item.data, root)
      end,
    })
  end)
end

function M.complete()
  local root = cm.root()
  local seen, out = {}, {}
  local meta = root and cm.metadata(root, { timeout = 3000 })
  for _, d in ipairs(meta and meta.dependencies or {}) do
    if not seen[d.name] then
      seen[d.name] = true
      out[#out + 1] = d.name
    end
  end
  table.sort(out)
  return out
end

-- ================================================================== setup

local did_setup = false

--- What a Rust buffer gets: the in-process client and <leader>rG (free: checked
--- against every global and Rust mapping of this config; <leader>rE is "Open
--- docs").
function M.on_rust_buffer(buf)
  M.attach(buf)
  vim.keymap.set("n", "<leader>rG", M.fix_at_cursor, { buffer = buf, desc = "Fix missing crate feature" })
end

function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  local group = vim.api.nvim_create_augroup("xynovim_crate_features", { clear = true })

  vim.api.nvim_create_user_command("CrateFeatures", function(o)
    M.open(o.args)
  end, {
    nargs = "?",
    desc = "Explore and toggle the cargo features of a dependency",
    complete = function(lead)
      return vim.tbl_filter(function(n)
        return vim.startswith(n, lead)
      end, M.complete())
    end,
  })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "rust",
    callback = function(ev)
      M.on_rust_buffer(ev.buf)
    end,
  })
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "rust" then
      M.on_rust_buffer(b)
    end
  end
end

return M
