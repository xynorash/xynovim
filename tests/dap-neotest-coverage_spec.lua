-- lua/plugins/dap.lua, lua/plugins/rustaceanvim.lua, lua/plugins/coverage.lua,
-- lazyvim.json (dap.core, test.core, editor.overseer extras).
--
-- The helpers of dap.lua are file-local, so they are reached through what the
-- plugin spec exposes: the mason-nvim-dap `codelldb` handler (it installs
-- dap.configurations.rust and the on_config listener), the <leader>dR key
-- function and the dap-ui opts. `fresh()` loads a private copy of the spec file
-- (own closures, own sysroot cache); the lazy-registered one is used where the
-- wiring itself is under test. Cargo crates are written into temp dirs at run
-- time; the interactive prompts (vim.fn.input, vim.ui.select) are stubbed.
-- One real codelldb session runs at the end (skipped without codelldb).
local H = require("xynotest.helpers")
local EXE = vim.fn.has("win32") == 1 and ".exe" or ""

local undo = {}
--- Replace t[k] by v until after_each.
local function stub(t, k, v)
  local old = rawget(t, k)
  undo[#undo + 1] = function()
    rawset(t, k, old)
  end
  rawset(t, k, v)
end
after_each(function()
  for i = #undo, 1, -1 do
    pcall(undo[i])
  end
  undo = {}
  pcall(function()
    require("dap").terminate()
  end)
end)

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
end

--- Write { [relative path] = content } into a fresh temp dir; returns its real path.
local function crate(files)
  local dir = vim.uv.fs_realpath(H.tmpdir())
  for rel, text in pairs(files) do
    write(dir .. "/" .. rel, text)
  end
  return dir
end

local function cargo_meta(dir)
  local o = vim.system({ "cargo", "metadata", "--format-version", "1", "--no-deps" }, { cwd = dir, text = true }):wait(30000)
  H.eq(0, o.code, "cargo metadata of the test crate: " .. (o.stderr or ""))
  return vim.json.decode(o.stdout)
end

local function bin_crate(name)
  return crate({
    ["Cargo.toml"] = ('[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n'):format(name),
    ["src/main.rs"] = "fn main() { println!(\"hi\"); }\n",
  })
end

--- notify stub recording { msg, level, title }.
local function capture()
  local list = {}
  stub(vim, "notify", function(msg, level, opts)
    list[#list + 1] = { msg = msg, level = level, title = opts and opts.title }
  end)
  return list
end

local function edit(path)
  vim.cmd.cd(vim.fn.fnameescape(vim.fs.dirname(path)))
  vim.cmd.edit(vim.fn.fnameescape(path))
end

local function codelldb_cfg()
  return {
    name = "codelldb",
    adapters = require("mason-nvim-dap.mappings.adapters").codelldb,
    configurations = require("mason-nvim-dap.mappings.configurations").codelldb,
    filetypes = require("mason-nvim-dap.mappings.filetypes").codelldb,
  }
end

--- A private copy of lua/plugins/dap.lua's spec: { dap, mason-nvim-dap, dap-ui }.
local function fresh()
  return dofile(H.repo .. "/lua/plugins/dap.lua")
end

--- Fresh spec with the codelldb handler run; returns spec, rust configs, on_config listener.
local function fresh_setup()
  local spec = fresh()
  spec[2].opts.handlers.codelldb(codelldb_cfg())
  local dap = require("dap")
  return spec, dap.configurations.rust, dap.listeners.on_config["xynovim_rust_lldb"]
end

local function by_name(list, name)
  for _, c in ipairs(list) do
    if c.name == name then
      return c
    end
  end
end

--- Run fn(co-less) with vim.fn.input stubbed; returns the recorded calls.
local function stub_input(answer)
  local calls = {}
  local old = vim.fn.input
  vim.fn.input = function(...)
    calls[#calls + 1] = { ... }
    return type(answer) == "function" and answer(...) or answer
  end
  undo[#undo + 1] = function()
    vim.fn.input = old
  end
  return calls
end

local function dap_available()
  if vim.fn.executable("cargo") ~= 1 then
    H.skip_file("cargo not found")
  end
end

-- 1 ------------------------------------------------------------------------
describe("codelldb handler: Rust configurations", function()
  it("replaces dap.configurations.rust with exactly the three Rust configs (lazy-registered handler)", function()
    dap_available()
    local p = require("lazy.core.config").plugins["mason-nvim-dap.nvim"]
    H.ok(p and type(p.opts.handlers.codelldb) == "function", "mason-nvim-dap opts.handlers.codelldb")
    local dap = require("dap")
    dap.configurations.rust = { { name = "stale" } }
    p.opts.handlers.codelldb(codelldb_cfg())
    local cfgs = dap.configurations.rust
    H.eq(3, #cfgs)
    H.eq({ "LLDB: Launch", "LLDB: Launch (args)", "Rust: run current package binary (args prompt)" }, vim.tbl_map(function(c)
      return c.name
    end, cfgs))
    for _, c in ipairs(cfgs) do
      H.eq("codelldb", c.type)
      H.eq("launch", c.request)
      H.eq({ "rust" }, c.sourceLanguages)
      H.eq(false, c.stopOnEntry)
      H.eq("integratedTerminal", c.console)
    end
    H.ok(dap.adapters.codelldb, "default_setup registered the codelldb adapter")
    H.ok(dap.listeners.on_config["xynovim_rust_lldb"], "on_config listener installed")
  end)

  it("does not leak the Rust list into c/cpp (their configs keep the generic ones)", function()
    dap_available()
    local _, rust = fresh_setup()
    local cpp = require("dap").configurations.cpp or {}
    for _, c in ipairs(cpp) do
      H.not_ok(c.name == "Rust: run current package binary (args prompt)")
    end
    H.ok(rust ~= require("dap").configurations.c)
  end)
end)

-- 2 ------------------------------------------------------------------------
describe("configurations: program / args / cwd", function()
  it("configs 1 and 2: program prompts with <target>/debug/<bin> as default, cwd ${workspaceFolder}", function()
    dap_available()
    local dir = bin_crate("progpkg")
    edit(dir .. "/src/main.rs")
    local _, cfgs = fresh_setup()
    local calls = stub_input("ANSWER")
    local target = cargo_meta(dir).target_directory
    for _, name in ipairs({ "LLDB: Launch", "LLDB: Launch (args)" }) do
      local c = by_name(cfgs, name)
      H.eq("${workspaceFolder}", c.cwd)
      H.eq("function", type(c.program))
      H.eq("ANSWER", c.program())
    end
    H.eq(2, #calls)
    H.eq({ "Path to executable: ", target .. "/debug/progpkg" .. EXE, "file" }, calls[1])
    H.eq(calls[1], calls[2])
    -- config 1 has plain empty args, config 2 prompts
    H.eq({}, by_name(cfgs, "LLDB: Launch").args)
    H.eq("function", type(by_name(cfgs, "LLDB: Launch (args)").args))
  end)

  it("config 2 args: split on spaces, empty fields dropped", function()
    dap_available()
    local _, cfgs = fresh_setup()
    local c = by_name(cfgs, "LLDB: Launch (args)")
    local calls = stub_input("  --flag   value  x ")
    H.eq({ "--flag", "value", "x" }, c.args())
    H.eq({ "Args: " }, calls[1])
    stub_input("")
    H.eq({}, c.args())
  end)

  it("config 3: cwd is the package directory, args prompt like config 2", function()
    dap_available()
    local dir = bin_crate("cwdpkg")
    edit(dir .. "/src/main.rs")
    local _, cfgs = fresh_setup()
    local c = by_name(cfgs, "Rust: run current package binary (args prompt)")
    H.eq("function", type(c.cwd))
    H.eq(dir, c.cwd())
    stub_input("a  b")
    H.eq({ "a", "b" }, c.args())
  end)

  it("config 3: program builds the binary in the package dir (blocking outside a coroutine) and notifies with title 'dap'", function()
    dap_available()
    local dir = bin_crate("blockpkg")
    edit(dir .. "/src/main.rs")
    local _, cfgs = fresh_setup()
    local c = by_name(cfgs, "Rust: run current package binary (args prompt)")
    local n = capture()
    H.eq(nil, coroutine.running(), "the test runs on the main thread")
    local path = c.program()
    H.eq(cargo_meta(dir).target_directory .. "/debug/blockpkg" .. EXE, path)
    H.ok(vim.uv.fs_stat(path), "binary was built at " .. path)
    H.eq({ msg = "cargo build --package blockpkg --bin blockpkg", level = vim.log.levels.INFO, title = "dap" }, n[1])
    H.eq(1, #n)
  end)

  it("config 3: inside a coroutine the build yields (UI not blocked) and resumes with the path", function()
    dap_available()
    local dir = bin_crate("copkg")
    edit(dir .. "/src/main.rs")
    local _, cfgs = fresh_setup()
    local c = by_name(cfgs, "Rust: run current package binary (args prompt)")
    capture()
    local result, finished
    local co = coroutine.create(function()
      result = c.program()
      finished = true
    end)
    local ok, err = coroutine.resume(co)
    H.ok(ok, tostring(err))
    H.not_ok(finished, "program() yielded instead of blocking")
    H.eq("suspended", coroutine.status(co))
    H.wait_for(function()
      return finished
    end, 60000, "the coroutine build to finish")
    H.eq(cargo_meta(dir).target_directory .. "/debug/copkg" .. EXE, result)
    H.ok(vim.uv.fs_stat(result))
  end)
end)

-- 3 ------------------------------------------------------------------------
describe("current_binary selection (seen through config 3's cwd and config 1's default program)", function()
  local function default_for(cfgs)
    local calls = stub_input("x")
    by_name(cfgs, "LLDB: Launch").program()
    return calls[#calls][2]
  end
  local function cwd_of(cfgs)
    return by_name(cfgs, "Rust: run current package binary (args prompt)").cwd()
  end

  local function workspace()
    return crate({
      ["Cargo.toml"] = '[workspace]\nresolver = "2"\nmembers = ["a", "b", "libonly", "multi", "plain"]\n',
      ["a/Cargo.toml"] = '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2021"\n',
      ["a/src/main.rs"] = "fn main() {}\n",
      ["b/Cargo.toml"] = '[package]\nname = "b"\nversion = "0.1.0"\nedition = "2021"\n',
      ["b/src/main.rs"] = "fn main() {}\n",
      ["b/src/util.rs"] = "pub fn u() {}\n",
      ["libonly/Cargo.toml"] = '[package]\nname = "libonly"\nversion = "0.1.0"\nedition = "2021"\n',
      ["libonly/src/lib.rs"] = "pub fn l() {}\n",
      -- two bins, one named like the package (declared second): that one wins
      ["multi/Cargo.toml"] = '[package]\nname = "multi"\nversion = "0.1.0"\nedition = "2021"\n[[bin]]\nname = "zzz"\npath = "src/zzz.rs"\n[[bin]]\nname = "multi"\npath = "src/main.rs"\n',
      ["multi/src/main.rs"] = "fn main() {}\n",
      ["multi/src/zzz.rs"] = "fn main() {}\n",
      -- two bins, none named like the package: the first one
      ["plain/Cargo.toml"] = '[package]\nname = "plain"\nversion = "0.1.0"\nedition = "2021"\n[[bin]]\nname = "first"\npath = "src/first.rs"\n[[bin]]\nname = "second"\npath = "src/second.rs"\n',
      ["plain/src/first.rs"] = "fn main() {}\n",
      ["plain/src/second.rs"] = "fn main() {}\n",
    })
  end

  it("picks the package containing the buffer file", function()
    dap_available()
    local dir = workspace()
    local target = cargo_meta(dir).target_directory
    local _, cfgs = fresh_setup()
    edit(dir .. "/b/src/util.rs")
    H.eq(dir .. "/b", cwd_of(cfgs))
    H.eq(target .. "/debug/b" .. EXE, default_for(cfgs))
    edit(dir .. "/a/src/main.rs")
    H.eq(dir .. "/a", cwd_of(cfgs))
    H.eq(target .. "/debug/a" .. EXE, default_for(cfgs))
  end)

  it("bin named like the package wins, else the first bin", function()
    dap_available()
    local dir = workspace()
    local target = cargo_meta(dir).target_directory
    local _, cfgs = fresh_setup()
    edit(dir .. "/multi/src/main.rs")
    H.eq(target .. "/debug/multi" .. EXE, default_for(cfgs))
    edit(dir .. "/plain/src/second.rs")
    H.eq(target .. "/debug/first" .. EXE, default_for(cfgs))
  end)

  it("a package without a bin is skipped: the file's own package is not chosen, the first package with a bin is", function()
    dap_available()
    local dir = workspace()
    local target = cargo_meta(dir).target_directory
    local _, cfgs = fresh_setup()
    edit(dir .. "/libonly/src/lib.rs")
    H.eq(target .. "/debug/a" .. EXE, default_for(cfgs))
    H.eq(dir .. "/a", cwd_of(cfgs))
  end)

  it("longest directory match: a nested package wins over its parent", function()
    dap_available()
    local dir = crate({
      ["Cargo.toml"] = '[package]\nname = "top"\nversion = "0.1.0"\nedition = "2021"\n[workspace]\nmembers = ["sub"]\n',
      ["src/main.rs"] = "fn main() {}\n",
      ["sub/Cargo.toml"] = '[package]\nname = "sub"\nversion = "0.1.0"\nedition = "2021"\n',
      ["sub/src/main.rs"] = "fn main() {}\n",
    })
    local target = cargo_meta(dir).target_directory
    local _, cfgs = fresh_setup()
    edit(dir .. "/sub/src/main.rs")
    H.eq(target .. "/debug/sub" .. EXE, default_for(cfgs))
    edit(dir .. "/src/main.rs")
    H.eq(target .. "/debug/top" .. EXE, default_for(cfgs))
  end)

  it("no file: the workspace root package, else (virtual workspace) the first package with a bin", function()
    dap_available()
    local top = crate({
      ["Cargo.toml"] = '[package]\nname = "rootpkg"\nversion = "0.1.0"\nedition = "2021"\n[workspace]\nmembers = ["aaa"]\n',
      ["src/main.rs"] = "fn main() {}\n",
      ["aaa/Cargo.toml"] = '[package]\nname = "aaa"\nversion = "0.1.0"\nedition = "2021"\n',
      ["aaa/src/main.rs"] = "fn main() {}\n",
    })
    local _, cfgs = fresh_setup()
    vim.cmd.cd(vim.fn.fnameescape(top))
    vim.cmd.enew()
    H.eq(top, cwd_of(cfgs))
    H.eq(cargo_meta(top).target_directory .. "/debug/rootpkg" .. EXE, default_for(cfgs))
    local virt = workspace()
    vim.cmd.cd(vim.fn.fnameescape(virt))
    vim.cmd.enew()
    H.eq(virt .. "/a", cwd_of(cfgs))
  end)

  it("no package with a bin: default program falls back to <cwd>/, package dir to the cwd", function()
    dap_available()
    local dir = crate({
      ["Cargo.toml"] = '[package]\nname = "onlylib"\nversion = "0.1.0"\nedition = "2021"\n',
      ["src/lib.rs"] = "pub fn l() {}\n",
    })
    local _, cfgs = fresh_setup()
    edit(dir .. "/src/lib.rs")
    H.eq(vim.fn.getcwd() .. "/", default_for(cfgs))
    H.eq(vim.fn.getcwd(), cwd_of(cfgs))
  end)
end)

-- 4 ------------------------------------------------------------------------
describe("build_current_binary failures", function()
  it("no package with a bin: ERROR notify and dap.ABORT", function()
    dap_available()
    local dir = crate({
      ["Cargo.toml"] = '[package]\nname = "nobin"\nversion = "0.1.0"\nedition = "2021"\n',
      ["src/lib.rs"] = "pub fn l() {}\n",
    })
    local _, cfgs = fresh_setup()
    edit(dir .. "/src/lib.rs")
    local n = capture()
    local r = by_name(cfgs, "Rust: run current package binary (args prompt)").program()
    H.eq(require("dap").ABORT, r)
    H.eq({ { msg = "no Cargo package with a binary found for this buffer", level = vim.log.levels.ERROR, title = "dap" } }, n)
  end)

  it("a failing cargo build: ERROR 'cargo build failed:' + stderr and ABORT", function()
    dap_available()
    local dir = crate({
      ["Cargo.toml"] = '[package]\nname = "badbuild"\nversion = "0.1.0"\nedition = "2021"\n',
      ["src/main.rs"] = "fn main() { let x: u32 = \"no\"; }\n",
    })
    local _, cfgs = fresh_setup()
    edit(dir .. "/src/main.rs")
    local n = capture()
    local r = by_name(cfgs, "Rust: run current package binary (args prompt)").program()
    H.eq(require("dap").ABORT, r)
    H.eq(2, #n)
    H.eq(vim.log.levels.INFO, n[1].level)
    H.eq(vim.log.levels.ERROR, n[2].level)
    H.eq("dap", n[2].title)
    H.eq("cargo build failed:\n", n[2].msg:sub(1, 20))
    H.match(n[2].msg, "mismatched types")
  end)
end)

-- 5 ------------------------------------------------------------------------
describe("cargo metadata failure", function()
  it("an invalid Cargo.toml gives no binary and no error", function()
    dap_available()
    local dir = crate({ ["Cargo.toml"] = "this is [not toml\n", ["src/main.rs"] = "fn main() {}\n" })
    local _, cfgs = fresh_setup()
    edit(dir .. "/src/main.rs")
    local n = capture()
    local calls = stub_input("x")
    local ok, e = pcall(function()
      by_name(cfgs, "LLDB: Launch").program()
      H.eq(vim.fn.getcwd(), by_name(cfgs, "Rust: run current package binary (args prompt)").cwd())
    end)
    H.ok(ok, tostring(e))
    H.eq(vim.fn.getcwd() .. "/", calls[1][2])
    H.eq({}, n)
  end)

  it("cargo exiting 0 with invalid JSON gives nil, not an error", function()
    dap_available()
    local dir = bin_crate("jsonpkg")
    edit(dir .. "/src/main.rs")
    local _, cfgs = fresh_setup()
    local real = vim.system
    stub(vim, "system", function(cmd, ...)
      if cmd[1] == "cargo" and cmd[2] == "metadata" then
        return {
          wait = function()
            return { code = 0, stdout = "{not json", stderr = "" }
          end,
        }
      end
      return real(cmd, ...)
    end)
    local calls = stub_input("x")
    local ok, e = pcall(function()
      by_name(cfgs, "LLDB: Launch").program()
    end)
    H.ok(ok, tostring(e))
    H.eq(vim.fn.getcwd() .. "/", calls[1][2])
  end)
end)

-- 6, 7 ---------------------------------------------------------------------
local function sysroot_script()
  local o = vim.system({ "rustc", "--print", "sysroot" }, { text = true }):wait(10000)
  return vim.trim(o.stdout) .. "/lib/rustlib/etc/lldb_lookup.py"
end

--- Count the `rustc --print sysroot` calls made while fn runs; `answer` (a
--- table {code, stdout}) replaces the real result when given.
local function count_sysroot(answer, fn)
  local real = vim.system
  local n = 0
  stub(vim, "system", function(cmd, ...)
    if cmd[1] == "rustc" and cmd[2] == "--print" then
      n = n + 1
      if answer then
        return {
          wait = function()
            return { code = answer.code, stdout = answer.stdout, stderr = "" }
          end,
        }
      end
    end
    return real(cmd, ...)
  end)
  fn()
  vim.system = real
  return n
end

describe("lldb_lookup_script (sysroot cache)", function()
  it("resolves `rustc --print sysroot` once across calls", function()
    dap_available()
    local _, _, listener = fresh_setup()
    local n = count_sysroot(nil, function()
      for _ = 1, 3 do
        listener({ type = "codelldb", sourceLanguages = { "rust" } })
      end
    end)
    H.eq(1, n)
  end)

  it("a failing rustc is cached as missing: no import, no second lookup", function()
    dap_available()
    local _, _, listener = fresh_setup()
    local out
    local n = count_sysroot({ code = 1, stdout = "" }, function()
      out = listener({ type = "codelldb", sourceLanguages = { "rust" } })
      listener({ type = "codelldb", sourceLanguages = { "rust" } })
    end)
    H.eq(1, n)
    H.eq({ "breakpoint set -n rust_panic" }, out.initCommands)
  end)

  it("a toolchain without lldb_lookup.py is cached as missing too", function()
    dap_available()
    local _, _, listener = fresh_setup()
    local empty = H.tmpdir()
    local out
    local n = count_sysroot({ code = 0, stdout = empty .. "\n" }, function()
      out = listener({ type = "codelldb", sourceLanguages = { "rust" } })
      listener({ type = "codelldb", sourceLanguages = { "rust" } })
    end)
    H.eq(1, n)
    H.eq({ "breakpoint set -n rust_panic" }, out.initCommands)
  end)
end)

describe("rust_lldb_init (dap.listeners.on_config)", function()
  local function rust(extra)
    return vim.tbl_extend("force", { type = "codelldb", request = "launch", sourceLanguages = { "rust" } }, extra or {})
  end

  it("adds the lldb_lookup.py import first and the rust_panic breakpoint last, nothing else", function()
    dap_available()
    local script = sysroot_script()
    if not vim.uv.fs_stat(script) then
      H.skip_file("this toolchain ships no lldb_lookup.py")
    end
    local _, _, listener = fresh_setup()
    local out = listener(rust())
    H.eq({ 'command script import "' .. script .. '"', "breakpoint set -n rust_panic" }, out.initCommands)
    for _, c in ipairs(out.initCommands) do
      H.no_match(c, "lldb_commands", true)
    end
  end)

  it("keeps existing initCommands (import inserted at position 1, panic breakpoint appended)", function()
    dap_available()
    local script = sysroot_script()
    if not vim.uv.fs_stat(script) then
      H.skip_file("this toolchain ships no lldb_lookup.py")
    end
    local _, _, listener = fresh_setup()
    local out = listener(rust({ initCommands = { "settings set x y", "log enable lldb all" } }))
    H.eq({
      'command script import "' .. script .. '"',
      "settings set x y",
      "log enable lldb all",
      "breakpoint set -n rust_panic",
    }, out.initCommands)
  end)

  it("does not add the import when an initCommand already mentions lldb_lookup.py", function()
    dap_available()
    local _, _, listener = fresh_setup()
    local mine = 'command script import "/somewhere/lldb_lookup.py"'
    local out = listener(rust({ initCommands = { mine } }))
    H.eq({ mine, "breakpoint set -n rust_panic" }, out.initCommands)
  end)

  it("is idempotent: a second call adds nothing", function()
    dap_available()
    local _, _, listener = fresh_setup()
    local once = listener(rust({ initCommands = { "a" } }))
    local snapshot = vim.deepcopy(once.initCommands)
    local twice = listener(once)
    H.eq(snapshot, twice.initCommands)
    local n = 0
    for _, c in ipairs(twice.initCommands) do
      if c == "breakpoint set -n rust_panic" then
        n = n + 1
      end
    end
    H.eq(1, n)
  end)

  it("leaves other adapter types and non-Rust languages unchanged", function()
    dap_available()
    local _, _, listener = fresh_setup()
    local py = { type = "python", request = "launch", sourceLanguages = { "rust" } }
    H.eq({ type = "python", request = "launch", sourceLanguages = { "rust" } }, listener(py))
    local cpp = { type = "codelldb", request = "launch", sourceLanguages = { "cpp" } }
    H.eq({ type = "codelldb", request = "launch", sourceLanguages = { "cpp" } }, listener(cpp))
    local none = { type = "codelldb", request = "launch" }
    H.eq({ type = "codelldb", request = "launch" }, listener(none))
  end)

  it("registered under the key 'xynovim_rust_lldb' and applied by dap to a codelldb config", function()
    dap_available()
    local _, _, listener = fresh_setup()
    H.eq("function", type(listener))
    H.eq(listener, require("dap").listeners.on_config["xynovim_rust_lldb"])
  end)
end)

-- 8 ------------------------------------------------------------------------
describe("dap-ui opts", function()
  local function opts()
    return fresh()[3].opts()
  end

  it("is registered with the plugin spec and resolves to the same layouts", function()
    local p = require("lazy.core.config").plugins["nvim-dap-ui"]
    local o = require("lazy.core.plugin").values(p, "opts", false)
    H.eq(opts().layouts, o.layouts)
    H.eq(true, o.wrap)
  end)

  it("the UI stays open when the session terminates or exits (the output is only in the hidden dap-terminal otherwise)", function()
    local lazy = require("lazy")
    lazy.load({ plugins = { "nvim-dap-ui" } })
    local dap = require("dap")
    H.wait_for(function()
      return dap.listeners.before.event_terminated["dapui_config"] == nil
    end, 5000, "LazyVim's closing listener to be removed")
    H.is_nil(dap.listeners.before.event_exited["dapui_config"])
    H.eq("function", type(dap.listeners.after.event_initialized["dapui_config"]), "it still opens on start")
  end)

  it("the console is re-scrolled when its topline is at or past the buffer end; breakpoint signs use the theme's groups", function()
    H.need_os({ "linux" }, "topline never resets on macos-latest and windows-latest (run 38912021512), cause not diagnosed")
    require("lazy").load({ plugins = { "nvim-dap-ui" } })
    local dap = require("dap")
    H.wait_for(function()
      return dap.listeners.after.event_stopped["xynovim_console"] ~= nil
    end, 5000, "the console listener")
    for _, ev in ipairs({ "event_stopped", "event_terminated", "event_exited" }) do
      H.eq("function", type(dap.listeners.after[ev]["xynovim_console"]), ev)
    end
    H.eq("DapBreakpoint", vim.fn.sign_getdefined("DapBreakpoint")[1].texthl)
    H.eq("DapBreakpointCondition", vim.fn.sign_getdefined("DapBreakpointCondition")[1].texthl)
    -- a window in the state the field test saw: 10 lines, topline 19
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].filetype = "dapui_console"
    vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.fn["repeat"]({ "out" }, 10))
    vim.cmd("botright 5split")
    local w = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w, b)
    vim.fn.winrestview({ topline = 10 })
    local before = vim.fn.getwininfo(w)[1].topline
    dap.listeners.after.event_terminated["xynovim_console"]()
    H.wait_for(function()
      return vim.fn.getwininfo(w)[1].topline == 1
    end, 2000, "topline back at 1 (was " .. before .. ")")
    vim.api.nvim_win_close(w, true)
  end)

  it("wrap on; left sidebar elements and sizes; bottom panel", function()
    local o = opts()
    H.eq(true, o.wrap)
    H.eq("left", o.layouts[1].position)
    H.eq({
      { id = "scopes", size = 0.4 },
      { id = "breakpoints", size = 0.15 },
      { id = "stacks", size = 0.25 },
      { id = "watches", size = 0.2 },
    }, o.layouts[1].elements)
    H.eq("bottom", o.layouts[2].position)
    H.eq(10, o.layouts[2].size)
    H.eq({ { id = "repl", size = 0.5 }, { id = "console", size = 0.5 } }, o.layouts[2].elements)
  end)

  it("sidebar width = max(40, min(60, floor(columns * 0.35)))", function()
    -- headless nvim has no UI to resize: shadow vim.o for the call instead
    local real = vim.o
    undo[#undo + 1] = function()
      vim.o = real
    end
    for cols, want in pairs({ [80] = 40, [100] = 40, [140] = 49, [171] = 59, [200] = 60, [400] = 60 }) do
      vim.o = setmetatable({ columns = cols }, { __index = real })
      H.eq(want, opts().layouts[1].size, "columns=" .. cols)
    end
  end)
end)

-- 9, 10 --------------------------------------------------------------------
describe("<leader>dR workspace debuggables", function()
  local function key_fn()
    local k = fresh()[1].keys[1]
    H.eq("<leader>dR", k[1])
    H.eq("Rust Debuggables (whole workspace)", k.desc)
    return k[2]
  end

  --- Stub the editor side: RA runnables answer, vim.ui.select, dap start, last debuggable.
  local function rig(ra_result, choose)
    local r = { selected = {}, started = {}, last = {} }
    stub(require("rustaceanvim.rust_analyzer"), "buf_request", function(_, method, _, cb)
      r.method = method
      cb(nil, ra_result)
    end)
    stub(vim.ui, "select", function(items, opts, on_choice)
      r.items, r.opts = items, opts
      r.labels = vim.tbl_map(opts.format_item, items)
      local pick = choose and choose(items, r.labels)
      on_choice(pick)
    end)
    stub(require("rustaceanvim.dap"), "start", function(args, verbose, cb)
      r.started[#r.started + 1] = { args = args, verbose = verbose, cb = cb }
    end)
    stub(require("rustaceanvim.cached_commands"), "set_last_debuggable", function(args)
      r.last[#r.last + 1] = args
    end)
    return r
  end

  local function ws()
    return crate({
      ["Cargo.toml"] = '[workspace]\nresolver = "2"\nmembers = ["app", "tools"]\n',
      ["app/Cargo.toml"] = '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2021"\n',
      ["app/src/main.rs"] = "fn main() {}\n",
      ["app/examples/demo.rs"] = "fn main() {}\n",
      ["tools/Cargo.toml"] = '[package]\nname = "tools"\nversion = "0.1.0"\nedition = "2021"\n',
      ["tools/src/lib.rs"] = "pub fn t() {}\n",
      ["tools/src/bin/gen.rs"] = "fn main() {}\n",
      ["tools/examples/ex.rs"] = "fn main() {}\n",
    })
  end

  local function runnable(cargo, exec, kind)
    return {
      label = "label",
      kind = kind or "cargo",
      args = { cargoArgs = cargo, executableArgs = exec or {}, workspaceRoot = "/ws", cwd = "/ws/app" },
    }
  end

  it("lists bins and examples of all packages plus the current file's runnables, merged and deduped", function()
    H.need_rust()
    local dir = ws()
    edit(dir .. "/app/src/main.rs")
    vim.bo.filetype = "rust"
    local ra = {
      runnable({ "run", "--package", "app", "--bin", "app" }), -- same as the metadata bin once sanitized
      runnable({ "test", "--package", "app", "--bin", "app" }, { "tests::a", "--exact", "--show-output" }),
      runnable({ "test", "--package", "app", "--bin", "app" }, { "tests::b", "--exact", "--show-output" }),
      runnable({ "test", "--package", "app", "--bin", "app" }, { "tests::a", "--exact", "--show-output" }), -- duplicate
      runnable({ "check", "--package", "app" }), -- dropped
      { label = "shell", kind = "shell", args = { cwd = "/ws", program = "make", args = {} } }, -- dropped
    }
    local r = rig(ra, function()
      return nil
    end)
    key_fn()()
    H.eq("experimental/runnables", r.method)
    H.eq("Debuggables (workspace)", r.opts.prompt)
    H.eq("rust-tools/debuggables", r.opts.kind)
    local want = {
      "bin app (app)",
      "example demo (app)",
      "bin gen (tools)",
      "example ex (tools)",
      "test/run: test --no-run --package app --bin app -- tests::a --exact --show-output",
      "test/run: test --no-run --package app --bin app -- tests::b --exact --show-output",
    }
    local got = vim.deepcopy(r.labels)
    table.sort(got)
    local sorted = vim.deepcopy(want)
    table.sort(sorted)
    H.eq(sorted, got)
    -- metadata entries first, runnables after
    local idx = {}
    for i, l in ipairs(r.labels) do
      idx[l] = i
    end
    H.ok(idx["bin gen (tools)"] < idx[want[5]] and idx["example demo (app)"] < idx[want[5]])
    -- 'run' was sanitized to 'build' and merged into the metadata entry (no second "app" bin entry)
    for _, l in ipairs(r.labels) do
      H.no_match(l, "test/run: build", true)
      H.no_match(l, "check", true)
      H.no_match(l, "make", true)
    end
    -- the metadata entries carry cargo args for debugging
    for _, it in ipairs(r.items) do
      if it.label == "bin gen (tools)" then
        H.eq({ "build", "--package", "tools", "--bin", "gen" }, it.args.cargoArgs)
        H.eq(dir, it.args.workspaceRoot)
        H.eq(dir .. "/tools", it.args.cwd)
        H.eq({}, it.args.executableArgs)
      elseif it.label == "example ex (tools)" then
        H.eq({ "build", "--package", "tools", "--example", "ex" }, it.args.cargoArgs)
      end
    end
  end)

  it("selecting starts rustaceanvim.dap.start with dap.run and records the last debuggable", function()
    H.need_rust()
    local dir = ws()
    edit(dir .. "/app/src/main.rs")
    vim.bo.filetype = "rust"
    local r = rig({}, function(items, labels)
      for i, l in ipairs(labels) do
        if l == "example ex (tools)" then
          return items[i]
        end
      end
    end)
    key_fn()()
    H.eq(1, #r.started)
    H.eq({ "build", "--package", "tools", "--example", "ex" }, r.started[1].args.cargoArgs)
    H.eq(true, r.started[1].verbose)
    H.eq(require("dap").run, r.started[1].cb)
    H.eq(1, #r.last)
    H.eq(r.started[1].args, r.last[1])
  end)

  it("cancelling the picker starts nothing", function()
    H.need_rust()
    local dir = ws()
    edit(dir .. "/app/src/main.rs")
    vim.bo.filetype = "rust"
    local r = rig({}, function()
      return nil
    end)
    key_fn()()
    H.ok(#r.items > 0)
    H.eq(0, #r.started)
    H.eq(0, #r.last)
  end)

  it("nothing debuggable: WARN 'no debuggable targets found' and no picker", function()
    H.need_rust()
    local dir = crate({
      ["Cargo.toml"] = '[package]\nname = "libonly"\nversion = "0.1.0"\nedition = "2021"\n',
      ["src/lib.rs"] = "pub fn l() {}\n",
    })
    edit(dir .. "/src/lib.rs")
    vim.bo.filetype = "rust"
    local n = capture()
    local r = rig({ runnable({ "check", "--package", "libonly" }) })
    key_fn()()
    H.eq(nil, r.items)
    H.eq({ { msg = "no debuggable targets found", level = vim.log.levels.WARN, title = "dap" } }, n)
  end)

  it("a non-Rust buffer: WARN and no request", function()
    H.need_rust()
    local dir = crate({ ["notes.txt"] = "x\n" })
    edit(dir .. "/notes.txt")
    local n = capture()
    local r = rig({})
    key_fn()()
    H.eq(nil, r.method)
    H.eq({ { msg = "<leader>dR works from a Rust buffer", level = vim.log.levels.WARN, title = "dap" } }, n)
  end)

  it("uses rustaceanvim internals that exist in the locked version", function()
    H.need_rust()
    local rv = require("rustaceanvim.runnables")
    H.eq("function", type(rv.as_cargo_runnable))
    H.eq("function", type(require("rustaceanvim.overrides").sanitize_command_for_debugging))
    H.eq("function", type(require("rustaceanvim.dap").start))
    H.eq("function", type(require("rustaceanvim.cached_commands").set_last_debuggable))
    H.eq("function", type(require("rustaceanvim.rust_analyzer").buf_request))
    -- and they behave as dap.lua relies on
    local c = { "run", "--package", "p", "--bin", "p" }
    require("rustaceanvim.overrides").sanitize_command_for_debugging(c)
    H.eq({ "build", "--package", "p", "--bin", "p" }, c)
    local t = { "test", "--package", "p" }
    require("rustaceanvim.overrides").sanitize_command_for_debugging(t)
    H.eq({ "test", "--no-run", "--package", "p" }, t)
    H.is_nil(rv.as_cargo_runnable({ args = { program = "x" } }))
  end)

  it("the real <leader>dR map exists in a Rust buffer", function()
    H.need_rust()
    local dir = bin_crate("mapcheck")
    edit(dir .. "/src/main.rs")
    H.very_lazy()
    local m = vim.fn.maparg("<leader>dR", "n", false, true)
    H.eq("Rust Debuggables (whole workspace)", m.desc)
  end)
end)

describe("<leader>dP pause", function()
  local function key_fn()
    local k = fresh()[1].keys[2]
    H.eq("<leader>dP", k[1])
    return k[2]
  end

  it("a running session with no known threads asks for them and pauses the first (codelldb fills them only on a stop)", function()
    local dap = require("dap")
    local pauses, reqs = {}, {}
    local orig_pause, orig_session = dap.pause, dap.session
    dap.pause = function(...)
      pauses[#pauses + 1] = { ... }
    end
    dap.session = function()
      return {
        threads = {},
        request = function(_, cmd, _, cb)
          reqs[#reqs + 1] = cmd
          cb(nil, { threads = { { id = 7, name = "main" } } })
        end,
      }
    end
    local ok, err = pcall(key_fn())
    dap.pause, dap.session = orig_pause, orig_session
    H.ok(ok, tostring(err))
    H.eq({ "threads" }, reqs)
    H.eq({ { 7 } }, pauses)
  end)

  it("known threads: plain dap.pause(); no session: a notice", function()
    local dap = require("dap")
    local pauses = 0
    local orig_pause, orig_session = dap.pause, dap.session
    dap.pause = function()
      pauses = pauses + 1
    end
    dap.session = function()
      return { threads = { [1] = {} }, request = error }
    end
    local ok, err = pcall(key_fn())
    H.ok(ok, tostring(err))
    H.eq(1, pauses)
    dap.session = function() end
    local n = H.capture_notify()
    pcall(key_fn())
    n.restore()
    dap.pause, dap.session = orig_pause, orig_session
    H.eq(1, pauses)
    H.eq("no debug session", n.list[1].msg)
  end)
end)

-- 16, 17 -------------------------------------------------------------------
describe("rustaceanvim dap settings", function()
  it("dap.autoload_configurations is false", function()
    H.need_rust()
    H.eq(false, require("rustaceanvim.config.internal").dap.autoload_configurations)
  end)

  it("adapter: Mason's codelldb with --liblldb and --port ${port}", function()
    H.need_rust()
    local dir = bin_crate("adapterpkg")
    edit(dir .. "/src/main.rs")
    H.very_lazy()
    local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/codelldb"
    if not vim.uv.fs_stat(mason_bin) then
      H.skip_file("Mason's codelldb is not installed")
    end
    H.ok(vim.uv.fs_stat(mason_bin), "mason/bin/codelldb")
    local a = vim.g.rustaceanvim.dap.adapter
    H.eq("table", type(a), "LazyVim sets the adapter when mason.nvim is present")
    H.eq("server", a.type)
    H.eq("${port}", a.port)
    H.eq("127.0.0.1", a.host)
    H.eq(vim.uv.fs_realpath(mason_bin), vim.uv.fs_realpath(a.executable.command))
    local args = a.executable.args
    H.eq("--liblldb", args[1])
    H.match(args[2], "liblldb", true)
    H.eq({ "--port", "${port}" }, { args[3], args[4] })
    H.eq(4, #args)
    H.ok(vim.uv.fs_stat(args[2]), "liblldb library exists: " .. args[2])
    -- the user's rustaceanvim opts were not lost on the way
    H.eq(false, vim.g.rustaceanvim.dap.autoload_configurations)
  end)
end)

-- 12, 13, 14 ---------------------------------------------------------------
describe("neotest, overseer", function()
  local function extras()
    local f = assert(io.open(H.repo .. "/lazyvim.json"))
    local j = vim.json.decode(f:read("*a"))
    f:close()
    return j.extras
  end

  it("lazyvim.json enables dap.core, test.core, editor.overseer and lang.rust", function()
    local e = extras()
    for _, x in ipairs({ "dap.core", "test.core", "editor.overseer", "lang.rust" }) do
      H.has(e, "lazyvim.plugins.extras." .. x)
    end
  end)

  it("neotest is configured with rustaceanvim's adapter", function()
    local p = require("lazy.core.config").plugins["neotest"]
    H.ok(p, "neotest plugin spec")
    -- the raw spec: resolving it with lazy's values() would run LazyVim's opts
    -- function (it replaces the adapter names by objects) before neotest loads
    H.eq("table", type(p.opts.adapters["rustaceanvim.neotest"]), "adapters['rustaceanvim.neotest']")
  end)

  it("test keys exist and neotest's watch consumer is present", function()
    H.need_rust()
    local dir = bin_crate("neokeys")
    edit(dir .. "/src/main.rs")
    H.very_lazy()
    local want = {
      ["<leader>tt"] = "Run File (Neotest)",
      ["<leader>tr"] = "Run Nearest (Neotest)",
      ["<leader>tT"] = "Run All Test Files (Neotest)",
      ["<leader>tl"] = "Run Last (Neotest)",
      ["<leader>tw"] = "Toggle Watch (Neotest)",
      ["<leader>ts"] = "Toggle Summary (Neotest)",
      ["<leader>to"] = "Show Output (Neotest)",
      ["<leader>tO"] = "Toggle Output Panel (Neotest)",
      ["<leader>tS"] = "Stop (Neotest)",
      ["<leader>ta"] = "Attach to Test (Neotest)",
      ["<leader>td"] = "Debug Nearest",
    }
    for lhs, desc in pairs(want) do
      H.eq(desc, vim.fn.maparg(lhs, "n", false, true).desc, lhs)
    end
    local nt = require("neotest")
    local waited = vim.wait(15000, function()
      return nt.watch
    end, 50)
    H.ok(waited, "neotest.consumers.watch; messages: " .. H.messages())
    H.ok(nt.watch, "neotest.watch (consumer)")
    H.eq("function", type(nt.watch.toggle))
    H.ok(nt.run and nt.summary and nt.output_panel)
  end)

  it("nextest is used for neotest's test commands when cargo-nextest is installed", function()
    H.need_rust()
    if vim.fn.executable("cargo-nextest") ~= 1 then
      H.skip_file("cargo-nextest is not installed")
    end
    local args = { "test", "--package", "p", "--", "t::a", "--exact" }
    local out = require("rustaceanvim.overrides").maybe_nextest_transform(args)
    H.eq("nextest", out[1])
    H.eq("run", out[2])
  end)

  it("<leader>tD is a Rust-buffer map that runs `cargo test --doc --workspace` in a terminal", function()
    H.need_rust()
    local dir = bin_crate("doctestpkg")
    edit(dir .. "/src/main.rs")
    H.very_lazy()
    H.wait_for(function()
      return vim.fn.maparg("<leader>tD", "n", false, true).desc == "Doctests (cargo test --doc)"
    end, 60000, "the <leader>tD map")
    local seen = {}
    stub(Snacks.terminal, "get", function()
      return nil
    end)
    stub(Snacks.terminal, "open", function(cmd, opts)
      seen = { cmd = cmd, cwd = opts.cwd }
    end)
    local rc = require("config.rust_context")
    local flags = rc.cargo_flags(rc.get(dir))
    H.feed("<leader>tD", "mx")
    H.wait_for(function()
      return seen.cmd
    end, 5000, "the doctest terminal")
    H.eq(vim.list_extend({ "cargo", "test", "--doc", "--workspace" }, flags), seen.cmd)
    H.eq(dir, seen.cwd)
  end)

  it("neotest (nextest) cannot see doctests, cargo test --doc fails on them; README documents <leader>tD", function()
    H.need_rust()
    local dir = crate({
      ["Cargo.toml"] = '[package]\nname = "doctestlib"\nversion = "0.1.0"\nedition = "2021"\n',
      ["src/lib.rs"] = "/// ```\n/// assert_eq!(1, 2);\n/// ```\npub fn f() {}\n",
    })
    local d = vim.system({ "cargo", "test", "--doc" }, { cwd = dir, text = true }):wait(120000)
    H.ok(d.code ~= 0, "the failing doctest fails under cargo test --doc")
    if vim.fn.executable("cargo-nextest") == 1 then
      local nx = vim.system({ "cargo", "nextest", "run" }, { cwd = dir, text = true }):wait(120000)
      H.no_match(nx.stderr .. nx.stdout, "FAIL", true, "nextest does not run the doctest")
    end
    local readme = H.docs_text()
    H.match(readme, "nextest cannot run doctests", true)
    H.match(readme, "<leader>tD", true)
    H.match(readme, "a failing doctest is shown as skipped, not failed", true)
  end)

  it("overseer: <leader>oo/ow/ot exist and the Overseer commands are defined after load", function()
    H.need_rust()
    local dir = bin_crate("overseerpkg")
    edit(dir .. "/src/main.rs")
    H.very_lazy()
    for lhs, desc in pairs({ ["<leader>oo"] = "Run task", ["<leader>ow"] = "Task list", ["<leader>ot"] = "Task action" }) do
      local m = vim.fn.maparg(lhs, "n", false, true)
      H.eq(desc, m.desc, lhs)
    end
    require("lazy").load({ plugins = { "overseer.nvim" } })
    for _, c in ipairs({ "OverseerRun", "OverseerToggle", "OverseerTaskAction", "OverseerOpen", "OverseerClose", "OverseerShell" }) do
      H.eq(2, vim.fn.exists(":" .. c), c)
    end
  end)
end)

-- 15 -----------------------------------------------------------------------
describe("coverage honours :RustContext", function()
  local function key_fn()
    local k = dofile(H.repo .. "/lua/plugins/coverage.lua").keys[1]
    H.eq("<leader>tc", k[1])
    return k[2]
  end

  --- Run <leader>tc with vim.system stubbed; returns the command and cwd.
  local function run_tc(dir)
    local seen
    local real = vim.system
    stub(vim, "system", function(cmd, opts, cb)
      if cmd[1] == "cargo" and cmd[2] == "llvm-cov" then
        seen = { cmd = cmd, cwd = opts.cwd }
        vim.schedule(function()
          cb({ code = 1, stderr = "stub", stdout = "" })
        end)
        return {}
      end
      return real(cmd, opts, cb)
    end)
    capture()
    key_fn()()
    H.wait_for(function()
      return seen
    end, 5000, "the cargo llvm-cov call")
    return seen
  end

  local function setup_crate()
    local dir = crate({
      ["Cargo.toml"] = '[package]\nname = "covpkg"\nversion = "0.1.0"\nedition = "2021"\n[features]\ndefault = ["a"]\na = []\nb = []\n',
      ["src/main.rs"] = "fn main() {}\n",
    })
    edit(dir .. "/src/main.rs")
    undo[#undo + 1] = function()
      pcall(require("config.rust_context").apply, dir, nil)
    end
    return dir
  end

  it("default context: --all-features; nextest when installed", function()
    H.need_rust()
    local dir = setup_crate()
    local s = run_tc(dir)
    H.eq(dir, s.cwd)
    local want = { "cargo", "llvm-cov" }
    if vim.fn.executable("cargo-nextest") == 1 then
      want[#want + 1] = "nextest"
    end
    vim.list_extend(want, { "--workspace", "--ignore-run-fail", "--lcov", "--output-path", "target/lcov.info", "--all-features" })
    H.eq(want, s.cmd)
  end)

  it("a stored context (features, no default, target) is passed on", function()
    H.need_rust()
    local dir = setup_crate()
    require("config.rust_context").apply(dir, { all = false, no_default = true, features = { "b" }, target = "x86_64-unknown-linux-gnu" })
    local s = run_tc(dir)
    local tail = vim.list_slice(s.cmd, #s.cmd - 4)
    H.eq({ "--no-default-features", "--features", "b", "--target", "x86_64-unknown-linux-gnu" }, tail)
    H.not_ok(vim.tbl_contains(s.cmd, "--all-features"))
  end)

  it(":RustTools coverage entry carries the same flags", function()
    H.need_rust()
    local dir = setup_crate()
    require("config.rust_context").apply(dir, { all = false, no_default = false, features = { "a", "b" } })
    local items
    stub(Snacks, "picker", function(o)
      items = o.items
    end)
    require("config.rust_tasks").tools()
    H.ok(items, "the tools picker was opened")
    local cov
    for _, i in ipairs(items) do
      if i.text:find("coverage report", 1, true) then
        cov = i
      end
    end
    H.ok(cov, "coverage entry")
    H.eq({ "cargo", "llvm-cov", "--workspace", "--ignore-run-fail", "--summary-only", "--features", "a,b" }, cov.cmd)
    require("config.rust_context").apply(dir, nil)
    items = nil
    require("config.rust_tasks").tools()
    for _, i in ipairs(items) do
      if i.text:find("coverage report", 1, true) then
        H.eq({ "cargo", "llvm-cov", "--workspace", "--ignore-run-fail", "--summary-only", "--all-features" }, i.cmd)
      end
    end
  end)

  it("the <leader>tc / tg / tG keys are registered by the plugin spec", function()
    local keys = dofile(H.repo .. "/lua/plugins/coverage.lua").keys
    local lhs = vim.tbl_map(function(k)
      return k[1]
    end, keys)
    H.eq({ "<leader>tc", "<leader>tg", "<leader>tG" }, lhs)
  end)
end)

-- 11 -----------------------------------------------------------------------
describe("real debug session (codelldb + cargo)", function()
  local S -- shared crate { dir, bin, main_buf }
  local MAIN = table.concat({
    "#[derive(Debug)]",
    "#[allow(dead_code)]",
    "enum E {",
    "    A,",
    "    B(i32),",
    "}",
    "",
    "fn check(n: usize) {",
    '    let owned = String::from("hello");',
    "    let v = vec![1, 2, 3, 4];",
    "    let k = E::B(7);",
    "    if n > 0 && v.len() == 4 {",
    '        panic!("boom {} {:?} {:?}", owned, v, k);',
    "    }",
    "}",
    "",
    "fn main() {",
    "    let x = 1;",
    "    check(x);",
    "}",
    "",
  }, "\n")
  local MAIN_LINE = 19 -- `check(x);`

  local function need()
    H.need_rust()
    if vim.fn.stdpath("data") and not vim.uv.fs_stat(vim.fn.stdpath("data") .. "/mason/bin/codelldb") then
      H.skip_file("Mason's codelldb is not installed")
    end
    local cfg = vim.fn.expand("~/.cargo/config.toml")
    local txt = vim.uv.fs_stat(cfg) and table.concat(vim.fn.readfile(cfg), "\n") or ""
    if not txt:find("[profile.dev]", 1, true) or not txt:find("debug%s*=%s*true") then
      H.skip_file("~/.cargo/config.toml lacks profile.dev debug = true (locals need full debuginfo)")
    end
  end

  local function session()
    if S then
      vim.cmd.cd(vim.fn.fnameescape(S.dir))
      vim.cmd.edit(vim.fn.fnameescape(S.dir .. "/src/main.rs"))
      return S
    end
    local dir = crate({
      ["Cargo.toml"] = '[package]\nname = "panicker"\nversion = "0.1.0"\nedition = "2021"\n',
      ["src/main.rs"] = MAIN,
    })
    vim.cmd.cd(vim.fn.fnameescape(dir))
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/src/main.rs"))
    H.very_lazy()
    local b = vim.system({ "cargo", "build" }, { cwd = dir, text = true }):wait(180000)
    H.eq(0, b.code, "building the debug crate: " .. (b.stderr or ""))
    H.wait_lsp("rust-analyzer", vim.api.nvim_get_current_buf(), 60000)
    S = { dir = dir, bin = cargo_meta(dir).target_directory .. "/debug/panicker" .. EXE }
    return S
  end

  --- Wait for the current dap session to be stopped; returns session.
  local function stopped(timeout)
    local dap = require("dap")
    return H.wait_for(function()
      local s = dap.session()
      return s and s.stopped_thread_id and s.current_frame and s
    end, timeout or 90000, "the debugger to stop")
  end

  local function request(s, cmd, args)
    local res
    s:request(cmd, args, function(err, body)
      res = { err = err, body = body }
    end)
    H.wait_for(function()
      return res
    end, 20000, "dap " .. cmd)
    H.is_nil(res.err and res.err.message, "dap " .. cmd)
    return res.body
  end

  --- Local variables of the frame whose name contains `pat`: { name = value }.
  local function locals_of(s, pat)
    local st = request(s, "stackTrace", { threadId = s.stopped_thread_id })
    local frame
    for _, f in ipairs(st.stackFrames) do
      if f.name:find(pat, 1, true) then
        frame = f
        break
      end
    end
    H.ok(frame, "no frame matching " .. pat .. " in " .. vim.inspect(vim.tbl_map(function(f)
      return f.name
    end, st.stackFrames)))
    local scopes = request(s, "scopes", { frameId = frame.id }).scopes
    local out = {}
    for _, sc in ipairs(scopes) do
      if sc.name == "Local" or sc.name:find("Local") then
        for _, v in ipairs(request(s, "variables", { variablesReference = sc.variablesReference }).variables) do
          out[v.name] = v.value
        end
      end
    end
    return out, st.stackFrames
  end

  local function assert_panic_stop(s)
    local vars, frames = locals_of(s, "check")
    H.match(frames[1].name, "rust_panic", true, "top frame")
    H.eq('"hello"', vars.owned)
    H.eq("size=4", vars.v)
    H.eq("B(7)", vars.k)
  end

  local function release()
    local dap = require("dap")
    dap.terminate()
    pcall(function()
      H.wait_for(function()
        return dap.session() == nil
      end, 15000, "the session to end")
    end)
  end

  it("configs 1 and 3 stop in rust_panic with the locals of the check frame", function()
    need()
    local s0 = session()
    vim.cmd("only")
    local _, cfgs = (function()
      local p = require("lazy.core.config").plugins["mason-nvim-dap.nvim"]
      p.opts.handlers.codelldb(codelldb_cfg())
      return nil, require("dap").configurations.rust
    end)()
    local dap = require("dap")
    -- config 1: program prompt answered with the built binary
    stub_input(s0.bin)
    dap.run(vim.deepcopy(by_name(cfgs, "LLDB: Launch")))
    assert_panic_stop(stopped())
    release()
    -- config 3: builds the current package, args prompt answered empty
    stub_input("")
    capture()
    dap.run(vim.deepcopy(by_name(cfgs, "Rust: run current package binary (args prompt)")))
    assert_panic_stop(stopped())
    release()
  end)

  it("a breakpoint in main stops with its locals, then continues into rust_panic", function()
    need()
    local s0 = session()
    local dap = require("dap")
    local bufnr = vim.api.nvim_get_current_buf()
    require("dap.breakpoints").set({}, bufnr, MAIN_LINE)
    undo[#undo + 1] = function()
      require("dap.breakpoints").clear()
    end
    local p = require("lazy.core.config").plugins["mason-nvim-dap.nvim"]
    p.opts.handlers.codelldb(codelldb_cfg())
    stub_input(s0.bin)
    dap.run(vim.deepcopy(by_name(dap.configurations.rust, "LLDB: Launch")))
    local s = stopped()
    local vars, frames = locals_of(s, "main")
    H.match(frames[1].name, "main", true)
    H.eq("1", vars.x)
    dap.continue()
    H.wait_for(function()
      local cur = dap.session()
      if not (cur and cur.stopped_thread_id) then
        return false
      end
      local st = request(cur, "stackTrace", { threadId = cur.stopped_thread_id, levels = 1 })
      return st.stackFrames[1] and st.stackFrames[1].name:find("rust_panic", 1, true)
    end, 60000, "the stop in rust_panic")
    assert_panic_stop(dap.session())
    release()
  end)

  --- Press `lhs` in the current buffer through its real mapping.
  local function press(lhs)
    local m = vim.fn.maparg(lhs, "n", false, true)
    H.ok(m.lhs, "no mapping for " .. lhs)
    if m.callback then
      m.callback()
    else
      H.feed(lhs, "mx")
    end
  end

  local function handler_run()
    -- mason-nvim-dap's handler (what a real session has run by now) installs
    -- the configurations rustaceanvim copies and the rust_lldb_init listener
    require("lazy.core.config").plugins["mason-nvim-dap.nvim"].opts.handlers.codelldb(codelldb_cfg())
  end

  it("<leader>dR (workspace debuggables) stops in rust_panic with the same locals", function()
    need()
    session()
    handler_run()
    stub(vim.ui, "select", function(items, opts, on_choice)
      for _, it in ipairs(items) do
        if opts.format_item(it) == "bin panicker (panicker)" then
          return on_choice(it)
        end
      end
      error("no 'bin panicker (panicker)' entry in " .. vim.inspect(vim.tbl_map(opts.format_item, items)))
    end)
    press("<leader>dR")
    assert_panic_stop(stopped())
    release()
  end)

  it("<leader>dr (rustaceanvim debuggables) stops in rust_panic with the same locals", function()
    need()
    vim.cmd("only")
    session()
    handler_run()
    H.wait_for(function()
      return vim.fn.maparg("<leader>dr", "n", false, true).buffer == 1
    end, 10000, "the buffer-local <leader>dr")
    local labels
    stub(vim.ui, "select", function(items, _, on_choice)
      labels = vim.deepcopy(items) -- rustaceanvim passes plain strings
      for i, l in ipairs(labels) do
        if l:find("^build %-%-package panicker %-%-bin panicker") then
          return on_choice(items[i], i)
        end
      end
      error("no build entry of the binary in " .. vim.inspect(labels))
    end)
    -- The real rust-analyzer answers experimental/runnables with "content
    -- modified" (and rustaceanvim then shows nothing) for a long time after the
    -- earlier builds, so its answer is replaced by what it returns for main.rs:
    -- everything else (mapping, sanitising, picker, dap start) is rustaceanvim's.
    local dir = vim.fs.dirname(vim.fs.dirname(vim.api.nvim_buf_get_name(0)))
    stub(require("rustaceanvim.rust_analyzer"), "buf_request", function(_, method, _, handler)
      H.eq("experimental/runnables", method)
      handler(nil, {
        {
          label = "cargo run --package panicker --bin panicker",
          kind = "cargo",
          args = {
            cargoArgs = { "run", "--package", "panicker", "--bin", "panicker" },
            cargoExtraArgs = {},
            executableArgs = {},
            workspaceRoot = dir,
            cwd = dir,
          },
        },
      })
    end)
    press("<leader>dr")
    H.ok(labels, "the debuggables picker was shown")
    assert_panic_stop(stopped())
    release()
  end)
end)

-- 18 -----------------------------------------------------------------------
pending("interactive prompts with a real terminal (vim.fn.input / vim.ui.select are stubbed here)", "needs a pty-driven nvim session")
pending("multi-bin workspaces in a real debug session (selection logic is covered above, no launch)", "README: untested")
pending("narrow terminals (dap-ui width is checked through vim.o.columns, not rendered)", "README: untested")
pending("clicking a Debug codelens", "needs a mouse-driven UI session")
pending("threads that panic (only the main thread is covered)", "README: untested")
pending("lldb-dap as the adapter", "lldb-dap is not installed; codelldb only")
