-- Loaded with `nvim --cmd 'luafile hook.lua'` by the harness: timestamps the startup milestones
-- relative to BENCH_T0_MS (wall clock taken by the shell right before exec'ing nvim).
-- BENCH_PROBE=<file> runs that file (probe.lua) once startup is done.
-- BENCH_MODE=startup additionally writes the marks to BENCH_OUT and quits once the config is
-- fully up (lazy.nvim's VeryLazy event, or UIEnter + 500 ms for configs without it).
local uv = vim.uv
local function ts()
  local t = uv.clock_gettime("realtime")
  return t.sec * 1000 + t.nsec / 1e6
end
local t0 = tonumber(vim.env.BENCH_T0_MS) or ts()
local function mark(name)
  _G.bench_marks[name] = math.floor((ts() - t0) * 10 + 0.5) / 10
end
_G.bench_marks = {}
mark("hook_loaded")
local g = vim.api.nvim_create_augroup("bench_hook", { clear = true })
local function au(ev, cb, pat)
  vim.api.nvim_create_autocmd(ev, { group = g, pattern = pat, once = true, callback = cb })
end
local finishing = false
local function finish()
  if finishing then return end
  finishing = true
  if vim.env.BENCH_PROBE and vim.env.BENCH_PROBE ~= "" then
    -- run the probe from the main loop, after startup finished (-S would run it before VimEnter)
    vim.schedule(function()
      local ok, err = pcall(dofile, vim.env.BENCH_PROBE)
      if not ok then
        local f = io.open(vim.env.BENCH_OUT, "w")
        if f then f:write(vim.json.encode({ error = tostring(err) })) f:close() end
        vim.cmd("qa!")
      end
    end)
  elseif vim.env.BENCH_MODE == "startup" then
    local f = io.open(vim.env.BENCH_OUT, "w")
    if f then
      f:write(vim.json.encode(_G.bench_marks))
      f:close()
    end
    vim.schedule(function() vim.cmd("qa!") end)
  end
end
au("VimEnter", function() mark("vimenter") end)
au("UIEnter", function()
  mark("uienter")
  vim.defer_fn(function()
    if not _G.bench_marks.very_lazy then
      _G.bench_marks.very_lazy_missing = true
      finish()
    end
  end, 1500)
end)
au("User", function()
  mark("very_lazy")
  vim.schedule(function() mark("very_lazy_idle") finish() end)
end, "VeryLazy")
