-- auto-save (lua/plugins/auto-save.lua) and the disk guard (lua/config/disk_guard.lua).
-- All files live in temp dirs; "dependency" paths are faked with CARGO_HOME /
-- RUSTUP_HOME pointing into one. Needs rust-analyzer only for the multi-file
-- rename test (skipped with a message otherwise).
local H = require("xynotest.helpers")
local dg = require("config.disk_guard")

-- --------------------------------------------------------------- local utils

local function read(path)
  local f = assert(io.open(path, "rb"))
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

local mtime_n = 0
--- Change a file on disk "behind the buffer's back": new content and an mtime
--- that differs from every earlier one (no reliance on clock granularity).
local function external_write(path, text)
  write(path, text)
  mtime_n = mtime_n + 7
  local t = os.time() + 100 + mtime_n
  assert(vim.uv.fs_utime(path, t, t))
end

local function stamp_of(path)
  local st = assert(vim.uv.fs_stat(path))
  return ("%d.%09d"):format(st.mtime.sec, st.mtime.nsec)
end

--- A temp file, opened in the current window. Returns path, bufnr.
local function open_file(text, name)
  local dir = H.tmpdir()
  local path = dir .. "/" .. (name or "f.txt")
  write(path, text or "one\ntwo\n")
  return path, H.open(path)
end

