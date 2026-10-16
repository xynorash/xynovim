-- The Windows scripts mirror the shell ones: scripts/bootstrap.ps1 does what
-- scripts/bootstrap.sh does, scripts/test.lua (and the thin test.ps1) what
-- scripts/test.sh does. Table checks on the text, plus a real PowerShell parse
-- when pwsh / powershell is installed. Runs on every platform.
local H = require("xynotest.helpers")

local function read(rel)
  local f = assert(io.open(H.repo .. "/" .. rel, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local sh, ps, tl = read("scripts/bootstrap.sh"), read("scripts/bootstrap.ps1"), read("scripts/test.lua")
local tsh = read("scripts/test.sh")

describe("scripts/bootstrap.ps1 mirrors scripts/bootstrap.sh", function()
  it("runs the same three steps in the same order", function()
    for _, step in ipairs({ "Lazy! install", "Lazy! restore", "provision.lua" }) do
      H.has(sh, step)
      H.has(ps, step)
    end
    local a, b, c = ps:find("Lazy! install", 1, true), ps:find("Lazy! restore", 1, true), ps:find("provision.lua", 1, true)
    H.ok(a < b and b < c, "install, then restore, then provision")
    H.has(ps, "step 1/3")
    H.has(ps, "step 3/3")
  end)

  it("puts the lockfile back after the install round and compares it at the end", function()
    H.has(ps, "Copy-Item -LiteralPath $orig -Destination $lock")
    H.has(ps, "Get-FileHash")
    H.has(ps, "lazy-lock.json unchanged")
    H.has(ps, "lazy-lock.json changed")
  end)

  it("checks the same prerequisites (minus unzip / gzip, which Windows does not use) and keeps the skip switch", function()
    local list = sh:match("for tool in ([^;]-); do")
    H.ok(list, "the tool list in bootstrap.sh")
    for tool in list:gmatch("%S+") do
      if tool ~= "unzip" and tool ~= "gzip" and tool ~= "gcc" and tool ~= "rust-analyzer" then
        H.has(ps, "'" .. tool .. "'")
      end
    end
    H.has(ps, "rust-analyzer")
    H.has(ps, "'gcc', 'cc', 'clang', 'cl', 'zig'")
    H.has(ps, "BOOTSTRAP_SKIP_PREREQS")
    H.has(sh, "BOOTSTRAP_SKIP_PREREQS")
    H.has(ps, "winget")
    H.not_ok(ps:find("'unzip'", 1, true), "Windows does not need unzip")
  end)

  it("links the config with a junction (no administrator rights) and never replaces an existing directory", function()
    H.has(ps, "mklink /J")
    H.has(ps, "is not this checkout")
    H.has(ps, "LOCALAPPDATA")
    H.has(ps, "XDG_CONFIG_HOME")
  end)

  it("uses only PowerShell 5.1 syntax (no ?: ?? && || -Parallel)", function()
    local code = ps:gsub("#[^\n]*", "")
    for _, bad in ipairs({ " ?? ", " ? ", "-Parallel", "&&", "||" }) do
      H.not_ok(code:find(bad, 1, true), "PowerShell 7 only: " .. bad)
    end
  end)

  it("parses with the PowerShell parser (when pwsh or powershell exists)", function()
    local exe = vim.fn.executable("pwsh") == 1 and "pwsh" or vim.fn.executable("powershell") == 1 and "powershell" or nil
    if not exe then
      return skip("no pwsh / powershell on this machine")
    end
    for _, f in ipairs({ "scripts/bootstrap.ps1", "scripts/test.ps1" }) do
      local cmd = ("$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('%s',[ref]$null,[ref]$e); if ($e.Count) { $e | ForEach-Object { $_.ToString() }; exit 1 }"):format(
        H.repo .. "/" .. f
      )
      local r = vim.system({ exe, "-NoProfile", "-NonInteractive", "-Command", cmd }, { text = true }):wait(60000)
      H.eq(0, r.code, f .. ": " .. (r.stdout or "") .. (r.stderr or ""))
    end
  end)
end)

describe("scripts/test.lua and test.ps1 mirror scripts/test.sh", function()
  it("take the same options", function()
    for _, opt in ipairs({ "--list", "--timeout", "-v" }) do
      H.has(tsh, opt)
      H.has(tl, opt)
    end
    H.has(tl, "--coverage") -- documented as not supported there
  end)

  it("use the same protocol: XYNO_SPEC, the runner, the XYNO_RESULT line, xyno-timeout, the 30 s grace", function()
    for _, w in ipairs({ "XYNO_SPEC", "tests/runner.lua", "XYNO_RESULT", "xyno%-timeout", "30000", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XYNO_TEST_TMP" }) do
      H.ok(tl:find(w) or tl:find(w, 1, true), "test.lua lacks " .. w)
    end
    H.has(tsh, "XYNO_RESULT")
    H.has(tsh, "xyno-timeout")
  end)

  it("test.ps1 only locates nvim and runs test.lua", function()
    local t = read("scripts/test.ps1")
    H.has(t, "scripts")
    H.has(t, "test.lua")
    H.has(t, "-l")
  end)

  it("--list prints the spec files (same list as test.sh --list)", function()
    local nvim = vim.v.progpath
    local r = vim.system({ nvim, "--clean", "-l", H.repo .. "/scripts/test.lua", "--list" }, { text = true }):wait(30000)
    H.eq(0, r.code, r.stderr)
    local got = vim.split(vim.trim(r.stdout), "\r?\n")
    local want = {}
    for name in vim.fs.dir(H.repo .. "/tests") do
      if name:match("_spec%.lua$") then
        want[#want + 1] = "tests/" .. name
      end
    end
    table.sort(want)
    H.eq(want, got)
  end)
end)

describe("OS-aware skips", function()
  it("a spec with a `-- xyno-os:` header for another platform is skipped with its reason", function()
    local other = H.os == "linux" and "windows" or "linux"
    local dir = H.tmpdir()
    local spec = dir .. "/os_spec.lua"
    local f = assert(io.open(spec, "wb"))
    f:write(("-- xyno-os: %s (only there)\nlocal H = require('xynotest.helpers')\nit('x', function() error('must not run') end)\n"):format(other))
    f:close()
    local r = vim.system({ vim.v.progpath, "--headless", "-S", H.repo .. "/tests/runner.lua" }, {
      text = true,
      env = { XYNO_SPEC = spec },
    }):wait(120000)
    H.eq(0, r.code, r.stdout .. r.stderr)
    H.match(r.stdout, "SKIP os_spec.lua (needs " .. other .. ", this is " .. H.os .. ": only there)", true)
    H.match(r.stdout, "XYNO_RESULT passed=0 failed=0 skipped=1", true)
  end)

  it("H.need_os / H.need_posix skip with the platform in the reason", function()
    local harness = require("xynotest.harness")
    local ok, e = pcall(H.need_os, { "nowhere" }, "because")
    H.eq(false, ok)
    H.ok(harness.is_skip(e))
    H.match(e.reason, "needs nowhere, this is " .. H.os .. ": because", true)
    if H.is_win then
      local ok2, e2 = pcall(H.need_posix, "sh")
      H.eq(false, ok2)
      H.ok(harness.is_skip(e2))
    else
      H.eq(true, pcall(H.need_posix, "sh"))
    end
  end)
end)
