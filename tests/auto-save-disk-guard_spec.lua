-- auto-save (lua/plugins/auto-save.lua) with the xyno-guard.nvim plugin (lua/plugins/xyno-guard.lua) as its
-- condition. The guard itself (is_dependency, can_save, the stamps, FileChangedShell, save_all, the
-- apply_workspace_edit wrapper) is specified in the plugin repository; this file keeps the xynovim
-- configuration, the autosave behaviour end to end, the didSave / BufWritePost / lint / neotest glue
-- of the User AutoSaveWritePost handler, the multi-file rename and the 99 interplay.
-- All files live in temp dirs; "dependency" paths are faked with CARGO_HOME /
-- RUSTUP_HOME pointing into one. Needs rust-analyzer only for the multi-file
-- rename test (skipped with a message otherwise).
local H = require("xynotest.helpers")
local dg = require("xyno_guard")

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
      H.ok(o.condition == dg.can_save, "condition is xyno_guard.can_save")
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

    it("3 an autosave in the middle of an insert does not split the undo block: one u undoes the whole insert", function()
      H.need_tmux()
      -- field test: the debounced write closed the insert-mode undo block, so `u` after
      -- "abc" <pause> "def" <pause> "ghi" removed only " ghi"; the hook now runs :undojoin
      local dir = H.tmpdir()
      local path = dir .. "/undo.txt"
      write(path, "one\n")
      local function pane()
        return H.tmux({ "capture-pane", "-p", "-t", "t" }, "undo").stdout or ""
      end
      local r = H.tmux({ "new-session", "-d", "-s", "t", "-x", "120", "-y", "30", "-c", dir, "nvim " .. path }, "undo")
      H.eq(0, r.code, r.stderr)
      H.wait_for(function()
        return pane():find("one", 1, true)
      end, 60000, "nvim to show the file")
      vim.wait(1500)
      H.tmux({ "send-keys", "-t", "t", "A", " abc" }, "undo")
      H.wait_for(function()
        return read(path) == "one abc\n"
      end, 6000, "first autosave while typing")
      H.tmux({ "send-keys", "-t", "t", " def" }, "undo")
      H.wait_for(function()
        return read(path) == "one abc def\n"
      end, 6000, "second autosave while typing")
      H.tmux({ "send-keys", "-t", "t", " ghi", "Escape" }, "undo")
      H.wait_for(function()
        return read(path) == "one abc def ghi\n"
      end, 6000, "autosave on leaving insert mode")
      H.tmux({ "send-keys", "-t", "t", "u" }, "undo")
      H.wait_for(function()
        return read(path) == "one\n"
      end, 6000, "u undid the whole insert (and the undo was autosaved)")
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

    it("an autosaved non-Rust buffer reaches nvim-lint's BufWritePost handler (Cargo.toml lints stayed stale); a Rust one does not", function()
      local lint_was = package.loaded["lint"]
      package.loaded["lint"] = lint_was or {}
      local g = vim.api.nvim_create_augroup("nvim-lint", { clear = false })
      local hits = {}
      local id = vim.api.nvim_create_autocmd("BufWritePost", {
        group = g,
        callback = function(ev)
          hits[#hits + 1] = ev.buf
        end,
      })
      local _, buf = open_file("one\n")
      vim.bo[buf].filetype = "toml"
      autosave_once(buf)
      H.eq({ buf }, hits)
      vim.bo[buf].filetype = "rust"
      autosave_once(buf)
      H.eq({ buf }, hits, "no lint re-emit for Rust")
      pcall(vim.api.nvim_del_autocmd, id)
      package.loaded["lint"] = lint_was
    end)

    it("6 an autosaved Rust buffer reaches neotest's own rediscovery (group neotest.Client) and no other BufWritePost handler", function()
      local _, buf = open_file("one\n")
      vim.bo[buf].filetype = "rust"
      local n = count_bufwritepost(buf)
      local seen = {}
      local g = vim.api.nvim_create_augroup("neotest.Client", { clear = true })
      vim.api.nvim_create_autocmd("BufWritePost", {
        group = g,
        callback = function(ev)
          seen[#seen + 1] = ev.buf
        end,
      })
      local had = package.loaded["neotest.client"]
      package.loaded["neotest.client"] = {}
      autosave_once(buf)
      H.eq({ buf }, seen, "rediscovery requested (the tree kept the old tests: <leader>tr ran another one)")
      H.eq(0, n(), "the global BufWritePost event is not re-emitted")
      vim.bo[buf].filetype = "text"
      autosave_once(buf)
      H.eq(1, #seen, "not for other filetypes")
      package.loaded["neotest.client"] = had
      pcall(vim.api.nvim_del_augroup_by_name, "neotest.Client")
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

  -- ---------------------------------------------------- 13, 14: the write guard
  describe("AutoSaveWritePre / Post", function()
    local function fire(pattern, buf)
      vim.api.nvim_exec_autocmds("User", { pattern = pattern, data = { saved_buffer = buf } })
    end

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
      H.is_nil(vim.b[buf].xyno_guard_buftype)
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

  -- ------------------------------------------------ 16: LazyVim's FocusGained checktime
  describe("FileChangedShell", function()
    it("16 LazyVim's FocusGained :checktime (lazyvim_checktime) still exists", function()
      local acs = vim.api.nvim_get_autocmds({ group = "lazyvim_checktime", event = "FocusGained" })
      H.ok(#acs > 0, "FocusGained autocmd in lazyvim_checktime")
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
