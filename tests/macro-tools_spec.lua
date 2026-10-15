-- config.macro_tools: macro call help (signature popup from macro_rules!
-- matcher arms, format-string / sqlx hints, snippets), the macro lens
-- (:MacroExpand) and :ProcMacroStatus.
-- The first half is pure and table-driven (lexer, placeholder counting,
-- matcher parsing and matching, report text). The "live" half runs a real
-- rust-analyzer on a copy of the deps-lab fixture and skips without it.
local H = require("xynotest.helpers")
local mt = require("config.macro_tools")

after_each(function()
  pcall(mt.close_popup)
  pcall(mt.lens_close)
  pcall(vim.cmd, "silent! %bwipeout!")
  -- one rust-analyzer per live test: a leftover one keeps building
  for _, c in ipairs(vim.lsp.get_clients()) do
    pcall(c.stop, c, true)
  end
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
end)

--- Run fn with FileType autocmds ignored (no rustaceanvim attach).
local function quiet(fn)
  local saved = vim.o.eventignore
  vim.o.eventignore = "FileType"
  local ok, a = pcall(fn)
  vim.o.eventignore = saved
  if not ok then
    error(a, 0)
  end
  return a
end

local function scratch(lines)
  return quiet(function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "rust"
    return buf
  end)
end

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- ------------------------------------------------------------------ lexer

