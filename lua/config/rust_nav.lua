-- Rust navigation helpers that rust-analyzer has no single request for.
local M = {}

local function ra_client(buf)
  return vim.lsp.get_clients({ bufnr = buf, name = "rust-analyzer" })[1]
end

--- RustRover's "Go to super method" (Ctrl+U): from a method inside
--- `impl Trait for T`, jump to the same method in the trait definition.
function M.goto_super()
  local buf = vim.api.nvim_get_current_buf()
  local client = ra_client(buf)
  local node = vim.treesitter.get_node()
  while node and node:type() ~= "function_item" do
    node = node:parent()
  end
  if not (client and node) then
    return vim.notify("not inside a function", vim.log.levels.WARN)
  end
  local impl = node:parent()
  while impl and impl:type() ~= "impl_item" do
    impl = impl:parent()
  end
  local trait = impl and impl:field("trait")[1]
  if not trait then
    return vim.notify("not a trait impl method", vim.log.levels.WARN)
  end
  -- Land on the trait's own identifier: `fmt::Display`, `From<T>` -> `Display`, `From`.
  while trait:type() ~= "type_identifier" do
    local nxt = trait:field(trait:type() == "generic_type" and "type" or "name")[1]
    if not nxt then
      break
    end
    trait = nxt
  end
  local name = vim.treesitter.get_node_text(node:field("name")[1], buf)
  local row, col = trait:start()
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    position = { line = row, character = col },
  }
  client:request("textDocument/definition", params, function(err, res)
    local loc = res and (vim.islist(res) and res[1] or res)
    if err or not loc then
      return vim.notify("trait definition not found", vim.log.levels.WARN)
    end
    vim.lsp.util.show_document(loc, client.offset_encoding, { focus = true })
    vim.fn.search("\\<fn\\s\\+" .. name .. "\\>", "cw")
    vim.cmd("normal! zz")
  end, buf)
end

--- Reads/writes of the symbol under the cursor in this file, labelled
--- [R]/[W], in the quickfix list (RustRover's usage-type grouping).
function M.local_usages()
  local buf = vim.api.nvim_get_current_buf()
  local client = ra_client(buf)
  if not client then
    return
  end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request("textDocument/documentHighlight", params, function(err, res)
    if err or not res or #res == 0 then
      return vim.notify("no usages in this file", vim.log.levels.INFO)
    end
    local kind = { [1] = "T", [2] = "R", [3] = "W" }
    local items = {}
    for _, h in ipairs(res) do
      local lnum = h.range.start.line + 1
      items[#items + 1] = {
        bufnr = buf,
        lnum = lnum,
        col = h.range.start.character + 1,
        text = ("[%s] %s"):format(kind[h.kind or 1], vim.trim(vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or "")),
      }
    end
    table.sort(items, function(a, b)
      return a.lnum < b.lnum
    end)
    vim.fn.setqflist({}, " ", { title = "usages (this file)", items = items })
    vim.cmd("copen")
  end, buf)
end

return M
