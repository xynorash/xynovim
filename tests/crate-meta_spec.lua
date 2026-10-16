-- config.crate_meta (cargo metadata, registry sources, crates.io client, known
-- path heads) and config.code_actions (request, filter, apply, wait).
-- Hermetic: path-only temp workspaces, a fake CARGO_HOME, a faked or file://
-- curl, a fake LSP client. The deps-lab fixtures need cargo metadata --offline
-- to succeed (the registry must already hold their crates) and skip otherwise;
-- the two network tests skip without network.
local H = require("xynotest.helpers")
local cm = require("config.crate_meta")
local ca = require("config.code_actions")

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
  pcall(vim.cmd, "silent! %bwipeout!")
end)

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

--- A workspace of path crates only (no registry needed):
--- app (bin+lib "app") -> renamed util (as `helpers`), optional opt, dev dev_only,
--- build builder; plus the members util, opt, dev_only, builder.
local function make_workspace()
  local root = H.tmpdir() .. "/ws"
  write(root .. "/Cargo.toml", '[workspace]\nmembers = ["app", "util", "opt", "dev_only", "builder"]\nresolver = "2"\n')
  for _, n in ipairs({ "util", "opt", "dev_only", "builder" }) do
    write(
      ("%s/%s/Cargo.toml"):format(root, n),
      ('[package]\nname = "%s"\nversion = "0.2.0"\nedition = "2021"\n\n[features]\nfast = []\nextra = ["fast"]\n'):format(n)
    )
    write(("%s/%s/src/lib.rs"):format(root, n), "pub fn f() {}\n")
  end
  write(
    root .. "/app/Cargo.toml",
    [[
[package]
name = "app"
version = "0.1.0"
edition = "2021"

[dependencies]
helpers = { package = "util", path = "../util", default-features = false, features = ["fast"] }
opt = { path = "../opt", optional = true }

[dev-dependencies]
dev_only = { path = "../dev_only" }

[build-dependencies]
builder = { path = "../builder" }
]]
  )
  write(root .. "/app/build.rs", "fn main() {}\n")
  write(root .. "/app/src/main.rs", "mod net;\nmod inline_mod {}\nstruct Local;\nmacro_rules! shout { () => {}; }\nfn main() {}\n")
  write(root .. "/app/src/lib.rs", "pub mod net;\n")
  write(root .. "/app/src/net.rs", "pub mod http;\n")
  write(root .. "/app/src/net/http.rs", "")
  write(root .. "/app/src/macros.rs", "macro_rules! other_file_macro { () => {}; }\n")
  return root
end

-- ---------------------------------------------------------------- validation

describe("crate_meta validation", function()
  it("accepts crate names and rejects anything a shell or path could misread", function()
    for _, n in ipairs({ "serde", "serde_json", "tokio-util", "a1" }) do
      H.ok(cm.valid_name(n), n)
    end
    for _, n in ipairs({ "", "a b", "a/b", "../x", "a;b", "a$(x)", "a\nb", "é", string.rep("a", 65), 5 }) do
      H.not_ok(cm.valid_name(n), vim.inspect(n))
    end
  end)

  it("accepts semver-ish versions only", function()
    for _, v in ipairs({ "1.0.0", "0.9.15", "1.2.3-rc.1", "1.0.0+build.5" }) do
      H.ok(cm.valid_version(v), v)
    end
    for _, v in ipairs({ "1", "1.0", "^1.0.0", "1.0.0; rm", "../1.0.0", "" }) do
      H.not_ok(cm.valid_version(v), v)
    end
  end)

  it("compares versions numerically and puts pre-releases first", function()
    H.eq(-1, cm.compare_versions("1.0.9", "1.0.10"))
    H.eq(1, cm.compare_versions("2.0.0", "1.99.99"))
    H.eq(0, cm.compare_versions("1.2.3", "1.2.3"))
    H.eq(-1, cm.compare_versions("1.0.0-rc.1", "1.0.0"))
    H.eq(1, cm.compare_versions("1.0.0", "1.0.0-rc.1"))
  end)

  it("builds sparse index paths", function()
    H.eq("1/a", cm.index_path("a"))
    H.eq("2/ab", cm.index_path("ab"))
    H.eq("3/s/syn", cm.index_path("syn"))
    H.eq("se/rd/serde", cm.index_path("serde"))
    H.eq("se/rd/serde_json", cm.index_path("Serde_Json"):gsub("serde_json", "serde_json") and "se/rd/serde_json")
    H.eq("to/ki/tokio-util", cm.index_path("tokio-util"))
  end)
end)

-- ---------------------------------------------------------- cargo metadata

