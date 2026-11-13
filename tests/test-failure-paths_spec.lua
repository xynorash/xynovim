-- Failure paths of the test UI: nextest absent (<leader>tP), a test that never finishes.
local H = require("xynotest.helpers")
local T = require("config.test_ui")

local function capture(fn)
  local notes = {}
  local real = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = real
  assert(ok, err)
  return notes
end

describe("nextest profile picker", function()
  it("says nextest is missing and how to get it, instead of offering profiles that change nothing", function()
    if vim.fn.executable("cargo-nextest") == 1 then
      return skip("cargo-nextest is installed here")
    end
    local picked = false
    local real = vim.ui.select
    vim.ui.select = function()
      picked = true
    end
    local notes = capture(function()
      T.pick_profile()
    end)
    vim.ui.select = real
    H.not_ok(picked, "a picker was opened")
    H.eq(1, #notes)
    H.eq(vim.log.levels.WARN, notes[1].level)
    H.has(notes[1].msg, "cargo-nextest is not installed")
    H.has(notes[1].msg, "cargo test")
    H.has(notes[1].msg, "cargo install cargo-nextest")
  end)
end)

describe("a test run that never ends", function()
  it("tells how to stop it after M.slow_after_s, once, and not when the run finished", function()
    local old = T.slow_after_s
    T.slow_after_s = 0.1
    local client = { listeners = {}, get_position = function() end }
    T.consumer(client)
    local notes = capture(function()
      client.listeners.run()
      vim.wait(400)
    end)
    H.eq(1, #notes)
    H.has(notes[1].msg, "<leader>tS")
    -- a finished run stays quiet
    local quiet = capture(function()
      client.listeners.run()
      client.listeners.results("a", {}, false)
      vim.wait(400)
    end)
    T.slow_after_s = old
    for _, n in ipairs(quiet) do
      H.no_match(n.msg, "still running")
    end
  end)
end)
