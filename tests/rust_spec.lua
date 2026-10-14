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
    -- Either tier may answer first, and the wording differs per rust-analyzer
    -- version ("mismatched types", "expected i32, found &'static str") and per
    -- tier (bacon-ls has no code): accept any rendering of E0308.
    H.wait_for(function()
      for _, d in ipairs(H.diagnostics(nil, buf)) do
        if tostring(d.code) == "E0308" or d.message:find("mismatched types", 1, true) or d.message:find("expected .*, found") then
          return d
        end
      end
    end, 60000, "an E0308 type error diagnostic in the broken crate")
  end)

  it("attaches to a standalone file", function()
    local _, buf = H.open_fixture("standalone.rs")
    H.wait_lsp("rust-analyzer", buf)
  end)
end)
