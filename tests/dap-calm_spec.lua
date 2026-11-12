-- The debug UI is calmer: raw registers and the empty Static / Global scopes are not listed, and the dap-ui
-- layout closes when the user terminates the session (it stays after a program that ends by itself).
local H = require("xynotest.helpers")
local DV = require("config.dap_values")

describe("scopes pane", function()
  local scopes = { { name = "Local" }, { name = "Static" }, { name = "Global" }, { name = "Registers" } }
  after_each(function()
    vim.g.xynovim_dap_scopes = nil
  end)
  it("lists only the locals of a CodeLLDB answer", function()
    H.eq({ { name = "Local" } }, DV.calm_scopes(scopes))
  end)
  it("vim.g.xynovim_dap_scopes = 'all' lists everything", function()
    vim.g.xynovim_dap_scopes = "all"
    H.eq(4, #DV.calm_scopes(scopes))
  end)
  it("never returns an empty list (other adapters' scope names stay)", function()
    H.eq({ { name = "Registers" } }, DV.calm_scopes({ { name = "Registers" } }))
    H.eq(
      { { name = "Arguments" }, { name = "Locals" } },
      DV.calm_scopes({ { name = "Arguments" }, { name = "Locals" } })
    )
  end)
  it("is wired as a nvim-dap listener that edits the answer of a Rust session", function()
    local dap = require("dap")
    DV.setup()
    local fn = dap.listeners.before.scopes["xynovim_calm_scopes"]
    H.eq("function", type(fn))
    local body = { scopes = vim.deepcopy(scopes) }
    fn({ config = { type = "codelldb" }, adapter = { type = "executable", command = "codelldb" } }, nil, body)
    H.ok(#body.scopes <= 4)
  end)
end)

describe("dap-ui closes on terminate", function()
  it("dap.terminate() then the terminated event closes the dapui layout; a natural exit keeps it", function()
    local dap = require("dap")
    DV.setup()
    local closed = 0
    package.loaded["dapui"] = {
      close = function()
        closed = closed + 1
      end,
    }
    local l = dap.listeners.after.event_terminated["xynovim_close_on_terminate"]
    H.eq("function", type(l))
    l() -- the program ended by itself
    H.eq(0, closed, "output stays readable in the console")
    pcall(dap.terminate) -- no session: it only notifies, but the user asked
    l()
    H.eq(1, closed, "closed after the user's terminate")
    l()
    H.eq(1, closed, "and only once per request")
    package.loaded["dapui"] = nil
  end)
end)
