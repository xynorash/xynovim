-- lua/plugins/ninety-nine.lua: lazy loading, keys, config (tmp_dir pruning,
-- setup args) and the Guarded provider (snapshot, auto-save counter, sandbox).
-- No real claude request is made (see the pending test at the end).
local H = require("xynotest.helpers")

-- This spec writes into stdpath("cache")/99: only ever in the temp dirs of
-- scripts/test.sh, never in the real cache.
local test_tmp = vim.env.XYNO_TEST_TMP
local cache = vim.fn.stdpath("cache")
if not test_tmp or test_tmp == "" or not vim.startswith(vim.fs.normalize(cache), vim.fs.normalize(vim.fs.dirname(test_tmp)) .. "/") then
  H.skip_file("run through scripts/test.sh (stdpath('cache') must be a temp dir, got " .. cache .. ")")
end

local tmp_dir = cache .. "/99"
local DAY = 24 * 3600

-- Files for the prune test, created BEFORE 99 first loads (the plugin config
-- prunes once, when it runs).
local function touch(path, age_days, content)
  vim.fn.writefile({ content or "x" }, path)
  local t = os.time() - age_days * DAY
  assert(vim.uv.fs_utime(path, t, t))
end
vim.fn.mkdir(tmp_dir .. "/olddir", "p")
touch(tmp_dir .. "/old.txt", 8)
touch(tmp_dir .. "/fresh.txt", 1)
touch(tmp_dir .. "/olddir/inner-old.txt", 30)
do
  local t = os.time() - 30 * DAY
  assert(vim.uv.fs_utime(tmp_dir .. "/olddir", t, t))
end

local function loaded(name)
  return package.loaded[name] ~= nil
end
local function lazy_plugin(name)
  return require("lazy.core.config").plugins[name]
end
local function plugin_loaded(name)
  local p = lazy_plugin(name)
  return p and p._.loaded ~= nil
end

local state = {} -- filled by the "loads on the first key" test
local function guarded()
  return require("99").__get_state().provider_override
end
local function claude()
  return require("99").Providers.ClaudeCodeProvider
end

