-- :RustRoutes - HTTP route picker for axum / actix / rocket projects
-- (RustRover's Endpoints tool window, minimal). Pure treesitter, no LSP:
--   .route("/users/{id}", get(show).delete(remove))   axum, actix `web::get().to(h)`
--   #[get("/users")] async fn list() {}               actix-web, rocket, poem-style
--   #[actix_web::post("/users")]
local M = {}

local METHODS = { "get", "post", "put", "delete", "patch", "head", "options", "trace", "connect", "route" }

local QUERY = [[
((call_expression
   function: (field_expression field: (field_identifier) @_f)
   arguments: (arguments . (string_literal (string_content) @path) . (_) @handler))
 (#eq? @_f "route"))

(attribute_item
  (attribute
    [(identifier) @verb
     (scoped_identifier name: (identifier) @verb)]
    arguments: (token_tree . (string_literal (string_content) @path))))
]]

--- Parse `src` and return { { path, kind, detail, row, col } ... } (row 0-based).
function M.scan_source(src)
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, "rust")
  if not ok then
    return {}
  end
  local tree = parser:parse()[1]
  local query = vim.treesitter.query.parse("rust", QUERY)
  local out = {}
  for _, match in query:iter_matches(tree:root(), src, 0, -1) do
    local cap = {}
    for id, nodes in pairs(match) do
      cap[query.captures[id]] = nodes[#nodes]
    end
    if cap.verb then
      -- attribute: only HTTP verbs, and the route belongs to the fn that follows
      local verb = vim.treesitter.get_node_text(cap.verb, src)
      if vim.list_contains(METHODS, verb) then
        local fn = cap.verb
        while fn and fn:type() ~= "attribute_item" do
          fn = fn:parent()
        end
        local nxt = fn and fn:next_named_sibling()
        while nxt and nxt:type() == "attribute_item" do
          nxt = nxt:next_named_sibling()
        end
        local name = nxt and nxt:type() == "function_item" and vim.treesitter.get_node_text(nxt:field("name")[1], src)
        local row, col = cap.path:start()
        out[#out + 1] = {
          path = vim.treesitter.get_node_text(cap.path, src),
          kind = verb:upper(),
          detail = name or "?",
          row = row,
          col = col,
        }
      end
    elseif cap.handler then
      local row, col = cap.path:start()
      out[#out + 1] = {
        path = vim.treesitter.get_node_text(cap.path, src),
        kind = "ROUTE",
        -- `get(show).delete(remove)` / `web::get().to(h)` / `any(h)`, whitespace squeezed
        detail = (vim.treesitter.get_node_text(cap.handler, src):gsub("%s+", " ")),
        row = row,
        col = col,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.row < b.row
  end)
  return out
end

local SKIP = { target = true, [".git"] = true, node_modules = true, ["bacon-ls-live"] = true }

--- Every route in the workspace's .rs files.
function M.collect(root)
  local items = {}
  for name, type in vim.fs.dir(root, {
    depth = 12,
    skip = function(dir)
      return not SKIP[vim.fs.basename(dir)] -- dir is the path relative to root: nested target/ too
    end,
  }) do
    if type == "file" and name:match("%.rs$") then
      local file = root .. "/" .. name
      local f = io.open(file)
      local src = f and f:read("*a")
      if f then
        f:close()
      end
      -- cheap pre-filter before parsing
      if src and (src:find(".route(", 1, true) or src:find("#[", 1, true)) then
        for _, r in ipairs(M.scan_source(src)) do
          items[#items + 1] = {
            text = ("%s %s  %s  %s"):format(r.kind, r.path, r.detail, name),
            file = file,
            pos = { r.row + 1, r.col },
            kind = r.kind,
            route = r.path,
            detail = r.detail,
            rel = name,
          }
        end
      end
    end
  end
  return items
end

function M.pick()
  local root = require("config.rust_context").root()
  if not root then
    return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
  end
  local items = M.collect(root)
  if #items == 0 then
    return vim.notify("no routes found (.route(\"/p\", ..) or #[get(\"/p\")])", vim.log.levels.INFO)
  end
  Snacks.picker({
    title = "Routes",
    items = items,
    format = function(item)
      return {
        { ("%-7s"):format(item.kind), "Keyword" },
        { item.route .. "  ", "String" },
        { item.detail .. "  ", "Function" },
        { item.rel, "Comment" },
      }
    end,
    preview = "file",
  })
end

function M.setup()
  vim.api.nvim_create_user_command("RustRoutes", M.pick, { desc = "Pick an axum/actix/rocket route in the workspace" })
end

return M
