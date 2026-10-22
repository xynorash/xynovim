-- Rust keymaps (keymaps.lua), rust_assist.lua, the rust_nav keys, after/ftplugin/rust.lua.
-- One real rust-analyzer session on tests/fixtures/keymaps-rust-crate is shared by
-- the tests; the rest of the behaviour is checked with stubs of the editor API
-- (restored in after_each) so no test depends on rust-analyzer's timing.
local H = require("xynotest.helpers")

local S -- shared session { dir, buf, client }
local undo = {}

--- Replace t[k] by v until after_each.
local function stub(t, k, v)
  local old = rawget(t, k)
  undo[#undo + 1] = function()
    rawset(t, k, old)
  end
  rawset(t, k, v)
end

local function session()
  H.need_rust()
  if S then
    vim.cmd("only")
    vim.api.nvim_set_current_buf(S.buf)
    -- the tree must follow the buffer reset of after_each (get_node does not reparse)
    vim.treesitter.get_parser(S.buf, "rust"):parse(true)
    return S
  end
  local dir, buf = H.open_fixture("keymaps-rust-crate")
  local client = H.wait_lsp("rust-analyzer", buf)
  H.wait_for(function()
    return vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg("<leader>cR", "n", false, true).desc == "Rename File"
        and vim.fn.maparg("<leader>ca", "n", false, true).desc ~= nil
    end)
  end, 15000, "the scheduled rust maps")
  S = { dir = dir, buf = buf, client = client }
  return S
end

--- maparg of `lhs` as seen from the session buffer.
local function mp(lhs, mode)
  return vim.api.nvim_buf_call(S.buf, function()
    return vim.fn.maparg(lhs, mode or "n", false, true)
  end)
end

local function find(pat)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local l = vim.fn.search("\\V" .. pat, "cw")
  H.ok(l > 0, "pattern not found in the fixture: " .. pat)
  return l
end

local function lines()
  return vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
end

local ORIGINAL
local function remember()
  ORIGINAL = ORIGINAL or lines()
end
local function reset_buffer()
  if ORIGINAL then
    vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, ORIGINAL)
    vim.bo[S.buf].modified = false
  end
end

