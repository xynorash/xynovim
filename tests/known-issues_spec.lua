-- Regression specs for the entries of docs/KNOWN_ISSUES.md that config fixed:
--   * a multi-file LSP edit is undone as a whole (config/rename_undo.lua)
--   * the naming lints of the two diagnostic tiers show once (config/ux.lua)
--   * a quote typed after a backslash does not leave a stray quote (plugins/mini-pairs.lua)
--   * crates.nvim's diagnostics are not published twice (plugins/crates.lua)
--   * the frame chosen after a panic stop (config/dap_panic.lua; the live stop is in dap-neotest-coverage_spec)
local H = require("xynotest.helpers")

local function write(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Two files on disk, both open, and a workspace edit renaming `old` to `new` in both.
local function rename_fixture()
  local dir = H.tmpdir()
  local a, b = dir .. "/a.txt", dir .. "/b.txt"
  write(a, "let old = 1\nold + 1\n")
  write(b, "use old\n")
  vim.cmd("edit " .. vim.fn.fnameescape(b))
  local bufb = vim.api.nvim_get_current_buf()
  vim.cmd("edit " .. vim.fn.fnameescape(a))
  local bufa = vim.api.nvim_get_current_buf()
  local function te(l, s, e)
    return { range = { start = { line = l, character = s }, ["end"] = { line = l, character = e } }, newText = "new" }
  end
  local edit = {
    changes = {
      [vim.uri_from_fname(a)] = { te(0, 4, 7), te(1, 0, 3) },
      [vim.uri_from_fname(b)] = { te(0, 4, 7) },
    },
  }
  return { a = a, b = b, bufa = bufa, bufb = bufb, edit = edit }
end

describe("a multi-file LSP edit (rename) and undo", function()
  it("u in one file undoes the edit in every file, <C-r> redoes it", function()
    H.very_lazy()
    local ru = require("config.rename_undo")
    ru.setup()
    local f = rename_fixture()
    vim.lsp.util.apply_workspace_edit(f.edit, "utf-16")
    H.eq({ "let new = 1", "new + 1" }, lines(f.bufa))
    H.eq({ "use new" }, lines(f.bufb))
    vim.api.nvim_set_current_buf(f.bufa)
    H.feed("u")
    H.eq({ "let old = 1", "old + 1" }, lines(f.bufa), "current file")
    H.eq({ "use old" }, lines(f.bufb), "the other file is back as well")
    H.feed("<C-r>")
    H.eq({ "let new = 1", "new + 1" }, lines(f.bufa))
    H.eq({ "use new" }, lines(f.bufb), "redo reaches the other file too")
  end)

  it("a single-file edit and an edit made since keep the stock undo", function()
    H.very_lazy()
    local ru = require("config.rename_undo")
    ru.setup()
    local f = rename_fixture()
    vim.lsp.util.apply_workspace_edit(f.edit, "utf-16")
    -- typed since in this buffer: u is the plain undo of that change only
    vim.api.nvim_set_current_buf(f.bufa)
    vim.cmd("let &undolevels = &undolevels") -- the rename is its own undo block
    vim.api.nvim_buf_set_lines(f.bufa, 0, 1, false, { "let typed = 1" })
    H.feed("u")
    H.eq({ "let new = 1", "new + 1" }, lines(f.bufa), "only the typed change is undone")
    H.eq({ "use new" }, lines(f.bufb), "the other file keeps the rename")
    -- a one-buffer edit never forms a group
    ru.last = nil
    vim.api.nvim_set_current_buf(f.bufb)
    local one = { changes = { [vim.uri_from_fname(f.b)] = f.edit.changes[vim.uri_from_fname(f.b)] } }
    vim.api.nvim_buf_set_lines(f.bufb, 0, -1, false, { "use old" })
    vim.lsp.util.apply_workspace_edit(one, "utf-16")
    H.is_nil(ru.last, "no group for one buffer")
  end)

  it("the files are not left in the half state that auto-save would write", function()
    H.very_lazy()
    local ru = require("config.rename_undo")
    ru.setup()
    local f = rename_fixture()
    vim.lsp.util.apply_workspace_edit(f.edit, "utf-16")
    vim.cmd("silent wall")
    vim.api.nvim_set_current_buf(f.bufa)
    H.feed("u")
    vim.cmd("silent wall") -- what auto-save does a second later
    H.eq({ "let old = 1", "old + 1" }, vim.fn.readfile(f.a), "a.txt on disk")
    H.eq({ "use old" }, vim.fn.readfile(f.b), "b.txt on disk is not left renamed")
  end)
end)

-- ------------------------------------------------------------ naming lints

describe("naming lints reported by both tiers (field test: shown twice)", function()
  local ux = require("config.ux")

  local function two_tiers(ra, clippy)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x", "y" })
    -- the clippy tier gets the LOWER namespace id: before, its uncoded twin won
    local a = vim.api.nvim_create_namespace("ki-clippy-" .. vim.uv.hrtime())
    local b = vim.api.nvim_create_namespace("ki-ra-" .. vim.uv.hrtime())
    vim.diagnostic.set(
      a,
      buf,
      { vim.tbl_extend("force", { lnum = 0, col = 0, severity = 2, source = "bacon-ls" }, clippy) }
    )
    vim.diagnostic.set(
      b,
      buf,
      { vim.tbl_extend("force", { lnum = 0, col = 0, severity = 3, source = "rust-analyzer" }, ra) }
    )
    return ux.diagnostic_text(vim.diagnostic.get(buf, { namespace = a })[1]),
      ux.diagnostic_text(vim.diagnostic.get(buf, { namespace = b })[1])
  end

  -- the wording is what rust-analyzer and rustc/clippy printed for the same code in a probe crate
  local cases = {
    {
      "non_camel_case_types",
      "Structure `bad_type` should have UpperCamelCase name, e.g. `BadType`",
      "warning: type `bad_type` should have an upper camel case name\n --> src/main.rs:2:8",
    },
    {
      "non_snake_case",
      "Function `BadName` should have snake_case name, e.g. `bad_name`",
      "warning: function `BadName` should have a snake case name\n --> src/main.rs:1:4",
    },
    {
      "non_snake_case",
      "Variable `Mixed` should have snake_case name, e.g. `mixed`",
      "warning: variable `Mixed` should have a snake case name",
    },
    {
      "non_upper_case_globals",
      "Constant `lower` should have UPPER_SNAKE_CASE name, e.g. `LOWER`",
      "warning: constant `lower` should have an upper case name",
    },
  }
  for _, c in ipairs(cases) do
    it(c[1] .. ": one line of virtual text, rust-analyzer's", function()
      local clippy_text, ra_text = two_tiers({ code = c[1], message = c[2] }, { message = c[3] })
      H.is_nil(clippy_text, "the clippy twin is hidden")
      H.eq(c[2] .. " [rust-analyzer]", ra_text)
    end)
  end

  it("the same lint on two different identifiers on one line stays two problems", function()
    local clippy_text, ra_text = two_tiers(
      { code = "non_snake_case", message = "Variable `Mixed` should have snake_case name, e.g. `mixed`" },
      { message = "warning: variable `Other` should have a snake case name" }
    )
    H.ok(clippy_text, "a different identifier is not hidden")
    H.ok(ra_text)
  end)

  it("a different naming lint for the same identifier stays too", function()
    local clippy_text = two_tiers(
      { code = "non_snake_case", message = "Function `Foo` should have snake_case name, e.g. `foo`" },
      { message = "warning: type `Foo` should have an upper camel case name" }
    )
    H.ok(clippy_text)
  end)
end)

-- ---------------------------------------------------------- panic frame

describe("config/dap_panic: the frame shown after a panic stop", function()
  local dp = require("config.dap_panic")
  local function f(name, path)
    return { id = 1, name = name, source = path and { path = path } or nil }
  end

  it("skips the runtime frames above the first workspace frame", function()
    local frames = {
      f("__rustc::rust_panic", "/rustc/abc/library/std/src/panicking.rs"),
      f("std::panicking::panic_with_hook", "/rustc/abc/library/std/src/panicking.rs"),
      f(
        "core::panicking::panic_fmt",
        "/home/u/.rustup/toolchains/x/lib/rustlib/src/rust/library/core/src/panicking.rs"
      ),
      f("rust_begin_unwind"),
      f("panicker::check", "/home/u/proj/src/main.rs"),
      f("panicker::main", "/home/u/proj/src/main.rs"),
    }
    H.eq("panicker::check", dp.target(frames).name)
  end)

  it("does nothing for a stop that is not in rust_panic, or when no user frame exists", function()
    H.is_nil(dp.target({ f("panicker::check", "/p/src/main.rs"), f("panicker::main", "/p/src/main.rs") }))
    H.is_nil(dp.target({ f("__rustc::rust_panic", "/rustc/a/x.rs"), f("core::panicking::panic", "/rustc/a/y.rs") }))
    H.is_nil(dp.target({}))
  end)
end)

-- ---------------------------------------------------------------- mini.pairs

describe("mini.pairs and an escaped quote (field test: a stray quote at the end)", function()
  --- type `keys` in insert mode in a fresh buffer of filetype `ft`; returns the line
  local function typed(ft, keys)
    vim.cmd("enew!")
    vim.bo.filetype = ft
    vim.api.nvim_feedkeys(vim.keycode("A" .. keys .. "<Esc>"), "tx", false)
    return vim.api.nvim_get_current_line()
  end

  for _, ft in ipairs({ "text", "lua", "rust" }) do
    it(ft .. ': "a\\"b" is typed as it reads, with no stray quote', function()
      H.very_lazy()
      H.eq('"a\\"b"', typed(ft, '"a\\"b"'))
    end)
  end

  it("an even number of backslashes still lets the quote close the string", function()
    H.very_lazy()
    H.eq('"a\\\\"', typed("text", '"a\\\\"'))
    H.eq("'a\\'b'", typed("text", "'a\\'b'"))
  end)

  it("the usual pairing is untouched", function()
    H.very_lazy()
    H.eq('"ab"', typed("text", '"ab"'))
    H.eq("(x)", typed("text", "(x)"))
  end)
end)

-- ---------------------------------------------------------------- crates.nvim

describe("crates.nvim diagnostics (field test: 'upgrade available' twice)", function()
  it("an exact repeat in crates.nvim's namespaces is published once, other namespaces are untouched", function()
    require("lazy").load({ plugins = { "crates.nvim" } })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'serde = "0.9"', 'log = "0.3"' })
    local function d(lnum, msg)
      return {
        bufnr = buf,
        lnum = lnum,
        col = 0,
        end_lnum = lnum,
        end_col = 5,
        severity = 2,
        source = "crates",
        message = msg,
      }
    end
    local custom = vim.api.nvim_create_namespace("crates.nvim")
    vim.diagnostic.set(
      custom,
      buf,
      { d(0, "There is an upgrade available"), d(0, "There is an upgrade available"), d(1, "x") }
    )
    H.eq(2, #vim.diagnostic.get(buf, { namespace = custom }), "line 1 once, line 2 once")
    local diag_ns = vim.api.nvim_create_namespace("crates.nvim.diagnostic")
    vim.diagnostic.set(diag_ns, buf, { d(0, "a"), d(0, "a") })
    H.eq(1, #vim.diagnostic.get(buf, { namespace = diag_ns }))
    -- two different messages on one line stay two
    vim.diagnostic.set(custom, buf, { d(0, "a"), d(0, "b") })
    H.eq(2, #vim.diagnostic.get(buf, { namespace = custom }))
    -- any other namespace keeps its repeats
    local other = vim.api.nvim_create_namespace("ki-other")
    vim.diagnostic.set(other, buf, { d(0, "a"), d(0, "a") })
    H.eq(2, #vim.diagnostic.get(buf, { namespace = other }))
  end)
end)
