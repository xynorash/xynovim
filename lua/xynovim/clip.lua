-- The clipboard statusline part. xyno-clipboard.nvim's hint warns "clip: tmux drops OSC52" whenever tmux ignores
-- OSC 52, even on a local Wayland session where wl-copy / wl-paste carry every yank and OSC 52 is only a
-- bonus (the plugin's newer versions stay quiet then; the pinned one does not). Same rule here, so the
-- warning only shows when the active route really is tmux + OSC 52 and tmux really drops it.
local M = {}

--- Whether a yank reaches the system clipboard without OSC 52 (local Wayland with wl-copy and wl-paste).
function M.local_native()
  return vim.env.WAYLAND_DISPLAY ~= nil
    and vim.env.SSH_TTY == nil
    and vim.env.SSH_CONNECTION == nil
    and vim.fn.executable("wl-copy") == 1
    and vim.fn.executable("wl-paste") == 1
end

local OSC52_ONLY = { ["tmux-drops"] = true, ["tmux-no-clipboard"] = true }

--- The loaded plugin, if it has a statusline().
local function plugin()
  local c = package.loaded["xyno_clipboard"]
  return c and type(c.statusline) == "function" and c or nil
end

--- text, highlight group ("" when there is nothing to say).
function M.status()
  local c = plugin()
  if not c then
    return "", nil
  end
  local text, hl = c.statusline()
  if text ~= "" and M.local_native() then
    local kind
    if type(c.hint) == "function" then
      local ok, h = pcall(c.hint)
      kind = ok and h and h.kind or nil
    elseif text:find("tmux", 1, true) then
      kind = "tmux-drops" -- a plugin version without hint(): the words say what it is
    end
    if OSC52_ONLY[kind] then
      return "", nil
    end
  end
  return text, hl
end

return M
