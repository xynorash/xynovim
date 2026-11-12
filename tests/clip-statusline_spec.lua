-- The clipboard statusline part: "clip: tmux drops OSC52" only when OSC 52 is the route that carries the yank.
local H = require("xynotest.helpers")
local clip = require("xynovim.clip")

local saved = {}
local function env(k, v)
  if saved[k] == nil then
    saved[k] = { vim.env[k] }
  end
  vim.env[k] = v
end

local function fake_tools()
  local dir = H.tmpdir()
  for _, t in ipairs({ "wl-copy", "wl-paste" }) do
    local f = assert(io.open(dir .. "/" .. t, "w"))
    f:write("#!/bin/sh\nexit 0\n")
    f:close()
    vim.fn.system({ "chmod", "+x", dir .. "/" .. t })
  end
  env("PATH", dir .. ":" .. vim.env.PATH)
end

describe("clipboard statusline hint", function()
  local real
  before_each(function()
    real = package.loaded["xyno_clipboard"]
    package.loaded["xyno_clipboard"] = {
      statusline = function()
        return "clip: tmux drops OSC52", "XynoClipboardError"
      end,
      hint = function()
        return { kind = "tmux-drops" }
      end,
    }
    env("SSH_TTY", nil)
    env("SSH_CONNECTION", nil)
  end)
  after_each(function()
    package.loaded["xyno_clipboard"] = real
    for k, v in pairs(saved) do
      vim.env[k] = v[1]
    end
    saved = {}
  end)

  it("a local Wayland session with wl-copy / wl-paste does not warn that tmux drops OSC 52", function()
    fake_tools()
    env("WAYLAND_DISPLAY", "wayland-test")
    H.ok(clip.local_native())
    H.eq("", (clip.status()))
  end)

  it("without a Wayland session (or over SSH) the warning is shown", function()
    fake_tools()
    env("WAYLAND_DISPLAY", nil)
    H.eq("clip: tmux drops OSC52", (clip.status()))
    env("WAYLAND_DISPLAY", "wayland-test")
    env("SSH_CONNECTION", "1 2 3 4")
    local text, hl = clip.status()
    H.eq({ "clip: tmux drops OSC52", "XynoClipboardError" }, { text, hl })
  end)

  it("other hints (no tool at all) are never hidden", function()
    fake_tools()
    env("WAYLAND_DISPLAY", "wayland-test")
    package.loaded["xyno_clipboard"].statusline = function()
      return "clip: no tool", "XynoClipboardWarn"
    end
    package.loaded["xyno_clipboard"].hint = function()
      return { kind = "no-tool" }
    end
    H.eq("clip: no tool", (clip.status()))
  end)
end)
