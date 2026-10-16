-- xyno-timeout: 300
-- config.rust_new (:RustNewBin, :RustNewLib, :RustNewWorkspace, :RustNewMember and the three
-- dashboard entries) and lua/plugins/rust-new.lua. Pure functions first, then the flows with the
-- REAL cargo in temp directories (cargo new works offline), the failure paths (stub cargo / empty
-- PATH / read-only parent), and the dashboard rendered in tmux at several window sizes.
local H = require("xynotest.helpers")
local R = require("config.rust_new")
local E = require("config.egui_new")

-- ------------------------------------------------------------------ helpers

local restores = {}
local function stub(t, k, v)
  local orig = t[k]
  t[k] = v
  restores[#restores + 1] = function()
    t[k] = orig
  end
end

local function need_cargo()
  if vim.fn.executable("cargo") ~= 1 then
    return skip("cargo not found")
  end
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local saved_g, saved_path = {}, vim.env.PATH
before_each(function()
  R.reset_edition()
  saved_g.dir = vim.g.xynovim_projects_dir
  vim.g.xynovim_projects_dir = nil
end)

after_each(function()
  -- a run still in flight (a test that stopped early) must not leak into the next one
  pcall(H.wait_for, function()
    return not R.running()
  end, 60000, "the run to finish")
  for i = #restores, 1, -1 do
    pcall(restores[i])
  end
  restores = {}
  vim.env.PATH = saved_path
  vim.g.xynovim_projects_dir = saved_g.dir
  -- opening a generated main.rs starts the Rust language servers
  pcall(function()
    for _, c in ipairs(vim.lsp.get_clients()) do
      c:stop(true)
    end
  end)
  pcall(vim.cmd, "silent! %bwipeout!")
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
end)

--- Answer vim.ui.input from a list (false = cancel); returns the log of the prompts.
local function stub_input(answers)
  local log = {}
  stub(vim.ui, "input", function(opts, cb)
    log[#log + 1] = opts
    local a = table.remove(answers, 1)
    if a == nil then
      error("unexpected prompt: " .. tostring(opts.prompt))
    end
    if a == false then
      return cb(nil)
    end
    cb(a)
  end)
  return log
end

--- Answer vim.ui.select from a list (false = cancel).
local function stub_select(answers)
  local log = {}
  stub(vim.ui, "select", function(items, opts, cb)
    log[#log + 1] = { items = items, opts = opts }
    local a = table.remove(answers, 1)
    if a == nil then
      error("unexpected select: " .. tostring(opts.prompt))
    end
    if a == false then
      return cb(nil)
    end
    cb(a, vim.fn.index(items, a) + 1)
  end)
  return log
end

local function find_msg(cap, pat, level)
  for _, m in ipairs(cap.list) do
    if tostring(m.msg):find(pat, 1, true) and (not level or m.level == level) then
      return m
    end
  end
end

local function wait_cb(fn)
  local done
  fn(function(err, info)
    done = { err, info }
  end)
  H.wait_for(function()
    return done ~= nil
  end, 60000, "the run did not finish")
  return done[1], done[2]
end

local function run(cmd, cwd)
  return vim.system(cmd, { cwd = cwd, text = true }):wait(60000)
end

--- Real cargo's Cargo.toml for a new project (edition as installed).
local function real_cargo_toml(kind)
  local tmp = H.tmpdir()
  local r = run({ "cargo", "new", "--vcs", "none", kind, "probe" }, tmp)
  H.eq(0, r.code, r.stderr)
  return read(tmp .. "/probe/Cargo.toml")
end

--- A directory holding a `cargo` stub (script body) first on PATH.
local function stub_cargo(body)
  local d = H.tmpdir()
  write(d .. "/cargo", "#!/bin/sh\n" .. body .. "\n")
  vim.uv.fs_chmod(d .. "/cargo", 493)
  vim.env.PATH = d .. ":" .. saved_path
  return d
end

-- ============================================================ pure functions

describe("rust_new.name", function()
  it("accepts hyphens (cargo does) and keeps the name as typed", function()
    local name, crate = R.name(" my-app ")
    H.eq("my-app", name)
    H.eq("my_app", crate)
    H.eq("tool", (R.name("tool")))
    H.eq("_x1", (R.name("_x1")))
  end)

  it("applies the same cargo rules as the egui flow (shared function)", function()
    for _, bad in ipairs({
      "",
      "   ",
      "1abc",
      "my app",
      "my.app",
      "é",
      "fn",
      "self",
      "async",
      "test",
      "core",
      "std",
      "alloc",
      "proc_macro",
      "deps",
      "_",
      ("a"):rep(65),
      "-x",
      "--vcs",
      "-",
    }) do
      local n, why = R.name(bad)
      H.is_nil(n, "'" .. bad .. "' must be refused")
      H.ok(type(why) == "string" and why ~= "", "a reason for '" .. bad .. "'")
      -- the egui flow shares the cargo part: it refuses everything except the leading dash,
      -- which it only knows through its '_' conversion
      if not bad:match("^%-") then
        local c1 = E.cargo_name(bad)
        H.is_nil(c1)
      end
    end
    H.ok(R.name(("a"):rep(64)), "64 characters are fine")
    local crate, _, note = E.cargo_name("my-lib")
    H.eq("my_lib", crate)
    H.eq("crate name: my_lib", note)
  end)

  it("does not carry the egui template's own restrictions", function()
    H.ok(R.name("egui"))
    H.ok(R.name("eframe_template"))
    H.is_nil((E.validate_name("egui")), "the egui flow still refuses its dependencies")
  end)

  it("shows the library's crate identifier only when it differs", function()
    local _, crate = R.name("my-lib")
    H.match(R.lib_note("my-lib", crate), "my_lib", true)
    H.is_nil(R.lib_note("mylib", "mylib"))
  end)
end)

describe("rust_new.first_line", function()
  it("prefers the error line, else the first line", function()
    H.eq("error: boom", R.first_line("warning: x\nerror: boom\nmore"))
    H.eq("warning: x", R.first_line("\n  warning: x \nnote: y"))
    H.eq("no output", R.first_line(""))
    H.eq("no output", R.first_line(nil))
  end)
end)

describe("rust_new editions and the workspace Cargo.toml", function()
  it("reads the edition of a generated Cargo.toml's [package] only", function()
    H.eq("2021", R.parse_edition('[package]\nname = "a"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n'))
    H.is_nil(R.parse_edition('[workspace.package]\nedition = "2021"\n[package]\nname = "a"\n'))
    H.is_nil(R.parse_edition(""))
  end)

  it("resolver 3 from edition 2024 on, else 2", function()
    H.eq("2", R.resolver("2015"))
    H.eq("2", R.resolver("2018"))
    H.eq("2", R.resolver("2021"))
    H.eq("3", R.resolver("2024"))
    H.eq("3", R.resolver("2027"))
    H.eq("2", R.resolver(nil))
  end)

  it("builds the manifest for 2018, 2021 and 2024", function()
    for ed, resolver in pairs({ ["2018"] = "2", ["2021"] = "2", ["2024"] = "3" }) do
      H.eq(
        table.concat({
          "[workspace]",
          'resolver = "' .. resolver .. '"',
          'members = ["crates/*"]',
          "",
          "[workspace.package]",
          'version = "0.1.0"',
          'edition = "' .. ed .. '"',
          "",
          "[workspace.dependencies]",
          "",
        }, "\n"),
        R.workspace_toml(ed)
      )
    end
  end)
end)

describe("rust_new.inherit", function()
  local SAMPLE = '[package]\nname = "my-app"\nversion = "0.1.0"\nedition = "2024"\n\n[dependencies]\n'

  it("rewrites version and edition of cargo's own output, nothing else", function()
    H.eq('[package]\nname = "my-app"\nversion.workspace = true\nedition.workspace = true\n\n[dependencies]\n', R.inherit(SAMPLE))
  end)

  it("works on the text the installed cargo really writes", function()
    need_cargo()
    for _, kind in ipairs({ "--bin", "--lib" }) do
      local text = real_cargo_toml(kind)
      local out = R.inherit(text)
      H.has(out, "version.workspace = true")
      H.has(out, "edition.workspace = true")
      H.no_match(out, 'version = "', true)
      H.no_match(out, 'edition = "', true)
      -- every other line is untouched
      local keep = vim.tbl_filter(function(l)
        return not l:match("^version") and not l:match("^edition")
      end, vim.split(text, "\n", { plain = true }))
      local keep2 = vim.tbl_filter(function(l)
        return not l:match("^version") and not l:match("^edition")
      end, vim.split(out, "\n", { plain = true }))
      H.eq(keep, keep2)
    end
  end)

  it("only the keys asked for, only in [package], comments and CRLF kept", function()
    local t = '[package]\nname = "a"\nversion = "1.2.3" # keep\nedition = "2021"\n[dependencies]\nversion = "9"\n'
    H.eq(
      '[package]\nname = "a"\nversion.workspace = true # keep\nedition = "2021"\n[dependencies]\nversion = "9"\n',
      R.inherit(t, { version = true })
    )
    H.eq('[package]\r\nname = "a"\r\nversion.workspace = true\r\n', R.inherit('[package]\r\nname = "a"\r\nversion = "1"\r\n'))
    H.eq(SAMPLE, R.inherit(SAMPLE, {}))
  end)
end)

describe("rust_new.workspace_info / add_member_path", function()
  it("reads glob and explicit lists and the directory for new members", function()
    local g = R.workspace_info('[workspace]\nmembers = ["crates/*"]\n')
    H.eq({ "crates/*" }, g.members)
    H.eq("crates", g.dir)
    local g2 = R.workspace_info('[workspace]\nresolver = "2"\nmembers = [\n  "libs/*", # all libs\n  "tools/x",\n]\n')
    H.eq({ "libs/*", "tools/x" }, g2.members)
    H.eq("libs", g2.dir)
    local g3 = R.workspace_info("[workspace]\nmembers = ['a', \"b\"]\n")
    H.eq({ "a", "b" }, g3.members)
    H.eq("crates", g3.dir)
  end)

  it("tells which keys [workspace.package] provides", function()
    local i = R.workspace_info('[workspace]\nmembers = ["a"]\n[workspace.package]\nversion = "1"\n')
    H.eq({ version = true }, i.inherits)
  end)

  it("refuses without a members list", function()
    for _, t in ipairs({
      '[package]\nname = "a"\n',
      "[workspace]\n",
      '[workspace]\nresolver = "2"\n',
      '[package]\nmembers = ["x"]\n',
      '[workspace]\nmembers = ["a"\n',
    }) do
      local i, why = R.workspace_info(t)
      H.is_nil(i)
      H.ok(why and why ~= "")
    end
  end)

  it("adds to a one-line list, keeping everything else", function()
    H.eq('[workspace]\nmembers = ["a", "crates/n"]\n', R.add_member_path('[workspace]\nmembers = ["a"]\n', "crates/n"))
    H.eq('[workspace]\nmembers = [ "a", "crates/n" ]\n', R.add_member_path('[workspace]\nmembers = [ "a" ]\n', "crates/n"))
    H.eq('[workspace]\nmembers = ["crates/n"]\n', R.add_member_path("[workspace]\nmembers = []\n", "crates/n"))
    H.eq('[workspace]\nmembers = ["a", "crates/n"]\n', R.add_member_path('[workspace]\nmembers = ["a",]\n', "crates/n"))
  end)

  it("adds a line to a multi-line list with its indent, comma and comments", function()
    local t = '[workspace]\nresolver = "2"\nmembers = [\n    "a",\n    "b" # last\n]\n\n[workspace.package]\nversion = "0.1.0"\n'
    H.eq(
      '[workspace]\nresolver = "2"\nmembers = [\n    "a",\n    "b", # last\n    "crates/n",\n]\n\n[workspace.package]\nversion = "0.1.0"\n',
      R.add_member_path(t, "crates/n")
    )
    local t2 = "[workspace]\nmembers = [\n\t'a',\n\t'b',\n]\n"
    H.eq("[workspace]\nmembers = [\n\t'a',\n\t'b',\n\t\"crates/n\",\n]\n", R.add_member_path(t2, "crates/n"))
    H.eq('[workspace]\nmembers = [\n  "crates/n",\n]\n', R.add_member_path("[workspace]\nmembers = [\n]\n", "crates/n"))
  end)

  it("does nothing when an entry already covers the path", function()
    local t = '[workspace]\nmembers = ["crates/*", "x"]\n'
    H.eq(t, R.add_member_path(t, "crates/n"))
    H.eq(t, R.add_member_path(t, "x"))
    H.eq('[workspace]\nmembers = ["crates/*", "x", "libs/n"]\n', R.add_member_path(t, "libs/n"))
  end)

  it("only touches the [workspace] table's list", function()
    local t = '[package]\nmembers = ["p"]\n[workspace]\nmembers = ["a"]\n'
    H.eq('[package]\nmembers = ["p"]\n[workspace]\nmembers = ["a", "crates/n"]\n', R.add_member_path(t, "crates/n"))
    local i, why = R.add_member_path("[workspace]\n", "crates/n")
    H.is_nil(i)
    H.ok(why)
  end)
end)

-- ================================================ flows with the real cargo

describe("rust_new.create_project (real cargo)", function()
  before_each(need_cargo)

  it("a binary: cargo new --bin with a git repository, hyphens kept", function()
    local parent = H.tmpdir()
    local err, info = wait_cb(function(cb)
      R.create_project({ name = "my-app", parent = parent, kind = "binary" }, cb)
    end)
    H.is_nil(err)
    H.eq(parent .. "/my-app", info.dir)
    H.ok(vim.uv.fs_stat(parent .. "/my-app/src/main.rs"))
    H.is_nil(vim.uv.fs_stat(parent .. "/my-app/src/lib.rs"))
    H.ok(vim.uv.fs_stat(parent .. "/my-app/.git"), "a repository exists")
    H.has(read(parent .. "/my-app/Cargo.toml"), 'name = "my-app"')
    H.eq(0, run({ "cargo", "check", "--offline" }, parent .. "/my-app").code)
  end)

  it("a library: src/lib.rs, same repository", function()
    local parent = H.tmpdir()
    local err, info = wait_cb(function(cb)
      R.create_project({ name = "my-lib", parent = parent, kind = "library" }, cb)
    end)
    H.is_nil(err)
    H.eq(parent .. "/my-lib/src/lib.rs", info.file)
    H.ok(vim.uv.fs_stat(info.file))
    H.is_nil(vim.uv.fs_stat(parent .. "/my-lib/src/main.rs"))
    H.ok(vim.uv.fs_stat(parent .. "/my-lib/.git"))
  end)

  it("uses the edition of the installed cargo, never a fixed one", function()
    local parent = H.tmpdir()
    local err = wait_cb(function(cb)
      R.create_project({ name = "ed", parent = parent, kind = "binary" }, cb)
    end)
    H.is_nil(err)
    H.eq(R.parse_edition(real_cargo_toml("--bin")), R.parse_edition(read(parent .. "/ed/Cargo.toml")))
  end)

  it("creates missing parent directories", function()
    local parent = H.tmpdir() .. "/a/b"
    local err = wait_cb(function(cb)
      R.create_project({ name = "x", parent = parent, kind = "binary" }, cb)
    end)
    H.is_nil(err)
    H.ok(vim.uv.fs_stat(parent .. "/x/Cargo.toml"))
  end)
end)

describe("rust_new.create_workspace (real cargo)", function()
  before_each(need_cargo)

  local function ws(parent, name, kind, member)
    return wait_cb(function(cb)
      R.create_workspace({ name = name, parent = parent, kind = kind, member = member }, cb)
    end)
  end

  it("builds the layout with a binary member and inherited version / edition", function()
    local parent = H.tmpdir()
    local err, info = ws(parent, "my-ws", "binary", "my-ws-app")
    H.is_nil(err)
    local root = parent .. "/my-ws"
    H.eq(root, info.dir)
    H.eq(root .. "/crates/my-ws-app/src/main.rs", info.file)
    local top = read(root .. "/Cargo.toml")
    local edition = R.parse_edition(real_cargo_toml("--bin"))
    H.eq(R.workspace_toml(edition), top)
    H.eq(R.resolver(edition), info.resolver)
    H.eq("/target\n", read(root .. "/.gitignore"))
    H.eq(
      '[package]\nname = "my-ws-app"\nversion.workspace = true\nedition.workspace = true\n\n[dependencies]\n',
      read(root .. "/crates/my-ws-app/Cargo.toml")
    )
    H.ok(vim.uv.fs_stat(root .. "/.git"), "git init")
    H.is_nil(vim.uv.fs_stat(root .. "/crates/my-ws-app/.git"), "no repository inside the member")
    H.eq("main", vim.trim(run({ "git", "symbolic-ref", "--short", "HEAD" }, root).stdout))
    H.eq("", vim.trim(run({ "git", "log", "--oneline" }, root).stdout), "no commit")
  end)

  it("workspace_members in cargo metadata and a clean cargo check with a binary and a library", function()
    local parent = H.tmpdir()
    H.is_nil((ws(parent, "w", "binary", "w-app")))
    local root = parent .. "/w"
    local err = wait_cb(function(cb)
      R.create_member({ root = root, kind = "library", name = "w-core", taken = {} }, cb)
    end)
    H.is_nil(err)
    local meta = run({ "cargo", "metadata", "--no-deps", "--offline", "--format-version", "1" }, root)
    H.eq(0, meta.code, meta.stderr)
    local m = vim.json.decode(meta.stdout)
    H.eq(2, #m.workspace_members)
    local names = {}
    for _, p in ipairs(m.packages) do
      names[#names + 1] = p.name
    end
    table.sort(names)
    H.eq({ "w-app", "w-core" }, names)
    for _, p in ipairs(m.packages) do
      H.eq(R.parse_edition(read(root .. "/Cargo.toml"):gsub("%[workspace.package%]", "[package]")), p.edition)
      H.eq("0.1.0", p.version)
    end
    local check = run({ "cargo", "check", "--offline" }, root)
    H.eq(0, check.code, check.stderr)
    H.eq(root, m.workspace_root)
  end)

  it("a library first member", function()
    local parent = H.tmpdir()
    local err, info = ws(parent, "libws", "library", "libws-core")
    H.is_nil(err)
    H.eq(parent .. "/libws/crates/libws-core/src/lib.rs", info.file)
    H.ok(vim.uv.fs_stat(info.file))
    H.eq(0, run({ "cargo", "check", "--offline" }, parent .. "/libws").code)
  end)

  it("resolver follows the edition cargo reports (stub cargo for 2021 and 2018)", function()
    local real = vim.fn.exepath("cargo")
    for ed, resolver in pairs({ ["2021"] = "2", ["2018"] = "2" }) do
      R.reset_edition()
      vim.env.PATH = saved_path
      local d = H.tmpdir()
      write(
        d .. "/cargo",
        ([[#!/bin/sh
"%s" "$@" || exit $?
for a in "$@"; do last=$a; done
# rewrite the edition cargo wrote, as if this were an older cargo
f="$last/Cargo.toml"; [ -f "$f" ] || f="$PWD/$last/Cargo.toml"
sed -i 's/^edition = .*/edition = "%s"/' "$f"
]]):format(real, ed)
      )
      vim.uv.fs_chmod(d .. "/cargo", 493)
      vim.env.PATH = d .. ":" .. saved_path
      local parent = H.tmpdir()
      local err, info = ws(parent, "old", "binary", "old-app")
      H.is_nil(err, ed)
      H.eq(ed, info.edition)
      H.eq(resolver, info.resolver)
      H.has(read(parent .. "/old/Cargo.toml"), 'resolver = "' .. resolver .. '"')
      H.has(read(parent .. "/old/Cargo.toml"), 'edition = "' .. ed .. '"')
    end
  end)

  it("asks cargo for the edition once per session", function()
    local calls = H.tmpdir() .. "/calls"
    local real = vim.fn.exepath("cargo")
    local d = H.tmpdir()
    write(d .. "/cargo", ('#!/bin/sh\necho x >> "%s"\nexec "%s" "$@"\n'):format(calls, real))
    vim.uv.fs_chmod(d .. "/cargo", 493)
    vim.env.PATH = d .. ":" .. saved_path
    local parent = H.tmpdir()
    H.is_nil((ws(parent, "one", "binary", "one-app")))
    H.is_nil((ws(parent, "two", "binary", "two-app")))
    -- per workspace: the cargo new of the member; the edition probe ran once in total
    local n = #vim.split(vim.trim(read(calls)), "\n", { plain = true })
    H.eq(3, n)
  end)
end)

describe("rust_new.create_member (real cargo)", function()
  before_each(need_cargo)

  local function member(root, kind, name, taken)
    return wait_cb(function(cb)
      R.create_member({ root = root, kind = kind, name = name, taken = taken or {} }, cb)
    end)
  end

  it("glob members: the manifest is not edited, the member inherits", function()
    local parent = H.tmpdir()
    H.is_nil((wait_cb(function(cb)
      R.create_workspace({ name = "g", parent = parent, kind = "binary", member = "g-app" }, cb)
    end)))
    local before = read(parent .. "/g/Cargo.toml")
    local err, info = member(parent .. "/g", "library", "more-things")
    H.is_nil(err)
    H.eq(before, read(parent .. "/g/Cargo.toml"))
    H.eq("crates/more-things", info.rel)
    H.has(read(parent .. "/g/crates/more-things/Cargo.toml"), "edition.workspace = true")
    H.eq(0, run({ "cargo", "check", "--offline" }, parent .. "/g").code)
  end)

  it("explicit list: the path is added once, formatting kept; a [workspace.package] without edition is respected", function()
    local root = H.tmpdir()
    write(
      root .. "/Cargo.toml",
      '[workspace]\nresolver = "2"\nmembers = [\n    "crates/a",\n]\n\n[workspace.package]\nversion = "0.3.0"\n'
    )
    write(root .. "/crates/a/Cargo.toml", '[package]\nname = "a"\nversion.workspace = true\nedition = "2021"\n')
    write(root .. "/crates/a/src/lib.rs", "")
    local err, info = member(root, "binary", "b-two")
    H.is_nil(err)
    local top = read(root .. "/Cargo.toml")
    H.eq(1, select(2, top:gsub('"crates/b%-two"', "")), top)
    H.has(top, '    "crates/a",\n    "crates/b-two",\n]')
    H.eq({ "edition" }, info.not_inherited)
    local pkg = read(root .. "/crates/b-two/Cargo.toml")
    H.has(pkg, "version.workspace = true")
    H.match(pkg, 'edition = "%d+"')
    local meta = run({ "cargo", "metadata", "--no-deps", "--offline", "--format-version", "1" }, root)
    H.eq(0, meta.code, meta.stderr)
    H.eq(2, #vim.json.decode(meta.stdout).workspace_members)
  end)

  it("rejects a name that collides with an existing member (hyphen or underscore) and a taken directory", function()
    local parent = H.tmpdir()
    H.is_nil((wait_cb(function(cb)
      R.create_workspace({ name = "c", parent = parent, kind = "library", member = "my-core" }, cb)
    end)))
    local before = read(parent .. "/c/Cargo.toml")
    local err = member(parent .. "/c", "library", "my_core", { my_core = true })
    H.match(err, "exists already", true)
    err = member(parent .. "/c", "binary", "my-core", {})
    H.match(err, "already exists", true)
    H.eq(before, read(parent .. "/c/Cargo.toml"))
    H.eq({ "my-core" }, vim.fn.readdir(parent .. "/c/crates"))
  end)

  it("refuses a manifest without a members list and restores the manifest when cargo fails", function()
    local root = H.tmpdir()
    write(root .. "/Cargo.toml", '[package]\nname = "p"\nversion = "0.1.0"\n')
    local err = member(root, "binary", "x")
    H.match(err, "not a workspace", true)
    H.is_nil(vim.uv.fs_stat(root .. "/crates"))

    local ws_root = H.tmpdir()
    local text = '[workspace]\nmembers = ["a"]\n'
    write(ws_root .. "/Cargo.toml", text)
    stub_cargo('echo "error: member boom" >&2\nexit 101')
    err = member(ws_root, "binary", "x")
    H.match(err, "error: member boom", true)
    H.eq(text, read(ws_root .. "/Cargo.toml"))
    H.is_nil(vim.uv.fs_stat(ws_root .. "/crates/x"))
  end)
end)

-- ============================================================ failure paths

describe("rust_new failure paths", function()
  it("an existing target is refused and left alone", function()
    need_cargo()
    local parent = H.tmpdir()
    write(parent .. "/there/keep.txt", "k")
    for _, kind in ipairs({ "binary", "library" }) do
      local err = wait_cb(function(cb)
        R.create_project({ name = "there", parent = parent, kind = kind }, cb)
      end)
      H.match(err, "already exists", true)
    end
    local err = wait_cb(function(cb)
      R.create_workspace({ name = "there", parent = parent, kind = "binary", member = "m" }, cb)
    end)
    H.match(err, "already exists", true)
    H.eq("k", read(parent .. "/there/keep.txt"))
    H.eq({ "keep.txt" }, vim.fn.readdir(parent .. "/there"))
  end)

  it("an invalid name or kind never reaches cargo", function()
    local parent = H.tmpdir()
    stub_cargo('echo called >> "' .. parent .. '/called"')
    for _, n in ipairs({ "", "fn", "-x", "a b", "test" }) do
      local err = wait_cb(function(cb)
        R.create_project({ name = n, parent = parent, kind = "binary" }, cb)
      end)
      H.match(err, "invalid name", true)
      err = wait_cb(function(cb)
        R.create_workspace({ name = n, parent = parent, kind = "binary", member = "ok" }, cb)
      end)
      H.match(err, "invalid workspace name", true)
      err = wait_cb(function(cb)
        R.create_workspace({ name = "okws", parent = parent, kind = "binary", member = n }, cb)
      end)
      H.match(err, "invalid member name", true)
    end
    local err = wait_cb(function(cb)
      R.create_project({ name = "ok", parent = parent, kind = "both" }, cb)
    end)
    H.match(err, "unknown kind", true)
    H.is_nil(vim.uv.fs_stat(parent .. "/called"))
    H.eq({}, vim.fn.readdir(parent))
  end)

  it("cargo missing: a clear error and nothing created, parents included", function()
    local parent = H.tmpdir()
    local empty = H.tmpdir()
    vim.env.PATH = empty
    for _, f in ipairs({
      function(cb)
        R.create_project({ name = "a", parent = parent .. "/p/q", kind = "binary" }, cb)
      end,
      function(cb)
        R.create_workspace({ name = "a", parent = parent .. "/p/q", kind = "binary", member = "m" }, cb)
      end,
      function(cb)
        R.create_member({ root = parent, kind = "binary", name = "m" }, cb)
      end,
    }) do
      local err = wait_cb(f)
      H.eq("cargo not found", err)
    end
    H.eq({}, vim.fn.readdir(parent))
  end)

  it("cargo failing: its first stderr line, no directory left (project, workspace)", function()
    local parent = H.tmpdir()
    stub_cargo('echo "error: the stub says no" >&2\necho "second line" >&2\nexit 101')
    local err = wait_cb(function(cb)
      R.create_project({ name = "boom", parent = parent .. "/new/dir", kind = "binary" }, cb)
    end)
    H.eq("cargo new failed: error: the stub says no", err)
    H.eq({}, vim.fn.readdir(parent))
    -- the edition probe is the first cargo call of a workspace
    R.reset_edition()
    err = wait_cb(function(cb)
      R.create_workspace({ name = "boom", parent = parent .. "/new/dir", kind = "binary", member = "m" }, cb)
    end)
    H.match(err, "error: the stub says no", true)
    H.eq({}, vim.fn.readdir(parent))
  end)

  it("a workspace whose member step fails leaves no directory behind", function()
    need_cargo()
    local real = vim.fn.exepath("cargo")
    local parent = H.tmpdir()
    stub_cargo(('case "$*" in *probe*) exec "%s" "$@";; esac\necho "error: member step failed" >&2\nexit 101'):format(real))
    local err = wait_cb(function(cb)
      R.create_workspace({ name = "half", parent = parent .. "/x/y", kind = "library", member = "half-core" }, cb)
    end)
    H.match(err, "error: member step failed", true)
    H.eq({}, vim.fn.readdir(parent))
  end)

  it("a read-only parent: an error from cargo / mkdir and nothing left", function()
    need_cargo()
    if vim.uv.os_getpid and (vim.uv.getuid and vim.uv.getuid() == 0 or vim.env.USER == "root") then
      return skip("root can write into a read-only directory")
    end
    local parent = H.tmpdir()
    vim.uv.fs_chmod(parent, 365) -- r-xr-xr-x
    local probe = vim.uv.fs_open(parent .. "/w", "w", 420)
    if probe then
      vim.uv.fs_close(probe)
      vim.uv.fs_chmod(parent, 493)
      return skip("the directory is writable anyway")
    end
    for _, f in ipairs({
      function(cb)
        R.create_project({ name = "ro", parent = parent, kind = "binary" }, cb)
      end,
      function(cb)
        R.create_workspace({ name = "ro", parent = parent, kind = "binary", member = "m" }, cb)
      end,
      function(cb)
        R.create_project({ name = "ro", parent = parent .. "/sub", kind = "binary" }, cb)
      end,
    }) do
      local err = wait_cb(f)
      H.ok(err and err ~= "", "an error")
    end
    H.eq({}, vim.fn.readdir(parent))
    vim.uv.fs_chmod(parent, 493)
  end)
end)

-- ============================================================ the prompts

describe(":RustNew* prompts", function()
  local function setup_flow()
    need_cargo()
    local parent = H.tmpdir()
    vim.g.xynovim_projects_dir = parent
    return parent, H.capture_notify()
  end

  local function wait_msg(cap, pat)
    H.wait_for(function()
      return find_msg(cap, pat) or find_msg(cap, "RustNew: ", vim.log.levels.ERROR)
    end, 60000, "notification " .. pat)
    H.not_ok(find_msg(cap, "RustNew: ", vim.log.levels.ERROR), vim.inspect(cap.list))
  end

  it("the four commands exist with an optional name", function()
    for _, c in ipairs({ "RustNewBin", "RustNewLib", "RustNewWorkspace", "RustNewMember" }) do
      H.eq(2, vim.fn.exists(":" .. c), c)
      H.eq("?", vim.api.nvim_get_commands({})[c].nargs)
    end
    H.eq(2, vim.fn.exists(":RustNew"), "the old picker command stays")
  end)

  it("binary: name, parent (default vim.g.xynovim_projects_dir), cargo new, cd, main.rs, next steps", function()
    local parent, cap = setup_flow()
    local log = stub_input({ "hello-bin", parent })
    vim.cmd("RustNewBin")
    H.eq(2, #log)
    H.match(log[1].prompt, "name")
    H.eq(parent, log[2].default)
    wait_msg(cap, "created ")
    local dir = parent .. "/hello-bin"
    H.eq(vim.uv.fs_realpath(dir), vim.uv.fs_realpath(vim.uv.cwd()))
    H.eq(vim.uv.fs_realpath(dir .. "/src/main.rs"), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
    H.has(find_msg(cap, "created ").msg, "cargo run")
    H.ok(vim.uv.fs_stat(dir .. "/.git"))
  end)

  it("library: name given as the argument, the crate identifier is shown, src/lib.rs opens", function()
    local parent, cap = setup_flow()
    local log = stub_input({ parent })
    vim.cmd("RustNewLib my-lib")
    H.eq(1, #log, "no name prompt")
    wait_msg(cap, "created ")
    H.ok(find_msg(cap, "my_lib"), "the identifier is shown")
    H.eq(vim.uv.fs_realpath(parent .. "/my-lib/src/lib.rs"), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
  end)

  it("the default parent is ~/projects when it exists, else the cwd", function()
    local home = H.tmpdir()
    stub(vim.uv, "os_homedir", function()
      return home
    end)
    stub(vim.uv, "cwd", function()
      return "/the/cwd"
    end)
    H.eq("/the/cwd", E.default_parent())
    vim.fn.mkdir(home .. "/projects")
    H.eq(home .. "/projects", E.default_parent())
    vim.g.xynovim_projects_dir = "/custom"
    H.eq("/custom", E.default_parent())
  end)

  it("an invalid argument re-prompts with the reason; an existing target and a file as parent re-prompt", function()
    local parent, cap = setup_flow()
    write(parent .. "/taken/Cargo.toml", "")
    write(parent .. "/afile", "x")
    local log = stub_input({ "good1", parent .. "/afile", parent })
    vim.cmd("RustNewBin fn")
    H.eq(3, #log)
    H.match(log[1].prompt, "keyword", true)
    H.eq("fn", log[1].default)
    H.match(log[2].prompt, "Parent")
    H.match(log[3].prompt, "not a directory", true)
    wait_msg(cap, "created ")
    H.ok(vim.uv.fs_stat(parent .. "/good1/Cargo.toml"))
    vim.cmd("silent! %bwipeout!")

    -- an existing target directory is refused at the parent prompt
    local log2 = stub_input({ parent, false })
    vim.cmd("RustNewBin taken")
    H.eq(2, #log2)
    H.match(log2[2].prompt, "exists already", true)
  end)

  it("asks before creating a missing parent; 'No' creates nothing", function()
    local parent, cap = setup_flow()
    local confirms = {}
    stub(vim.fn, "confirm", function(msg)
      confirms[#confirms + 1] = msg
      return #confirms == 1 and 2 or 1
    end)
    stub_input({ "pp", parent .. "/new/dir", parent .. "/new/dir" })
    vim.cmd("RustNewBin")
    H.wait_for(function()
      return #confirms == 2
    end, 5000, "second confirm")
    H.has(confirms[1], parent .. "/new/dir")
    wait_msg(cap, "created ")
    H.ok(vim.uv.fs_stat(parent .. "/new/dir/pp/Cargo.toml"))
  end)

  it("cancelling any prompt aborts silently and leaves nothing (bin, lib, workspace)", function()
    local parent, cap = setup_flow()
    stub(vim.fn, "confirm", function()
      error("no confirm expected")
    end)
    local function try(cmd, answers, selects, expect_prompts)
      local log = stub_input(answers)
      stub_select(selects)
      vim.cmd(cmd)
      vim.wait(100)
      H.eq(expect_prompts, #log, cmd)
    end
    try("RustNewBin", { false }, {}, 1)
    try("RustNewBin", { "a", false }, {}, 2)
    try("RustNewLib", { false }, {}, 1)
    try("RustNewLib", { "a", false }, {}, 2)
    try("RustNewWorkspace", { false }, {}, 1)
    try("RustNewWorkspace", { "a", false }, {}, 2)
    try("RustNewWorkspace", { "a", parent }, { false }, 2) -- the kind select
    try("RustNewWorkspace", { "a", parent, false }, { "binary" }, 3) -- the member name
    vim.wait(200)
    H.eq({}, vim.fn.readdir(parent))
    H.eq({}, vim.tbl_filter(function(m)
      return tostring(m.msg):find("RustNew", 1, true)
    end, cap.list), "no RustNew notification at all")
  end)

  it("workspace: name, parent, kind FIRST, then the member name prefilled with -app / -core", function()
    local parent, cap = setup_flow()
    local log = stub_input({ "big-ws", parent, "big-ws-app" })
    local sel = stub_select({ "binary" })
    vim.cmd("RustNewWorkspace")
    H.eq({ "binary", "library" }, sel[1].items)
    H.eq(3, #log)
    H.eq("big-ws-app", log[3].default)
    wait_msg(cap, "created ")
    local root = parent .. "/big-ws"
    H.eq(vim.uv.fs_realpath(root), vim.uv.fs_realpath(vim.uv.cwd()))
    H.eq(vim.uv.fs_realpath(root .. "/crates/big-ws-app/src/main.rs"), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
    local msg = find_msg(cap, "created ").msg
    H.has(msg, "cargo run -p big-ws-app")
    H.has(msg, "<leader>rX")
    H.has(msg, "crates/big-ws-app/")
    H.has(msg, 'members = ["crates/*"]')

    -- a library asks for a different default
    vim.cmd("silent! %bwipeout!")
    local log2 = stub_input({ "libs", parent, "libs-core" })
    stub_select({ "library" })
    vim.cmd("RustNewWorkspace")
    H.eq("libs-core", log2[3].default)
    H.wait_for(function()
      return vim.uv.fs_stat(parent .. "/libs/crates/libs-core/src/lib.rs")
    end, 60000, "second workspace")
  end)

  it("workspace creation does not block: a progress notification is shown while cargo runs", function()
    local parent, cap = setup_flow()
    stub_input({ "slow", parent, "slow-app" })
    stub_select({ "binary" })
    vim.cmd("RustNewWorkspace")
    H.ok(find_msg(cap, "cargo new") or find_msg(cap, "asking cargo"), "progress right away")
    wait_msg(cap, "created ")
  end)

  it(":RustNewMember: finds the workspace from the current buffer, asks kind and name, refuses elsewhere", function()
    local parent, cap = setup_flow()
    stub_input({ "mw", parent, "mw-app" })
    stub_select({ "binary" })
    vim.cmd("RustNewWorkspace")
    wait_msg(cap, "created ")
    local root = parent .. "/mw"
    local log = stub_input({ "mw-core" })
    local sel = stub_select({ "library" })
    vim.cmd("RustNewMember")
    H.wait_for(function()
      return vim.uv.fs_stat(root .. "/crates/mw-core/src/lib.rs")
    end, 60000, "member created")
    H.eq(1, #sel)
    H.eq(1, #log)
    H.wait_for(function()
      return find_msg(cap, "added crates/mw-core")
    end, 10000, "notification")
    H.eq(vim.uv.fs_realpath(root .. "/crates/mw-core/src/lib.rs"), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))

    -- a name that exists is re-prompted
    stub_input({ "mw-app", "mw_core", "another" })
    stub_select({ "binary" })
    local before = #cap.list
    vim.cmd("RustNewMember")
    H.wait_for(function()
      return vim.uv.fs_stat(root .. "/crates/another/Cargo.toml")
    end, 60000, "third member")
    local warned = 0
    for i = before + 1, #cap.list do
      if tostring(cap.list[i].msg):find("exists already", 1, true) then
        warned = warned + 1
      end
    end
    H.eq(2, warned)

    -- outside a workspace: refused, no prompt
    H.wait_for(function()
      return not R.running()
    end, 60000, "the third member to be finished")
    local lone = H.tmpdir()
    run({ "cargo", "new", "--vcs", "none", "lone" }, lone)
    vim.cmd("silent! %bwipeout!")
    vim.cmd("edit " .. vim.fn.fnameescape(lone .. "/lone/src/main.rs"))
    local log2 = stub_input({})
    cap = H.capture_notify()
    vim.cmd("RustNewMember")
    vim.wait(100)
    H.eq(0, #log2)
    H.ok(find_msg(cap, "not a workspace with a members list", vim.log.levels.ERROR), vim.inspect(cap.list))
    H.eq({ "src" }, vim.tbl_filter(function(n)
      return n == "src"
    end, vim.fn.readdir(lone .. "/lone")))
    H.is_nil(vim.uv.fs_stat(lone .. "/lone/crates"))
  end)

  it("a second command while one runs is refused", function()
    local parent, cap = setup_flow()
    stub_input({ "first", parent, "second", parent })
    vim.cmd("RustNewBin")
    -- the run of the first one is in flight (async)
    vim.cmd("RustNewBin")
    H.ok(find_msg(cap, "being created already", vim.log.levels.WARN) or find_msg(cap, "created "), vim.inspect(cap.list))
    H.wait_for(function()
      return find_msg(cap, "created ")
    end, 60000, "first created")
  end)
end)

-- ================================================================= dashboard

describe("dashboard entries 'New Rust Binary / Library / Workspace'", function()
  local function snacks_opts()
    local plugin = H.ok(require("lazy.core.config").plugins["snacks.nvim"], "snacks.nvim")
    return require("lazy.core.plugin").values(plugin, "opts", false)
  end

  local WANT = {
    { "b", "New Rust Binary", ":RustNewBin" },
    { "i", "New Rust Library", ":RustNewLib" },
    { "w", "New Rust Workspace", ":RustNewWorkspace" },
  }

  it("three entries with unique keys and distinct icons, in order, before the egui entry and Quit", function()
    local keys = snacks_opts().dashboard.preset.keys
    local seen, icons, pos = {}, {}, {}
    for i, k in ipairs(keys) do
      H.is_nil(seen[k.key], "duplicate dashboard key " .. tostring(k.key))
      seen[k.key] = true
      H.is_nil(icons[k.icon or ""], "duplicate icon for " .. tostring(k.desc))
      icons[k.icon or ""] = true
      pos[k.desc] = i
    end
    for n, w in ipairs(WANT) do
      local i = H.ok(pos[w[2]], w[2] .. " is in the merged preset")
      H.eq(w[1], keys[i].key)
      H.eq(w[3], keys[i].action)
      H.ok(keys[i].icon and #keys[i].icon > 0)
      if n > 1 then
        H.eq(pos[WANT[n - 1][2]] + 1, i, "the three are consecutive")
      end
    end
    H.eq(pos["Quit"] - 1, pos["New egui Project"], "the egui entry stays right before Quit")
    H.ok(pos["New Rust Workspace"] < pos["New egui Project"])
    for _, k in ipairs({ "f", "n", "p", "g", "r", "c", "s", "x", "l", "q", "e" }) do
      H.ok(seen[k], "the existing key " .. k .. " is unchanged")
    end
  end)

  it("the layout thresholds follow the number of entries", function()
    local o = snacks_opts()
    local n = #o.dashboard.preset.keys
    local s = o.dashboard.sections
    local lines = vim.o.lines
    vim.o.lines = 2 * n + 11
    H.ok(s[2].enabled() and not s[3].enabled() and s[1].enabled(), "tall at 2n+11")
    vim.o.lines = 2 * n + 10
    H.ok(not s[2].enabled() and s[3].enabled() and s[1].enabled(), "short with the header below")
    vim.o.lines = n + 12
    H.ok(s[1].enabled(), "header at n+12")
    vim.o.lines = n + 11
    H.ok(not s[1].enabled(), "no header below n+12")
    vim.o.lines = lines
  end)

  local function in_tmux(cols, rows, session)
    H.need_tmux()
    local env = {}
    for _, k in ipairs({ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "TMPDIR", "HOME" }) do
      if vim.env[k] then
        env[#env + 1] = ("%s=%s"):format(k, vim.fn.shellescape(vim.env[k]))
      end
    end
    local cmd = "env " .. table.concat(env, " ") .. " " .. vim.fn.shellescape(vim.fn.exepath("nvim"))
    local r = H.tmux({ "new-session", "-d", "-s", session, "-x", tostring(cols), "-y", tostring(rows), cmd }, session)
    H.eq(0, r.code, r.stderr)
    local function capture()
      return H.tmux({ "capture-pane", "-p", "-t", session }, session).stdout or ""
    end
    return capture, function(keys)
      H.tmux({ "send-keys", "-t", session, keys }, session)
    end
  end

  -- every entry with its key on one screen line, at the sizes the layouts are made for
  for _, c in ipairs({ { 80, 24 }, { 100, 30 }, { 190, 50 }, { 80, 18 }, { 120, 38 }, { 120, 39 } }) do
    it(("every entry and key is on screen at %dx%d"):format(c[1], c[2]), function()
      local capture = in_tmux(c[1], c[2], ("d%dx%d"):format(c[1], c[2]))
      H.wait_for(function()
        local p = capture()
        return p:find("Quit", 1, true) and p:find("loaded", 1, true)
      end, 30000, ("dashboard at %dx%d:\n%s"):format(c[1], c[2], capture()))
      local pane = capture()
      for _, k in ipairs(snacks_opts().dashboard.preset.keys) do
        local found
        for line in pane:gmatch("[^\n]+") do
          if line:find(k.desc, 1, true) and line:match("%s" .. vim.pesc(k.key) .. "%s*$") then
            found = true
          end
        end
        H.ok(found, ("'%s' (%s) is missing at %dx%d:\n%s"):format(k.desc, k.key, c[1], c[2], pane))
      end
      H.match(pane, "loaded %d+/%d+ plugins")
    end)
  end

  for _, w in ipairs(WANT) do
    it(("pressing %s at 80x24 opens the prompt of %s"):format(w[1], w[2]), function()
      local capture, send = in_tmux(80, 24, "key" .. w[1])
      H.wait_for(function()
        return capture():find("Quit", 1, true)
      end, 30000, "dashboard")
      send(w[1])
      local want = w[1] == "w" and "Workspace name" or "Project name"
      H.wait_for(function()
        return capture():find(want, 1, true)
      end, 10000, "the prompt after pressing " .. w[1] .. ":\n" .. capture())
      send("Escape")
    end)
  end
end)
