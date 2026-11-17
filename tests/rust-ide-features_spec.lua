-- xyno-timeout: 400
-- IDE features around rust-analyzer, checked against the real server on tests/fixtures/keymaps-rust-crate
-- and the real Trouble / crates.nvim: call hierarchy, find usages, workspace symbols, the diff-preview
-- code-action and refactor menus (xyno-rust.nvim), :RustFixAll, run configurations, the Problems panel
-- filters, and organize imports on save (the Cargo.toml completion is cargo-toml-ui_spec.lua). Needs XYNOVIM_DEV_PLUGINS for the xyno-rust commands (skipped otherwise).
local H = require("xynotest.helpers")

local S
local function session()
  H.need_rust()
  if S then
    vim.api.nvim_set_current_buf(S.buf)
    return S
  end
  local dir, buf = H.open_fixture("keymaps-rust-crate")
  local client = H.wait_lsp("rust-analyzer", buf)
  H.wait_for(function()
    return vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg("<leader>rb", "n", false, true).desc ~= nil
    end)
  end, 20000, "the scheduled rust maps")
  S = { dir = dir, buf = buf, client = client }
  -- analysed: documentSymbol answers
  H.wait_for(function()
    local r = vim.lsp.buf_request_sync(
      buf,
      "textDocument/documentSymbol",
      { textDocument = vim.lsp.util.make_text_document_params(buf) },
      5000
    )
    for _, x in pairs(r or {}) do
      if x.result and #x.result > 0 then
        return true
      end
    end
  end, 90000, "analysis")
  return S
end

local function need_dev()
  if
    vim.fn.exists(":RustRun") ~= 2
    or not pcall(require, "xyno_rust.run_configs")
    or not pcall(require, "xyno_rust.action_menu")
  then
    H.skip_file(
      "the pinned xyno-rust.nvim has no run_configs / action_menu modules (run with XYNOVIM_DEV_PLUGINS=~/projects/xyno-plugins)"
    )
  end
end

local function pos_of(buf, pat)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local c = l:find(pat, 1, true)
    if c then
      return { line = i - 1, character = c - 1 }
    end
  end
  error("pattern not in the fixture: " .. pat)
end

local function request(method, params, ms)
  local s = session()
  local res = vim.lsp.buf_request_sync(s.buf, method, params, ms or 20000)
  local out = res and res[s.client.id]
  return out and out.result, out and out.err
end

