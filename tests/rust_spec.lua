-- Needs rust-analyzer and cargo (skipped with a message otherwise).
local H = require("xynotest.helpers")

describe("rust-analyzer on the fixtures", function()
  before_each(function()
    H.need_rust()
  end)

  it("attaches to the basic crate and reports no errors", function()
    local _, buf = H.open_fixture("basic", "src/lib.rs")
    H.wait_lsp("rust-analyzer", buf)
    -- attached is not analysed: wait until it answers with the crate's symbols
    H.wait_for(function()
      local res = vim.lsp.buf_request_sync(
        buf,
        "textDocument/documentSymbol",
        { textDocument = vim.lsp.util.make_text_document_params(buf) },
        5000
      )
      for _, r in pairs(res or {}) do
        for _, sym in ipairs(r.result or {}) do
          if sym.name == "answer" then
            return true
          end
        end
      end
    end, 60000, "documentSymbol to list `answer`")
    H.eq(
      {},
      vim.tbl_filter(function(d)
        return d.severity == vim.diagnostic.severity.ERROR
      end, H.diagnostics(nil, buf))
    )
  end)

  it("reports the type error of the broken crate", function()
    local _, buf = H.open_fixture("broken", "src/main.rs")
    H.wait_lsp("rust-analyzer", buf)
    local d = H.wait_for(function()
      return H.diagnostics(nil, buf)[1]
    end, 60000, "a diagnostic in the broken crate")
    H.match(d.message, "mismatched types", true)
  end)

  it("attaches to a standalone file", function()
    local _, buf = H.open_fixture("standalone.rs")
    H.wait_lsp("rust-analyzer", buf)
  end)
end)
