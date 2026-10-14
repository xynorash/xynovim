-- config.crate_features: the missing-feature fix (name -> feature from the
-- crate's own source, the code action in the normal menu, Cargo.toml edits)
-- and the :CrateFeatures explorer.
-- Hermetic where it can be: synthetic crates in temp dirs for the scanner, text
-- fixtures for the manifest editor, a faked cm.exec for the argv checks. The
-- tests on real crates (serde, clap, tokio from the deps-lab fixtures) need the
-- registry to hold them offline (cargo metadata --offline) and skip with the
-- reason otherwise; one test runs a real `cargo check` on the fixture.
local H = require("xynotest.helpers")
local cm = require("config.crate_meta")
local ca = require("config.code_actions")
local cf = require("config.crate_features")

local restores = {}
local function stub(t, k, v)
  local orig = t[k]
  t[k] = v
  restores[#restores + 1] = function()
    t[k] = orig
  end
end

after_each(function()
  for i = #restores, 1, -1 do
    pcall(restores[i])
  end
  restores = {}
  cm.invalidate()
  cf.clear_cache()
  pcall(vim.cmd, "silent! %bwipeout!")
end)

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

--- A fake registry crate: a derive-style re-export behind an optional
--- dependency, a tokio-like cfg wrapper macro, a gated module, a glob
--- re-export, a macro_export macro and a commented-out decoy.
local function make_crate()
  local dir = H.tmpdir() .. "/fake-1.0.0"
  write(
    dir .. "/Cargo.toml",
    [[
[package]
name = "fake"
version = "1.0.0"

[features]
default = ["std"]
std = []
derive = ["fake_derive"]
rt = []
rt-multi-thread = ["rt"]
macros = ["fake_macros"]
full = ["derive", "rt-multi-thread", "macros"]

[dependencies]
fake_derive = { version = "1", optional = true }
fake_macros = { version = "1", optional = true }
]]
  )
  write(
    dir .. "/src/lib.rs",
    [[
//! docs with a decoy: #[cfg(feature = "decoy")] pub use x::Decoy;
#[macro_use]
mod macros;

pub struct Always;
pub fn always_fn() {}

#[cfg(feature = "fake_derive")]
#[doc(inline)]
pub use fake_derive::{Serialize, Deserialize as De};

/* #[cfg(feature = "decoy")] pub struct Decoy2; */

cfg_macros! {
    pub use fake_macros::main;
    cfg_rt! {
        #[cfg(feature = "rt-multi-thread")]
        pub use fake_macros::spawn_mt;
        pub use fake_macros::spawn;
    }
}

#[cfg(feature = "rt")]
pub mod runtime;

mod private_impl;
pub use self::private_impl::*;

#[cfg(any(feature = "derive", feature = "macros"))]
pub fn either() {}

#[cfg(all(feature = "derive", feature = "macros"))]
pub fn both() {}

#[cfg(test)]
pub fn only_in_tests() {}

#[macro_export]
#[cfg(feature = "macros")]
macro_rules! shout { () => {}; }

#[cfg(feature = "std")]
pub struct WithStd;
pub struct Plain<T: Iterator<Item = u8>> { x: T }
pub const LIMIT: Foo = Foo { a: 1 };
pub struct AfterConst;
]]
  )
  write(dir .. "/src/runtime.rs", "pub struct Runtime;\npub fn block_on() {}\n#[cfg(feature = \"macros\")]\npub struct MacroRuntime;\n")
  write(dir .. "/src/private_impl.rs", "#[cfg(feature = \"derive\")]\npub struct Exported;\npub struct Hidden;\n")
  write(
    dir .. "/src/macros/mod.rs",
    [[
#[macro_use]
mod cfg;
]]
  )
  write(
    dir .. "/src/macros/cfg.rs",
    [[
macro_rules! cfg_macros {
    ($($item:item)*) => {
        $(
            #[cfg(feature = "macros")]
            #[cfg_attr(docsrs, doc(cfg(feature = "macros")))]
            $item
        )*
    }
}
macro_rules! cfg_rt {
    ($($item:item)*) => { $( #[cfg(feature = "rt")] $item )* }
}
]]
  )
  return dir
end

local function features_of(dir)
  local ft = cm.parse_features(cm.read_manifest(dir))
  -- the implicit features of the optional dependencies (metadata has them)
  ft.fake_derive = { "dep:fake_derive" }
  ft.fake_macros = { "dep:fake_macros" }
  return ft
end

local function gate_keys(gate)
  local out = {}
  for _, alt in ipairs(gate) do
    local k = vim.tbl_keys(alt)
    table.sort(k)
    out[#out + 1] = table.concat(k, "+")
  end
  table.sort(out)
  return out
end

-- ------------------------------------------------------------------ cfg

describe("crate_features cfg parsing", function()
  it("reads feature, all, any, not and test", function()
    H.eq({ "a" }, gate_keys(cf.parse_cfg('feature = "a"')))
    H.eq({ "a+b" }, gate_keys(cf.parse_cfg('all(feature = "a", feature = "b")')))
    H.eq({ "a", "b" }, gate_keys(cf.parse_cfg('any(feature = "a", feature = "b")')))
    H.eq({ "a+c", "b+c" }, gate_keys(cf.parse_cfg('all(any(feature = "a", feature = "b"), feature = "c")')))
    H.eq({ "" }, gate_keys(cf.parse_cfg('not(feature = "a")')), "not() and other predicates are no requirement")
    H.eq({ "" }, gate_keys(cf.parse_cfg("unix")))
    H.eq({}, cf.parse_cfg("test"), "cfg(test) is never")
    H.eq({ "a" }, gate_keys(cf.parse_cfg('all(unix, feature = "a", not(target_os = "windows"))')))
  end)

  it("reads use trees", function()
    local u = cf.parse_use("fake_derive::{Serialize, Deserialize as De, inner::{self, X}, *}")
    local names = {}
    for _, e in ipairs(u) do
      names[#names + 1] = e.glob and "*" or e.name
    end
    H.eq({ "Serialize", "De", "inner", "X", "*" }, names)
    H.eq({ "a", "b" }, cf.parse_use("a::b::*")[1].path == nil and {} or { "a", "b" })
  end)
end)

-- --------------------------------------------------------------- scanner

describe("crate_features source scan", function()
  it("finds the gate of re-exports, wrapper macros, modules, globs and macro_export", function()
    local dir = make_crate()
    local idx = cf.scan(dir)
    H.ok(idx.files >= 5, "read lib.rs, macros/mod.rs, macros/cfg.rs, runtime.rs, private_impl.rs: " .. idx.files)
    local function gate(n)
      local g, why = cf.gate_of(idx, n)
      return g and gate_keys(g) or why
    end
    H.eq({ "fake_derive" }, gate("Serialize"))
    H.eq({ "fake_derive" }, gate("De"), "renamed re-export")
    H.eq("not found", gate("Deserialize"), "the original name was renamed away")
    H.eq({ "macros" }, gate("main"), "cfg_macros! wrapper")
    H.eq({ "macros+rt" }, gate("spawn"), "nested cfg_macros! { cfg_rt! { .. } }")
    H.eq({ "macros+rt+rt-multi-thread" }, gate("spawn_mt"))
    H.eq({ "rt" }, gate("Runtime"), "item of a gated module file")
    H.eq({ "macros+rt" }, gate("MacroRuntime"), "gate of the module AND of the item")
    H.eq({ "derive" }, gate("Exported"), "pub item of a private module re-exported by a glob")
    H.eq({ "derive", "macros" }, gate("either"))
    H.eq({ "derive+macros" }, gate("both"))
    H.eq({ "macros" }, gate("shout"), "#[macro_export] macro_rules")
    H.eq("ungated", gate("Always"))
    H.eq("ungated", gate("always_fn"))
    H.eq("not found", gate("only_in_tests"), "cfg(test) items are not API")
    H.eq("not found", gate("Decoy"), "a commented-out item is no item")
    H.eq("not found", gate("Decoy2"))
    H.eq("not found", gate("NoSuchThing"))
    H.eq({ "std" }, gate("WithStd"))
    H.eq("ungated", gate("Plain"), "`Item = u8` in a where/bound does not swallow the next items")
    H.eq("ungated", gate("AfterConst"), "a const initialised with a struct literal ends at its `;`")
  end)

  it("caps the files read and says so", function()
    local dir = make_crate()
    cf.clear_cache()
    local old = cf.config.max_files
    stub(cf.config, "max_files", 2)
    local idx = cf.scan(dir)
    H.eq(true, idx.truncated)
    H.ok(idx.files <= 2)
    cf.config.max_files = old
  end)

  it("a crate with no lib.rs scans to nothing without raising", function()
    local dir = H.tmpdir() .. "/nolib-1.0.0"
    write(dir .. "/Cargo.toml", '[package]\nname = "nolib"\nversion = "1.0.0"\n')
    local idx = cf.scan(dir)
    H.eq(0, idx.files)
    H.is_nil((cf.gate_of(idx, "X")))
  end)
end)

-- ----------------------------------------------------------- resolution

describe("crate_features feature resolution", function()
  local dir = make_crate()
  local ft = features_of(dir)
  local function resolve(names, enabled)
    local gate = { {} }
    for _, n in ipairs(names) do
      gate[1][n] = true
    end
    return cf.resolve(gate, ft, enabled or {})
  end

  it("maps an optional dependency's implicit feature to the feature that enables it", function()
    H.eq({ "derive" }, (resolve({ "fake_derive" })))
  end)

  it("keeps a plain gate feature and drops what another one implies", function()
    H.eq({ "macros" }, (resolve({ "fake_macros" })))
    H.eq({ "rt-multi-thread" }, (resolve({ "rt", "rt-multi-thread" })), "rt-multi-thread implies rt")
    H.eq({ "macros", "rt-multi-thread" }, (resolve({ "fake_macros", "rt", "rt-multi-thread" })))
  end)

  it("returns nothing when the gate already holds", function()
    local r, why = resolve({ "fake_derive" }, cf.closure(ft, "derive"))
    H.is_nil(r)
    H.eq("enabled", why)
  end)

  it("picks the cheapest alternative of an any()", function()
    local g = cf.parse_cfg('any(all(feature = "derive", feature = "macros"), feature = "std")')
    H.eq({ "std" }, (cf.resolve(g, ft, {})))
  end)

  it("computes the enabled set from declared features and the default set", function()
    local d = { features = { "rt-multi-thread" }, uses_default_features = true }
    local set = cf.enabled_set(d, ft)
    H.ok(set.rt and set["rt-multi-thread"] and set.std)
    d.uses_default_features = false
    H.not_ok(cf.enabled_set(d, ft).std)
  end)
end)

-- ------------------------------------------------------------- messages

describe("crate_features diagnostic messages", function()
  local function names(msg)
    return vim.tbl_map(function(n)
      return n.name .. (n.qual and ("@" .. n.qual) or "")
    end, cf.names_from_message(msg))
  end

  it("reads rustc, rust-analyzer and bacon-ls wording", function()
    H.eq({ "Serialize" }, names("cannot find derive macro `Serialize` in this scope"))
    H.eq({ "main" }, names("cannot find attribute macro `main` in this scope"))
    H.eq({ "json" }, names("cannot find macro `json` in this scope"))
    H.eq({ "spawn@tokio" }, names("failed to resolve: could not find `spawn` in `tokio`"))
    H.eq({ "Serialize@serde" }, names("unresolved import `serde::Serialize`"))
    H.eq({ "main@tokio" }, names("unresolved macro `tokio::main`"))
    H.eq({ "Parser@clap" }, names("error[E0432]: unresolved import `clap::Parser`\nno `Parser` in the root"))
  end)

  it("ignores messages without a name and names that are no identifier", function()
    H.eq({}, names("mismatched types"))
    H.eq({}, names("cannot find value `a b` in this scope"))
    H.eq({}, names("cannot find macro `x; rm -rf` in this scope"))
  end)
end)

-- ------------------------------------------------------- manifest editor

describe("crate_features Cargo.toml edits", function()
  local function edit(text, key, op, features, extra)
    return cf.edit_manifest(text, vim.tbl_extend("force", { key = key, kind = "normal" }, extra or {}), op, features)
  end

  it("turns a version string into an inline table", function()
    local out = edit('[dependencies]\nserde = "1" # keep\nrand = "0.8"\n', "serde", "add", { "derive" })
    H.eq('[dependencies]\nserde = { version = "1", features = ["derive"] } # keep\nrand = "0.8"\n', out)
  end)

  it("appends to an existing features array and to an inline table without one", function()
    H.eq('[dependencies]\ntokio = { version = "1", features = ["rt", "macros"] }\n', (edit('[dependencies]\ntokio = { version = "1", features = ["rt"] }\n', "tokio", "add", { "macros" })))
    H.eq('[dependencies]\nx = { version = "1", default-features = false, features = ["a"] }\n', (edit('[dependencies]\nx = { version = "1", default-features = false }\n', "x", "add", { "a" })))
    H.eq('[dependencies]\nx = { features = ["a"] }\n', (edit("[dependencies]\nx = { }\n", "x", "add", { "a" })))
    H.eq('[dependencies]\nserde = { workspace = true, features = ["derive"] } # c\n', (edit("[dependencies]\nserde = { workspace = true } # c\n", "serde", "add", { "derive" })))
  end)

  it("keeps a multi-line array's layout, comments and trailing comma", function()
    local src = '[dependencies]\ntokio = { version = "1", features = [\n    "rt", # runtime\n    "net",\n] }\n'
    local out = edit(src, "tokio", "add", { "macros" })
    H.eq('[dependencies]\ntokio = { version = "1", features = [\n    "rt", # runtime\n    "net",\n    "macros",\n] }\n', out)
  end)

  it("edits the table form and the dotted-key form", function()
    H.eq('[dependencies.serde]\nversion = "1"\nfeatures = ["derive"]\n\n[other]\na = 1\n', (edit('[dependencies.serde]\nversion = "1"\n\n[other]\na = 1\n', "serde", "add", { "derive" })))
    H.eq('[dependencies.serde]\nversion = "1"\nfeatures = ["a", "derive"]\n', (edit('[dependencies.serde]\nversion = "1"\nfeatures = ["a"]\n', "serde", "add", { "derive" })))
    H.eq('[dependencies]\nserde.workspace = true\nserde.features = ["derive"]\nrand = "1"\n', (edit('[dependencies]\nserde.workspace = true\nrand = "1"\n', "serde", "add", { "derive" })))
    H.eq('[dependencies]\nserde.workspace = true\nserde.features = ["a", "derive"]\n', (edit('[dependencies]\nserde.workspace = true\nserde.features = ["a"]\n', "serde", "add", { "derive" })))
  end)

  it("picks the dependency table of the kind and target", function()
    local src = '[dependencies]\nx = "1"\n\n[dev-dependencies]\nx = "1"\n\n[target.\'cfg(unix)\'.dependencies]\nx = "1"\n'
    local dev = edit(src, "x", "add", { "f" }, { kind = "dev" })
    H.eq('[dependencies]\nx = "1"\n\n[dev-dependencies]\nx = { version = "1", features = ["f"] }\n\n[target.\'cfg(unix)\'.dependencies]\nx = "1"\n', dev)
    local tgt = edit(src, "x", "add", { "f" }, { target = "cfg(unix)" })
    H.eq('[dependencies]\nx = "1"\n\n[dev-dependencies]\nx = "1"\n\n[target.\'cfg(unix)\'.dependencies]\nx = { version = "1", features = ["f"] }\n', tgt)
    local ws = cf.edit_manifest('[workspace.dependencies]\nx = "1"\n', { key = "x", workspace = true }, "add", { "f" })
    H.eq('[workspace.dependencies]\nx = { version = "1", features = ["f"] }\n', ws)
  end)

  it("handles a renamed dependency key and quoted keys", function()
    H.eq('[dependencies]\nhelpers = { package = "util", path = "../util", features = ["fast"] }\n', (edit('[dependencies]\nhelpers = { package = "util", path = "../util" }\n', "helpers", "add", { "fast" })))
    H.eq('[dependencies]\n"my-dep" = { version = "1", features = ["f"] }\n', (edit('[dependencies]\n"my-dep" = "1"\n', "my-dep", "add", { "f" })))
  end)

  it("removes a feature and leaves the rest", function()
    H.eq('[dependencies]\ntokio = { version = "1", features = ["rt"] }\n', (edit('[dependencies]\ntokio = { version = "1", features = ["rt", "macros"] }\n', "tokio", "remove", { "macros" })))
    H.eq('[dependencies]\ntokio = { version = "1", features = ["macros"] }\n', (edit('[dependencies]\ntokio = { version = "1", features = ["rt", "macros"] }\n', "tokio", "remove", { "rt" })))
    H.eq('[dependencies]\ntokio = { version = "1", features = [] }\n', (edit('[dependencies]\ntokio = { version = "1", features = ["rt"] }\n', "tokio", "remove", { "rt" })))
  end)

  it("reports what it cannot do instead of guessing", function()
    local out, why = edit('[dependencies]\nx = "1"\n', "y", "add", { "f" })
    H.is_nil(out)
    H.match(why, "not declared", false)
    out, why = edit('[dependencies]\nx = { version = "1", features = ["a"] }\n', "x", "add", { "a" })
    H.is_nil(out)
    H.match(why, "already", false)
    out, why = edit('[dependencies]\nx = "1"\n', "x", "remove", { "a" })
    H.is_nil(out)
    H.match(why, "not declared", false)
  end)
end)

-- ------------------------------------------------- set_features (no cargo)

describe("crate_features set_features", function()
  local function fake_dep(dir, over)
    return vim.tbl_extend("force", {
      name = "serde",
      alias = "serde",
      kind = "normal",
      features = {},
      uses_default_features = true,
      source = "registry+https://github.com/rust-lang/crates.io-index",
      member = "app",
      member_manifest = dir .. "/Cargo.toml",
    }, over or {})
  end
  local function run(d, features, on)
    local done, ok, how
    cf.set_features(d, features, on, function(a, b)
      done, ok, how = true, a, b
    end)
    H.wait_for(function()
      return done
    end, 5000, "set_features did not finish")
    return ok, how
  end

  it("runs cargo add with an argv list, offline first, for a registry dependency", function()
    local dir = H.tmpdir()
    write(dir .. "/Cargo.toml", '[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\nserde = "1"\n')
    local calls = {}
    stub(cm, "exec", function(argv, opts, cb)
      calls[#calls + 1] = argv
      -- act like cargo add
      write(dir .. "/Cargo.toml", '[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\nserde = { version = "1", features = ["derive"] }\n')
      cb({ code = 0, stdout = "", stderr = "" })
    end)
    local ok, how = run(fake_dep(dir), { "derive" }, true)
    H.eq(true, ok)
    H.eq("cargo add", how)
    H.eq(1, #calls)
    H.eq({ "cargo", "add", "serde", "--features", "derive", "--manifest-path", dir .. "/Cargo.toml", "--offline" }, calls[1])
  end)

  it("passes --dev / --build / --target and falls back to the online run", function()
    local dir = H.tmpdir()
    write(dir .. "/Cargo.toml", '[package]\nname = "app"\nversion = "0.1.0"\n\n[dev-dependencies]\nserde = "1"\n')
    local calls = {}
    stub(cm, "exec", function(argv, _, cb)
      calls[#calls + 1] = argv
      if #calls == 1 then
        return cb({ code = 101, stdout = "", stderr = "offline: no index" })
      end
      write(dir .. "/Cargo.toml", '[package]\nname = "app"\nversion = "0.1.0"\n\n[dev-dependencies]\nserde = { version = "1", features = ["derive"] }\n')
      cb({ code = 0, stdout = "", stderr = "" })
    end)
    local ok = run(fake_dep(dir, { kind = "dev", target = "cfg(unix)" }), { "derive" }, true)
    H.eq(true, ok)
    H.eq(2, #calls)
    H.has(calls[1], "--dev")
    H.has(calls[1], "--offline")
    H.not_ok(vim.tbl_contains(calls[2], "--offline"))
    H.eq({ "--target", "cfg(unix)" }, { calls[2][#calls[2] - 1], calls[2][#calls[2]] }, "target last")
  end)

  it("falls back to the text edit when cargo add is missing or changes nothing", function()
    local dir = H.tmpdir()
    write(dir .. "/Cargo.toml", '[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\nserde = "1" # keep\n')
    stub(cm, "exec", function(_, _, cb)
      cb({ code = -1, stdout = "", stderr = "cargo: not found" })
    end)
    local ok, how = run(fake_dep(dir), { "derive" }, true)
    H.eq(true, ok)
    H.eq("text edit", how)
    H.eq('[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\nserde = { version = "1", features = ["derive"] } # keep\n', read(dir .. "/Cargo.toml"))
  end)

  it("edits renamed and path dependencies as text and never calls cargo for them", function()
    local dir = H.tmpdir()
    write(dir .. "/Cargo.toml", '[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\nhelpers = { package = "util", path = "../util" }\n')
    stub(cm, "exec", function()
      error("cargo must not run")
    end)
    local ok, how = run(fake_dep(dir, { name = "util", alias = "helpers", rename = "helpers", source = vim.NIL and nil }), { "fast" }, true)
    H.eq(true, ok, tostring(how))
    H.eq("text edit", how)
    H.match(read(dir .. "/Cargo.toml"), 'features = ["fast"]', true)
  end)

  it("switching off is a text edit", function()
    local dir = H.tmpdir()
    write(dir .. "/Cargo.toml", '[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\nserde = { version = "1", features = ["derive", "rc"] }\n')
    stub(cm, "exec", function()
      error("cargo must not run")
    end)
    local ok = run(fake_dep(dir, { features = { "derive", "rc" } }), { "derive" }, false)
    H.eq(true, ok)
    H.match(read(dir .. "/Cargo.toml"), 'features = ["rc"]', true)
  end)

  it("refuses names that are not plain identifiers and manifests with unsaved changes", function()
    local dir = H.tmpdir()
    write(dir .. "/Cargo.toml", '[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\nserde = "1"\n')
    stub(cm, "exec", function()
      error("cargo must not run")
    end)
    local ok, why = run(fake_dep(dir), { "derive; rm -rf /" }, true)
    H.eq(false, ok)
    H.match(why, "invalid", false)
    ok = run(fake_dep(dir, { name = "serde --git evil" }), { "derive" }, true)
    H.eq(false, ok)
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/Cargo.toml"))
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "# dirty" })
    ok, why = run(fake_dep(dir), { "derive" }, true)
    H.eq(false, ok)
    H.match(why, "unsaved", false)
    H.eq('[package]\nname = "app"\nversion = "0.1.0"\n\n[dependencies]\nserde = "1"\n', read(dir .. "/Cargo.toml"))
  end)
end)

-- ------------------------------------------- real crates (registry needed)

--- A temp crate with the given [dependencies] body; metadata offline or skip.
local function crate_with(deps_toml, main_rs)
  local dir = H.tmpdir() .. "/cf-app"
  write(dir .. "/Cargo.toml", '[package]\nname = "cf-app"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n' .. deps_toml)
  write(dir .. "/src/main.rs", main_rs)
  local meta, err = cm.metadata(dir)
  if not meta then
    return skip("registry lacks these crates offline: " .. tostring(err):sub(1, 120))
  end
  return dir, meta
end

--- Make src/main.rs the current buffer without a filetype (no rust-analyzer
--- starts for a scratch crate).
local function enter(dir)
  vim.cmd.cd(vim.fn.fnameescape(dir))
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, dir .. "/src/main.rs")
  vim.api.nvim_set_current_buf(buf)
end

local function suggest(meta, dir, msg, lnum)
  local file = dir .. "/src/main.rs"
  local lines = vim.fn.readfile(file)
  return cf.suggest(meta, file, lines, { { message = msg, lnum = lnum or 0, col = 0 } })
end

describe("crate_features on real crates", function()
  it("serde: #[derive(Serialize)] without the derive feature -> enable `derive`", function()
    H.need_rust()
    local dir, meta = crate_with('serde = "1"\n', "use serde::Serialize;\n#[derive(Serialize)]\nstruct A;\nfn main() {}\n")
    local s = suggest(meta, dir, "cannot find derive macro `Serialize` in this scope", 1)
    H.eq(1, #s, vim.inspect(s))
    H.eq("serde", s[1].crate)
    H.eq({ "derive" }, s[1].features)
    H.eq("Enable feature `derive` of `serde`", cf.title(s[1]))
    H.eq(dir .. "/Cargo.toml", s[1].manifest)
  end)

  it("clap: Parser needs derive; tokio: main needs macros", function()
    H.need_rust()
    local dir, meta = crate_with(
      'clap = "4"\ntokio = { version = "1", features = ["rt-multi-thread"] }\n',
      "use clap::Parser;\n#[derive(Parser)]\nstruct Cli;\n#[tokio::main]\nasync fn main() {}\n"
    )
    local s = suggest(meta, dir, "cannot find derive macro `Parser` in this scope", 1)
    H.eq(1, #s, vim.inspect(s))
    H.eq({ "clap", { "derive" } }, { s[1].crate, s[1].features })
    s = suggest(meta, dir, "failed to resolve: could not find `main` in `tokio`", 3)
    H.eq(1, #s, vim.inspect(s))
    H.eq({ "tokio", { "macros" } }, { s[1].crate, s[1].features })
  end)

  it("offers nothing when the feature is already on, for an item in no feature, or for no diagnostic", function()
    H.need_rust()
    local dir, meta = crate_with('serde = { version = "1", features = ["derive"] }\n', "use serde::Serialize;\n#[derive(Serialize)]\nstruct A;\nfn main() {}\n")
    H.eq({}, suggest(meta, dir, "cannot find derive macro `Serialize` in this scope", 1), "derive is on: not a feature problem")
    local dir2, meta2 = crate_with('serde = "1"\n', "#[derive(Frobnicate)]\nstruct A;\nfn main() {}\n")
    H.eq({}, suggest(meta2, dir2, "cannot find derive macro `Frobnicate` in this scope", 0), "an item that exists in no feature")
    H.eq({}, suggest(meta2, dir2, "mismatched types", 0))
    H.eq({}, cf.suggest(meta2, dir2 .. "/src/main.rs", { "" }, {}))
  end)

  it("the identifier under an unnamed diagnostic in an attribute is used", function()
    H.need_rust()
    local dir, meta = crate_with('serde = "1"\n', "#[derive(Debug, Serialize)]\nstruct A;\nfn main() {}\n")
    local lines = vim.fn.readfile(dir .. "/src/main.rs")
    local col = lines[1]:find("Serialize", 1, true) - 1
    local s = cf.suggest(meta, dir .. "/src/main.rs", lines, { { message = "unresolved macro", lnum = 0, col = col, end_lnum = 0, end_col = col + 9 } })
    H.eq({ "derive" }, s[1] and s[1].features)
  end)

  it("explores serde: declared vs available, what derive unlocks, the unused hint", function()
    H.need_rust()
    local dir, meta = crate_with('serde = { version = "1", features = ["derive"] }\n', "use serde::Serialize;\n#[derive(Serialize)]\nstruct A;\nfn main() {}\n")
    local d = cm.dependencies(meta, { name = "serde" })[1]
    local info = cf.explore(meta, d)
    local by = {}
    for _, f in ipairs(info.features) do
      by[f.name] = f
    end
    H.eq(true, by.derive.declared)
    H.eq(true, by.derive.on)
    H.has(by.derive.items, "Serialize")
    H.has(by.derive.items, "Deserialize")
    H.eq(false, by.derive.unused, "Serialize is written in main.rs")
    H.eq(false, by.rc.on)
    H.eq(false, by.rc.declared)
    H.eq(true, by.std.in_default)
    H.eq(true, by.std.on, "default features are on")
    H.has(info.default, "std")
    H.match(cf.feature_line(by.derive), "[x] derive", true)
    H.match(cf.feature_line(by.derive), "unlocks", true)
    H.match(table.concat(cf.feature_preview(info, by.derive), "\n"), "Deserialize", true)
  end)

  it("flags a declared feature whose items the workspace never mentions as unused?", function()
    H.need_rust()
    local _, meta = crate_with('serde = { version = "1", features = ["derive", "rc"] }\n', "fn main() {}\n")
    local info = cf.explore(meta, cm.dependencies(meta, { name = "serde" })[1])
    local by = {}
    for _, f in ipairs(info.features) do
      by[f.name] = f
    end
    H.eq(true, by.derive.unused)
    H.match(cf.feature_line(by.derive), "unused?", true)
    H.eq(false, by.rc.unused, "a feature that gates no item is not judged")
  end)
end)

-- ---------------------------------------- the deps-lab-nofeature acceptance

describe("crate_features acceptance on tests/fixtures/deps-lab-nofeature", function()
  it("the derive diagnostic yields the action, applying it makes cargo check succeed", function()
    H.need_rust()
    local dir = H.fixture("deps-lab-nofeature")
    local meta, err = cm.metadata(dir)
    if not meta then
      return skip("registry lacks the fixture's crates offline: " .. tostring(err):sub(1, 120))
    end
    local main = dir .. "/src/main.rs"
    local lines = vim.fn.readfile(main)
    local lnum
    for i, l in ipairs(lines) do
      if l:find("#[derive(Debug, Serialize, Deserialize)]", 1, true) then
        lnum = i - 1
      end
    end
    H.ok(lnum, "fixture still derives Serialize")
    local s = cf.suggest(meta, main, lines, { { message = "cannot find derive macro `Serialize` in this scope", lnum = lnum, col = 0 } })
    H.eq(1, #s, vim.inspect(s))
    H.eq({ "serde", { "derive" } }, { s[1].crate, s[1].features })
    -- the code action in the normal menu: a buffer of the file with the
    -- in-process client, a diagnostic as bacon-ls reports it
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, main)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = ""
    cf.attach(buf)
    local clients = vim.lsp.get_clients({ bufnr = buf, name = cf.client_name })
    H.eq(1, #clients, "the in-process client attached")
    local ns = vim.api.nvim_create_namespace("cf-spec")
    vim.diagnostic.set(ns, buf, { { lnum = lnum, col = 0, end_lnum = lnum, end_col = 5, severity = 1, message = "cannot find derive macro `Serialize` in this scope", source = "bacon-ls" } })
    stub(ca, "client_name", cf.client_name)
    local list = ca.request_wait(buf, { start = { lnum, 0 }, ["end"] = { lnum, 1 } }, {})
    local hits = ca.filter(list, { title = "Enable feature `derive` of `serde`", plain = true })
    H.eq(1, #hits, vim.inspect(vim.tbl_map(function(a)
      return a.title
    end, list)))
    H.eq("quickfix", hits[1].kind)
    local before = read(dir .. "/Cargo.toml")
    local ok, aerr = ca.apply(hits[1], { timeout = 60000 })
    H.eq(true, ok, tostring(aerr))
    local after = read(dir .. "/Cargo.toml")
    H.ok(after ~= before)
    H.match(after, 'serde = { version = "1", features = ["derive"] }', true)
    H.match(after, 'clap = { version = "4", features = ["derive"] }', true)
    -- cargo check on the edited copy
    local target = H.tmpdir()
    local r = vim.system({ "cargo", "check", "--offline", "--quiet", "--target-dir", target }, { cwd = dir, text = true }):wait(110000)
    H.eq(0, r.code, (r.stderr or ""):sub(-1500))
  end)

  it("an uneditable-by-cargo manifest still gets the feature through the text edit (workspace = true)", function()
    H.need_rust()
    local root = H.tmpdir() .. "/ws"
    write(root .. "/Cargo.toml", '[workspace]\nmembers = ["m"]\nresolver = "2"\n\n[workspace.dependencies]\nserde = "1" # keep me\n')
    write(root .. "/m/Cargo.toml", '[package]\nname = "m"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\nserde = { workspace = true } # c\n')
    write(root .. "/m/src/main.rs", "fn main() {}\n")
    local meta, err = cm.metadata(root)
    if not meta then
      return skip("registry lacks serde offline: " .. tostring(err):sub(1, 120))
    end
    stub(cm, "exec", function(_, _, cb)
      cb({ code = -1, stdout = "", stderr = "no cargo" })
    end)
    local d = cm.dependencies(meta, { name = "serde" })[1]
    local done, ok, how
    cf.set_features(d, { "derive" }, true, function(a, b)
      done, ok, how = true, a, b
    end)
    H.wait_for(function()
      return done
    end, 5000)
    H.eq(true, ok, tostring(how))
    H.eq('[package]\nname = "m"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\nserde = { workspace = true, features = ["derive"] } # c\n', read(root .. "/m/Cargo.toml"))
    H.eq('[workspace]\nmembers = ["m"]\nresolver = "2"\n\n[workspace.dependencies]\nserde = "1" # keep me\n', read(root .. "/Cargo.toml"), "the workspace table is not touched")
  end)
end)

-- ----------------------------------------------------- explorer command

describe("crate_features :CrateFeatures", function()
  it("registers the command and the Rust key, free of other mappings", function()
    cf.setup()
    H.eq(2, vim.fn.exists(":CrateFeatures"))
    local buf = vim.api.nvim_create_buf(false, true)
    cf.on_rust_buffer(buf)
    local m = vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg("<leader>rG", "n", false, true)
    end)
    H.eq(1, m.buffer)
    H.eq("Fix missing crate feature", m.desc)
    -- not global, and <leader>rE keeps its meaning
    local other = vim.api.nvim_create_buf(false, true)
    local g = vim.api.nvim_buf_call(other, function()
      return vim.fn.maparg("<leader>rG", "n", false, true)
    end)
    H.eq(0, vim.tbl_count(g), "no global <leader>rG")
    local e = vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg("<leader>rE", "n", false, true)
    end)
    H.ok(e.desc == nil or not e.desc:find("feature", 1, true), "<leader>rE is not taken over")
  end)

  it("lists a dependency's features and toggles one with an edit of Cargo.toml", function()
    H.need_rust()
    local dir, meta = crate_with('serde = { version = "1", features = ["rc"] }\n', "fn main() {}\n")
    enter(dir)
    local picked
    stub(cf, "pick", function(items, opts)
      picked = { items = items, opts = opts }
    end)
    local real_exec = cm.exec
    stub(cm, "exec", function(argv, o, cb) -- no cargo add (text edit); metadata still runs
      if argv[2] == "add" then
        return cb({ code = -1, stdout = "", stderr = "no cargo" })
      end
      return real_exec(argv, o, cb)
    end)
    cf.open("serde")
    H.wait_for(function()
      return picked
    end, 20000, "the picker did not open")
    H.match(picked.opts.title, "serde", true)
    local by = {}
    for _, it in ipairs(picked.items) do
      by[it.data.name] = it
    end
    H.ok(by.rc and by.derive, "features listed")
    H.match(by.rc.text, "[x] rc", true)
    H.match(by.derive.text, "[ ] derive", true)
    -- toggle derive on: the list opens again with it declared
    local reopened
    stub(cf, "pick", function(its, o)
      reopened = { items = its, opts = o }
    end)
    picked.opts.on_toggle(by.derive)
    H.wait_for(function()
      return reopened
    end, 20000, "the list did not reopen after the toggle")
    H.match(read(dir .. "/Cargo.toml"), 'features = ["rc", "derive"]', true)
    local row
    for _, it in ipairs(reopened.items) do
      if it.data.name == "derive" then
        row = it
      end
    end
    H.match(row.text, "[x] derive", true)
    -- and off again
    local again
    stub(cf, "pick", function(its, o)
      again = { items = its, opts = o }
    end)
    reopened.opts.on_toggle(row)
    H.wait_for(function()
      return again
    end, 20000)
    H.match(read(dir .. "/Cargo.toml"), 'features = ["rc"]', true)
  end)

  it("says so for a crate that is not a dependency", function()
    H.need_rust()
    local dir = crate_with('serde = "1"\n', "fn main() {}\n")
    enter(dir)
    local seen = H.capture_notify()
    cf.open("nosuchcrate")
    H.wait_for(function()
      return #seen.list > 0
    end, 20000)
    H.match(seen.list[1].msg, "no dependency", true)
  end)
end)