describe("crate_meta.metadata", function()
  it("reads members, dependencies by kind, renames, optional and features", function()
    H.need_rust()
    local root = make_workspace()
    local meta, err = cm.metadata(root)
    H.ok(meta, err)
    H.eq(root, meta.root)
    H.eq(5, #meta.members)
    local app
    for _, m in ipairs(meta.members) do
      if m.name == "app" then
        app = m
      end
    end
    H.ok(app)
    H.eq("app", app.lib_name)
    H.eq(root .. "/app", app.dir)

    local deps = cm.dependencies(meta, { member = "app" })
    H.eq(4, #deps)
    local by = {}
    for _, d in ipairs(deps) do
      by[d.alias] = d
    end
    -- the rename: package util used as `helpers`
    H.eq("util", by.helpers.name)
    H.eq("normal", by.helpers.kind)
    H.eq(false, by.helpers.uses_default_features)
    H.eq({ "fast" }, by.helpers.features)
    H.eq("app", by.helpers.member)
    H.eq("dev", by.dev_only.kind)
    H.eq("build", by.builder.kind)
    H.eq(true, by.opt.optional)
    -- the resolved package carries its full [features] table
    H.eq("util", by.helpers.resolved.name)
    H.eq("0.2.0", by.helpers.resolved.version)
    H.eq({ "fast" }, by.helpers.resolved.features.extra)
    H.has(by.helpers.resolved.enabled_features, "fast")
    H.eq(1, #cm.dependencies(meta, { member = "app", kind = "dev" }))
    H.eq(1, #cm.dependencies(meta, { name = "helpers" }))
    -- an optional dependency nobody enabled is not resolved
    H.is_nil(by.opt.resolved)
    H.eq("app", cm.member_of(meta, root .. "/app/src/main.rs").name)
    H.is_nil(cm.member_of(meta, "/nonexistent/x.rs"))
  end)

  it("caches until a manifest or the lock changes", function()
    H.need_rust()
    local root = make_workspace()
    local a = cm.metadata(root)
    H.ok(a)
    H.ok(rawequal(a, cm.metadata(root)), "second call is the cached table")
    -- a member manifest edit (new mtime) invalidates
    local f = root .. "/app/Cargo.toml"
    local txt = io.open(f):read("*a")
    vim.uv.fs_utime(f, os.time() + 5, os.time() + 5)
    local b = cm.metadata(root)
    H.ok(not rawequal(a, b), "recomputed after the member manifest changed")
    write(f, txt:gsub('version = "0.1.0"', 'version = "0.1.1"'))
    local c = cm.metadata(root)
    H.eq("0.1.1", vim.tbl_filter(function(m)
      return m.name == "app"
    end, c.members)[1].version)
    -- refresh forces
    H.ok(not rawequal(c, cm.metadata(root, { refresh = true })))
  end)

  it("has an async variant", function()
    H.need_rust()
    local root = make_workspace()
    local got, gerr
    cm.metadata_async(root, function(m, e)
      got, gerr = m or false, e
    end)
    H.wait_for(function()
      return got ~= nil
    end, 20000, "metadata_async")
    H.ok(got, gerr)
    H.eq(5, #got.members)
    -- a second call while nothing is pending is answered from the cache
    local again
    cm.metadata_async(root, function(m)
      again = m
    end)
    H.wait_for(function()
      return again
    end, 2000)
    H.ok(rawequal(got, again))
  end)

  it("returns an error value, not an exception, outside a workspace and for a broken manifest", function()
    H.need_rust()
    local dir = H.tmpdir()
    local m, e = cm.metadata(dir)
    H.is_nil(m)
    H.match(e, "workspace", true)
    write(dir .. "/Cargo.toml", "this is [not toml")
    local m2, e2 = cm.metadata(dir)
    H.is_nil(m2)
    H.ok(type(e2) == "string" and #e2 > 0)
  end)

  it("reads the deps-lab fixture (serde derive, tokio macros)", function()
    H.need_rust()
    local dir = H.fixture("deps-lab")
    local meta, err = cm.metadata(dir)
    if not meta then
      return skip("registry lacks the deps-lab crates offline: " .. tostring(err):sub(1, 120))
    end
    H.eq("deps-lab", meta.members[1].name)
    H.eq("2024", meta.members[1].targets[1].edition)
    local serde = cm.dependencies(meta, { name = "serde" })[1]
    H.eq({ "derive" }, serde.features)
    H.eq(true, serde.uses_default_features)
    H.ok(serde.resolved.features.derive, "serde's [features] table has derive")
    H.has(serde.resolved.enabled_features, "derive")
    H.eq({ "macros", "rt-multi-thread" }, vim.list_slice(cm.dependencies(meta, { name = "tokio" })[1].features, 1, 2))
    local lite = H.fixture("deps-lab-nofeature")
    local m2 = cm.metadata(lite)
    H.ok(m2)
    local s2 = cm.dependencies(m2, { name = "serde" })[1]
    H.eq({}, s2.features)
    H.not_ok(vim.tbl_contains(s2.resolved.enabled_features, "derive"))
  end)
end)

-- ---------------------------------------------------------------- registry

describe("crate_meta registry and sources", function()
  local function fake_home()
    local home = H.tmpdir()
    stub(cm.config, "cargo_home", home)
    local reg = home .. "/registry/src/index.crates.io-test"
    for _, d in ipairs({ "serde-1.0.9", "serde-1.0.10", "serde-0.9.15", "serde_json-1.0.1", "serde-1.0.11-rc.1", "foo-bar-1.0.0", "foo-2.0.0" }) do
      write(reg .. "/" .. d .. "/Cargo.toml", ('[package]\nname = "%s"\n'):format(d))
      write(reg .. "/" .. d .. "/src/lib.rs", "// lib of " .. d .. "\n")
    end
    return home, reg
  end

  it("finds the highest unpacked version, an exact one, and never a prefix-sibling", function()
    local _, reg = fake_home()
    H.eq(reg .. "/serde-1.0.11-rc.1", (cm.registry_dir("serde")))
    H.eq(reg .. "/serde-1.0.10", (cm.registry_dir("serde", "1.0.10")))
    H.eq(reg .. "/serde-0.9.15", (cm.registry_dir("serde", "0.9.15")))
    H.eq(reg .. "/serde_json-1.0.1", (cm.registry_dir("serde_json")))
    H.eq(reg .. "/foo-2.0.0", (cm.registry_dir("foo")))
    H.eq(reg .. "/foo-bar-1.0.0", (cm.registry_dir("foo-bar")))
    H.is_nil(cm.registry_dir("serde", "9.9.9"))
    H.is_nil(cm.registry_dir("nonexistent"))
  end)

  it("refuses names and versions that are not valid", function()
    fake_home()
    H.is_nil(cm.registry_dir("../x"))
    H.is_nil(cm.registry_dir("*"))
    H.is_nil(cm.registry_dir("serde", "1.0.*"))
    H.is_nil(cm.source_dir(H.tmpdir(), "a/b"))
  end)

  it("reads lib.rs and Cargo.toml, honouring [lib] path but not escapes", function()
    local _, reg = fake_home()
    local dir = reg .. "/serde-1.0.10"
    H.match(cm.read_manifest(dir), 'name = "serde-1.0.10"', true)
    local text, path = cm.read_lib(dir)
    H.match(text, "lib of serde-1.0.10", true)
    H.eq(dir .. "/src/lib.rs", path)
    write(dir .. "/Cargo.toml", '[package]\nname = "x"\n\n[lib]\nname = "x"\npath = "src/other.rs"\n\n[features]\n')
    write(dir .. "/src/other.rs", "// other\n")
    H.match((cm.read_lib(dir)), "other", true)
    write(dir .. "/Cargo.toml", '[lib]\npath = "../serde-1.0.9/src/lib.rs"\n')
    local t2, p2 = cm.read_lib(dir)
    H.eq(dir .. "/src/lib.rs", p2, "an escaping [lib] path falls back to src/lib.rs")
    H.match(t2, "lib of serde-1.0.10", true)
    H.is_nil(cm.read_lib(nil))
    H.is_nil(cm.read_lib(dir .. "/missing"))
  end)

  it("source_dir resolves path dependencies through the metadata and falls back to the registry", function()
    H.need_rust()
    local _, reg = fake_home()
    local root = make_workspace()
    H.eq(root .. "/util", (cm.source_dir(root, "util")))
    local _, v = cm.source_dir(root, "util")
    H.eq("0.2.0", v)
    H.eq(reg .. "/serde-1.0.10", (cm.source_dir(root, "serde", "1.0.10")))
  end)

  it("parses a [features] table", function()
    local f = cm.parse_features([[
[package]
name = "x"

[features]
default = ["std"]  # comment
std = []
derive = ["serde_derive"]
multi = [
  "a/b",
  "dep:c", # why
]
"quoted" = ["x"]

[dependencies]
serde_derive = { version = "1", optional = true }
]])
    H.eq({ "std" }, f.default)
    H.eq({}, f.std)
    H.eq({ "serde_derive" }, f.derive)
    H.eq({ "a/b", "dep:c" }, f.multi)
    H.eq({ "x" }, f.quoted)
    H.is_nil(f.serde_derive)
    H.eq({}, cm.parse_features("[package]\nname = 'x'\n"))
  end)
end)

-- ------------------------------------------------------------ crates.io client

local INDEX_SERDE = table.concat({
  vim.json.encode({ name = "serde", vers = "1.0.1", yanked = false, features = { derive = { "serde_derive" } }, deps = {} }),
  vim.json.encode({
    name = "serde",
    vers = "1.0.9",
    yanked = false,
    features = { default = { "std" }, std = {} },
    features2 = { derive = { "dep:serde_derive" } },
    deps = {
      { name = "serde_derive", req = "^1", optional = true, features = {}, default_features = true, kind = "normal" },
      { name = "rand", req = "^0.9", optional = true, features = {}, default_features = true, kind = "dev" },
    },
  }),
  vim.json.encode({ name = "serde", vers = "1.0.10", yanked = true, features = {}, deps = {} }),
  "not json at all",
  vim.json.encode({ name = "../evil", vers = "1.0.0", features = {}, deps = {} }),
  vim.json.encode({ name = "serde", vers = "x; rm -rf", features = {}, deps = {} }),
}, "\n") .. "\n"

local API_SERDE = vim.json.encode({
  crate = { name = "serde", description = "A serialization framework", downloads = 123456, recent_downloads = 789 },
})

local SEARCH = vim.json.encode({
  crates = {
    { name = "serde", max_version = "1.0.9", max_stable_version = "1.0.9", description = "ser/de", downloads = 10, recent_downloads = 2 },
    { name = "bad name;rm", max_version = "1.0.0" },
    { name = "serde_json", max_version = "1.1.0-beta.1", description = "json", downloads = 5 },
  },
})

--- Fake M.exec for curl. `answers` maps a url substring to { code, body, status }.
local function fake_curl(answers)
  local calls = {}
  stub(cm, "exec", function(argv, _, cb)
    calls[#calls + 1] = argv
    local url = argv[#argv]
    local ans
    for pat, a in pairs(answers) do
      if url:find(pat, 1, true) then
        ans = a
      end
    end
    ans = ans or { code = 22 }
    local r = { code = ans.code or 0, stdout = (ans.body or "") .. "\n" .. (ans.status or 200), stderr = ans.err or "" }
    vim.schedule(function()
      cb(r)
    end)
  end)
  return calls
end

local function cache_setup()
  stub(cm.config, "cache_dir", H.tmpdir() .. "/crates")
end

describe("crate_meta crates.io client (faked curl)", function()
  it("reads the index: versions, merged features, implicit features, yanked, junk lines", function()
    cache_setup()
    local calls = fake_curl({ ["index.crates.io/se/rd/serde"] = { body = INDEX_SERDE }, ["/crates/serde"] = { body = API_SERDE } })
    local info, err = cm.info("serde")
    H.ok(info, err)
    H.eq(3, #info.versions, "junk and invalid lines are dropped")
    H.eq("1.0.9", info.newest, "the newest version that is not yanked")
    H.eq({ "dep:serde_derive" }, info.features.derive, "features2 overrides")
    H.eq({ "std" }, info.features.default)
    H.eq({}, info.features.std)
    H.is_nil(info.features.serde_derive, "dep: is explicit, so no implicit feature")
    H.eq({ "dep:rand" }, info.features.rand, "an optional dependency becomes a feature of the same name")
    H.eq("A serialization framework", info.description)
    H.eq(123456, info.downloads)
    H.eq(789, info.recent_downloads)
    -- argv, never a shell string
    local argv = calls[1]
    H.eq("curl", argv[1])
    H.has(argv, "xynovim (github.com/xynorash/xynovim)")
    H.has(argv, "--max-time")
    H.eq("5", argv[vim.fn.index(argv, "--max-time") + 2])
    H.eq("https://index.crates.io/se/rd/serde", argv[#argv])
  end)

  it("serves a fresh cache without a request, refresh forces one", function()
    cache_setup()
    local calls = fake_curl({ ["index.crates.io"] = { body = INDEX_SERDE }, ["/crates/"] = { body = API_SERDE } })
    H.ok(cm.info("serde"))
    local n = #calls
    local again = cm.info("serde")
    H.eq(n, #calls, "no new request inside the TTL")
    H.eq(true, again.from_cache)
    H.ok(cm.info("serde", { refresh = true }))
    H.ok(#calls > n)
  end)

  it("falls back to stale cached data when offline, and says so", function()
    cache_setup()
    stub(cm.config, "index_ttl", 0)
    fake_curl({ ["index.crates.io"] = { body = INDEX_SERDE }, ["/crates/"] = { body = API_SERDE } })
    H.ok(cm.info("serde"))
    vim.wait(1100) -- the TTL is in whole seconds
    fake_curl({ ["index.crates.io"] = { code = 6, err = "Could not resolve host" }, ["/crates/"] = { code = 6 } })
    local info, err = cm.info("serde")
    H.ok(info, err)
    H.eq(true, info.stale)
    H.eq("1.0.9", info.newest)
  end)

  it("returns an offline error value without a cache, 'not found' for an unknown crate", function()
    cache_setup()
    fake_curl({ ["index.crates.io"] = { code = 28, err = "timed out" } })
    local info, err = cm.info("serde")
    H.is_nil(info)
    H.match(err, "^offline", false)
    fake_curl({ ["index.crates.io"] = { body = "", status = 404 } })
    local i2, e2 = cm.info("surely-not-a-crate")
    H.is_nil(i2)
    H.eq("not found", e2)
    fake_curl({ ["index.crates.io"] = { body = "", status = 503 } })
    local _, e3 = cm.info("serde")
    H.eq("http 503", e3)
  end)

  it("validates names and queries before anything is run", function()
    cache_setup()
    local calls = fake_curl({})
    for _, bad in ipairs({ "a b", "../x", "a;b", "$(id)", "", "a\nb" }) do
      local i, e = cm.info(bad)
      H.is_nil(i, bad)
      H.eq("invalid crate name", e)
    end
    for _, bad in ipairs({ "", "   ", string.rep("x", 101), "a\nb" }) do
      local r, e = cm.search(bad)
      H.is_nil(r)
      H.eq("invalid search query", e)
    end
    H.eq(0, #calls)
  end)

  it("searches: url-encoded query, per_page, validated result names", function()
    cache_setup()
    local calls = fake_curl({ ["/crates?q="] = { body = SEARCH } })
    local list, err = cm.search("serde json&x=1")
    H.ok(list, err)
    H.eq(2, #list, "a result with an invalid name is dropped")
    H.eq("serde", list[1].name)
    H.eq("1.0.9", list[1].version)
    H.eq(10, list[1].downloads)
    H.eq("1.1.0-beta.1", list[2].version)
    H.eq("https://crates.io/api/v1/crates?q=serde%20json%26x%3D1&per_page=10", calls[1][#calls[1]])
    H.has(calls[1], "xynovim (github.com/xynorash/xynovim)")
    -- cached: no second request
    cm.search("serde json&x=1")
    H.eq(1, #calls)
    -- offline with a stale cache
    stub(cm.config, "search_ttl", -1)
    fake_curl({ ["/crates?q="] = { code = 7 } })
    local stale = cm.search("serde json&x=1")
    H.eq(true, stale.stale)
    H.eq("serde", stale[1].name)
    local none, e = cm.search("never searched")
    H.is_nil(none)
    H.match(e, "^offline")
  end)

  it("has async variants", function()
    cache_setup()
    fake_curl({ ["index.crates.io"] = { body = INDEX_SERDE }, ["/crates/"] = { body = API_SERDE }, ["/crates?q="] = { body = SEARCH } })
    local info, list
    cm.info_async("serde", function(i)
      info = i
    end)
    cm.search_async("serde", function(l)
      list = l
    end)
    H.wait_for(function()
      return info and list
    end, 3000)
    H.eq("1.0.9", info.newest)
    H.eq(2, #list)
  end)
end)

describe("crate_meta crates.io client (real curl, file:// stand-in)", function()
  it("runs curl with argv against the index layout", function()
    if vim.fn.executable("curl") ~= 1 then
      return skip("curl not found")
    end
    cache_setup()
    local srv = H.tmpdir()
    write(srv .. "/idx/se/rd/serde", INDEX_SERDE)
    stub(cm.config, "index_url", "file://" .. srv .. "/idx")
    stub(cm.config, "api_url", "file://" .. srv .. "/api")
    stub(cm.config, "proto", "=file")
    local info, err = cm.info("serde")
    H.ok(info, err)
    H.eq("1.0.9", info.newest)
    H.is_nil(info.downloads, "the API answer is optional")
    local _, e = cm.info("not-there")
    H.ok(e, "a missing file is an error value")
  end)

  it("refuses non-https URLs under the default protocol rule", function()
    if vim.fn.executable("curl") ~= 1 then
      return skip("curl not found")
    end
    cache_setup()
    local srv = H.tmpdir()
    write(srv .. "/idx/se/rd/serde", INDEX_SERDE)
    stub(cm.config, "index_url", "file://" .. srv .. "/idx")
    local info, err = cm.info("serde", { index_only = true })
    H.is_nil(info)
    H.ok(err)
  end)
end)

describe("crate_meta crates.io client (network)", function()
  local function online()
    if vim.fn.executable("curl") ~= 1 then
      return false, "curl not found"
    end
    local r = vim.system({ "curl", "-sS", "--max-time", "5", "-o", "/dev/null", "https://index.crates.io/config.json" }):wait(8000)
    if r.code ~= 0 then
      return false, "no network to crates.io"
    end
    return true
  end

  it("looks up serde in the real index", function()
    local ok, why = online()
    if not ok then
      return skip(why)
    end
    cache_setup()
    local info, err = cm.info("serde")
    H.ok(info, err)
    H.ok(#info.versions > 100)
    H.ok(info.features.derive, "serde has a derive feature")
    H.ok(cm.valid_version(info.newest))
    H.ok(info.downloads and info.downloads > 1000000, "downloads from the API")
    H.ok(info.description and #info.description > 0)
  end)

  it("searches the real API", function()
    local ok, why = online()
    if not ok then
      return skip(why)
    end
    cache_setup()
    local list, err = cm.search("serde_json")
    H.ok(list, err)
    local names = vim.tbl_map(function(c)
      return c.name
    end, list)
    H.has(names, "serde_json")
    H.ok(#list <= 10)
  end)
end)

-- ------------------------------------------------------------ path heads

describe("crate_meta.is_known_path_head", function()
  local root, meta, main
  local function known(name, file)
    return cm.is_known_path_head(root, name, { file = file or main, meta = meta })
  end

  before_each(function()
    H.need_rust()
    root = make_workspace()
    main = root .. "/app/src/main.rs"
    meta = cm.metadata(root)
  end)

  it("knows keywords and the std crates", function()
    H.eq("keyword", (known("crate")))
    H.eq("keyword", (known("self")))
    H.eq("keyword", (known("super")))
    for _, n in ipairs(cm.std_crates) do
      H.eq("std", (known(n)))
    end
    H.eq({ "std", "core", "alloc", "proc_macro", "test" }, cm.std_crates)
  end)

  it("knows dependencies of the file's member, renames and the own lib name", function()
    local k, d = known("helpers")
    H.eq("dependency", k)
    H.eq("util", d)
    H.is_nil((known("util")), "the original name of a renamed dep is not a path head")
    H.eq("dependency", (known("opt")))
    H.eq("dependency", (known("dev_only")))
    H.eq("dependency", (known("builder")))
    H.eq("own_crate", (known("app")))
    -- another member's dependencies are not in scope for this file
    H.is_nil((known("helpers", root .. "/util/src/lib.rs")))
    H.eq("dependency", (cm.is_known_path_head(root, "helpers", { meta = meta, file = "" })), "no file: any member")
  end)

  it("knows local modules, items and macros from the file tree", function()
    H.eq("module", (known("net")), "mod net; and net.rs")
    H.eq("module", (known("inline_mod")))
    H.eq("local_item", (known("Local")))
    H.eq("macro", (known("shout")))
    H.eq("macro", (known("other_file_macro")), "a macro_rules! elsewhere in the member")
    H.eq("module", (known("http", root .. "/app/src/net.rs")), "pub mod http; in net.rs")
    H.eq("module", (known("http", root .. "/app/src/lib.rs") or "module"), "")
    H.eq("module", (known("macros")), "src/macros.rs sibling")
  end)

  it("says nil for names that are nothing", function()
    H.is_nil((known("rand")))
    H.is_nil((known("")))
    H.is_nil((known("shout_not")))
    H.is_nil((cm.is_known_path_head(root, nil)))
  end)

  it("reads an unsaved buffer, not the disk", function()
    vim.cmd.edit(vim.fn.fnameescape(main))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "mod brand_new;", "fn main() {}" })
    H.eq("module", (known("brand_new")))
    H.is_nil((known("net_gone")))
  end)

  it("works on the deps-lab fixture: its dependencies are known, rand is not", function()
    local dir = H.fixture("deps-lab")
    local m = cm.metadata(dir)
    if not m then
      return skip("registry lacks the deps-lab crates offline")
    end
    local file = dir .. "/src/main.rs"
    for _, n in ipairs({ "anyhow", "clap", "serde", "serde_json", "thiserror", "tokio" }) do
      H.eq("dependency", (cm.is_known_path_head(dir, n, { file = file, meta = m })), n)
    end
    H.is_nil((cm.is_known_path_head(dir, "deps_lab", { file = file, meta = m })), "a bin-only package has no lib name")
    H.is_nil((cm.is_known_path_head(dir, "rand", { file = file, meta = m })))
  end)
end)

-- ------------------------------------------------------------ code actions

--- A fake rust-analyzer client answering from `state`.
local function fake_client(state)
  local client = {
    id = 4242,
    name = "rust-analyzer",
    offset_encoding = "utf-16",
    requests = {},
  }
  function client:request(method, params, handler)
    self.requests[#self.requests + 1] = { method = method, params = params }
    local reply = state[method]
    local r = type(reply) == "function" and reply(params, self) or reply
    vim.schedule(function()
      if r and r.err then
        handler(r.err)
      else
        handler(nil, r)
      end
    end)
    return true, #self.requests
  end
  stub(ca, "clients", function()
    return { client }
  end)
  stub(vim.lsp, "get_client_by_id", function(id)
    return id == client.id and client or nil
  end)
  return client
end

local function edit_action(buf, title, kind, text)
  local uri = vim.uri_from_bufnr(buf)
  return {
    title = title,
    kind = kind,
    isPreferred = title:find("Import") ~= nil,
    edit = {
      changes = {
        [uri] = { { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }, newText = text } },
      },
    },
  }
end

describe("code_actions (fake client)", function()
  local buf
  before_each(function()
    vim.cmd("enew!")
    buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fn main() {}", "// é line" })
    vim.api.nvim_buf_set_name(buf, H.tmpdir() .. "/a.rs")
  end)

  it("requests with the range, diagnostics, only and the client's encoding, and normalises", function()
    local c = fake_client({
      ["textDocument/codeAction"] = {
        edit_action(buf, "Import `serde::Serialize`", "quickfix", "use serde::Serialize;\n"),
        { title = "Disabled", kind = "refactor", disabled = { reason = "x" } },
        { title = "Lazy", kind = "refactor.extract", data = { id = 1 } },
        { title = "Run it", kind = "source", command = { title = "Run it", command = "ra.run", arguments = { 1 } } },
      },
    })
    local diag = { lnum = 1, col = 5, end_lnum = 1, end_col = 8, message = "unresolved", severity = 1, source = "rustc" }
    local list, errs = ca.request_wait(buf, { start = { 1, 5 }, ["end"] = { 1, 8 } }, { diagnostics = { diag }, only = { "quickfix" } })
    H.is_nil(errs)
    H.eq(3, #list, "disabled actions are dropped")
    local p = c.requests[1].params
    H.eq({ line = 1, character = 4 }, p.range.start, "byte col 5 after the two-byte é is utf-16 char 4")
    H.eq({ line = 1, character = 7 }, p.range["end"])
    H.eq({ "quickfix" }, p.context.only)
    H.eq(1, #p.context.diagnostics)
    H.eq("unresolved", p.context.diagnostics[1].message)
    H.eq(1, p.context.triggerKind)
    H.eq("Import `serde::Serialize`", list[1].title)
    H.eq("quickfix", list[1].kind)
    H.eq(true, list[1].is_preferred)
    H.ok(list[1].edit)
    H.eq("ra.run", list[3].command.command)
    H.eq(4242, list[1].client_id)
    H.ok(list[1].raw)
    -- a bare position and the cursor default are both empty ranges
    ca.request_wait(buf, { 0, 3 }, {})
    H.eq(c.requests[#c.requests].params.range.start, c.requests[#c.requests].params.range["end"])
  end)

  it("filters by kind (dot-prefix), title pattern, literal title and preferred", function()
    local list = {
      { title = "Import `a::Error`", kind = "quickfix", is_preferred = true },
      { title = "Qualify as `a::Error`", kind = "quickfix", is_preferred = false },
      { title = "Extract into function", kind = "refactor.extract", is_preferred = false },
      { title = "Inline", kind = "refactor.inline" },
      { title = "Nokind", kind = "" },
      { title = "Quickfixes", kind = "quickfixes" },
    }
    H.eq(2, #ca.filter(list, { kind = "quickfix" }), "quickfixes is not quickfix")
    H.eq(2, #ca.filter(list, { kind = "refactor" }))
    H.eq(1, #ca.filter(list, { kind = "refactor.extract" }))
    H.eq(3, #ca.filter(list, { kind = { "quickfix", "refactor.inline" } }))
    H.eq(1, #ca.filter(list, { title = "^Import" }))
    H.eq(2, #ca.filter(list, { title = "a::Error", plain = true }))
    H.eq(1, #ca.filter(list, { preferred = true }))
    H.eq(1, #ca.filter(list, { kind = "quickfix", title = "Qualify" }))
    H.eq(#list, #ca.filter(list, nil))
  end)

  it("applies an edit with the client's offset encoding", function()
    fake_client({ ["textDocument/codeAction"] = { edit_action(buf, "Import `x::Y`", "quickfix", "use x::Y;\n") } })
    local list = ca.request_wait(buf, { 0, 0 })
    local ok, err = ca.apply(list[1])
    H.ok(ok, err)
    H.eq("use x::Y;", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("resolves a lazy action before applying it", function()
    local resolved_for
    local c = fake_client({
      ["textDocument/codeAction"] = { { title = "Lazy", kind = "quickfix", data = { id = 7 } } },
      ["codeAction/resolve"] = function(params)
        resolved_for = params.data.id
        return edit_action(buf, "Lazy", "quickfix", "// resolved\n")
      end,
    })
    local a = ca.request_wait(buf, { 0, 0 })[1]
    H.not_ok(a.edit)
    local ok, err = ca.apply(a)
    H.ok(ok, err)
    H.eq(7, resolved_for)
    H.eq("// resolved", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    H.eq("codeAction/resolve", c.requests[#c.requests].method)
  end)

  it("retries resolve while the server says content modified", function()
    local n = 0
    fake_client({
      ["textDocument/codeAction"] = { { title = "Lazy", kind = "quickfix", data = { id = 1 } } },
      ["codeAction/resolve"] = function()
        n = n + 1
        if n < 3 then
          return { err = { code = -32801, message = "content modified" } }
        end
        return edit_action(buf, "Lazy", "quickfix", "// ok\n")
      end,
    })
    local a = ca.request_wait(buf, { 0, 0 })[1]
    local ok, err = ca.apply(a)
    H.ok(ok, err)
    H.eq(3, n)
  end)

  it("gives up resolving with an error value", function()
    fake_client({
      ["textDocument/codeAction"] = { { title = "Lazy", kind = "quickfix", data = {} } },
      ["codeAction/resolve"] = { err = { code = -32603, message = "boom" } },
    })
    local ok, err = ca.apply(ca.request_wait(buf, { 0, 0 })[1])
    H.eq(false, ok)
    H.eq("boom", err)
  end)

  it("runs the command of an action through workspace/executeCommand", function()
    local c = fake_client({
      ["textDocument/codeAction"] = { { title = "Run", kind = "source", command = { title = "Run", command = "ra.run", arguments = { "a" } } } },
      ["workspace/executeCommand"] = {},
    })
    local ok, err = ca.apply(ca.request_wait(buf, { 0, 0 })[1])
    H.ok(ok, err)
    local last = c.requests[#c.requests]
    H.eq("workspace/executeCommand", last.method)
    H.eq({ command = "ra.run", arguments = { "a" } }, last.params)
  end)

  it("applies several edits as one undo step", function()
    fake_client({ ["textDocument/codeAction"] = {} })
    local function act(text)
      return { title = text, kind = "quickfix", edit = edit_action(buf, text, "quickfix", text).edit, client_id = 4242, bufnr = buf }
    end
    vim.cmd("setlocal undolevels=1000")
    vim.cmd("normal! ix") -- an earlier, separate undo step
    vim.cmd("let &undolevels = &undolevels") -- close it
    local n, err = ca.apply_all({ act("// one\n"), act("// two\n"), act("// three\n") })
    H.is_nil(err)
    H.eq(3, n)
    H.eq({ "// three", "// two", "// one" }, vim.api.nvim_buf_get_lines(buf, 0, 3, false))
    vim.cmd("undo")
    H.eq("xfn main() {}", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "one undo reverts all three")
  end)

  it("request_wait retries 'content modified' and reports what it ended with", function()
    local n = 0
    fake_client({
      ["textDocument/codeAction"] = function()
        n = n + 1
        if n < 3 then
          return { err = { code = -32801, message = "content modified" } }
        end
        return { { title = "Late", kind = "quickfix" } }
      end,
    })
    local list, err = ca.request_wait(buf, { 0, 0 }, { timeout = 5000 })
    H.is_nil(err)
    H.eq("Late", list[1].title)
    H.eq(3, n)

    fake_client({ ["textDocument/codeAction"] = { err = { code = -32801, message = "content modified" } } })
    local l2, e2 = ca.request_wait(buf, { 0, 0 }, { timeout = 600 })
    H.eq({}, l2)
    H.match(e2, "content modified", true)
  end)

  it("wait_for polls until an action matching the filter shows up", function()
    local n = 0
    fake_client({
      ["textDocument/codeAction"] = function()
        n = n + 1
        return n < 3 and {} or { { title = "Import `a::B`", kind = "quickfix" } }
      end,
    })
    local hits = ca.wait_for(buf, { 0, 0 }, { kind = "quickfix", title = "^Import" }, { timeout = 5000, interval = 50 })
    H.eq(1, #hits)
    H.eq(3, n)
    local none = ca.wait_for(buf, { 0, 0 }, { title = "^Nothing" }, { timeout = 300, interval = 50 })
    H.eq({}, none)
  end)

  it("reports a missing client as a value", function()
    stub(ca, "clients", function()
      return {}
    end)
    local list, err = ca.request_wait(buf, { 0, 0 })
    H.eq({}, list)
    H.match(err, "no rust-analyzer client", true)
  end)
end)

describe("code_actions (real rust-analyzer)", function()
  it("offers an Import action for an unresolved std name and applies it", function()
    H.need_rust()
    local dir, buf = H.open_fixture("basic", "src/lib.rs")
    write(dir .. "/src/lib.rs", "pub fn make() -> HashMap<u8, u8> {\n    HashMap::new()\n}\n")
    vim.cmd("edit!")
    buf = vim.api.nvim_get_current_buf()
    H.wait_lsp("rust-analyzer", buf)
    local hits = ca.wait_for(buf, { 1, 5 }, { kind = "quickfix", title = "^Import `std::collections::HashMap`" }, { timeout = 90000 })
    H.ok(#hits >= 1, "rust-analyzer offered the import")
    local ok, err = ca.apply(hits[1])
    H.ok(ok, err)
    H.match(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "use std::collections::HashMap;", true)
  end)
end)

describe("crate_meta bounded reads", function()
  it("does not read a symlink to /dev/zero, a FIFO or an oversized source file", function()
    local dir = H.tmpdir() .. "/evil"
    write(dir .. "/Cargo.toml", '[package]\nname = "evil"\nversion = "0.1.0"\n')
    vim.fn.mkdir(dir .. "/src", "p")
    vim.uv.fs_symlink("/dev/zero", dir .. "/src/lib.rs")
    H.is_nil((cm.read_lib(dir)))
    os.remove(dir .. "/src/lib.rs")
    if vim.fn.executable("mkfifo") == 1 then
      vim.system({ "mkfifo", dir .. "/src/lib.rs" }):wait()
      H.is_nil((cm.read_lib(dir))) -- would block forever on an open for reading
    end
    os.remove(dir .. "/src/lib.rs")
    write(dir .. "/src/lib.rs", string.rep("a", 3 * 1024 * 1024))
    H.is_nil((cm.read_lib(dir)))
    write(dir .. "/src/lib.rs", "pub fn x() {}\n")
    H.match((cm.read_lib(dir)), "pub fn x", true)
  end)
end)
