-- Calmer inlay-hint defaults: lifetime-elision hints are off (rust-analyzer's own default), parameter-name hints
-- are dropped where the argument already says what it is. Per-kind toggles stay.
local H = require("xynotest.helpers")
local ui = require("config.ui")

describe("inlay hint defaults", function()
  after_each(function()
    vim.g.xynovim_hints = nil
    vim.g.xynovim_hints_params = nil
  end)

  it("types and parameter names on, lifetimes off, until asked for", function()
    vim.g.xynovim_hints = nil
    H.eq({ types = true, params = true, lifetimes = false }, ui.hint_state())
    H.eq("never", ui.hint_settings(ui.hint_state()).lifetimeElisionHints.enable)
    H.ok(ui.hint_state_is_default())
    vim.g.xynovim_hints = { lifetimes = true }
    H.eq(true, ui.hint_state().lifetimes)
    H.eq("skip_trivial", ui.hint_settings(ui.hint_state()).lifetimeElisionHints.enable)
    vim.g.xynovim_hints = { params = false }
    H.eq(false, ui.hint_state().params)
    H.eq(true, ui.hint_state().types)
  end)

  it("the server starts with those kinds (default_settings carry no lifetime hints)", function()
    local o =
      require("lazy.core.plugin").values(require("lazy.core.config").plugins["rustaceanvim"], "opts", false).server
    local ws = H.fixture("basic")
    local ra = o.settings(ws, vim.deepcopy(o.default_settings))["rust-analyzer"]
    H.eq("never", ra.inlayHints.lifetimeElisionHints.enable)
    vim.g.xynovim_hints = { lifetimes = true }
    ra = o.settings(ws, vim.deepcopy(o.default_settings))["rust-analyzer"]
    H.eq("skip_trivial", ra.inlayHints.lifetimeElisionHints.enable)
  end)

  it("self-explanatory arguments: names, field paths, string literals", function()
    for _, a in ipairs({ "user", "user.id", "&name", "&mut buf", '"x"' }) do
      H.eq(true, ui.self_explanatory_argument(a), a)
    end
    for _, a in ipairs({ "5000", "true", "foo()", "a + b", "|x| x", "Some(1)", "" }) do
      H.eq(false, ui.self_explanatory_argument(a), a)
    end
  end)

  it("parameter hints of such arguments are dropped from an answer, the others and other kinds stay", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'connect(host, 5000, "tls", opts.retries, f(x));' })
    local function hint(col, kind)
      return { position = { line = 0, character = col }, label = "p:", kind = kind }
    end
    local got = ui.filter_param_hints(buf, {
      hint(8, 2), -- host
      hint(14, 2), -- 5000
      hint(20, 2), -- "tls"
      hint(26, 2), -- opts.retries
      hint(40, 2), -- f(x)
      hint(0, 1), -- a type hint: untouched
    })
    local cols = vim.tbl_map(function(h)
      return h.position.character
    end, got)
    H.eq({ 14, 40, 0 }, cols)
    vim.g.xynovim_hints_params = "all"
    H.eq(6, #ui.filter_param_hints(buf, {
      hint(8, 2),
      hint(14, 2),
      hint(20, 2),
      hint(26, 2),
      hint(40, 2),
      hint(0, 1),
    }))
  end)

  it(
    "a rust-analyzer client's inlayHint requests are filtered (the built-in and end-of-line renderers use them)",
    function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "f(a, 1);" })
      local seen
      local client = {
        request = function(_, _, _, handler)
          handler(nil, {
            { position = { line = 0, character = 2 }, label = "x:", kind = 2 },
            { position = { line = 0, character = 5 }, label = "y:", kind = 2 },
          }, { bufnr = buf })
          return true
        end,
      }
      ui.wrap_hint_requests(client)
      client:request("textDocument/inlayHint", {}, function(_, res)
        seen = res
      end, buf)
      H.eq(1, #seen)
      H.eq("y:", seen[1].label)
    end
  )
end)
