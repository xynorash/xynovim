-- xyno-timeout: 400
-- config.import_engine: pure scoring/decision/parsing (table driven, no
-- server), the project memory (temp state file), the scan and the auto-import
-- flow against a FAKE rust-analyzer client (hermetic), and the acceptance
-- cases against the real rust-analyzer on the deps-lab fixture (skipped
-- without rust-analyzer, cargo or the registry crates).
local H = require("xynotest.helpers")
local E = require("config.import_engine")
local ca = require("xyno_rust.code_actions")
local cm = require("xyno_rust.crate_meta")

local restores = {}
local function stub(t, k, v)
  local orig = t[k]
  t[k] = v
  restores[#restores + 1] = function()
    t[k] = orig
  end
end

local saved_mode = vim.g.xynovim_auto_import
local saved_debounce = E.config.debounce

before_each(function()
  stub(E, "state_file", H.tmpdir() .. "/state/imports.json")
  E.reload_memory()
end)

after_each(function()
  for i = #restores, 1, -1 do
    pcall(restores[i])
  end
  restores = {}
  E.reload_memory()
  E.config.debounce = saved_debounce
  vim.g.xynovim_auto_import = saved_mode
  pcall(vim.cmd, "silent! %bwipeout!")
end)

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function cands(...)
  local out = {}
  for _, p in ipairs({ ... }) do
    out[#out + 1] = E.candidate(p)
  end
  return out
end

local function paths(list)
  return vim.tbl_map(function(c)
    return c.path
  end, list)
end

describe("use paths and titles", function()
  it("flattens use statements", function()
    local cases = {
      { "use serde::Serialize;", { "serde::Serialize" } },
      { "use std::{io::{self, Read}, fmt::Display as D};", { "std::io", "std::io::Read", "std::fmt::Display" } },
      { "pub(crate) use a::b::*;", { "a::b::*" } },
      { "use a::{b, c::{d, e}};", { "a::b", "a::c::d", "a::c::e" } },
      { "use a::{\n    b, // note\n    c,\n};", { "a::b", "a::c" } },
    }
    for _, c in ipairs(cases) do
      H.eq(c[2], E.flatten_use(c[1]), c[1])
    end
  end)

  it("collects the use statements of a text", function()
    local text = "use a::b;\n// use no::pe;\nmod m {\n    pub use c::{d, e};\n}\nfn f() { let use_it = 1; }\n"
    H.eq({ "a::b", "c::d", "c::e" }, vim.fn.sort(E.use_paths(text)))
  end)

  it("reads the import title and refuses anything odd", function()
    H.eq("std::io::Error", E.parse_title("Import `std::io::Error`"))
    H.eq("std::fmt::Write", E.parse_title("Import `std::fmt::Write as _`"))
    H.is_nil(E.parse_title("Qualify as `std::io::Error`"))
    H.is_nil(E.parse_title("Import `a; rm -rf`"))
    H.is_nil(E.parse_title(nil))
  end)

  it("reads the return type hint", function()
    H.eq({ error = true, mod = "io" }, E.parse_return("io::Result<()>"))
    H.eq({ error = true, mod = "io" }, E.parse_return("Result<u8, io::Error>"))
    H.eq({ error = true, mod = "anyhow" }, E.parse_return("anyhow::Result<T>"))
    H.eq({ error = true }, E.parse_return("Result<u8, MyError>"))
    H.is_nil(E.parse_return("Option<u8>"))
  end)
end)

describe("scoring", function()
  local ERR = cands("std::error::Error", "std::fmt::Error", "std::io::Error", "thiserror::Error", "anyhow::Error")
  local deps = { anyhow = 1, thiserror = 2 }

  it("ranks the derive macro of a proc-macro crate first inside #[derive(", function()
    local ranked = E.rank(ERR, { ctx = { derive = true }, dep_index = deps, proc_macro = { thiserror = true } })
    H.eq("thiserror::Error", ranked[1].path)
    H.match(table.concat(ranked[1].why, ";"), "derive macro", true)
  end)

  it("ranks std::io::Error first for a fn returning io::Result", function()
    local ctx = E.parse_return("io::Result<()>")
    local ranked = E.rank(ERR, { ctx = { error = true, ret = ctx }, dep_index = deps })
    H.eq("std::io::Error", ranked[1].path)
  end)

  it("weights use in this file over siblings over the crate", function()
    local a, b = unpack(cands("x::Thing", "y::Thing"))
    local function best(uses)
      return E.rank({ a, b }, { uses = uses })[1].path
    end
    H.eq("y::Thing", best({ file = { "y::Thing" } }))
    H.eq("x::Thing", best({ crate = { "x::Thing", "x::Thing" }, sibling = { "y::Thing" } }), "2x crate (4) beats 1x sibling (3)")
    H.eq("y::Thing", best({ crate = { "x::Thing" }, sibling = { "y::Thing" } }))
    H.eq("x::Thing", best({ file = { "y::Thing" }, sibling = { "x::Thing", "x::Thing" } }), "file 4 vs sibling 6: sibling wins")
  end)

  it("counts uses of the same module as weaker evidence", function()
    local ranked = E.rank(cands("std::io::Error", "std::fmt::Error"), { uses = { file = { "std::io::Read", "std::io::Write" } } })
    H.eq("std::io::Error", ranked[1].path)
    local score = ranked[1].score
    H.eq(2 * 4 * 0.5, score)
  end)

  it("prefers traits in a trait position", function()
    local c = cands("std::fmt::Write", "std::io::Write", "foo::Write")
    c[3].kind = nil
    local ranked = E.rank(c, { ctx = { trait_pos = true } })
    H.eq("trait", ranked[1].kind)
    H.eq("foo::Write", ranked[3].path)
  end)

  it("penalises std items a dependency shadows, and core twins of std", function()
    local ranked = E.rank(cands("std::error::Error", "anyhow::Error", "core::error::Error"), { dep_index = { anyhow = 1 } })
    H.eq({ "anyhow::Error", "std::error::Error", "core::error::Error" }, paths(ranked))
  end)

  it("breaks ties by dependency order, then by path", function()
    local ranked = E.rank(cands("b::Thing", "a::Thing", "c::Thing"), { dep_index = { b = 1, c = 2 } })
    H.eq({ "b::Thing", "c::Thing", "a::Thing" }, paths(ranked))
    ranked = E.rank(cands("z::T", "a::T"), {})
    H.eq({ "a::T", "z::T" }, paths(ranked))
  end)

  it("ranks candidates that need a new crate last", function()
    local c = cands("rand::Rng", "std::io::Read")
    c[1].add_crate = true
    local ranked = E.rank(c, {})
    H.eq("std::io::Read", ranked[1].path)
    H.match(table.concat(ranked[2].why, ";"), "not a dependency yet", true)
  end)
end)

describe("decisions", function()
  local one = cands("serde::Serialize")
  local many = cands("std::fmt::Error", "std::io::Error")
  it("takes a single candidate in 'single' mode, asks in 'ask', does nothing when off", function()
    H.eq("apply", E.decide("single", one).act)
    H.eq("ask", E.decide("ask", one).act)
    H.eq("off", E.decide("off", one).act)
  end)
  it("never guesses between several candidates", function()
    H.eq("pick", E.decide("single", many).act)
    H.eq("none", E.decide("single", {}).act)
  end)
  it("lets a remembered choice win over ambiguity, only if it is still offered", function()
    local d = E.decide("single", many, "std::io::Error")
    H.eq("apply", d.act)
    H.eq("std::io::Error", d.cand.path)
    H.eq("pick", E.decide("single", many, "gone::Error").act)
    H.eq("ask", E.decide("ask", many, "std::io::Error").act)
  end)
  it("does not take a crate-adding candidate automatically", function()
    local c = cands("rand::Rng")
    c[1].add_crate = true
    H.eq("pick", E.decide("single", c).act)
  end)
  it("defaults to ask", function()
    vim.g.xynovim_auto_import = nil
    H.eq("ask", E.mode())
    vim.g.xynovim_auto_import = "bogus"
    H.eq("ask", E.mode())
    vim.g.xynovim_auto_import = "single"
    H.eq("single", E.mode())
  end)
end)

describe("memory", function()
  it("persists per project and name, and survives a restart", function()
    H.ok(E.remember("/proj/a", "Error", "std::io::Error"))
    H.ok(E.remember("/proj/b", "Error", "anyhow::Error"))
    E.reload_memory() -- what a restart does: read the file again
    H.eq("std::io::Error", E.remembered("/proj/a", "Error"))
    H.eq("anyhow::Error", E.remembered("/proj/b", "Error"))
    H.is_nil(E.remembered("/proj/a", "Other"))
    H.ok(vim.uv.fs_stat(E.state_file), "state file written")
  end)
  it("forgets one name or a whole project", function()
    E.remember("/p", "A", "x::A")
    E.remember("/p", "B", "x::B")
    H.eq(1, E.forget("/p", "A"))
    H.is_nil(E.remembered("/p", "A"))
    H.eq("x::B", E.remembered("/p", "B"))
    H.eq(1, E.forget("/p"))
    H.eq(0, E.forget("/p"))
    E.reload_memory()
    H.is_nil(E.remembered("/p", "B"))
  end)
  it("refuses names and paths that are not plain identifiers, also from the file", function()
    H.not_ok(E.remember("/p", "a b", "x::A"))
    H.not_ok(E.remember("/p", "A", "x::A; rm"))
    write(E.state_file, vim.json.encode({ ["/p"] = { Good = "x::Good", Bad = "x::Bad; rm -rf", ["Bad Name"] = "x::Y" } }))
    E.reload_memory()
    H.eq("x::Good", E.remembered("/p", "Good"))
    H.is_nil(E.remembered("/p", "Bad"))
    H.is_nil(E.remembered("/p", "Bad Name"))
  end)
  it("survives a corrupt state file", function()
    write(E.state_file, "{not json")
    E.reload_memory()
    H.is_nil(E.remembered("/p", "A"))
    H.ok(E.remember("/p", "A", "x::A"))
  end)
end)

-- A Rust file in a path-only crate, loaded in a buffer.
local function rust_buffer(lines)
  local dir = H.tmpdir() .. "/crate"
  write(dir .. "/Cargo.toml", '[package]\nname = "tmp"\nversion = "0.1.0"\nedition = "2021"\n')
  write(dir .. "/src/main.rs", table.concat(lines, "\n") .. "\n")
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/src/main.rs"))
  vim.bo.filetype = "rust"
  return vim.api.nvim_get_current_buf(), dir
end

local function need_ts()
  if not pcall(vim.treesitter.language.add, "rust") then
    skip("the rust treesitter parser is not installed")
  end
end

local function names(list)
  return vim.tbl_map(function(p)
    return p.name
  end, list)
end

describe("syntax scan", function()
  it("finds names nothing declares or imports, not generics, prelude, locals or use lines", function()
    need_ts()
    local buf = rust_buffer({
      "use std::fmt::Display;",
      "struct Local;",
      "fn f<T: Clone>(x: T, h: HashMap<u8, Local>) -> Option<Display> {",
      "    let _ = Instant::now();",
      "    None",
      "}",
    })
    local found = E.scan_syntax(buf, 0, 5)
    H.eq({ "HashMap", "Instant" }, names(found))
    H.eq(2, found[1].row)
    H.eq(#"fn f<T: Clone>(x: T, h: ", found[1].col)
  end)

  it("skips buffers above max_lines (whole-buffer reads per edit freeze huge files)", function()
    need_ts()
    local buf = rust_buffer({ "fn f() { Instant::now(); }", "", "" })
    local old = E.config.max_lines
    E.config.max_lines = 2
    local big = E.scan_syntax(buf, 0, 2)
    E.config.max_lines = old
    H.eq({}, big)
    H.eq({ "Instant" }, names(E.scan_syntax(buf, 0, 2)))
  end)

  it("finds the names inside #[derive(...)], not prelude derives or qualified ones", function()
    need_ts()
    local buf = rust_buffer({ "#[derive(Debug, Clone, Serialize, serde::Deserialize)]", "struct S;" })
    H.eq({ "Serialize" }, names(E.scan_syntax(buf, 0, 1)))
  end)

  it("ignores names inside a macro definition", function()
    need_ts()
    local buf = rust_buffer({
      "macro_rules! make {",
      "    () => { let _x: Widget = Widget::new(); };",
      "}",
      "fn f() { let _y: Gadget; }",
    })
    local found = E.unresolved(buf, 0, 3)
    H.eq({ "Gadget" }, names(found))
  end)

  it("uses the unresolved-name diagnostics of either tier", function()
    need_ts()
    local buf = rust_buffer({ "fn f() { let _y = widget::make(); }" })
    local ns = vim.api.nvim_create_namespace("import-engine-spec")
    vim.diagnostic.set(ns, buf, {
      { lnum = 0, col = 16, end_lnum = 0, end_col = 22, message = "failed to resolve: use of undeclared crate or module `widget`", severity = 1 },
    })
    H.eq({ "widget" }, names(E.scan_diagnostics(buf, 0, 0)))
    vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, end_lnum = 0, end_col = 2, message = "unresolved import `a::b`", severity = 1 } })
    H.eq({}, E.scan_diagnostics(buf, 0, 0))
  end)
end)

