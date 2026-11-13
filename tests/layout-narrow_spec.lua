-- Side panels at a Ghostty-default ~93 columns: the neotest summary (48 columns) plus the dap-ui sidebar
-- (40..60) left ~30 columns for the code. Below 120 columns the summary is a float and dap-ui is one bottom strip.
local H = require("xynotest.helpers")
local narrow = require("config.narrow")

local function with_columns(cols, fn)
  local old = vim.o.columns
  vim.o.columns = cols
  local ok, err = pcall(fn)
  vim.o.columns = old
  assert(ok, err)
end

local function code_width_after(open)
  vim.cmd("only | enew!")
  local code = vim.api.nvim_get_current_win()
  open()
  return vim.api.nvim_win_get_width(code)
end

describe("neotest summary", function()
  it("is a float at 93 columns: the code window keeps its width", function()
    with_columns(93, function()
      H.ok(narrow.is_narrow())
      local w = code_width_after(function()
        local win = narrow.summary_open()
        H.eq("editor", vim.api.nvim_win_get_config(win).relative)
      end)
      H.ok(w >= 90, "code window is " .. w .. " columns")
    end)
  end)

  it("is the 48-column split on a wide window", function()
    with_columns(200, function()
      H.not_ok(narrow.is_narrow())
      local w = code_width_after(function()
        local win = narrow.summary_open()
        H.eq("", vim.api.nvim_win_get_config(win).relative)
        H.eq(48, vim.api.nvim_win_get_width(win))
      end)
      H.ok(w >= 140, "code window is " .. w)
    end)
  end)

  it("the float closes when the cursor leaves it", function()
    with_columns(93, function()
      vim.cmd("only | enew!")
      local code = vim.api.nvim_get_current_win()
      local win = narrow.summary_open()
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_set_current_win(code)
      H.wait_for(function()
        return not vim.api.nvim_win_is_valid(win)
      end, 2000, "the summary float stayed open")
    end)
  end)

  it("neotest is configured to use it", function()
    local spec = dofile(H.repo .. "/lua/plugins/neotest.lua")[1]
    H.eq("function", type(spec.opts.summary.open))
  end)
end)

describe("dap-ui layouts", function()
  it("one bottom strip below 120 columns, sidebar plus strip above", function()
    with_columns(93, function()
      local l = narrow.dapui_layouts()
      H.eq(1, #l)
      H.eq("bottom", l[1].position)
    end)
    with_columns(200, function()
      local l = narrow.dapui_layouts()
      H.eq(2, #l)
      H.eq("left", l[1].position)
    end)
  end)

  it("a width change before open re-reads the layouts", function()
    require("lazy").load({ plugins = { "nvim-dap-ui" } })
    local dapui = require("dapui")
    with_columns(200, function()
      narrow.follow_dapui()
      dapui.setup({ layouts = narrow.dapui_layouts() })
    end)
    -- applied state is wide; now narrow
    with_columns(93, function()
      local seen
      local cfg = require("dapui.config")
      dapui.open({})
      seen = #cfg.layouts
      pcall(dapui.close, {})
      H.eq(1, seen, "dapui still had the wide layouts")
    end)
  end)
end)
