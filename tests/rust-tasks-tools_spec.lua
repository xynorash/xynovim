-- config.rust_tasks (:RustTargets, :RustTools, :ActJob, :RustNew, doctests) and
-- lua/plugins/coverage.lua (<leader>tc, nvim-coverage opts, lcov backend).
-- Snacks.picker / Snacks.terminal / vim.ui / vim.system are stubbed where the
-- spec only needs to see what would run; real cargo is used for metadata,
-- `cargo new` and the one end-to-end coverage run.
local H = require("xynotest.helpers")
local rc = require("config.rust_context")
local tasks = require("config.rust_tasks")

-- ------------------------------------------------------------------- stubs

local restores = {}

--- Replace t[k] by v until the end of the test.
local function stub(t, k, v)
  local orig = t[k]
  t[k] = v
  restores[#restores + 1] = function()
    t[k] = orig
  end
end

local function unstub_all()
  for i = #restores, 1, -1 do
    pcall(restores[i])
  end
  restores = {}
end

after_each(function()
  unstub_all()
  pcall(vim.cmd, "silent! %bwipeout!")
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
end)

--- Stub the stored :RustContext of every root.
local function with_ctx(ctx)
  stub(rc, "get", function()
    return ctx
  end)
end

--- Stub Snacks.picker; returns the table the picker options land in.
local function capture_picker()
  local cap = {}
  stub(Snacks, "picker", function(opts)
    cap.opts = opts
    return opts
  end)
  return cap
end

--- Stub Snacks.terminal.open/get; `existing` is what get() returns.
local function capture_term(existing)
  local cap = { opened = {}, gets = {} }
  stub(Snacks.terminal, "get", function(cmd, opts)
    cap.gets[#cap.gets + 1] = { cmd = cmd, opts = opts }
    return existing
  end)
  cap.terms = {}
  stub(Snacks.terminal, "open", function(cmd, opts)
    cap.opened[#cap.opened + 1] = { cmd = cmd, opts = opts }
    local t = {
      buf_valid = function()
        return true
      end,
      close = function(self, o)
        self.closed = o
      end,
    }
    cap.terms[#cap.terms + 1] = t
    return t
  end)
  return cap
end

--- Answer `cargo metadata` with `meta` (a Lua table); anything else goes to
--- the real vim.system (the LSP clients use it too).
local function fake_metadata(meta)
  local real = vim.system
  stub(vim, "system", function(cmd, opts, cb)
    if cmd[1] == "cargo" and cmd[2] == "metadata" then
      local res = { code = 0, stdout = vim.json.encode(meta), stderr = "" }
      return {
        wait = function()
          return res
        end,
      }
    end
    return real(cmd, opts, cb)
  end)
end

--- The item of a picker whose text starts with `prefix`.
local function item(opts, prefix)
  for _, it in ipairs(opts.items) do
    if it.text:sub(1, #prefix) == prefix then
      return it
    end
  end
  error(
    ("no picker item starting with %q in %s"):format(
      prefix,
      vim.inspect(vim.tbl_map(function(i)
        return i.text
      end, opts.items))
    ),
    2
  )
end

--- Copy of the `all` fixture (lib, bin `tool`, example, test, bench; features
--- default=[a], a, b) as the current directory and buffer.
local function open_all()
  return H.open_fixture("rust-tasks-tools-all", "src/main.rs")
end

--- A buffer in a directory with no Cargo.toml above it.
local function open_outside_crate()
  local dir = H.tmpdir()
  vim.cmd.cd(vim.fn.fnameescape(dir))
  vim.fn.writefile({ "x" }, dir .. "/note.txt")
  H.open(dir .. "/note.txt")
  return dir
end

local function wait_notify(cap, pat, ms)
  return H.wait_for(function()
    for _, n in ipairs(cap.list) do
      if n.msg:find(pat, 1, true) then
        return n
      end
    end
  end, ms or 5000, "notification " .. pat)
end

-- ============================================================ 1. commands

describe("rust_tasks.setup commands", function()
  local function check(name, nargs, desc)
    local c = H.ok(vim.api.nvim_get_commands({})[name], name .. " is not defined")
    H.eq(nargs, c.nargs, name .. " nargs")
    H.eq(desc, c.definition, name .. " desc")
  end

  it("defines RustTargets, RustTools, ActJob and RustNew with their descs", function()
    check("RustTargets", "0", "Run/test/bench a cargo target")
    check("RustTools", "0", "Cargo tools: deny, audit, bloat, timings, ...")
    check("ActJob", "0", "Run the GitHub Actions job under the cursor with act")
    check("RustNew", "?", "cargo new in the current directory")
  end)
end)

-- ===================================================== 2. targets: errors

describe(":RustTargets errors", function()
  it("warns outside a crate", function()
    open_outside_crate()
    local n = H.capture_notify()
    local cap = capture_picker()
    vim.cmd("RustTargets")
    H.eq(1, #n.list)
    H.eq("no Cargo.toml found", n.list[1].msg)
    H.eq(vim.log.levels.WARN, n.list[1].level)
    H.is_nil(cap.opts, "no picker outside a crate")
  end)

  it("reports a cargo metadata failure as ERROR", function()
    H.need_rust()
    local dir = H.tmpdir()
    vim.fn.writefile({ "[package]", "this is not toml" }, dir .. "/Cargo.toml")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    H.open(dir .. "/Cargo.toml")
    local n = H.capture_notify()
    local cap = capture_picker()
    vim.cmd("RustTargets")
    H.eq(1, #n.list)
    H.match(n.list[1].msg, "^cargo metadata failed: ")
    H.match(n.list[1].msg, "Cargo.toml", true, "carries cargo's stderr")
    H.eq(vim.log.levels.ERROR, n.list[1].level)
    H.is_nil(cap.opts)
  end)
end)

-- ================================================ 3-6. targets: the items

describe(":RustTargets items", function()
  before_each(function()
    H.need_rust()
  end)

  local function targets_for_all(ctx)
    with_ctx(ctx)
    local dir = open_all()
    local cap = capture_picker()
    vim.cmd("RustTargets")
    return H.ok(cap.opts, "picker was not opened"), dir
  end

  it("builds run/test/build + samply + flamegraph for a bin, run/build for an example, test, bench, and the lib trio", function()
    local opts = targets_for_all(nil)
    local t = vim.tbl_map(function(i)
      return i.text
    end, opts.items)
    table.sort(t)
    H.eq({
      "bench  bench bn (rtt_all)",
      "build  bin tool (rtt_all)",
      "build  example ex (rtt_all)",
      "build  lib rtt_all (rtt_all)",
      "doc-test  lib rtt_all (rtt_all)",
      "flamegraph  bin tool (rtt_all)",
      "run  bin tool (rtt_all)",
      "run  example ex (rtt_all)",
      "samply  bin tool (rtt_all)",
      "test  bin tool (rtt_all)",
      "test  lib rtt_all (rtt_all)",
      "test  test it (rtt_all)",
    }, t)
    H.eq("text", opts.format)
  end)

  it("treats proc-macro, rlib, cdylib, staticlib and dylib targets as libs", function()
    local kinds = { "proc-macro", "rlib", "cdylib", "staticlib", "dylib" }
    local targets = {}
    for _, k in ipairs(kinds) do
      targets[#targets + 1] = { name = "t_" .. k:gsub("%-", "_"), kind = { k } }
    end
    local dir = H.fixture("rust-tasks-tools-all")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    H.open(dir .. "/src/main.rs")
    fake_metadata({ target_directory = dir .. "/target", packages = { { name = "p", features = {}, targets = targets } } })
    with_ctx(nil)
    local cap = capture_picker()
    vim.cmd("RustTargets")
    H.eq(#kinds * 3, #cap.opts.items)
    for _, k in ipairs(kinds) do
      local n = "t_" .. k:gsub("%-", "_")
      H.eq({ "cargo", "test", "-p", "p", "--lib", "--all-features" }, item(cap.opts, "test  lib " .. n).cmd, k)
      H.eq({ "cargo", "test", "-p", "p", "--doc", "--all-features" }, item(cap.opts, "doc-test  lib " .. n).cmd, k)
      H.eq({ "cargo", "build", "-p", "p", "--lib", "--all-features" }, item(cap.opts, "build  lib " .. n).cmd, k)
    end
  end)

  it("item commands select the package and target by name; the default context appends --all-features", function()
    local opts = targets_for_all(nil)
    local af = "--all-features"
    H.eq({ "cargo", "run", "-p", "rtt_all", "--bin", "tool", af }, item(opts, "run  bin").cmd)
    H.eq({ "cargo", "test", "-p", "rtt_all", "--bin", "tool", af }, item(opts, "test  bin").cmd)
    H.eq({ "cargo", "build", "-p", "rtt_all", "--bin", "tool", af }, item(opts, "build  bin").cmd)
    H.eq({ "cargo", "run", "-p", "rtt_all", "--example", "ex", af }, item(opts, "run  example").cmd)
    H.eq({ "cargo", "build", "-p", "rtt_all", "--example", "ex", af }, item(opts, "build  example").cmd)
    H.eq({ "cargo", "test", "-p", "rtt_all", "--test", "it", af }, item(opts, "test  test").cmd)
    H.eq({ "cargo", "bench", "-p", "rtt_all", "--bench", "bn", af }, item(opts, "bench  bench").cmd)
  end)

  it("a stored context appends its flags and target; the lib items use --lib / --doc without a name", function()
    local ctx = { all = false, no_default = true, features = { "b" }, target = "x86_64-unknown-linux-gnu" }
    local opts = targets_for_all(ctx)
    local function with(cmd)
      return vim.list_extend(cmd, { "--no-default-features", "--features", "b", "--target", "x86_64-unknown-linux-gnu" })
    end
    H.eq(with({ "cargo", "run", "-p", "rtt_all", "--bin", "tool" }), item(opts, "run  bin").cmd)
    H.eq(with({ "cargo", "test", "-p", "rtt_all", "--lib" }), item(opts, "test  lib").cmd)
    H.eq(with({ "cargo", "test", "-p", "rtt_all", "--doc" }), item(opts, "doc-test  lib").cmd)
    H.eq(with({ "cargo", "build", "-p", "rtt_all", "--lib" }), item(opts, "build  lib").cmd)
  end)

  it("the samply item builds with the profiling profile, then records the binary (shellescaped)", function()
    H.need_posix("the samply item is `sh -c` on POSIX and a cmd.exe line on Windows")
    local opts, dir = targets_for_all(nil)
    local meta = vim.json.decode(
      vim.system({ "cargo", "metadata", "--format-version", "1", "--no-deps" }, { cwd = dir, text = true }):wait().stdout
    )
    local build = { "cargo", "build", "--profile", "profiling", "-p", "rtt_all", "--bin", "tool", "--all-features" }
    local expected = table.concat(vim.tbl_map(vim.fn.shellescape, build), " ")
      .. " && samply record "
      .. vim.fn.shellescape(meta.target_directory .. "/profiling/tool")
    H.eq({ "sh", "-c", expected }, item(opts, "samply  bin tool (rtt_all)").cmd)
  end)

  it("the samply item shellescapes odd target directories and names", function()
    H.need_posix("the samply item is `sh -c` on POSIX and a cmd.exe line on Windows")
    local dir = H.fixture("rust-tasks-tools-all")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    H.open(dir .. "/src/main.rs")
    local weird = "/tmp/it's here/target"
    fake_metadata({
      target_directory = weird,
      packages = { { name = "p", features = {}, targets = { { name = "my bin", kind = { "bin" } } } } },
    })
    with_ctx(nil)
    local cap = capture_picker()
    vim.cmd("RustTargets")
    local cmd = item(cap.opts, "samply").cmd
    H.eq("sh", cmd[1])
    H.eq("-c", cmd[2])
    H.has(cmd[3], "'my bin'")
    H.has(cmd[3], " && samply record " .. vim.fn.shellescape(weird .. "/profiling/my bin"))
  end)

  it("the flamegraph item replaces --all-features by --features <non-default features, sorted>", function()
    local opts = targets_for_all(nil)
    H.eq(
      { "cargo", "flamegraph", "--profile", "profiling", "-p", "rtt_all", "--bin", "tool", "--features", "a,b" },
      item(opts, "flamegraph").cmd
    )
  end)

  it("the flamegraph item keeps the target flag and leaves a feature-list context alone", function()
    local opts = targets_for_all({ all = true, target = "x86_64-unknown-linux-gnu" })
    H.eq({
      "cargo", "flamegraph", "--profile", "profiling", "-p", "rtt_all", "--bin", "tool",
      "--target", "x86_64-unknown-linux-gnu", "--features", "a,b",
    }, item(opts, "flamegraph").cmd)
    unstub_all()
    local opts2 = targets_for_all({ all = false, features = { "b" } })
    H.eq(
      { "cargo", "flamegraph", "--profile", "profiling", "-p", "rtt_all", "--bin", "tool", "--features", "b" },
      item(opts2, "flamegraph").cmd
    )
  end)

  it("the flamegraph item adds no --features for a package without features", function()
    local dir = H.fixture("rust-tasks-tools-all")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    H.open(dir .. "/src/main.rs")
    fake_metadata({
      target_directory = dir .. "/target",
      packages = { { name = "p", features = vim.empty_dict(), targets = { { name = "b", kind = { "bin" } } } } },
    })
    with_ctx(nil)
    local cap = capture_picker()
    vim.cmd("RustTargets")
    H.eq({ "cargo", "flamegraph", "--profile", "profiling", "-p", "p", "--bin", "b" }, item(cap.opts, "flamegraph").cmd)
  end)

  it("titles the picker with the context description", function()
    local opts = targets_for_all(nil)
    H.eq("Cargo targets - all features, host target", opts.title)
    unstub_all()
    local ctx = { all = false, features = { "a", "b" }, target = "wasm32-unknown-unknown" }
    local opts2 = targets_for_all(ctx)
    H.eq("Cargo targets - " .. rc.describe(ctx), opts2.title)
    H.eq("Cargo targets - features: a,b | target: wasm32-unknown-unknown", opts2.title)
  end)

  it("confirm closes the picker and runs the item in a bottom terminal at the workspace root", function()
    local opts, dir = targets_for_all(nil)
    local term = capture_term(nil)
    local closed = 0
    local fake_picker = {
      close = function()
        closed = closed + 1
      end,
    }
    local it = item(opts, "run  bin")
    opts.confirm(fake_picker, it)
    H.eq(1, closed)
    H.eq(1, #term.opened)
    H.eq(it.cmd, term.opened[1].cmd)
    H.eq(dir, term.opened[1].opts.cwd)
    -- confirming nothing closes the picker and runs nothing
    opts.confirm(fake_picker, nil)
    H.eq(2, closed)
    H.eq(1, #term.opened)
  end)
end)

-- ============================================================ 7. term()

describe("term (through :RustTools confirm)", function()
  before_each(function()
    H.need_rust()
  end)

  local function confirm_first(existing)
    local dir = open_all()
    with_ctx(nil)
    local cap = capture_picker()
    local term = capture_term(existing)
    vim.cmd("RustTools")
    local it = cap.opts.items[1]
    cap.opts.confirm({ close = function() end }, it)
    return term, it, dir
  end

  it("opens Snacks.terminal at the bottom, keeps it open after exit and sets the cwd", function()
    local term, it, dir = confirm_first(nil)
    H.eq(1, #term.opened)
    H.eq(it.cmd, term.opened[1].cmd)
    H.eq({ cwd = dir, auto_close = false, win = { position = "bottom" } }, term.opened[1].opts)
  end)

  it("looks the finished terminal of the same cmd up without creating one", function()
    local term, it, dir = confirm_first(nil)
    H.eq(1, #term.gets)
    H.eq(it.cmd, term.gets[1].cmd)
    H.eq({ cwd = dir, create = false }, term.gets[1].opts)
  end)

  it("a DIFFERENT command closes the previous run's terminal too (no extra split per command)", function()
    local dir = open_all()
    with_ctx(nil)
    local cap = capture_picker()
    local term = capture_term(nil)
    vim.cmd("RustTools")
    cap.opts.confirm({ close = function() end }, cap.opts.items[1])
    cap.opts.confirm({ close = function() end }, cap.opts.items[2])
    H.eq(2, #term.opened)
    H.eq({ buf = true }, term.terms[1].closed, "the first command's terminal was closed")
    H.is_nil(term.terms[2].closed)
    cap.opts.confirm({ close = function() end }, cap.opts.items[3])
    H.eq({ buf = true }, term.terms[2].closed)
    H.eq(dir, term.opened[3].opts.cwd)
  end)

  it("closes (and wipes the buffer of) an existing terminal before reopening", function()
    local closed
    local old = {
      close = function(_, o)
        closed = o
      end,
    }
    local term = confirm_first(old)
    H.eq({ buf = true }, closed)
    H.eq(1, #term.opened)
  end)
end)

-- ================================================================ 8. new

describe(":RustNew", function()
  local function setup_dir()
    local dir = H.tmpdir()
    vim.cmd.cd(vim.fn.fnameescape(dir))
    return vim.uv.cwd()
  end

  before_each(function()
    H.need_rust()
  end)

  it("with a name asks for the crate type (bin, lib) and creates a bin crate", function()
    local dir = setup_dir()
    local asked
    stub(vim.ui, "select", function(items, o, cb)
      asked = { items = items, prompt = o.prompt }
      cb("bin")
    end)
    stub(vim.ui, "input", function()
      error("must not ask for the name when one is given")
    end)
    local n = H.capture_notify()
    vim.cmd("RustNew mybin")
    H.eq({ items = { "bin", "lib" }, prompt = "Crate type" }, asked)
    H.eq(1, vim.fn.filereadable(dir .. "/mybin/src/main.rs"))
    H.eq(dir .. "/mybin/src/main.rs", vim.api.nvim_buf_get_name(0))
    H.eq("created " .. dir .. "/mybin", n.list[#n.list].msg)
  end)

  it("a lib crate gets --lib and opens src/lib.rs", function()
    local dir = setup_dir()
    stub(vim.ui, "select", function(_, _, cb)
      cb("lib")
    end)
    local n = H.capture_notify()
    vim.cmd("RustNew mylib")
    H.eq(1, vim.fn.filereadable(dir .. "/mylib/src/lib.rs"))
    H.eq(0, vim.fn.filereadable(dir .. "/mylib/src/main.rs"))
    H.eq(dir .. "/mylib/src/lib.rs", vim.api.nvim_buf_get_name(0))
    H.eq("created " .. dir .. "/mylib", n.list[#n.list].msg)
  end)

  it("without a name asks vim.ui.input 'New crate name: '", function()
    local dir = setup_dir()
    local prompt
    stub(vim.ui, "input", function(o, cb)
      prompt = o.prompt
      cb("asked")
    end)
    stub(vim.ui, "select", function(_, _, cb)
      cb("bin")
    end)
    H.capture_notify()
    vim.cmd("RustNew")
    H.eq("New crate name: ", prompt)
    H.eq(1, vim.fn.filereadable(dir .. "/asked/src/main.rs"))
  end)

  it("an empty name (or a cancelled input) does nothing", function()
    local dir = setup_dir()
    local selected = false
    stub(vim.ui, "select", function()
      selected = true
    end)
    stub(vim.ui, "input", function(_, cb)
      cb("")
    end)
    vim.cmd("RustNew")
    stub(vim.ui, "input", function(_, cb)
      cb(nil)
    end)
    vim.cmd("RustNew")
    H.not_ok(selected, "no type question for an empty name")
    H.eq({}, vim.fn.readdir(dir))
  end)

  it("a name starting with '-' is refused (cargo would take it as an option)", function()
    local dir = setup_dir()
    stub(vim.ui, "select", function()
      error("no type question for a refused name")
    end)
    local n = H.capture_notify()
    vim.cmd("RustNew -dash")
    H.eq(1, #n.list)
    H.eq(vim.log.levels.ERROR, n.list[1].level)
    H.match(n.list[1].msg, "cannot start with '-'", true)
    H.eq({}, vim.fn.readdir(dir))
  end)

  it("a cancelled type question creates nothing", function()
    local dir = setup_dir()
    stub(vim.ui, "select", function(_, _, cb)
      cb(nil)
    end)
    vim.cmd("RustNew nothing")
    H.eq({}, vim.fn.readdir(dir))
  end)

  it("shows cargo's stderr as ERROR when cargo new fails", function()
    local dir = setup_dir()
    vim.fn.mkdir(dir .. "/taken/src", "p")
    vim.fn.writefile({ "x" }, dir .. "/taken/Cargo.toml")
    stub(vim.ui, "select", function(_, _, cb)
      cb("bin")
    end)
    local n = H.capture_notify()
    vim.cmd("RustNew taken")
    H.eq(1, #n.list)
    H.eq(vim.log.levels.ERROR, n.list[1].level)
    H.match(n.list[1].msg, "already exists", true)
  end)
end)

-- =========================================================== 9-10. tools

describe(":RustTools", function()
  local function tools(ctx)
    with_ctx(ctx)
    local dir = open_all()
    local cap = capture_picker()
    vim.cmd("RustTools")
    return H.ok(cap.opts, "picker was not opened"), dir
  end

  it("lists the 9 tools with their commands; the builds (timings, bloat, coverage) get the context flags", function()
    H.need_rust()
    local ctx = { all = false, features = { "a" }, target = "x86_64-unknown-linux-gnu" }
    local opts, dir = tools(ctx)
    H.eq("Cargo tools", opts.title)
    H.eq("text", opts.format)
    local cov = { "cargo", "llvm-cov", "--workspace", "--ignore-run-fail", "--summary-only", "--features", "a", "--target", "x86_64-unknown-linux-gnu" }
    local flags = { "--features", "a", "--target", "x86_64-unknown-linux-gnu" }
    local expected = {
      { "timings (cargo build --timings; report in target/cargo-timings)", vim.list_extend({ "cargo", "build", "--timings" }, flags) },
      { "bloat by crate (release)", vim.list_extend({ "cargo", "bloat", "--release", "--crates" }, flags) },
      { "bloat by function (release, top 30)", vim.list_extend({ "cargo", "bloat", "--release", "-n", "30" }, flags) },
      { "unused dependencies (cargo machete)", { "cargo", "machete" } },
      { "deny: fetch advisory DB", { "cargo", "deny", "fetch" } },
      { "deny: check all (no deny.toml: licenses skipped)", { "cargo", "deny", "check", "advisories", "bans", "sources" } },
      { "audit (RustSec)", { "cargo", "audit" } },
      { "duplicate dependency versions", { "cargo", "tree", "-d" } },
      { "coverage report (summary in terminal)", cov },
    }
    H.eq(#expected, #opts.items)
    for i, e in ipairs(expected) do
      H.eq(e[1], opts.items[i].text, "text " .. i)
      H.eq(e[2], opts.items[i].cmd, "cmd " .. i)
    end
    -- running one goes through term() in the workspace root
    local term = capture_term(nil)
    opts.confirm({ close = function() end }, opts.items[4])
    H.eq({ "cargo", "machete" }, term.opened[1].cmd)
    H.eq(dir, term.opened[1].opts.cwd)
  end)

  it("deny: check all runs the licence check only when the crate has a deny.toml", function()
    H.need_rust()
    local opts, dir = tools(nil)
    H.eq("deny: check all (no deny.toml: licenses skipped)", opts.items[6].text)
    H.eq({ "cargo", "deny", "check", "advisories", "bans", "sources" }, opts.items[6].cmd)
    unstub_all()
    vim.fn.writefile({ "[licenses]" }, dir .. "/deny.toml")
    with_ctx(nil)
    local cap = capture_picker()
    vim.cmd("RustTools")
    local opts2 = H.ok(cap.opts, "picker was not opened")
    H.eq("deny: check all", opts2.items[6].text)
    H.eq({ "cargo", "deny", "check" }, opts2.items[6].cmd)
    vim.fn.delete(dir .. "/deny.toml")
  end)

  it("the default context puts --all-features on the coverage entry, repeated calls do not accumulate flags", function()
    H.need_rust()
    local opts = tools(nil)
    H.eq({ "cargo", "llvm-cov", "--workspace", "--ignore-run-fail", "--summary-only", "--all-features" }, opts.items[9].cmd)
    H.eq({ "cargo", "build", "--timings", "--all-features" }, opts.items[1].cmd)
    unstub_all()
    local opts2 = tools(nil)
    H.eq({ "cargo", "llvm-cov", "--workspace", "--ignore-run-fail", "--summary-only", "--all-features" }, opts2.items[9].cmd)
  end)

  it("warns outside a crate", function()
    open_outside_crate()
    local n = H.capture_notify()
    local cap = capture_picker()
    vim.cmd("RustTools")
    H.eq(1, #n.list)
    H.eq("no Cargo.toml found", n.list[1].msg)
    H.eq(vim.log.levels.WARN, n.list[1].level)
    H.is_nil(cap.opts)
  end)
end)

-- ============================================================== 11. act

describe(":ActJob", function()
  local function start_yaml()
    if not pcall(vim.treesitter.start, 0, "yaml") then
      H.skip_file("no yaml treesitter parser")
    end
  end

  local function open_workflow()
    local repo = H.tmpdir()
    vim.fn.mkdir(repo .. "/.github/workflows", "p")
    local file = repo .. "/.github/workflows/ci.yml"
    vim.fn.writefile(vim.fn.readfile(H.repo .. "/.github/workflows/ci.yml"), file)
    H.git_init(repo)
    vim.cmd.cd(vim.fn.fnameescape(repo))
    H.open(file)
    start_yaml()
    return repo, file
  end

  local function goto_line(pat)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:find(pat, 1, true) then
        vim.api.nvim_win_set_cursor(0, { i, 6 })
        return i
      end
    end
    error("no line with " .. pat)
  end

  it("runs `act -j <job> -W <file>` for the job under the cursor in the git root", function()
    local repo, file = open_workflow()
    local term = capture_term(nil)
    goto_line("runs-on:") -- a key inside job `smoke`
    vim.cmd("ActJob")
    H.eq(1, #term.opened)
    H.eq({ "act", "-j", "smoke", "-W", file }, term.opened[1].cmd)
    H.eq(repo, term.opened[1].opts.cwd)
  end)

  it("also finds the job when the cursor is on a step deep inside it", function()
    open_workflow()
    local term = capture_term(nil)
    goto_line("Startup smoke test")
    vim.cmd("ActJob")
    H.eq("smoke", term.opened[1].cmd[3])
  end)

  it("picks the right job in a file with several jobs, the cwd is the root without a .git", function()
    local repo = H.tmpdir()
    local file = repo .. "/two.yml"
    vim.fn.writefile({
      "name: x",
      "jobs:",
      "  first:",
      "    runs-on: ubuntu-latest",
      "    steps:",
      "      - run: echo 1",
      "  second:",
      "    runs-on: ubuntu-latest",
      "    steps:",
      "      - run: echo 2",
    }, file)
    vim.cmd.cd(vim.fn.fnameescape(repo))
    H.open(file)
    start_yaml()
    local term = capture_term(nil)
    vim.api.nvim_win_set_cursor(0, { 10, 10 })
    vim.cmd("ActJob")
    H.eq({ "act", "-j", "second", "-W", file }, term.opened[1].cmd)
    H.eq(vim.uv.cwd(), term.opened[1].opts.cwd)
    vim.api.nvim_win_set_cursor(0, { 4, 10 })
    vim.cmd("ActJob")
    H.eq("first", term.opened[2].cmd[3])
  end)

  it("warns outside `jobs:`", function()
    open_workflow()
    local term = capture_term(nil)
    local n = H.capture_notify()
    vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- `name: CI`
    vim.cmd("ActJob")
    H.eq(0, #term.opened)
    H.eq(1, #n.list)
    H.eq("cursor is not inside a job under `jobs:`", n.list[1].msg)
    H.eq(vim.log.levels.WARN, n.list[1].level)
    -- the `permissions:` block is not a job either
    goto_line("contents: read")
    vim.cmd("ActJob")
    H.eq(0, #term.opened)
    H.eq(2, #n.list)
  end)
end)

-- ========================================================== 12. doctests

describe("rust_tasks.doctests", function()
  it("runs cargo test --doc --workspace + the context flags in the workspace root", function()
    H.need_rust()
    with_ctx({ all = false, features = { "b" } })
    local dir = open_all()
    local term = capture_term(nil)
    tasks.doctests()
    H.eq(1, #term.opened)
    H.eq({ "cargo", "test", "--doc", "--workspace", "--features", "b" }, term.opened[1].cmd)
    H.eq(dir, term.opened[1].opts.cwd)
    H.eq(false, term.opened[1].opts.auto_close)
  end)

  it("defaults to --all-features", function()
    H.need_rust()
    with_ctx(nil)
    open_all()
    local term = capture_term(nil)
    tasks.doctests()
    H.eq({ "cargo", "test", "--doc", "--workspace", "--all-features" }, term.opened[1].cmd)
  end)

  it("warns without a crate", function()
    open_outside_crate()
    local term = capture_term(nil)
    local n = H.capture_notify()
    tasks.doctests()
    H.eq(0, #term.opened)
    H.eq("no Cargo.toml found", n.list[1].msg)
    H.eq(vim.log.levels.WARN, n.list[1].level)
  end)
end)

-- ==================================================== 13. <leader>tc run

describe("<leader>tc (coverage run)", function()
  local function tc()
    require("lazy").load({ plugins = { "nvim-coverage" } })
    local m = vim.fn.maparg("<leader>tc", "n", false, true)
    return H.ok(m.callback, "<leader>tc has no Lua callback")
  end

  --- Stub vim.system (captures cargo llvm-cov), vim.fn.executable (nextest) and
  --- vim.cmd (CoverageLoad/Show recorded, everything else real).
  local function harness(nextest)
    local cap = { cmds = {} }
    local real_system = vim.system
    stub(vim, "system", function(cmd, opts, cb)
      if cmd[1] ~= "cargo" or cmd[2] ~= "llvm-cov" then -- the LSP clients use vim.system too
        return real_system(cmd, opts, cb)
      end
      cap.sys = { cmd = cmd, opts = opts }
      cap.done = cb
      return {}
    end)
    local real_exec = vim.fn.executable
    stub(vim.fn, "executable", function(name)
      if name == "cargo-nextest" then
        return nextest and 1 or 0
      end
      return real_exec(name)
    end)
    local real_cmd = vim.cmd
    stub(
      vim,
      "cmd",
      setmetatable({}, {
        __call = function(_, c, ...)
          if c == "CoverageLoad" or c == "CoverageShow" then
            cap.cmds[#cap.cmds + 1] = c
            return
          end
          return real_cmd(c, ...)
        end,
        __index = real_cmd,
      })
    )
    return cap
  end

  --- Complete the stubbed cargo run. Noice replaces vim.notify from a scheduled
  --- callback queued by VeryLazy, so let the event queue drain and install the
  --- capture again before the run's own scheduled callback. Returns the capture.
  local function finish(cap, res)
    vim.wait(300)
    local n = H.capture_notify()
    cap.done(vim.tbl_extend("force", { code = 0, stdout = "", stderr = "" }, res or {}))
    return n
  end

  it("runs cargo llvm-cov nextest with the lcov output + context flags in the workspace root", function()
    H.need_rust()
    local fn = tc()
    with_ctx({ all = false, features = { "a" }, target = "x86_64-unknown-linux-gnu" })
    local dir = open_all()
    local n = H.capture_notify()
    local cap = harness(true)
    fn()
    local expected = {
      "cargo", "llvm-cov", "nextest", "--workspace", "--ignore-run-fail", "--lcov", "--output-path", "target/lcov.info",
      "--features", "a", "--target", "x86_64-unknown-linux-gnu",
    }
    H.eq(expected, cap.sys.cmd)
    H.eq(dir, cap.sys.opts.cwd)
    H.eq(true, cap.sys.opts.text)
    H.eq("coverage: running " .. table.concat(expected, " "), n.list[1].msg)
  end)

  it("leaves nextest out when cargo-nextest is not executable", function()
    H.need_rust()
    local fn = tc()
    with_ctx(nil)
    open_all()
    H.capture_notify()
    local cap = harness(false)
    fn()
    H.eq({
      "cargo", "llvm-cov", "--workspace", "--ignore-run-fail", "--lcov", "--output-path", "target/lcov.info", "--all-features",
    }, cap.sys.cmd)
  end)

  it("on exit 0 loads and shows the coverage and says where it came from", function()
    H.known_issue({ "macos" }, "coverage run specs hang on macos-latest (run 39655339161: file timed out after 240 s; cause not diagnosed)")
    H.need_rust()
    local fn = tc()
    with_ctx(nil)
    local dir = open_all()
    local n = H.capture_notify()
    local cap = harness(true)
    fn()
    n = finish(cap)
    wait_notify(n, "coverage loaded")
    H.eq({ "CoverageLoad", "CoverageShow" }, cap.cmds)
    H.eq("coverage loaded (" .. dir .. "/target/lcov.info)", n.list[#n.list].msg)
    for _, x in ipairs(n.list) do
      H.not_ok(x.level == vim.log.levels.WARN, "no warning when the tests passed: " .. x.msg)
    end
  end)

  it("warns that tests failed (nextest and cargo test wording) but still loads the report", function()
    H.known_issue({ "macos" }, "coverage run notification timed out after 183 s on macos-latest (run 39647013043; cause not diagnosed)")
    H.need_rust()
    local fn = tc()
    with_ctx(nil)
    open_all()
    local variants = {
      { stderr = "Summary 3 tests run: 2 passed, 1 failed, 0 skipped" },
      { stdout = "test result: FAILED. 0 passed; 2 failed; 0 ignored" },
    }
    for _, res in ipairs(variants) do
      local n = H.capture_notify()
      local cap = harness(true)
      fn()
      n = finish(cap, res)
      local w = wait_notify(n, "coverage: some tests FAILED (the report is still written)")
      H.eq(vim.log.levels.WARN, w.level)
      H.eq({ "CoverageLoad", "CoverageShow" }, cap.cmds)
      n.restore()
      unstub_all()
      with_ctx(nil)
    end
  end)

  it("does not warn for '0 failed'", function()
    H.known_issue({ "macos" }, "coverage run specs hang on macos-latest (run 39655339161: file timed out after 240 s; cause not diagnosed)")
    H.need_rust()
    local fn = tc()
    with_ctx(nil)
    open_all()
    local n = H.capture_notify()
    local cap = harness(true)
    fn()
    n = finish(cap, { stderr = "test result: ok. 3 passed; 0 failed; 0 ignored" })
    wait_notify(n, "coverage loaded")
    for _, x in ipairs(n.list) do
      H.no_match(x.msg, "FAILED", true)
    end
  end)

  it("a non-zero exit is an ERROR with the last 600 chars of stderr and loads nothing", function()
    H.known_issue({ "macos" }, "coverage run specs hang on macos-latest (run 39655339161: file timed out after 240 s; cause not diagnosed)")
    H.need_rust()
    local fn = tc()
    with_ctx(nil)
    open_all()
    local n = H.capture_notify()
    local cap = harness(true)
    fn()
    local err = ("x"):rep(500) .. ("0123456789"):rep(70) -- 1200 chars
    n = finish(cap, { code = 101, stderr = err })
    local e = wait_notify(n, "coverage run failed:")
    H.eq(vim.log.levels.ERROR, e.level)
    H.eq("coverage run failed:\n" .. err:sub(-600), e.msg)
    H.eq({}, cap.cmds)
  end)

  it("warns without a crate and runs nothing", function()
    local fn = tc()
    open_outside_crate()
    local n = H.capture_notify()
    local cap = harness(true)
    fn()
    H.is_nil(cap.sys)
    H.eq("no Cargo.toml found", n.list[1].msg)
    H.eq(vim.log.levels.WARN, n.list[1].level)
  end)
end)

-- ================================================== 14. plugin options

describe("nvim-coverage options", function()
  it("sets auto_reload, commands and the opaque, smaller summary window", function()
    require("lazy").load({ plugins = { "nvim-coverage" } })
    local o = require("coverage.config").opts
    H.eq(true, o.auto_reload)
    H.eq(true, o.commands)
    H.eq(0, o.summary.window.winblend)
    H.eq(0.6, o.summary.width_percentage)
    H.eq(0.4, o.summary.height_percentage)
  end)

  it("is lazy loaded on the seven Coverage commands and the <leader>tc/tg/tG keys", function()
    local plugin = require("lazy.core.config").plugins["nvim-coverage"]
    H.ok(plugin, "nvim-coverage is not in the lazy spec")
    local cmds = vim.deepcopy(plugin.cmd)
    table.sort(cmds)
    H.eq({ "Coverage", "CoverageClear", "CoverageHide", "CoverageLoad", "CoverageShow", "CoverageSummary", "CoverageToggle" }, cmds)
    local keys = {}
    for _, k in ipairs(plugin.keys or {}) do
      keys[k.lhs or k[1]] = true
    end
    for _, lhs in ipairs({ "<leader>tc", "<leader>tg", "<leader>tG" }) do
      H.ok(keys[lhs], lhs .. " missing from the plugin keys")
    end
  end)
end)

-- ================================================= 15. the rust backend

describe("coverage rust backend (lcov instead of grcov)", function()
  local function load_plugin()
    require("lazy").load({ plugins = { "nvim-coverage" } })
  end

  local function write_lcov(root, lines)
    local out = { "TN:", "SF:" .. root .. "/src/lib.rs" }
    local hit = 0
    for _, l in ipairs(lines) do
      out[#out + 1] = ("DA:%d,%d"):format(l[1], l[2])
      hit = hit + (l[2] > 0 and 1 or 0)
    end
    vim.list_extend(out, { "LF:" .. #lines, "LH:" .. hit, "end_of_record" })
    vim.fn.mkdir(root .. "/target", "p")
    vim.fn.writefile(out, root .. "/target/lcov.info")
  end

  local function placed(buf)
    return vim.fn.sign_getplaced(buf, { group = "coverage" })[1].signs
  end

  after_each(function()
    pcall(vim.cmd, "CoverageClear")
  end)

  it("replaces coverage.languages.rust with sign_list, summary and load", function()
    load_plugin()
    local m = package.loaded["coverage.languages.rust"]
    H.eq("function", type(m.sign_list))
    H.eq("function", type(m.summary))
    H.eq("function", type(m.load))
    local common = require("coverage.languages.common")
    H.eq(common.sign_list, m.sign_list)
    H.eq(common.summary, m.summary)
  end)

  it("coverage_file is <root>/target/lcov.info, or the cwd's when there is no crate", function()
    H.need_rust()
    load_plugin()
    local f = require("coverage.config").opts.lang.rust.coverage_file
    H.eq("function", type(f))
    local dir = open_all()
    H.eq(dir .. "/target/lcov.info", f())
    open_outside_crate()
    H.eq(vim.uv.cwd() .. "/target/lcov.info", f())
  end)

  it("a missing coverage file is an INFO hint, not an error", function()
    load_plugin()
    local dir = H.fixture("rust-tasks-tools-cov")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    H.open(dir .. "/src/lib.rs")
    H.eq("rust", vim.bo.filetype)
    local n = H.capture_notify()
    vim.cmd("CoverageLoad")
    H.eq(1, #n.list)
    H.eq("No coverage file (target/lcov.info); run <leader>tc", n.list[1].msg)
    H.eq(vim.log.levels.INFO, n.list[1].level)
  end)

  it("loads target/lcov.info: signs are placed on the covered lines and CoverageSummary shows 100%", function()
    load_plugin()
    local dir = H.fixture("rust-tasks-tools-cov")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/src/lib.rs")
    write_lcov(dir, { { 1, 1 }, { 2, 1 }, { 3, 1 }, { 9, 1 } })
    vim.cmd("Coverage") -- load + place
    local s = placed(buf)
    H.eq(4, #s)
    local lines = vim.tbl_map(function(x)
      return x.lnum
    end, s)
    table.sort(lines)
    H.eq({ 1, 2, 3, 9 }, lines)
    for _, x in ipairs(s) do
      H.eq("coverage_covered", x.name)
    end
    vim.cmd("CoverageSummary")
    local text
    H.wait_for(function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          local t = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
          if t:find("Total", 1, true) then
            text = t
            return true
          end
        end
      end
    end, 5000, "the summary float")
    H.match(text, "100%%")
    H.match(text, "lib.rs", true) -- the path is shortened to fit the column
  end)

  it("marks missed lines as uncovered", function()
    load_plugin()
    local dir = H.fixture("rust-tasks-tools-cov")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/src/lib.rs")
    write_lcov(dir, { { 1, 1 }, { 2, 0 } })
    vim.cmd("Coverage")
    local by = {}
    for _, x in ipairs(placed(buf)) do
      by[x.lnum] = x.name
    end
    H.eq({ [1] = "coverage_covered", [2] = "coverage_uncovered" }, by)
  end)
end)

-- ================================================== 16. end to end (slow)

describe("<leader>tc end to end (optional, slow)", function()
  it("a real cargo llvm-cov run writes target/lcov.info and places the signs", function()
    H.need_rust()
    if vim.system({ "cargo", "llvm-cov", "--version" }):wait(20000).code ~= 0 then
      H.skip_file("cargo-llvm-cov not installed")
    end
    if vim.fn.executable("cargo-nextest") ~= 1 then
      H.skip_file("cargo-nextest not installed")
    end
    require("lazy").load({ plugins = { "nvim-coverage" } })
    local dir = H.fixture("rust-tasks-tools-cov")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/src/lib.rs")
    local n = H.capture_notify()
    local m = vim.fn.maparg("<leader>tc", "n", false, true)
    H.ok(m.callback)
    m.callback()
    H.wait_for(function()
      for _, x in ipairs(n.list) do
        if x.msg:find("coverage loaded", 1, true) or x.msg:find("coverage run failed", 1, true) then
          return true
        end
      end
    end, 300000, "the coverage run to finish")
    for _, x in ipairs(n.list) do
      if x.msg:find("coverage run failed", 1, true) then
        if x.msg:find("llvm-tools", 1, true) or x.msg:find("llvm-profdata", 1, true) then
          H.skip_file("llvm-tools missing: " .. x.msg:sub(1, 200))
        end
        error(x.msg)
      end
    end
    H.eq(1, vim.fn.filereadable(dir .. "/target/lcov.info"))
    H.has(table.concat(vim.fn.readfile(dir .. "/target/lcov.info"), "\n"), dir .. "/src/lib.rs")
    local s = vim.fn.sign_getplaced(buf, { group = "coverage" })[1].signs
    H.ok(#s > 0, "signs were placed")
    local lines = vim.tbl_map(function(x)
      return x.lnum
    end, s)
    H.has(lines, 2, "the body of add() is covered")
    pcall(vim.cmd, "CoverageClear")
  end)
end)

-- ============================================ 17. profiling profile (info)

describe("perf profile", function()
  pending(
    "[profile.profiling] lives in ~/.cargo/config.toml",
    "outside the repo (user-level cargo config); the samply/flamegraph items only pass --profile profiling"
  )
end)
