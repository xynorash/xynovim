-- bacon-ls publishes one identical diagnostic per span of a lint (a single `unused imports` warning three
-- times). lua/config/diag_dedup.lua drops exact duplicates (same range, severity, code, source, message);
-- lua/plugins/bacon-ls.lua installs it as the server's publishDiagnostics handler.
local H = require("xynotest.helpers")
local dd = require("config.diag_dedup")

local function lsp_diag(line, c1, c2, msg, sev, code)
  return {
    range = { start = { line = line, character = c1 }, ["end"] = { line = line, character = c2 } },
    message = msg or "unused imports: `a`, `b`",
    severity = sev or 2,
    source = "bacon-ls",
    code = code,
  }
end

describe("diagnostic de-duplication", function()
  it("three identical diagnostics become one; order and distinct ones are kept", function()
    local a = lsp_diag(3, 4, 10)
    local list =
      { a, vim.deepcopy(a), lsp_diag(5, 0, 3, "other"), vim.deepcopy(a), vim.deepcopy(lsp_diag(5, 0, 3, "other")) }
    local out, dropped = dd.dedupe(list)
    H.eq(2, #out)
    H.eq(3, dropped)
    H.eq(3, out[1].range.start.line)
    H.eq("other", out[2].message)
  end)

  it("anything that differs in range, severity, code, source or message stays", function()
    local base = lsp_diag(1, 0, 4, "m", 2, "unused_imports")
    local variants = {
      lsp_diag(2, 0, 4, "m", 2, "unused_imports"),
      lsp_diag(1, 1, 4, "m", 2, "unused_imports"),
      lsp_diag(1, 0, 5, "m", 2, "unused_imports"),
      lsp_diag(1, 0, 4, "m", 1, "unused_imports"),
      lsp_diag(1, 0, 4, "m", 2, "other_code"),
      lsp_diag(1, 0, 4, "m2", 2, "unused_imports"),
      vim.tbl_extend("force", base, { source = "rust-analyzer" }),
    }
    local list = { base }
    vim.list_extend(list, variants)
    local out, dropped = dd.dedupe(list)
    H.eq(#list, #out)
    H.eq(0, dropped)
  end)

  it("table codes and a missing code are handled; nil and empty lists are fine", function()
    local d = lsp_diag(0, 0, 1, "x", 2, { value = "E0599", target = "https://x" })
    H.eq(1, #(dd.dedupe({ d, vim.deepcopy(d) })))
    H.eq({}, (dd.dedupe(nil)))
    H.eq({}, (dd.dedupe({})))
  end)

  it("the bacon_ls server uses it: three identical published diagnostics are counted once in vim.diagnostic", function()
    local srv = dofile(H.repo .. "/lua/plugins/bacon-ls.lua").opts.servers.bacon_ls
    local handler = srv.handlers and srv.handlers["textDocument/publishDiagnostics"]
    H.eq("function", type(handler))
    vim.cmd("enew")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, H.tmpdir() .. "/dedupe.rs")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "use a::b;", "fn main() {}" })
    local client_id = vim.lsp.start({
      name = "fake-dedupe",
      cmd = function()
        return {
          request = function(method, _, cb)
            if method == "initialize" then
              cb(nil, { capabilities = {} })
            else
              cb(nil, nil)
            end
            return true, 1
          end,
          notify = function()
            return true
          end,
          is_closing = function()
            return false
          end,
          terminate = function() end,
        }
      end,
      root_dir = vim.uv.cwd(),
    }, { bufnr = buf })
    H.ok(client_id, "fake client started")
    vim.wait(1000, function()
      local c = vim.lsp.get_client_by_id(client_id)
      return c and c.initialized
    end)
    local d = lsp_diag(0, 0, 9)
    handler(
      nil,
      { uri = vim.uri_from_bufnr(buf), diagnostics = { d, vim.deepcopy(d), vim.deepcopy(d) } },
      { client_id = client_id, method = "textDocument/publishDiagnostics" }
    )
    H.eq(1, #vim.diagnostic.get(buf), "one warning, not three")
    H.eq(1, vim.diagnostic.count(buf)[vim.diagnostic.severity.WARN])
    vim.lsp.stop_client(client_id)
    vim.cmd("silent! bwipeout!")
  end)
end)
