-- xyno-os: linux (a fake `claude` shell script on PATH)
-- A failed agent run (sandboxed claude exits non-zero) used to raise an unhandled Lua error with a stack
-- trace (99's base provider calls logger:fatal = assert(false) in the exit callback) and showed the whole
-- vim.inspect of the result. Now: no error, one message with Claude's real reason and a hint.
local H = require("xynotest.helpers")

local test_tmp = vim.env.XYNO_TEST_TMP
local cache = vim.fn.stdpath("cache")
if
  not test_tmp
  or test_tmp == ""
  or not vim.startswith(vim.fs.normalize(cache), vim.fs.normalize(vim.fs.dirname(test_tmp)) .. "/")
then
  H.skip_file("run through scripts/test.sh (stdpath('cache') must be a temp dir)")
end

local notified
local function run_failing(script)
  local dir = H.tmpdir()
  vim.fn.writefile({ "#!/bin/sh", script }, dir .. "/claude")
  vim.uv.fs_chmod(dir .. "/claude", 493)
  local saved_path, saved_g = vim.env.PATH, vim.g.xynovim_99_sandbox
  vim.env.PATH = dir .. ":" .. vim.env.PATH
  vim.g.xynovim_99_sandbox = false -- the unsandboxed path shares the exit handling; no bwrap needed
  local restore_notify = vim.notify
  vim.notify = function(m)
    notified = (notified or "") .. tostring(m)
  end
  local errors = {}
  local old_schedule_err = vim.v.errmsg
  vim.v.errmsg = ""
  local _99 = require("99")
  local Guarded = _99.__get_state().provider_override
  local done
  local obs = {
    on_start = function() end,
    on_stdout = function() end,
    on_stderr = function() end,
    on_complete = function(status, text)
      done = { status, text }
    end,
  }
  local ctx = {
    model = "x",
    tmp_file = dir .. "/tmp",
    logger = require("99.logger.logger"):set_id(4242),
    is_cancelled = function()
      return false
    end,
    _set_process = function() end,
    cancel = function() end,
  }
  vim.cmd("enew!")
  local ok, err = pcall(Guarded.make_request, Guarded, "q", ctx, obs)
  H.wait_for(function()
    return done ~= nil
  end, 15000, "the agent run never completed: " .. tostring(ok) .. " " .. tostring(err) .. " " .. vim.v.errmsg)
  vim.wait(300)
  vim.notify = restore_notify
  vim.env.PATH = saved_path
  vim.g.xynovim_99_sandbox = saved_g
  return ok, err, done, vim.v.errmsg
end

describe("a failed agent run", function()
  it("shows Claude's real reason and a hint, with no Lua error or stack trace", function()
    H.clear_messages()
    local ok, err, done, errmsg = run_failing("echo 'Not logged in · Please run /login'; exit 1")
    H.ok(ok, tostring(err))
    H.eq("failed", done[1])
    H.has(done[2], "Not logged in")
    H.has(notified, "Not logged in")
    H.has(done[2], "/login")
    H.has(done[2], "exited with code 1")
    H.no_match(done[2], "stack traceback")
    H.no_match(done[2], "vim%.inspect")
    H.no_match(H.messages(), "stack traceback")
    H.no_match(H.messages(), "fatal msg")
    H.no_match(errmsg, "fatal msg")
  end)

  it("huge output does not end up in the message", function()
    local _, _, done = run_failing("yes 'lots of agent output' | head -c 3000000; echo 'boom at the end' >&2; exit 2")
    H.eq("failed", done[1])
    H.has(done[2], "boom at the end")
    H.ok(#done[2] < 800, "message is " .. #done[2] .. " bytes")
  end)

  it("a blocked user namespace gets its own hint", function()
    local _, _, done = run_failing("echo 'bwrap: No permissions to create new namespace' >&2; exit 1")
    H.has(done[2], "namespaces")
  end)
end)