local function set_lines(buf, lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

local env_undo = {}
local function env(name, value)
  local old = vim.env[name]
  vim.env[name] = value
  env_undo[#env_undo + 1] = function()
    vim.env[name] = old
  end
end

local as = function()
  return require("auto-save")
end

--- WARN messages captured so far, as plain strings.
local function warnings(cap)
  local out = {}
  for _, n in ipairs(cap.list) do
    if n.level == vim.log.levels.WARN then
      out[#out + 1] = n.msg
    end
  end
  return out
end

--- A language server that only records what it is sent. `save` is its
--- textDocumentSync.save capability. Returns the notification log.
local function fake_lsp(buf, name, save)
  local log = {}
  local cmd = function()
    local closing = false
    return {
      request = function(method, _, cb)
        if method == "initialize" then
          cb(nil, { capabilities = { textDocumentSync = { openClose = true, change = 1, save = save } } })
        elseif method == "shutdown" then
          cb(nil, nil)
        end
        return true, 1
      end,
      notify = function(method, params)
        log[#log + 1] = { method = method, params = params }
        return true
      end,
      is_closing = function()
        return closing
      end,
      terminate = function()
        closing = true
      end,
    }
  end
  local id = vim.lsp.start({ name = name, cmd = cmd, root_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(buf)) }, {
    bufnr = buf,
  })
  H.wait_for(function()
    local c = vim.lsp.get_client_by_id(id)
    return c and c.initialized
  end, 5000, "fake LSP " .. name)
  return log, vim.lsp.get_client_by_id(id)
end

local function count(log, method)
  local n = 0
  for _, e in ipairs(log) do
    if e.method == method then
      n = n + 1
    end
  end
  return n
end

--- Count BufWritePost events for `buf`; returns fn giving the count.
local function count_bufwritepost(buf)
  local n = 0
  local g = vim.api.nvim_create_augroup("spec_bwp_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = g,
    buffer = buf,
    callback = function()
      n = n + 1
    end,
  })
  return function()
    return n
  end
end

-- Plugin loaded once; every test starts with auto-save off (tests that need it
-- switch it on) so a debounce timer cannot fire in the middle of a unit test.
require("lazy").load({ plugins = { "auto-save.nvim" } })

describe("auto-save and disk guard", function()
  before_each(function()
    as().off()
  end)
  after_each(function()
    as().off()
    for i = #env_undo, 1, -1 do
      env_undo[i]()
    end
    env_undo = {}
    pcall(function()
      for _, c in ipairs(vim.lsp.get_clients()) do
        c:stop(true)
      end
    end)
    vim.cmd("silent! %bwipeout!")
  end)

  -- 19 runs first: rust-analyzer does not attach in a process whose earlier
  -- tests stopped every LSP client (after_each below)
  -- ------------------------------------------------------------- 19: rename
  describe("multi-file rename (needs rust-analyzer)", function()
    it("19 leaves no modified buffers and everything on disk", function()
      H.need_rust()
      local dir = H.fixture("workspace", { git = true })
      vim.cmd.cd(vim.fn.fnameescape(dir))
      local main = dir .. "/app/src/main.rs"
      local lib = dir .. "/core/src/lib.rs"
      local bmain = H.open(main)
      local blib = H.open(lib)
      H.wait_lsp("rust-analyzer", blib)
      H.wait_lsp("rust-analyzer", bmain)
      -- auto-save stays off: it is save_all (after the workspace edit) that must write
      vim.api.nvim_set_current_buf(blib)
      local row
      for i, l in ipairs(vim.api.nvim_buf_get_lines(blib, 0, -1, false)) do
        if l:find("pub fn mode", 1, true) then
          row = i
          break
        end
      end
      vim.api.nvim_win_set_cursor(0, { row, 11 })
      -- rust-analyzer answers renames with an error until it has loaded the
      -- workspace: retry until the other crate's file changed on disk
      H.wait_for(function()
        if read(main):find("mode_renamed", 1, true) then
          return true
        end
        vim.lsp.buf.rename("mode_renamed", { bufnr = blib })
        vim.wait(4000, function()
          return read(main):find("mode_renamed", 1, true) ~= nil
        end, 100)
        return read(main):find("mode_renamed", 1, true) ~= nil
      end, 120000, "the rename to reach app/src/main.rs on disk")
      H.wait_for(function()
        return read(lib):find("mode_renamed", 1, true)
      end, 10000, "core/src/lib.rs on disk")
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
          H.not_ok(vim.bo[b].modified, "buffer " .. vim.api.nvim_buf_get_name(b) .. " is still modified")
        end
      end
    end)
  end)

  -- ------------------------------------------------------------- 1, 2: setup
  describe("configuration", function()
    it("1 lazy-loads on InsertLeave/TextChanged/TextChangedI and sets up enabled, noautocmd, 1000ms, can_save", function()
      local spec = dofile(H.repo .. "/lua/plugins/auto-save.lua")
      H.eq("okuuva/auto-save.nvim", spec[1])
      H.eq({ "InsertLeave", "TextChanged", "TextChangedI" }, spec.event)
      local o = require("auto-save.config").opts
      H.eq(true, o.enabled)
      H.eq(true, o.noautocmd)
      H.eq(1000, o.debounce_delay)
      H.ok(o.condition == dg.can_save, "condition is disk_guard.can_save")
    end)

    it("2 has the documented trigger events", function()
      H.eq({
        immediate_save = { "BufLeave", "FocusLost", "QuitPre", "VimSuspend" },
        defer_save = { "InsertLeave", "TextChanged", "TextChangedI" },
        cancel_deferred_save = { "InsertEnter" },
      }, require("auto-save.config").opts.trigger_events)
    end)

    it("2 registers those events as autocmds when on", function()
      as().on()
      local seen = {}
      for _, a in ipairs(vim.api.nvim_get_autocmds({ group = "AutoSave" })) do
        seen[a.event] = true
      end
      for _, e in ipairs({ "BufLeave", "FocusLost", "QuitPre", "VimSuspend", "InsertLeave", "TextChanged", "TextChangedI", "InsertEnter" }) do
        H.ok(seen[e], "autocmd for " .. e)
      end
    end)
  end)

  -- ------------------------------------------------------- 3, 4: autosaving
  describe("autosave", function()
    it("3 writes about a second after a text change", function()
      local path, buf = open_file("one\n")
      as().on()
      set_lines(buf, { "changed" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      vim.wait(300)
      H.eq("one\n", read(path), "not saved before the debounce delay")
      H.wait_for(function()
        return read(path) == "changed\n"
      end, 4000, "autosave of the text change")
      H.not_ok(vim.bo[buf].modified)
    end)

    it("3 writes while still typing in insert mode (TextChangedI), in a real nvim", function()
      H.need_tmux()
      -- headless -S never returns to the main loop, so typed keys are not
      -- consumed in-process: type into a real (tmux) nvim with this config
      local dir = H.tmpdir()
      local path = dir .. "/typed.txt"
      write(path, "one\n")
      local function pane()
        return H.tmux({ "capture-pane", "-p", "-t", "t" }, "typing").stdout or ""
      end
      local r = H.tmux({ "new-session", "-d", "-s", "t", "-x", "120", "-y", "30", "-c", dir, "nvim " .. path }, "typing")
      H.eq(0, r.code, r.stderr)
      H.wait_for(function()
        return pane():find("one", 1, true)
      end, 60000, "nvim to show the file")
      vim.wait(1500) -- let VeryLazy finish
      H.tmux({ "send-keys", "-t", "t", "A", "typed" }, "typing")
      H.wait_for(function()
        return pane():find("onetyped", 1, true)
      end, 5000, "typed text on screen")
      H.eq("one\n", read(path), "nothing saved right away")
      H.wait_for(function()
        return read(path) == "onetyped\n"
      end, 6000, "autosave while still in insert mode")
      -- still in insert mode: another key is inserted (not run as a normal command)
      H.tmux({ "send-keys", "-t", "t", "Z" }, "typing")
      H.wait_for(function()
        return read(path) == "onetypedZ\n"
      end, 6000, "second autosave, still typing")
    end)

    it("3 does not write when nothing changed and when auto-save is off", function()
      local path, buf = open_file("one\n")
      set_lines(buf, { "off" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      vim.wait(1500)
      H.eq("one\n", read(path))
      H.ok(vim.bo[buf].modified)
    end)

    describe("format-on-save", function()
      local ugly = "local   x=1  local y   = {1,2,   3}"

      it("4 an autosave does not format, :w does not format, <leader>cf does", function()
        H.eq(false, vim.g.autoformat)
        local path, buf = open_file(ugly .. "\n", "fmt.lua")
        if not vim.iter(require("conform").list_formatters(buf)):any(function(f)
          return f.available
        end) then
          H.skip_file("no conform formatter available for lua (stylua)")
        end

        as().on()
        set_lines(buf, { ugly .. " -- a" })
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
        H.wait_for(function()
          return read(path) == ugly .. " -- a\n"
        end, 4000, "autosave of unformatted text")
        as().off()

        set_lines(buf, { ugly .. " -- w" })
        vim.cmd("write")
        H.eq(ugly .. " -- w\n", read(path), ":w must not format")

        set_lines(buf, { ugly })
        -- the <leader>cf mapping itself (feeding keys would wait for which-key)
        local map = vim.fn.maparg(" cf", "n", false, true)
        H.ok(map.callback, "<leader>cf is mapped")
        map.callback()
        H.wait_for(function()
          return #vim.api.nvim_buf_get_lines(buf, 0, -1, false) > 1
        end, 10000, "<leader>cf to format the buffer")
        H.eq({ "local x = 1", "local y = { 1, 2, 3 }" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      end)
    end)

    it("21 never touches a dependency source, even when it was made modifiable and edited", function()
      local ch = H.tmpdir()
      env("CARGO_HOME", ch)
      local path = ch .. "/registry/src/index-1/crate-1.0.0/src/lib.rs"
      write(path, "pub fn a() {}\n")
      local buf = H.open(path)
      H.eq(false, vim.bo[buf].modifiable)
      vim.cmd("set modifiable")
      as().on()
      set_lines(buf, { "// edited" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      vim.api.nvim_exec_autocmds("BufLeave", { buffer = buf })
      vim.wait(2000)
      H.eq("pub fn a() {}\n", read(path))
      H.ok(vim.bo[buf].modified)
    end)
  end)

  -- ------------------------------------------------ 5, 6, 23: AutoSaveWritePost
  describe("User AutoSaveWritePost handler", function()
    it("5 re-sends didSave to attached clients that support it, only to those", function()
      local path, buf = open_file("one\n")
      local log_a = fake_lsp(buf, "fake-save", { includeText = false })
      local log_b = fake_lsp(buf, "fake-nosave", false)
      H.eq("user_autosave_didsave", vim.api.nvim_get_autocmds({ event = "User", pattern = "AutoSaveWritePost", group = "user_autosave_didsave" })[1].group_name)

      as().on()
      set_lines(buf, { "x" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      H.wait_for(function()
        return read(path) == "x\n" and count(log_a, "textDocument/didSave") == 1
      end, 4000, "didSave after autosave")
      H.eq(0, count(log_b, "textDocument/didSave"), "client without save support is not notified")
      local ev = vim.iter(log_a):find(function(e)
        return e.method == "textDocument/didSave"
      end)
      H.eq(vim.uri_from_bufnr(buf), ev.params.textDocument.uri)
    end)

    it("5 sends no didSave when the buffer is still modified after the write", function()
      local _, buf = open_file("one\n")
      local log = fake_lsp(buf, "fake-save", { includeText = false })
      set_lines(buf, { "dirty" })
      vim.api.nvim_exec_autocmds("User", { pattern = "AutoSaveWritePost", data = { saved_buffer = buf } })
      H.eq(0, count(log, "textDocument/didSave"))
      vim.cmd("noautocmd silent write")
      vim.api.nvim_exec_autocmds("User", { pattern = "AutoSaveWritePost", data = { saved_buffer = buf } })
      H.eq(1, count(log, "textDocument/didSave"))
    end)

    -- A BufWritePost autocmd whose callback "lives in" neotest's watcher.lua
    local function fake_watcher()
      local fn = load("return function() end", "@/fake/neotest/consumers/watch/watcher.lua")()
      return vim.api.nvim_create_autocmd("BufWritePost", { group = vim.api.nvim_create_augroup("spec_fake_watcher", { clear = true }), callback = fn })
    end
    after_each(function()
      pcall(vim.api.nvim_del_augroup_by_name, "spec_fake_watcher")
      package.loaded["neotest.consumers.watch.watcher"] = nil
    end)

    local function autosave_once(buf)
      local path = vim.api.nvim_buf_get_name(buf)
      as().on()
      set_lines(buf, { "auto " .. vim.uv.hrtime() })
      local want = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      H.wait_for(function()
        return read(path) == want
      end, 4000, "autosave")
      vim.wait(100)
      as().off()
    end

    it("6 re-emits BufWritePost for the buffer while a neotest watcher exists", function()
      local _, buf = open_file("one\n")
      local n = count_bufwritepost(buf)
      package.loaded["neotest.consumers.watch.watcher"] = {}
      fake_watcher()
      autosave_once(buf)
      H.eq(1, n())
      autosave_once(buf)
      H.eq(2, n())
    end)

    it("6/23 does NOT re-emit BufWritePost without a watcher autocmd or without the loaded module", function()
      local _, buf = open_file("one\n")
      local n = count_bufwritepost(buf)
      autosave_once(buf) -- nothing at all
      H.eq(0, n())
      fake_watcher() -- autocmd but module not loaded
      autosave_once(buf)
      H.eq(0, n())
      pcall(vim.api.nvim_del_augroup_by_name, "spec_fake_watcher")
      package.loaded["neotest.consumers.watch.watcher"] = {} -- module but no autocmd
      autosave_once(buf)
      H.eq(0, n())
    end)

    it("23 an autosave sends didSave although noautocmd suppresses BufWritePost", function()
      local _, buf = open_file("one\n")
      local log = fake_lsp(buf, "fake-save", { includeText = false })
      local n = count_bufwritepost(buf)
      autosave_once(buf)
      H.eq(0, n())
      H.eq(1, count(log, "textDocument/didSave"))
    end)
  end)

  -- ---------------------------------------------------------- 7, 8: dependency
  describe("is_dependency", function()
    it("7 recognises ~/.cargo/registry, ~/.cargo/git and ~/.rustup", function()
      local home = vim.uv.os_homedir()
      H.eq(true, dg.is_dependency(home .. "/.cargo/registry/src/index/x-1/src/lib.rs"))
      H.eq(true, dg.is_dependency(home .. "/.cargo/git/checkouts/x/abc/src/lib.rs"))
      H.eq(true, dg.is_dependency(home .. "/.rustup/toolchains/stable/lib/rustlib/src/rust/library/std/src/lib.rs"))
    end)

    it("7 does not match similar prefixes or project files", function()
      local home = vim.uv.os_homedir()
      H.eq(false, dg.is_dependency(home .. "/.cargo/registryx/a.rs"))
      H.eq(false, dg.is_dependency(home .. "/.cargo/gitx/a.rs"))
      H.eq(false, dg.is_dependency(home .. "/.rustupx/a.rs"))
      H.eq(false, dg.is_dependency(home .. "/.cargo/bin/a.rs"))
      H.eq(false, dg.is_dependency(home .. "/projects/foo/src/main.rs"))
      H.eq(false, dg.is_dependency("/tmp/.cargo/registry/a.rs"))
    end)

    it("7 honours $CARGO_HOME (registry, git) and $RUSTUP_HOME", function()
      local ch, rh = H.tmpdir(), H.tmpdir()
      H.eq(false, dg.is_dependency(ch .. "/registry/a.rs"))
      env("CARGO_HOME", ch .. "/") -- a trailing slash is tolerated
      env("RUSTUP_HOME", rh)
      H.eq(true, dg.is_dependency(ch .. "/registry/src/a.rs"))
      H.eq(true, dg.is_dependency(ch .. "/git/checkouts/a.rs"))
      H.eq(true, dg.is_dependency(rh .. "/toolchains/a.rs"))
      H.eq(false, dg.is_dependency(ch .. "/registryx/a.rs"))
      H.eq(false, dg.is_dependency(ch .. "/bin/a.rs"))
      H.eq(false, dg.is_dependency(rh .. "x/a.rs"))
    end)

    it("8 a dependency buffer is nomodifiable and readonly; :set modifiable allows editing; can_save stays false", function()
      local ch = H.tmpdir()
      env("CARGO_HOME", ch)
      local path = ch .. "/registry/src/index-1/c-1.0.0/src/lib.rs"
      write(path, "pub fn a() {}\n")
      local buf = H.open(path)
      H.eq(false, vim.bo[buf].modifiable)
      H.eq(true, vim.bo[buf].readonly)
      H.throws(function()
        set_lines(buf, { "nope" })
      end, "modifiable")
      vim.cmd("set modifiable")
      set_lines(buf, { "// hacked" })
      H.eq({ "// hacked" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      H.eq(false, dg.can_save(buf))
    end)

    it("8 a buffer outside the dependency roots stays modifiable", function()
      local _, buf = open_file("x\n")
      H.eq(true, vim.bo[buf].modifiable)
      H.eq(false, vim.bo[buf].readonly)
    end)
  end)

  -- ------------------------------------------------------ 9, 10, 11, 12: stamps
  describe("can_save", function()
    it("9 is true for non-file buffers (buftype set, or no name)", function()
      local scratch = vim.api.nvim_create_buf(false, true)
      H.eq(true, dg.can_save(scratch))
      local noname = vim.api.nvim_create_buf(true, false)
      H.eq(true, dg.can_save(noname))
      local named_nofile = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(named_nofile, H.tmpdir() .. "/virt")
      vim.bo[named_nofile].buftype = "nofile"
      H.eq(true, dg.can_save(named_nofile))
      H.is_nil(vim.b[named_nofile].xynovim_disk_stamp)
    end)

    it("9 records the mtime as sec.nsec on BufReadPost", function()
      local path, buf = open_file()
      local s = vim.b[buf].xynovim_disk_stamp
      H.match(s, "^%d+%.%d%d%d%d%d%d%d%d%d$")
      H.eq(stamp_of(path), s)
    end)

    it("9 re-records on BufWritePost", function()
      local path, buf = open_file()
      external_write(path, "other\n")
      H.not_ok(vim.b[buf].xynovim_disk_stamp == stamp_of(path))
      vim.cmd("silent write!")
      H.eq(stamp_of(path), vim.b[buf].xynovim_disk_stamp)
    end)

    it("9 re-records on BufFilePost", function()
      local path, buf = open_file()
      local other = vim.fs.dirname(path) .. "/g.txt"
      write(other, "g\n")
      vim.b[buf].xynovim_disk_stamp = nil
      vim.cmd("silent file " .. vim.fn.fnameescape(other))
      H.eq(stamp_of(other), vim.b[buf].xynovim_disk_stamp)
    end)

    it("9 re-records on FileChangedShellPost", function()
      local path, buf = open_file()
      vim.b[buf].xynovim_disk_stamp = nil
      vim.api.nvim_exec_autocmds("FileChangedShellPost", { buffer = buf })
      H.eq(stamp_of(path), vim.b[buf].xynovim_disk_stamp)
    end)

    it("10 with no stamp yet records one and returns true", function()
      local path, buf = open_file()
      vim.b[buf].xynovim_disk_stamp = nil
      H.eq(true, dg.can_save(buf))
      H.eq(stamp_of(path), vim.b[buf].xynovim_disk_stamp)
    end)

    it("10 an unchanged mtime returns true, silently", function()
      local _, buf = open_file()
      local cap = H.capture_notify()
      H.eq(true, dg.can_save(buf))
      H.eq(true, dg.can_save(buf))
      H.eq({}, cap.list)
      cap.restore()
    end)

    it("11 a change on disk after the stamp: false and one warning per mtime", function()
      local path, buf = open_file()
      local cap = H.capture_notify()
      external_write(path, "changed\n")
      local short = vim.fn.fnamemodify(path, ":~:.")
      local msg = short
        .. " changed on disk while this buffer has unsaved edits: auto-save is paused for it (:w! keeps the buffer, :e! takes the disk version)"
      H.eq(false, dg.can_save(buf))
      H.eq({ msg }, warnings(cap))
      H.eq(false, dg.can_save(buf))
      H.eq(false, dg.can_save(buf))
      H.eq({ msg }, warnings(cap), "not repeated for the same mtime")
      external_write(path, "changed again\n")
      H.eq(false, dg.can_save(buf))
      H.eq({ msg, msg }, warnings(cap), "a newer change warns again")
      cap.restore()
    end)

    it("11 becomes true again once the buffer was written (:w! keeps the buffer)", function()
      local path, buf = open_file()
      external_write(path, "disk\n")
      H.eq(false, dg.can_save(buf))
      set_lines(buf, { "mine" })
      vim.cmd("silent write!")
      H.eq("mine\n", read(path))
      H.eq(true, dg.can_save(buf))
    end)

    it("12 a deleted file: false and one warning", function()
      local path, buf = open_file()
      local cap = H.capture_notify()
      os.remove(path)
      local msg = vim.fn.fnamemodify(path, ":~:.") .. " no longer exists on disk: auto-save is paused for this buffer (:w to recreate it)"
      H.eq(false, dg.can_save(buf))
      H.eq(false, dg.can_save(buf))
      H.eq({ msg }, warnings(cap))
      cap.restore()
    end)

    it("12 autosave does not recreate a deleted file", function()
      local path, buf = open_file()
      local cap = H.capture_notify()
      os.remove(path)
      as().on()
      set_lines(buf, { "edit" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      vim.wait(1800)
      H.eq(nil, vim.uv.fs_stat(path))
      H.ok(vim.bo[buf].modified)
      H.eq(1, #vim.tbl_filter(function(m)
        return m:find("no longer exists on disk", 1, true)
      end, warnings(cap)))
      cap.restore()
    end)
  end)

  -- ---------------------------------------------------- 13, 14: the write guard
  describe("AutoSaveWritePre / Post", function()
    local function fire(pattern, buf)
      vim.api.nvim_exec_autocmds("User", { pattern = pattern, data = { saved_buffer = buf } })
    end

    it("13 Pre with can_save false switches buftype to nowrite (saved), Post restores it", function()
      local path, buf = open_file()
      local cap = H.capture_notify()
      external_write(path, "disk\n")
      fire("AutoSaveWritePre", buf)
      H.eq("nowrite", vim.bo[buf].buftype)
      H.eq("", vim.b[buf].xynovim_disk_buftype)
      set_lines(buf, { "mine" })
      vim.cmd("silent! write")
      H.eq("disk\n", read(path), "a nowrite buffer cannot be written")
      fire("AutoSaveWritePost", buf)
      H.eq("", vim.bo[buf].buftype)
      H.is_nil(vim.b[buf].xynovim_disk_buftype)
      cap.restore()
    end)

    it("13 Pre with can_save true leaves the buftype alone, Post records the stamp", function()
      local path, buf = open_file()
      fire("AutoSaveWritePre", buf)
      H.eq("", vim.bo[buf].buftype)
      H.is_nil(vim.b[buf].xynovim_disk_buftype)
      external_write(path, "now\n")
      fire("AutoSaveWritePost", buf)
      H.eq(stamp_of(path), vim.b[buf].xynovim_disk_stamp)
    end)

    it("13/14 a file changed inside the debounce window is not overwritten, no W12 prompt, buffer stays modified", function()
      local path, buf = open_file("one\n")
      local cap = H.capture_notify()
      H.clear_messages()
      as().on()
      set_lines(buf, { "mine" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf }) -- condition passes: timer starts
      external_write(path, "theirs\n") -- ... then the file changes before the write
      vim.wait(2000)
      H.eq("theirs\n", read(path))
      H.eq(true, vim.bo[buf].modified, "a refused write leaves modified=true")
      H.eq("", vim.bo[buf].buftype)
      H.is_nil(vim.b[buf].xynovim_disk_buftype)
      H.no_match(H.messages(), "Do you really want to write", true)
      H.eq({ "mine" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      cap.restore()
    end)

    it("14 handlers keyed on modified skip a refused write (no didSave, no BufWritePost re-emit)", function()
      local path, buf = open_file("one\n")
      local log = fake_lsp(buf, "fake-save", { includeText = false })
      local cap = H.capture_notify()
      local n = count_bufwritepost(buf)
      package.loaded["neotest.consumers.watch.watcher"] = {}
      vim.api.nvim_create_autocmd("BufWritePost", {
        group = vim.api.nvim_create_augroup("spec_fake_watcher", { clear = true }),
        callback = load("return function() end", "@/fake/neotest/consumers/watch/watcher.lua")(),
      })
      as().on()
      set_lines(buf, { "mine" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      external_write(path, "theirs\n")
      vim.wait(2000)
      H.eq(0, count(log, "textDocument/didSave"))
      H.eq(0, n())
      pcall(vim.api.nvim_del_augroup_by_name, "spec_fake_watcher")
      package.loaded["neotest.consumers.watch.watcher"] = nil
      cap.restore()
    end)
  end)

  -- ----------------------------------------------------- 15, 16: FileChangedShell
  describe("FileChangedShell", function()
    -- Observes (and neutralises, so nothing can prompt) what the guard decided.
    -- Registered after the guard's autocmd, so it runs after it.
    local function spy()
      local seen = {}
      vim.api.nvim_create_autocmd("FileChangedShell", {
        group = vim.api.nvim_create_augroup("spec_fcs_spy", { clear = true }),
        callback = function()
          seen[#seen + 1] = { reason = vim.v.fcs_reason, choice = vim.v.fcs_choice }
          vim.v.fcs_choice = ""
        end,
      })
      return seen
    end
    after_each(function()
      pcall(vim.api.nvim_del_augroup_by_name, "spec_fcs_spy")
    end)

    it("15 conflict (modified buffer, file changed): no prompt, choice '', one warning, edits kept", function()
      local path, buf = open_file()
      local seen = spy()
      local cap = H.capture_notify()
      set_lines(buf, { "unsaved" })
      external_write(path, "disk\n")
      vim.cmd("checktime")
      H.eq({ { reason = "conflict", choice = "" } }, seen)
      H.eq({
        vim.fn.fnamemodify(path, ":~:.") .. " changed on disk and the buffer has unsaved edits (:e! takes the disk version, :w! keeps the buffer)",
      }, warnings(cap))
      H.eq({ "unsaved" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      H.eq(false, dg.can_save(buf))
      H.eq(1, #warnings(cap), "can_save does not repeat the warning")
      cap.restore()
    end)

    it("15 deleted: no prompt, choice '', warning, buffer kept", function()
      local path, buf = open_file()
      local seen = spy()
      local cap = H.capture_notify()
      os.remove(path)
      vim.cmd("checktime")
      H.eq({ { reason = "deleted", choice = "" } }, seen)
      H.eq({ vim.fn.fnamemodify(path, ":~:.") .. " was deleted on disk (the buffer is kept)" }, warnings(cap))
      H.eq(true, vim.api.nvim_buf_is_loaded(buf))
      H.eq({ "one", "two" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      cap.restore()
    end)

    it("15 other reasons: 'ask' without autoread (with autoread nvim reloads without the event)", function()
      local path, buf = open_file()
      local seen = spy()
      local old = vim.o.autoread
      H._restore[#H._restore + 1] = function()
        vim.o.autoread = old
      end
      vim.o.autoread = true
      external_write(path, "disk1\n")
      vim.cmd("checktime")
      H.eq({}, seen, "autoread: reloaded natively, no event")
      H.eq({ "disk1" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.o.autoread = false
      external_write(path, "disk2\n")
      vim.cmd("checktime")
      H.eq(1, #seen)
      H.eq("ask", seen[1].choice)
      H.ok(seen[1].reason ~= "conflict" and seen[1].reason ~= "deleted")
      vim.o.autoread = old
    end)

    it("15 an unmodified buffer reloads after an external change and :checktime", function()
      local path, buf = open_file()
      external_write(path, "from disk\n")
      vim.cmd("checktime")
      H.wait_for(function()
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "from disk"
      end, 3000, "reload")
      H.not_ok(vim.bo[buf].modified)
      H.eq(stamp_of(path), vim.b[buf].xynovim_disk_stamp)
      H.eq(true, dg.can_save(buf))
    end)

    it("16 LazyVim's FocusGained :checktime (lazyvim_checktime) still exists", function()
      local acs = vim.api.nvim_get_autocmds({ group = "lazyvim_checktime", event = "FocusGained" })
      H.ok(#acs > 0, "FocusGained autocmd in lazyvim_checktime")
    end)
  end)

  -- ------------------------------------------------------- 17, 18, 20: save_all
  describe("save_all", function()
    it("17 writes modified file buffers with events; skips unmodified, dependency and externally changed ones", function()
      local ch = H.tmpdir()
      env("CARGO_HOME", ch)
      local dir = H.tmpdir()
      local pa, pb, pc, pd, pe = dir .. "/a.txt", dir .. "/b.txt", dir .. "/c.txt", dir .. "/d.txt", ch .. "/registry/src/x/lib.rs"
      write(pa, "a\n")
      write(pb, "b\n")
      write(pc, "c\n")
      write(pd, "d\n")
      write(pe, "e\n")
      local ba, _, bc, _, be = H.open(pa), H.open(pb), H.open(pc), H.open(pd), H.open(pe)
      local logs = fake_lsp(ba, "fake-save", { includeText = false })
      local npost = count_bufwritepost(ba)
      set_lines(ba, { "A" }) -- modified: written
      set_lines(bc, { "C" }) -- modified but changed on disk: skipped
      external_write(pc, "C-disk\n")
      vim.cmd("set modifiable") -- dependency buffer made editable on purpose
      set_lines(be, { "E" }) -- modified dependency: skipped
      -- bb, bd unmodified: untouched
      local mt = stamp_of(pb)
      dg.save_all()
      H.eq("A\n", read(pa))
      H.eq("b\n", read(pb))
      H.eq("C-disk\n", read(pc))
      H.eq("d\n", read(pd))
      H.eq("e\n", read(pe))
      H.eq(mt, stamp_of(pb))
      H.not_ok(vim.bo[ba].modified)
      H.ok(vim.bo[bc].modified)
      H.ok(vim.bo[be].modified)
      H.eq(1, npost(), "BufWritePost fired (write, not noautocmd)")
      H.eq(1, count(logs, "textDocument/didSave"), "didSave was sent")
    end)

    it("17 skips unloaded, non-file and nomodifiable buffers", function()
      local path, buf = open_file("x\n")
      local scratch = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "s" })
      set_lines(buf, { "X" })
      vim.bo[buf].modifiable = true
      local path2 = vim.fs.dirname(path) .. "/n.txt"
      write(path2, "n\n")
      local nb = H.open(path2)
      set_lines(nb, { "N" })
      vim.bo[nb].modifiable = false
      dg.save_all()
      H.eq("X\n", read(path))
      H.eq("n\n", read(path2))
    end)

    describe("wrapping apply_workspace_edit (18)", function()
      local orig_save_all
      before_each(function()
        orig_save_all = dg.save_all
        local calls = 0
        dg.save_all = function()
          calls = calls + 1
        end
        dg._calls = function()
          return calls
        end
      end)
      after_each(function()
        dg.save_all = orig_save_all
        dg._calls = nil
      end)

      -- the wrapper's captured original, via its upvalue
      local function orig_of(wrapper)
        local i = 1
        while true do
          local n, v = debug.getupvalue(wrapper, i)
          if not n then
            return nil
          end
          if n == "orig" then
            return v, i
          end
          i = i + 1
        end
      end

      local function attach_fake(name)
        local path, buf = open_file("x\n")
        fake_lsp(buf, name, false)
        return path, buf
      end

      it("18 wraps once after the first LspAttach, and stays wrapped once however many attach", function()
        attach_fake("fake-1")
        local w = vim.lsp.util.apply_workspace_edit
        local orig = orig_of(w)
        H.ok(orig, "wrapper found")
        H.ok(debug.getinfo(orig, "S").source:find("disk_guard.lua", 1, true) == nil, "original is not a wrapper")
        attach_fake("fake-2")
        vim.api.nvim_exec_autocmds("LspAttach", { buffer = vim.api.nvim_get_current_buf(), data = { client_id = 1 } })
        H.ok(vim.lsp.util.apply_workspace_edit == w, "not wrapped again")
        H.ok(debug.getinfo(orig_of(w), "S").source:find("disk_guard.lua", 1, true) == nil)
      end)

      it("18 a changes edit on another file schedules save_all", function()
        local path, buf = attach_fake("fake-1")
        local other = vim.uri_from_fname(vim.fs.dirname(path) .. "/other.txt")
        vim.lsp.util.apply_workspace_edit({ changes = { [other] = {} } }, "utf-16")
        H.eq(0, dg._calls(), "scheduled, not synchronous")
        H.wait_for(function()
          return dg._calls() == 1
        end, 2000, "save_all")
        H.ok(buf)
      end)

      it("18 a documentChanges edit on another file, and create/rename/delete kinds, schedule save_all", function()
        local path = attach_fake("fake-1")
        local dir = vim.fs.dirname(path)
        local other = vim.uri_from_fname(dir .. "/other.txt")
        vim.lsp.util.apply_workspace_edit({
          documentChanges = { { textDocument = { uri = other, version = vim.NIL }, edits = {} } },
        }, "utf-16")
        H.wait_for(function()
          return dg._calls() == 1
        end, 2000, "save_all after documentChanges")
        local created = dir .. "/new.txt"
        vim.lsp.util.apply_workspace_edit({ documentChanges = { { kind = "create", uri = vim.uri_from_fname(created) } } }, "utf-16")
        H.wait_for(function()
          return dg._calls() == 2
        end, 2000, "save_all after create")
        H.ok(vim.uv.fs_stat(created), "the create was applied")
        local renamed = dir .. "/renamed.txt"
        vim.lsp.util.apply_workspace_edit({
          documentChanges = { { kind = "rename", oldUri = vim.uri_from_fname(created), newUri = vim.uri_from_fname(renamed) } },
        }, "utf-16")
        H.wait_for(function()
          return dg._calls() == 3
        end, 2000, "save_all after rename")
        vim.lsp.util.apply_workspace_edit({ documentChanges = { { kind = "delete", uri = vim.uri_from_fname(renamed) } } }, "utf-16")
        H.wait_for(function()
          return dg._calls() == 4
        end, 2000, "save_all after delete")
      end)

      it("18 an edit confined to the current buffer does not schedule save_all", function()
        local _, buf = attach_fake("fake-1")
        local cur = vim.uri_from_bufnr(buf)
        vim.lsp.util.apply_workspace_edit({ changes = { [cur] = {} } }, "utf-16")
        vim.lsp.util.apply_workspace_edit({
          documentChanges = { { textDocument = { uri = cur, version = vim.NIL }, edits = {} } },
        }, "utf-16")
        vim.wait(300)
        H.eq(0, dg._calls())
      end)

      it("18 preserves the original's return value", function()
        attach_fake("fake-1")
        local w = vim.lsp.util.apply_workspace_edit
        local orig, idx = orig_of(w)
        debug.setupvalue(w, idx, function()
          return "sentinel"
        end)
        local ok, res = pcall(w, { changes = {} }, "utf-16")
        debug.setupvalue(w, idx, orig)
        H.ok(ok, tostring(res))
        H.eq("sentinel", res)
      end)
    end)

    it("20 buffers loaded before setup() are recorded by setup()", function()
      local path, buf = open_file()
      vim.b[buf].xynovim_disk_stamp = nil
      dg.setup()
      H.eq(stamp_of(path), vim.b[buf].xynovim_disk_stamp)
      -- and the events still work afterwards
      external_write(path, "z\n")
      vim.cmd("silent write!")
      H.eq(stamp_of(path), vim.b[buf].xynovim_disk_stamp)
    end)
  end)

  -- ----------------------------------------------------------- 22: 99 guard
  describe("interplay with the 99 guard", function()
    it("22 auto-save off() stops autosaving and on() restores it (the calls the 99 guard makes)", function()
      local path, buf = open_file("one\n")
      as().on()
      H.eq(true, as().enabled())
      as().off()
      H.eq(false, as().enabled())
      set_lines(buf, { "while requests run" })
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      vim.wait(1600)
      H.eq("one\n", read(path))
      as().on()
      H.eq(true, as().enabled())
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
      H.wait_for(function()
        return read(path) == "while requests run\n"
      end, 4000, "autosave after on()")
    end)

    pending("22 the guard only turns auto-save back on if it turned it off", "lives in agent-99-guard's closure (lua/plugins/ninety-nine.lua); covered by that area's spec")
  end)
end)
