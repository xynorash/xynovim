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
-- Both are off by default (the plugin's tag option is off by default too). Not built: Ruby keywords, C++
-- `#if` macros as a separate rule, Kotlin lambda arrows and labels: those grammars are not installed here
-- and a rule cannot be tested without one (docs/RAINBOW.md).
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

local function query_for(lang, rule)
  local q = queries[lang]
  if q == nil then
    local ok, parsed = pcall(vim.treesitter.query.parse, lang, rule.query)
    q = ok and parsed or false
    queries[lang] = q
  end
  return q
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