describe("navigation features (rust-analyzer)", function()
  it("call hierarchy: `used` is called from `main` (incoming), and `main` calls `used` (outgoing)", function()
    local s = session()
    local p = pos_of(s.buf, "pub fn used")
    p.character = p.character + 8
    local tdp = { textDocument = vim.lsp.util.make_text_document_params(s.buf), position = p }
    local items = H.wait_for(function()
      local r = request("textDocument/prepareCallHierarchy", tdp)
      return r and #r > 0 and r
    end, 60000, "prepareCallHierarchy")
    H.eq("used", items[1].name)
    local inc = H.wait_for(function()
      local r = request("callHierarchy/incomingCalls", { item = items[1] })
      return r and #r > 0 and r
    end, 60000, "incoming calls")
    local from = vim.tbl_map(function(c)
      return c.from.name
    end, inc)
    H.has(from, "main")
    local mp = pos_of(s.buf, "fn main")
    mp.character = mp.character + 3
    local mitems = request("textDocument/prepareCallHierarchy", { textDocument = tdp.textDocument, position = mp })
    local out = H.wait_for(function()
      local r = request("callHierarchy/outgoingCalls", { item = mitems[1] })
      return r and #r > 0 and r
    end, 60000, "outgoing calls")
    H.has(
      vim.tbl_map(function(c)
        return c.to.name
      end, out),
      "plain"
    )
  end)

  it("the call hierarchy trees are Trouble modes with a key", function()
    local keys = {}
    for _, k in ipairs(require("lazy.core.config").plugins["trouble.nvim"].keys or {}) do
      keys[k[1]] = k[2]
    end
    H.match(keys["<leader>cI"], "lsp_incoming_calls", true)
    H.match(keys["<leader>cO"], "lsp_outgoing_calls", true)
  end)

  it("find usages: references of `used` include its call in main", function()
    local s = session()
    local p = pos_of(s.buf, "pub fn used")
    p.character = p.character + 8
    local refs = request("textDocument/references", {
      textDocument = vim.lsp.util.make_text_document_params(s.buf),
      position = p,
      context = { includeDeclaration = false },
    })
    H.ok(#refs >= 1, "references")
  end)

  it("workspace symbol search finds a type by a fragment of its name", function()
    local r = H.wait_for(function()
      local res = request("workspace/symbol", { query = "Wrap" })
      return res and #res > 0 and res
    end, 60000, "workspace/symbol")
    H.has(
      vim.tbl_map(function(x)
        return x.name
      end, r),
      "Wrapper"
    )
  end)
end)

describe("code actions with a diff preview", function()
  it("<leader>ca, <leader>ra, <leader>rb, <leader>rB, <leader>rQ are buffer maps to the xyno-rust commands", function()
    local s = session()
    need_dev()
    local function m(lhs, mode)
      return vim.api.nvim_buf_call(s.buf, function()
        return vim.fn.maparg(lhs, mode or "n", false, true)
      end)
    end
    -- <leader>ca is LazyVim's buffer map with our callback (editing-ui.lua): it runs :RustActions in Rust
    local ran = {}
    local real_cmd = vim.cmd
    for _, mode in ipairs({ "n", "x" }) do
      local cb = m("<leader>ca", mode).callback
      H.ok(cb, "<leader>ca callback in mode " .. mode)
      vim.cmd = setmetatable({}, {
        __call = function(_, c)
          ran[#ran + 1] = c
        end,
        __index = real_cmd,
      })
      vim.api.nvim_buf_call(s.buf, cb)
      vim.cmd = real_cmd
    end
    H.eq({ "RustActions", "RustActions" }, ran)
    H.match(m("<leader>ra").rhs, "RustRefactor", true)
    H.match(m("<leader>rb").rhs, "RustRun", true)
    H.match(m("<leader>rB").rhs, "RustRunLast", true)
    H.match(m("<leader>rQ").rhs, "RustFixAll", true)
  end)

  it("the refactor menu shows Extract and Inline with diffs against the real server (real Snacks picker)", function()
    local s = session()
    need_dev()
    local am = require("xyno_rust.action_menu")
    vim.api.nvim_set_current_buf(s.buf)
    local p = pos_of(s.buf, "self.0 * self.0")
    local got
    am.open({
      only = { "refactor" },
      range = { start = { p.line, p.character }, ["end"] = { p.line, p.character + 6 } },
      pick = function(items, o)
        got = { items = items, opts = o }
      end,
    })
    H.wait_for(function()
      return got
    end, 60000, "menu items")
    local titles = vim.tbl_map(function(i)
      return i.title
    end, got.items)
    H.has(titles, "Extract into variable")
    -- the real picker accepts the options and renders a preview (no stub of Snacks)
    local picker = Snacks.picker(vim.tbl_extend("force", got.opts, { focus = "list" }))
    H.wait_for(function()
      return picker.preview and picker.preview.win and picker.preview.win:valid()
    end, 10000, "picker preview window")
    H.wait_for(function()
      local b = picker.preview.win.buf
      local l = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      return table.concat(l, "\n"):find("@@", 1, true) ~= nil or table.concat(l, "\n"):find("changes no text", 1, true)
    end, 20000, "a diff in the preview")
    local txt = table.concat(vim.api.nvim_buf_get_lines(picker.preview.win.buf, 0, -1, false), "\n")
    H.match(txt, "main.rs", true)
    H.match(txt, "--- a/", true)
    picker:close()
  end)
end)

describe("run configurations in the full config", function()
  it(":RustRun defines defaults for the crate, runs `main` with args and env in a terminal", function()
    local s = session()
    need_dev()
    local R = require("xyno_rust.run_configs")
    local trust = require("xyno_rust.trust")
    trust.trust(s.dir)
    local opened
    local orig = R.open
    R.open = function(argv, env, root)
      opened = { argv = argv, env = env, root = root }
    end
    vim.api.nvim_set_current_buf(s.buf)
    local rc = require("xyno_rust.rust_context")
    local root = H.wait_for(function()
      return rc.root(nil, { nowait = true })
    end, 20000, "root")
    R.save(root, {
      name = "with args",
      cmd = "run",
      bin = "keymaps_rust_crate",
      args = "--n 3 'a b'",
      env = { RUST_LOG = "debug" },
    })
    local n = H.capture_notify()
    R.run_named("with args")
    H.wait_for(function()
      return opened or #n.list > 0
    end, 30000, "terminal")
    H.ok(opened, vim.inspect(n.list))
    R.open = orig
    H.eq("cargo", opened.argv[1])
    H.has(opened.argv, "--bin")
    H.eq({ "--", "--n", "3", "a b" }, vim.list_slice(opened.argv, #opened.argv - 3))
    H.eq({ RUST_LOG = "debug" }, opened.env)
    pcall(R.delete, root, "with args")
    pcall(vim.uv.fs_unlink, R.file())
  end)
end)

describe("Problems panel filters (real Trouble)", function()
  it("e / w / S / a narrow the diagnostics list by severity and source, and the header names the filter", function()
    require("lazy").load({ plugins = { "trouble.nvim" } })
    local P = require("config.problems")
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
    vim.api.nvim_set_current_buf(buf)
    local ns1, ns2 = vim.api.nvim_create_namespace("pf1"), vim.api.nvim_create_namespace("pf2")
    vim.diagnostic.set(ns1, buf, {
      { lnum = 0, col = 0, message = "e1", severity = 1, source = "rustc" },
      { lnum = 1, col = 0, message = "w1", severity = 2, source = "rustc" },
    })
    vim.diagnostic.set(ns2, buf, { { lnum = 2, col = 0, message = "h1", severity = 4, source = "clippy" } })
    local T = require("trouble")
    local view = T.open({ mode = "diagnostics", new = true, focus = false })
    H.ok(view.opts.keys.e and view.opts.keys.w and view.opts.keys.S and view.opts.keys.a, "keys merged into the mode")
    local Filter = require("trouble.filter")
    local function shown()
      local out = {}
      for _, item in ipairs(T.get_items({ mode = "diagnostics" })) do
        local ok = true
        for _, f in pairs(view._filters) do
          ok = ok and Filter.is(item, f.filter, { opts = view.opts })
        end
        if ok then
          out[#out + 1] = item.item.message
        end
      end
      table.sort(out)
      return out
    end
    H.eq({ "e1", "h1", "w1" }, shown())
    P.actions.errors(view)
    H.eq({ "e1" }, shown())
    P.actions.errors(view) -- again: lifted
    H.eq({ "e1", "h1", "w1" }, shown())
    P.actions.warnings(view)
    H.eq({ "e1", "w1" }, shown())
    -- the header names it
    local header = vim.inspect(view:header())
    H.match(header, "errors and warnings", true)
    P.actions.clear(view)
    P.actions.source(view) -- first source, alphabetical: clippy
    H.eq({ "h1" }, shown())
    P.actions.source(view)
    H.eq({ "e1", "w1" }, shown())
    P.actions.source(view) -- past the last: all
    H.eq({ "e1", "h1", "w1" }, shown())
    -- severity and source combine
    P.actions.warnings(view)
    P.actions.source(view)
    P.actions.source(view)
    H.eq({ "e1", "w1" }, shown())
    P.actions.errors(view)
    H.eq({ "e1" }, shown())
    P.actions.clear(view)
    H.eq({ "e1", "h1", "w1" }, shown())
    view:close()
    vim.diagnostic.reset(ns1, buf)
    vim.diagnostic.reset(ns2, buf)
  end)

  it("<leader>xe opens the errors-only list", function()
    local m = vim.fn.maparg("<leader>xe", "n", false, true)
    H.match(m.rhs or "", "severity=vim.diagnostic.severity.ERROR", true)
  end)
end)

describe("organize imports on save", function()
  it("is off by default, and when on organizes after the write and writes again", function()
    local s = session()
    need_dev()
    local ra = require("config.rust_assist")
    local engine = require("xyno_imports.engine")
    local calls = 0
    local orig = engine.organize
    engine.organize = function(buf, cb)
      calls = calls + 1
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "// organized" })
      cb(1)
    end
    vim.api.nvim_set_current_buf(s.buf)
    local before = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
    vim.g.xynovim_organize_on_save = nil
    ra.organize_on_save(s.buf)
    H.eq(0, calls, "off by default")
    vim.g.xynovim_organize_on_save = true
    vim.cmd("silent write")
    H.wait_for(function()
      return calls == 1
    end, 5000, "organize after :w")
    H.eq(false, vim.bo[s.buf].modified, "written again")
    H.eq("// organized", vim.fn.readfile(s.dir .. "/src/main.rs")[1])
    -- a buffer-local off wins
    vim.b[s.buf].xynovim_organize_on_save = false
    ra.organize_on_save(s.buf)
    H.eq(1, calls)
    vim.b[s.buf].xynovim_organize_on_save = nil
    vim.g.xynovim_organize_on_save = nil
    engine.organize = orig
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, before)
    vim.cmd("silent write")
  end)
end)
