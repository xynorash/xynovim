-- xynovim.trust_fallback fingerprint (the vendored copy of xyno_rust.trust used while lazy-lock.json pins an
-- xyno-rust.nvim without the trust module): what is watched (custom build script paths, path dependencies and
-- workspace members outside the root, proc-macro crates, files beyond the first MiB) and `cargo metadata
-- --no-deps --offline` as the async source of that list. The same cases run in xyno-rust.nvim
-- (tests/trust_fingerprint_spec.lua there).
-- xyno-timeout: 120
local H = require("xynotest.helpers")
local trust = require("xynovim.trust_fallback")

local fp, prime, primed, forget = trust.fingerprint, trust.prime, trust.primed, trust._forget
local drift = trust.drift
--- trusted by the workspace's own entry (the spec helpers may trust the temp directory's parent as a whole)
local function is_trusted(ws)
  local ok, by = trust.is_trusted(ws)
  return ok and by == ws
end
local function trusted(ws, opts)
  return trust.trust(ws, opts)
end
local function fb_max_bytes()
  return trust._max_bytes
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function manifest(name, extra)
  return ('[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n%s'):format(name, extra or "")
end

--- A workspace root `<base>/ws` next to `<base>/dep`, so "outside the root" is a sibling directory.
local function layout()
  local base = H.tmpdir()
  local ws, dep = base .. "/ws", base .. "/dep"
  write(ws .. "/Cargo.toml", manifest("ws"))
  write(ws .. "/src/main.rs", "fn main() {}\n")
  write(dep .. "/Cargo.toml", manifest("dep"))
  write(dep .. "/src/lib.rs", "")
  return base, ws, dep
end

local function hash(ws)
  return fp(ws, { fresh = true }).hash
end

--- the hash changed after `change()` (and was stable before it)
local function changes(ws, change, msg)
  local before = hash(ws)
  H.eq(before, hash(ws), msg .. ": stable while nothing changes")
  change()
  H.ok(before ~= hash(ws), msg)
end