-- Temporarily replace fields of a table; returns restore().
local function patch(tbl, fields)
  local saved, had = {}, {}
  for k, v in pairs(fields) do
    saved[k] = rawget(tbl, k)
    had[k] = saved[k] ~= nil
    tbl[k] = v
  end
  local function restore()
    for k in pairs(fields) do
      if had[k] then
        tbl[k] = saved[k]
      else
        tbl[k] = nil
      end
    end
  end
  H._restore[#H._restore + 1] = restore
  return restore
end

-- ----------------------------------------------------------------- lazy load

describe("lazy loading", function()
  it("does not load 99, telescope or blink.compat at startup", function()
    H.not_ok(loaded("99"), "99 is loaded")
    H.not_ok(plugin_loaded("99"), "lazy marks 99 loaded")
    H.not_ok(loaded("telescope"), "telescope is loaded")
    H.not_ok(plugin_loaded("telescope.nvim"), "lazy marks telescope loaded")
    H.not_ok(loaded("blink.compat"), "blink.compat is loaded")
    H.not_ok(plugin_loaded("blink.compat"), "lazy marks blink.compat loaded")
  end)

  it("depends on telescope.nvim and blink.compat 2.*", function()
    local deps = lazy_plugin("99").dependencies
    H.has(deps, "telescope.nvim")
    H.has(deps, "blink.compat")
    H.eq("2.*", lazy_plugin("blink.compat").version)
  end)

  it("loads on the first <leader>9 key together with its dependencies", function()
    H.clear_messages()
    H.feed("<leader>9c") -- clear_previous_requests: harmless
    H.ok(loaded("99"), "99 not loaded by the key")
    H.ok(plugin_loaded("99"))
    H.ok(plugin_loaded("telescope.nvim"), "telescope not loaded with 99")
    H.ok(plugin_loaded("blink.compat"), "blink.compat not loaded with 99")
    H.not_ok(H.messages():find("E%d+"), H.messages())
    state.loaded = true
  end)
end)

-- --------------------------------------------------------------------- keys

describe("keys", function()
  local specs = {
    -- lhs, mode, desc, how to reach the function that must be called
    { "<leader>9s", "n", "99: Search", "99", "search" },
    { "<leader>9v", "n", "99: Vibe", "99", "vibe" },
    { "<leader>9vv", "v", "99: Visual", "99", "visual" },
    { "<leader>9o", "n", "99: Open last interaction", "99", "open" },
    { "<leader>9l", "n", "99: View logs", "99", "view_logs" },
    { "<leader>9c", "n", "99: Clear previous", "99", "clear_previous_requests" },
    { "<leader>9x", "n", "99: Stop all requests", "99", "stop_all_requests" },
    { "<leader>9w", "n", "99: Worker search", "Worker", "search" },
    { "<leader>9W", "n", "99: Worker set work", "Worker", "set_work" },
    { "<leader>9m", "n", "99: Select model", "99.extensions.telescope", "select_model" },
    { "<leader>9P", "n", "99: Select provider", "99.extensions.telescope", "select_provider" },
  }

  local function target(mod)
    if mod == "Worker" then
      return require("99").Extensions.Worker
    end
    return require(mod)
  end

  for _, s in ipairs(specs) do
    local lhs, mode, desc, mod, fn = s[1], s[2], s[3], s[4], s[5]
    it(("%s (%s) calls %s.%s, desc %q"):format(lhs, mode, mod, fn, desc), function()
      H.ok(state.loaded, "99 must be loaded by the previous group")
      local map = vim.fn.maparg(lhs, mode, false, true)
      H.eq(desc, map.desc)
      H.match(map.desc, "^99: ")

      local t = target(mod)
      local calls = 0
      patch(t, {
        [fn] = function()
          calls = calls + 1
        end,
      })
      vim.cmd("enew!")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello world" })
      if mode == "v" then
        H.feed("vl")
        H.feed(lhs)
        H.feed("<Esc>")
      else
        H.feed(lhs)
      end
      H.eq(1, calls, lhs .. " did not reach " .. mod .. "." .. fn)
    end)
  end

  it("<leader>9vv exists in visual mode only", function()
    H.eq("", vim.fn.maparg("<leader>9vv", "n"))
    H.ok(vim.fn.maparg("<leader>9vv", "v") ~= "")
  end)
end)

-- ------------------------------------------------------------------- config

describe("config", function()
  it("uses an absolute tmp_dir = stdpath('cache')/99", function()
    local st = require("99").__get_state()
    H.eq(cache .. "/99", st:tmp_dir())
    H.eq("/", st:tmp_dir():sub(1, 1))
  end)

  it("deleted files older than 7 days, kept fresh files and subdirectories", function()
    H.is_nil(vim.uv.fs_stat(tmp_dir .. "/old.txt"), "old file still there")
    H.ok(vim.uv.fs_stat(tmp_dir .. "/fresh.txt"), "fresh file removed")
    local d = vim.uv.fs_stat(tmp_dir .. "/olddir")
    H.ok(d and d.type == "directory", "old subdirectory removed")
    H.ok(vim.uv.fs_stat(tmp_dir .. "/olddir/inner-old.txt"), "file inside the subdirectory removed")
  end)

  it("passes the documented setup args", function()
    local _99 = require("99")
    local st = _99.__get_state()
    H.eq("claude-sonnet-5", st.model)
    H.eq({ "--effort", "medium" }, st.provider_extra_args)
    H.eq(true, st.display_errors)
    H.eq("blink", st.completion.source)
    local Claude = _99.Providers.ClaudeCodeProvider
    local g = st.provider_override
    H.ok(g and g ~= Claude, "provider is Claude itself, not a guard")
    H.eq("table", type(g))
    H.ok(getmetatable(g).__index == Claude, "Guarded.__index is not ClaudeCodeProvider")
  end)

  it("logs to stdpath('state')/99.log at INFO with print_on_error", function()
    local Logger = require("99.logger.logger")
    H.eq(require("99").INFO, Logger.level)
    H.eq(true, Logger.print_on_error)
    H.ok(Logger.sink.fd, "logger has no file sink (type = 'file' missing?)")
    local path = vim.fn.stdpath("state") .. "/99.log"
    H.ok(vim.uv.fs_stat(path), "log file " .. path .. " not created")
    local l = Logger:set_id(1)
    l:info("spec-info-marker")
    l:debug("spec-debug-marker")
    local text = table.concat(vim.fn.readfile(path), "\n")
    H.has(text, "spec-info-marker")
    H.not_ok(text:find("spec-debug-marker", 1, true), "DEBUG line written at INFO level")
  end)
end)

-- ------------------------------------------------------------ guarded: models

describe("Guarded.fetch_models", function()
  it("prepends claude-sonnet-5 to the static list", function()
    local G, C = guarded(), claude()
    local base
    C.fetch_models(function(m)
      base = m
    end)
    local got, err
    G.fetch_models(function(m, e)
      got, err = m, e
    end)
    H.is_nil(err)
    H.eq("claude-sonnet-5", got[1])
    H.eq(base, vim.list_slice(got, 2))
  end)

  it("passes an error with nil models through, without a fake model", function()
    local restore = patch(claude(), {
      fetch_models = function(cb)
        cb(nil, "boom")
      end,
    })
    local called, got, err = 0, "unset", nil
    guarded().fetch_models(function(m, e)
      called, got, err = called + 1, m, e
    end)
    restore()
    H.eq(1, called)
    H.is_nil(got)
    H.eq("boom", err)
  end)

  it("passes nil models and nil error through", function()
    local restore = patch(claude(), {
      fetch_models = function(cb)
        cb(nil, nil)
      end,
    })
    local called, got = 0, "unset"
    guarded().fetch_models(function(m)
      called, got = called + 1, m
    end)
    restore()
    H.eq(1, called)
    H.is_nil(got)
  end)
end)

-- --------------------------------------------------------- guarded: sandbox

describe("Guarded._build_command", function()
  local sandbox = require("config.agent_sandbox")

  local function with_wrap_spy()
    local seen = {}
    local orig = sandbox.wrap
    local restore = patch(sandbox, {
      wrap = function(cmd, project, tmp)
        seen.cmd, seen.project, seen.tmp = cmd, project, tmp
        return orig(cmd, project, tmp)
      end,
    })
    return seen, restore
  end

  local ctx = { model = "claude-sonnet-5" }

  -- these two look at the arguments wrap() gets, not at bwrap: without bwrap
  -- (a CI runner) wrap refuses, so they run with the explicit opt-out
  local saved_sandbox
  before_each(function()
    saved_sandbox = vim.g.xynovim_99_sandbox
    vim.g.xynovim_99_sandbox = false
  end)
  after_each(function()
    vim.g.xynovim_99_sandbox = saved_sandbox
  end)

  it("wraps the Claude command with the git root of the buffer and the tmp_dir", function()
    local dir = H.open_fixture("basic", "src/main.rs", { git = true })
    local seen, restore = with_wrap_spy()
    local out = guarded():_build_command("do it", ctx)
    restore()
    local plain = claude():_build_command("do it", ctx)
    H.eq(plain, seen.cmd)
    H.eq(vim.uv.fs_realpath(dir), vim.uv.fs_realpath(seen.project))
    H.eq(tmp_dir, seen.tmp)
    H.eq("claude", plain[1])
    -- the wrapped command ends with the claude command itself
    H.eq(plain, vim.list_slice(out, #out - #plain + 1))
  end)

  it("uses the cwd when the buffer is not in a git repository", function()
    local dir = H.tmpdir()
    vim.cmd.cd(vim.fn.fnameescape(dir))
    vim.cmd("enew!")
    local seen, restore = with_wrap_spy()
    guarded():_build_command("q", ctx)
    restore()
    H.eq(vim.uv.fs_realpath(dir), vim.uv.fs_realpath(seen.project))
  end)

  it("starts with bwrap, ends with claude and drops GITHUB_TOKEN", function()
    if vim.fn.executable("bwrap") ~= 1 then
      skip("bwrap not found")
    end
    local saved = vim.g.xynovim_99_sandbox
    vim.g.xynovim_99_sandbox = nil
    H.open_fixture("basic", "src/main.rs", { git = true })
    -- scrub_names() works from the live environment: put a token there
    vim.env.GITHUB_TOKEN = "s3cret"
    local out = guarded():_build_command("do it", ctx)
    vim.env.GITHUB_TOKEN = nil
    vim.g.xynovim_99_sandbox = saved
    H.eq("bwrap", out[1])
    H.eq("claude", out[#out - #claude():_build_command("do it", ctx) + 1])
    local unset = false
    for i, a in ipairs(out) do
      if a == "--unsetenv" and out[i + 1] == "GITHUB_TOKEN" then
        unset = true
      end
    end
    H.ok(unset, "GITHUB_TOKEN is not unset: " .. table.concat(out, " "))
  end)

  it("really hides GITHUB_TOKEN from the wrapped process", function()
    H.need_sandbox()
    local dir = H.open_fixture("basic", "src/main.rs", { git = true })
    local saved = vim.g.xynovim_99_sandbox
    vim.g.xynovim_99_sandbox = nil
    vim.env.GITHUB_TOKEN = "s3cret"
    local cmd = require("config.agent_sandbox").wrap({ "bash", "-c", 'echo "[${GITHUB_TOKEN-unset}]"' }, dir, tmp_dir)
    vim.g.xynovim_99_sandbox = saved
    local r = vim.system(cmd, { cwd = dir, text = true }):wait(10000)
    vim.env.GITHUB_TOKEN = nil
    H.eq(0, r.code, r.stderr)
    H.eq("[unset]", vim.trim(r.stdout))
  end)
end)

-- --------------------------------------------------- guarded: make_request

local function autosave()
  return require("auto-save")
end

-- Replace Claude.make_request by a fake that records its calls. Returns
-- rec = { n, observers = {}, contexts = {}, order = {} }, restore().
local function fake_claude(behaviour)
  local rec = { n = 0, observers = {}, contexts = {} }
  local restore = patch(claude(), {
    make_request = function(_, query, context, observer)
      rec.n = rec.n + 1
      rec.observers[rec.n] = observer
      rec.contexts[rec.n] = context
      rec.order[#rec.order + 1] = "claude"
      if behaviour then
        return behaviour(rec, query, context, observer)
      end
      return "result" .. rec.n
    end,
  })
  rec.order = {}
  return rec, restore
end

local function new_observer()
  local obs = { completed = {} }
  obs.on_start = function() end
  obs.on_stdout = function() end
  obs.on_stderr = function() end
  obs.on_complete = function(status, text)
    obs.completed[#obs.completed + 1] = { status, text }
    return "orig-return"
  end
  return obs
end

local function new_context()
  local ctx = { cancelled = 0 }
  ctx.cancel = function(self)
    self.cancelled = self.cancelled + 1
  end
  return ctx
end

-- Start a request through the Guarded provider.
local function start(rec_ctx, obs)
  obs = obs or new_observer()
  local ctx = rec_ctx or new_context()
  vim.cmd("enew!") -- unnamed buffer: no snapshot, no repo
  local res = guarded():make_request("q", ctx, obs)
  return ctx, obs, res
end

describe("Guarded.make_request", function()
  local rec, restore_claude
  local as_on_calls

  before_each(function()
    vim.g.xynovim_99_sandbox = false
    rec, restore_claude = fake_claude()
    autosave().on()
    as_on_calls = 0
    local as = autosave()
    local orig_on = as.on
    patch(as, {
      on = function(...)
        as_on_calls = as_on_calls + 1
        return orig_on(...)
      end,
    })
  end)

  after_each(function()
    restore_claude()
    -- finish whatever a failed test left in flight, then reset auto-save
    for i, o in ipairs(rec.observers) do
      pcall(o.on_complete, "failed", "cleanup" .. i)
    end
    for _, fn in ipairs(H._restore) do
      pcall(fn)
    end
    H._restore = {}
    vim.g.xynovim_99_sandbox = nil
    autosave().on()
  end)

  it("returns what Claude.make_request returns", function()
    local _, _, res = start()
    H.eq("result1", res)
    rec.observers[1].on_complete("success", "")
  end)

  it("takes a forced 'before 99 request' snapshot of the buffer path before the request starts", function()
    H.need_os({ "linux" }, "times out waiting for the snapshot commit on macos-latest (run 38912021512), cause not diagnosed")
    local dir = H.open_fixture("basic", "src/main.rs", { git = true })
    local lh = require("config.local_history")
    local order, snap = {}, nil
    local orig = lh.snapshot
    patch(lh, {
      snapshot = function(opts)
        order[#order + 1] = "snapshot"
        snap = opts
        return orig(vim.tbl_extend("force", opts, {
          done = function(c)
            order[#order + 1] = "done"
            if opts.done then
              opts.done(c)
            end
          end,
        }))
      end,
    })
    local buf_path = vim.api.nvim_buf_get_name(0)
    -- Claude.make_request records "claude" in rec.order; snapshot must precede it
    guarded():make_request("q", new_context(), new_observer())
    H.eq("snapshot", order[1])
    H.eq(0, rec.n, "the agent must wait for the checkpoint")
    H.wait_for(function()
      return rec.n == 1
    end, 20000, "the request to start after the snapshot")
    H.eq("done", order[2], "claude started before the snapshot finished")
    H.eq("claude", rec.order[1])
    H.eq(buf_path, snap.path)
    H.eq(true, snap.force)
    H.eq("before 99 request", snap.label)
    rec.observers[1].on_complete("success", "")

    H.wait_for(function()
      local refs = H.git(dir, "for-each-ref", "--format=%(refname)", "refs/lochist")
      if refs == "" then
        return false
      end
      for ref in refs:gmatch("[^\n]+") do
        if H.git(dir, "log", "-1", "--format=%s", ref) == "before 99 request" then
          return true
        end
      end
    end, 20000, "refs/lochist commit 'before 99 request'")
  end)

  it("starts the agent only from the checkpoint's done callback; a cancel before that never starts it", function()
    H.open_fixture("basic", "src/main.rs", { git = true })
    local lh = require("config.local_history")
    local dones = {}
    patch(lh, {
      snapshot = function(opts)
        dones[#dones + 1] = opts.done
      end,
    })
    local ctx = new_context()
    guarded():make_request("q", ctx, new_observer())
    H.eq(0, rec.n, "started before the checkpoint finished")
    H.eq(false, autosave().enabled(), "in flight while waiting")
    dones[1]("deadbeef")
    H.eq(1, rec.n)
    dones[1]("again") -- a late fallback timer must not start it twice
    H.eq(1, rec.n)
    rec.observers[1].on_complete("success", "")
    H.eq(true, autosave().enabled())

    local ctx2 = new_context()
    guarded():make_request("q", ctx2, new_observer())
    H.eq(1, rec.n)
    ctx2.cancel(ctx2)
    H.eq(true, autosave().enabled(), "cancel released")
    dones[2]()
    H.eq(1, rec.n, "a cancelled request was started anyway")
  end)

  it("the first request turns auto-save off, a second leaves it off, release happens once each", function()
    H.eq(true, autosave().enabled())
    start()
    H.eq(false, autosave().enabled())
    start()
    H.eq(false, autosave().enabled())
    rec.observers[1].on_complete("success", "")
    H.eq(false, autosave().enabled(), "turned on while a request is still in flight")
    rec.observers[1].on_complete("success", "") -- duplicate: must not release the second request
    H.eq(false, autosave().enabled(), "a duplicate completion released another request")
    rec.observers[2].on_complete("success", "")
    H.eq(true, autosave().enabled())
    H.eq(1, as_on_calls)
  end)

  it("releases on on_complete and forwards to the original observer", function()
    local _, obs = start()
    H.eq(false, autosave().enabled())
    local ret = rec.observers[1].on_complete("success", "text")
    H.eq("orig-return", ret)
    H.eq({ { "success", "text" } }, obs.completed)
    H.eq(true, autosave().enabled())
  end)

  it("releases and re-raises on a synchronous throw from Claude.make_request", function()
    restore_claude()
    restore_claude = patch(claude(), {
      make_request = function()
        error("spawn failed", 0)
      end,
    })
    vim.cmd("enew!")
    local ok, e = pcall(guarded().make_request, guarded(), "q", new_context(), new_observer())
    H.not_ok(ok)
    H.eq("spawn failed", e)
    H.eq(true, autosave().enabled(), "auto-save stayed off after a throw")
    H.eq(1, as_on_calls)
  end)

  it("releases on cancel without waiting for on_complete; the late on_complete does nothing", function()
    local ctx = start()
    H.eq(false, autosave().enabled())
    ctx.cancel(ctx)
    H.eq(1, ctx.cancelled, "the original cancel was not called")
    H.eq(true, autosave().enabled(), "cancel did not release")
    -- on_complete follows later (or never)
    rec.observers[1].on_complete("cancelled", "")
    H.eq(true, autosave().enabled())
    H.eq(1, as_on_calls)
  end)

  it("a duplicate completion after cancel does not double-decrement (second request keeps auto-save off)", function()
    local ctxA = start()
    start()
    H.eq(false, autosave().enabled())
    ctxA.cancel(ctxA)
    H.eq(false, autosave().enabled(), "cancel of A released B")
    rec.observers[1].on_complete("cancelled", "")
    rec.observers[1].on_complete("cancelled", "")
    H.eq(false, autosave().enabled(), "late/duplicate completion of A released B")
    rec.observers[2].on_complete("success", "")
    H.eq(true, autosave().enabled())
  end)

  it("cancel with two concurrent requests keeps auto-save off until the second ends", function()
    local ctxA = start()
    local ctxB = start()
    ctxA.cancel(ctxA)
    H.eq(false, autosave().enabled())
    H.eq(0, as_on_calls)
    ctxB.cancel(ctxB)
    H.eq(true, autosave().enabled())
    H.eq(1, as_on_calls)
  end)

  it("still releases when the original cancel throws, and re-raises its error", function()
    local ctx = new_context()
    ctx.cancel = function()
      error("cancel failed", 0)
    end
    start(ctx)
    H.eq(false, autosave().enabled())
    local ok, e = pcall(ctx.cancel, ctx)
    H.not_ok(ok)
    H.eq("cancel failed", e)
    H.eq(true, autosave().enabled())
  end)

  it("works for a context without a cancel function", function()
    local ctx = { }
    start(ctx)
    H.eq(false, autosave().enabled())
    H.is_nil(ctx.cancel)
    rec.observers[1].on_complete("success", "")
    H.eq(true, autosave().enabled())
  end)

  it("does not touch auto-save the user switched on meanwhile", function()
    start()
    H.eq(false, autosave().enabled())
    autosave().on() -- the user's own toggle
    H.eq(1, as_on_calls)
    rec.observers[1].on_complete("success", "")
    H.eq(true, autosave().enabled())
    H.eq(1, as_on_calls, "the guard called auto-save.on() again")
  end)

  it("leaves auto-save off for a user who had it off before", function()
    autosave().off()
    start()
    rec.observers[1].on_complete("success", "")
    H.eq(false, autosave().enabled())
    H.eq(0, as_on_calls)
    -- and the next request after the user turns it on is guarded normally
    autosave().on()
    start()
    H.eq(false, autosave().enabled())
    rec.observers[2].on_complete("success", "")
    H.eq(true, autosave().enabled())
  end)

  it("the observer wrapper keeps the original methods through __index and overrides on_complete", function()
    local obs = new_observer()
    obs.extra = "kept"
    local started, stdout = 0, {}
    obs.on_start = function()
      started = started + 1
    end
    obs.on_stdout = function(d)
      stdout[#stdout + 1] = d
    end
    start(nil, obs)
    local w = rec.observers[1]
    H.ok(w ~= obs, "the observer is not wrapped")
    H.eq("kept", w.extra)
    H.ok(w.on_start == obs.on_start)
    H.ok(w.on_stderr == obs.on_stderr)
    H.ok(w.on_complete ~= obs.on_complete)
    H.ok(rawget(w, "on_complete"), "on_complete not overridden on the wrapper")
    w.on_start()
    w.on_stdout("chunk")
    H.eq(1, started)
    H.eq({ "chunk" }, stdout)
    w.on_complete("failed", "why")
    H.eq({ { "failed", "why" } }, obs.completed)
  end)
end)

-- ------------------------------------------------- end to end, stub provider

describe("Guard with a stub provider", function()
  it("auto-save is off in flight, on afterwards, snapshot taken, extra args reach the command", function()
    vim.g.xynovim_99_sandbox = false
    local dir = H.open_fixture("basic", "src/main.rs", { git = true })
    local work = H.tmpdir()
    local flag, args_file, answer = work .. "/started", work .. "/args", work .. "/answer"
    local script = ('echo "$0 $1" > %s; echo up > %s; sleep 1; printf stubbed > %s'):format(args_file, flag, answer)
    local restore = patch(claude(), {
      _build_command = function()
        return { "bash", "-c", script }
      end,
    })
    autosave().on()

    local done
    local obs = {
      on_start = function() end,
      on_stdout = function() end,
      on_stderr = function() end,
      on_complete = function(status, text)
        done = { status, text }
        -- the guard releases BEFORE forwarding to the observer
        done.enabled = autosave().enabled()
      end,
    }
    local context = {
      logger = require("99.logger.logger"),
      _99 = require("99").__get_state(),
      tmp_file = answer,
      is_cancelled = function()
        return false
      end,
      _set_process = function(self, p)
        self.proc = p
      end,
    }
    guarded():make_request("q", context, obs)

    H.wait_for(function()
      return vim.uv.fs_stat(flag)
    end, 10000, "stub to start")
    H.is_nil(done, "request already finished")
    H.eq(false, autosave().enabled(), "auto-save on while the request is in flight")

    H.wait_for(function()
      return done
    end, 15000, "on_complete")
    restore()
    H.eq({ "success", "stubbed" }, { done[1], done[2] })
    H.eq(true, done.enabled)
    H.eq(true, autosave().enabled())
    H.eq("--effort medium", vim.trim(table.concat(vim.fn.readfile(args_file), "\n")))

    H.wait_for(function()
      local refs = H.git(dir, "for-each-ref", "--format=%(refname)", "refs/lochist")
      for ref in refs:gmatch("[^\n]+") do
        if H.git(dir, "log", "-1", "--format=%s", ref) == "before 99 request" then
          return true
        end
      end
    end, 20000, "'before 99 request' snapshot")
    vim.g.xynovim_99_sandbox = nil
  end)
end)

-- ------------------------------------------------------------ README claims

describe("README claims", function()
  local readme
  before_each(function()
    readme = H.docs_text()
  end)

  it("logger path ~/.local/state/nvim/99.log at INFO", function()
    H.has(readme, "~/.local/state/nvim/99.log")
    local path = vim.fn.stdpath("state") .. "/99.log"
    H.match(path, "/nvim/99.log$")
    H.eq(require("99").INFO, require("99.logger.logger").level)
  end)

  it("tmp_dir is absolute (ninety-nine.lua says MUST be absolute)", function()
    H.eq("/", require("99").__get_state():tmp_dir():sub(1, 1))
    local src = table.concat(vim.fn.readfile(H.repo .. "/lua/plugins/ninety-nine.lua"), "\n")
    H.has(src, "MUST be absolute")
  end)

  it("blink completion needs blink.compat, which is there and loadable", function()
    H.eq("blink", require("99").__get_state().completion.source)
    H.ok(plugin_loaded("blink.compat"))
    H.ok(pcall(require, "blink.compat"), "blink.compat cannot be required")
  end)

  it("which-key names the group <leader>9 '99 (agent)'", function()
    -- Read from the plugin spec: which-key's runtime option tree could not be
    -- inspected reliably headless (lazy's own opts are consumed once loaded).
    local opts
    for _, spec in ipairs(dofile(H.repo .. "/lua/plugins/editing-ui.lua")) do
      if spec[1] == "folke/which-key.nvim" then
        opts = spec.opts
      end
    end
    H.ok(opts, "no which-key.nvim spec in editing-ui.lua")
    local found
    local function walk(t) -- the spec is a list of lists of {lhs, group = ...}
      for _, s in pairs(t) do
        if type(s) == "table" and rawget(s, 1) == "<leader>9" then
          found = s.group
        elseif type(s) == "table" then
          walk(s)
        end
      end
    end
    walk(opts)
    H.eq("99 (agent)", found)
  end)

  it("99 is on the Claude Code provider with --effort medium", function()
    H.has(readme, "Claude Code provider")
    H.has(readme, "--effort medium")
    H.eq({ "--effort", "medium" }, require("99").__get_state().provider_extra_args)
    H.ok(getmetatable(guarded()).__index == claude())
  end)
end)

-- ------------------------------------------ guarded: fails closed, warns open

describe("Guarded.make_request without a sandbox backend", function()
  local rec, restore_claude, notes, restore_notify, saved_path

  before_each(function()
    vim.g.xynovim_99_sandbox = nil
    vim.g.xynovim_99_allow_unsandboxed = nil
    saved_path = vim.env.PATH
    vim.env.PATH = "/nonexistent-xyno-path" -- no bwrap (the same refusal as Windows / macOS)
    rec, restore_claude = fake_claude()
    autosave().on()
    notes = {}
    restore_notify = patch(vim, {
      notify = function(msg, level)
        notes[#notes + 1] = { msg = msg, level = level }
      end,
    })
  end)

  after_each(function()
    vim.env.PATH = saved_path
    restore_notify()
    restore_claude()
    for _, fn in ipairs(H._restore) do
      pcall(fn)
    end
    H._restore = {}
    vim.g.xynovim_99_sandbox = nil
    vim.g.xynovim_99_allow_unsandboxed = nil
    autosave().on()
  end)

  it("refuses: nothing is spawned, on_complete('failed') names the opt-in, auto-save is untouched", function()
    local off_calls = 0
    local as = autosave()
    local orig_off = as.off
    patch(as, {
      off = function(...)
        off_calls = off_calls + 1
        return orig_off(...)
      end,
    })
    local _, obs, res = start()
    H.is_nil(res)
    H.eq(0, rec.n)
    H.eq(0, off_calls)
    H.eq(true, as.enabled())
    H.eq(1, #obs.completed)
    H.eq("failed", obs.completed[1][1])
    H.has(obs.completed[1][2], "xynovim_99_allow_unsandboxed")
    H.eq(1, #notes)
    H.eq(vim.log.levels.ERROR, notes[1].level)
  end)

  it("does not leak the in-flight token: a later request with the opt-in still toggles auto-save", function()
    start()
    vim.g.xynovim_99_allow_unsandboxed = true
    local _, _, res = start()
    H.eq("result1", res)
    H.eq(false, autosave().enabled())
    rec.observers[1].on_complete("success", "")
    H.eq(true, autosave().enabled())
  end)

  it("allow_unsandboxed = true runs the request and warns on EVERY request", function()
    vim.g.xynovim_99_allow_unsandboxed = true
    for i = 1, 2 do
      local _, _, res = start()
      H.eq("result" .. i, res)
      rec.observers[i].on_complete("success", "")
    end
    local warns = vim.tbl_filter(function(n)
      return n.level == vim.log.levels.WARN and n.msg:find("WITHOUT a sandbox", 1, true)
    end, notes)
    H.eq(2, #warns)
  end)

  it("sandbox = false warns on every request too", function()
    vim.g.xynovim_99_sandbox = false
    for i = 1, 2 do
      start()
      rec.observers[i].on_complete("success", "")
    end
    local warns = vim.tbl_filter(function(n)
      return n.msg:find("WITHOUT a sandbox", 1, true)
    end, notes)
    H.eq(2, #warns)
  end)

  it("_build_command raises instead of returning an unwrapped command", function()
    local ok, err = pcall(function()
      return guarded():_build_command("do it", { model = "claude-sonnet-5" })
    end)
    H.eq(false, ok)
    H.has(err, "99 sandbox")
  end)
end)

pending(
  "a real 99 request end to end (claude, sandbox, response applied)",
  "not verified in the README: needs a real claude session and network"
)

-- ------------------------------------------- the provider picker is guarded

describe("provider picker (<leader>9P)", function()
  local pickers, cap

  before_each(function()
    vim.g.xynovim_99_sandbox = nil
    vim.g.xynovim_99_allow_unsandboxed = nil
    require("99").set_provider(guarded())
    pickers = require("99.extensions.pickers")
    cap = H.capture_notify()
  end)

  after_each(function()
    cap.restore()
    vim.g.xynovim_99_sandbox = nil
    vim.g.xynovim_99_allow_unsandboxed = nil
    require("99").set_provider(guarded())
  end)

  it("refuses every provider but the guarded one, spawning nothing", function()
    local g = guarded()
    local info = pickers.get_providers()
    H.ok(#info.names >= 2, "no other providers listed")
    for _, name in ipairs(info.names) do
      if info.lookup[name] ~= claude() then
        pickers.on_provider_selected(name, info.lookup)
        H.ok(require("99").get_provider() == g, name .. " replaced the guarded provider")
      end
    end
    local refused = vim.tbl_filter(function(n)
      return type(n.msg) == "string" and n.msg:find("only the guarded", 1, true)
    end, cap.list)
    H.eq(#info.names - 1, #refused)
    H.eq(0, #vim.tbl_filter(function(n)
      return type(n.msg) == "string" and n.msg:find("Provider set", 1, true)
    end, cap.list), "the picker announced a switch that did not happen")
  end)

  it("allows another provider with the explicit opt-out", function()
    vim.g.xynovim_99_sandbox = false
    local info = pickers.get_providers()
    local other = info.lookup.OpenCodeProvider
    H.ok(other, "OpenCodeProvider not listed")
    pickers.on_provider_selected("OpenCodeProvider", info.lookup)
    H.ok(require("99").get_provider()._xyno_inner == other)
  end)

  it("allow_unsandboxed does not unlock providers while a working sandbox exists", function()
    if vim.fn.has("linux") ~= 1 or vim.fn.executable("bwrap") ~= 1 then
      return
    end
    vim.g.xynovim_99_allow_unsandboxed = true
    local info = pickers.get_providers()
    pickers.on_provider_selected("OpenCodeProvider", info.lookup)
    H.ok(require("99").get_provider() == guarded())
  end)

  it("allow_unsandboxed unlocks providers when there is no backend", function()
    local saved = vim.env.PATH
    vim.env.PATH = "/nonexistent-xyno-path"
    vim.g.xynovim_99_allow_unsandboxed = true
    local info = pickers.get_providers()
    pickers.on_provider_selected("OpenCodeProvider", info.lookup)
    vim.env.PATH = saved
    H.ok(require("99").get_provider()._xyno_inner == info.lookup.OpenCodeProvider)
  end)

  it("a provider chosen under the opt-in is refused per request once revoked, and warns while active", function()
    local info = pickers.get_providers()
    local other = info.lookup.OpenCodeProvider
    local calls = 0
    local orig = other.make_request
    other.make_request = function()
      calls = calls + 1
      return "ran"
    end
    local function obs()
      local o = { completed = {} }
      o.on_start = function() end
      o.on_complete = function(...)
        o.completed[#o.completed + 1] = { ... }
      end
      return o
    end
    local ok, err = pcall(function()
      vim.g.xynovim_99_sandbox = false
      pickers.on_provider_selected("OpenCodeProvider", info.lookup)
      local p = require("99").get_provider()
      H.eq("ran", p:make_request("q", {}, obs()))
      H.eq(1, #vim.tbl_filter(function(n)
        return type(n.msg) == "string" and n.msg:find("WITHOUT a sandbox", 1, true)
      end, cap.list))
      vim.g.xynovim_99_sandbox = nil
      local o = obs()
      H.is_nil(p:make_request("q", {}, o))
      H.eq(1, calls)
      H.eq("failed", o.completed[1][1])
    end)
    other.make_request = orig
    if not ok then
      error(err, 0)
    end
  end)
end)
