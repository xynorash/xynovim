-- The test helpers themselves (no Rust tooling needed).
local H = require("xynotest.helpers")

describe("helpers", function()
  it("deep-compares in eq", function()
    H.eq({ 1, { a = 2 } }, { 1, { a = 2 } })
    H.throws(function()
      H.eq({ 1 }, { 2 })
    end, "expected")
  end)

  it("wait_for returns the value and times out with a message", function()
    local n = 0
    H.eq(
      3,
      H.wait_for(function()
        n = n + 1
        return n >= 3 and n
      end, 1000)
    )
    H.throws(function()
      H.wait_for(function() end, 50, "never")
    end, "timed out waiting for never")
  end)

  it("feed types keys through mappings", function()
    vim.cmd("enew!")
    H.feed("ihello<Esc>")
    H.eq({ "hello" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  it("captures notifications and restores vim.notify", function()
    local orig = vim.notify
    local cap = H.capture_notify()
    vim.notify("x", vim.log.levels.WARN)
    H.eq({ { msg = "x", level = vim.log.levels.WARN } }, cap.list)
    cap.restore()
    H.ok(vim.notify == orig)
  end)

  it("copies fixtures into private temp dirs", function()
    local a, b = H.fixture("basic"), H.fixture("basic")
    H.ok(a ~= b)
    H.eq(1, vim.fn.filereadable(a .. "/src/lib.rs"))
    H.eq(1, vim.fn.filereadable(H.fixture("workspace") .. "/core/Cargo.toml"))
    H.eq(1, vim.fn.filereadable(H.fixture("broken") .. "/src/main.rs"))
    H.eq(1, vim.fn.filereadable(H.fixture("standalone.rs")))
  end)

  it("makes git repositories", function()
    local dir = H.fixture("basic", { git = true })
    H.eq("main", H.git(dir, "rev-parse", "--abbrev-ref", "HEAD"))
    H.eq("", H.git(dir, "status", "--porcelain"))
  end)

  it("removes its temp dirs in cleanup", function()
    local dir = H.tmpdir()
    H.eq(1, vim.fn.isdirectory(dir))
    H.cleanup()
    H.eq(0, vim.fn.isdirectory(dir))
  end)
end)

describe("sandbox wrapper", function()
  it("keeps the project writable and the rest of the disk read-only", function()
    local project = H.fixture("basic")
    local r = H.sandbox_sh(
      "echo ok > inside.txt && ! touch " .. vim.fn.shellescape(vim.env.HOME) .. "/xyno-sandbox-probe",
      project
    )
    H.eq(0, r.code, r.stderr)
    H.eq(1, vim.fn.filereadable(project .. "/inside.txt"))
    H.eq(0, vim.fn.filereadable(vim.env.HOME .. "/xyno-sandbox-probe"))
  end)
end)
