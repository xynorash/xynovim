-- Rainbow brackets, after the JetBrains plugin "Rainbow Brackets" (izhangzhihao/intellij-rainbow-brackets),
-- natively on Neovim's tree-sitter trees. Not a wrapper around rainbow-delimiters.nvim: that plugin keeps a
-- hand-written query per language, has no unmatched-bracket marking, no scope highlighting, no contrast
-- guarantee, and is not installed here; this module needs no new dependency (supply-chain policy) and its
-- engine is language independent. See docs/RAINBOW.md for the option table and the feature map.
--
-- How a bracket is coloured (the same rule the JetBrains plugin uses on its PSI tree): a *pair* is a
-- node's direct children that are an open and the matching close bracket token (so `Foo(a)` in a pattern,
-- `pub(crate)`, `#[attr]`, `a[i]`, `{ ... }`, `<T>` all count wherever the tokens sit among the children).
-- The level of a bracket is the number of enclosing pairs, and the colour is level mod number-of-colours.
-- Strings, comments, char literals and lifetimes are never tokens of a pair, so nothing inside them is
-- touched; a comparison `<` has no partner `>` among its siblings (and sits in no generics node), so it is
-- not a bracket either. Only the visible lines are looked at (a decoration provider with ephemeral
-- extmarks), and the per-buffer caches are keyed on `changedtick`, so a huge file costs what the window costs.
local api = vim.api

local M = {}

local ns = api.nvim_create_namespace("xyno_rainbow")
M.ns = ns

-- ---------------------------------------------------------------------------------------- options

