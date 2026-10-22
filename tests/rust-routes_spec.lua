-- The <leader>rN map of :RustRoutes (keymaps.lua). The scanner, the workspace walk and the picker are
-- specs of the xyno-rust.nvim repository.
local H = require("xynotest.helpers")

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

describe("<leader>rN", function()
  it("maps to :RustRoutes buffer-locally when rust-analyzer attaches", function()
    -- the real LspAttach handler (keymaps.lua) needs a rust-analyzer client;
    -- hand it a fake one so the test stays independent of the server
    H.very_lazy()
    local dir = H.tmpdir()
    write(dir .. "/a.rs", "fn main() {}\n")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/a.rs"))
    local buf = vim.api.nvim_get_current_buf()
    local function lookup(b)
      return vim.api.nvim_buf_call(b, function()
        return vim.fn.maparg(vim.g.mapleader .. "rN", "n", false, true)
      end)
    end
    -- (only the global hidden "not bound" stub, never the buffer-local map)
    H.eq(0, lookup(buf).buffer or 0, "buffer-local map exists before attach")

    local orig = vim.lsp.get_client_by_id
    vim.lsp.get_client_by_id = function(id)
      if id == 987654 then
        return { name = "rust-analyzer", id = id }
      end
      return orig(id)
    end
    local ok, err = pcall(function()
      -- only this config's own handler: other LspAttach handlers expect a real client
      local acs = vim.api.nvim_get_autocmds({ event = "LspAttach", group = "xynovim_rust_keymaps" })
      H.eq(1, #acs)
      acs[1].callback({ buf = buf, data = { client_id = 987654 } })
      H.wait_for(function()
        return lookup(buf).buffer == 1 and lookup(buf).rhs
      end, 20000, "<leader>rN map")
    end)
    vim.lsp.get_client_by_id = orig
    if not ok then
      error(err, 0)
    end
    local m = lookup(buf)
    H.eq("<cmd>rustroutes<cr>", m.rhs:lower())
    H.eq(1, m.buffer)
    H.eq("HTTP routes (axum / actix / rocket)", m.desc)
    -- not global: another buffer has no such map
    vim.cmd.enew()
    H.eq(0, lookup(vim.api.nvim_get_current_buf()).buffer or 0)
  end)
end)

