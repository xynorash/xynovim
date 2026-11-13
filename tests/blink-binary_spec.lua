-- blink.cmp's prebuilt-library download: quiet when the library is there, once-only otherwise.
local H = require("xynotest.helpers")
local B = require("config.blink_binary")

local NOW = 1000000
local function plan(over)
  return B.plan(vim.tbl_extend("force", { lib = false, now = NOW, disabled = false }, over or {}))
end

describe("blink binary plan", function()
  it("a library with a real version file: nothing is downloaded, no fallback warning", function()
    local p = plan({ lib = true, version = "v1.10.2" })
    H.eq("ready", p.state)
    H.eq("prefer_rust", p.implementation)
  end)
  it("missing library: one download", function()
    local p = plan()
    H.eq("download", p.state)
    H.eq(true, p.download)
  end)
  it("another instance is mid-download (v0.0.0, young): no second download, Lua matcher", function()
    local p = plan({ version = "v0.0.0", version_age = 10 })
    H.eq({ "downloading", false, "lua" }, { p.state, p.download, p.implementation })
  end)
  it("a stale v0.0.0 (failed or killed download) is retried, but not within 6 hours of the last attempt", function()
    H.eq("download", plan({ version = "v0.0.0", version_age = 99999 }).state)
    local p = plan({ version = "v0.0.0", version_age = 99999, last_attempt = NOW - 60 })
    H.eq({ "backoff", false, "lua" }, { p.state, p.download, p.implementation })
    H.eq("download", plan({ last_attempt = NOW - B.RETRY_AFTER - 1 }).state)
  end)
  it("vim.g.xynovim_blink_download = false never downloads", function()
    local p = plan({ disabled = true })
    H.eq({ "disabled", false, "lua" }, { p.state, p.download, p.implementation })
    H.eq("ready", plan({ disabled = true, lib = true, version = "v1.10.2" }).state, "an existing library is still used")
  end)
  it("is merged into blink's fuzzy opts and reported by :checkhealth", function()
    local tmp = H.tmpdir()
    B.dir = tmp -- never touch the real plugin directory from a spec
    local o = B.fuzzy_opts()
    B.release()
    B.dir = nil
    H.eq("boolean", type(o.prebuilt_binaries.download))
    local txt = vim.inspect(B.report())
    H.match(txt, "github.com/saghen/blink.cmp/releases", true)
    H.match(txt, "xynovim_blink_download", true)
  end)
end)

describe("blink binary: once-only across processes", function()
  local tmp, child
  before_each(function()
    tmp = H.tmpdir()
    B.dir = tmp
  end)
  after_each(function()
    B.release()
    B.dir = nil
    if child then
      pcall(function()
        child:kill(9)
      end)
      child = nil
    end
  end)

  local function lock_path()
    return tmp .. "/target/xynovim-blink-download.lock"
  end
  local function write_lock(pid, at)
    vim.fn.mkdir(tmp .. "/target", "p")
    local f = assert(io.open(lock_path(), "w"))
    f:write(vim.json.encode({ pid = pid, at = at or os.time() }))
    f:close()
  end

  it("the spec runner never downloads into the shared plugin directory", function()
    H.eq(false, vim.g.xynovim_blink_download)
  end)

  it(
    "a live lock of another process means 'downloading' with its pid and age, whatever the version file says",
    function()
      local other = 4242
      local p = plan({ version = "v1.0.0", lock = { pid = other, at = NOW - 30, alive = true }, pid = 1 })
      H.eq({ "downloading", false, "lua" }, { p.state, p.download, p.implementation })
      H.match(p.why, "4242", true)
      H.match(p.why, "30 s", true)
    end
  )

  it("our own lock, a dead holder's lock and a young v0.0.0 marker with no live holder do not block", function()
    H.eq("download", plan({ lock = { pid = 7, at = NOW, alive = true }, pid = 7 }).state, "own lock")
    H.eq("download", plan({ lock = { pid = 7, at = NOW - 9999, alive = false }, pid = 1 }).state, "dead holder")
    -- interrupted download: marker is young but somebody already tried (stamp) and nobody holds the lock
    local p = plan({ version = "v0.0.0", version_age = 5, last_attempt = NOW - 5, pid = 1 })
    H.eq("backoff", p.state)
    H.match(p.why, "interrupted", true)
  end)

  it("acquire is exclusive: a second process (a live pid) cannot take it, a dead or aged lock is taken over", function()
    H.ok(B.acquire(), "first")
    H.ok(B.acquire(), "again from the same process")
    B.release()
    H.is_nil(vim.uv.fs_stat(lock_path()), "released")
    child = vim.system({ "sleep", "20" })
    write_lock(child.pid)
    H.not_ok(B.acquire(), "held by a live process")
    local env = B.env()
    H.ok(env.lock and env.lock.alive and env.lock.pid == child.pid)
    write_lock(child.pid, os.time() - B.LOCK_MAX_AGE - 5)
    H.ok(B.acquire(), "an old lock is replaced even if the pid is alive (pids are reused)")
    B.release()
    write_lock(2147483646)
    H.ok(B.acquire(), "a dead holder is replaced")
    B.release()
    H.is_nil(vim.uv.fs_stat(lock_path()))
  end)

  it("release only drops our own lock", function()
    child = vim.system({ "sleep", "20" })
    write_lock(child.pid)
    B.release()
    H.ok(vim.uv.fs_stat(lock_path()), "someone else's lock stays")
  end)

  it("one download: the second start sees the stamp in the plugin directory (not the state directory)", function()
    vim.g.xynovim_blink_download = nil
    local first = B.fuzzy_opts()
    B.release()
    H.eq(true, first.prebuilt_binaries.download, "no library, no lock, no stamp: the first start downloads")
    H.ok(vim.uv.fs_stat(tmp .. "/target/xynovim-blink-download.json"), "stamp next to the library")
    H.is_nil(vim.uv.fs_stat(vim.fn.stdpath("state") .. "/xynovim-blink-download.json"), "not in the state directory")
    local second = B.fuzzy_opts()
    vim.g.xynovim_blink_download = false
    H.eq(false, second.prebuilt_binaries.download, "back-off: not a second download")
    H.eq("lua", second.implementation)
    H.eq("backoff", B.last.state)
  end)

  it("two processes started together: only the one that wins the lock downloads", function()
    vim.g.xynovim_blink_download = nil
    child = vim.system({ "sleep", "20" })
    write_lock(child.pid) -- the other instance got there first
    local o = B.fuzzy_opts()
    vim.g.xynovim_blink_download = false
    H.eq(false, o.prebuilt_binaries.download)
    H.eq("downloading", B.last.state)
    H.match(B.last.why, tostring(child.pid), true)
  end)

  it(":checkhealth names who downloads", function()
    child = vim.system({ "sleep", "20" })
    write_lock(child.pid)
    B.last = nil
    vim.g.xynovim_blink_download = nil
    local txt = vim.inspect(B.report())
    vim.g.xynovim_blink_download = false
    H.match(txt, tostring(child.pid), true)
    H.match(txt, "downloading", true)
  end)
end)
