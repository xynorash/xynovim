-- Utilities for spec files. `local H = require("xynotest.helpers")`.
--
-- Assertions   H.eq H.ok H.not_ok H.is_nil H.match H.no_match H.has H.throws
-- Waiting      H.wait_for(pred, timeout_ms, msg) H.wait_lsp(name, bufnr, ms)
-- Editor       H.feed(keys) H.open(path) H.clients() H.diagnostics(source)
--              H.messages() H.clear_messages() H.capture_notify()
-- Fixtures     H.fixture(name, {git=true}) H.open_fixture(name, rel) H.git(...)
-- Processes    H.sandbox_sh(script, project) H.tmux(...) H.spawn(cmd)
-- Skipping     H.skip_file(reason) H.need_rust() H.need_sandbox() H.need_tmux()
-- Cleanup      H.cleanup() (the runner calls it at the end; registered
--              resources are temp dirs, jobs, tmux sockets, LSP clients)
local harness = require("xynotest.harness")

local H = {}
local repo = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
H.repo = repo
H.fixtures = repo .. "/tests/fixtures"

-- ---------------------------------------------------------------- assertions

local function fail(msg, level)
  error(msg, (level or 1) + 1)
end

function H.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    fail(
      ("%sexpected %s\n  actual   %s"):format(msg and (msg .. ": ") or "", vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

function H.ok(v, msg)
  if not v then
    fail(msg or ("expected a truthy value, got " .. vim.inspect(v)), 2)
  end
  return v
end

function H.not_ok(v, msg)
  if v then
    fail(msg or ("expected a falsy value, got " .. vim.inspect(v)), 2)
  end
end

function H.is_nil(v, msg)
  if v ~= nil then
    fail((msg and (msg .. ": ") or "") .. "expected nil, got " .. vim.inspect(v), 2)
  end
end

--- Lua pattern match (plain = true for a literal substring).
function H.match(str, pat, plain, msg)
  if type(str) ~= "string" or not str:find(pat, 1, plain) then
    fail((msg and (msg .. ": ") or "") .. ("%s does not match %q"):format(vim.inspect(str), pat), 2)
  end
end

function H.no_match(str, pat, plain, msg)
  if type(str) == "string" and str:find(pat, 1, plain) then
    fail((msg and (msg .. ": ") or "") .. ("%s unexpectedly matches %q"):format(vim.inspect(str), pat), 2)
  end
end

--- A list contains `item` (deep compare), or a string contains the substring.
function H.has(container, item, msg)
  local found = false
  if type(container) == "string" then
    found = container:find(item, 1, true) ~= nil
  else
    for _, v in ipairs(container) do
      if vim.deep_equal(v, item) then
        found = true
        break
      end
    end
  end
  if not found then
    fail(
      (msg and (msg .. ": ") or "") .. ("%s does not contain %s"):format(vim.inspect(container), vim.inspect(item)),
      2
    )
  end
end

--- fn must raise an error (matching `pat`, a Lua pattern, when given).
function H.throws(fn, pat)
  local ok, e = pcall(fn)
  if ok then
    fail("expected an error, none raised", 2)
  end
  if pat and not tostring(e):find(pat) then
    fail(("error %q does not match %q"):format(tostring(e), pat), 2)
  end
end

-- ------------------------------------------------------------------ waiting

--- Wait until pred() is truthy (vim.wait, the event loop keeps running).
--- Returns its value; raises `msg` on timeout.
function H.wait_for(pred, timeout_ms, msg)
  local value
  local done = vim.wait(timeout_ms or 5000, function()
    value = pred()
    return value and true or false
  end, 20)
  if not done then
    fail("timed out waiting for " .. (msg or "condition"), 2)
  end
  return value
end

function H.clients(bufnr, name)
  return vim.lsp.get_clients({ bufnr = bufnr, name = name })
end

--- Wait for LSP client `name` attached to `bufnr` (default current buffer).
function H.wait_lsp(name, bufnr, timeout_ms)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return H.wait_for(function()
    return H.clients(bufnr, name)[1]
  end, timeout_ms or 60000, "LSP client " .. name)
end

--- Diagnostics of a buffer, optionally only those of `source`
--- (vim.diagnostic `source` field, e.g. "rustc", "rust-analyzer", "clippy").
function H.diagnostics(source, bufnr)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr or 0)) do
    if not source or d.source == source or (d.source or ""):find(source, 1, true) then
      out[#out + 1] = d
    end
  end
  return out
end

-- ------------------------------------------------------------------- editor

--- Type keys as if typed (mappings apply). Processes them before returning.
function H.feed(keys, mode)
  local k = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(k, mode or "x", false)
end

--- :edit a file and fire VeryLazy (never fires headless; LazyVim's setup
--- hangs off it). Returns the buffer number.
function H.open(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  H.very_lazy()
  return vim.api.nvim_get_current_buf()
end

local very_lazy_done = false
--- Fire User VeryLazy and, the first time, wait for the notify replacement that
--- noice queues from it (vim.notify wrappers installed later made specs that
--- capture vim.notify flaky: "vim.notify has been overwritten by another plugin").
function H.very_lazy()
  local before = vim.notify
  vim.cmd("doautocmd User VeryLazy")
  if not very_lazy_done then
    very_lazy_done = true
    vim.wait(2000, function()
      return vim.notify ~= before
    end, 20)
    vim.wait(300) -- the rest of the queued callbacks
  end
end

--- Text of :messages.
function H.messages()
  return vim.api.nvim_exec2("messages", { output = true }).output
end

function H.clear_messages()
  vim.cmd("messages clear")
end

--- Replace vim.notify; returns { list = {{msg, level}...}, restore = fn }.
function H.capture_notify()
  local orig = vim.notify
  local cap = { list = {} }
  vim.notify = function(msg, level)
    cap.list[#cap.list + 1] = { msg = msg, level = level }
  end
  cap.restore = function()
    vim.notify = orig
  end
  H._restore[#H._restore + 1] = cap.restore
  return cap
end

-- ----------------------------------------------------------------- tool probes

--- Both rust-analyzer (a real one, not rustup's proxy stub) and cargo work.
function H.rust_available()
  if vim.env.XYNO_TEST_SKIP_RUST == "1" then
    return false, "XYNO_TEST_SKIP_RUST=1"
  end
  if vim.fn.executable("cargo") ~= 1 then
    return false, "cargo not found"
  end
  if vim.fn.executable("rust-analyzer") ~= 1 then
    return false, "rust-analyzer not found"
  end
  if vim.system({ "rust-analyzer", "--version" }):wait(10000).code ~= 0 then
    return false, "rust-analyzer is only a rustup proxy (rustup component add rust-analyzer)"
  end
  return true
end

function H.sandbox_available()
  if vim.fn.executable("bwrap") ~= 1 then
    return false, "bwrap not found"
  end
  local dir = H.tmpdir()
  local prev = vim.fn.chdir(dir)
  local cmd = require("config.agent_sandbox").wrap({ "true" }, dir, dir)
  vim.fn.chdir(prev)
  local r = vim.system(cmd, { cwd = dir }):wait(10000)
  if r.code ~= 0 then
    return false, "bwrap cannot create a sandbox here: " .. vim.trim(r.stderr or "")
  end
  return true
end

function H.tmux_available()
  if vim.fn.executable("tmux") ~= 1 then
    return false, "tmux not found"
  end
  return true
end

function H.skip_file(reason)
  harness.skip(reason)
end

local function need(probe)
  local ok, why = probe()
  if not ok then
    harness.skip(why)
  end
end
function H.need_rust()
  need(H.rust_available)
end
function H.need_sandbox()
  need(H.sandbox_available)
end
function H.need_tmux()
  need(H.tmux_available)
end

-- -------------------------------------------------------------- temp + cleanup

H._dirs, H._jobs, H._restore, H._tmux = {}, {}, {}, {}

--- A fresh empty directory, removed by cleanup().
function H.tmpdir()
  local base = vim.env.XYNO_TEST_TMP
  if not base or base == "" then
    base = vim.fs.dirname(vim.fn.tempname())
  end
  local dir = assert(vim.uv.fs_mkdtemp(base .. "/spec-XXXXXX"))
  H._dirs[#H._dirs + 1] = dir
  return dir
end

local function run(cmd, opts)
  local r = vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait(60000)
  return r
end

--- Run git in `dir` with a fixed identity; returns trimmed stdout, raises on failure.
function H.git(dir, ...)
  local cmd = { "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", ... }
  local r = run(cmd, { cwd = dir })
  if r.code ~= 0 then
    error(("git %s failed (%d): %s"):format(table.concat({ ... }, " "), r.code, r.stderr), 2)
  end
  return vim.trim(r.stdout)
end

--- git init + one commit of everything in `dir`.
function H.git_init(dir)
  H.git(dir, "init", "-q", "-b", "main")
  H.git(dir, "add", "-A")
  H.git(dir, "commit", "-q", "-m", "init")
  return dir
end

--- Copy tests/fixtures/<name> (a crate directory or a single .rs file) into a
--- fresh temp dir. Returns the path of the copy (directory, or file path).
--- opts.git = true makes the crate a git repository with one commit.
function H.fixture(name, opts)
  opts = opts or {}
  local src = H.fixtures .. "/" .. name
  local dir = H.tmpdir()
  local r = run({ "cp", "-a", "--no-preserve=ownership", src, dir .. "/" })
  assert(r.code == 0, "copying fixture " .. name .. ": " .. (r.stderr or ""))
  local dest = dir .. "/" .. name
  if opts.git then
    H.git_init(vim.fn.isdirectory(dest) == 1 and dest or dir)
  end
  return dest
end

--- Copy a fixture, cd into the crate, open `rel` (default src/main.rs or the
--- file itself). Returns dir, bufnr.
function H.open_fixture(name, rel, opts)
  local dest = H.fixture(name, opts)
  if vim.fn.isdirectory(dest) == 1 then
    vim.cmd.cd(vim.fn.fnameescape(dest))
    return dest, H.open(dest .. "/" .. (rel or "src/main.rs"))
  end
  vim.cmd.cd(vim.fn.fnameescape(vim.fs.dirname(dest)))
  return vim.fs.dirname(dest), H.open(dest)
end

--- Run a bash script inside the 99 sandbox wrapper (config.agent_sandbox)
--- with `project` writable. Returns vim.system's result {code, stdout, stderr}.
function H.sandbox_sh(script, project, opts)
  H.need_sandbox()
  local tmp = H.tmpdir()
  -- wrap() runs the command in nvim's cwd, which 99 sets to the project
  local prev = vim.fn.chdir(project)
  local cmd = require("config.agent_sandbox").wrap({ "bash", "-c", script }, project, tmp)
  vim.fn.chdir(prev)
  return run(cmd, vim.tbl_extend("force", { cwd = project }, opts or {}))
end

--- Start a background process (killed by cleanup). Returns the vim.SystemObj.
function H.spawn(cmd, opts)
  local obj = vim.system(cmd, opts or {})
  H._jobs[#H._jobs + 1] = obj
  return obj
end

--- Run tmux on a private socket (one per call site key); the server is killed
--- by cleanup. First argument may be a socket-name suffix table {sock="x"}.
function H.tmux(args, sock)
  H.need_tmux()
  sock = ("%s-%s"):format(vim.env.XYNO_TMUX_PREFIX or ("xynotest-" .. vim.uv.os_getpid()), sock or "main")
  H._tmux[sock] = true
  local cmd = { "tmux", "-L", sock }
  vim.list_extend(cmd, args)
  return run(cmd)
end

--- Stop LSP clients, close buffers, kill jobs and tmux servers, delete temp dirs.
function H.cleanup()
  for _, fn in ipairs(H._restore) do
    pcall(fn)
  end
  H._restore = {}
  -- bufferline recomputes its tabline (quadratic in the buffer count) on every
  -- event while the LSP clients are waited for: a spec that had listed many
  -- buffers then spun for minutes and nvim never got to exit. Drop the tabline
  -- and the buffers (without autocmds) before anything waits.
  pcall(function()
    vim.o.showtabline = 0
    vim.o.tabline = ""
    vim.cmd("noautocmd silent! %bwipeout!")
  end)
  pcall(function()
    for _, c in ipairs(vim.lsp.get_clients()) do
      c:stop(true)
    end
    vim.wait(2000, function()
      return #vim.lsp.get_clients() == 0
    end, 20)
  end)
  for sock in pairs(H._tmux) do
    pcall(function()
      vim.system({ "tmux", "-L", sock, "kill-server" }):wait(5000)
    end)
  end
  H._tmux = {}
  for _, j in ipairs(H._jobs) do
    pcall(function()
      j:kill(15)
      j:wait(2000)
    end)
  end
  H._jobs = {}
  pcall(vim.cmd, "silent! %bwipeout!")
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
  for _, d in ipairs(H._dirs) do
    vim.fn.delete(d, "rf")
  end
  H._dirs = {}
end

return H
