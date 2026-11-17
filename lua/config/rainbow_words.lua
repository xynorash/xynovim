-- Rainbow keywords and tags: the part of the JetBrains plugin's feature list that colours words, not
-- brackets, by nesting depth. A small rule table on top of tree-sitter queries; no pair engine involved.
--
--   keywords  Python `if/elif/else/for/while/try/except/finally/with/def/class` coloured by the number of
--             enclosing indentation blocks; C `#if/#ifdef/#ifndef/#elif/#else/#endif` coloured by the
--             number of enclosing conditional-compilation blocks, so `#if` and its `#endif` match.
--   tags      HTML / XML / JSX (javascript and tsx grammars) tag names and their `<` `>` `</` `/>` coloured
--             by element depth, so an opening and its closing tag match; YAML mapping keys by the depth of
--             the mapping they sit in (the plugin's exact YAML rule is not documented; this is the same
--             idea: colour by nesting).
--
-- Both are off by default (the plugin's tag option is off by default too).
--
-- The rules are data (RULES below; `M.add_rule(lang, rule)` adds one). Ruby keywords, C++ `#if` and Kotlin
-- lambda arrows have rules too, written from the grammars' node names but NEVER RUN against a parser: the
-- three grammars are not installed here (`:TSInstall ruby cpp kotlin`), so these rules are dormant until
-- they are, and unverified. A rule whose grammar is missing, or whose query does not parse against the
-- installed grammar, is skipped quietly (a query is checked part by part: the parts that parse still work).
-- The mechanism itself is specced with a grammar that is installed (tests/rainbow_spec.lua).
local M = {}

local PY_KW = '["if" "elif" "else" "for" "while" "try" "except" "finally" "with" "def" "class"] @w'
local C_KW = '["#if" "#ifdef" "#ifndef" "#elif" "#elifdef" "#elifndef" "#else" "#endif"] @w'

local function tag_query(open, close, selfc, name_of)
  local function host(h, toks)
    return ("(%s %s @w)"):format(h, toks)
  end
  local parts = {
    host(open, '["<" ">"]'),
    host(close, '["</" ">"]'),
    host(selfc, '["<" "/>"]'),
  }
  for _, h in ipairs({ open, close, selfc }) do
    parts[#parts + 1] = ("(%s %s @w)"):format(h, name_of)
  end
  return table.concat(parts, "\n")
end

local JSX = tag_query("jsx_opening_element", "jsx_closing_element", "jsx_self_closing_element", "name: (_)")

-- kind: "keywords" | "tags"; query; nest = node types that count as one level (the host of the word counts
-- itself, so one is taken off); group = the colour list the levels cycle through.
local RULES = {
  python = { kind = "keywords", query = PY_KW, nest = { block = true }, base = 0, list = "curly" },
  c = {
    kind = "keywords",
    query = C_KW,
    nest = { preproc_if = true, preproc_ifdef = true },
    base = 1,
    list = "curly",
  },
  html = {
    kind = "tags",
    query = tag_query("start_tag", "end_tag", "self_closing_tag", "(tag_name)"),
    nest = { element = true },
    base = 1,
    list = "angle",
  },
  xml = {
    kind = "tags",
    query = tag_query("STag", "ETag", "EmptyElemTag", "(Name)"),
    nest = { element = true },
    base = 1,
    list = "angle",
  },
  javascript = {
    kind = "tags",
    query = JSX,
    nest = { jsx_element = true, jsx_self_closing_element = true },
    base = 1,
    list = "angle",
  },
  tsx = {
    kind = "tags",
    query = JSX,
    nest = { jsx_element = true, jsx_self_closing_element = true },
    base = 1,
    list = "angle",
  },
  -- Written against tree-sitter-ruby / -cpp / -kotlin node names, not run (grammars not installed).
  ruby = {
    kind = "keywords",
    parts = {
      '(if ["if" "end"] @w)',
      '(elsif "elsif" @w)',
      '(else "else" @w)',
      '(unless ["unless" "end"] @w)',
      '(while ["while" "end"] @w)',
      '(until ["until" "end"] @w)',
      '(for ["for" "end"] @w)',
      '(case ["case" "end"] @w)',
      '(when "when" @w)',
      '(begin ["begin" "end"] @w)',
      '(rescue "rescue" @w)',
      '(ensure "ensure" @w)',
      '(method ["def" "end"] @w)',
      '(singleton_method ["def" "end"] @w)',
      '(class ["class" "end"] @w)',
      '(module ["module" "end"] @w)',
    },
    nest = {
      ["if"] = true,
      unless = true,
      ["while"] = true,
      ["until"] = true,
      ["for"] = true,
      case = true,
      begin = true,
      method = true,
      singleton_method = true,
      class = true,
      module = true,
    },
    base = 1,
    list = "curly",
  },
  cpp = {
    kind = "keywords",
    query = C_KW,
    nest = { preproc_if = true, preproc_ifdef = true },
    base = 1,
    list = "curly",
  },
  kotlin = {
    kind = "keywords",
    parts = { '(lambda_literal "->" @w)' },
    nest = { lambda_literal = true },
    base = 1,
    list = "curly",
  },
  yaml = {
    kind = "tags",
    query = "(block_mapping_pair key: (_) @w)",
    nest = { block_mapping = true },
    base = 1,
    list = "angle",
  },
}
M.RULES = RULES

local queries = {}

--- Add or replace the rule of `lang`: { kind = "keywords"|"tags", query = "...@w" or parts = { "...@w", ... },
--- nest = { node_type = true }, base = n, list = "curly"|"angle"|... }.
function M.add_rule(lang, rule)
  RULES[lang] = rule
  queries[lang] = nil
end

local function query_for(lang, rule)
  local q = queries[lang]
  if q == nil then
    local ok, parsed
    if rule.parts then
      local good = {}
      for _, part in ipairs(rule.parts) do
        if pcall(vim.treesitter.query.parse, lang, part) then
          good[#good + 1] = part
        end
      end
      ok, parsed = pcall(vim.treesitter.query.parse, lang, table.concat(good, "\n"))
      ok = ok and #good > 0
    else
      ok, parsed = pcall(vim.treesitter.query.parse, lang, rule.query)
    end
    q = ok and parsed or false
    queries[lang] = q
  end
  return q
end

--- Languages that have a rule but no installed grammar (the rules wait for `:TSInstall <lang>`).
function M.waiting()
  local out = {}
  for lang in pairs(RULES) do
    if not pcall(vim.treesitter.language.add, lang) then
      out[#out + 1] = lang
    end
  end
  table.sort(out)
  return out
end

local function depth(node, rule)
  local n = 0
  local cur = node
  while cur do
    if rule.nest[cur:type()] then
      n = n + 1
    end
    cur = cur:parent()
  end
  return math.max(n - rule.base, 0)
end

--- Marks { row, col, end_col, group } for rows [srow, erow].
---@param opts table the rainbow options (opts.words.keywords / opts.words.tags)
---@param groups table the applied palette ({ by_kind = {...} })
function M.collect(buf, parser, srow, erow, opts, groups)
  local marks = {}
  local w = opts.words
  if not (w and (w.keywords or w.tags)) then
    return marks
  end
  parser:for_each_tree(function(tree, ltree)
    local lang = ltree:lang()
    local rule = RULES[lang]
    if not rule or not w[rule.kind] then
      return
    end
    local par = ltree:parent()
    if par and par:lang() == lang then
      return
    end
    local q = query_for(lang, rule)
    local list = groups.by_kind[rule.list]
    if not q or not list then
      return
    end
    local seen = {}
    for _, node in q:iter_captures(tree:root(), buf, srow, erow + 1) do
      local r, c, er, ec = node:range()
      if r >= srow and r <= erow and er == r then
        local cell = r * 1048576 + c
        if not seen[cell] then
          seen[cell] = true
          marks[#marks + 1] = { r, c, ec, list[depth(node, rule) % #list + 1] }
        end
      end
    end
  end)
  return marks
end

return M