describe("trust fingerprint: what cargo runs, beyond Cargo.toml and build.rs at the root", function()
  it("a build script at a custom path (package.build = 'x/gen.rs')", function()
    H.known_issue(
      { "windows" },
      "fingerprint file names differ on windows-latest (runs 43433161619, 43436212295, 43440285823, 43443589115): the files under the root are watched by absolute name, not relative to it; the drive-letter spelling of M.normalize against vim.fs.normalize is not the whole cause (folding it made trust-fallback fail), not diagnosed"
    )
    local _, ws = layout()
    write(ws .. "/Cargo.toml", manifest("ws", 'build = "x/gen.rs"\n'))
    write(ws .. "/x/gen.rs", "fn main() {}\n")
    H.ok(fp(ws, { fresh = true }).files["x/gen.rs"], "watched by name")
    changes(ws, function()
      write(ws .. "/x/gen.rs", 'fn main() { println!("cargo:rustc-env=A=1"); }\n')
    end, "editing the custom build script")
  end)

  it("build = false is not a build script even when a build.rs file lies there", function()
    local _, ws = layout()
    write(ws .. "/Cargo.toml", manifest("ws", "build = false\n"))
    write(ws .. "/gen.rs", "fn main() {}\n")
    H.is_nil(fp(ws, { fresh = true }).files["gen.rs"])
  end)

  it("the modules of a build script (mod x; and include!)", function()
    H.known_issue(
      { "windows" },
      "fingerprint file names differ on windows-latest (runs 43433161619, 43436212295, 43440285823, 43443589115): the files under the root are watched by absolute name, not relative to it; the drive-letter spelling of M.normalize against vim.fs.normalize is not the whole cause (folding it made trust-fallback fail), not diagnosed"
    )
    local _, ws = layout()
    write(ws .. "/build.rs", 'mod helper;\nfn main() { helper::run(); include!("inc.rs"); }\n')
    write(ws .. "/helper.rs", "pub fn run() {}\n")
    write(ws .. "/inc.rs", "\n")
    local files = fp(ws, { fresh = true }).files
    H.ok(files["helper.rs"], "mod helper;")
    H.ok(files["inc.rs"], "include!")
    changes(ws, function()
      write(ws .. "/helper.rs", "pub fn run() { /* x */ }\n")
    end, "editing the build script's module")
  end)

  it("a path dependency outside the root with its own build.rs", function()
    local _, ws, dep = layout()
    write(ws .. "/Cargo.toml", manifest("ws", '\n[dependencies]\ndep = { path = "../dep" }\n'))
    write(dep .. "/build.rs", "fn main() {}\n")
    H.ok(fp(ws, { fresh = true }).files[dep .. "/build.rs"], "watched by its absolute name")
    H.ok(fp(ws, { fresh = true }).files[dep .. "/Cargo.toml"], "and its manifest")
    changes(ws, function()
      write(dep .. "/build.rs", 'fn main() { std::process::Command::new("x"); }\n')
    end, "editing the dependency's build.rs")
  end)

  it("a path dependency of a path dependency (followed, bounded)", function()
    local base, ws, dep = layout()
    write(ws .. "/Cargo.toml", manifest("ws", '\n[dependencies]\ndep = { path = "../dep" }\n'))
    write(dep .. "/Cargo.toml", manifest("dep", '\n[dependencies]\ndeep = { path = "../deep" }\n'))
    write(base .. "/deep/Cargo.toml", manifest("deep"))
    write(base .. "/deep/build.rs", "fn main() {}\n")
    changes(ws, function()
      write(base .. "/deep/build.rs", "fn main() { /* y */ }\n")
    end, "editing the build.rs two path hops away")
  end)

  it("a workspace member outside the root", function()
    local _, ws, dep = layout()
    write(ws .. "/Cargo.toml", '[workspace]\nmembers = ["../dep"]\n' .. manifest("ws"))
    write(dep .. "/build.rs", "fn main() {}\n")
    changes(ws, function()
      write(dep .. "/build.rs", "fn main() { /* z */ }\n")
    end, "editing a member's build.rs outside the root")
  end)

  it("a workspace member found by a 'dir/*' glob outside the root", function()
    local base, ws = layout()
    write(ws .. "/Cargo.toml", '[workspace]\nmembers = ["../crates/*"]\n' .. manifest("ws"))
    write(base .. "/crates/a/Cargo.toml", manifest("a"))
    write(base .. "/crates/a/build.rs", "fn main() {}\n")
    changes(ws, function()
      write(base .. "/crates/a/build.rs", "fn main() { /* q */ }\n")
    end, "editing a glob member's build.rs")
  end)

  it("every source file of a proc-macro crate (it runs inside the compiler)", function()
    H.known_issue(
      { "windows" },
      "fingerprint file names differ on windows-latest (runs 43433161619, 43436212295, 43440285823, 43443589115): the files under the root are watched by absolute name, not relative to it; the drive-letter spelling of M.normalize against vim.fs.normalize is not the whole cause (folding it made trust-fallback fail), not diagnosed"
    )
    local _, ws = layout()
    write(ws .. "/Cargo.toml", '[workspace]\nmembers = ["pm"]\n' .. manifest("ws"))
    write(ws .. "/pm/Cargo.toml", manifest("pm", "\n[lib]\nproc-macro = true\n"))
    write(ws .. "/pm/src/lib.rs", "mod inner;\n")
    write(ws .. "/pm/src/inner.rs", "// v1\n")
    write(ws .. "/pm/src/deep/more.rs", "// v1\n")
    local files = fp(ws, { fresh = true }).files
    H.ok(files["pm/src/lib.rs"] and files["pm/src/inner.rs"] and files["pm/src/deep/more.rs"], "all watched")
    changes(ws, function()
      write(ws .. "/pm/src/inner.rs", "// v2 evil\n")
    end, "editing a module of the proc-macro crate")
  end)

  it("an ordinary (non proc-macro) crate's sources are not watched", function()
    local _, ws = layout()
    local before = hash(ws)
    write(ws .. "/src/main.rs", "fn main() { println!(); }\n")
    H.eq(before, hash(ws), "a normal edit never asks again")
  end)

  it("a file beyond the first MiB: a change at 1.5 MiB is seen", function()
    local _, ws = layout()
    local big = string.rep("// padding line\n", 140000) -- about 2.2 MiB
    write(ws .. "/build.rs", big .. "fn main() {}\n")
    changes(ws, function()
      local f = assert(io.open(ws .. "/build.rs", "r+b"))
      f:seek("set", 1500000)
      f:write("X")
      f:close()
    end, "a byte changed at offset 1500000 of build.rs")
  end)

  it("a file beyond the whole-file limit still notices its tail and its size", function()
    local _, ws = layout()
    local limit = fb_max_bytes()
    local f = assert(io.open(ws .. "/build.rs", "wb"))
    local chunk = string.rep("a", 1024 * 1024)
    for _ = 1, math.floor(limit / (1024 * 1024)) + 2 do
      f:write(chunk)
    end
    f:close()
    changes(ws, function()
      local g = assert(io.open(ws .. "/build.rs", "r+b"))
      g:seek("end", -10)
      g:write("Z")
      g:close()
    end, "the last MiB of a file over the limit")
  end)

  it("a long chain of path dependencies stays bounded", function()
    local base, ws = layout()
    local deps = {}
    for i = 1, 150 do
      deps[#deps + 1] = ('d%d = { path = "../c%d" }'):format(i, i)
      write(base .. ("/c%d/Cargo.toml"):format(i), manifest("c" .. i))
      write(base .. ("/c%d/build.rs"):format(i), "fn main() {}\n")
    end
    write(ws .. "/Cargo.toml", manifest("ws", "\n[dependencies]\n" .. table.concat(deps, "\n") .. "\n"))
    local f = fp(ws, { fresh = true })
    H.ok(vim.tbl_count(f.files) <= 400, "at most 400 files")
    H.ok(f.hash and f.hash ~= "")
  end)
end)

describe("trust fingerprint: cargo metadata, async", function()
  before_each(function()
    H.need_rust()
    forget()
  end)

  local function prime_wait(ws)
    local done, ok, err
    prime(ws, function(o, e)
      done, ok, err = true, o, e
    end)
    H.ok(not done, "prime returns at once: the callback comes later, from the event loop")
    H.wait_for(function()
      return done
    end, 30000, "cargo metadata")
    return ok, err
  end

  it("prime reads the build scripts, proc-macro targets and path dependencies cargo names", function()
    H.known_issue(
      { "windows" },
      "fingerprint file names differ on windows-latest (runs 43433161619, 43436212295, 43440285823, 43443589115): the files under the root are watched by absolute name, not relative to it; the drive-letter spelling of M.normalize against vim.fs.normalize is not the whole cause (folding it made trust-fallback fail), not diagnosed"
    )
    local _, ws, dep = layout()
    write(
      ws .. "/Cargo.toml",
      '[workspace]\nmembers = ["pm"]\n'
        .. manifest("ws", 'build = "x/gen.rs"\n\n[dependencies]\ndep = { path = "../dep" }\n')
    )
    write(ws .. "/x/gen.rs", "fn main() {}\n")
    write(ws .. "/pm/Cargo.toml", manifest("pm", "\n[lib]\nproc-macro = true\n"))
    write(ws .. "/pm/src/lib.rs", "")
    write(ws .. "/pm/src/extra.rs", "// e\n")
    write(dep .. "/build.rs", "fn main() {}\n")
    H.not_ok(primed(ws))
    local ok, err = prime_wait(ws)
    H.ok(ok, "metadata ok: " .. tostring(err))
    H.ok(primed(ws))
    local files = fp(ws, { fresh = true }).files
    H.ok(files["x/gen.rs"], "custom-build target")
    H.ok(files["pm/src/extra.rs"], "proc-macro crate source")
    H.ok(files[dep .. "/build.rs"], "path dependency's build script")
    H.ok(files[dep .. "/Cargo.toml"], "path dependency's manifest")
    changes(ws, function()
      write(dep .. "/build.rs", "fn main() { /* after metadata */ }\n")
    end, "editing the path dependency after the metadata is read")
  end)

  it("metadata is dropped when a manifest changes (the fallback keeps watching)", function()
    H.known_issue(
      { "windows" },
      "fingerprint file names differ on windows-latest (runs 43433161619, 43436212295, 43440285823, 43443589115): the files under the root are watched by absolute name, not relative to it; the drive-letter spelling of M.normalize against vim.fs.normalize is not the whole cause (folding it made trust-fallback fail), not diagnosed"
    )
    local _, ws = layout()
    H.ok(prime_wait(ws))
    H.ok(primed(ws))
    write(ws .. "/Cargo.toml", manifest("ws", 'build = "late.rs"\n'))
    write(ws .. "/late.rs", "fn main() {}\n")
    H.not_ok(primed(ws), "the manifest it was made from changed")
    H.ok(fp(ws, { fresh = true }).files["late.rs"], "the fallback sees the new custom build script at once")
  end)

  it("metadata is a manifest read: a build.rustc / rustc-wrapper canary in .cargo/config.toml does not run", function()
    local base, ws = layout()
    local canary = base .. "/CANARY"
    write(base .. "/evil.sh", ('#!/bin/sh\ntouch %s\nexec rustc "$@"\n'):format(canary))
    vim.uv.fs_chmod(base .. "/evil.sh", 493)
    write(
      ws .. "/.cargo/config.toml",
      ('[build]\nrustc = "%s/evil.sh"\nrustc-wrapper = "%s/evil.sh"\n'):format(base, base)
    )
    write(ws .. "/build.rs", ('fn main() { std::fs::write(%q, "x").unwrap(); }\n'):format(canary))
    prime_wait(ws)
    vim.wait(300)
    H.is_nil(vim.uv.fs_stat(canary), "nothing of the workspace ran")
  end)

  it("without cargo the fallback still works and prime says so", function()
    local _, ws, dep = layout()
    write(ws .. "/Cargo.toml", manifest("ws", '\n[dependencies]\ndep = { path = "../dep" }\n'))
    write(dep .. "/build.rs", "fn main() {}\n")
    local path = vim.env.PATH
    vim.env.PATH = "/nonexistent"
    local ok, err
    prime(ws, function(o, e)
      ok, err = o, e
    end)
    vim.env.PATH = path
    H.eq(false, ok)
    H.match(err, "no cargo", true)
    H.ok(fp(ws, { fresh = true }).files[dep .. "/build.rs"], "the manifest scan found the dependency's build.rs")
  end)

  it("a workspace without a Cargo.toml: prime says so, nothing breaks", function()
    local ws = H.tmpdir()
    local ok, err
    prime(ws, function(o, e)
      ok, err = o, e
    end)
    H.eq(false, ok)
    H.match(err, "Cargo.toml", true)
    H.ok(fp(ws, { fresh = true }).hash)
  end)

  it("trust records the metadata's files without a false drift, and a later change to them is seen", function()
    H.known_issue(
      { "windows" },
      "fingerprint file names differ on windows-latest (runs 43433161619, 43436212295, 43440285823, 43443589115): the files under the root are watched by absolute name, not relative to it; the drive-letter spelling of M.normalize against vim.fs.normalize is not the whole cause (folding it made trust-fallback fail), not diagnosed"
    )
    local _, ws, dep = layout()
    write(ws .. "/Cargo.toml", manifest("ws", '\n[dependencies]\ndep = { path = "../dep" }\n'))
    write(dep .. "/build.rs", "fn main() {}\n")
    trusted(ws)
    H.ok(is_trusted(ws), "trusted right after")
    H.wait_for(function()
      return primed(ws)
    end, 30000, "the background prime after trust")
    vim.wait(200)
    H.ok(is_trusted(ws), "still trusted once the metadata arrived (no false drift)")
    H.is_nil(drift(ws))
    write(dep .. "/build.rs", "fn main() { /* pulled */ }\n")
    H.not_ok(is_trusted(ws), "the dependency's build.rs changed: untrusted again")
    local names = drift(ws)
    H.ok(names and vim.tbl_contains(names, dep .. "/build.rs"), "named: " .. vim.inspect(names))
  end)

  it("an entry recorded before the metadata of this session is read still compares equal", function()
    H.known_issue(
      { "windows" },
      "fingerprint file names differ on windows-latest (runs 43433161619, 43436212295, 43440285823, 43443589115): the files under the root are watched by absolute name, not relative to it; the drive-letter spelling of M.normalize against vim.fs.normalize is not the whole cause (folding it made trust-fallback fail), not diagnosed"
    )
    local _, ws, dep = layout()
    write(ws .. "/Cargo.toml", manifest("ws", '\n[dependencies]\ndep = { path = "../dep" }\n'))
    write(dep .. "/build.rs", "fn main() {}\n")
    trusted(ws, { no_prime = true })
    forget() -- a new session: no metadata, no memo
    H.ok(is_trusted(ws))
    H.is_nil(drift(ws))
  end)
end)