describe("use index", function()
  it("reads multi-line use statements of every file under a root and invalidates", function()
    local root = H.tmpdir() .. "/ws"
    write(root .. "/src/a.rs", "use serde::{\n    Deserialize,\n    Serialize,\n};\nfn main() {}\n")
    write(root .. "/src/b.rs", "pub use std::io::Read;\n")
    write(root .. "/target/debug/skip.rs", "use ignored::Thing;\n")
    local got
    E.use_index(root, function(m)
      got = m
    end)
    H.wait_for(function()
      return got
    end, 20000, "use index")
    H.eq({ "serde::Deserialize", "serde::Serialize" }, vim.fn.sort(got[root .. "/src/a.rs"]))
    H.eq({ "std::io::Read" }, got[root .. "/src/b.rs"])
    H.is_nil(got[root .. "/target/debug/skip.rs"])
    -- cached until invalidated
    write(root .. "/src/c.rs", "use new::Thing;\n")
    local again
    E.use_index(root, function(m)
      again = m
    end)
    H.wait_for(function()
      return again
    end, 5000)
    H.is_nil(again[root .. "/src/c.rs"])
    E.invalidate_uses()
    local third
    E.use_index(root, function(m)
      third = m
    end)
    H.wait_for(function()
      return third
    end, 20000)
    H.eq({ "new::Thing" }, third[root .. "/src/c.rs"])
  end)
end)