--- Capture `vim.cmd.RustLsp(...)` calls.
local function capture_rustlsp()
  local calls = {}
  stub(vim.cmd, "RustLsp", function(arg)
    calls[#calls + 1] = arg
  end)
  return calls
end

--- Capture `vim.api.nvim_cmd({cmd = "RustLsp", ...})` calls (ssr, workspaceSymbol).
local function capture_nvim_cmd()
  local calls = {}
  local orig = vim.api.nvim_cmd
  stub(vim.api, "nvim_cmd", function(c, o)
    if type(c) == "table" and c.cmd == "RustLsp" then
      calls[#calls + 1] = c
      return ""
    end
    return orig(c, o)
  end)
  return calls
end

local function notifications()
  local cap = H.capture_notify()
  undo[#undo + 1] = cap.restore
  return cap.list
end

--- Answer vim.ui.input with `answer`; records the prompt.
local function answer_input(answer)
  local seen = {}
  stub(vim.ui, "input", function(opts, cb)
    seen[#seen + 1] = opts.prompt
    cb(answer)
  end)
  return seen
end

after_each(function()
  for i = #undo, 1, -1 do
    pcall(undo[i])
  end
  undo = {}
  if S then
    pcall(vim.cmd, "only")
    pcall(vim.api.nvim_set_current_buf, S.buf)
    pcall(reset_buffer)
  end
end)

local RA_MAPS_N = {
  "ra", "rv", "rf", "rc", "ri", "rs", "rj", "rm", "rh", "rH", "rS", "rp", "rt", "rC", "rd", "rE", "re",
  "rw", "rW", "tD", "rT", "ru", "rl", "rF", "rX", "rZ", "rN", "rR", "rP", "cR",
}
local RA_MAPS_X = { "ra", "rv", "rf", "rc", "rM", "ri", "rs", "rj", "rk" }

describe("LspAttach autocmd", function()
  before_each(function()
    H.very_lazy() -- keymaps.lua is loaded by LazyVim on VeryLazy
  end)

  --- Attach a fake client named `name` to a scratch buffer, return the buffer.
  local function fake_attach(name)
    local buf = vim.api.nvim_create_buf(false, true)
    stub(vim.lsp, "get_client_by_id", function(id)
      return id == 987654 and { name = name } or nil
    end)
    vim.api.nvim_exec_autocmds("LspAttach", { buffer = buf, data = { client_id = 987654 } })
    return buf
  end
  local function has_map(buf, lhs, mode)
    return vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg(lhs, mode or "n", false, true).buffer == 1
    end)
  end

  it("1. xynovim_rust_keymaps has an LspAttach autocmd", function()
    local acs = vim.api.nvim_get_autocmds({ group = "xynovim_rust_keymaps", event = "LspAttach" })
    H.eq(1, #acs)
  end)

  it("1. acts only for rust-analyzer (no maps for bacon_ls / taplo)", function()
    for _, name in ipairs({ "bacon_ls", "taplo" }) do
      local b = fake_attach(name)
      vim.wait(300, function()
        return false
      end)
      H.not_ok(has_map(b, "<leader>ra"), name .. " must not get the rust maps")
      H.not_ok(has_map(b, "<leader>cR"), name .. " must not get <leader>cR")
    end
  end)

  it("2. maps are set after vim.schedule, buffer-local, with a desc", function()
    local b = fake_attach("rust-analyzer")
    H.not_ok(has_map(b, "<leader>ra"), "not set synchronously")
    H.wait_for(function()
      return has_map(b, "<leader>ra")
    end, 2000, "scheduled maps")
    local m = vim.api.nvim_buf_call(b, function()
      return vim.fn.maparg("<leader>ra", "n", false, true)
    end)
    H.eq("Refactor actions", m.desc)
    local global = vim.fn.maparg("<leader>ra", "n", false, true)
    H.ok(global.buffer ~= 1, "no global <leader>ra")
    -- every rust map carries a description
    for _, mode in ipairs({ "n", "x" }) do
      for _, km in ipairs(vim.api.nvim_buf_get_keymap(b, mode)) do
        H.ok(km.desc and km.desc ~= "", "map without desc: " .. km.lhs)
      end
    end
  end)

  it("2. maps are skipped when the buffer is gone before the schedule runs", function()
    local b = fake_attach("rust-analyzer")
    vim.api.nvim_buf_delete(b, { force = true })
    vim.wait(200, function()
      return false
    end)
    H.not_ok(vim.api.nvim_buf_is_valid(b))
  end)

  it("26. adds the which-key group <leader>r = rust buffer-locally (pcall protected)", function()
    local added
    local orig = package.loaded["which-key"]
    package.loaded["which-key"] = {
      add = function(spec)
        if type(spec) == "table" and type(spec[1]) == "table" and spec[1][1] == "<leader>r" then
          added = spec
        end
      end,
    }
    undo[#undo + 1] = function()
      package.loaded["which-key"] = orig
    end
    local b = fake_attach("rust-analyzer")
    H.wait_for(function()
      return added
    end, 2000, "which-key add")
    H.eq({ { "<leader>r", group = "rust", buffer = b } }, added)

    -- a throwing which-key must not stop the other maps
    package.loaded["which-key"] = {
      add = function()
        error("boom")
      end,
    }
    local b2 = fake_attach("rust-analyzer")
    H.wait_for(function()
      return has_map(b2, "<leader>cR")
    end, 2000, "maps despite a failing which-key")
  end)
end)

describe("buffer-local maps on a Rust buffer", function()
  before_each(function()
    session()
    remember()
  end)

  it("2/25. <leader>cR is restored to 'Rename File'; <leader>ca stays 'Code Action'", function()
    local m = mp("<leader>cR")
    H.eq(1, m.buffer)
    H.eq("Rename File", m.desc)
    local called = 0
    stub(Snacks.rename, "rename_file", function()
      called = called + 1
    end)
    stub(vim.ui, "input", function(_, cb)
      cb("a_free_name.rs") -- the prompt is ours (it refuses an existing destination), then Snacks renames
    end)
    m.callback()
    H.eq(1, called)
    local ca = mp("<leader>ca")
    H.eq("Code Action", ca.desc)
    local cax = mp("<leader>ca", "x")
    H.eq("Code Action", cax.desc)
  end)

  it("27. the complete normal / visual map list is buffer-local with the documented descs", function()
    local expect_desc = {
      ra = "Refactor actions", rv = "Extract variable", rf = "Extract function", rc = "Extract constant",
      ri = "Inline", rs = "Structural search & replace", rj = "Join lines (semantic)",
      rm = "Expand macro (recursive)", rh = "View HIR", rH = "View MIR", rS = "Syntax tree",
      rp = "Parent module", rt = "Related tests", rC = "Open Cargo.toml", rd = "Open docs (local rustup, else docs.rs)",
      rE = "Open docs (same as rd)", re = "Explain error code", rw = "Workspace symbol",
      rW = "Workspace symbol (+ dependencies, all kinds)", tD = "Doctests (cargo test --doc)",
      rT = "Toggle tests in find usages", ru = "Go to super method (trait item)",
      rl = "Usages in file (R/W)", rF = "Cargo features / target (both diagnostic tiers)",
      rX = "Cargo targets: run / test / bench", rZ = "Cargo tools (deny, audit, bloat, timings, ...)",
      rN = "HTTP routes (axum / actix / rocket)", rR = "Reload workspace", rP = "Rebuild proc macros",
      cR = "Rename File",
    }
    for _, k in ipairs(RA_MAPS_N) do
      local m = mp("<leader>" .. k, "n")
      H.eq(1, m.buffer, "normal <leader>" .. k .. " buffer-local")
      H.eq(expect_desc[k], m.desc, "desc of <leader>" .. k)
    end
    for _, k in ipairs(RA_MAPS_X) do
      H.eq(1, mp("<leader>" .. k, "x").buffer, "visual <leader>" .. k .. " buffer-local")
    end
    for _, lhs in ipairs({ "<A-j>", "<A-k>" }) do
      H.eq(1, mp(lhs, "n").buffer, lhs)
    end
    H.eq("Move item down", mp("<A-j>").desc)
    H.eq("Move item up", mp("<A-k>").desc)
    -- shown as <M-j> / <M-k>, they shadow LazyVim's Move Down/Up here
    local lhs = {}
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(S.buf, "n")) do
      lhs[km.lhs] = true
    end
    H.ok(lhs["<M-j>"] and lhs["<M-k>"], "<M-j>/<M-k> in the buffer maps")

    -- no other <leader>r* in this buffer, in either mode
    local want = {}
    for _, k in ipairs(RA_MAPS_N) do
      want[k] = true
    end
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(S.buf, "n")) do
      local k = km.lhs:match("^<Space>(r.*)$")
      if k then
        H.ok(want[k], "unexpected normal map <leader>" .. k)
      end
    end
    local wantx = {}
    for _, k in ipairs(RA_MAPS_X) do
      wantx[k] = true
    end
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(S.buf, "x")) do
      local k = km.lhs:match("^<Space>(r.*)$")
      if k then
        H.ok(wantx[k], "unexpected visual map <leader>" .. k)
      end
    end
  end)

  it("3. <leader>ra (n, x) calls code_action with context.only = {'refactor'}", function()
    local got
    stub(vim.lsp.buf, "code_action", function(o)
      got = o
    end)
    for _, mode in ipairs({ "n", "x" }) do
      got = nil
      local m = mp("<leader>ra", mode)
      H.eq("Refactor actions", m.desc)
      m.callback()
      H.eq({ "refactor" }, got.context.only)
    end
  end)

  --- Which titles does the assist filter of lhs accept?
  local function filter_for(lhs, mode)
    local got
    stub(vim.lsp.buf, "code_action", function(o)
      got = o
    end)
    mp(lhs, mode).callback()
    H.ok(got and got.apply == true, "apply = true")
    return function(title)
      return got.filter({ title = title })
    end
  end

  it("4/5. rv / rf / rc filter by title and are n + x maps", function()
    for lhs, spec in pairs({
      ["<leader>rv"] = { "Extract variable", "Extract into variable", "Extract into function" },
      ["<leader>rf"] = { "Extract function", "Extract into function", "Extract into variable" },
      ["<leader>rc"] = { "Extract constant", "Extract into constant", "Extract into function" },
    }) do
      for _, mode in ipairs({ "n", "x" }) do
        H.eq(spec[1], mp(lhs, mode).desc, lhs .. " " .. mode)
      end
      local f = filter_for(lhs, "n")
      H.ok(f(spec[2]), lhs .. " matches " .. spec[2])
      H.not_ok(f(spec[3]), lhs .. " rejects " .. spec[3])
      H.not_ok(f("Do not Extract into " .. spec[2]:match("into (%a+)")), lhs .. " is anchored")
    end
  end)

  it("4. rv on `1 + 2 + 3` extracts into a variable (real rust-analyzer)", function()
    local l = find("let total = 1 + 2 + 3")
    -- cursor on the `1`; select the whole expression `1 + 2 + 3`
    local col = lines()[l]:find("1 + 2 + 3", 1, true) - 1
    vim.api.nvim_win_set_cursor(0, { l, col })
    H.feed("v8l", "x")
    H.eq("v", vim.fn.mode())
    -- rust-analyzer must have loaded the crate before it offers the assist
    local range = {
      start = { line = l - 1, character = col },
      ["end"] = { line = l - 1, character = col + 9 },
    }
    H.wait_for(function()
      local r = S.client:request_sync("textDocument/codeAction", {
        textDocument = vim.lsp.util.make_text_document_params(S.buf),
        range = range,
        context = { diagnostics = {} },
      }, 5000, S.buf)
      for _, a in ipairs(r and r.result or {}) do
        if a.title:find("^Extract into variable") then
          return true
        end
      end
    end, 90000, "rust-analyzer to offer 'Extract into variable'")
    mp("<leader>rv", "x").callback()
    H.feed("<Esc>")
    local text = H.wait_for(function()
      local t = table.concat(lines(), "\n")
      return t:find("let var_name = 1 %+ 2 %+ 3;", 1) and t
    end, 15000, "extract variable edit, buffer is now:\n" .. table.concat(lines(), "\n", 36, 44))
    H.match(text, "let total = var_name;", true)
  end)

  it("6. <leader>rM is visual only and matches Extract module / module", function()
    H.eq("Extract module (visual)", mp("<leader>rM", "x").desc)
    -- normal mode: a notice, never `r M` on the character under the cursor
    local before = lines()
    local n = notifications()
    local nm = mp("<leader>rM", "n")
    H.eq("Extract module (visual only)", nm.desc)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    nm.callback()
    H.match(n[1].msg, "select code first", true)
    H.eq(before, lines(), "normal-mode <leader>rM must not edit the buffer")
    local f = filter_for("<leader>rM", "x")
    H.ok(f("Extract module"))
    H.ok(f("Extract Module"))
    H.not_ok(f("Move module"))
  end)

  it("7. <leader>ri 'Inline' matches '^Inline [^m]' but not 'Inline macro'", function()
    for _, mode in ipairs({ "n", "x" }) do
      H.eq("Inline", mp("<leader>ri", mode).desc)
    end
    local f = filter_for("<leader>ri", "n")
    H.ok(f("Inline variable"))
    H.ok(f("Inline function"))
    H.not_ok(f("Inline macro"))
    -- the destructive variant asks first (it deleted the fn and broke `as` casts silently)
    local asked = {}
    stub(vim.fn, "confirm", function(msg)
      asked[#asked + 1] = msg
      return #asked == 1 and 2 or 1
    end)
    H.not_ok(f("Inline into all callers"), "answer No")
    H.ok(f("Inline into all callers"), "answer Yes")
    H.eq(2, #asked)
    H.match(asked[1], "Inline into all callers", true)
    H.eq(2, #asked, "other variants do not ask")
    H.ok(f("Inline function"))
    H.eq(2, #asked)
  end)

  it("8. M.ssr prompts, ignores an empty/nil answer, runs :RustLsp ssr <query>", function()
    local ra = require("config.rust_assist")
    local calls = capture_nvim_cmd()
    local prompts = answer_input("a ==>> b")
    ra.ssr()
    H.eq({ "SSR query (pattern ==>> replacement): " }, prompts)
    H.eq(1, #calls)
    H.eq({ cmd = "RustLsp", args = { "ssr", "a ==>> b" } }, calls[1])

    for _, none in ipairs({ "", "nil" }) do
      calls = capture_nvim_cmd()
      answer_input(none ~= "nil" and none or nil)
      ra.ssr()
      H.eq(0, #calls, "empty answer does nothing")
    end
  end)

  it("8. a query without `==>>` is refused with a notice instead of a rustaceanvim traceback", function()
    local ra = require("config.rust_assist")
    local calls = capture_nvim_cmd()
    local n = notifications()
    answer_input("nonsense ==>")
    ra.ssr()
    H.eq(0, #calls)
    H.eq(1, #n)
    H.eq(vim.log.levels.WARN, n[1].level)
    H.match(n[1].msg, "pattern ==>> replacement", true)
  end)

  it("8. a query rust-analyzer cannot parse gives a WARN notice, not rustaceanvim's traceback (real rust-analyzer)", function()
    local ra = require("config.rust_assist")
    local n = notifications()
    local errs = {}
    stub(vim.api, "nvim_err_writeln", function(m)
      errs[#errs + 1] = m
    end)
    answer_input("nonsense ==>>")
    ra.ssr()
    local ssr = H.wait_for(function()
      for _, x in ipairs(n) do
        if x.msg:find("^SSR") then
          return x
        end
      end
    end, 30000, "a notice for the SSR parse error")
    -- WARN with rust-analyzer's parse error; INFO "SSR: no matches" when the
    -- server answers an unloaded workspace with an empty result instead
    H.ok(ssr.level == vim.log.levels.WARN or ssr.level == vim.log.levels.INFO, "level " .. tostring(ssr.level))
    H.match(ssr.msg, "SSR: ", true)
    H.eq({}, errs)
    -- the wrapper is gone again
    local rv = require("rustaceanvim.rust_analyzer")
    H.eq(rv.buf_request, rv.buf_request)
    H.is_nil(debug.getinfo(rv.buf_request, "S").source:find("rust_assist", 1, true))
  end)

  it("8. a query that matches nothing says 'SSR: no matches' (real rust-analyzer)", function()
    local ra = require("config.rust_assist")
    local n = notifications()
    answer_input("Some(98765) ==>> None")
    -- rust-analyzer answers "content modified" while the workspace is still
    -- loading (slow machines, CI): ask again until it has settled
    local ssr
    H.wait_for(function()
      if not ssr then
        ra.ssr()
      end
      for _, x in ipairs(n) do
        if x.msg == "SSR: no matches" then
          ssr = x
          return true
        end
      end
      vim.wait(1500)
      for i = #n, 1, -1 do
        if n[i].msg == "SSR: content modified" then
          table.remove(n, i)
        end
      end
      return false
    end, 60000, "SSR: no matches")
    H.eq({ msg = "SSR: no matches", level = vim.log.levels.INFO }, ssr)
  end)

  it("8. <leader>rs maps: normal and selection variants", function()
    H.eq("Structural search & replace", mp("<leader>rs", "n").desc)
    H.eq("Structural search & replace (selection)", mp("<leader>rs", "x").desc)
    local calls = capture_nvim_cmd()
    answer_input("x ==>> y")
    mp("<leader>rs", "n").callback()
    H.is_nil(calls[1].range)
  end)

  it("8. the visual variant leaves visual mode and passes the '< '> range", function()
    local calls = capture_nvim_cmd()
    answer_input("x ==>> y")
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    H.feed("Vj", "x")
    H.eq("V", vim.fn.mode())
    mp("<leader>rs", "x").callback()
    H.eq("n", vim.fn.mode())
    H.eq({ 3, 4 }, calls[1].range)
    H.eq({ "ssr", "x ==>> y" }, calls[1].args)
  end)

  it("9/10/11/14/24. simple RustLsp maps", function()
    local calls = capture_rustlsp()
    local plain = {
      ["<leader>rj"] = { "joinLines", "Join lines (semantic)" },
      ["<leader>rm"] = { "expandMacro", "Expand macro (recursive)" },
      ["<leader>rp"] = { "parentModule", "Parent module" },
      ["<leader>rt"] = { "relatedTests", "Related tests" },
      ["<leader>rC"] = { "openCargo", "Open Cargo.toml" },
      ["<leader>rR"] = { "reloadWorkspace", "Reload workspace" },
      ["<leader>rP"] = { "rebuildProcMacros", "Rebuild proc macros" },
    }
    for lhs, spec in pairs(plain) do
      calls[1] = nil
      local m = mp(lhs)
      H.eq(spec[2], m.desc)
      m.callback()
      H.eq(spec[1], calls[1], lhs)
    end
    local tabled = {
      ["<leader>rh"] = { { "view", "hir" }, "View HIR" },
      ["<leader>rH"] = { { "view", "mir" }, "View MIR" },
    }
    for lhs, spec in pairs(tabled) do
      calls[1] = nil
      local m = mp(lhs)
      H.eq(spec[2], m.desc)
      m.callback()
      H.eq(spec[1], calls[1], lhs)
    end
  end)

  it("<A-j>/<A-k> send experimental/moveItem and apply the edits as plain text (`$e` is kept)", function()
    session()
    remember()
    local ra = require("rustaceanvim.rust_analyzer")
    local sent = {}
    stub(ra, "buf_request", function(_, method, params, handler)
      sent[#sent + 1] = { method, params.direction }
      -- unescaped snippet edit like rust-analyzer's: `$e` and the `$0` marker
      handler(nil, {
        { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } },
          newText = "($e:expr) => { $e + $e$0 };", insertTextFormat = 2 },
      }, { bufnr = S.buf, client_id = S.client.id })
    end)
    vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, { "aaa", "bbb" })
    mp("<A-j>").callback()
    H.eq("($e:expr) => { $e + $e };", lines()[1])
    H.eq("bbb", lines()[2])
    mp("<A-k>").callback()
    H.eq({ { "experimental/moveItem", "Down" }, { "experimental/moveItem", "Up" } }, sent)
    reset_buffer()
  end)

  it("<leader>cR refuses an existing destination (was overwritten) and renames to a free name", function()
    session()
    local from = vim.api.nvim_buf_get_name(S.buf)
    local other = vim.fs.dirname(from) .. "/other_existing.txt"
    vim.fn.writefile({ "keep me" }, other)
    local answer
    local renamed = {}
    local prompts = {}
    stub(vim.ui, "input", function(o, cb)
      prompts[#prompts + 1] = o.default
      local dir = o.default:match("^(.*)/[^/]*$")
      cb((dir and dir .. "/" or "") .. answer)
    end)
    stub(Snacks.rename, "rename_file", function(o)
      renamed[#renamed + 1] = o
    end)
    local n = notifications()
    answer = "other_existing.txt"
    mp("<leader>cR").callback()
    H.eq(1, #prompts, "prompted; notes: " .. vim.inspect(n))
    H.eq(0, #renamed, "nothing is renamed over an existing file")
    H.eq({ "keep me" }, vim.fn.readfile(other))
    H.eq(vim.log.levels.ERROR, n[#n].level)
    H.match(n[#n].msg, "already exists", true)
    answer = "fresh_name.rs"
    mp("<leader>cR").callback()
    H.eq(1, #renamed)
    H.eq(from, renamed[1].from)
    H.match(renamed[1].to, "/fresh_name.rs", true)
    os.remove(other)
  end)

  it("9. <leader>rj in visual mode is the :RustLsp joinLines<CR> command", function()
    local m = mp("<leader>rj", "x")
    H.eq("Join lines (semantic)", m.desc)
    H.eq(":RustLsp joinLines<CR>", m.rhs)
  end)

  it("16. <leader>rk (visual) is RustLsp hover range, and not a normal map", function()
    local calls = capture_rustlsp()
    local m = mp("<leader>rk", "x")
    H.eq("Hover range (type of selection)", m.desc)
    m.callback()
    H.eq({ "hover", "range" }, calls[1])
    local before = lines()
    local n = notifications()
    local nm = mp("<leader>rk", "n")
    H.eq("Hover range (visual only)", nm.desc)
    nm.callback()
    H.eq(1, #calls, "normal mode must not call hover range again")
    H.match(n[1].msg, "select code first", true)
    H.eq(before, lines())
  end)

  it("11. <leader>rh really opens a HIR buffer (real rust-analyzer)", function()
    local l = find("fn used")
    vim.api.nvim_win_set_cursor(0, { l, 4 })
    mp("<leader>rh").callback()
    -- rust-analyzer answers asynchronously and rustaceanvim opens the window (and moves focus) in
    -- the callback: wait for a window showing another buffer with content, not only for a new window
    local hir
    H.wait_for(function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local b = vim.api.nvim_win_get_buf(w)
        if b ~= S.buf and #vim.api.nvim_buf_get_lines(b, 0, -1, false) > 1 then
          hir = b
          return true
        end
      end
    end, 30000, "a window with the HIR")
    H.ok(hir ~= S.buf, "a HIR buffer is shown")
  end)

  it("23. <leader>rF/rX/rZ/rN run the :Rust* commands", function()
    local want = { rF = "RustContext", rX = "RustTargets", rZ = "RustTools", rN = "RustRoutes" }
    for k, cmd in pairs(want) do
      H.eq("<cmd>" .. cmd .. "<cr>", mp("<leader>" .. k).rhs, k)
      H.eq(2, vim.fn.exists(":" .. cmd), cmd .. " is a user command")
    end
  end)

  it("34. <leader>rD and <leader>rr are not mapped (only the global hidden 'not bound' stub)", function()
    for _, lhs in ipairs({ "<leader>rD", "<leader>rr" }) do
      for _, mode in ipairs({ "n", "x" }) do
        local m = mp(lhs, mode)
        H.eq(0, m.buffer or 0, lhs .. " in " .. mode .. " is not buffer-local")
        H.eq("which_key_ignore", m.desc, lhs .. " in " .. mode)
      end
    end
  end)

  it("35. explainError / renderDiagnostic / relatedDiagnostics are not bound", function()
    for _, mode in ipairs({ "n", "x" }) do
      for _, km in ipairs(vim.api.nvim_buf_get_keymap(S.buf, mode)) do
        local s = (km.rhs or "") .. " " .. (km.desc or "")
        for _, w in ipairs({ "explainError", "renderDiagnostic", "relatedDiagnostics" }) do
          H.no_match(s, w, true, "buffer map " .. km.lhs)
        end
      end
    end
    -- and the global maps do not carry them either
    for _, km in ipairs(vim.api.nvim_get_keymap("n")) do
      local s = (km.rhs or "") .. " " .. (km.desc or "")
      for _, w in ipairs({ "explainError", "renderDiagnostic", "relatedDiagnostics" }) do
        H.no_match(s, w, true, "global map " .. km.lhs)
      end
    end
  end)
end)

describe("rust_assist", function()
  local ra, rarust
  before_each(function()
    session()
    remember()
    ra = require("config.rust_assist")
    rarust = require("rustaceanvim.rust_analyzer")
  end)

  --- Stub rustaceanvim's buf_request; `reply(method, params)` returns err, res.
  local function stub_request(reply)
    local seen = {}
    stub(rarust, "buf_request", function(_, method, params, cb)
      seen[#seen + 1] = { method = method, params = params }
      local err, res = reply(method, params)
      cb(err, res)
    end)
    return seen
  end

  local function syntax_tree_buffer(result, err)
    stub_request(function()
      return err, result
    end)
    local before = #vim.api.nvim_list_wins()
    mp("<leader>rS").callback()
    H.eq(before + 1, #vim.api.nvim_list_wins(), "a vsplit opened")
    return vim.api.nvim_get_current_buf()
  end

  it("12/32. syntax tree JSON is pretty-printed: sorted keys, 2 spaces, scalar arrays inline, {}", function()
    local buf = syntax_tree_buffer('{"b":1,"a":[1,2],"c":{},"d":[{"x":"s","a":null}],"e":"t"}')
    H.eq({
      "{",
      '  "a": [1,2],',
      '  "b": 1,',
      '  "c": {},',
      '  "d": [',
      "    {",
      '      "a": null,',
      '      "x": "s"',
      "    }",
      "  ],",
      '  "e": "t"',
      "}",
    }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("12. the tree buffer is a nomodifiable json scratch buffer; q closes the split", function()
    local wins = #vim.api.nvim_list_wins()
    local buf = syntax_tree_buffer('{"k":[]}')
    H.eq("json", vim.bo[buf].filetype)
    H.not_ok(vim.bo[buf].modifiable)
    H.eq("nofile", vim.bo[buf].buftype)
    H.feed("q")
    H.eq(wins, #vim.api.nvim_list_wins())
    H.not_ok(vim.api.nvim_get_current_buf() == buf)
  end)

  it("12. a plain-text answer (older servers) is shown with filetype rust", function()
    local buf = syntax_tree_buffer("SOURCE_FILE@0..3\n  FN@0..3")
    H.eq("rust", vim.bo[buf].filetype)
    H.eq({ "SOURCE_FILE@0..3", "  FN@0..3" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("12. an error answer notifies 'rust-analyzer: <msg>' (ERROR) and opens nothing", function()
    local n = notifications()
    stub_request(function()
      return { message = "boom" }, nil
    end)
    local wins = #vim.api.nvim_list_wins()
    mp("<leader>rS").callback()
    H.eq({ { msg = "rust-analyzer: boom", level = vim.log.levels.ERROR } }, n)
    H.eq(wins, #vim.api.nvim_list_wins())
    n[1] = nil
    stub_request(function()
      return nil, nil
    end)
    mp("<leader>rS").callback()
    H.eq("rust-analyzer: viewSyntaxTree failed", n[1].msg)
  end)

  it("12. syntax tree request goes to rust-analyzer/viewSyntaxTree with the document", function()
    local seen = stub_request(function()
      return nil, "{}"
    end)
    mp("<leader>rS").callback()
    H.eq("rust-analyzer/viewSyntaxTree", seen[1].method)
    H.match(seen[1].params.textDocument.uri, "main.rs", true)
  end)

  it("13. syntax_tree and open_docs return silently without a rustaceanvim client", function()
    local n = notifications()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local requested = 0
    stub(rarust, "buf_request", function()
      requested = requested + 1
    end)
    local wins = #vim.api.nvim_list_wins()
    ra.syntax_tree()
    ra.open_docs()
    H.eq(0, requested)
    H.eq({}, n)
    H.eq(wins, #vim.api.nvim_list_wins())
  end)

  describe("open_docs", function()
    local function run(res)
      local opened = {}
      stub(require("rustaceanvim.config.internal").tools, "open_url", function(url)
        opened[#opened + 1] = url
      end)
      local n = notifications()
      local seen = stub_request(function()
        return nil, res
      end)
      mp("<leader>rd").callback()
      return opened, n, seen
    end
    local INFO = vim.log.levels.INFO
    local NODOC = "no documentation for the item under the cursor"

    it("15. rd and rE both call M.open_docs and request externalDocs", function()
      H.eq("Open docs (local rustup, else docs.rs)", mp("<leader>rd").desc)
      H.eq("Open docs (same as rd)", mp("<leader>rE").desc)
      local calls = 0
      stub(ra, "open_docs", function()
        calls = calls + 1
      end)
      mp("<leader>rd").callback()
      mp("<leader>rE").callback()
      H.eq(2, calls)
      undo[#undo]() -- put the real open_docs back
      undo[#undo] = nil
      local _, _, seen = run({ web = "https://x/" })
      H.eq("experimental/externalDocs", seen[1].method)
    end)

    it("15. vim.NIL or a non-table answer: INFO notification, no error, nothing opened", function()
      for _, res in ipairs({ vim.NIL, "oops", false }) do
        local opened, n = run(res)
        H.eq({}, opened)
        H.eq({ { msg = NODOC, level = INFO } }, n)
      end
    end)

    it("15. the local docs file is preferred when it exists, else the web URL", function()
      local dir = H.tmpdir()
      local f = dir .. "/index.html"
      vim.fn.writefile({ "x" }, f)
      local uri = vim.uri_from_fname(f)
      local opened = run({ ["local"] = uri, web = "https://docs.rs/x" })
      H.eq({ uri }, opened)
      opened = run({ ["local"] = vim.uri_from_fname(dir .. "/missing.html"), web = "https://docs.rs/x" })
      H.eq({ "https://docs.rs/x" }, opened)
      opened = run({ ["local"] = vim.NIL, web = "https://docs.rs/y" })
      H.eq({ "https://docs.rs/y" }, opened)
    end)

    it("15. neither local nor web: INFO notification", function()
      local opened, n = run({ ["local"] = vim.NIL, web = vim.NIL })
      H.eq({}, opened)
      H.eq({ { msg = NODOC, level = INFO } }, n)
      opened, n = run({})
      H.eq({}, opened)
      H.eq(NODOC, n[1].msg)
    end)
  end)

  describe("explain error <leader>re", function()
    local ns = vim.api.nvim_create_namespace("keymaps_rust_spec")
    local function diag(list)
      local l = find("let total")
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      for _, d in ipairs(list) do
        d.lnum = l - 1
        d.col = 0
      end
      vim.diagnostic.set(ns, S.buf, list)
      undo[#undo + 1] = function()
        vim.diagnostic.reset(ns, S.buf)
      end
    end
    local function capture_win()
      local got
      stub(Snacks, "win", function(o)
        -- snacks' notifier opens its own windows (style "notification") for earlier
        -- tests' still-pending notifications; only the explain float counts here
        if o and o.style == "notification" then
          return
        end
        got = o
      end)
      return function()
        return got
      end
    end

    it("17. d.code (E0000 style) shows rustc --explain in a markdown float", function()
      H.eq("Explain error code", mp("<leader>re").desc)
      local win = capture_win()
      diag({ { message = "mismatched types", code = "E0308" } })
      mp("<leader>re").callback()
      local o = H.wait_for(win, 20000, "the explain float")
      H.eq("markdown", o.ft)
      H.eq(" E0308 ", o.title)
      H.eq(0.7, o.width)
      H.eq(0.8, o.height)
      H.eq("rounded", o.border)
      H.match(table.concat(o.text, "\n"), "Expected type did not match", true)
    end)

    it("17. the code is taken from the message when d.code is missing or not E-shaped", function()
      local win = capture_win()
      diag({
        { message = "something", code = 123 },
        { message = "error[E0599]: no method named `x`" },
      })
      mp("<leader>re").callback()
      local o = H.wait_for(win, 20000, "the explain float")
      H.eq(" E0599 ", o.title)
    end)

    it("17. no E-code on the line: INFO notification, nothing runs", function()
      local n = notifications()
      local win = capture_win()
      local ran = false
      stub(vim, "system", function()
        ran = true
      end)
      diag({ { message = "unused variable", code = "unused_variables" } })
      mp("<leader>re").callback()
      H.eq({ { msg = "no E0000 error code in the diagnostics on this line", level = vim.log.levels.INFO } }, n)
      H.not_ok(ran)
      H.is_nil(win())
    end)

    it("17. a failing rustc --explain gives an ERROR notification and no float", function()
      local n = notifications()
      local win = capture_win()
      local cmd
      stub(vim, "system", function(c, _, cb)
        cmd = c
        cb({ code = 1, stderr = "no such code" })
      end)
      diag({ { message = "x", code = "E9999" } })
      mp("<leader>re").callback()
      H.wait_for(function()
        return n[1]
      end, 2000, "error notification")
      H.eq({ "rustc", "--explain", "E9999" }, cmd)
      H.eq(vim.log.levels.ERROR, n[1].level)
      H.match(n[1].msg, "rustc --explain E9999 failed", true)
      H.match(n[1].msg, "no such code", true)
      H.is_nil(win())
    end)
  end)

  describe("workspace symbol", function()
    it("18. rw / rW ask once ('Symbol query: '), search the first word (and say so), bang for rW", function()
      H.eq("Workspace symbol", mp("<leader>rw").desc)
      H.eq("Workspace symbol (+ dependencies, all kinds)", mp("<leader>rW").desc)
      local calls = capture_nvim_cmd()
      local prompts = answer_input("  Hash Map  ")
      local cap = H.capture_notify()
      mp("<leader>rw").callback()
      mp("<leader>rW").callback()
      cap.restore()
      H.eq({ "Symbol query: ", "Symbol query: " }, prompts)
      H.eq({ cmd = "RustLsp", args = { "workspaceSymbol", "Hash" } }, calls[1])
      H.eq({ cmd = "RustLsp", args = { "workspaceSymbol", "Hash" }, bang = true }, calls[2])
      H.match(cap.list[1].msg, "only one word is searched (Hash)", true)
      prompts = answer_input("   ")
      mp("<leader>rw").callback()
      H.eq(2, #calls, "a blank query runs nothing")
    end)

    it("18. from the quickfix window rw runs in a Rust window of the tab (RustLsp does not exist elsewhere)", function()
      local seen_ft
      local orig = vim.api.nvim_cmd
      stub(vim.api, "nvim_cmd", function(c, o)
        if type(c) == "table" and c.cmd == "RustLsp" then
          seen_ft = vim.bo.filetype
          return ""
        end
        return orig(c, o)
      end)
      answer_input("Foo")
      vim.fn.setqflist({}, "r", { items = { { text = "x" } } })
      vim.cmd("copen")
      H.eq("qf", vim.bo.filetype)
      mp("<leader>rw", "n").callback()
      H.eq("rust", seen_ft)
      vim.fn.setqflist({}, "r")
    end)

    it("18. an empty answer does nothing", function()
      local calls = capture_nvim_cmd()
      answer_input("")
      mp("<leader>rw").callback()
      H.eq(0, #calls)
    end)

    it("18. vim.npcall is shimmed to vim.F.npcall", function()
      H.ok(vim.npcall, "vim.npcall exists")
      H.eq(vim.F.npcall, vim.npcall)
    end)

    it("18. results land in the quickfix list (real rust-analyzer)", function()
      vim.fn.setqflist({}, "r")
      stub(vim.ui, "input", function(_, cb)
        cb("Square")
      end)
      mp("<leader>rw").callback()
      local items = H.wait_for(function()
        local qf = vim.fn.getqflist()
        return #qf > 0 and qf
      end, 60000, "workspace symbol results in the quickfix list")
      local found = false
      for _, it in ipairs(items) do
        found = found or (it.text or ""):find("Square", 1, true) ~= nil
      end
      H.ok(found, "a Square result: " .. vim.inspect(items))
      vim.fn.setqflist({}, "r")
    end)
  end)

  it("19. <leader>tD runs cargo test --doc --workspace (+ context flags) in a Snacks terminal in the root", function()
    H.eq("Doctests (cargo test --doc)", mp("<leader>tD").desc)
    local cmd, opts
    stub(Snacks.terminal, "open", function(c, o)
      cmd, opts = c, o
    end)
    mp("<leader>tD").callback()
    H.eq({ "cargo", "test", "--doc", "--workspace" }, vim.list_slice(cmd, 1, 4))
    H.ok(#cmd >= 5, "context flags appended: " .. vim.inspect(cmd))
    H.eq(vim.uv.fs_realpath(S.dir), vim.uv.fs_realpath(opts.cwd))
    H.eq("bottom", opts.win.position)
  end)

  it("19. <leader>tD is buffer-local (no global map)", function()
    H.not_ok(vim.fn.maparg("<leader>tD", "n", false, true).buffer == 1 and false)
    local g = vim.tbl_filter(function(m)
      return m.lhs == "<Space>tD"
    end, vim.api.nvim_get_keymap("n"))
    H.eq({}, g)
  end)

  it("20. <leader>rT flips excludeTests, sends didChangeConfiguration and notifies", function()
    H.eq("Toggle tests in find usages", mp("<leader>rT").desc)
    local n = notifications()
    local sent = {}
    local c = S.client
    local orig_notify = c.notify
    stub(c, "notify", function(self, method, params)
      sent[#sent + 1] = { method = method, params = params }
      return orig_notify(self, method, params)
    end)
    local refs = c.settings["rust-analyzer"].references
    local start = refs.excludeTests
    mp("<leader>rT").callback()
    H.eq(not start, refs.excludeTests)
    H.eq("workspace/didChangeConfiguration", sent[1].method)
    H.eq(c.settings, sent[1].params.settings)
    H.eq("find usages: tests " .. (refs.excludeTests and "excluded" or "included"), n[1].msg)
    mp("<leader>rT").callback()
    H.eq(start, refs.excludeTests)
    H.eq("find usages: tests " .. (start and "excluded" or "included"), n[2].msg)
  end)

  it("20. references of `used` go 2 -> 3 when tests are included (import stays excluded)", function()
    local c = S.client
    local refs = c.settings["rust-analyzer"].references
    H.eq(true, refs.excludeTests, "default: tests excluded")
    local l = find("pub fn used")
    local col = lines()[l]:find("used", 1, true) - 1
    local function count()
      local res = c:request_sync("textDocument/references", {
        textDocument = vim.lsp.util.make_text_document_params(S.buf),
        position = { line = l - 1, character = col },
        context = { includeDeclaration = true },
      }, 20000, S.buf)
      return res and res.result and #res.result or -1
    end
    H.wait_for(function()
      return count() == 2
    end, 60000, "2 references with tests excluded")
    mp("<leader>rT").callback()
    H.wait_for(function()
      return count() == 3
    end, 60000, "3 references with tests included")
    mp("<leader>rT").callback()
    H.wait_for(function()
      return count() == 2
    end, 60000, "2 references again")
  end)
end)

-- The behaviour of the two commands is specced in xyno-rust.nvim (rust-nav_spec); here only the keys.
describe("rust_nav keys", function()
  before_each(function()
    session()
    remember()
  end)

  it("21. maps: ru / rl descs", function()
    H.eq("Go to super method (trait item)", mp("<leader>ru").desc)
    H.eq("Usages in file (R/W)", mp("<leader>rl").desc)
  end)

  it("21. outside a function: WARN 'not inside a function'", function()
    local n = notifications()
    find("use std::fmt")
    mp("<leader>ru").callback()
    H.eq({ { msg = "not inside a function", level = vim.log.levels.WARN } }, n)
  end)
end)

describe("global maps of keymaps.lua", function()
  local function g(lhs)
    return vim.fn.maparg(lhs, "n", false, true)
  end

  it("28. <leader>uu 'Undotree' opens the built-in undotree", function()
    local m = g("<leader>uu")
    H.eq("Undotree", m.desc)
    H.not_ok(m.buffer == 1)
    local opened = 0
    package.preload["undotree"] = nil
    local packadd = {}
    stub(vim.cmd, "packadd", function(name)
      packadd[#packadd + 1] = name
    end)
    local fake = { open = function() opened = opened + 1 end }
    local orig = package.loaded["undotree"]
    package.loaded["undotree"] = fake
    undo[#undo + 1] = function()
      package.loaded["undotree"] = orig
    end
    m.callback()
    H.eq({ "nvim.undotree" }, packadd)
    H.eq(1, opened)
  end)

  it("28. <leader>uu works for real (the nvim.undotree package exists)", function()
    local before = #vim.api.nvim_list_wins()
    vim.cmd.edit(vim.fn.tempname() .. ".txt")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a" })
    g("<leader>uu").callback()
    H.ok(#vim.api.nvim_list_wins() > before, "the undotree opened a window")
    vim.cmd("only")
  end)

  it("28. <leader>gH 'Local history (file)' is :LocalHistory", function()
    local m = g("<leader>gH")
    H.eq("Local history (file)", m.desc)
    H.eq("<cmd>LocalHistory<cr>", m.rhs)
    H.eq(2, vim.fn.exists(":LocalHistory"))
  end)

  it("28. <leader>uB is the Colourblind diagnostics toggle", function()
    local m = g("<leader>uB")
    H.match(m.desc, "Colourblind diagnostics", true)
    local ux = require("config.ux")
    local start = ux.colorblind_enabled()
    m.callback()
    H.eq(not start, ux.colorblind_enabled())
    m.callback()
    H.eq(start, ux.colorblind_enabled())
  end)
end)

describe("after/ftplugin/rust.lua", function()
  local function scratch(ft)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = ft
    return buf
  end
  local function quote_map(buf)
    return vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg("'", "i", false, true)
    end)
  end

  it("29. the ' insert map is buffer-local with the documented desc", function()
    local buf = scratch("rust")
    local m = quote_map(buf)
    H.eq(1, m.buffer)
    H.eq("Quote (no pairing: lifetimes)", m.desc)
  end)

  it("29. typing &'a str leaves no stray closing quote", function()
    local buf = scratch("rust")
    H.feed("ix: &'a str<Esc>")
    H.eq("x: &'a str", vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1])
    H.feed("ccx: Foo<'b><Esc>")
    H.eq("x: Foo<'b>", vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1])
  end)

  it("29. spell is on locally with camel in spelloptions", function()
    local buf = scratch("rust")
    H.ok(vim.wo.spell)
    H.match(vim.bo[buf].filetype, "rust")
    H.ok(vim.tbl_contains(vim.opt_local.spelloptions:get(), "camel"))
    -- local, not global
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(other)
    vim.bo[other].filetype = "lua"
    H.not_ok(vim.wo.spell and false)
  end)

  it("33. the \" map inserts a plain quote behind an odd number of backslashes, every other one goes to mini.pairs", function()
    -- (typing it through feedkeys evaluates expr maps before the preceding keys of the same
    -- batch are inserted, so the map is called directly with the line state of each case)
    local buf = scratch("rust")
    H.very_lazy()
    local m = vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg('"', "i", false, true)
    end)
    H.eq(1, m.buffer)
    H.eq(1, m.expr)
    local function press(line, col, fn)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
      -- (normal mode clamps the cursor onto the last character; insert mode may sit behind it)
      local orig = vim.api.nvim_win_get_cursor
      vim.api.nvim_win_get_cursor = function()
        return { 1, col or #line }
      end
      local ok, res = pcall(fn or m.callback)
      vim.api.nvim_win_get_cursor = orig
      assert(ok, res)
      return res
    end
    H.eq('"', press('let f = "a\\'), "one backslash: escaped quote")
    H.eq('"', press('let f = "a\\\\\\'), "three backslashes")
    -- every other state is delegated to the global mini.pairs mapping
    local global
    for _, g in ipairs(vim.api.nvim_get_keymap("i")) do
      if g.lhs == '"' then
        global = g
      end
    end
    H.ok(global and global.expr == 1, "mini.pairs' global map")
    for _, line in ipairs({ "let f = ", 'let f = "a\\\\' }) do
      local got = press(line)
      local expected = press(line, nil, function()
        return vim.api.nvim_eval(global.rhs)
      end)
      H.eq(expected, got, "delegated: " .. line)
    end
    H.ok(press("let f = ") ~= '"', "a plain quote still pairs")
  end)

  it("31. the ' map exists only in Rust buffers (not toml / lua)", function()
    for _, ft in ipairs({ "toml", "lua" }) do
      local buf = scratch(ft)
      H.not_ok(quote_map(buf).buffer == 1, ft .. " has no buffer-local quote map")
    end
    H.eq(1, quote_map(scratch("rust")).buffer)
  end)

  describe("spell checking", function()
    local function open_main()
      local dir = H.fixture("keymaps-rust-crate")
      vim.cmd.cd(vim.fn.fnameescape(dir))
      vim.cmd.edit(vim.fn.fnameescape(dir .. "/src/main.rs"))
      H.very_lazy()
      return vim.api.nvim_get_current_buf()
    end

    it("30. the highlights query marks only comments as @spell", function()
      local buf = open_main()
      local parser = vim.treesitter.get_parser(buf, "rust")
      local tree = parser:parse()[1]
      local query = vim.treesitter.query.get("rust", "highlights")
      local spelled = {}
      for id, node in query:iter_captures(tree:root(), buf) do
        if query.captures[id] == "spell" then
          spelled[#spelled + 1] = node
        end
      end
      H.ok(#spelled > 0)
      local function covered(row, col)
        for _, n in ipairs(spelled) do
          local sr, sc, er, ec = n:range()
          if (row > sr or (row == sr and col >= sc)) and (row < er or (row == er and col < ec)) then
            return true
          end
        end
        return false
      end
      local function at(pat, word)
        local row = vim.fn.search(pat, "nw") - 1
        local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
        return row, line:find(word, 1, true) - 1
      end
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      H.ok(covered(at("misspeled", "misspeled")), "doc comment spelled")
      H.ok(covered(at("bdword", "bdword")), "line comment spelled")
      H.not_ok(covered(at("name_wrdx = ", "name_wrdx")), "identifier skipped")
      H.not_ok(covered(at("strng literal", "strng")), "string skipped")
    end)

    it("30. ]s finds only the misspelled words in comments", function()
      local buf = open_main()
      vim.bo.spelllang = "en"
      if vim.fn.spellbadword("misspeled")[1] == "" then
        H.skip_file("no English spell dictionary available")
      end
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local found = {}
      for _ = 1, 8 do
        vim.cmd("silent! normal! ]s")
        local w = vim.fn.expand("<cword>")
        if found[w] then
          break
        end
        found[w] = true
      end
      H.ok(found["misspeled"], "doc comment word flagged: " .. vim.inspect(found))
      H.ok(found["bdword"], "line comment word flagged: " .. vim.inspect(found))
      H.not_ok(found["wrdx"] or found["name_wrdx"] or found["strng"], "identifier/string flagged: " .. vim.inspect(found))
      H.ok(vim.api.nvim_buf_is_valid(buf))
    end)

    it("32. Rust words (Vec, tokio, usize, impl) are in the shipped spellfile and not flagged", function()
      open_main()
      vim.bo.spelllang = "en"
      if vim.fn.spellbadword("misspeled")[1] == "" then
        H.skip_file("no English spell dictionary available")
      end
      local files = vim.opt_local.spellfile:get()
      H.eq(vim.fn.stdpath("config") .. "/spell/en.utf-8.add", files[#files])
      for _, w in ipairs({ "Vec", "tokio", "serde", "usize", "impl", "async", "struct", "TODO" }) do
        H.eq("", vim.fn.spellbadword(w)[1], w .. " flagged")
      end
      H.eq("misspeled", vim.fn.spellbadword("misspeled")[1])
      -- `zg` goes to the user's own list, not into this repo
      H.match(files[1], "/site/spell/en.utf-8.add", true)
    end)
  end)
end)
