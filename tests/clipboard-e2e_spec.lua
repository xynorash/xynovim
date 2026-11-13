-- The clipboard end to end with REAL nvim processes and fake wl-copy / wl-paste on PATH: a plain local
-- session, tmux and ssh variables, a real TUI inside a real tmux server (the yank must land in the tmux
-- paste buffer), and the OSC 52 fallback when no clipboard tool exists. The provider logic itself is
-- specified in xyno-clipboard.nvim (11+ specs); this file checks what a user of xynovim sees.
--
-- The no-tool cases need the plugin version with the OSC 52 fallback (the lock file may still pin an
-- older one; run with XYNOVIM_DEV_PLUGINS=<dir of the clones>, docs/DEV-PLUGINS.md) and skip otherwise.
-- xyno-os: linux (the clipboard provider is Linux only; fake wl-clipboard are sh scripts)
local H = require("xynotest.helpers")

local function write(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function exec_file(path, s)
  write(path, s)
  vim.uv.fs_chmod(path, tonumber("755", 8))
end

--- A bin dir with fake wl-copy / wl-paste (and symlinks to the few tools nvim needs), a state dir the
--- fakes write to. `tools = false` leaves the fakes out: a machine without any clipboard tool.
local function sandbox(tools)
  local dir = H.tmpdir()
  local bin, state = dir .. "/bin", dir .. "/state"
  vim.fn.mkdir(bin, "p")
  vim.fn.mkdir(state, "p")
  for _, t in ipairs({ "sh", "cat", "env", "git", "curl", "uname", "ls", "rm", "mkdir", "tar", "gzip" }) do
    local p = vim.fn.exepath(t)
    if p ~= "" then
      vim.uv.fs_symlink(p, bin .. "/" .. t)
    end
  end
  if tools then
    exec_file(
      bin .. "/wl-copy",
      '#!/bin/sh\necho "$*" >> "$FAKE_CLIP_DIR/wl-copy.args"\ncat > "$FAKE_CLIP_DIR/wl-copy.out"\n'
    )
    exec_file(bin .. "/wl-paste", '#!/bin/sh\ncat "$FAKE_CLIP_DIR/wl-paste.in"\n')
  end
  write(state .. "/wl-paste.in", "pasted-from-wayland")
  return { dir = dir, bin = bin, state = state }
end

local function base_env(sb, extra)
  local env = { PATH = sb.bin, FAKE_CLIP_DIR = sb.state, TERM = "xterm-256color" }
  for _, k in ipairs({
    "HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    "XDG_CACHE_HOME",
    "TMPDIR",
    "XYNOVIM_DEV_PLUGINS",
  }) do
    env[k] = vim.env[k]
  end
  return vim.tbl_extend("force", env, extra or {})
end

--- Headless child with the full config: yanks a line with "+yy, pastes with "+p, and reports what
--- reached the fakes, which OSC 52 sequences went to the UI, and the messages. nvim_ui_send is
--- recorded (there is no UI in a headless child).
local PROBE = [[
local sent = {}
vim.api.nvim_ui_send = function(s) sent[#sent + 1] = s end
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "yank me" })
vim.cmd('normal! gg"+yy')
vim.wait(500) -- let the provider's wl-copy job run before the probe quits
local after_yank = #sent
if vim.env.PROBE_OLD_SWITCH then
  vim.g.xynovim_remote_clipboard_osc52 = false
  vim.cmd('normal! gg"+yy')
end
local pasted_ok = true
if not vim.env.PROBE_NO_PASTE then -- an OSC 52 paste query waits 10 s for a terminal that is not there
  pasted_ok = pcall(vim.cmd, 'normal! G$"+p')
end
return {
  provider = vim.g.clipboard and vim.g.clipboard.name or vim.NIL,
  pasted_ok = pasted_ok, sent = sent, after_yank = after_yank,
  pasted = vim.api.nvim_buf_get_lines(0, 0, -1, false),
  messages = vim.api.nvim_exec2("messages", { output = true }).output,
  errmsg = vim.v.errmsg,
}
]]

local function child(sb, extra)
  local dir = H.tmpdir()
  local script = dir .. "/child.lua"
  write(
    script,
    ([[
vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = function()
  vim.defer_fn(function()
    local ok, res = xpcall(function() %s end, debug.traceback)
    io.stdout:write("\nXYNO_JSON " .. vim.json.encode({ ok = ok, res = res }) .. "\n")
    vim.cmd("qa!")
  end, 300)
end })
]]):format(PROBE)
  )
  local r = vim
    .system(
      { vim.fn.exepath("nvim"), "--headless", "-S", script },
      { text = true, env = base_env(sb, extra), clear_env = true, cwd = dir }
    )
    :wait(60000)
  local line = ((r.stdout or "") .. (r.stderr or "")):match("XYNO_JSON (%b{})")
  if not line then
    error(("child nvim printed no result (exit %s)\n%s\n%s"):format(r.code, r.stdout, r.stderr), 2)
  end
  local out = vim.json.decode(line)
  if not out.ok then
    error("child failed: " .. tostring(out.res), 2)
  end
  return out.res
