-- config.crate_add: the unknown-crate hint (treesitter scan, diagnostics, the
-- code action served by the in-process server) and :CrateAdd (search ->
-- features -> target -> cargo add argv).
-- Hermetic: path-only temp workspaces (cargo metadata needs no registry),
-- stubbed pickers, crates.io client and `cargo add`. One test runs the whole
-- flow for real (crates.io + cargo add itoa on a copy of the deps-lab fixture,
-- then cargo check) and skips without network or cargo.
local H = require("xynotest.helpers")
local cm = require("config.crate_meta")
local ca = require("config.crate_add")

local restores = {}
local function stub(t, k, v)
  local orig = t[k]
  t[k] = v
  restores[#restores + 1] = function()
    t[k] = orig
  end
  return orig
end

after_each(function()
  for i = #restores, 1, -1 do
    pcall(restores[i])
  end
  restores = {}
  cm.invalidate()
  pcall(vim.cmd, "silent! %bwipeout!")
  vim.diagnostic.reset(ca.ns)
end)

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function read(path)
  local f = assert(io.open(path, "r"))
  local t = f:read("*a")
  f:close()
  return t
end

local function pkg(root, name, deps)
  write(
    ("%s/%s/Cargo.toml"):format(root, name),
    ('[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n%s'):format(name, deps or "")
  )
end

--- app (bin + lib "app") with a path dependency, a renamed one and a
--- dev-dependency; plus those crates as members.
local function make_ws()
  local root = H.tmpdir() .. "/ws"
  write(root .. "/Cargo.toml", '[workspace]\nmembers = ["app", "localdep", "devdep", "other"]\nresolver = "2"\n')
  for _, n in ipairs({ "localdep", "devdep", "other" }) do
    pkg(root, n)
    write(("%s/%s/src/lib.rs"):format(root, n), "pub fn f() {}\n")
  end
  pkg(
    root,
    "app",
    '\n[dependencies]\nlocaldep = { path = "../localdep" }\nren = { package = "other", path = "../other" }\n\n[dev-dependencies]\ndevdep = { path = "../devdep" }\n'
  )
  write(root .. "/app/src/lib.rs", "pub fn thing() {}\n")
  write(root .. "/app/src/main.rs", "fn main() {}\n")
  write(root .. "/app/src/inner.rs", "pub fn f() {}\n")
  return root
end

--- Write `text` to app/src/main.rs, load it into a buffer and scan it.
--- Returns the list of "name@line" strings (1-based line).
local function scan(root, text, rel)
  local file = root .. "/app/" .. (rel or "src/main.rs")
  write(file, text)
  local meta, err = cm.metadata(root)
  H.ok(meta, err)
  vim.cmd.edit(vim.fn.fnameescape(file))
  local hits = ca.scan(vim.api.nvim_get_current_buf(), meta)
  if not hits then
    return nil
  end
  return vim.tbl_map(function(h)
    return ("%s@%d"):format(h.name, h.lnum + 1)
  end, hits)
end

-- ------------------------------------------------------------------ scan

describe("crate_add.scan: what is flagged", function()
  it("flags unknown heads of use paths, expression paths, types and attributes", function()
    local root = make_ws()
    H.eq(
      { "rand@1", "serde_json@2", "chrono@4", "tokio@5", "tokio@7" },
      scan(
        root,
        table.concat({
          "use rand::Rng;",
          "use {serde_json::Value, localdep::f};",
          "fn main() {",
          "    let d: chrono::Utc = x;",
          "    #[tokio::main]",
          "    fn a() {}",
          "    let m = tokio::spawn(1);",
          "}",
        }, "\n")
      )
    )
  end)

  it("flags the head of a nested use list and of a wildcard use", function()
    local root = make_ws()
    H.eq({ "alpha@1", "beta@2" }, scan(root, "use alpha::{a, b::c};\nuse beta::x;\nfn main() {}\n"))
    H.eq({}, scan(root, "use alpha::{b::*};\nfn main() { rand::random::<u8>(); }\n"), "a glob of an unknown crate may bring any name")
  end)

  it("reports the exact head range", function()
    local root = make_ws()
    local file = root .. "/app/src/main.rs"
    write(file, "fn main() { let x = rand::random::<u8>(); }\n")
    local meta = cm.metadata(root)
    vim.cmd.edit(vim.fn.fnameescape(file))
    local hits = ca.scan(vim.api.nvim_get_current_buf(), meta)
    H.eq({ name = "rand", lnum = 0, col = 20, end_col = 24 }, hits[1])
  end)
end)

describe("crate_add.scan: what is never flagged", function()
  it("keeps quiet about std, dependencies, renames, dev-dependencies, own crate, modules, imports, generics", function()
    local root = make_ws()
    local text = table.concat({
      "use std::io;",
      "use core::fmt;",
      "use localdep::f;",
      "use ren::f as g;", -- a rename is a dependency by its alias
      "use devdep::f as h;", -- a dev-dependency
      "use app::thing;", -- own lib name
      "use io as myio;",
      "extern crate alpha as beta;",
      "mod inner;",
      "struct S;",
      "enum Color { Red }",
      "macro_rules! m { () => { $crate::foo::bar(); other::x(); } }",
      "fn g<t>() {",
      "    t::default();",
      "    io::stdin();",
      "    inner::f();",
      "    let _ = Color::Red;",
      "    beta::x();",
      "    myio::stdout();",
      "    core::mem::drop(1);",
      "    let _ = u32::MAX;",
      "    let _ = S::new();",
      "    println!(\"{}\", rand::random::<u8>());", -- macro arguments are tokens, not paths
      "}",
      "#[rustfmt::skip]",
      "#[cfg(test)]",
      "mod tests {",
      "    use super::*;",
      "    use devdep::f;",
      "    fn t() { devdep::f(); }",
      "}",
    }, "\n")
    H.eq({}, scan(root, text))
  end)

  it("keeps quiet in files that glob-import from the own crate or another file", function()
    local root = make_ws()
    H.eq({}, scan(root, "use crate::prelude::*;\nfn main() { rand::random::<u8>(); }\n"))
    H.eq({}, scan(root, "use super::*;\nfn t() { rand::random::<u8>(); }\n"), "super:: at file level reaches another file")
  end)

  it("keeps flagging when the glob is std, a dependency, an enum or super inside an inline mod", function()
    local root = make_ws()
    H.eq({ "rand@3" }, scan(root, "use std::collections::*;\nuse localdep::*;\nfn main() { rand::random::<u8>(); }\n"))
    H.eq({ "rand@3" }, scan(root, "mod t {\n    use super::*;\n    fn f() { rand::random::<u8>(); }\n}\n"))
  end)

  it("skips edition 2015 packages, non-rust and dependency-source files", function()
    local root = make_ws()
    write(root .. "/app/Cargo.toml", (read(root .. "/app/Cargo.toml"):gsub('edition = "2021"', 'edition = "2015"')))
    cm.invalidate()
    H.is_nil(scan(root, "fn main() { rand::random::<u8>(); }\n"))
    H.not_ok(ca.applicable_file("/home/u/.cargo/registry/src/x/serde-1/src/lib.rs"))
    H.not_ok(ca.applicable_file("/p/target/debug/build/x/out.rs"))
    H.not_ok(ca.applicable_file("/p/Cargo.toml"))
    H.ok(ca.applicable_file("/p/src/main.rs"))
  end)

  it("does not apply to a file outside every member", function()
    local root = make_ws()
    local meta = cm.metadata(root)
    write(root .. "/loose.rs", "fn main() { rand::random::<u8>(); }\n")
    vim.cmd.edit(vim.fn.fnameescape(root .. "/loose.rs"))
    H.is_nil(ca.scan(vim.api.nvim_get_current_buf(), meta))
  end)
end)

-- ------------------------------------------------------------- build_argv

describe("crate_add.build_argv", function()
  it("builds the argv for each target and flag", function()
    H.eq({ "cargo", "add", "itoa" }, ca.build_argv({ name = "itoa" }))
    H.eq({ "cargo", "add", "itoa", "-p", "app", "--dev" }, ca.build_argv({ name = "itoa", package = "app", kind = "dev" }))
    H.eq({ "cargo", "add", "itoa", "--build" }, ca.build_argv({ name = "itoa", kind = "build" }))
    H.eq(
      { "cargo", "add", "serde", "--no-default-features", "-F", "derive,std", "--offline" },
      ca.build_argv({ name = "serde", default_features = false, features = { "derive", "std" }, offline = true })
    )
  end)

  it("refuses names, packages, features and kinds a shell or a path could misread", function()
    for _, bad in ipairs({ "a;b", "a b", "../x", "$(x)", "", "a\nb", "--git", "-p" }) do
      local argv, err = ca.build_argv({ name = bad })
      H.is_nil(argv, bad)
      H.ok(err)
    end
    H.is_nil(ca.build_argv({ name = "ok", package = "a b" }))
    H.is_nil(ca.build_argv({ name = "ok", features = { "x;rm" } }))
    H.is_nil(ca.build_argv({ name = "ok", features = { "a b" } }))
    H.is_nil(ca.build_argv({ name = "ok", kind = "evil" }))
  end)
end)

-- ------------------------------------------------------------ the flow

--- cargo add stub: records the argv, optionally edits the manifest, answers ok.
local function fake_cargo(on_add)
  local calls = {}
  local orig
  orig = stub(cm, "exec", function(argv, opts, cb)
    if argv[1] == "cargo" and argv[2] == "add" then
      calls[#calls + 1] = { argv = argv, cwd = opts and opts.cwd }
      local r = on_add and on_add(argv) or { code = 0, stdout = "", stderr = "    Adding x\n" }
      return vim.schedule(function()
        cb(r)
      end)
    end
    return orig(argv, opts, cb)
  end)
  return calls
end

local function fake_registry(opts)
  opts = opts or {}
  stub(cm, "search_async", function(q, cb)
    vim.schedule(function()
      if opts.search_err then
        return cb(nil, opts.search_err)
      end
      local list = { stale = opts.stale, from_cache = opts.stale or opts.from_cache }
      list[1] = { name = "itoa", version = "1.0.15", downloads = 123456789, description = "Fast integer to string conversion" }
      list[2] = { name = "itoap", version = "1.0.0", downloads = 5, description = "other" }
      cb(list)
    end)
  end)
  stub(cm, "info_async", function(name, cb)
    vim.schedule(function()
      if opts.info_err then
        return cb(nil, opts.info_err)
      end
      cb({
        name = name,
        newest = "1.0.15",
        features = { default = { "std" }, std = {}, alloc = { "dep:hashbrown" }, ["no-panic"] = { "dep:no-panic" } },
      })
    end)
  end)
end

--- Script the pickers. `plan` = { features = {names} | nil (default only),
--- member = name, kind = "normal"|"dev"|"build" }. Records every picker spec.
local function script_ui(plan)
  local seen = {}
  stub(ca.ui, "pick", function(spec, cb)
    seen[#seen + 1] = spec
    local sel = {}
    if spec.title:find("^crates.io") then
      sel = { spec.items[1] }
    elseif spec.title:find("^Features") then
      for _, want in ipairs(plan.features or { "default" }) do
        for _, it in ipairs(spec.items) do
          if it.feature == want then
            sel[#sel + 1] = it
          end
        end
      end
    else
      for _, it in ipairs(spec.items) do
        if (not plan.member or it.member.name == plan.member) and it.kind == (plan.kind or "normal") then
          sel = { it }
          break
        end
      end
    end
    cb(sel)
  end)
  return seen
end

local function run_add(query)
  local done, ok, msg
  ca.add(query, function(a, b)
    done, ok, msg = true, a, b
  end)
  H.wait_for(function()
    return done
  end, 15000, "the add flow")
  return ok, msg
end

--- Two members, a [workspace.dependencies] with itoa, the buffer is app's.
local function make_flow_ws()
  local root = H.tmpdir() .. "/flow"
  write(root .. "/Cargo.toml", '[workspace]\nmembers = ["app", "lib2"]\nresolver = "2"\n\n[workspace.dependencies]\nitoa = "1"\n')
  pkg(root, "app", "\n[dependencies]\n")
  pkg(root, "lib2")
  write(root .. "/app/src/main.rs", "fn main() {}\n")
  write(root .. "/lib2/src/lib.rs", "")
  vim.cmd.edit(vim.fn.fnameescape(root .. "/app/src/main.rs"))
  return root
end

describe("crate_add :CrateAdd flow (stubbed crates.io and cargo)", function()
  it("shows name, version, downloads and description; features with their dependency lists", function()
    make_flow_ws()
    fake_registry()
    fake_cargo()
    local seen = script_ui({})
    H.ok(run_add("itoa"))
    H.match(seen[1].items[1].display, "itoa", true)
    H.match(seen[1].items[1].display, "1.0.15", true)
    H.match(seen[1].items[1].display, "123.5M", true)
    H.match(seen[1].items[1].display, "Fast integer", true)
    local by = {}
    for _, it in ipairs(seen[2].items) do
      by[it.feature] = it
    end
    H.eq("default", seen[2].items[1].feature, "default is listed first")
    H.ok(seen[2].items[1].preselect, "and preselected")
    H.match(by.alloc.display, "dep:hashbrown", true)
    H.match(by.std.display, "no dependencies", true)
    H.ok(seen[2].multi)
  end)

  it("produces the right cargo add argv for each target choice", function()
    local root = make_flow_ws()
    fake_registry()
    local calls = fake_cargo()
    local cases = {
      { { member = "app", kind = "normal" }, { "cargo", "add", "itoa", "-p", "app" } },
      { { member = "app", kind = "dev", features = { "default", "alloc" } }, { "cargo", "add", "itoa", "-p", "app", "--dev", "-F", "alloc" } },
      { { member = "lib2", kind = "build", features = { "std", "alloc" } }, { "cargo", "add", "itoa", "-p", "lib2", "--build", "--no-default-features", "-F", "std,alloc" } },
      { { member = "lib2", kind = "normal", features = { "no-panic" } }, { "cargo", "add", "itoa", "-p", "lib2", "--no-default-features", "-F", "no-panic" } },
    }
    for i, c in ipairs(cases) do
      script_ui(c[1])
      H.ok(run_add("itoa"), "case " .. i)
      H.eq(c[2], calls[i].argv, "case " .. i)
      H.eq(root, calls[i].cwd, "cargo runs in the workspace root")
    end
  end)

  it("offers every member and kind, marks what [workspace.dependencies] already has", function()
    make_flow_ws()
    fake_registry()
    fake_cargo()
    local seen = script_ui({})
    H.ok(run_add("itoa"))
    local items = seen[3].items
    H.eq(6, #items, "2 members x 3 kinds")
    H.match(items[1].display, "app", true, "the member of the buffer comes first")
    H.match(items[1].display, "[dependencies]", true)
    H.match(items[1].display, "[workspace.dependencies]", true)
    H.no_match(items[2].display, "workspace.dependencies", true)
  end)

  it("a single-package workspace has no member prefix", function()
    local root = H.tmpdir() .. "/solo"
    write(root .. "/Cargo.toml", '[package]\nname = "solo"\nversion = "0.1.0"\nedition = "2021"\n')
    write(root .. "/src/main.rs", "fn main() {}\n")
    vim.cmd.edit(vim.fn.fnameescape(root .. "/src/main.rs"))
    fake_registry()
    local calls = fake_cargo()
    local seen = script_ui({ kind = "dev" })
    H.ok(run_add("itoa"))
    H.eq(3, #seen[3].items)
    H.eq("[dependencies]", seen[3].items[1].text)
    H.eq({ "cargo", "add", "itoa", "-p", "solo", "--dev" }, calls[1].argv)
  end)

  it("reports the line cargo wrote and refreshes", function()
    local root = make_flow_ws()
    fake_registry()
    fake_cargo(function()
      write(root .. "/app/Cargo.toml", read(root .. "/app/Cargo.toml") .. 'itoa = "1.0.15"\n')
      return { code = 0, stdout = "", stderr = "" }
    end)
    script_ui({})
    local cap = H.capture_notify()
    local ok, msg = run_add("itoa")
    H.ok(ok)
    H.match(msg, 'itoa = "1.0.15"', true)
    H.match(msg, "[dependencies]", true)
    local last = cap.list[#cap.list].msg
    H.match(last, 'itoa = "1.0.15"', true)
  end)

  it("shows cargo's error and reports failure", function()
    make_flow_ws()
    fake_registry()
    fake_cargo(function()
      return { code = 101, stdout = "", stderr = "error: the crate `itoa` could not be found in registry index.\n" }
    end)
    script_ui({})
    local cap = H.capture_notify()
    local ok, msg = run_add("itoa")
    H.eq(false, ok)
    H.match(msg, "could not be found", true)
    H.eq(vim.log.levels.ERROR, cap.list[#cap.list].level)
  end)

  it("offline: a clear message without a search answer, --offline when the results came from the cache", function()
    make_flow_ws()
    fake_registry({ search_err = "Could not resolve host: crates.io" })
    local calls = fake_cargo()
    local seen = script_ui({})
    local cap = H.capture_notify()
    ca.add("itoa")
    H.wait_for(function()
      for _, n in ipairs(cap.list) do
        if n.msg:find("search failed", 1, true) then
          return true
        end
      end
    end, 3000, "the offline message")
    H.eq(0, #seen, "no picker")
    H.eq(0, #calls)
    local text = vim.tbl_map(function(n)
      return n.msg
    end, cap.list)
    H.match(table.concat(text, "\n"), "Could not resolve host", true)

    restores[#restores]() -- search_async/info_async stubs: replace with a cached answer
    fake_registry({ stale = true })
    script_ui({})
    H.ok(run_add("itoa"))
    H.has(calls[1].argv, "--offline")
  end)

  it("goes on with the defaults when the feature list cannot be fetched", function()
    make_flow_ws()
    fake_registry({ info_err = "timed out" })
    local calls = fake_cargo()
    local seen = script_ui({})
    H.ok(run_add("itoa"))
    H.eq(2, #seen, "crate picker and target picker, no feature picker")
    H.eq({ "cargo", "add", "itoa", "-p", "app" }, calls[1].argv)
  end)

  it("outside a cargo workspace it says so", function()
    local dir = H.tmpdir() .. "/nowhere"
    write(dir .. "/a.rs", "fn main() {}\n")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/a.rs"))
    vim.cmd.lcd(vim.fn.fnameescape(dir))
    local cap = H.capture_notify()
    local seen = script_ui({})
    stub(cm, "root", function()
      return nil
    end)
    ca.add("itoa")
    H.eq(0, #seen)
    H.match(cap.list[#cap.list].msg, "not in a cargo workspace", true)
  end)
end)

describe("crate_add helpers", function()
  it("added_line finds the line in the table of the kind", function()
    local f = H.tmpdir() .. "/Cargo.toml"
    write(f, '[package]\nname = "x"\n\n[dependencies]\nserde = "1"\nitoa = { version = "1", features = ["a"] }\n\n[dev-dependencies]\nitoa = "2"\nitoa-extra.workspace = true\n')
    H.eq('itoa = { version = "1", features = ["a"] }', ca.added_line(f, "itoa", "normal"))
    H.eq('itoa = "2"', ca.added_line(f, "itoa", "dev"))
    H.is_nil(ca.added_line(f, "itoa", "build"))
    H.eq("itoa-extra.workspace = true", ca.added_line(f, "itoa-extra", "dev"))
  end)

  it("in_workspace_table reads inline and table forms only inside [workspace.dependencies]", function()
    local d = H.tmpdir()
    write(d .. "/Cargo.toml", '[workspace]\n[workspace.dependencies]\na = "1"\nb.version = "1"\n[workspace.dependencies.c]\nversion = "1"\n[dependencies]\nd = "1"\n')
    for _, n in ipairs({ "a", "b", "c" }) do
      H.ok(ca.in_workspace_table(d, n), n)
    end
    H.not_ok(ca.in_workspace_table(d, "d"))
  end)
end)

-- ------------------------------------------- diagnostics, server, the action

describe("crate_add unknown-crate hint and code action", function()
  local function have_rust()
    if vim.fn.executable("cargo") ~= 1 then
      skip("cargo not found")
    end
  end

  --- app2 without rand; a sibling path crate `rand` that `cargo add rand`
  --- (stubbed) wires in.
  local function make_ws2()
    local root = H.tmpdir() .. "/ws2"
    write(root .. "/Cargo.toml", '[workspace]\nmembers = ["app2"]\nresolver = "2"\n')
    pkg(root, "app2", "\n[dependencies]\n")
    pkg(root, "rand")
    write(root .. "/rand/src/lib.rs", "pub fn random() -> u8 { 4 }\n")
    write(root .. "/app2/src/main.rs", "fn main() {\n    let n = rand::random();\n    println!(\"{}\", n);\n}\n")
    return root
  end

  it("shows the hint within 3 s, offers 'Add crate rand' through the code-action menu, and clears it after the add", function()
    have_rust()
    local root = make_ws2()
    local calls = fake_cargo(function()
      write(root .. "/app2/Cargo.toml", read(root .. "/app2/Cargo.toml") .. 'rand = { path = "../rand" }\n')
      return { code = 0, stdout = "", stderr = "" }
    end)
    H.very_lazy() -- setup(): the server, the autocmds, the command
    local t0 = vim.uv.now()
    vim.cmd.edit(vim.fn.fnameescape(root .. "/app2/src/main.rs"))
    local buf = vim.api.nvim_get_current_buf()
    local function hints()
      return vim.diagnostic.get(buf, { namespace = ca.ns })
    end
    H.wait_for(function()
      return #hints() > 0
    end, 3000, "the unknown-crate hint")
    H.ok(vim.uv.now() - t0 < 3000)
    local d = hints()[1]
    H.eq("crate 'rand' is not a dependency", d.message)
    H.eq(vim.diagnostic.severity.HINT, d.severity)
    H.eq("xynovim", d.source)
    H.eq(1, d.lnum)

    -- the in-process server is attached and its action reaches vim.lsp.buf.code_action (<leader>ca)
    H.wait_for(function()
      return #H.clients(buf, "xynovim-crates") > 0
    end, 5000, "the xynovim-crates client")
    vim.api.nvim_win_set_cursor(0, { d.lnum + 1, d.col })
    local titles
    local orig_select = stub(vim.ui, "select", function(items, _, on_choice)
      titles = vim.tbl_map(function(i)
        return i.action and i.action.title or tostring(i)
      end, items)
      on_choice(nil)
    end)
    vim.lsp.buf.code_action({ filter = function(a) return a.title:find("^Add crate") ~= nil end })
    H.wait_for(function()
      return titles
    end, 3000, "the code-action menu")
    H.has(titles, "Add crate rand")
    vim.ui.select = orig_select

    -- apply it: cargo add rand runs for the package of the file, the hint goes away
    vim.lsp.buf.code_action({
      filter = function(a)
        return a.title == "Add crate rand"
      end,
      apply = true,
    })
    H.wait_for(function()
      return #calls > 0
    end, 5000, "cargo add")
    H.eq({ "cargo", "add", "rand", "-p", "app2" }, calls[1].argv)
    H.wait_for(function()
      return #hints() == 0
    end, 8000, "the hint to disappear")
  end)

  it("offers nothing away from the hint", function()
    have_rust()
    local root = make_ws2()
    H.very_lazy()
    vim.cmd.edit(vim.fn.fnameescape(root .. "/app2/src/main.rs"))
    local buf = vim.api.nvim_get_current_buf()
    H.wait_for(function()
      return #vim.diagnostic.get(buf, { namespace = ca.ns }) > 0 and #H.clients(buf, "xynovim-crates") > 0
    end, 5000, "hint and client")
    local acts = ca.actions_for(buf, { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 2 } })
    H.eq(0, #acts)
    local on = ca.actions_for(buf, { start = { line = 1, character = 14 }, ["end"] = { line = 1, character = 14 } })
    H.eq({ "Add crate rand", "Add crate rand (choose features and target)" }, vim.tbl_map(function(a)
      return a.title
    end, on))
  end)

  it("the second action opens the :CrateAdd flow for that crate", function()
    have_rust()
    local root = make_ws2()
    H.very_lazy()
    vim.cmd.edit(vim.fn.fnameescape(root .. "/app2/src/main.rs"))
    local buf = vim.api.nvim_get_current_buf()
    H.wait_for(function()
      return #vim.diagnostic.get(buf, { namespace = ca.ns }) > 0
    end, 5000, "the hint")
    H.wait_for(function()
      return #H.clients(buf, "xynovim-crates") > 0
    end, 5000, "the client")
    local got
    stub(ca, "add", function(q)
      got = q
    end)
    vim.api.nvim_win_set_cursor(0, { 2, 14 })
    vim.lsp.buf.code_action({
      filter = function(a)
        return a.title:find("choose features", 1, true) ~= nil
      end,
      apply = true,
    })
    H.wait_for(function()
      return got
    end, 3000, "CrateAdd for rand")
    H.eq("rand", got)
  end)

  it("no hint for a crate that is a dependency, nor after the crate is removed again", function()
    have_rust()
    local root = make_ws2()
    write(root .. "/app2/Cargo.toml", read(root .. "/app2/Cargo.toml") .. 'rand = { path = "../rand" }\n')
    H.very_lazy()
    vim.cmd.edit(vim.fn.fnameescape(root .. "/app2/src/main.rs"))
    local buf = vim.api.nvim_get_current_buf()
    local done
    ca.refresh(buf, function(h)
      done = h or false
    end)
    H.wait_for(function()
      return done ~= nil
    end, 5000, "the scan")
    H.eq({}, done)
    H.eq(0, #vim.diagnostic.get(buf, { namespace = ca.ns }))
  end)

  it("the check can be switched off with vim.g.xynovim_crate_check = false", function()
    have_rust()
    local root = make_ws2()
    H.very_lazy()
    vim.g.xynovim_crate_check = false
    local orig = vim.g.xynovim_crate_check
    table.insert(restores, function()
      vim.g.xynovim_crate_check = nil
    end)
    vim.cmd.edit(vim.fn.fnameescape(root .. "/app2/src/main.rs"))
    local buf = vim.api.nvim_get_current_buf()
    ca.refresh(buf)
    vim.wait(800)
    H.eq(0, #vim.diagnostic.get(buf, { namespace = ca.ns }))
    H.eq(false, orig)
  end)

  it("registers :CrateAdd and <leader>rA", function()
    H.very_lazy()
    H.eq(2, vim.fn.exists(":CrateAdd"))
    H.open_fixture("basic")
    H.wait_for(function()
      return vim.fn.maparg(" rA", "n", false, true).buffer == 1
    end, 3000, "the buffer-local <leader>rA")
    H.match(vim.fn.maparg(" rA", "n", false, true).rhs or "", "CrateAdd", true)
    -- keymaps.lua's rule: the only global <leader>r maps are the hidden stubs
    vim.cmd("enew")
    local g = vim.fn.maparg(" rA", "n", false, true)
    H.not_ok(g.rhs and g.rhs:find("CrateAdd", 1, true), "no global <leader>rA map")
  end)
end)

describe("crate_add real picker (Snacks)", function()
  it("preselects `default`, Tab toggles, Enter returns exactly the ticked items (possibly none)", function()
    H.very_lazy()
    local items = ca.feature_items({ features = { default = { "std" }, std = {}, alloc = { "dep:h" } } })
    local got
    ca.ui.pick({ title = "Features of x", items = items, multi = true }, function(sel)
      got = sel
    end)
    local p = H.wait_for(function()
      return Snacks.picker.get()[1]
    end, 5000, "the picker")
    H.wait_for(function()
      return #p:selected() == 1
    end, 3000, "default preselected")
    H.eq("default", p:selected()[1].feature)
    H.feed("<Tab>")
    H.eq(0, #p:selected())
    H.feed("<CR>")
    H.wait_for(function()
      return got
    end, 3000, "the callback")
    H.eq({}, got, "nothing ticked is an answer, not the highlighted item")
  end)
end)

describe("crate_add follows auto-save", function()
  it("rescans a rust buffer when auto-save wrote it (noautocmd: no BufWritePost)", function()
    H.very_lazy()
    local root = make_ws()
    local file = root .. "/app/src/main.rs"
    write(file, "fn main() {}\n")
    vim.cmd.edit(vim.fn.fnameescape(file))
    local buf = vim.api.nvim_get_current_buf()
    local hit
    stub(ca, "schedule", function(b)
      hit = b
    end)
    vim.api.nvim_exec_autocmds("User", { pattern = "AutoSaveWritePost", data = { saved_buffer = buf } })
    H.eq(buf, hit)
  end)
end)

-- ------------------------------------------------------------- network

describe("crate_add: the real flow (crates.io + cargo add)", function()
  local function online()
    if vim.fn.executable("curl") ~= 1 or vim.fn.executable("cargo") ~= 1 then
      return false, "curl or cargo not found"
    end
    local r = vim.system({ "curl", "-sS", "--max-time", "5", "-o", "/dev/null", "https://index.crates.io/config.json" }):wait(8000)
    if r.code ~= 0 then
      return false, "no network to crates.io"
    end
    return true
  end

  it("adds itoa to a copy of deps-lab, which then builds", function()
    local ok, why = online()
    if not ok then
      return skip(why)
    end
    local dir = H.fixture("deps-lab")
    local meta, err = cm.metadata(dir)
    if not meta then
      return skip("the registry lacks the deps-lab crates offline: " .. tostring(err):sub(1, 100))
    end
    stub(cm.config, "cache_dir", H.tmpdir() .. "/crates")
    cm.invalidate()
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/src/main.rs"))
    local chosen
    stub(ca.ui, "pick", function(spec, cb)
      if spec.title:find("^crates.io") then
        for _, it in ipairs(spec.items) do
          if it.crate.name == "itoa" then
            chosen = it
          end
        end
        return cb({ chosen or spec.items[1] })
      elseif spec.title:find("^Features") then
        local sel = {}
        for _, it in ipairs(spec.items) do
          if it.preselect then
            sel[#sel + 1] = it
          end
        end
        return cb(sel)
      end
      cb({ spec.items[1] })
    end)
    local done, okk, msg
    ca.add("itoa", function(a, b)
      done, okk, msg = true, a, b
    end)
    H.wait_for(function()
      return done
    end, 90000, "cargo add itoa")
    H.ok(okk, msg)
    H.ok(chosen, "itoa is among the search results")
    H.match(msg, "itoa", true)
    H.match(read(dir .. "/Cargo.toml"), "\nitoa = ", true)
    local b = vim.system({ "cargo", "check", "--quiet" }, { cwd = dir, text = true }):wait(110000)
    H.eq(0, b.code, b.stderr)
  end)
end)

describe("crate_add review fixes", function()
  it("a fresh cached answer is not labelled offline", function()
    make_flow_ws()
    fake_registry({ from_cache = true })
    fake_cargo()
    local seen = script_ui({})
    H.ok(run_add("itoa"))
    H.not_ok(seen[1].title:find("cached", 1, true), seen[1].title)
    stub(cm, "search_async", function(q, cb)
      vim.schedule(function()
        cb({ stale = true, { name = "itoa", version = "1", downloads = 1 } })
      end)
    end)
    seen = script_ui({})
    run_add("itoa")
    H.match(seen[1].title, "cached, offline?", true)
  end)

  it("restarts bacon-ls like a manifest save after cargo add (the buffer-less edit)", function()
    local root = make_flow_ws()
    fake_registry()
    fake_cargo()
    script_ui({})
    local saved = {}
    stub(require("config.rust_restart"), "manifest_saved", function(file)
      saved[#saved + 1] = file
    end)
    H.ok(run_add("itoa"))
    H.eq(1, #saved)
    H.match(saved[1], "Cargo.toml$")
  end)
end)