-- ------------------------------------------------- the flow, fake server

--- A rust-analyzer stand-in: for a range, `answers[name under the range]` is
--- the list of import paths to offer; the edit inserts the use line at 0:0.
local function fake_server(buf, answers)
  local seen = { requests = 0 }
  local client = {
    id = 4242,
    name = "rust-analyzer",
    offset_encoding = "utf-16",
    request = function(_, method, params, cb)
      seen.requests = seen.requests + 1
      local line = vim.api.nvim_buf_get_lines(buf, params.range.start.line, params.range.start.line + 1, false)[1] or ""
      local name = line:sub(params.range.start.character + 1, params.range["end"].character)
      local result = {}
      for _, path in ipairs(answers[name] or {}) do
        result[#result + 1] = {
          title = "Import `" .. path .. "`",
          kind = "quickfix",
          edit = {
            changes = {
              [vim.uri_from_bufnr(buf)] = {
                { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }, newText = "use " .. path .. ";\n" },
              },
            },
          },
        }
      end
      vim.schedule(function()
        cb(nil, result)
      end)
    end,
  }
  stub(ca, "clients", function()
    return { client }
  end)
  return seen
end

local function run_sync(buf, from, to, opts)
  local done, n
  opts = vim.tbl_extend("force", opts or {}, {
    done = function(c)
      done, n = true, c
    end,
  })
  E.run(buf, from, to, opts)
  H.wait_for(function()
    return done
  end, 30000, "import run")
  return n
