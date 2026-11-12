-- xyno-timeout: 200
-- Cargo.toml editing in the full config: crates.nvim's in-process language server answers
-- completion for the features of a dependency (`features = ["`) and its versions, and hover. Needs
-- crates.io (the sparse index): skipped when it is unreachable.
local H = require("xynotest.helpers")

local function online()
  local r = vim.system({ "curl", "-sS", "-m", "8", "-o", "/dev/null", "-w", "%{http_code}", "https://index.crates.io/se/rd/serde" }, { text = true }):wait(12000)
  return r.code == 0 and r.stdout == "200"
end

describe("Cargo.toml (crates.nvim)", function()
  it("completes the features and the versions of a dependency", function()
    if not online() then
      H.skip_file("crates.io unreachable")
    end
    local dir = H.tmpdir()
    vim.fn.mkdir(dir .. "/src", "p")
    vim.fn.writefile({ "[package]", 'name = "t"', 'version = "0.1.0"', 'edition = "2021"', "", "[dependencies]", 'serde = { version = "1", features = [""] }' }, dir .. "/Cargo.toml")
    vim.fn.writefile({ "fn main() {}" }, dir .. "/src/main.rs")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/Cargo.toml"))
    local buf = vim.api.nvim_get_current_buf()
    H.very_lazy()
    local names = {}
    local client = H.wait_for(function()
      names = vim.tbl_map(function(c)
        return c.name
      end, vim.lsp.get_clients({ bufnr = buf }))
      for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
        if c.name:find("crates", 1, true) then
          return c
        end
      end
    end, 30000, "the crates in-process LSP; clients: " .. vim.inspect(names))
    --- Poll a completion request without nesting waits (a vim.wait inside a wait predicate re-enters
    --- itself): one request in flight, the last answer kept. crates.nvim completes at the CURSOR, so
    --- the cursor goes to the position first.
    local function poller(line, char)
      local pending, last = false, nil
      return function()
        if not pending then
          pending = true
          pcall(vim.api.nvim_win_set_cursor, 0, { line + 1, char })
          client:request("textDocument/completion", {
            textDocument = vim.lsp.util.make_text_document_params(buf),
            position = { line = line, character = char },
          }, function(_, res)
            pending = false
            last = vim.tbl_map(function(i)
              return i.label
            end, res and (res.items or res) or {})
          end, buf)
        end
        return last and #last > 0 and last
      end
    end
    -- versions
    local vcol = vim.api.nvim_buf_get_lines(buf, 6, 7, false)[1]:find('version = "1"', 1, true) + #'version = "1' - 1
    local versions = H.wait_for(poller(6, vcol), 60000, "version completion")
    H.ok(#versions >= 1, "versions offered")
    local col = vim.api.nvim_buf_get_lines(buf, 6, 7, false)[1]:find('features = [""', 1, true) + #'features = ["' - 1
    local labels = H.wait_for(poller(6, col), 60000, "feature completion")
    H.has(labels, "derive")
  end)
end)
