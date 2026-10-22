-- Local History through the xyno-history.nvim plugin (xynorash/xyno-history.nvim, lua/plugins/xyno-history.lua):
-- the module itself is specified in the plugin repository; this file covers what xynovim promises on top:
-- the plugin is loaded at startup with setup() called, :LocalHistory* and <leader>gH exist, the old
-- vim.g.xynovim_lochist_* caps are still honoured, snapshots made before the split (refs/lochist/*) are
-- browsable, and the integrations (auto-save, the 99 guard checkpoint in plugins/ninety-nine.lua).
-- Hermetic: temp repos and a private GIT_CONFIG_GLOBAL.
-- xyno-os: linux,macos (as the plugin's own specs: bash stubs, kill -0)
local H = require("xynotest.helpers")
local LH = require("xyno_history")

local REAL_GIT = vim.fn.exepath("git")
local uv = vim.uv
local MB = 1024 * 1024

-- LazyVim's keymaps/autocmds hang off VeryLazy, which never fires headless
-- (before any vim.notify shim: noice complains about a replaced vim.notify)
H.very_lazy()

local base = H.tmpdir()

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

write(base .. "/global_ignore", "*.globalignored\n")
write(base .. "/gitconfig", "[core]\n\texcludesFile = " .. base .. "/global_ignore\n")
do
  local saved = {}
  for _, k in ipairs({ "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM" }) do
    saved[k] = vim.env[k]
  end
  vim.env.GIT_CONFIG_GLOBAL = base .. "/gitconfig"
  vim.env.GIT_CONFIG_NOSYSTEM = "1"
  H._restore[#H._restore + 1] = function()
    for k, v in pairs(saved) do
      vim.env[k] = v
    end
  end
end

local function run(dir, args, stdin)
  local cmd = { REAL_GIT, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "core.quotepath=false" }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { cwd = dir, text = true, stdin = stdin }):wait(60000)
end
--- real git, trimmed stdout, raises on failure
local function G(dir, ...)
  local r = run(dir, { ... })
  if r.code ~= 0 then
    error(("git %s failed (%d): %s"):format(table.concat({ ... }, " "), r.code, r.stderr), 2)
  end
  return vim.trim(r.stdout)
end
local function tip(root, ref)
  local r = run(root, { "rev-parse", "-q", "--verify", ref })
  return r.code == 0 and vim.trim(r.stdout) or nil
end
local function names(root, rev)
  local out = {}
  for _, n in ipairs(vim.split(G(root, "ls-tree", "-r", "--name-only", "-z", rev), "\0", { plain = true })) do
    if n ~= "" then
      out[#out + 1] = n
    end
  end
  return out
end
local function blob(root, rev, rel)
  local r = run(root, { "show", rev .. ":" .. rel })
  return r.code == 0 and r.stdout or nil
end
local function subject(root, ref)
  return G(root, "log", "-1", "--format=%s", ref)
end

local function mkrepo(files)
  local dir = H.tmpdir()
  local root = uv.fs_realpath(dir) .. "/repo"
  vim.fn.mkdir(root, "p")
  G(root, "init", "-q", "-b", "main")
  for rel, text in pairs(files or { ["a.txt"] = "a\n" }) do
    write(root .. "/" .. rel, text)
  end
  G(root, "add", "-A")
  G(root, "commit", "-q", "-m", "init")
  return root
end

--- Synchronous snapshot: forced by default; returns the commit (nil when nothing changed or failed).
local function snap(root, opts)
  opts = vim.tbl_extend("force", { path = root, force = true }, opts or {})
  local called, commit = false, nil
  local user_done = opts.done
  opts.done = function(c)
    called, commit = true, c
    if user_done then
      user_done(c)
    end
  end
  LH.snapshot(opts)
  H.wait_for(function()
    return called
  end, 30000, "snapshot done callback")
  return commit
end

local function open_file(root, rel)
  vim.cmd.cd(vim.fn.fnameescape(root))
  return H.open(root .. "/" .. rel)
end

--- Commits on `ref` (oldest first) through fast-import, as the pre-split module wrote them.
local function chain(root, ref, items, file)
  file = file or "f.txt"
  local now = os.time()
  local s = {}
  for i, it in ipairs(items) do
    local msg = it.msg or ("snap" .. i)
    s[#s + 1] = ("commit %s\nmark :%d\ncommitter xynovim <lochist@xynovim> %d +0000\ndata %d\n%s\n"):format(
      ref, i, now - (it.days or 0) * 86400, #msg, msg
    )
    if i > 1 then
      s[#s + 1] = ("from :%d\n"):format(i - 1)
    end
    s[#s + 1] = ("M 100644 inline %s\ndata %d\n%s\n\n"):format(file, #it.content, it.content)
  end
  local r = run(root, { "fast-import", "--quiet" }, table.concat(s))
  H.eq(0, r.code, "fast-import: " .. (r.stderr or ""))
end

local orig_select, sel_calls = vim.ui.select, {}
local function mock_select(pick_fn)
  sel_calls = {}
  vim.ui.select = function(items, opts, cb)
    sel_calls[#sel_calls + 1] = { items = items, opts = opts }
    local idx = pick_fn(items, opts, #sel_calls)
    if idx then
      cb(items[idx], idx)
    else
      cb(nil)
    end
  end
end

local notes, orig_notify = {}, vim.notify
local function note_matching(pat)
  local out = {}
  for _, n in ipairs(notes) do
    if n.msg:find(pat, 1, true) then
      out[#out + 1] = n
    end
  end
  return out
end


before_each(function()
  vim.cmd("silent! %bwipeout!")
  vim.cmd("enew")
  vim.cmd.cd(vim.fn.fnameescape(base))
  vim.g.xynovim_lochist_max_bytes = nil
  vim.g.xynovim_lochist_max_total_bytes = nil
  notes = {}
  vim.notify = function(msg, level)
    if type(msg) == "string" and msg:find("has been overwritten by another plugin", 1, true) then
      return -- noice's late check (timing dependent, seen on macOS runners)
    end
    notes[#notes + 1] = { msg = msg, level = level }
  end
  pcall(function()
    require("auto-save").off()
  end)
end)

after_each(function()
  vim.notify = orig_notify
  vim.ui.select = orig_select
end)

describe("wiring", function()
  it("loads the plugin at startup (not lazy) and calls setup(): the autocmd group exists", function()
    local plugin = require("lazy.core.config").plugins["xyno-history.nvim"]
    H.ok(plugin, "plugin spec xyno-history.nvim")
    H.eq("xynorash/xyno-history.nvim", plugin[1])
    H.ok(plugin._.loaded, "loaded")
    local seen = {}
    for _, a in ipairs(vim.api.nvim_get_autocmds({ group = "xyno_history" })) do
      seen[a.event] = a.pattern
    end
    H.eq("AutoSaveWritePost", seen.User)
    H.ok(seen.BufWritePost, "BufWritePost")
    H.ok(seen.VimLeavePre, "VimLeavePre")
  end)

  it("defines :LocalHistory, :LocalHistoryPrune[!] and :LocalHistoryRestore with the documented arities", function()
    local cmds = vim.api.nvim_get_commands({})
    H.eq("0", cmds.LocalHistory.nargs)
    H.eq("?", cmds.LocalHistoryPrune.nargs)
    H.eq(true, cmds.LocalHistoryPrune.bang)
    H.eq("0", cmds.LocalHistoryRestore.nargs)
  end)

  it("maps <leader>gH to :LocalHistory", function()
    local m = vim.fn.maparg(vim.g.mapleader .. "gH", "n", false, true)
    H.eq("<cmd>localhistory<cr>", (m.rhs or ""):lower())
    H.eq("Local history (file)", m.desc)
  end)

  it("a :write of a buffer takes a snapshot on refs/lochist/<branch> (BufWritePost)", function()
    local root = mkrepo()
    open_file(root, "a.txt")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "saved" })
    vim.cmd.write()
    local ref = "refs/lochist/main"
    H.wait_for(function()
      return tip(root, ref)
    end, 15000, "snapshot after :write")
    H.eq("saved\n", blob(root, ref, "a.txt"))
    H.eq("autosave", subject(root, ref))
  end)

  it("snapshots made before the plugin split (refs/lochist/*, author xynovim) are listed by :LocalHistory", function()
    local root = mkrepo({ ["f.txt"] = "now\n" })
    chain(root, "refs/lochist/main", { { days = 2, content = "old one\n" }, { days = 1, content = "old two\n" } })
    open_file(root, "f.txt")
    mock_select(function()
      return nil
    end)
    vim.cmd("LocalHistory")
    H.wait_for(function()
      return #sel_calls == 1
    end, 15000, "the picker opened")
    H.eq(2, #sel_calls[1].items, "both pre-split snapshots offered")
  end)
end)

describe("the old vim.g caps still apply (mapped onto max_bytes and max_total_bytes)", function()
  it("max_bytes and max_total_bytes follow vim.g.xynovim_lochist_* at run time and fall back to the plugin defaults", function()
    H.is_nil(LH.config.max_bytes)
    H.is_nil(LH.config.max_total_bytes)
    vim.g.xynovim_lochist_max_bytes = 123
    vim.g.xynovim_lochist_max_total_bytes = 456
    H.eq(123, LH.config.max_bytes)
    H.eq(456, LH.config.max_total_bytes)
    vim.g.xynovim_lochist_max_bytes = nil
    H.is_nil(LH.config.max_bytes)
  end)

  it("vim.g.xynovim_lochist_max_bytes leaves a big untracked file out of the snapshot, with one notice", function()
    vim.g.xynovim_lochist_max_bytes = MB
    local root = mkrepo()
    write(root .. "/big.bin", string.rep("x", 2 * MB))
    write(root .. "/small.txt", "s\n")
    local c = snap(root)
    H.eq({ "a.txt", "small.txt" }, names(root, c))
    H.eq(1, #note_matching("local history: skipping big.bin"))
  end)

  it("without the variable the plugin default (10 MB) applies; 0 disables the cap", function()
    local root = mkrepo()
    write(root .. "/big.bin", string.rep("x", 11 * MB))
    H.eq({ "a.txt" }, names(root, snap(root)), "11 MB over the 10 MB default")
    vim.g.xynovim_lochist_max_bytes = 0
    write(root .. "/a.txt", "again\n")
    H.has(names(root, snap(root)), "big.bin", "cap disabled by 0")
  end)

  it("vim.g.xynovim_lochist_max_total_bytes leaves the largest files out until the snapshot fits", function()
    vim.g.xynovim_lochist_max_bytes = 2 * MB
    vim.g.xynovim_lochist_max_total_bytes = 3 * MB
    local root = mkrepo()
    write(root .. "/m1.bin", string.rep("x", MB))
    write(root .. "/m2.bin", string.rep("y", MB))
    write(root .. "/m3.bin", string.rep("z", MB + MB / 2))
    write(root .. "/small.txt", "s\n")
    local c = snap(root)
    H.eq({ "a.txt", "m1.bin", "m2.bin", "small.txt" }, names(root, c), "the 1.5 MB file went")
    H.eq(1, #note_matching("local history: skipping m3.bin"))
  end)
end)

describe("integrations", function()
  it("User AutoSaveWritePost snapshots only when the buffer is no longer modified (a refused write leaves none)", function()
    local root = mkrepo()
    local buf = open_file(root, "a.txt")
    -- refused write (xyno-guard): still modified -> no snapshot
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
    H.eq(true, vim.bo[buf].modified)
    vim.api.nvim_exec_autocmds("User", { pattern = "AutoSaveWritePost", data = { saved_buffer = buf } })
    vim.wait(700)
    H.is_nil(tip(root, "refs/lochist/main"))
    -- written: snapshot (content of the disk file)
    write(root .. "/a.txt", "on disk\n")
    vim.cmd("silent! checktime")
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent! edit!")
    end)
    H.eq(false, vim.bo[buf].modified)
    vim.api.nvim_exec_autocmds("User", { pattern = "AutoSaveWritePost", data = { saved_buffer = buf } })
    H.wait_for(function() return tip(root, "refs/lochist/main") end, 15000, "snapshot")
    H.eq("on disk\n", blob(root, "refs/lochist/main", "a.txt"))
    -- no data / invalid buffer: no error
    H.ok(pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AutoSaveWritePost" }))
    H.ok(pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AutoSaveWritePost", data = { saved_buffer = 99999 } }))
  end)

  it("99 guard: a forced snapshot labelled 'before 99 request' is taken before every request, throttle or not", function()
    local ok = pcall(function()
      require("lazy").load({ plugins = { "99" } })
    end)
    local ok2, _99 = pcall(require, "99")
    if not (ok and ok2) then
      skip("the 99 plugin cannot be loaded here")
    end
    local providers = require("99.providers")
    local provider = _99.get_provider()
    H.ok(provider ~= providers.OpenCodeProvider, "the guarded provider is configured")
    local Claude = providers.ClaudeCodeProvider
    local orig = Claude.make_request
    local observers = {}
    Claude.make_request = function(_, _, _, obs)
      observers[#observers + 1] = obs
    end
    H._restore[#H._restore + 1] = function()
      Claude.make_request = orig
    end
    -- (this test is about the checkpoint, not the sandbox: without bwrap, e.g. on
    -- a CI runner, the guarded provider would refuse to start at all)
    local old_sandbox = vim.g.xynovim_99_sandbox
    vim.g.xynovim_99_sandbox = false
    H._restore[#H._restore + 1] = function()
      vim.g.xynovim_99_sandbox = old_sandbox
    end
    local root = mkrepo()
    open_file(root, "a.txt")
    H.ok(snap(root, { force = false }), "normal autosave first: the throttle window is open")
    for i = 1, 2 do
      write(root .. "/a.txt", "request " .. i .. "\n")
      local before = tip(root, "refs/lochist/main")
      provider:make_request("prompt", {}, { on_complete = function() end })
      H.eq(i - 1, #observers, "the agent must not start before its checkpoint")
      H.wait_for(function()
        return tip(root, "refs/lochist/main") ~= before
      end, 15000, "labelled snapshot " .. i)
      H.wait_for(function()
        return #observers == i
      end, 15000, "the real provider got the request, after the snapshot")
      H.eq("before 99 request", subject(root, "refs/lochist/main"))
      H.eq("request " .. i .. "\n", blob(root, "refs/lochist/main", "a.txt"))
      observers[i].on_complete()
    end
    pcall(function()
      require("auto-save").off()
    end)
  end)
end)