end

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

describe("auto-import flow (fake rust-analyzer)", function()
  local SRC = { "fn main() {", "    let _s: Serializer = make();", "}" }

  it("'single' imports the one candidate: one undo step, a one-line note", function()
    need_ts()
    local buf = rust_buffer(SRC)
    fake_server(buf, { Serializer = { "serde::Serializer" } })
    local cap = H.capture_notify()
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local n = run_sync(buf, 0, 2, { mode = "single" })
    H.eq(1, n)
    H.eq("use serde::Serializer;", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    H.eq("imported serde::Serializer", cap.list[#cap.list].msg)
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent undo")
    end)
    H.eq(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "one undo restores the buffer")
  end)

  it("joins several imports of one run into one undo step", function()
    need_ts()
    local buf = rust_buffer({ "fn main() {", "    let _a: Alpha = x();", "    let _b: Beta = y();", "}" })
    fake_server(buf, { Alpha = { "one::Alpha" }, Beta = { "two::Beta" } })
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    H.eq(2, run_sync(buf, 0, 3, { mode = "single" }))
    local t = text(buf)
    H.match(t, "use one::Alpha;", true)
    H.match(t, "use two::Beta;", true)
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent undo")
    end)
    H.eq(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("leaves an ambiguous name alone, in 'single' mode", function()
    need_ts()
    local buf = rust_buffer(SRC)
    fake_server(buf, { Serializer = { "serde::Serializer", "other::Serializer" } })
    local before = text(buf)
    H.eq(0, run_sync(buf, 0, 2, { mode = "single" }))
    H.eq(before, text(buf))
  end)

  it("uses the remembered choice when several candidates exist", function()
    need_ts()
    local buf, dir = rust_buffer(SRC)
    fake_server(buf, { Serializer = { "serde::Serializer", "other::Serializer" } })
    E.remember(cm.root(dir .. "/src/main.rs"), "Serializer", "other::Serializer")
    H.eq(1, run_sync(buf, 0, 2, { mode = "single" }))
    H.eq("use other::Serializer;", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("does nothing when off, when not modifiable, and for macro definitions", function()
    need_ts()
    local buf = rust_buffer(SRC)
    local seen = fake_server(buf, { Serializer = { "serde::Serializer" } })
    local before = text(buf)
    H.eq(0, run_sync(buf, 0, 2, { mode = "off" }))
    vim.bo[buf].modifiable = false
    H.eq(0, run_sync(buf, 0, 2, { mode = "single" }))
    vim.bo[buf].modifiable = true
    H.eq(before, text(buf))
    H.eq(0, seen.requests, "no request was even sent")
    local mbuf = rust_buffer({ "macro_rules! m {", "    () => { let _s: Serializer = make(); };", "}" })
    local seen2 = fake_server(mbuf, { Serializer = { "serde::Serializer" } })
    H.eq(0, run_sync(mbuf, 0, 2, { mode = "single" }))
    H.eq(0, seen2.requests)
  end)

  it("'ask' prompts, applies on yes, and a dismissal is cached for the session", function()
    need_ts()
    local buf = rust_buffer(SRC)
    fake_server(buf, { Serializer = { "serde::Serializer" } })
    local asked = {}
    stub(E, "ask_key", function(cand)
      asked[#asked + 1] = cand.path
      return #asked > 1
    end)
    local before = text(buf)
    H.eq(0, run_sync(buf, 0, 2, { mode = "ask" }))
    H.eq(before, text(buf), "dismissed: nothing changed")
    H.eq(0, run_sync(buf, 0, 2, { mode = "ask" }))
    H.eq(1, #asked, "the dismissal is cached, no second prompt")
    -- a fresh project key (forget does not exist for dismissals of other roots): accept path
    local buf2 = rust_buffer({ "fn main() {", "    let _s: Other = make();", "}" })
    fake_server(buf2, { Other = { "x::Other" } })
    H.eq(1, run_sync(buf2, 0, 2, { mode = "ask" }))
    H.match(text(buf2), "use x::Other;", true)
  end)

  it("never prompts outside normal mode of the current buffer", function()
    need_ts()
    local buf = rust_buffer(SRC)
    fake_server(buf, { Serializer = { "serde::Serializer" } })
    local prompted = false
    stub(E, "ask_key", function()
      prompted = true
      return true
    end)
    vim.cmd("enew")
    H.eq(0, run_sync(buf, 0, 2, { mode = "ask" }))
    H.not_ok(prompted)
  end)

  it("triggers after InsertLeave and a save, debounced, and not again after an undo", function()
    H.known_issue({ "macos" }, "timing on the macos-latest runner (run 39647013043: auto import after InsertLeave timed out at 17 s; passes on Linux and Windows)")
    need_ts()
    vim.g.xynovim_auto_import = "single"
    E.config.debounce = 80
    H.very_lazy() -- setup() of the engine (autocmds)
    local buf = rust_buffer(SRC)
    fake_server(buf, { Serializer = { "serde::Serializer" } })
    -- the buffer was just loaded: simulate typing the line
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "    let _s: Serializer = make();" })
    vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
    H.wait_for(function()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "use serde::Serializer;"
    end, 15000, "auto import after InsertLeave")
    -- undo: the name must not come back by itself
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent undo")
      vim.cmd("doautocmd TextChanged")
    end)
    vim.wait(800)
    H.ok(not text(buf):find("use serde::Serializer;", 1, true), "an undone import is not redone")
  end)

  it("registers the commands and the keys (rI, rO) and loads a source", function()
    H.very_lazy()
    for _, c in ipairs({ "ImportName", "ImportForget", "ImportOrganize" }) do
      H.eq(2, vim.fn.exists(":" .. c), c)
    end
    need_ts()
    local buf = rust_buffer(SRC)
    vim.api.nvim_exec_autocmds("FileType", { buffer = buf })
    H.ok(vim.fn.maparg("<leader>rI", "n", false, true).buffer == 1, "<leader>rI")
    H.ok(vim.fn.maparg("<leader>rO", "n", false, true).buffer == 1, "<leader>rO")
  end)
end)

describe("resolve and sources", function()
  it("ranks the server's candidates with the extra sources, remembered ones win", function()
    need_ts()
    local buf, dir = rust_buffer({ "fn f() {", "    let _r = Rng::new();", "}" })
    fake_server(buf, { Rng = { "x::Rng", "y::Rng" } })
    local unreg = E.register_source(function(name)
      if name == "Rng" then
        return { { path = "rand::Rng", crate = "rand", add_crate = true }, { path = "bad path;", crate = "x" } }
      end
    end)
    local res = E.resolve("Rng", { bufnr = buf })
    H.eq({ "x::Rng", "y::Rng", "rand::Rng" }, paths(res.candidates))
    H.eq("x::Rng", res.best.path)
    H.not_ok(res.unambiguous)
    H.ok(res.candidates[3].add_crate)
    E.remember(cm.root(dir .. "/src/main.rs"), "Rng", "y::Rng")
    res = E.resolve("Rng", { bufnr = buf })
    H.eq("y::Rng", res.choice.path)
    H.ok(res.unambiguous)
    local got
    E.resolve("Rng", {
      bufnr = buf,
      cb = function(r)
        got = r
      end,
    })
    H.wait_for(function()
      return got
    end, 20000)
    H.eq("y::Rng", got.remembered.path)
    unreg()
    res = E.resolve("Rng", { bufnr = buf })
    H.eq(2, #res.candidates)
    H.eq({}, E.resolve("not a name!", {}).candidates)
  end)

  it("applies a source candidate through its own apply function", function()
    need_ts()
    local buf = rust_buffer({ "fn f() { let _r = Rng::new(); }" })
    fake_server(buf, {})
    local applied
    local c = E.candidate("rand::Rng", { add_crate = true, apply = function(cb)
      applied = true
      cb(true)
    end })
    local ok
    E.apply_candidate(buf, c, function(o)
      ok = o
    end)
    H.wait_for(function()
      return ok ~= nil
    end, 5000)
    H.ok(applied and ok)
    local bad
    E.apply_candidate(buf, E.candidate("rand::Rng", { add_crate = true }), function(o, err)
      bad = { o, err }
    end)
    H.wait_for(function()
      return bad
    end, 5000)
    H.not_ok(bad[1])
  end)

  it("ImportName shows the ranked list with reasons and remembers the pick", function()
    need_ts()
    local buf, dir = rust_buffer({ "use y::Other;", "fn f() {", "    let _r: Rng = z();", "}" })
    fake_server(buf, { Rng = { "x::Rng", "y::Rng" } })
    vim.api.nvim_win_set_cursor(0, { 3, 12 })
    local shown
    stub(E, "select", function(items, opts, on_choice)
      shown = { items = items, opts = opts }
      on_choice(items[2])
    end)
    local cap = H.capture_notify()
    E.import_name()
    H.wait_for(function()
      return shown
    end, 20000, "picker")
    H.eq(2, #shown.items)
    H.eq("y::Rng", shown.items[1].path, "y is used in the file (module sibling of y::Other)")
    H.match(shown.opts.format_item(shown.items[1]), "y::Rng", true)
    H.match(shown.opts.format_item(shown.items[1]), "use(s) from y", true)
    H.wait_for(function()
      return E.remembered(cm.root(dir .. "/src/main.rs"), "Rng") ~= nil
    end, 5000)
    H.eq("x::Rng", E.remembered(cm.root(dir .. "/src/main.rs"), "Rng"))
    H.match(cap.list[#cap.list].msg, "imported x::Rng", true)
  end)
end)

-- ------------------------------------------------------- real rust-analyzer

local function lab()
  H.need_rust()
  local dir = H.fixture("deps-lab")
  local meta = cm.metadata(dir)
  if not meta then
    skip("registry lacks the deps-lab crates offline")
  end
  vim.cmd.cd(vim.fn.fnameescape(dir))
  local buf = H.open(dir .. "/src/main.rs")
  H.wait_lsp("rust-analyzer", buf)
  return dir, buf
end

--- Replace the buffer and wait until rust-analyzer offers `title` at (row, col).
local function set_and_wait(buf, lines, row, col, ec, title)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local hits = ca.wait_for(buf, { start = { row, col }, ["end"] = { row, ec } }, { kind = "quickfix", title = title }, { timeout = 120000, only = { "quickfix" } })
  H.ok(#hits > 0, "rust-analyzer offered " .. title)
  -- headless nvim has no keystrokes between the setup and the action: close the undo block
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("let &undolevels = &undolevels")
  end)
end

local function lab_lines()
  return vim.fn.readfile(H.fixtures .. "/deps-lab/src/main.rs")
end

describe("real rust-analyzer on deps-lab", function()
  it("'single' imports Serialize, leaves Error alone, in one undo step", function()
    local _, buf = lab()
    local lines = lab_lines()
    -- Serialize is no longer imported; a free-standing `Error` is ambiguous
    lines[2] = "use serde::Deserialize;"
    vim.list_extend(lines, { "", "fn lonely() -> Result<(), Error> {", "    Ok(())", "}" })
    set_and_wait(buf, lines, 9, 16, 25, "^Import `serde::Serialize`")
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local cap = H.capture_notify()
    local n = run_sync(buf, 0, #lines - 1, { mode = "single" })
    local t = text(buf)
    H.eq(1, n, "exactly one import: " .. t)
    -- rust-analyzer merges it into the existing `use serde::Deserialize;`
    H.match(t, "use serde::{Deserialize, Serialize};", true)
    H.no_match(t, "use std::io::Error", true)
    H.no_match(t, "Error;", true)
    local notes = vim.tbl_map(function(c)
      return c.msg
    end, cap.list)
    H.has(notes, "imported serde::Serialize")
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent undo")
    end)
    H.eq(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "one undo restores the buffer")
  end)

  it("ranks thiserror::Error first inside #[derive( and std::io::Error for an io::Result fn", function()
    local _, buf = lab()
    local lines = lab_lines()
    lines[4] = "#[derive(Debug, Error)]"
    vim.list_extend(lines, { "", "fn reader() -> std::io::Result<()> {", "    let _e: Error = todo!();", "    Ok(())", "}" })
    set_and_wait(buf, lines, 3, 16, 21, "^Import `thiserror::Error`")
    local res = E.resolve("Error", { bufnr = buf, pos = { 3, 16 } })
    H.eq("thiserror::Error", res.best.path, vim.inspect(paths(res.candidates)))
    local row = #lines - 3
    set_and_wait(buf, lines, row, 12, 17, "^Import `std::io::Error`")
    res = E.resolve("Error", { bufnr = buf, pos = { row, 12 } })
    H.eq("std::io::Error", res.best.path, vim.inspect(paths(res.candidates)))
    H.ok(#res.candidates > 3, "ambiguous")
    -- the picker shows the reasons
    H.match(E.format_item(res.best), "return type", true)
  end)

  it("remembers an explicit choice across a restart and 'single' then applies it", function()
    local dir, buf = lab()
    local lines = lab_lines()
    vim.list_extend(lines, { "", "fn lonely() -> Result<(), Error> {", "    Ok(())", "}" })
    local row = #lines - 3
    set_and_wait(buf, lines, row, 26, 31, "^Import `std::io::Error`")
    local before = text(buf)
    H.eq(0, run_sync(buf, 0, #lines - 1, { mode = "single" }), "ambiguous without a memory")
    H.eq(before, text(buf))
    local root = cm.root(dir)
    E.remember(root, "Error", "std::io::Error")
    E.reload_memory() -- restart: read imports.json again
    H.eq("std::io::Error", E.remembered(root, "Error"))
    H.eq(1, run_sync(buf, 0, #lines - 1, { mode = "single" }))
    H.match(text(buf), "use std::io::Error;", true)
  end)

  it("organizes imports in one undo step", function()
    local _, buf = lab()
    local lines = {
      "use std::io::Read;",
      "use std::io::Write;",
      "use std::collections::HashMap;",
      "use std::{fmt};",
      "",
      "fn f(_: &mut dyn Read, _: &mut dyn Write, _: fmt::Result) {}",
      "fn main() {}",
    }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    ca.wait_for(buf, { start = { 0, 4 }, ["end"] = { 0, 4 } }, { title = "^Merge imports" }, { timeout = 120000 })
    ca.wait_for(buf, { start = { 0, 0 }, ["end"] = { 6, 0 } }, { title = "^Remove all unused imports" }, { timeout = 120000 })
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("let &undolevels = &undolevels")
    end)
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local n = E.organize(buf)
    H.ok(n >= 2, "applied " .. n)
    local t = text(buf)
    H.no_match(t, "HashMap", true)
    H.no_match(t, "use std::io::Read;", true)
    H.match(t, "use std::{fmt, io::{Read, Write}};", true)
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent undo")
    end)
    H.eq(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "one undo restores the buffer")
  end)

  it("imports on paste in 'single' mode", function()
    local _, buf = lab()
    vim.g.xynovim_auto_import = "single"
    E.config.debounce = 100
    local lines = lab_lines()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    set_and_wait(buf, vim.list_extend(vim.deepcopy(lines), { "fn t() { let _m = HashMap::<u8, u8>::new(); }" }), #lines, 18, 25, "^Import `std::collections::HashMap`")
    vim.api.nvim_buf_set_lines(buf, #lines, -1, false, {})
    vim.api.nvim_win_set_cursor(0, { #lines, 0 })
    vim.paste({ "fn t() { let _m = HashMap::<u8, u8>::new(); }" }, -1)
    H.wait_for(function()
      return text(buf):find("use std::collections::HashMap;", 1, true)
    end, 60000, "import after the paste")
  end)
end)

describe("import engine review fixes", function()
  it("the default ask_key never blocks without a UI", function()
    H.eq(0, #vim.api.nvim_list_uis())
    H.eq(false, E.ask_key({ path = "serde::Serialize" }, "Serialize"))
  end)

  it("ImportName with a remembered choice keeps the others in ranked order", function()
    need_ts()
    local buf, dir = rust_buffer({ "fn f() {", "    let _r: Error = z();", "}" })
    local names = { "a::Error", "b::Error", "c::Error", "d::Error", "e::Error", "f::Error" }
    fake_server(buf, { Error = names })
    vim.api.nvim_win_set_cursor(0, { 2, 14 })
    local root = cm.root(dir .. "/src/main.rs")
    H.ok(E.remember(root, "Error", "e::Error"))
    local shown
    stub(E, "select", function(items)
      shown = items
    end)
    E.import_name()
    H.wait_for(function()
      return shown
    end, 20000, "picker")
    H.eq("e::Error", shown[1].path)
    local rest = {}
    for i = 2, #shown do
      rest[#rest + 1] = shown[i].path
    end
    local plain
    E.resolve("Error", { bufnr = buf, pos = { 1, 12 }, cb = function(res)
      plain = {}
      for _, c in ipairs(res.candidates) do
        if c.path ~= "e::Error" then
          plain[#plain + 1] = c.path
        end
      end
    end })
    H.wait_for(function()
      return plain
    end, 20000, "resolve")
    H.eq(plain, rest)
  end)
end)