describe("lexer", function()
  local cases = {
    { 'println!("a, b", x)', { "id", "p", "group" } },
    { 'r#"a "quoted" {}"# x', { "str", "id" } },
    { "b'x' 'a 'static '\\n' '\\''", { "lit", "life", "life", "lit", "lit" } },
    { "a /* c /* nested */ */ b // line\n c", { "id", "id", "id" } },
    { "1..2 1.5 x.0", { "lit", "p", "lit", "lit", "id", "p", "lit" } },
    { 'vec![1, "a]b", (2)]', { "id", "p", "group" } },
    { "r#type =>", { "id", "p" } },
  }
  for _, c in ipairs(cases) do
    it("tokens of " .. c[1]:gsub("\n", " "), function()
      local kinds = vim.tbl_map(function(t)
        return t.t
      end, mt.lex(c[1]))
      H.eq(c[2], kinds)
    end)
  end

  it("marks a group that is not closed yet and keeps its tokens", function()
    local toks = mt.lex('vec![1, (2,')
    H.eq(3, #toks)
    local g = toks[3]
    H.ok(g.open)
    H.eq("[", g.d)
    H.ok(g.kids[#g.kids].open, "the inner paren is open too")
  end)

  it("reports 0-based positions and shifts them with row0/col0", function()
    local toks = mt.lex("a\n  bc", { row0 = 10, col0 = 4 })
    H.eq({ 10, 4, 10, 5 }, { toks[1].sr, toks[1].sc, toks[1].er, toks[1].ec })
    H.eq({ 11, 2, 11, 4 }, { toks[2].sr, toks[2].sc, toks[2].er, toks[2].ec })
  end)

  it("string_content drops the quotes and the braces of \\u escapes", function()
    H.eq("a {} b", mt.string_content('"a {} b"'))
    H.eq("x\\u{1F600}y", mt.string_content('r#"x\\u{1F600}y"#'))
    H.eq("xy", mt.string_content('"x\\u{1F600}y"'))
  end)
end)

-- ---------------------------------------------------------- placeholders

describe("format placeholders", function()
  -- { format string, needs (arguments), count, names }
  local cases = {
    { "", 0, 0, {} },
    { "plain", 0, 0, {} },
    { "{}", 1, 1, {} },
    { "{} {}", 2, 2, {} },
    { "{{}} {}", 1, 1, {} },
    { "{{{}}}", 1, 1, {} },
    { "{0} {0} {1}", 2, 3, {} },
    { "{1}", 2, 1, {} },
    { "{x} {y:?}", 0, 2, { "x", "y" } },
    { "{} {name}", 1, 2, { "name" } },
    { "{:>5} {:#?} {:08.3}", 3, 3, {} },
    { "{:.*}", 2, 1, {} },
    { "{:1$}", 2, 1, {} },
    { "{:width$}", 1, 1, { "width" } },
    { "{:.prec$} {}", 2, 2, { "prec" } },
    { "{0:?} {}", 1, 2, {} },
    { "{x:>w$}", 0, 1, { "w", "x" } },
  }
  for _, c in ipairs(cases) do
    it("counts " .. vim.inspect(c[1]), function()
      local info = mt.parse_format(c[1])
      H.ok(info)
      H.eq(c[2], info.needs, "arguments needed")
      H.eq(c[3], info.count, "placeholders")
      local names = vim.tbl_keys(info.names)
      table.sort(names)
      H.eq(c[4], names)
    end)
  end

  it("refuses malformed strings (rustc reports those)", function()
    H.is_nil((mt.parse_format("{")))
    H.is_nil((mt.parse_format("}")))
    H.is_nil((mt.parse_format("a {} }")))
  end)
end)

describe("format and sqlx hints", function()
  -- { source, expected hints as { kind, needs, given } }
  local cases = {
    { 'println!("{} {}", a)', { { "missing", 2, 1 } } },
    { 'println!("{}", a, b)', { { "unused", 1, 2 } } },
    { 'println!("{x} {}", a)', {} },
    { 'println!("{0} {0}", a)', {} },
    { 'println!("{0} {1}", a)', { { "missing", 2, 1 } } },
    { 'println!("{{}}")', {} },
    { 'println!("{}")', { { "missing", 1, 0 } } },
    { 'println!("{x}", x = 1)', {} },
    { 'println!("{}", x = 1)', {} },
    { 'println!("{}", a, y = 1)', { { "unused", 1, 2 } } },
    { 'write!(f, "{} {}", a)', { { "missing", 2, 1 } } },
    { 'writeln!(f, "{}", a)', {} },
    { 'assert!(x > 0, "bad {}")', { { "missing", 1, 0 } } },
    { 'assert_eq!(a, b, "{} {}", c)', { { "missing", 2, 1 } } },
    { 'assert_eq!(a, b)', {} },
    { 'panic!("oops {}")', { { "missing", 1, 0 } } },
    { 'format!("{:.*}", 3)', { { "missing", 2, 1 } } },
    { 'info!(user = 1, "hello {}")', { { "missing", 1, 0 } } },
    { 'tracing::warn!(?x, "n={} m={}", a)', { { "missing", 2, 1 } } },
    { 'info!(target: "x", "ok {}", a)', {} },
    { 'println!("{}", format!("{} {}", a))', { { "missing", 2, 1 } } },
    { 'println!("a {}", vec![1, 2])', {} },
    { 'sqlx::query!("select $1, $2", a)', { { "sql", 2, 1 } } },
    { 'sqlx::query!("select $1, $2", a, b)', {} },
    { 'query_as!(Row, "select ?, ?", a)', { { "sql", 2, 1 } } },
    { 'query_scalar!("select 1")', {} },
    { 'query!("select $1, $1", a)', {} },
    { "query!(\"select 'a?' where x = ?\", a)", {} },
    { 'query!("select 1 -- why?", a)', { { "sql", 0, 1 } } },
    { 'let s = "println!(\\"{}\\")";', {} },
    { 'println!("{}", /* {} */ a)', {} },
  }
  for _, c in ipairs(cases) do
    it(c[1], function()
      local got = vim.tbl_map(function(h)
        return { h.kind, h.needs, h.given }
      end, mt.hints(c[1]))
      H.eq(c[2], got)
    end)
  end

  it("positions: the missing hint covers the format string, the unused one the argument", function()
    local h = mt.hints('fn f() {\n    println!("{} {}", a);\n    println!("{}", a, b);\n}')
    H.eq({ 1, 13, 1, 20 }, { h[1].sr, h[1].sc, h[1].er, h[1].ec })
    H.eq({ 2, 22, 2, 23 }, { h[2].sr, h[2].sc, h[2].er, h[2].ec })
  end)
end)

-- ----------------------------------------------------- hint diagnostics, fix

describe("hint diagnostics and :MacroFormatFix", function()
  it("publishes a hint per problem and updates on refresh", function()
    local buf = scratch({ "fn f() {", '    println!("{} {}", a);', "}" })
    mt.refresh_hints(buf)
    local ds = vim.diagnostic.get(buf, { namespace = mt.ns })
    H.eq(1, #ds)
    H.eq(vim.diagnostic.severity.HINT, ds[1].severity)
    H.eq(1, ds[1].lnum)
    H.match(ds[1].message, "needs 2 arguments, 1 given", true)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '    println!("{} {}", a, b);' })
    mt.refresh_hints(buf)
    H.eq(0, #vim.diagnostic.get(buf, { namespace = mt.ns }))
  end)

  it("adds the missing arguments, with and without a trailing comma", function()
    local buf = scratch({ "fn f() {", '    println!("{} {} {}", a);', '    println!("{} {}", a,);', "}" })
    vim.api.nvim_win_set_cursor(0, { 2, 6 })
    H.eq(2, mt.format_fix(buf))
    H.eq('    println!("{} {} {}", a, todo!(), todo!());', vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1])
    vim.api.nvim_win_set_cursor(0, { 3, 6 })
    H.eq(1, mt.format_fix(buf))
    H.eq('    println!("{} {}", a, todo!(),);', vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
    H.eq(0, #vim.diagnostic.get(buf, { namespace = mt.ns }))
  end)

  it("fixes a call that spans lines", function()
    local buf = scratch({ "fn f() {", "    println!(", '        "{} {}",', "        a", "    );", "}" })
    vim.api.nvim_win_set_cursor(0, { 3, 10 })
    H.eq(1, mt.format_fix(buf))
    H.eq({ "        a, todo!()", "    );" }, vim.api.nvim_buf_get_lines(buf, 3, 5, false))
  end)

  it("does nothing away from a problem", function()
    local buf = scratch({ 'println!("{}", a);' })
    H.eq(0, mt.format_fix(buf))
  end)
end)

-- --------------------------------------------------------------- matcher

local VEC = [[
macro_rules! vec {
    () => ( $crate::vec::Vec::new() );
    ($elem:expr; $n:expr) => ( $crate::vec::from_elem($elem, $n) );
    ($($x:expr),+ $(,)?) => ( <[_]>::into_vec(Box::new([$($x),+])) );
}
#[macro_export]
macro_rules! mix {
    (@one $i:ident) => {};
    ($a:ident => $($rest:tt)*) => {};
    ({ $($k:ident : $v:expr),* }) => {};
    ($vis:vis struct $name:ident;) => {};
    ($t:ty, $l:lifetime, $lit:literal) => {};
}
]]

describe("macro_rules parsing", function()
  it("parses the arms of a definition by name", function()
    local def = mt.parse_macro_def(VEC, nil, nil, "vec")
    H.ok(def)
    H.eq("vec", def.name)
    H.eq(3, #def.arms)
    H.eq({ "", "$elem:expr; $n:expr", "$($x:expr),+ $(,)?" }, vim.tbl_map(function(a)
      return a.matcher
    end, def.arms))
    H.eq("(", def.arms[1].delim)
  end)

  it("finds the definition at a position (the name)", function()
    local def = mt.parse_macro_def(VEC, 6, 14)
    H.eq("mix", def.name)
    H.eq(5, #def.arms)
    H.eq(6, def.row)
    H.is_nil(mt.parse_macro_def(VEC, 5, 3), "an attribute line is not a definition")
  end)

  it("keeps the delimiter of each arm and works for macros inside functions", function()
    local def = mt.parse_macro_def("fn f() {\n    macro_rules! inner { [$a:expr] => {}; }\n}", 1, 20)
    H.eq("inner", def.name)
    H.eq("[", def.arms[1].delim)
  end)

  it("lists the fragments of a matcher once each", function()
    H.eq(
      { { name = "a", spec = "ident" }, { name = "rest", spec = "tt" } },
      mt.fragments("$a:ident => $($rest:tt)* $a:ident")
    )
  end)
end)

describe("arm matching", function()
  local vec = mt.parse_macro_def(VEC, nil, nil, "vec")
  local mix = mt.parse_macro_def(VEC, nil, nil, "mix")

  --- { def, typed arguments (the text after the opening delimiter), arm that must be best (index) or nil, results }
  local cases = {
    { vec, "", 1, { 2, 1, 1 } },
    { vec, "1", 3, { 0, 1, 2 } },
    { vec, "1,", 3, { 0, 0, 2 } },
    { vec, "1, 2, 3", 3, { 0, 0, 2 } },
    { vec, "1, 2, 3,", 3, { 0, 0, 2 } },
    { vec, "0; ", 2, { 0, 1, 0 } },
    { vec, "0; 10", 2, { 0, 2, 0 } },
    { vec, "foo(1, 2), bar", 3, { 0, 0, 2 } },
    { vec, "vec![1, 2]; 3", 2, { 0, 2, 0 } },
    { vec, "1; 2; 3", nil, { 0, 0, 0 } },
    { mix, "@one x", 1, { 2, 0, 0, 0, 0 } },
    { mix, "a => x y z", 2, { 0, 2, 0, 0, 0 } },
    { mix, "a =>", 2, { 0, 2, 0, 0, 0 } },
    { mix, "{ a: 1, b: 2 }", 3, { 0, 0, 2, 0, 0 } },
    { mix, "{ a: 1,", 3, { 0, 0, 1, 0, 0 } },
    { mix, "pub struct Foo;", 4, { 0, 0, 0, 2, 0 } },
    { mix, "struct Foo;", 4, { 0, 0, 0, 2, 0 } },
    { mix, "Vec<u8>, 'a, 5", 5, { 0, 0, 0, 0, 2 } },
    { mix, "HashMap<K, V>, 'a", 5, { 0, 0, 0, 0, 1 } },
    { mix, "u8, 'a, -1", 5, { 0, 0, 0, 0, 2 } },
  }
  for _, c in ipairs(cases) do
    it(("%s! given %q"):format(c[1].name, c[2]), function()
      local toks = mt.lex(c[2])
      local m = mt.match_arms(c[1], toks)
      H.eq(c[4], m.results, "per-arm result")
      H.eq(c[3], m.best, "best arm")
    end)
  end

  it("stays bounded on a pathological matcher", function()
    local def = mt.parse_macro_def("macro_rules! p { ($($a:expr)* $($b:expr)* $($c:expr)*) => {}; }", nil, nil, "p")
    local toks = mt.lex(("a b c d e f g h i j k l m n o p q r s t u v w x y z "):rep(3))
    local t0 = vim.uv.hrtime()
    mt.match_arms(def, toks)
    H.ok((vim.uv.hrtime() - t0) / 1e9 < 2, "matching took too long")
  end)
end)

describe("call context", function()
  --- { text before the cursor, name, innermost, has group, typed tokens }
  local cases = {
    { "let v = vec!", "vec", true, false, 0 },
    { "let v = vec![", "vec", true, true, 0 },
    { "let v = vec![1, 2", "vec", true, true, 3 },
    { "let v = vec![foo(1, ", "vec", false, true, 2 },
    { "fn f() { println!(\"a {}\", bar(", "println", false, true, 4 },
    { "x = tokio::select! {", "select", true, true, 0 },
    { "let a = 1;", nil },
    { "let s = vec![1];\nlet t = foo(", nil },
    { 'let s = "vec![";', nil },
    { "// vec![\nlet z = (", nil },
  }
  for _, c in ipairs(cases) do
    it(vim.inspect(c[1]), function()
      local ctx = mt.context_before(c[1])
      if not c[2] then
        return H.is_nil(ctx)
      end
      H.ok(ctx, "a macro call")
      H.eq(c[2], ctx.name)
      H.eq(c[3], ctx.innermost)
      H.eq(c[4], ctx.group ~= nil)
      H.eq(c[5], ctx.group and #ctx.group.kids or 0)
    end)
  end

  it("reports the path of a qualified macro", function()
    H.eq("tokio", mt.context_before("tokio::select! {").path)
  end)
end)

describe("popup text", function()
  local vec = mt.parse_macro_def(VEC, nil, nil, "vec")

  it("marks the matching arm and explains its fragments", function()
    local view = mt.popup("vec", vec, mt.lex("0; "))
    H.eq("  vec!()", view.lines[1])
    H.eq("> vec!( $elem:expr; $n:expr )", view.lines[2])
    H.eq("  vec!( $($x:expr),+ $(,)? )", view.lines[3])
  end)

  it("lists the fragment legend", function()
    local view = mt.popup("vec", vec, mt.lex("0; "))
    H.has(view.lines, "$elem: expr - an expression")
    H.has(view.lines, "$n: expr - an expression")
  end)

  it("says when no arm fits", function()
    local view = mt.popup("vec", vec, mt.lex("1; 2; 3"))
    H.has(view.lines, "no arm fits the arguments typed so far")
  end)

  it("every fragment kind has an explanation", function()
    for _, k in ipairs({ "expr", "ty", "ident", "path", "pat", "pat_param", "stmt", "block", "item", "meta", "tt", "lifetime", "literal", "vis" }) do
      H.ok(mt.fragment_doc[k], k)
    end
  end)
end)

-- ------------------------------------------------------------- snippets

describe("blink source", function()
  it("registers the provider and offers select!, matches!, vec![x; n]", function()
    local opts = mt.blink_opts(nil, { sources = { default = { "lsp", "path" } } })
    H.eq("config.macro_tools", opts.sources.providers.macro_tools.module)
    H.has(opts.sources.default, "macro_tools")
    mt.blink_opts(nil, opts)
    local n = 0
    for _, s in ipairs(opts.sources.default) do
      n = n + (s == "macro_tools" and 1 or 0)
    end
    H.eq(1, n, "added once")
    scratch({ "fn f() {", "    sel", "}" })
    vim.api.nvim_win_set_cursor(0, { 2, 7 })
    local src = mt.new({})
    H.ok(src:enabled())
    local items
    src:get_completions({ line = "    sel", cursor = { 2, 7 }, bufnr = vim.api.nvim_get_current_buf() }, function(r)
      items = r.items
    end)
    local labels = vim.tbl_map(function(i)
      return i.label
    end, items)
    H.has(labels, "select!")
    H.has(labels, "matches!")
    H.has(labels, "vec![x; n]")
    for _, i in ipairs(items) do
      H.eq(2, i.insertTextFormat, "snippet format")
    end
  end)

  it("never offers anything after a dot", function()
    scratch({ "fn f() {", "    x.sel", "}" })
    vim.api.nvim_win_set_cursor(0, { 2, 9 })
    local items
    mt.new({}):get_completions({ line = "    x.sel", cursor = { 2, 9 }, bufnr = vim.api.nvim_get_current_buf() }, function(r)
      items = r.items
    end)
    H.eq(0, #items)
  end)

  it("every snippet body parses as a snippet", function()
    for _, s in ipairs(mt.snippets) do
      local ok, parsed = pcall(vim.lsp._snippet_grammar.parse, s.text)
      H.ok(ok, s.label .. ": " .. tostring(parsed))
    end
  end)
end)

-- ------------------------------------------------------------- the lens

describe("expansion helpers", function()
  local EXP = [[
const _: () = {
    extern crate serde as _serde;
    #[automatically_derived]
    impl _serde::Serialize for Item {
        fn serialize<__S>(&self, s: __S) -> Result<(), ()> {
            Ok(())
        }
    }
    impl Item {
        fn helper() {}
    }
};
fn main() {}
]]

  it("lists the generated items with their labels and rows", function()
    local items = mt.items_of(EXP)
    local labels = vim.tbl_map(function(i)
      return i.label
    end, items)
    H.eq({ "impl _serde::Serialize for Item", "fn serialize", "impl Item", "fn helper", "fn main" }, labels)
    H.eq(3, items[1].row)
  end)

  it("finds the generated item of a symbol", function()
    local items = mt.items_of(EXP)
    H.eq("fn serialize", mt.find_symbol(items, "serialize").label)
    H.eq("impl _serde::Serialize for Item", mt.find_symbol(items, "Serialize").label)
    H.eq("impl Item", mt.find_symbol(items, "Item").label == "impl _serde::Serialize for Item" and "impl Item" or "x")
    H.is_nil(mt.find_symbol(items, "nope"))
    H.is_nil(mt.find_symbol(items, ""))
  end)

  it("finds the call under a position and the same call in the source", function()
    local src = 'fn a() {\n    one!(1);\n    foo!(vec![1,  2]);\n}\nfn b() {\n    foo!(vec![1, 2]);\n}'
    local call = mt.call_at(src, 2, 12)
    H.eq("vec", call.name, "the inner call wins")
    local same = mt.find_same_call(src, call.key, 5)
    H.eq(5, same.id.sr, "nearest to row 5")
    same = mt.find_same_call(src, call.key, 0)
    H.eq(2, same.id.sr, "nearest to row 0")
    H.is_nil(mt.find_same_call(src, "vec![9]", 0))
    H.is_nil(mt.call_at(src, 0, 0))
  end)

  it("builds the cargo expand command for the file's target", function()
    local member = {
      manifest_path = "/w/p/Cargo.toml",
      targets = {
        { name = "p", kind = { "lib" }, src_path = "/w/p/src/lib.rs" },
        { name = "p", kind = { "bin" }, src_path = "/w/p/src/main.rs" },
      },
    }
    local a = mt.expand_argv(member, "/w/p/src/lib.rs")
    H.eq({ "cargo", "expand", "--color", "never", "--manifest-path", "/w/p/Cargo.toml", "--lib" }, a)
    a = mt.expand_argv(member, "/w/p/src/main.rs")
    H.eq("--bin", a[#a - 1])
    a = mt.expand_argv(member, "/w/p/src/net/mod.rs")
    H.eq({ "--lib", "net" }, { a[#a - 1], a[#a] })
    a = mt.expand_argv(member, "/w/p/src/net/http.rs")
    H.eq("net::http", a[#a])
    local none, why = mt.expand_argv(member, "/elsewhere/x.rs")
    H.is_nil(none)
    H.match(why, "not a target", true)
  end)
end)

-- --------------------------------------------------- proc-macro health

describe("proc-macro status", function()
  local STATUS = [[
Workspaces:
Loaded 57 packages across 1 workspace.
Crates for file 0:
Crate: deps_lab(Crate(Id(580)))
    Is a proc macro crate: false
Crate: serde_derive(Crate(Id(5a9)))
    Is a proc macro crate: true
Configuration:
    procMacro_enable: false,
    procMacro_attributes_enable: true,
]]

  it("reads the crates and the settings of analyzerStatus", function()
    local st = mt.parse_analyzer_status(STATUS)
    H.eq({ { name = "deps_lab", proc_macro = false }, { name = "serde_derive", proc_macro = true } }, st.crates)
    H.eq("false", st.enabled)
    H.eq("true", st.attributes)
  end)

  it("tells which diagnostics are about macros that were not expanded", function()
    local list = {
      { code = "macro-error", message = "proc-macro expansion failed" },
      { code = "proc-macro-disabled", message = "proc macro `tokio::main` not expanded: proc macro attributes are disabled" },
      { code = "E0308", message = "mismatched types" },
      { code = "unresolved-proc-macro", message = "proc macro `Serialize` not expanded" },
      { code = nil, message = "this macro expansion is too deep" },
    }
    local got = mt.macro_diagnostics(list)
    H.eq(4, #got)
    H.eq("E0308", list[3].code)
  end)

  it("names the proc macros a crate exports", function()
    local src = [[
#[proc_macro_derive(Serialize, attributes(serde))]
pub fn derive_serialize(input: TokenStream) -> TokenStream { input }
#[proc_macro_attribute]
pub fn main(args: TokenStream, item: TokenStream) -> TokenStream { item }
#[proc_macro]
pub fn select(input: TokenStream) -> TokenStream { input }
]]
    H.eq({ "Serialize", "main", "select" }, mt.proc_macro_names(src))
  end)

  it("renders the report with its action targets", function()
    local buf = scratch({ "x" })
    local lines, targets = mt.report_lines({
      root = "/w/p",
      crates = {
        { name = "serde_derive", version = "1.0.0", built = true },
        { name = "my_macros", version = "0.1.0", built = false, member = true },
        { name = "slow_macro", version = "2.0.0", built = true },
      },
      ignored = { slow_macro = { "*" } },
      status = { enabled = "false" },
      diags = {
        { bufnr = buf, lnum = 4, col = 0, code = "unresolved-proc-macro", message = "proc macro `serde_derive` not expanded" },
      },
    })
    local text = table.concat(lines, "\n")
    H.match(text, "rust-analyzer.procMacro.enable is false", true)
    H.match(text, "serde_derive%s+1.0.0%s+built%s+1 problem")
    H.match(text, "my_macros%s+0.1.0%s+NOT BUILT%s+%(workspace%)")
    H.match(text, "slow_macro%s+2.0.0%s+ignored")
    H.match(text, ":5  [unresolved-proc-macro]", true)
    H.match(text, "r rebuild proc macros", true)
    local kinds = {}
    for _, t in pairs(targets) do
      kinds[t.kind] = (kinds[t.kind] or 0) + 1
    end
    H.eq({ crate = 3, diag = 1 }, kinds)
  end)

  -- { existing file text, crate, names, expected text | nil, expected error }
  local TOML = {
    { "", "slow-macro", { "slow_macro" }, '[procMacro.ignored]\n"slow-macro" = ["slow_macro"]\n' },
    { "", "x", nil, '[procMacro.ignored]\n"x" = ["*"]\n', nil },
    {
      '[cargo]\nfeatures = "all"\n',
      "a",
      { "A", "b" },
      '[cargo]\nfeatures = "all"\n\n[procMacro.ignored]\n"a" = ["A", "b"]\n',
    },
    {
      '[procMacro.ignored]\n"a" = ["x"]\n\n[cargo]\nfeatures = "all"\n',
      "b",
      { "y" },
      '[procMacro.ignored]\n"a" = ["x"]\n"b" = ["y"]\n\n[cargo]\nfeatures = "all"\n',
    },
    {
      '[procMacro.ignored]\na = ["x"]\n',
      "a",
      { "z" },
      '[procMacro.ignored]\n"a" = ["z"]\n',
    },
    {
      '[procMacro.ignored] # slow ones\n"foo" = ["a"]\n',
      "serde_derive",
      { "Serialize" },
      '[procMacro.ignored] # slow ones\n"foo" = ["a"]\n"serde_derive" = ["Serialize"]\n',
    },
    {
      '[procMacro.ignored]\n"serde_derive" = [\n  "Serialize",\n  "Deserialize",\n]\n"x" = ["y"]\n',
      "serde_derive",
      { "Serialize" },
      '[procMacro.ignored]\n"serde_derive" = ["Serialize"]\n"x" = ["y"]\n',
    },
    { 'procMacro.ignored.a = ["x"]\n', "b", nil, nil, "by hand" },
    { '[procMacro]\nignored = { a = ["x"] }\n', "b", nil, nil, "by hand" },
  }
  for i, c in ipairs(TOML) do
    it("edits rust-analyzer.toml, case " .. i, function()
      local new, why = mt.toml_ignore(c[1], c[2], c[3])
      if c[4] then
        H.eq(c[4], new)
      else
        H.is_nil(new)
        H.match(why, c[5], true)
      end
    end)
  end

  it("writes procMacro.ignored into the project's rust-analyzer.toml", function()
    local dir = H.tmpdir()
    local path = H.ok(mt.ignore_proc_macro(dir, "slow-macro", { "slow_macro" }))
    H.eq(dir .. "/rust-analyzer.toml", path)
    H.eq('[procMacro.ignored]\n"slow-macro" = ["slow_macro"]\n', read(path))
    H.ok(mt.ignore_proc_macro(dir, "b", nil))
    H.eq('[procMacro.ignored]\n"slow-macro" = ["slow_macro"]\n"b" = ["*"]\n', read(path))
  end)

  it("uses .rust-analyzer.toml when that is the file the project has", function()
    local dir = H.tmpdir()
    local f = assert(io.open(dir .. "/.rust-analyzer.toml", "w"))
    f:write('[cargo]\nfeatures = "all"\n')
    f:close()
    local path = H.ok(mt.ignore_proc_macro(dir, "a", { "a" }))
    H.eq(dir .. "/.rust-analyzer.toml", path)
    H.is_nil(vim.uv.fs_stat(dir .. "/rust-analyzer.toml"))
  end)

  it("refuses odd crate names and an unreadable form, leaving the file alone", function()
    local dir = H.tmpdir()
    local ok, err = mt.ignore_proc_macro(dir, "a/../b", nil)
    H.is_nil(ok)
    H.match(err, "odd crate name", true)
    H.is_nil(vim.uv.fs_stat(dir .. "/rust-analyzer.toml"))
    local f = assert(io.open(dir .. "/rust-analyzer.toml", "w"))
    f:write('procMacro.ignored.a = ["x"]\n')
    f:close()
    ok, err = mt.ignore_proc_macro(dir, "b", nil)
    H.is_nil(ok)
    H.match(err, "by hand", true)
    H.eq('procMacro.ignored.a = ["x"]\n', read(dir .. "/rust-analyzer.toml"))
  end)
end)

-- ----------------------------------------------------- real rust-analyzer

local USER_MACROS = [[

macro_rules! pair {
    ($a:expr, $b:expr) => { ($a, $b) };
    ($a:expr; $n:expr) => { [$a; $n] };
}

fn lab_extra() {
    let p = pair!(1, 2);
    let v = vec![1, 2, 3];
    println!("{} {:?}", p.0, vec![4]);
}
]]

--- Open a copy of deps-lab with the user macros appended; wait for
--- rust-analyzer to answer expandMacro for `println!`.
local function open_lab()
  H.need_rust()
  local dir, buf = H.open_fixture("deps-lab", "src/main.rs")
  local f = assert(io.open(dir .. "/src/main.rs", "a"))
  f:write(USER_MACROS)
  f:close()
  vim.cmd("edit!")
  buf = vim.api.nvim_get_current_buf()
  H.very_lazy()
  H.wait_lsp("rust-analyzer", buf)
  return dir, buf
end

local function find(buf, pat)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local s = l:find(pat, 1, true)
    if s then
      return i - 1, s - 1
    end
  end
  error("pattern not found: " .. pat)
end

--- Expand at (row, col) once rust-analyzer has loaded the workspace.
local function expand_when_ready(buf, row, col, timeout)
  local name, text
  local ok, err = pcall(H.wait_for, function()
    local done
    name, text = nil, nil
    mt.request_expand(buf, row, col, function(n, t)
      name, text, done = n, t, true
    end)
    vim.wait(5000, function()
      return done
    end, 20)
    -- "proc-macro not yet built": rust-analyzer is still building them
    return name
  end, timeout or 120000, "rust-analyzer expandMacro")
  if not ok then
    error(err .. " (last answer: " .. tostring(text) .. ")", 0)
  end
  return name, text
end

--- find_definition until rust-analyzer resolves it (not the built-in table).
local function definition_when_ready(buf, row, col, name)
  local def, where
  H.wait_for(function()
    local done
    def, where = nil, nil
    mt.find_definition(buf, row, col, name, function(d, w)
      def, where, done = d, w, true
    end)
    vim.wait(5000, function()
      return done
    end, 20)
    return def and where ~= "built-in table"
  end, 60000, "definition of " .. name .. " (last: " .. tostring(where) .. ")")
  return def, where
end

describe("live rust-analyzer", function()
  it("expands println!, a derive and #[tokio::main]", function()
    local _, buf = open_lab()
    local row, col = find(buf, 'println!("{} {:?}"')
    local name, text = expand_when_ready(buf, row, col + 2)
    H.eq("println!", name)
    H.match(text, "format_args_nl!", true)

    row, col = find(buf, "Serialize, Deserialize")
    name, text = expand_when_ready(buf, row, col + 2)
    H.eq("Serialize", name)
    H.match(text, "impl _serde::Serialize for Item", true)

    row, col = find(buf, "tokio::main")
    name, text = expand_when_ready(buf, row, col + 8)
    H.eq("main", name)
    H.match(text, "block_on", true)
  end)

  it(":MacroExpand opens a read-only rust split with the line count", function()
    local _, buf = open_lab()
    local row, col = find(buf, "pair!(1, 2)")
    expand_when_ready(buf, row, col + 1)
    vim.api.nvim_win_set_cursor(0, { row + 1, col + 1 })
    local cap = H.capture_notify()
    vim.cmd("MacroExpand")
    H.wait_for(function()
      return vim.bo.buftype == "nofile" and vim.bo.filetype == "rust"
    end, 20000, "the expansion window")
    local lens = vim.api.nvim_get_current_buf()
    H.ok(lens ~= buf)
    H.eq({ "(1, 2)" }, vim.api.nvim_buf_get_lines(lens, 0, -1, false), vim.inspect(cap.list))
    H.not_ok(vim.bo[lens].modifiable)
    H.match(vim.wo.winbar, "pair!", true)
    H.match(vim.wo.winbar, "expanded to 1 line", true)
    H.eq(0, #vim.lsp.get_clients({ bufnr = lens }), "no language server attached to the scratch buffer")
    vim.cmd("normal q")
    H.eq(buf, vim.api.nvim_get_current_buf())
  end)

  it("steps into a nested call and back, with a breadcrumb", function()
    local _, buf = open_lab()
    local row, col = find(buf, 'println!("{} {:?}"')
    expand_when_ready(buf, row, col + 2)
    vim.api.nvim_win_set_cursor(0, { row + 1, col + 2 })
    vim.cmd("MacroExpand")
    H.wait_for(function()
      return vim.bo.buftype == "nofile"
    end, 20000, "the expansion window")
    local lens = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(lens, 0, -1, false)
    local lrow
    for i, l in ipairs(lines) do
      if l:find("vec![4]", 1, true) then
        lrow = i
      end
    end
    H.ok(lrow, "the nested vec! is in the expansion: " .. table.concat(lines, "|"))
    vim.api.nvim_win_set_cursor(0, { lrow, (lines[lrow]:find("vec!", 1, true)) })
    mt.lens_step()
    H.wait_for(function()
      return vim.wo.winbar:find("println! > vec!", 1, true)
    end, 20000, "the breadcrumb")
    H.match(table.concat(vim.api.nvim_buf_get_lines(lens, 0, -1, false), "\n"), "box_assume_init_into_vec_unsafe", true)
    mt.lens_back()
    H.match(table.concat(vim.api.nvim_buf_get_lines(lens, 0, -1, false), "\n"), "format_args_nl", true)
    H.not_ok(vim.wo.winbar:find("println! > vec!", 1, true))
  end)

  it("a derive: lists the generated items and jumps to the cursor symbol", function()
    local _, buf = open_lab()
    local drow, dcol = find(buf, "Serialize, Deserialize")
    expand_when_ready(buf, drow, dcol + 2) -- warm: proc macros are built
    local row, col = find(buf, "struct Item")
    vim.api.nvim_win_set_cursor(0, { row + 1, col + 7 })
    vim.cmd("MacroExpand")
    H.wait_for(function()
      return vim.bo.buftype == "nofile"
    end, 30000, "the expansion window")
    local lens = vim.api.nvim_get_current_buf()
    local text = table.concat(vim.api.nvim_buf_get_lines(lens, 0, -1, false), "\n")
    H.match(text, "// ---- derive(Serialize)", true)
    H.match(text, "// ---- derive(Deserialize)", true)
    local labels = vim.tbl_map(function(i)
      return i.label
    end, mt.items_of(text))
    H.has(labels, "impl _serde::Serialize for Item")
    H.match(vim.wo.winbar, "items:", true)
    H.ok(#mt.item_macro_positions(buf, row, col + 7) >= 2, "positions of both derives")
  end)

  it("macro signature: the popup of a user macro_rules! highlights the arm that fits", function()
    local _, buf = open_lab()
    local row, col = find(buf, "pair!(1, 2)")
    expand_when_ready(buf, row, col + 1) -- rust-analyzer is ready
    local def, where = definition_when_ready(buf, row, col + 3, "pair")
    H.ok(def, tostring(where))
    H.eq(2, #def.arms)
    H.match(where, "main.rs:", true)
    local view = mt.popup("pair", def, mt.lex("1; "))
    H.match(view.lines[1], "pair!( $a:expr, $b:expr )", true)
    H.match(view.lines[2], "^> pair!%( %$a:expr; %$n:expr %)")
  end)

  it("macro signature: vec! is found in the standard library and its arms are shown", function()
    local _, buf = open_lab()
    local row, col = find(buf, "vec![1, 2, 3]")
    expand_when_ready(buf, row, col + 1)
    local def, where = definition_when_ready(buf, row, col + 1, "vec")
    H.ok(def, tostring(where))
    H.eq("vec", def.name)
    H.ok(#def.arms >= 3)
    local m = mt.match_arms(def, mt.lex("1, 2"))
    H.ok(m.best and def.arms[m.best].matcher:find("%$x:expr"))
  end)

  it("the popup follows the typed arguments of vec![ and closes again", function()
    local _, buf = open_lab()
    local row, col = find(buf, "let v = vec![1, 2, 3];")
    expand_when_ready(buf, row, col + 9)
    definition_when_ready(buf, row, col + 9, "vec")
    vim.api.nvim_buf_set_lines(buf, row + 1, row + 1, false, { "    let w = vec![" })
    vim.api.nvim_win_set_cursor(0, { row + 2, #"    let w = vec![" })
    local function popup_text()
      local w = mt.popup_win()
      return w and table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
    end
    mt.signature(buf, { manual = true })
    local text = H.wait_for(popup_text, 20000, "the macro popup")
    H.match(text, "$elem:expr", true)
    H.match(text, "$n: expr - an expression", true)
    H.match(text, "\n> vec!()", true, "empty arguments: the empty arm") -- the () arm is the first complete one
    -- typing on: the arm with `;` fits, then the list arm
    vim.api.nvim_buf_set_lines(buf, row + 1, row + 2, false, { "    let w = vec![0; " })
    vim.api.nvim_win_set_cursor(0, { row + 2, #"    let w = vec![0; " })
    mt.signature(buf)
    H.wait_for(function()
      local t = popup_text()
      return t and t:find("> vec!( $elem:expr; $n:expr )", 1, true)
    end, 10000, "the elem; n arm to be marked")
    vim.api.nvim_buf_set_lines(buf, row + 1, row + 2, false, { "    let w = vec![0, 1" })
    vim.api.nvim_win_set_cursor(0, { row + 2, #"    let w = vec![0, 1" })
    mt.signature(buf)
    H.wait_for(function()
      local t = popup_text()
      return t and t:find("> vec!( $($x:expr),+ $(,)? )", 1, true)
    end, 10000, "the list arm to be marked")
    vim.api.nvim_buf_set_lines(buf, row + 1, row + 2, false, { "    let w = vec![0, 1];" })
    vim.api.nvim_win_set_cursor(0, { row + 2, #"    let w = vec![0, 1];" })
    mt.signature(buf)
    H.is_nil(popup_text(), "closed after the call")
  end)

  it("hint diagnostics follow the edits of a real rust buffer", function()
    local _, buf = open_lab()
    local n = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, n, n, false, { "fn hints() {", '    println!("{} {}", 1);', "}" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    H.wait_for(function()
      return #vim.diagnostic.get(buf, { namespace = mt.ns }) == 1
    end, 10000, "the format hint")
    local d = vim.diagnostic.get(buf, { namespace = mt.ns })[1]
    H.eq(n + 1, d.lnum)
    H.match(d.message, "needs 2 arguments, 1 given", true)
    vim.api.nvim_win_set_cursor(0, { n + 2, 6 })
    vim.cmd("MacroFormatFix")
    H.eq('    println!("{} {}", 1, todo!());', vim.api.nvim_buf_get_lines(buf, n + 1, n + 2, false)[1])
  end)

  it("falls back to cargo expand, labelled, where rust-analyzer expands nothing", function()
    if vim.fn.executable("cargo-expand") ~= 1 then
      H.skip_file("cargo-expand is not installed")
    end
    local _, buf = open_lab()
    local row, col = find(buf, "macro_rules! pair")
    local drow, dcol = find(buf, "Serialize, Deserialize")
    expand_when_ready(buf, drow, dcol + 2)
    vim.api.nvim_win_set_cursor(0, { row + 1, col + 14 })
    vim.cmd("MacroExpand")
    H.wait_for(function()
      return vim.bo.buftype == "nofile" and vim.bo.filetype == "rust"
    end, 120000, "the cargo expand window")
    H.match(vim.wo.winbar, "FALLBACK (cargo expand", true)
    H.match(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"), "fn lab_extra", true)
  end)

  it("does not run cargo expand for a cursor that is not on a macro", function()
    local _, buf = open_lab()
    local drow, dcol = find(buf, "Serialize, Deserialize")
    expand_when_ready(buf, drow, dcol + 2)
    local row, col = find(buf, "fn lab_extra")
    vim.api.nvim_win_set_cursor(0, { row + 1, col + 3 })
    local cap = H.capture_notify()
    vim.cmd("MacroExpand")
    H.wait_for(function()
      for _, n in ipairs(cap.list) do
        if n.msg:find("no macro call, derive or attribute", 1, true) then
          return true
        end
      end
    end, 20000, "the no-macro message")
    H.not_ok(vim.bo.buftype == "nofile")
  end)

  it(":MacroExpand on a literal inside the arguments expands that call, not the crate", function()
    local _, buf = open_lab()
    local row, col = find(buf, "pair!(1, 2)")
    expand_when_ready(buf, row, col + 1)
    vim.api.nvim_win_set_cursor(0, { row + 1, col + 6 }) -- the `1`
    vim.cmd("MacroExpand")
    H.wait_for(function()
      return vim.bo.buftype == "nofile" and vim.bo.filetype == "rust"
    end, 20000, "the expansion window")
    H.eq({ "(1, 2)" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    H.match(vim.wo.winbar, "pair!", true)
  end)

  it("<C-k> and the other keys are buffer-local on a rust-analyzer buffer", function()
    local _, buf = open_lab()
    H.wait_for(function()
      local m = vim.fn.maparg("<C-k>", "i", false, true)
      return m.buffer == 1 and (m.desc or ""):find("Macro", 1, true)
    end, 10000, "the buffer-local <C-k>")
  end)

  it("keys and commands are registered and avoid the taken ones", function()
    local _, buf = open_lab()
    for _, c in ipairs({ "MacroExpand", "MacroFormatFix", "MacroSignature", "ProcMacroStatus" }) do
      H.eq(2, vim.fn.exists(":" .. c), c)
    end
    H.wait_for(function()
      return vim.fn.maparg("<leader>rx", "n", false, true).buffer == 1
    end, 10000, "<leader>rx")
    H.eq("Expand macro under cursor (lens)", vim.fn.maparg("<leader>rx", "n", false, true).desc)
    H.eq("Proc-macro status", vim.fn.maparg("<leader>rq", "n", false, true).desc)
    H.eq("Expand macro (recursive)", vim.fn.maparg("<leader>rm", "n", false, true).desc, "<leader>rm is untouched")
    H.eq("Macro / signature help", vim.fn.maparg("<C-k>", "i", false, true).desc)
  end)

  it(":ProcMacroStatus lists the workspace proc-macro crates and writes the ignore setting", function()
    local dir, buf = open_lab()
    local cm = require("config.crate_meta")
    local meta = cm.metadata(dir)
    if not meta then
      H.skip_file("cargo metadata failed (registry not populated?)")
    end
    local crates = mt.proc_macro_crates(meta, dir .. "/target")
    local names = vim.tbl_map(function(c)
      return c.name
    end, crates)
    H.has(names, "serde_derive")
    H.has(names, "thiserror-impl")
    H.has(names, "tokio-macros")
    local row, col = find(buf, "tokio::main")
    expand_when_ready(buf, row, col + 8)
    vim.cmd("ProcMacroStatus")
    H.wait_for(function()
      return vim.api.nvim_buf_get_name(0):find("proc%-macro%-status")
    end, 30000, "the status buffer")
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    H.match(text, "serde_derive", true)
    H.match(text, "Macros not expanded", true)
    H.match(text, "rust-analyzer", true)
    vim.cmd("normal q")
    -- the ignore action writes the project setting
    H.ok(mt.ignore_proc_macro(dir, "tokio-macros", { "main", "test" }))
    H.eq('[procMacro.ignored]\n"tokio-macros" = ["main", "test"]\n', read(dir .. "/rust-analyzer.toml"))
    -- rust-analyzer reads that file itself: its config dump shows the setting
    local client = H.clients(buf, "rust-analyzer")[1]
    local status
    H.wait_for(function()
      local r = client:request_sync("rust-analyzer/analyzerStatus", { textDocument = vim.lsp.util.make_text_document_params(buf) }, 20000, buf)
      status = r and r.result
      return status and status:find("procMacro_ignored", 1, true)
    end, 60000, "procMacro_ignored in rust-analyzer's config (rust-analyzer.toml)")
  end)
end)
