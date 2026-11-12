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
  if env.version == "v0.0.0" and (env.version_age or math.huge) < M.IN_PROGRESS then
    return {
      download = false,
      implementation = "lua",
      state = "downloading",
      why = "another Neovim is downloading it right now: Lua matcher until the next start",
    }
  end
  if env.last_attempt and env.now - env.last_attempt < M.RETRY_AFTER then
    return {
      download = false,
      implementation = "lua",
      state = "backoff",
      why = "a download was tried less than 6 hours ago and left no library: Lua matcher, no retry yet",
    }
  end
  return {
    download = true,
    implementation = "prefer_rust",
    state = "download",
    why = "no library for this blink.cmp version: downloading it once",
  }
end

local function plugin_dir()
  local ok, cfg = pcall(require, "lazy.core.config")
  local p = ok and cfg.plugins["blink.cmp"]
  return p and p.dir or (vim.fn.stdpath("data") .. "/lazy/blink.cmp")
end

local function stamp_file()
  return vim.fn.stdpath("state") .. "/xynovim-blink-download.json"
end

--- The environment `plan` decides on, read from disk.
function M.env()
  local dir = plugin_dir() .. "/target/release"
  local ext = vim.fn.has("mac") == 1 and ".dylib" or (vim.fn.has("win32") == 1 and ".dll" or ".so")
  local env = { now = os.time(), disabled = vim.g.xynovim_blink_download == false }
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
  local f = io.open(stamp_file(), "r")
  if f then
    local ok, data = pcall(vim.json.decode, f:read("*a"))
    f:close()
    env.last_attempt = ok and type(data) == "table" and tonumber(data.at) or nil
  end
  return env
end

--- Record that a download is about to start (once per RETRY_AFTER unless it ends in a library).
function M.note_attempt()
  pcall(function()
    vim.fn.mkdir(vim.fs.dirname(stamp_file()), "p")
    local f = assert(io.open(stamp_file(), "w"))
    f:write(vim.json.encode({ at = os.time() }))
    f:close()
  end)
end

--- Settings for blink's `fuzzy` option (merged into opts by plugins/blink-binary.lua).
function M.fuzzy_opts()
  local p = M.plan(M.env())
  if p.state == "download" then
    M.note_attempt()
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
