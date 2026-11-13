-- blink.cmp's fuzzy matcher is a native library. blink.cmp downloads a prebuilt one from its GitHub releases
-- (https://github.com/saghen/blink.cmp/releases/download/<tag>/<target-triple>.so, plus its .sha256) the first time
-- completion loads, when none matching the checked-out tag is in <plugin dir>/target/release. That was a
-- binary download at startup with a "Downloading pre-built binary" toast, repeated by every Neovim started
-- while the first download ran (blink writes `v0.0.0` into target/release/version for the duration), and,
-- failing, retried on every start. Now:
--   * the library is there and its version file is a real tag: nothing is downloaded, nothing is said
--     (blink only verifies the checksum);
--   * missing / outdated: ONE download, announced by blink's own single toast, never started while another
--     instance is in the middle of it (version file `v0.0.0`, younger than 2 min), not retried within 6 hours
--     after an attempt that did not end in a library; meanwhile the Lua fuzzy matcher is used, quietly
--     (implementation = "prefer_rust": no fallback warning);
--   * vim.g.xynovim_blink_download = false: never download, Lua matcher (what `:checkhealth xynovim` says).
-- `:checkhealth xynovim` shows the state, the source and the switch.
--
-- Once-only across processes (the earlier version used a stamp in the per-run state directory, which the spec
-- runner and every fresh XDG_STATE_HOME starts empty, and blink's `v0.0.0` marker is written only after the
-- decision, so two instances started together both downloaded, and a Neovim that exits mid-download, as every
-- short-lived spec instance does, left `v0.0.0` behind and the next one downloaded again):
--   * a LOCK file `<plugin dir>/target/xynovim-blink-download.lock` ({pid, at}), created exclusively before
--     blink is allowed to download; held while this process is the one downloading (released when the version
--     file turns into a real tag, at VimLeavePre, or after 150 s); a lock of a dead process or older than 5
--     minutes is taken over;
--   * the attempt stamp lives next to it in the plugin directory (shared by every instance and every
--     XDG_STATE_HOME), so the 6 hour back-off holds for the spec runner, first launches and the owner's editor;
--   * `v0.0.0` counts as "another Neovim is downloading" only while a live process holds the lock; otherwise it
--     is an interrupted download and falls under the back-off;
--   * the spec runner sets vim.g.xynovim_blink_download = false unless XYNO_TEST_BLINK_DOWNLOAD=1 (specs never
--     download into the shared plugin directory).
local M = {}

M.RETRY_AFTER = 6 * 3600
M.IN_PROGRESS = 120

--- Pure decision. env = { lib = bool, version = string|nil, version_age = seconds|nil, last_attempt = epoch|nil,
--- now = epoch, disabled = bool }.
--- @return { download: boolean, implementation: string, state: string, why: string }
function M.plan(env)
  local ready = env.lib and env.version ~= nil and env.version ~= "" and env.version ~= "v0.0.0"
  if ready then
    return {
      download = true,
      implementation = "prefer_rust",
      state = "ready",
      why = "the library is there (" .. env.version .. ")",
    }
  end
  if env.disabled then
    return {
      download = false,
      implementation = "lua",
      state = "disabled",
      why = "vim.g.xynovim_blink_download = false: Lua fuzzy matcher, nothing downloaded",
    }
  end
  local lock = env.lock
  if lock and lock.alive and lock.pid ~= env.pid then
    return {
      download = false,
      implementation = "lua",
      state = "downloading",
      why = ("Neovim process %s has been downloading it for %d s: Lua matcher until the next start"):format(
        tostring(lock.pid),
        math.max(env.now - (lock.at or env.now), 0)
      ),
    }
  end
  if env.version == "v0.0.0" and (env.version_age or math.huge) < M.IN_PROGRESS and not env.last_attempt then
    return {
      download = false,
      implementation = "lua",
      state = "downloading",
      why = "its version file says v0.0.0 (a download started a moment ago, owner unknown): Lua matcher until the next start",
    }
  end
  if env.last_attempt and env.now - env.last_attempt < M.RETRY_AFTER then
    return {
      download = false,
      implementation = "lua",
      state = "backoff",
      why = (env.version == "v0.0.0" and "an earlier download was interrupted (version file v0.0.0) and " or "")
        .. "a download was tried less than 6 hours ago and left no library: Lua matcher, no retry yet",
    }
  end
  return {
    download = true,
    implementation = "prefer_rust",
    state = "download",
    why = "no library for this blink.cmp version: downloading it once",
  }
end

M.dir = nil -- specs: a directory to use in place of the plugin's

local function plugin_dir()
  if M.dir then
    return M.dir
  end
  local ok, cfg = pcall(require, "lazy.core.config")
  local p = ok and cfg.plugins["blink.cmp"]
  return p and p.dir or (vim.fn.stdpath("data") .. "/lazy/blink.cmp")
end

--- Shared by every Neovim that uses this plugin directory (the state directory is per XDG_STATE_HOME).
local function stamp_file()
  return plugin_dir() .. "/target/xynovim-blink-download.json"
end

local function lock_file()
  return plugin_dir() .. "/target/xynovim-blink-download.lock"
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  return ok and type(data) == "table" and data or nil
end

local function pid_alive(pid)
  pid = tonumber(pid)
  if not pid or pid <= 0 then
    return false
  end
  local ok, res = pcall(vim.uv.kill, pid, 0)
  return ok and res == 0
end

M.LOCK_MAX_AGE = 300

--- The lock as plan() sees it: { pid, at, alive } or nil.
local function read_lock(now)
  local data = read_json(lock_file())
  if not data then
    return nil
  end
  local alive = pid_alive(data.pid) and now - (tonumber(data.at) or 0) < M.LOCK_MAX_AGE
  return { pid = tonumber(data.pid), at = tonumber(data.at), alive = alive }
end

--- The environment `plan` decides on, read from disk.
function M.env()
  local dir = plugin_dir() .. "/target/release"
  local ext = vim.fn.has("mac") == 1 and ".dylib" or (vim.fn.has("win32") == 1 and ".dll" or ".so")
  local env = { now = os.time(), disabled = vim.g.xynovim_blink_download == false, pid = vim.uv.os_getpid() }
  env.lib = vim.uv.fs_stat(dir .. "/libblink_cmp_fuzzy" .. ext) ~= nil
    or vim.uv.fs_stat(dir .. "/blink_cmp_fuzzy" .. ext) ~= nil
  local st = vim.uv.fs_stat(dir .. "/version")
  if st then
    local f = io.open(dir .. "/version", "r")
    if f then
      env.version = vim.trim(f:read("*a") or "")
      f:close()
    end
    env.version_age = os.time() - st.mtime.sec
  end
  local stamp = read_json(stamp_file())
  env.last_attempt = stamp and tonumber(stamp.at) or nil
  env.lock = read_lock(env.now)
  return env
end

--- Record that a download is about to start (once per RETRY_AFTER unless it ends in a library).
function M.note_attempt()
  pcall(function()
    vim.fn.mkdir(vim.fs.dirname(stamp_file()), "p")
    local f = assert(io.open(stamp_file(), "w"))
    f:write(vim.json.encode({ at = os.time(), pid = vim.uv.os_getpid() }))
    f:close()
  end)
end

--- Take the download lock: exclusive creation, a dead or too old holder is replaced. true when this process
--- now holds it.
function M.acquire()
  vim.fn.mkdir(vim.fs.dirname(lock_file()), "p")
  local function create()
    local fd = vim.uv.fs_open(lock_file(), "wx", 420)
    if not fd then
      return false
    end
    vim.uv.fs_write(fd, vim.json.encode({ pid = vim.uv.os_getpid(), at = os.time() }))
    vim.uv.fs_close(fd)
    return true
  end
  if create() then
    return true
  end
  local held = read_lock(os.time())
  if held and held.alive then
    return held.pid == vim.uv.os_getpid()
  end
  -- stale: move it aside atomically (only one racer wins the rename), then create ours
  local aside = ("%s.stale.%d"):format(lock_file(), vim.uv.os_getpid())
  if vim.uv.fs_rename(lock_file(), aside) then
    os.remove(aside)
  end
  return create()
end

--- Drop the lock if it is ours.
function M.release()
  local data = read_json(lock_file())
  if data and tonumber(data.pid) == vim.uv.os_getpid() then
    os.remove(lock_file())
  end
end

--- Hold the lock while the download runs: released when the version file is a real tag, at exit, or after 150 s.
local function hold_until_done()
  local started = os.time()
  local timer = assert(vim.uv.new_timer())
  local function done()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    M.release()
  end
  timer:start(
    2000,
    2000,
    vim.schedule_wrap(function()
      local env = M.env()
      if (env.version and env.version ~= "v0.0.0" and env.version ~= "") or os.time() - started > 150 then
        done()
      end
    end)
  )
  vim.api.nvim_create_autocmd("VimLeavePre", { once = true, callback = M.release })
end

--- Settings for blink's `fuzzy` option (merged into opts by plugins/blink-binary.lua).
function M.fuzzy_opts()
  local p = M.plan(M.env())
  if p.state == "download" then
    if M.acquire() then
      M.note_attempt()
      hold_until_done()
    else
      -- another process took the lock between the read and now: it downloads, we do not
      p = M.plan(M.env())
      if p.download then
        p = {
          download = false,
          implementation = "lua",
          state = "downloading",
          why = "another Neovim took the download lock first: Lua matcher until the next start",
        }
      end
    end
  end
  M.last = p
  return {
    implementation = p.implementation,
    prebuilt_binaries = { download = p.download },
  }
end

--- Lines for :checkhealth: { level, text } pairs.
function M.report()
  local p = M.last or M.plan(M.env())
  local env = M.env()
  local out = {}
  local lvl = (p.state == "ready") and "ok" or ((p.state == "disabled") and "info" or "warn")
  out[#out + 1] = { lvl, "blink.cmp fuzzy matcher: " .. p.state .. " - " .. p.why }
  out[#out + 1] = {
    "info",
    "it downloads blink.cmp's prebuilt library from https://github.com/saghen/blink.cmp/releases (<tag>/<triple>.so + .sha256, checksum verified), once per blink.cmp version; version file: "
      .. (env.version or "none"),
  }
  out[#out + 1] = {
    "info",
    "no download wanted: vim.g.xynovim_blink_download = false (Lua matcher), or build it: cargo build --release in the plugin directory",
  }
  return out
end

return M