local DEFAULTS = {
  enabled = true,
  -- which bracket kinds are coloured (the plugin's four switches, plus Rust's closure pipes)
  round = true,
  square = true,
  curly = true,
  angle = true,
  pipe = true,
  mismatch = true, -- mark unmatched brackets (the plugin does not; VS Code does)
  colors = 6, -- number of colours in the cycle (1..16; the colour-blind set has 8)
  cycle_all_types = true, -- one level counter for all kinds; false = every kind counts its own nesting
  skip_first_level = false, -- leave the outermost level (level 0) uncoloured
  palette = "auto", -- auto | island | colorblind | custom
  custom = {}, -- palette = "custom": a list of "#rrggbb", or { all = {...}, round = {...}, ... }
  min_contrast = "auto", -- auto = 3 (7 with vim.g.xynovim_contrast = "high"), or a number 1..21
  generator = { enabled = false, hue = "any", luminosity = "bright" },
  priority = 130, -- above treesitter (100) and LSP semantic tokens (125)
  max_lines = 0, -- 0 = no limit; N = files with more lines get no colours (the plugin's default is 1000)
  large = "on", -- "on" = also in large-file tier 1 (only the visible lines are ever processed), "off"
  disable = {}, -- filetypes, tree-sitter languages or file extensions that are left alone
  scope = {
    alpha = 0.2, -- the scope tint: its rainbow colour mixed this much into the editor background
    restrain_strength = 0.65, -- how far the text outside the scope is dimmed towards the background
    restrain_keep_colors = false, -- dim with a blend and keep the syntax colours
    any_key = false, -- false: ESC clears the scope highlight; true: any key does
    mouse = true, -- <C-RightMouse> highlights, <A-RightMouse> restrains
    box = "inverse", -- how the two brackets of the scope are drawn: inverse | underline | none
    suppress_debug = false,
    suppress_diff = false,
  },
}
M.DEFAULTS = DEFAULTS

local HUES = { "any", "red", "orange", "yellow", "green", "blue", "purple", "pink", "monochrome" }

--- spec: "boolean" | "string" | { int = {lo, hi} } | { num = {lo, hi} } | { enum = {...} } | function(v) -> ok, value
local function strlist(v)
  if type(v) ~= "table" then
    return false
  end
  local out = {}
  for _, s in ipairs(v) do
    if type(s) ~= "string" then
      return false
    end
    out[#out + 1] = s:lower():gsub("^%.", "")
  end
  return true, out
end

local function colorlist(v)
  local P = require("config.rainbow_palette")
  if type(v) ~= "table" then
    return false
  end
  local function one(list)
    if type(list) ~= "table" then
      return nil
    end
    local out = {}
    for _, c in ipairs(list) do
      local n = P.normalize(c)
      if not n then
        return nil
      end
      out[#out + 1] = n
    end
    return out
  end
  local out = {}
  if vim.islist(v) then
    if #v > 0 then
      local l = one(v)
      if not l then
        return false
      end
      out.all = l
    end
    return true, out
  end
  for k, list in pairs(v) do
    if k ~= "all" and not vim.tbl_contains(P.KINDS, k) then
      return false
    end
    local l = one(list)
    if not l then
      return false
    end
    out[k] = l
  end
  return true, out
end

local SPEC = {
  enabled = "boolean",
  round = "boolean",
  square = "boolean",
  curly = "boolean",
  angle = "boolean",
  pipe = "boolean",
  mismatch = "boolean",
  colors = { int = { 1, 16 } },
  cycle_all_types = "boolean",
  skip_first_level = "boolean",
  palette = { enum = { "auto", "island", "colorblind", "custom" } },
  custom = colorlist,
  min_contrast = function(v)
    if v == "auto" or (type(v) == "number" and v >= 1 and v <= 21) then
      return true, v
    end
    return false
  end,
  generator = {
    enabled = "boolean",
    hue = function(v)
      if type(v) == "string" and vim.tbl_contains(HUES, v) then
        return true, v
      end
      local n = require("config.rainbow_palette").normalize(v)
      return n ~= nil, n
    end,
    luminosity = { enum = { "bright", "light", "dark" } },
  },
  priority = { int = { 1, 65535 } },
  max_lines = { int = { 0, 100000000 } },
  large = { enum = { "on", "off" } },
  disable = strlist,
  scope = {
    alpha = { num = { 0, 1 } },
    restrain_strength = { num = { 0, 1 } },
    restrain_keep_colors = "boolean",
    any_key = "boolean",
    mouse = "boolean",
    box = { enum = { "inverse", "underline", "none" } },
    suppress_debug = "boolean",
    suppress_diff = "boolean",
  },
}
M.SPEC = SPEC

local function check(spec, v)
  if spec == "boolean" or spec == "string" then
    return type(v) == spec, v
  elseif type(spec) == "function" then
    return spec(v)
  elseif spec.int then
    return type(v) == "number" and v == math.floor(v) and v >= spec.int[1] and v <= spec.int[2], v
  elseif spec.num then
    return type(v) == "number" and v >= spec.num[1] and v <= spec.num[2], v
  elseif spec.enum then
    return type(v) == "string" and vim.tbl_contains(spec.enum, v), v
  end
  return false
end

local function describe(spec)
  if spec == "boolean" then
    return "true or false"
  elseif type(spec) == "function" then
    return "a value of the documented form"
  elseif spec.int then
    return ("an integer %d..%d"):format(spec.int[1], spec.int[2])
  elseif spec.num then
    return ("a number %g..%g"):format(spec.num[1], spec.num[2])
  elseif spec.enum then
    return "one of " .. table.concat(spec.enum, ", ")
  end
  return "?"
end

--- Merge `user` over `base` (a resolved table), checking every key against SPEC. Problems are appended
--- to `problems` as strings; an invalid or unknown key keeps the value it had.
local function merge(base, user, spec, path, problems)
  for k, v in pairs(user) do
    local p = path .. k
    local s = spec[k]
    if s == nil then
      problems[#problems + 1] = ("unknown option %s"):format(p)
    elseif type(s) == "table" and not (s.int or s.num or s.enum) then
      if type(v) == "table" then
        merge(base[k], v, s, p .. ".", problems)
      else
        problems[#problems + 1] = ("%s must be a table"):format(p)
      end
    else
      local ok, val = check(s, v)
      if ok then
        base[k] = val
      else
        problems[#problems + 1] = ("%s: %s is not valid (expected %s)"):format(p, vim.inspect(v), describe(s))
      end
    end
  end
end

--- Resolve options: defaults < saved (`:XynoRainbow save`) < vim.g.xynovim_rainbow. Pure.
---@return table opts, string[] problems
function M.resolve_options(user, saved)
  local o = vim.deepcopy(DEFAULTS)
  local problems = {}
  if user == false then
    o.enabled = false
    return o, problems
  end
  if saved then
    merge(o, saved, SPEC, "", {})
  end
  if user ~= nil then
    if type(user) ~= "table" then
      problems[1] = "vim.g.xynovim_rainbow must be a table (or false)"
    else
      merge(o, user, SPEC, "", problems)
    end
  end
  return o, problems
end

-- ---------------------------------------------------------------------------------------- state

local S = {
  opts = vim.deepcopy(DEFAULTS),
  problems = {},
  groups = nil, -- { by_kind, count, palette }
  queries = {},
  cache = {}, -- per window: the last list of marks
  version = 0,
  lang_off = {}, -- languages named in the `disable` list (also for injected trees)
  ready = false,
  stats = { redraws = 0, rebuilt = 0, last_us = 0, max_us = 0 },
}
M._state = S

function M.opts()
  return S.opts
end

function M.problems()
  return S.problems
end

-- ---------------------------------------------------------------------------------------- tokens

-- token text -> { kind, closes } for openers; CLOSER[text] = kind
local OPENER = {
  ["("] = { "round", ")" },
  ["["] = { "square", "]" },
  ["{"] = { "curly", "}" },
  ["${"] = { "curly", "}" },
  ["<"] = { "angle", ">" },
}
local CLOSER = { [")"] = "round", ["]"] = "square", ["}"] = "curly", [">"] = "angle" }

-- Nodes whose `<` `>` children are a bracket pair (everywhere else `<` is an operator or a template).
local ANGLE_HOSTS = {
  rust = { type_arguments = 1, type_parameters = 1, bracketed_type = 1, for_lifetimes = 1 },
  cpp = { template_argument_list = 1, template_parameter_list = 1 },
  java = { type_arguments = 1, type_parameters = 1 },
  typescript = { type_arguments = 1, type_parameters = 1 },
  tsx = { type_arguments = 1, type_parameters = 1 },
  c_sharp = { type_argument_list = 1, type_parameter_list = 1 },
  kotlin = { type_arguments = 1, type_parameters = 1 },
  swift = { type_arguments = 1, type_parameters = 1 },
}
-- Rust closure parameters: `|a, b|` (the same character opens and closes)
local PIPE_HOSTS = { rust = { closure_parameters = 1 } }

-- Languages that are text or patterns, not code: markdown prose, Lua patterns and regexes in strings (a lone `(`
-- or `[` there is usually meant literally), comments, doc comments, diffs. Brackets in them are left alone, like
-- the JetBrains plugin leaves strings and comments alone; a fenced code block of markdown is a tree of its own
-- language and is coloured.
local NON_CODE = {
  markdown = true,
  markdown_inline = true,
  luap = true,
  regex = true,
  printf = true,
  comment = true,
  luadoc = true,
  jsdoc = true,
  vimdoc = true,
  gitcommit = true,
  diff = true,
  rst = true,
  git_rebase = true,
}

local BAD = {} -- marker for an unmatched bracket token

local function enabled_kind(kind)
  return S.opts[kind] ~= false
end

local function query_for(lang)
  local q = S.queries[lang]
  if q ~= nil then
    return q
  end
  local cand = { "(", ")", "[", "]", "{", "}", "${" }
  if ANGLE_HOSTS[lang] then
    cand[#cand + 1] = "<"
    cand[#cand + 1] = ">"
  end
  if PIPE_HOSTS[lang] then
    cand[#cand + 1] = "|"
  end
  local function try(list)
    local parts = {}
    for _, t in ipairs(list) do
      parts[#parts + 1] = '"' .. t .. '"'
    end
    return pcall(vim.treesitter.query.parse, lang, "[" .. table.concat(parts, " ") .. "] @b")
  end
  local ok, parsed = try(cand)
  if not ok then
    local good = {}
    for _, t in ipairs(cand) do
      if try({ t }) then
        good[#good + 1] = t
      end
    end
    parsed = #good > 0 and select(2, try(good)) or false
  end
  S.queries[lang] = parsed or false
  return S.queries[lang]
end

-- ---------------------------------------------------------------------------------------- host scan

local FULL_SCAN = 128 -- hosts with more children are only looked at at both ends (a block is `{ ... }`)

local function build_host(node, lang, toks, full)
  local ntype = node:type()
  local pairs_, byid = {}, {}
  local stack = {}
  local angle_ok = ANGLE_HOSTS[lang] and ANGLE_HOSTS[lang][ntype]
  local pipes = PIPE_HOSTS[lang] and PIPE_HOSTS[lang][ntype] and {} or nil

  local function mkpair(kind, o, c)
    local orow, ocol = o:range()
    local crow, ccol, cerow, cecol = c:range()
    local p =
      { kind = kind, o = o, c = c, orow = orow, ocol = ocol, crow = crow, ccol = ccol, cerow = cerow, cecol = cecol }
    pairs_[#pairs_ + 1] = p
    byid[o:id()] = p
    byid[c:id()] = p
  end

  for _, t in ipairs(toks) do
    local text = t:type()
    if text == "|" then
      if pipes and enabled_kind("pipe") then
        pipes[#pipes + 1] = t
      end
    else
      local op = OPENER[text]
      if op then
        if (op[1] ~= "angle" or angle_ok) and enabled_kind(op[1]) then
          stack[#stack + 1] = { t = t, kind = op[1], close = op[2] }
        end
      else
        local kind = CLOSER[text]
        if kind and (kind ~= "angle" or angle_ok) and enabled_kind(kind) then
          local top = stack[#stack]
          if t:missing() then
            -- the parser invented this close: its open is unmatched
            if top and top.kind == kind then
              stack[#stack] = nil
              if full then
                byid[top.t:id()] = BAD
              end
            end
          elseif top and top.kind == kind then
            stack[#stack] = nil
            mkpair(kind, top.t, t)
          elseif full then
            byid[t:id()] = BAD
          end
        end
      end
    end
  end
  if full then
    for _, s in ipairs(stack) do
      byid[s.t:id()] = BAD
    end
  end
  if pipes and #pipes == 2 then
    mkpair("pipe", pipes[1], pipes[2])
  end
  if #pairs_ == 0 and next(byid) == nil then
    return false
  end
  return { pairs = pairs_, byid = byid, err = node:has_error() }
end

local function host_info(m, node, lang)
  local id = node:id()
  local h = m.hosts[id]
  if h ~= nil then
    return h
  end
  h = false
  local n = node:child_count()
  if n >= 1 then
    local toks = {}
    local function consider(c)
      if c and not c:named() then
        local t = c:type()
        if OPENER[t] or CLOSER[t] or t == "|" then
          toks[#toks + 1] = c
        end
      end
    end
    local full = n <= FULL_SCAN
    if full then
      for c in node:iter_children() do
        consider(c)
      end
    else
      for i = 0, 3 do
        consider(node:child(i))
      end
      for i = n - 4, n - 1 do
        consider(node:child(i))
      end
    end
    if #toks >= 1 then
      h = build_host(node, lang, toks, full)
    end
  end
  m.hosts[id] = h
  return h
end

local function before(r1, c1, r2, c2)
  return r1 < r2 or (r1 == r2 and c1 < c2)
end

--- number of pairs of `node` (of `key` kind, "*" = all) that strictly enclose (row, col)
local function count_in(m, node, lang, row, col, key)
  local h = host_info(m, node, lang)
  if not h then
    return 0
  end
  local n = 0
  for _, p in ipairs(h.pairs) do
    if (key == "*" or p.kind == key) and before(p.orow, p.ocol, row, col) and before(row, col, p.crow, p.ccol) then
      n = n + 1
    end
  end
  return n
end

--- The level of `node`: enclosing pairs (all kinds, or only `key`) above it. Memoised per buffer state.
local function level(m, lang, node, key)
  local memo = m.depth[key]
  if not memo then
    memo = {}
    m.depth[key] = memo
  end
  local got = memo[node:id()]
  if got then
    return got
  end
  local chain = {}
  local cur, parent = node, nil
  local run = 0
  while true do
    local mv = memo[cur:id()]
    if mv then
      run, parent = mv, cur
      break
    end
    chain[#chain + 1] = cur
    local p = cur:parent()
    if not p then
      break
    end
    cur = p
  end
  for i = #chain, 1, -1 do
    local x = chain[i]
    local a = 0
    if parent then
      local r, c = x:start()
      a = run + count_in(m, parent, lang, r, c, key)
    end
    memo[x:id()] = a
    run, parent = a, x
  end
  return memo[node:id()]
end

-- One memo per tree-sitter tree object. An edit changes the tree in place (same object, new `changedtick`)
-- and a finished parse brings a new object, so the memo is valid for exactly one (tree, tick) pair; it is
-- keyed weakly, so it goes away with its tree. (Node ids are addresses: never keep them across trees.)
local TREE_MEMO = setmetatable({}, { __mode = "k" })

local function memo_for(tree, tick)
  local m = TREE_MEMO[tree]
  if not m or m.tick ~= tick or m.version ~= S.version then
    m = { tick = tick, version = S.version, hosts = {}, depth = {} }
    TREE_MEMO[tree] = m
  end
  return m
end

-- ---------------------------------------------------------------------------------------- collecting

--- Levels contributed by the trees around an injected tree (0 for the root tree).
local function base_level(ltree, tree, tick)
  local parent = ltree:parent()
  if not parent or not S.opts.cycle_all_types then
    return 0
  end
  local r, c = tree:root():start()
  local ptree = parent:tree_for_range({ r, c, r, c }, { ignore_injections = true })
  if not ptree then
    return 0
  end
  local n = ptree:root():descendant_for_range(r, c, r, c)
  if not n then
    return 0
  end
  local m = memo_for(ptree, tick)
  local lang = parent:lang()
  return base_level(parent, ptree, tick) + level(m, lang, n, "*") + count_in(m, n, lang, r, c, "*")
end

local function group_for(kind, lvl)
  local list = S.groups.by_kind[kind]
  return list[lvl % #list + 1]
end

--- Marks for the rows [srow, erow] of `buf`: list of { row, col, end_col, group }.
---@param parser vim.treesitter.LanguageTree
function M.collect(buf, parser, srow, erow)
  local tick = api.nvim_buf_get_changedtick(buf)
  local marks, seen = {}, {}
  local o = S.opts
  local key_all = o.cycle_all_types
  parser:for_each_tree(function(tree, ltree)
    local lang = ltree:lang()
    local par = ltree:parent()
    if par and par:lang() == lang then
      return -- rust inside rust (macro bodies): the outer tree has the token trees already
    end
    if NON_CODE[lang] or S.lang_off[lang] then
      return
    end
    local q = query_for(lang)
    if not q then
      return
    end
    local m = memo_for(tree, tick)
    local base = par and base_level(ltree, tree, tick) or 0
    for _, node in q:iter_captures(tree:root(), buf, srow, erow + 1) do
      local r, c, _, ec = node:range()
      local host = node:parent()
      if host and r >= srow and r <= erow then
        local h = host_info(m, host, lang)
        local p = h and h.byid[node:id()] or nil
        if p ~= nil then
          local cell = r * 1048576 + c
          if not seen[cell] then
            seen[cell] = true
            if p == BAD then
              if o.mismatch and h.err then
                marks[#marks + 1] = { r, c, ec, "XynoRainbowMismatch" }
              end
            else
              local lvl = level(m, lang, node, key_all and "*" or p.kind) + base
              if not (o.skip_first_level and lvl == 0) then
                marks[#marks + 1] = { r, c, ec, group_for(p.kind, lvl) }
              end
            end
          end
        end
      end
    end
  end)
  return marks
end

--- The innermost pair around (row, col), brackets included, or nil.
--- { kind, o = {row, col}, c = {row, col, end_row, end_col}, level, group_index, color_group }
function M.pair_at(buf, row, col)
  local hl = vim.treesitter.highlighter.active[buf]
  local parser = hl and hl.tree
  if not parser or not S.groups then
    return nil
  end
  local tick = api.nvim_buf_get_changedtick(buf)
  local ltree = parser:language_for_range({ row, col, row, col })
  while ltree do
    local lang = ltree:lang()
    local tree = ltree:tree_for_range({ row, col, row, col }, { ignore_injections = true })
    if tree and not (ltree:parent() and ltree:parent():lang() == lang) then
      local m = memo_for(tree, tick)
      local x = tree:root():descendant_for_range(row, col, row, col)
      while x do
        local h = host_info(m, x, lang)
        if h then
          local best
          for _, p in ipairs(h.pairs) do
            if
              not before(row, col, p.orow, p.ocol)
              and before(row, col, p.cerow, p.cecol)
              and (not best or before(best.orow, best.ocol, p.orow, p.ocol))
            then
              best = p
            end
          end
          if best then
            local lvl = level(m, lang, best.o, S.opts.cycle_all_types and "*" or best.kind)
              + base_level(ltree, tree, tick)
            local list = S.groups.by_kind[best.kind]
            return {
              kind = best.kind,
              o = { best.orow, best.ocol },
              c = { best.crow, best.ccol, best.cerow, best.cecol },
              level = lvl,
              index = lvl % #list + 1,
              group = list[lvl % #list + 1],
              coloured = not (S.opts.skip_first_level and lvl == 0),
            }
          end
        end
        x = x:parent()
      end
    end
    ltree = ltree:parent()
  end
  return nil
end

-- ---------------------------------------------------------------------------------------- eligibility

local function bufvar(buf, name)
  local ok, v = pcall(api.nvim_buf_get_var, buf, name)
  if ok then
    return v
  end
  return nil
end

local function disabled_by_list(buf, ft)
  local list = S.opts.disable
  if #list == 0 then
    return false
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local ext = (api.nvim_buf_get_name(buf):match("%.([^./\\]+)$") or ""):lower()
  for _, e in ipairs(list) do
    if e == ft:lower() or e == lang:lower() or (ext ~= "" and e == ext) then
      return true
    end
  end
  return false
end

local function eligible(buf)
  local ft = vim.bo[buf].filetype
  local st = S.mem_static and S.mem_static[buf]
  if not st or st.ft ~= ft or st.version ~= S.version then
    st = {
      ft = ft,
      version = S.version,
      ok = vim.bo[buf].buftype == "" and ft ~= "" and not disabled_by_list(buf, ft),
    }
    S.mem_static = S.mem_static or {}
    S.mem_static[buf] = st
  end
  if not st.ok or bufvar(buf, "xynovim_rainbow") == false then
    return false
  end
  local o = S.opts
  if o.large == "off" and (bufvar(buf, "xyno_large") or 0) > 0 then
    return false
  end
  if o.max_lines > 0 and api.nvim_buf_line_count(buf) > o.max_lines then
    return false
  end
  return true
end
M.eligible = eligible

-- ---------------------------------------------------------------------------------------- provider

local function on_win(_, win, buf, top, bot)
  if not S.opts.enabled or not S.groups then
    return false
  end
  local hl = vim.treesitter.highlighter.active[buf]
  if not hl or not eligible(buf) then
    return false
  end
  local t0 = vim.uv.hrtime()
  local last = api.nvim_buf_line_count(buf) - 1
  local srow, erow = top, math.min(bot, last)
  local tick = api.nvim_buf_get_changedtick(buf)
  -- Never parse here: nvim 0.12's highlighter parses asynchronously in slices, and a synchronous
  -- parse() from a decoration provider forced the whole reparse (900 ms after an unbalanced `{` in a
  -- 38 000-line file). While it is running the trees are the edited old ones; the redraw it asks for
  -- when done brings the fresh ones, so nothing is cached in between.
  local parsing = hl.parsing
  local c = S.cache[win]
  if
    parsing
    or not (c and c.buf == buf and c.tick == tick and c.srow == srow and c.erow == erow and c.version == S.version)
  then
    local ok, marks = pcall(M.collect, buf, hl.tree, srow, erow)
    c = { buf = buf, tick = tick, srow = srow, erow = erow, version = S.version, marks = ok and marks or {} }
    S.cache[win] = (not parsing) and c or nil
    S.stats.rebuilt = S.stats.rebuilt + 1
  end
  local prio = S.opts.priority
  for _, mk in ipairs(c.marks) do
    api.nvim_buf_set_extmark(buf, ns, mk[1], mk[2], {
      end_col = mk[3],
      hl_group = mk[4],
      ephemeral = true,
      priority = prio,
    })
  end
  local us = (vim.uv.hrtime() - t0) / 1000
  S.stats.redraws = S.stats.redraws + 1
  S.stats.last_us = us
  if us > S.stats.max_us then
    S.stats.max_us = us
  end
  return false
end

-- ---------------------------------------------------------------------------------------- public

--- Forget every cache and redraw (options or colours changed).
function M.refresh()
  S.version = S.version + 1
  S.lang_off = {}
  for _, e in ipairs(S.opts.disable) do
    S.lang_off[e] = true
    S.lang_off[(vim.treesitter.language.get_lang(e) or e)] = true
  end
  S.cache, S.mem_static = {}, nil
  pcall(vim.cmd, "redraw!")
end

function M.apply_colors()
  local ok, groups = pcall(require("config.rainbow_palette").apply, S.opts)
  if ok then
    S.groups = groups
  end
  return ok
end

local function state_file()
  return vim.fn.stdpath("state") .. "/xynovim-rainbow.json"
end

local function read_saved()
  local f = io.open(state_file(), "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  local ok, t = pcall(vim.json.decode, s)
  return ok and type(t) == "table" and t or nil
end

--- Write the options that differ from the defaults to the state file (read back by the next setup,
--- below vim.g.xynovim_rainbow).
function M.save()
  local function diff(cur, def)
    local out = {}
    for k, v in pairs(cur) do
      if type(v) == "table" and not vim.islist(v) and type(def[k]) == "table" and not vim.islist(def[k]) then
        local d = diff(v, def[k])
        if next(d) then
          out[k] = d
        end
      elseif not vim.deep_equal(v, def[k]) then
        out[k] = v
      end
    end
    return out
  end
  local t = diff(S.opts, DEFAULTS)
  vim.fn.mkdir(vim.fs.dirname(state_file()), "p")
  local f, err = io.open(state_file(), "w")
  if not f then
    return false, err
  end
  f:write(vim.json.encode(t))
  f:close()
  return true, state_file()
end

function M.forget_saved()
  os.remove(state_file())
end

--- Read the options (defaults < saved < vim.g.xynovim_rainbow), define the colours, install the provider.
--- Safe to call again (it re-reads everything).
function M.setup()
  local o, problems = M.resolve_options(vim.g.xynovim_rainbow, read_saved())
  S.opts, S.problems = o, problems
  if #problems > 0 then
    vim.schedule(function()
      vim.notify("xynovim rainbow brackets: " .. table.concat(problems, "; "), vim.log.levels.WARN)
    end)
  end
  M.apply_colors()
  if not S.ready then
    S.ready = true
    api.nvim_set_decoration_provider(ns, { on_win = on_win })
    local group = api.nvim_create_augroup("xynovim_rainbow", { clear = true })
    api.nvim_create_autocmd({ "ColorScheme" }, {
      group = group,
      callback = function()
        M.apply_colors()
        M.refresh()
      end,
    })
    api.nvim_create_autocmd("OptionSet", {
      group = group,
      pattern = "background",
      callback = function()
        vim.schedule(function()
          M.apply_colors()
          M.refresh()
        end)
      end,
    })
    api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
      group = group,
      callback = function(ev)
        if S.mem_static then
          S.mem_static[ev.buf] = nil
        end
      end,
    })
    api.nvim_create_autocmd("WinClosed", {
      group = group,
      callback = function(ev)
        S.cache[tonumber(ev.match)] = nil
      end,
    })
  end
  require("config.rainbow_scope").setup()
  -- the command's code (lua/config/rainbow_cmd.lua) loads on first use
  api.nvim_create_user_command("XynoRainbow", function(c)
    require("config.rainbow_cmd").run(c)
  end, {
    nargs = "*",
    desc = "Rainbow brackets: status, switches, palette, scope",
    complete = function(a, c)
      return require("config.rainbow_cmd").complete(a, c)
    end,
  })
  M.refresh()
  return o
end

--- Change one option (dotted path, e.g. "scope.alpha"), validated; returns ok, message.
function M.set(path, value)
  local spec, base = SPEC, S.opts
  local parts = vim.split(path, ".", { plain = true })
  for i = 1, #parts - 1 do
    spec, base = spec[parts[i]], base[parts[i]]
    if type(spec) ~= "table" or type(base) ~= "table" then
      return false, "unknown option " .. path
    end
  end
  local key = parts[#parts]
  local s = spec[key]
  if s == nil then
    return false, "unknown option " .. path
  end
  if type(s) == "table" and not (s.int or s.num or s.enum) then
    return false, path .. " is a group; set one of its keys"
  end
  local ok, v = check(s, value)
  if not ok then
    return false, ("%s: %s is not valid (expected %s)"):format(path, vim.inspect(value), describe(s))
  end
  base[key] = v
  M.apply_colors()
  M.refresh()
  return true, v
end

function M.get(path)
  local v = S.opts
  for _, k in ipairs(vim.split(path, ".", { plain = true })) do
    if type(v) ~= "table" then
      return nil
    end
    v = v[k]
  end
  return v
end

function M.toggle(path)
  local cur = M.get(path)
  if type(cur) ~= "boolean" then
    return false, path .. " is not a switch"
  end
  return M.set(path, not cur)
end

--- What is on screen for the current window, for tests and :XynoRainbow status.
function M.status()
  local buf = api.nvim_get_current_buf()
  local hl = vim.treesitter.highlighter.active[buf]
  return {
    enabled = S.opts.enabled,
    eligible = hl ~= nil and eligible(buf),
    treesitter = hl ~= nil,
    palette = S.groups and S.groups.palette,
    colors = S.groups and S.groups.count,
    stats = vim.deepcopy(S.stats),
  }
end

return M
