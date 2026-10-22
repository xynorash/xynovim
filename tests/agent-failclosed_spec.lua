-- The 99 agent sandbox fails closed, on EVERY platform. This is the spec that
-- runs on Windows and macOS in the platforms workflow (bubblewrap exists only
-- on Linux, so there the answer must be "refused"); the plugin's own sandbox_spec
-- (Linux only) tests the bwrap command itself.
local H = require("xynotest.helpers")

local sandbox = require("xyno_sandbox")

local function with_g(name, value, fn)
  local old = vim.g[name]
  vim.g[name] = value
  local ok, err = pcall(fn)
  vim.g[name] = old
  assert(ok, err)
end

local function neutral(fn)
  with_g("xynovim_99_sandbox", nil, function()
    with_g("xynovim_99_allow_unsandboxed", nil, fn)
  end)
end

local native_backend = vim.fn.has("linux") == 1 and vim.fn.executable("bwrap") == 1

describe("agent_sandbox without a backend", function()
  it("loads and answers on this platform (" .. H.os .. ")", function()
    H.eq("function", type(sandbox.status))
    H.eq("function", type(sandbox.wrap))
  end)

  it("status() is bwrap only on Linux with bwrap, else refused", function()
    neutral(function()
      H.eq(native_backend and "bwrap" or "refused", sandbox.status().mode)
    end)
  end)

  it("a platform without a backend refuses and wrap() returns nil plus a reason", function()
    if native_backend then
      return skip("a bwrap backend exists here (the has('linux') = 0 case is in the plugin's sandbox_spec)")
    end
    neutral(function()
      local cmd = { "claude", "--dangerously-skip-permissions" }
      local got, reason = sandbox.wrap(cmd, vim.uv.cwd(), vim.uv.cwd())
      H.is_nil(got)
      H.ok(type(reason) == "string" and reason ~= "", "a reason comes with the refusal")
      if H.os ~= "linux" then
        H.has(reason, "Linux")
      end
    end)
  end)

  it("only the two explicit booleans lead to an unsandboxed run", function()
    local cmd = { "claude" }
    for _, v in ipairs({ 0, 1, "false", "true" }) do
      with_g("xynovim_99_sandbox", v, function()
        with_g("xynovim_99_allow_unsandboxed", v, function()
          H.eq(native_backend and "bwrap" or "refused", sandbox.status().mode, vim.inspect(v))
        end)
      end)
    end
    with_g("xynovim_99_sandbox", false, function()
      H.ok(sandbox.wrap(cmd, vim.uv.cwd(), vim.uv.cwd()) == cmd, "sandbox = false returns the command")
      H.eq("unsandboxed", sandbox.status().mode)
    end)
    if not native_backend then
      with_g("xynovim_99_sandbox", nil, function()
        with_g("xynovim_99_allow_unsandboxed", true, function()
          H.ok(sandbox.wrap(cmd, vim.uv.cwd(), vim.uv.cwd()) == cmd, "allow_unsandboxed returns the command")
          H.eq("allow_unsandboxed", sandbox.status().via)
        end)
      end)
    end
  end)
end)

describe("the 99 provider", function()
  it("is guarded: make_request refuses where no sandbox exists", function()
    local ok, _99 = pcall(require, "99")
    if not ok then
      return skip("99 is not installed (run the bootstrap)")
    end
    if native_backend then
      return skip("a bwrap backend exists here (the refusal is tested in agent-99-guard_spec)")
    end
    local lazy = require("lazy")
    lazy.load({ plugins = { "99" } })
    local Guarded = _99.__get_state().provider_override
    neutral(function()
      local notes, done = {}, {}
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        notes[#notes + 1] = { msg, level }
      end
      local spawned = false
      local orig_system = vim.system
      vim.system = function(...)
        spawned = true
        return orig_system(...)
      end
      local ok2, err = pcall(function()
        Guarded:make_request("q", { cancel = function() end }, {
          on_start = function() end,
          on_stdout = function() end,
          on_stderr = function() end,
          on_complete = function(status, text)
            done[#done + 1] = { status, text }
          end,
        })
      end)
      vim.notify, vim.system = orig_notify, orig_system
      assert(ok2, err)
      H.eq(false, spawned, "nothing was spawned")
      H.eq(1, #done)
      H.eq("failed", done[1][1])
      H.has(done[1][2], "xynovim_99_allow_unsandboxed")
      H.eq(vim.log.levels.ERROR, notes[1][2])
    end)
  end)
end)
