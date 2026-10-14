-- :checkhealth xynovim (lua/xynovim/health.lua), scripts/bootstrap.sh, the CI workflow,
-- Makefile, stylua.toml, .gitignore, LICENSE and the README prerequisite lists.
-- health.check() is unit-tested with vim.health stubbed and a fake PATH of stub
-- executables; bootstrap.sh runs in a temp "checkout" with a stub nvim. The one
-- test that needs the network (a real fresh install) runs only with XYNO_TEST_NETWORK=1.
local H = require("xynotest.helpers")

local repo = H.repo
local function read(rel)
  return table.concat(vim.fn.readfile(repo .. "/" .. rel), "\n") .. "\n"
end

-- ------------------------------------------------------------------ utilities

local function write_exec(path, body)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.split("#!/bin/sh\n" .. body, "\n"), path)
  vim.uv.fs_chmod(path, tonumber("755", 8))
end

--- A directory of stub executables; `spec` maps name -> script body, or `true`
--- for "print '<name> 9.9.9 stub' and exit 0".
local function stubdir(spec)
  local dir = H.tmpdir() .. "/bin"
  vim.fn.mkdir(dir, "p")
  for name, body in pairs(spec) do
    if body == false then
      goto continue
    end
    if body == true then
      body = ("echo '%s 9.9.9 stub'\n"):format(name)
    end
    write_exec(dir .. "/" .. name, body)
    ::continue::
  end
  return dir
end

local HEALTH_BINS = {
  "git", "curl", "tar", "unzip", "gzip", "gcc", "tree-sitter", "node", "cargo", "rust-analyzer", "bacon-ls", "codelldb", "taplo",
  "wgsl-analyzer", "cargo-nextest", "cargo-deny", "cargo-expand", "lazygit", "delta", "mold", "clang", "npm", "bwrap",
}
local ERRORS = { git = 1, cargo = 1, ["rust-analyzer"] = 1, ["bacon-ls"] = 1 }
local MASON = { ["tree-sitter"] = 1, ["bacon-ls"] = 1, codelldb = 1, taplo = 1, ["wgsl-analyzer"] = 1 }

local function all_stubs(extra)
  local spec = {}
  for _, b in ipairs(HEALTH_BINS) do
    spec[b] = true
  end
  for k, v in pairs(extra or {}) do
    spec[k] = v
  end
  return spec
end

local RUSTUP_OK = "case \"$*\" in\n  'component list --toolchain stable --installed') printf 'cargo-x86_64\\nclippy-x86_64\\nllvm-tools-x86_64\\nrustfmt-x86_64\\n' ;;\n  *) exit 1 ;;\nesac\n"

