-- A panic stops in `rust_panic` (see rust_lldb_init in plugins/dap.lua), the right place to read the
-- locals of the panicking function, but the frame nvim-dap jumps to is the Rust runtime's: the std
-- source (`/rustc/<hash>/library/...`, usually not on disk) with the workspace frame five or six
-- frames up. After such a stop the first frame that is not runtime is selected instead. The stack
-- keeps every frame (`dap.up()`/`dap.down()` and the frames view still reach the runtime ones).
local M = {}

--- Frame of the Rust runtime or panic machinery rather than the user's code.
---@param f table dap StackFrame
function M.is_runtime(f)
  local name = f.name or ""
  local path = (f.source and f.source.path or ""):gsub("\\", "/")
  if path:find("^/rustc/") or path:find("/lib/rustlib/", 1, true) then
    return true
  end
  -- no source at all (no debuginfo): judged by name
  if path == "" or not f.source then
    return name:find("rust_panic", 1, true) ~= nil
      or name:find("^core::panicking") ~= nil
      or name:find("^std::panicking") ~= nil
      or name:find("rust_begin_unwind", 1, true) ~= nil
      or name:find("__rust_end_short_backtrace", 1, true) ~= nil
      or name:find("^<unknown>") ~= nil
  end
  return false
end

--- The frame to show for a panic stop: nil unless the top frame is the panic machinery, else the
--- first frame that is not runtime (nil when there is none).
---@param frames table[]
---@return table|nil
function M.target(frames)
  local top = frames and frames[1]
  if not (top and (top.name or ""):find("rust_panic", 1, true)) then
    return nil
  end
  for i = 2, #frames do
    if not M.is_runtime(frames[i]) and frames[i].source and frames[i].source.path then
      return frames[i]
    end
  end
  return nil
end

--- dap.listeners.after.event_stopped handler. nvim-dap fetches the stack on its own after this event
--- and selects the top frame; poll for that, then move on.
function M.on_stopped(session, body)
  local tid = body and body.threadId
  if not tid or body.reason == "pause" then
    return
  end
  local tries = 0
  local function try()
    tries = tries + 1
    local thread = session.threads and session.threads[tid]
    local frames = thread and thread.frames
    local cur = session.current_frame
    if not (frames and frames[1] and cur) then
      if tries < 60 then
        vim.defer_fn(try, 50)
      end
      return
    end
    local target = M.target(frames)
    -- only when the session still sits on the top frame it selected itself
    if target and cur.id == frames[1].id and session.stopped_thread_id == tid then
      pcall(session._frame_set, session, target)
      vim.notify(
        ("Panic: showing `%s` (the runtime frames above it are skipped, `dap.down()` reaches them)"):format(target.name),
        vim.log.levels.INFO
      )
    end
  end
  vim.defer_fn(try, 50)
end

--- Register the listener; safe to call again.
function M.setup()
  require("dap").listeners.after.event_stopped["xynovim_panic_frame"] = M.on_stopped
end

return M