end

--- Neovim's own provider starts wl-copy as a job and the probe's nvim may quit first: wait for the fake's output.
local function wl_copy_out(sb)
  H.wait_for(function()
    return (read(sb.state .. "/wl-copy.out") or "") ~= ""
  end, 10000, "the fake wl-copy to write its input")
  return read(sb.state .. "/wl-copy.out")
end

local function osc52(text)
  return ("\27]52;c;%s\27\\"):format(vim.base64.encode(text))
end

--- Does the plugin version in use have the OSC 52 fallback for sessions without a tool?
local function plugin_has_fallback()
  local ok, dir = pcall(function()
    return require("lazy.core.config").plugins["xyno-clipboard.nvim"].dir
  end)
  local src = ok and read(dir .. "/lua/xyno_clipboard/init.lua") or ""
  return src:find("no clipboard tool", 1, true) ~= nil
end

describe("clipboard end to end: a plain local session with wl-clipboard", function()
  it("leaves Neovim's own provider alone: yank runs wl-copy, paste runs wl-paste, no OSC 52, no messages", function()
    local sb = sandbox(true)
    local r = child(sb, { WAYLAND_DISPLAY = "wayland-0" })
    H.eq(vim.NIL, r.provider, "xyno-clipboard does not install itself in a plain session that has wl-clipboard")
    H.eq("yank me\n", wl_copy_out(sb))
    H.eq({}, r.sent, "no OSC 52 in a plain session")
    -- Neovim's own provider reads the clipboard again with wl-paste (no longer a cache hit once the probe waited)
    H.eq({ "yank mepasted-from-wayland" }, r.pasted)
    H.eq("", vim.trim(r.messages))
    H.eq("", r.errmsg)
  end)
end)

describe("clipboard end to end: tmux / ssh sessions", function()
  it("tmux with wl-clipboard: yank -> wl-copy --sensitive AND OSC 52, paste -> wl-paste, no messages", function()
    local sb = sandbox(true)
    local r = child(sb, { WAYLAND_DISPLAY = "wayland-0", TMUX = "/tmp/fake-tmux,1,0" })
    H.eq("XynoClipboard", r.provider)
    H.eq("yank me\n", wl_copy_out(sb))
    H.match(read(sb.state .. "/wl-copy.args"), "--sensitive", true)
    H.eq(osc52("yank me\n"), r.sent[1])
    H.eq({ "yank mepasted-from-wayland" }, r.pasted)
    H.eq("", vim.trim(r.messages))
    H.eq("", r.errmsg)
  end)

  it("ssh without a Wayland display: OSC 52 copy only", function()
    local sb = sandbox(false)
    local r = child(sb, { SSH_TTY = "/dev/pts/9", PROBE_NO_PASTE = "1" })
    H.eq("XynoClipboard", r.provider)
    H.eq(osc52("yank me\n"), r.sent[1])
    H.is_nil(read(sb.state .. "/wl-copy.out"))
  end)

  it("vim.g.xynovim_remote_clipboard_osc52 = false still stops the emit in a real yank", function()
    local sb = sandbox(true)
    local r = child(sb, { WAYLAND_DISPLAY = "wayland-0", TMUX = "/tmp/fake-tmux,1,0", PROBE_OLD_SWITCH = "1" })
    H.eq(1, r.after_yank, "the first yank emitted")
    H.eq(1, #vim.tbl_filter(function(s)
      return s:find("\27]52;c;" .. vim.base64.encode("yank me\n"), 1, true)
    end, r.sent), "the second yank (switch off) did not")
  end)
end)