--- Run health.check() with PATH = `path`, XDG_DATA_HOME = a fresh temp dir (or
--- `data`), vim.health stubbed. Returns the list of {kind, msg, advice}.
local function run_check(path, data)
  local rec = {}
  local saved = { path = vim.env.PATH, data = vim.env.XDG_DATA_HOME }
  local orig = vim.health
  local stub = {}
  for _, k in ipairs({ "start", "ok", "warn", "error", "info" }) do
    stub[k] = function(msg, advice)
      rec[#rec + 1] = { kind = k, msg = msg, advice = advice }
    end
  end
  vim.health = stub
  vim.env.PATH = path
  vim.env.XDG_DATA_HOME = data or H.tmpdir()
  local ok, err = pcall(function()
    package.loaded["xynovim.health"] = nil
    require("xynovim.health").check()
  end)
  vim.health = orig
  vim.env.PATH = saved.path
  vim.env.XDG_DATA_HOME = saved.data
  assert(ok, err)
  return rec
end

--- First record whose message starts with `<bin> ` (or equals it).
local function rec_for(rec, bin)
  for _, r in ipairs(rec) do
    if r.msg:sub(1, #bin + 1) == bin .. " " then
      return r
    end
  end
end

local function section(rec, title)
  local out, on = {}, false
  for _, r in ipairs(rec) do
    if r.kind == "start" then
      on = r.msg == title
    elseif on then
      out[#out + 1] = r
    end
  end
  return out
end

local function sh(cmd, opts)
  opts = vim.tbl_extend("force", { text = true }, opts or {})
  return vim.system(cmd, opts):wait(opts.timeout_ms or 60000)
end

-- --------------------------------------------------------------------- health

describe("health: real :checkhealth", function()
  it("runs without Lua errors and has both sections", function()
    vim.cmd("checkhealth xynovim")
    local buf = vim.api.nvim_get_current_buf()
    H.wait_for(function()
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("xynovim: rust toolchain", 1, true)
    end, 30000, ":checkhealth xynovim output")
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    H.has(text, "xynovim: external tools")
    H.has(text, "xynovim: rust toolchain")
    H.no_match(text, "Failed to run healthcheck", true)
    H.no_match(text, "attempt to ")
    H.no_match(text, "stack traceback", true)
  end)
end)

describe("health: TOOLS table", function()
  local rec
  before_each(function()
    -- empty PATH dir, empty data dir: every tool is missing, so every TOOLS row shows
    rec = run_check(stubdir({}), nil)
  end)

  it("has 23 entries with the documented severities", function()
    local tools = section(rec, "xynovim: external tools")
    H.eq(23, #tools)
    for _, bin in ipairs(HEALTH_BINS) do
      local r = H.ok(rec_for(rec, bin), "no record for " .. bin)
      H.eq(ERRORS[bin] and "error" or "warn", r.kind, bin .. " severity")
    end
  end)

  it("reports every missing tool as '<bin> not found: <purpose>' with a hint", function()
    for _, bin in ipairs(HEALTH_BINS) do
      local r = rec_for(rec, bin)
      H.match(r.msg, "^" .. vim.pesc(bin) .. " not found: .+")
      if bin == "rust-analyzer" then
        H.eq("rustup component add rust-analyzer (or put a rust-analyzer binary on PATH)", r.advice)
      elseif MASON[bin] then
        H.eq("install it with :Mason or put it on PATH", r.advice, bin)
      else
        H.eq("install it and put it on PATH", r.advice, bin)
      end
    end
  end)
end)

describe("health: found tools", function()
  it("reports 'name (PATH) <first --version line>: purpose'", function()
    local dir = stubdir(all_stubs({ git = "echo 'git version 2.99'\necho second line\n" }))
    local rec = run_check(dir)
    local r = rec_for(rec, "git")
    H.eq("ok", r.kind)
    H.eq(("git (PATH) git version 2.99: plugin manager (lazy.nvim clones and checks out the lockfile)"), r.msg)
    H.eq("ok", rec_for(rec, "curl").kind)
    H.has(rec_for(rec, "curl").msg, "curl (PATH) curl 9.9.9 stub: ")
  end)

  it("cuts the version line at 80 characters", function()
    local long = ("v"):rep(120)
    local rec = run_check(stubdir(all_stubs({ tar = "echo " .. long .. "\n" })))
    H.has(rec_for(rec, "tar").msg, "tar (PATH) " .. ("v"):rep(80) .. ": ")
    H.no_match(rec_for(rec, "tar").msg, ("v"):rep(81), true)
  end)

  it("falls back to stderr when --version prints nothing on stdout", function()
    local rec = run_check(stubdir(all_stubs({ unzip = "echo 'UnZip 6.0 (stderr)' >&2\n" })))
    H.has(rec_for(rec, "unzip").msg, "unzip (PATH) UnZip 6.0 (stderr): ")
  end)

  it("passes the per-tool version args (unzip -v, others --version)", function()
    local log = H.tmpdir() .. "/args.log"
    local body = ("echo \"$0 $*\" >> %s\necho ok\n"):format(log)
    run_check(stubdir(all_stubs({ unzip = body, git = body })))
    local lines = vim.fn.readfile(log)
    local joined = table.concat(lines, "\n")
    H.match(joined, "unzip %-v")
    H.match(joined, "git %-%-version")
  end)

  it("reports codelldb (no version args) without a version and without running it", function()
    local marker = H.tmpdir() .. "/ran"
    local data = H.tmpdir()
    write_exec(data .. "/nvim/mason/bin/codelldb", ("touch %s\necho 'codelldb 1.0'\n"):format(marker))
    local rec = run_check(stubdir(all_stubs()), data)
    local r = rec_for(rec, "codelldb")
    H.eq("ok", r.kind)
    H.eq("codelldb (Mason): debugger (dap.core)", r.msg)
    H.eq(0, vim.fn.filereadable(marker))
  end)

  it("looks for bacon-ls, codelldb and taplo in Mason's bin first, then PATH; others PATH only", function()
    local data = H.tmpdir()
    -- every tool exists in Mason's bin AND on PATH
    for _, b in ipairs(HEALTH_BINS) do
      write_exec(data .. "/nvim/mason/bin/" .. b, ("echo 'mason-%s 1'\n"):format(b))
    end
    local rec = run_check(stubdir(all_stubs()), data)
    for _, b in ipairs(HEALTH_BINS) do
      local r = rec_for(rec, b)
      if MASON[b] then
        H.has(r.msg, b .. " (Mason)", b)
        if b ~= "codelldb" then
          H.has(r.msg, "mason-" .. b .. " 1")
        end
      else
        H.has(r.msg, b .. " (PATH) " .. b .. " 9.9.9 stub", b)
      end
    end
    -- Mason empty: PATH is used for the three, and Mason-only copies of other tools are ignored
    local data2 = H.tmpdir()
    write_exec(data2 .. "/nvim/mason/bin/git", "echo mason-git\n")
    local rec2 = run_check(stubdir(all_stubs({ git = false })), data2)
    for b in pairs(MASON) do
      H.has(rec_for(rec2, b).msg, b .. " (PATH)", b)
    end
  end)

  it("a tool only in Mason's bin counts only for the Mason tools", function()
    local data = H.tmpdir()
    write_exec(data .. "/nvim/mason/bin/taplo", "echo 'taplo 0.1'\n")
    write_exec(data .. "/nvim/mason/bin/lazygit", "echo 'lazygit 0.1'\n")
    local rec = run_check(stubdir({}), data)
    H.has(rec_for(rec, "taplo").msg, "taplo (Mason) taplo 0.1: ")
    H.match(rec_for(rec, "lazygit").msg, "^lazygit not found")
  end)
end)

describe("health: broken tools", function()
  it("reports a failing --version at the tool's level with 'reinstall it'", function()
    local rec = run_check(stubdir(all_stubs({ curl = "exit 1\n", cargo = "echo boom >&2\nexit 3\n" })))
    local c = rec_for(rec, "curl")
    H.eq("warn", c.kind)
    H.match(c.msg, "^curl found %(PATH: .*/bin/curl%) but `%-%-version` fails: ")
    H.eq("reinstall it", c.advice)
    local cargo = rec_for(rec, "cargo")
    H.eq("error", cargo.kind)
    H.eq("reinstall it", cargo.advice)
  end)

  it("a rustup-style rust-analyzer proxy (version fails) is an error with the rustup advice", function()
    local rec = run_check(stubdir(all_stubs({ ["rust-analyzer"] = "echo 'error: component not installed' >&2\nexit 1\n" })))
    local r = rec_for(rec, "rust-analyzer")
    H.eq("error", r.kind)
    H.match(r.msg, "^rust%-analyzer found %(PATH: .*/rust%-analyzer%) but `%-%-version` fails: language server")
    H.eq("rustup component add rust-analyzer", r.advice)
  end)

  it("a failing Mason tool names Mason as the place", function()
    local data = H.tmpdir()
    write_exec(data .. "/nvim/mason/bin/taplo", "exit 1\n")
    local rec = run_check(stubdir(all_stubs()), data)
    local r = rec_for(rec, "taplo")
    H.eq("warn", r.kind)
    H.match(r.msg, "^taplo found %(Mason: .*/mason/bin/taplo%) but `%-%-version` fails")
  end)
end)

describe("health: minimal PATH", function()
  it("with only nvim, git and timeout everything else is missing and rustup warns, returning early", function()
    local dir = H.tmpdir() .. "/min"
    vim.fn.mkdir(dir, "p")
    for _, b in ipairs({ "git", "timeout" }) do
      vim.uv.fs_symlink(vim.fn.exepath(b), dir .. "/" .. b)
    end
    vim.uv.fs_symlink(vim.v.progpath, dir .. "/nvim")
    local rec = run_check(dir)
    H.eq("ok", rec_for(rec, "git").kind)
    for _, b in ipairs(HEALTH_BINS) do
      if b ~= "git" then
        H.match(rec_for(rec, b).msg, "^" .. vim.pesc(b) .. " not found: ", false, b)
      end
    end
    local tc = section(rec, "xynovim: rust toolchain")
    H.eq(1, #tc)
    H.eq("warn", tc[1].kind)
    H.eq("rustup not found", tc[1].msg)
    H.eq("components cannot be checked; install rustup", tc[1].advice)
  end)
end)

describe("health: rust toolchain", function()
  local function toolchain(rustup)
    local rec = run_check(stubdir(all_stubs({ rustup = rustup })))
    return section(rec, "xynovim: rust toolchain")
  end

  it("asks rustup for the installed components of the stable toolchain", function()
    local log = H.tmpdir() .. "/rustup.log"
    toolchain(("echo \"$*\" >> %s\n"):format(log) .. RUSTUP_OK)
    H.eq({ "component list --toolchain stable --installed", "target list --toolchain stable --installed" }, vim.fn.readfile(log))
  end)

  it("ok when clippy and llvm-tools are installed", function()
    local tc = toolchain(RUSTUP_OK)
    H.eq(2, #tc)
    H.eq({ kind = "ok", msg = "stable has clippy: clippy tier and rust-analyzer lints" }, { kind = tc[1].kind, msg = tc[1].msg })
    H.eq({ kind = "ok", msg = "stable has llvm-tools: cargo-llvm-cov coverage (<leader>tc)" }, { kind = tc[2].kind, msg = tc[2].msg })
  end)

  it("warns with the rustup command for each missing component", function()
    local tc = toolchain("printf 'cargo-x86_64\\nrustfmt-x86_64\\n'\n")
    H.eq(3, #tc, "two components and the wasm32 target (this stub answers every call alike)")
    H.eq("warn", tc[1].kind)
    H.eq("stable lacks clippy: clippy tier and rust-analyzer lints", tc[1].msg)
    H.eq("rustup component add --toolchain stable clippy", tc[1].advice)
    H.eq("stable lacks llvm-tools: cargo-llvm-cov coverage (<leader>tc)", tc[2].msg)
    H.eq("rustup component add --toolchain stable llvm-tools", tc[2].advice)
    local only_clippy = toolchain("printf 'clippy-x86_64\\nrustfmt-x86_64\\n'\n")
    H.eq({ "ok", "warn" }, { only_clippy[1].kind, only_clippy[2].kind })
  end)

  it("checks the wasm32-unknown-unknown target: ok when listed, a warn with the rustup command when not, nothing when rustup cannot list", function()
    local with = "case \"$*\" in\n  'target list --toolchain stable --installed') printf 'x86_64-unknown-linux-gnu\\nwasm32-unknown-unknown\\n' ;;\n" .. RUSTUP_OK:match("^case \"%$%*\" in\n(.*)$")
    local tc = toolchain(with)
    H.eq(3, #tc)
    H.eq({ kind = "ok", msg = "stable has the wasm32-unknown-unknown target: web/WASM crates (:RustContext target)" }, { kind = tc[3].kind, msg = tc[3].msg })
    local without = "case \"$*\" in\n  'target list --toolchain stable --installed') printf 'x86_64-unknown-linux-gnu\\n' ;;\n" .. RUSTUP_OK:match("^case \"%$%*\" in\n(.*)$")
    tc = toolchain(without)
    H.eq(3, #tc)
    H.eq("warn", tc[3].kind)
    H.eq("rustup target add --toolchain stable wasm32-unknown-unknown", tc[3].advice)
    H.eq(2, #toolchain(RUSTUP_OK), "target list fails: no record")
  end)

  it("warns 'stable toolchain not installed' when rustup fails", function()
    local tc = toolchain("echo 'error: toolchain stable is not installed' >&2\nexit 1\n")
    H.eq(1, #tc)
    H.eq("warn", tc[1].kind)
    H.eq("stable toolchain not installed", tc[1].msg)
    H.eq("rustup toolchain install stable", tc[1].advice)
  end)
end)

-- ------------------------------------------------------------------ bootstrap

local LOCK_ORIG = '{"a": {"commit": "1111"}}\n'

--- A temp checkout holding a copy of scripts/bootstrap.sh and a lockfile, an
--- XDG_CONFIG_HOME linking nvim to it, and a bin dir with coreutils symlinks
--- plus a stub nvim that logs its arguments and (per env) rewrites the lockfile.
local function mkcheckout(opts)
  opts = opts or {}
  local root = H.tmpdir()
  local ck = root .. "/checkout"
  vim.fn.mkdir(ck .. "/scripts", "p")
  vim.fn.mkdir(root .. "/cfg", "p")
  vim.fn.mkdir(root .. "/tmp", "p")
  vim.fn.mkdir(root .. "/home", "p")
  sh({ "cp", repo .. "/scripts/bootstrap.sh", ck .. "/scripts/bootstrap.sh" })
  sh({ "cp", repo .. "/scripts/provision.lua", ck .. "/scripts/provision.lua" })
  vim.fn.writefile(vim.split(LOCK_ORIG:sub(1, -2), "\n"), ck .. "/lazy-lock.json")
  if not opts.nolink then
    vim.uv.fs_symlink(ck, root .. "/cfg/nvim")
  end
  local bin = root .. "/bin"
  vim.fn.mkdir(bin, "p")
  for _, c in ipairs({ "dirname", "readlink", "mktemp", "cp", "rm", "cmp", "diff", "cat" }) do
    vim.uv.fs_symlink(vim.fn.exepath(c), bin .. "/" .. c)
  end
  local log = root .. "/nvim.log"
  write_exec(
    bin .. "/nvim",
    ([[
echo "nvim $*" >> %s
case "$2" in
  '+Lazy! install') [ -n "$FAKE_INSTALL" ] && echo '{"clobbered": true}' > "$LOCK" ;;
  '+Lazy! restore')
    echo "restore sees: $(cat "$LOCK")" >> %s
    [ -n "$FAKE_RESTORE" ] && echo '{"a": {"commit": "2222"}}' > "$LOCK" ;;
esac
exit 0
]]):format(log, log)
  )
  return {
    root = root,
    ck = ck,
    bin = bin,
    log = log,
    lock = ck .. "/lazy-lock.json",
    script = ck .. "/scripts/bootstrap.sh",
    tmp = root .. "/tmp",
    --- stub the prerequisite tools (all but `except`); rust-analyzer's version can be made to fail
    stub_prereqs = function(_, except, ra_fails)
      except = except or {}
      for _, t in ipairs({ "nvim", "git", "curl", "tar", "unzip", "gzip", "gcc", "npm", "node", "cargo", "rustup", "rust-analyzer" }) do
        if not vim.tbl_contains(except, t) and t ~= "nvim" then
          write_exec(bin .. "/" .. t, (t == "rust-analyzer" and ra_fails) and "exit 1\n" or "echo stub\n")
        end
      end
    end,
    run = function(self, env)
      env = vim.tbl_extend("force", {
        PATH = self.bin,
        XDG_CONFIG_HOME = self.root .. "/cfg",
        HOME = self.root .. "/home",
        TMPDIR = self.tmp,
        LOCK = self.lock,
      }, env or {})
      return sh({ "/usr/bin/bash", self.script }, { env = env, clear_env = true, cwd = self.ck })
    end,
  }
end

local function log_lines(c)
  return vim.fn.filereadable(c.log) == 1 and vim.fn.readfile(c.log) or {}
end

describe("bootstrap.sh: static", function()
  it("is executable, uses strict mode and parses with bash -n", function()
    local st = vim.uv.fs_stat(repo .. "/scripts/bootstrap.sh")
    H.ok(bit.band(st.mode, tonumber("111", 8)) == tonumber("111", 8), "mode " .. string.format("%o", st.mode))
    H.eq("#!/usr/bin/env bash", vim.fn.readfile(repo .. "/scripts/bootstrap.sh", "", 1)[1])
    H.match(read("scripts/bootstrap.sh"), "\nset %-euo pipefail\n")
    local r = sh({ "bash", "-n", repo .. "/scripts/bootstrap.sh" })
    H.eq(0, r.code, r.stderr)
  end)

  it("shellcheck finds nothing (when installed)", function()
    if vim.fn.executable("shellcheck") ~= 1 then
      skip("shellcheck not installed")
    end
    local r = sh({ "shellcheck", repo .. "/scripts/bootstrap.sh", repo .. "/scripts/test.sh" })
    H.eq(0, r.code, r.stdout)
  end)

  it("shellcheck-style sanity: quoted expansions of paths, no bare rm -rf, trap cleans the temp copy", function()
    local s = read("scripts/bootstrap.sh")
    H.no_match(s, "rm %-rf")
    H.has(s, "trap 'rm -f \"$orig\"' EXIT")
    H.has(s, 'cp "$lock" "$orig"')
    H.has(s, 'cp "$orig" "$lock"')
  end)
end)

describe("bootstrap.sh: config link check", function()
  it("exits 1 naming the config dir and prints the ln -s hint when nvim is not linked to the checkout", function()
    local c = mkcheckout({ nolink = true })
    local other = c.root .. "/other"
    vim.fn.mkdir(other, "p")
    vim.uv.fs_symlink(other, c.root .. "/cfg/nvim")
    local r = c:run({ BOOTSTRAP_SKIP_PREREQS = "1" })
    H.eq(1, r.code)
    H.has(r.stderr, ("bootstrap: %s/cfg/nvim is not this checkout (%s)."):format(c.root, c.ck))
    H.has(r.stderr, ("ln -s '%s' '%s/cfg/nvim'"):format(c.ck, c.root))
    H.eq({}, log_lines(c), "nvim must not run")
  end)

  it("exits 1 when there is no nvim config at all", function()
    local c = mkcheckout({ nolink = true })
    local r = c:run({ BOOTSTRAP_SKIP_PREREQS = "1" })
    H.eq(1, r.code)
    H.has(r.stderr, "is not this checkout")
  end)

  it("falls back to ~/.config/nvim when XDG_CONFIG_HOME is unset", function()
    local c = mkcheckout({ nolink = true })
    vim.fn.mkdir(c.root .. "/home/.config", "p")
    -- wrong link: reported with the HOME path
    local r = c:run({ BOOTSTRAP_SKIP_PREREQS = "1", XDG_CONFIG_HOME = "" })
    -- (an empty XDG_CONFIG_HOME falls back too: ${VAR:-...})
    H.eq(1, r.code)
    H.has(r.stderr, c.root .. "/home/.config/nvim is not this checkout")
    -- right link: proceeds to the install steps
    vim.uv.fs_symlink(c.ck, c.root .. "/home/.config/nvim")
    local r2 = c:run({ BOOTSTRAP_SKIP_PREREQS = "1", XDG_CONFIG_HOME = "" })
    H.eq(0, r2.code, r2.stderr)
  end)

  it("accepts a config that is the checkout itself (not a link)", function()
    local c = mkcheckout({ nolink = true })
    local r = c:run({ BOOTSTRAP_SKIP_PREREQS = "1", XDG_CONFIG_HOME = c.root })
    -- <root>/nvim does not exist: refused
    H.eq(1, r.code)
    sh({ "mv", c.ck, c.root .. "/nvim" })
    local script = c.root .. "/nvim/scripts/bootstrap.sh"
    local env = { PATH = c.bin, XDG_CONFIG_HOME = c.root, HOME = c.root .. "/home", TMPDIR = c.tmp, BOOTSTRAP_SKIP_PREREQS = "1", LOCK = c.root .. "/nvim/lazy-lock.json" }
    local r2 = sh({ "/usr/bin/bash", script }, { env = env, clear_env = true })
    H.eq(0, r2.code, r2.stderr)
  end)
end)

describe("bootstrap.sh: prerequisites", function()
  it("passes silently when all are present", function()
    local c = mkcheckout()
    c:stub_prereqs()
    local r = c:run()
    H.eq(0, r.code, r.stderr)
    H.no_match(r.stderr, "missing prerequisites", true)
  end)

  it("lists every missing prerequisite and exits 1 before touching nvim", function()
    local c = mkcheckout()
    c:stub_prereqs({ "unzip", "gcc", "npm", "node", "rustup" })
    local r = c:run()
    H.eq(1, r.code)
    H.has(r.stderr, "bootstrap: missing prerequisites:\n")
    for _, t in ipairs({ "unzip", "gcc", "npm", "node", "rustup" }) do
      H.has(r.stderr, "\n  - " .. t .. "\n")
    end
    for _, t in ipairs({ "git", "curl", "tar", "cargo", "nvim" }) do
      H.no_match(r.stderr, "  - " .. t .. "\n", true)
    end
    H.has(r.stderr, "Install them (or set BOOTSTRAP_SKIP_PREREQS=1 to go on anyway) and rerun.")
    H.eq({}, log_lines(c), "nvim must not run")
  end)

  it("checks nvim, git, curl, tar, unzip, gzip, gcc, npm, node, cargo, rustup and rust-analyzer", function()
    local c = mkcheckout()
    -- bin holds only coreutils + the nvim stub: everything else is missing, in loop order
    local r = c:run()
    H.eq(1, r.code)
    local listed = {}
    for t in r.stderr:gmatch("\n  %- ([^\n]+)") do
      listed[#listed + 1] = t
    end
    -- nvim is present (stub), the other eleven are listed in the script's order
    H.eq({ "git", "curl", "tar", "unzip", "gzip", "gcc", "npm", "node", "cargo", "rustup", "rust-analyzer" }, listed)
    local c2 = mkcheckout()
    sh({ "rm", c2.bin .. "/nvim" })
    c2:stub_prereqs()
    local r2 = c2:run()
    H.eq(1, r2.code)
    H.has(r2.stderr, "\n  - nvim\n")
  end)

  it("reports a rust-analyzer that is only a rustup proxy (version fails)", function()
    local c = mkcheckout()
    c:stub_prereqs({}, true)
    local r = c:run()
    H.eq(1, r.code)
    H.has(r.stderr, "  - rust-analyzer (installed as a rustup proxy only: rustup component add rust-analyzer)\n")
  end)

  it("BOOTSTRAP_SKIP_PREREQS=1 skips the check", function()
    local c = mkcheckout()
    local r = c:run({ BOOTSTRAP_SKIP_PREREQS = "1" })
    H.eq(0, r.code, r.stderr)
    H.no_match(r.stderr, "missing prerequisites", true)
    H.eq(3, #vim.tbl_filter(function(l) return l:find("^nvim ") end, log_lines(c)))
  end)
end)

describe("bootstrap.sh: two-step restore", function()
  it("runs Lazy! install, restores the original lockfile, then Lazy! restore; unchanged -> exit 0", function()
    local c = mkcheckout()
    local r = c:run({ BOOTSTRAP_SKIP_PREREQS = "1", FAKE_INSTALL = "1" })
    H.eq(0, r.code, r.stderr)
    H.has(r.stdout, "bootstrap: step 1/3, Lazy! install\n")
    H.has(r.stdout, "bootstrap: step 2/3, Lazy! restore\n")
    H.has(r.stdout, "bootstrap: done, lazy-lock.json unchanged.\n")
    local log = log_lines(c)
    H.eq("nvim --headless +Lazy! install +qa", log[1])
    -- install clobbered the lockfile; step 2 must see the original again
    H.eq("nvim --headless +Lazy! restore +qa", log[2])
    H.eq("restore sees: " .. vim.trim(LOCK_ORIG), log[3])
    -- step 3: parsers and Mason tools, via scripts/provision.lua of the checkout
    H.has(log[4], "provision.lua")
    H.eq(LOCK_ORIG, table.concat(vim.fn.readfile(c.lock), "\n") .. "\n")
  end)

  it("a changed lockfile after restore: prints the diff, puts the original back and exits 1", function()
    local c = mkcheckout()
    local r = c:run({ BOOTSTRAP_SKIP_PREREQS = "1", FAKE_INSTALL = "1", FAKE_RESTORE = "1" })
    H.eq(1, r.code)
    H.has(r.stderr, "bootstrap: lazy-lock.json changed during restore (some plugin is not on its pinned commit):")
    H.has(r.stderr, '< {"a": {"commit": "1111"}}')
    H.has(r.stderr, '> {"a": {"commit": "2222"}}')
    H.no_match(r.stdout, "done, lazy-lock.json unchanged", true)
    H.eq(LOCK_ORIG, table.concat(vim.fn.readfile(c.lock), "\n") .. "\n")
  end)

  it("removes its temp copy of the lockfile on success and on failure", function()
    for _, env in ipairs({ {}, { FAKE_RESTORE = "1" } }) do
      local c = mkcheckout()
      c:run(vim.tbl_extend("force", { BOOTSTRAP_SKIP_PREREQS = "1" }, env))
      H.eq({}, vim.fn.readdir(c.tmp), "TMPDIR must be empty afterwards")
    end
  end)

  it("a failing nvim step aborts the script (set -e) and still removes the temp copy", function()
    local c = mkcheckout()
    write_exec(c.bin .. "/nvim", "exit 7\n")
    local r = c:run({ BOOTSTRAP_SKIP_PREREQS = "1" })
    H.eq(7, r.code)
    H.no_match(r.stdout, "step 2/2", true)
    H.eq({}, vim.fn.readdir(c.tmp))
  end)
end)

describe("bootstrap.sh: fresh install (network)", function()
  it("fresh XDG dirs: exit 0, lockfile unchanged, kulala on v5.3.4 (6656c9d) with only doc/tags untracked", function()
    if vim.env.XYNO_TEST_NETWORK ~= "1" then
      skip("network/slow test: set XYNO_TEST_NETWORK=1 to run (clones ~60 plugins)")
    end
    for _, t in ipairs({ "git", "curl", "gcc", "node", "cargo" }) do
      if vim.fn.executable(t) ~= 1 then
        skip(t .. " not found")
      end
    end
    local root = H.tmpdir()
    for _, d in ipairs({ "cfg", "data", "state", "cache" }) do
      vim.fn.mkdir(root .. "/" .. d, "p")
    end
    vim.uv.fs_symlink(repo, root .. "/cfg/nvim")
    local before = read("lazy-lock.json")
    local env = vim.tbl_extend("force", vim.fn.environ(), {
      XDG_CONFIG_HOME = root .. "/cfg",
      XDG_DATA_HOME = root .. "/data",
      XDG_STATE_HOME = root .. "/state",
      XDG_CACHE_HOME = root .. "/cache",
      BOOTSTRAP_SKIP_PREREQS = "1",
    })
    local r = sh({ "bash", repo .. "/scripts/bootstrap.sh" }, { env = env, timeout_ms = 20 * 60 * 1000 })
    H.eq(0, r.code, r.stderr)
    H.eq(before, read("lazy-lock.json"))
    local k = root .. "/data/nvim/lazy/kulala.nvim"
    H.eq("6656c9d", H.git(k, "rev-parse", "--short=7", "HEAD"))
    H.match(H.git(k, "describe", "--tags", "--always"), "^v5%.3%.4")
    H.eq("?? doc/tags", H.git(k, "status", "--porcelain"))
  end)
end)

-- ------------------------------------------------------------------------- CI

local ci = read(".github/workflows/ci.yml")

--- The steps of the smoke job as { text = chunk, name = ... }, in order.
local function ci_steps()
  local steps, cur = {}, nil
  local in_steps = false
  for _, l in ipairs(vim.split(ci, "\n")) do
    if l:match("^    steps:") then
      in_steps = true
    elseif in_steps and l:match("^      %- ") then
      cur = { text = l .. "\n" }
      steps[#steps + 1] = cur
    elseif cur then
      cur.text = cur.text .. l .. "\n"
    end
  end
  for _, s in ipairs(steps) do
    s.name = s.text:match("name: ([^\n]+)")
  end
  return steps
end

--- The `run: |` block of a step, dedented, as a string.
local function run_block(step)
  local out, on = {}, false
  for _, l in ipairs(vim.split(step.text, "\n")) do
    if on then
      if l:match("^          ") or l == "" then
        out[#out + 1] = l:sub(11)
      else
        break
      end
    elseif l:match("^        run: |") then
      on = true
    end
  end
  return table.concat(out, "\n")
end

describe("ci.yml", function()
  it("is named ci and triggers on push to main and on pull requests", function()
    H.match(ci, "^name: ci\n")
    H.has(ci, "\non:\n  push:\n    branches: [main]\n  pull_request:\n")
  end)

  it("has read-only contents permission and one job 'smoke' on ubuntu-latest, 15 minute timeout", function()
    H.has(ci, "\npermissions:\n  contents: read\n")
    local jobs = "\n" .. ci:match("\njobs:\n(.*)$")
    local names = {}
    for n in jobs:gmatch("\n  ([%w_-]+):") do
      names[#names + 1] = n
    end
    H.eq({ "smoke" }, names)
    H.has(ci, "    runs-on: ubuntu-latest\n")
    H.has(ci, "    timeout-minutes: 15\n")
  end)

  it("pins actions/checkout to the commit hash with persist-credentials false", function()
    local steps = ci_steps()
    H.match(steps[1].text, "uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683", true)
    H.match(steps[1].text, "persist%-credentials: false")
  end)

  it("has no unpinned third-party action", function()
    local n = 0
    for ref in ci:gmatch("uses:%s*([^%s#]+)") do
      n = n + 1
      H.match(ref, "^[%w_.-]+/[%w_./-]+@%x+$")
      H.eq(40, #ref:match("@(%x+)$"), ref .. " must be pinned to a full commit hash")
    end
    H.ok(n >= 1)
  end)

  it("runs the steps in the documented order", function()
    local steps = ci_steps()
    local want = {
      { "checkout", "uses: actions/checkout@" },
      { "install nvim", "Install Neovim stable" },
      { "link config", "Use the checkout as the Neovim config" },
      { "rust-analyzer", "Add rust%-analyzer" },
      { "bootstrap", "Restore plugins from the lockfile" },
      { "lock 1", "Lockfile unchanged" },
      { "smoke", "Startup smoke test" },
      { "specs", "Spec suite" },
      { "lock 2", "Lockfile still unchanged" },
    }
    H.eq(#want, #steps)
    for i, w in ipairs(want) do
      H.match(steps[i].text, w[2], false, "step " .. i .. " (" .. w[1] .. ")")
    end
  end)

  it("step contents: nvim tarball into $HOME/nvim and PATH, symlink, rustup, bootstrap, lockfile checks, test.sh", function()
    local s = ci_steps()
    local install = run_block(s[2])
    H.has(install, "curl -fsSL -o nvim.tar.gz https://github.com/neovim/neovim/releases/download/stable/nvim-linux-x86_64.tar.gz")
    H.has(install, 'tar -xzf nvim.tar.gz -C "$HOME/nvim" --strip-components=1')
    H.has(install, 'echo "$HOME/nvim/bin" >> "$GITHUB_PATH"')
    H.has(run_block(s[3]), 'ln -s "$GITHUB_WORKSPACE" "$HOME/.config/nvim"')
    H.has(s[4].text, "run: rustup component add rust-analyzer")
    H.has(s[5].text, "run: scripts/bootstrap.sh")
    H.has(s[6].text, "run: git diff --exit-code lazy-lock.json")
    H.has(s[8].text, "run: scripts/test.sh")
    H.has(s[9].text, "run: git diff --exit-code lazy-lock.json")
  end)

  describe("startup smoke step", function()
    local function run_smoke(nvim_body)
      local dir = H.tmpdir()
      local bin = dir .. "/bin"
      write_exec(bin .. "/nvim", nvim_body)
      for _, c in ipairs({ "date", "cat", "sleep" }) do
        vim.uv.fs_symlink(vim.fn.exepath(c), bin .. "/" .. c)
      end
      local script = dir .. "/smoke.sh"
      vim.fn.writefile(vim.split(run_block(ci_steps()[7]), "\n"), script)
      local r = sh({ "/usr/bin/bash", "-e", script }, { env = { PATH = bin, RUNNER_TEMP = dir }, clear_env = true, cwd = dir })
      return r, dir
    end

    it("passes for a quiet, fast nvim", function()
      local r = run_smoke("exit 0\n")
      H.eq(0, r.code, r.stdout .. r.stderr)
      H.match(r.stdout, "headless startup: %d+ ms")
    end)

    it("fails on any stderr output, and shows it", function()
      local r = run_smoke("echo 'E5108: Lua error boom' >&2\nexit 0\n")
      H.eq(1, r.code)
      H.has(r.stdout, "E5108: Lua error boom")
    end)

    it("fails when startup takes more than 3000 ms", function()
      local r = run_smoke("sleep 3.2\nexit 0\n")
      H.eq(1, r.code)
      H.has(r.stdout, "startup slower than 3000 ms")
    end)
  end)

  it("parses as YAML", function()
    local ok, parser = pcall(vim.treesitter.get_string_parser, ci, "yaml")
    if not ok then
      skip("no yaml tree-sitter parser: " .. tostring(parser))
    end
    H.not_ok(parser:parse()[1]:root():has_error(), "yaml parse errors")
  end)

  it("actionlint reports no findings (when installed)", function()
    if vim.fn.executable("actionlint") ~= 1 then
      skip("actionlint not installed")
    end
    local r = sh({ "actionlint", repo .. "/.github/workflows/ci.yml" })
    H.eq(0, r.code, r.stdout .. r.stderr)
  end)

  it("zizmor reports no findings (when installed)", function()
    if vim.fn.executable("zizmor") ~= 1 then
      skip("zizmor not installed")
    end
    -- --offline: no GitHub API lookups; online-only audits are not run
    local r = sh({ "zizmor", "--offline", "--no-progress", repo .. "/.github/workflows/ci.yml" }, { env = { HOME = H.tmpdir(), PATH = vim.env.PATH } })
    H.eq(0, r.code, r.stdout .. r.stderr)
  end)
end)

-- --------------------------------------------------------- Makefile and others

describe("Makefile", function()
  local mk = read("Makefile")

  it("declares test and coverage .PHONY", function()
    H.match(mk, "\n%.PHONY: test coverage\n")
  end)

  it("test runs scripts/test.sh $(ARGS), coverage adds --coverage", function()
    H.match(mk, "\ntest:\n\tscripts/test%.sh %$%(ARGS%)\n")
    H.match(mk, "\ncoverage:\n\tscripts/test%.sh %-%-coverage %$%(ARGS%)\n")
  end)

  it("make -n expands the targets to the script calls, passing ARGS", function()
    if vim.fn.executable("make") ~= 1 then
      skip("make not installed")
    end
    local r = sh({ "make", "-n", "--no-print-directory", "-C", repo, "test", "ARGS=smoke -v" })
    H.eq(0, r.code, r.stderr)
    H.eq("scripts/test.sh smoke -v", vim.trim(r.stdout))
    local r2 = sh({ "make", "-n", "--no-print-directory", "-C", repo, "coverage", "ARGS=routes" })
    H.eq("scripts/test.sh --coverage routes", vim.trim(r2.stdout))
  end)
end)

describe("stylua", function()
  it("stylua.toml: spaces, width 2, column 120", function()
    local t = read("stylua.toml")
    H.match(t, 'indent_type = "Spaces"', true)
    H.match(t, "indent_width = 2", true)
    H.match(t, "column_width = 120", true)
  end)

  it("stylua --check lua/ runs with that config; style drift is informational", function()
    local bin = vim.fn.exepath("stylua")
    if bin == "" and vim.fn.executable(vim.fn.stdpath("data") .. "/mason/bin/stylua") == 1 then
      bin = vim.fn.stdpath("data") .. "/mason/bin/stylua"
    end
    if bin == "" then
      skip("stylua not installed")
    end
    local r = sh({ bin, "--check", "lua/" }, { cwd = repo })
    -- 0 = clean, 1 = formatting differences; anything else is a config/parse error
    H.ok(r.code == 0 or r.code == 1, ("stylua exit %d: %s"):format(r.code, r.stderr))
    local drift = {}
    for f in (r.stdout .. r.stderr):gmatch("Diff in ([^%s:]+)") do
      drift[f] = true
    end
    H.no_match(r.stderr, "error", false)
    for f in pairs(drift) do
      H.match(f, "^lua/.+%.lua$")
    end
    -- known drift (informational): the two plugin files that use a different style
    if r.code == 1 then
      print(("[stylua] %d file(s) differ from stylua.toml, e.g. %s"):format(vim.tbl_count(drift), next(drift)))
    end
  end)
end)

describe(".gitignore and LICENSE", function()
  local function ignored(paths)
    local d = H.tmpdir()
    sh({ "cp", repo .. "/.gitignore", d .. "/.gitignore" })
    H.git(d, "init", "-q", "-b", "main")
    local out = {}
    for _, p in ipairs(paths) do
      out[p] = sh({ "git", "check-ignore", "-q", "--no-index", p }, { cwd = d }).code == 0
    end
    return out
  end

  it("ignores tt.*, .tests, doc/tags, debug, .repro, foo.*, *.log and data", function()
    local want = { "tt.lua", "tt.out", ".tests", ".tests/x", "doc/tags", "debug", ".repro", "foo.lua", "foo.txt", "a.log", "lua/x/b.log", "data" }
    local got = ignored(want)
    for _, p in ipairs(want) do
      H.ok(got[p], p .. " should be ignored")
    end
  end)

  it("does not ignore ordinary files", function()
    local keep = { "lua/config/lazy.lua", "README.md", "lazy-lock.json", "doc/other.txt", "tests/foo_spec.lua", "scripts/bootstrap.sh", "tt", "foo" }
    local got = ignored(keep)
    for _, p in ipairs(keep) do
      H.not_ok(got[p], p .. " should not be ignored")
    end
  end)

  it("'data' also hides stdpath-style data directories at any depth", function()
    local got = ignored({ "data/nvim/lazy/x", "a/data", "a/data/b/c.lua", "xdg/data/nvim/mason" })
    for p, v in pairs(got) do
      H.ok(v, p .. " should be ignored")
    end
  end)

  it("LICENSE is the Apache License 2.0", function()
    local l = read("LICENSE")
    H.has(l, "Apache License\n")
    H.has(l, "Version 2.0, January 2004")
    H.has(l, "http://www.apache.org/licenses/")
    H.has(l, "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION")
  end)
end)

describe("README prerequisites vs health TOOLS and bootstrap", function()
  local readme = read("README.md")
  local prereq = readme:match("\nPrerequisites .-\n\n(.-)\n\n```")

  --- Names in `backticks` of one prerequisite bullet.
  local function names(prefix)
    for l in prereq:gmatch("[^\n]+") do
      if l:find(prefix, 1, true) then
        local out = {}
        for n in l:gmatch("`([%w_-]+)`") do
          out[#out + 1] = n
        end
        return out, l
      end
    end
  end

  it("has the four prerequisite bullets", function()
    H.ok(prereq, "prerequisite block not found")
    H.ok(names("- Required to bring the config up"))
    H.ok(names("- Required for the Rust workflow"))
    H.ok(names("- Installed by Mason"))
    H.ok(names("- Optional"))
  end)

  it("every tool the README names is checked by health, by bootstrap, or explained", function()
    local rec = run_check(stubdir({}))
    local health = {}
    for _, b in ipairs(HEALTH_BINS) do
      health[b] = true
    end
    local bootstrap = read("scripts/bootstrap.sh")
    local loop = bootstrap:match("for tool in ([^;]+); do")
    local boot = {}
    for t in loop:gmatch("%S+") do
      boot[t] = true
    end
    -- explained: nvim is the running editor (bootstrap checks it), rustup is checked in
    -- health's "rust toolchain" section, `bacon` is explicitly NOT needed (not a backtick tool here)
    local explained = {
      nvim = "editor itself (bootstrap checks it)",
      rustup = "health rust toolchain section",
      ["markdown-toc"] = "npm package Mason installs",
      ["markdownlint-cli2"] = "npm package Mason installs",
      ["yaml-language-server"] = "npm package Mason installs",
      marksman = "Mason package",
      ["lua-language-server"] = "Mason package",
      ["json-lsp"] = "Mason package",
      ["tree-sitter-cli"] = "Mason package (health checks the tree-sitter binary)",
      stylua = "Mason package",
      shfmt = "Mason package",
    }
    local all = {}
    for _, p in ipairs({ "- Required to bring the config up", "- Required for the Rust workflow", "- Installed by Mason", "- Optional" }) do
      for _, n in ipairs((names(p))) do
        all[#all + 1] = n
      end
    end
    local seen = {}
    for _, n in ipairs(all) do
      seen[n] = true
      if n:match("^[%l-]+$") and n ~= "bacon" and n ~= "rustup" and n ~= "stable" and n ~= "clippy" and n ~= "llvm-tools" and n ~= "lazy" then
        H.ok(health[n] or boot[n] or explained[n] or n == "wgsl-analyzer", n .. " is named by the README but neither checked nor explained")
      end
    end
    for _, n in ipairs({ "nvim", "git", "curl", "tar", "unzip", "gcc", "node", "npm", "cargo", "rustup", "rust-analyzer", "bacon-ls", "codelldb", "taplo", "wgsl-analyzer", "mold", "clang", "cargo-nextest", "cargo-deny", "lazygit", "delta", "bwrap" }) do
      H.ok(seen[n], "README no longer names " .. n)
    end
    -- the required bring-up tools are all in bootstrap's prerequisite loop
    for _, n in ipairs({ "nvim", "git", "curl", "tar", "unzip", "gcc", "node", "npm", "cargo", "rustup", "rust-analyzer" }) do
      H.ok(boot[n], n .. " missing from bootstrap's prerequisite loop")
    end
    -- every health tool the README calls required/optional is listed in README text somewhere
    for _, b in ipairs(HEALTH_BINS) do
      H.ok(seen[b], "health checks " .. b .. " but the README prerequisites do not name it")
    end
    H.ok(#rec > 0)
  end)

  it("wgsl-analyzer (Mason) and cargo-expand are checked by :checkhealth", function()
    H.has(prereq, "`wgsl-analyzer`")
    H.has(read("lua/plugins/domain.lua"), 'ensure_installed = { "wgsl-analyzer" }')
    local rec = run_check(stubdir(all_stubs()))
    H.has(rec_for(rec, "wgsl-analyzer").msg, "wgsl-analyzer (PATH)")
    H.has(rec_for(rec, "cargo-expand").msg, "cargo-expand (PATH)")
    H.has(rec_for(rec, "gzip").msg, "gzip (PATH)")
  end)
end)

describe("lua/config/lazy.lua", function()
  it("loaded lazy with the checker and luarocks off and island-dark as install colourscheme", function()
    local o = require("lazy.core.config").options
    H.eq(false, o.checker.enabled)
    H.eq(false, o.rocks.enabled)
    H.eq(false, o.defaults.lazy)
    H.eq(false, o.defaults.version)
    H.has(o.install.colorscheme, "island-dark")
  end)

  it("clones lazy.nvim (stable) when it is missing, from the official repo", function()
    local s = read("lua/config/lazy.lua")
    H.has(s, 'local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"')
    H.has(s, "--branch=stable")
    H.has(s, "https://github.com/folke/lazy.nvim.git")
  end)
end)
