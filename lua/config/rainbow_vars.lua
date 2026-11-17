-- Rainbow variables (the JetBrains plugin's "Rainbow Variables" / semantic highlighting), on tree-sitter locals.
-- Every local variable and parameter gets a colour from its NAME, so the declaration and every use of
-- `total` look alike and `total` differs from `count`; fields, functions, types and anything that is not a
-- local of an enclosing scope keep their normal colours. The same rule as IntelliJ's semantic highlighting
-- (colour by name inside the function), with a stable hash instead of a per-function counter: the colour of a
-- name does not depend on what is on screen, at the price that two names can collide.
--
-- Uses the `locals` query of the language (nvim-treesitter ships one for Rust and others): `@local.scope`
-- nodes, `@local.definition.var` / `.parameter` definitions, `@local.reference` uses. A use is coloured when
-- an enclosing scope (found by walking up the tree) defines the same name. Shadowing is not told apart (two
-- `let x` in one function share a colour, like in IntelliJ).
local M = {}

local MAX_ROWS = 3000 -- the largest region looked at (the enclosing top-level items of the window)

local function hash(name)
  local h = 5381
  for i = 1, #name do
    h = (h * 33 + name:byte(i)) % 4294967296
  end
  return h
end

local DEF = { var = true, parameter = true }

--- Marks for the identifiers of rows [srow, erow]: { row, col, end_col, group, priority }.
---@param count integer number of variable colours
function M.collect(buf, parser, srow, erow, count, priority)
  local marks = {}
  parser:for_each_tree(function(tree, ltree)
    local lang = ltree:lang()
    if ltree:parent() and ltree:parent():lang() == lang then
      return
    end
    local q = vim.treesitter.query.get(lang, "locals")
    if not q then
      return
    end
    local root = tree:root()
    -- the whole top-level items that contain the window, so that definitions above its first row are seen
    local first = root:descendant_for_range(srow, 0, srow, 0)
    local last = root:descendant_for_range(erow, 0, erow, 0)
    local function top(n)
      while n and n:parent() and n:parent():parent() do
        n = n:parent()
      end
      return n
    end
    first, last = top(first), top(last)
    local r0 = first and first:start() or srow
    local r1 = last and select(3, last:range()) or erow
    if r1 - r0 > MAX_ROWS then
      r0, r1 = math.max(srow - 300, 0), erow + 300
    end
    local scopes = {}
    local defs, refs = {}, {}
    for id, node in q:iter_captures(root, buf, r0, r1 + 1) do
      local cap = q.captures[id]
      if cap == "local.scope" then
        scopes[node:id()] = { defs = {} }
      elseif cap:sub(1, 17) == "local.definition." and DEF[cap:sub(18)] then
        defs[#defs + 1] = node
      elseif cap == "local.reference" and node:type() == "identifier" then
        refs[#refs + 1] = node
      end
    end
    local function scope_up(node)
      local n = node:parent()
      while n do
        local sc = scopes[n:id()]
        if sc then
          return sc
        end
        n = n:parent()
      end
    end
    local function text(node)
      return vim.treesitter.get_node_text(node, buf)
    end
    for _, d in ipairs(defs) do
      local s = scope_up(d)
      if s then
        s.defs[text(d)] = true
      end
    end
    local function emit(node, name)
      local r, c, _, ec = node:range()
      if r >= srow and r <= erow then
        marks[#marks + 1] = { r, c, ec, "XynoRainbowVar" .. (hash(name) % count + 1), priority }
      end
    end
    for _, d in ipairs(defs) do
      local name = text(d)
      if name ~= "self" and name ~= "_" then
        emit(d, name)
      end
    end
    local emitted = {}
    for _, d in ipairs(defs) do
      emitted[d:id()] = true
    end
    for _, ref in ipairs(refs) do
      if not emitted[ref:id()] then
        local name = text(ref)
        local n = ref:parent()
        while n do
          local sc = scopes[n:id()]
          if sc and sc.defs[name] then
            emit(ref, name)
            break
          end
          n = n:parent()
        end
      end
    end
  end)
  return marks
end

return M