describe("clipboard end to end: no clipboard tool at all (OSC 52 fallback)", function()
  it("a plain session copies via OSC 52 and pastes what it copied", function()
    if not plugin_has_fallback() then
      skip("the loaded xyno-clipboard.nvim predates the OSC 52 fallback (use XYNOVIM_DEV_PLUGINS, docs/DEV-PLUGINS.md)")
    end
    local sb = sandbox(false)
    local r = child(sb, {})
    H.eq("XynoClipboard", r.provider)
    H.eq(osc52("yank me\n"), r.sent[1])
    H.eq({ "yank me", "yank me" }, r.pasted, "paste returns the last copy, no terminal query that could hang")
    -- headless nvim has no notifier UI, so the single hint lands in :messages; nothing else may
    local _, hints = r.messages:gsub("no clipboard tool found", "")
    H.ok(hints <= 1, "at most one hint, got " .. hints)
    H.eq(
      "",
      vim.trim(
        (
          r.messages:gsub(
            "xyno%-clipboard: no clipboard tool found.-:checkhealth provider shows what Neovim found%.",
            ""
          )
        )
      )
    )
  end)

  it("in a real TUI the hint appears exactly once and :messages stays empty", function()
    if not plugin_has_fallback() then
      skip("the loaded xyno-clipboard.nvim predates the OSC 52 fallback (use XYNOVIM_DEV_PLUGINS, docs/DEV-PLUGINS.md)")
    end
    H.need_tmux()
    local sb = sandbox(false)
    write(sb.dir .. "/f.txt", "tui text\n")
    local env = {}
    for k, v in pairs(base_env(sb, {})) do
      env[#env + 1] = ("%s=%s"):format(k, vim.fn.shellescape(v))
    end
    -- TMUX is deliberately not forwarded: this is the "plain terminal" case
    local cmd = ("cd %s && exec env -i %s nvim f.txt"):format(vim.fn.shellescape(sb.dir), table.concat(env, " "))
    cmd = cmd:gsub(" nvim f.txt$", " " .. vim.fn.shellescape(vim.fn.exepath("nvim")) .. " f.txt")
    local t = H.tmux({ "-f", "/dev/null", "new-session", "-d", "-x", "120", "-y", "30", "-s", "clip", cmd }, "clip")
    H.eq(0, t.code, t.stderr)
    H.tmux({ "set", "-g", "set-clipboard", "on" }, "clip")
    local function screen()
      return H.tmux({ "capture-pane", "-t", "clip", "-p" }, "clip").stdout or ""
    end
    local seen = H.wait_for(function()
      return screen():find("no clipboard tool", 1, true)
    end, 20000, "the hint")
    H.ok(seen)
    local first = screen()
    local _, count = first:gsub("no clipboard tool", "")
    H.eq(1, count, "one hint")
    H.tmux({ "send-keys", "-t", "clip", '"+yy' }, "clip")
    H.wait_for(function()
      return H.tmux({ "show-buffer" }, "clip").stdout == "tui text\n"
    end, 5000, "the tmux paste buffer after the yank")
    H.eq("tui text\n", H.tmux({ "show-buffer" }, "clip").stdout)
    H.tmux({
      "send-keys",
      "-t",
      "clip",
      ":lua vim.fn.writefile({ vim.api.nvim_exec2('messages', { output = true }).output }, 'msgs.txt')",
      "Enter",
    }, "clip")
    H.wait_for(function()
      return read(sb.dir .. "/msgs.txt") ~= nil
    end, 5000, "msgs.txt")
    H.eq("", vim.trim(read(sb.dir .. "/msgs.txt")), ":messages is empty")
  end)
end)

describe("clipboard end to end: a real TUI inside tmux", function()
  it("a yank lands in the tmux paste buffer (set-clipboard on), wl-copy is called too, paste reads wl-paste", function()
    H.need_tmux()
    local sb = sandbox(true)
    write(sb.dir .. "/f.txt", "tmux text\n")
    local env = {}
    for k, v in pairs(base_env(sb, { WAYLAND_DISPLAY = "wayland-0" })) do
      env[#env + 1] = ("%s=%s"):format(k, vim.fn.shellescape(v))
    end
    -- $TMUX is expanded by the pane's shell: the session is a real tmux one
    local cmd = ('cd %s && exec env -i %s TMUX="$TMUX" %s f.txt'):format(
      vim.fn.shellescape(sb.dir),
      table.concat(env, " "),
      vim.fn.shellescape(vim.fn.exepath("nvim"))
    )
    local t = H.tmux({ "-f", "/dev/null", "new-session", "-d", "-x", "120", "-y", "30", "-s", "tm", cmd }, "tm")
    H.eq(0, t.code, t.stderr)
    H.tmux({ "set", "-g", "set-clipboard", "on" }, "tm")
    H.wait_for(function()
      return (H.tmux({ "capture-pane", "-t", "tm", "-p" }, "tm").stdout or ""):find("tmux text", 1, true)
    end, 20000, "nvim up")
    H.tmux({ "send-keys", "-t", "tm", '"+yy' }, "tm")
    H.wait_for(function()
      return H.tmux({ "show-buffer" }, "tm").stdout == "tmux text\n"
    end, 5000, "the tmux paste buffer after the yank")
    H.eq("tmux text\n", H.tmux({ "show-buffer" }, "tm").stdout)
    H.wait_for(function()
      return read(sb.state .. "/wl-copy.out") == "tmux text\n"
    end, 3000, "wl-copy")
    H.tmux({ "send-keys", "-t", "tm", '$"+p', ":w! out.txt", "Enter" }, "tm")
    H.wait_for(function()
      return read(sb.dir .. "/out.txt") ~= nil
    end, 5000, "out.txt")
    H.eq("tmux textpasted-from-wayland\n", read(sb.dir .. "/out.txt"))
  end)
end)
