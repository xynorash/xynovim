-- Tiny describe/it framework for the spec files (stdlib + vim only). One spec
-- file runs per nvim process (tests/runner.lua), so there is no isolation
-- logic here: tests run in registration order, in the one editor.
--
--   describe(name, fn)        group; fn runs at load time and registers tests
--   it(name, fn)              a test; any error fails it
--   before_each / after_each  hooks of the enclosing describe (outer first / last)
--   pending(name, reason)     a registered but skipped test
--   skip(reason)              callable from a test or hook: counts as skipped
--
-- Plenary's busted was not used: PlenaryBustedFile starts a nested nvim with
-- its own minimal init, which would not load this config, and its runner
-- cannot be given our hard timeout or the coverage hook.
local M = {}

local SKIP = {}
local root -- { name = "", tests = {}, children = {}, before = {}, after = {} }
local cur

local function new_group(name, parent)
  return { name = name, parent = parent, items = {}, before = {}, after = {} }
end

function M.skip(reason)
  error(setmetatable({ reason = reason or "skipped" }, SKIP), 0)
end

local function is_skip(e)
  return type(e) == "table" and getmetatable(e) == SKIP
end
M.is_skip = is_skip

function M.install()
  root = new_group("", nil)
  cur = root
  _G.describe = function(name, fn)
    local g = new_group(name, cur)
    table.insert(cur.items, g)
    local prev = cur
    cur = g
    local ok, err = pcall(fn)
    cur = prev
    if not ok then
      error("describe '" .. name .. "': " .. tostring(err), 0)
    end
  end
  _G.it = function(name, fn)
    table.insert(cur.items, { name = name, fn = fn, group = cur })
  end
  _G.pending = function(name, reason)
    table.insert(cur.items, { name = name, group = cur, pending = reason or "pending" })
  end
  _G.before_each = function(fn)
    table.insert(cur.before, fn)
  end
  _G.after_each = function(fn)
    table.insert(cur.after, fn)
  end
  _G.skip = M.skip
end

local function full_name(t)
  local parts = { t.name }
  local g = t.group
  while g and g.name ~= "" do
    table.insert(parts, 1, g.name)
    g = g.parent
  end
  return table.concat(parts, " > ")
end

-- Traceback without the harness's own frames.
local function trace(e)
  if is_skip(e) then
    return e
  end
  local tb = debug.traceback(type(e) == "table" and vim.inspect(e) or tostring(e), 2)
  local keep = {}
  for l in tb:gmatch("[^\n]+") do
    if
      not l:find("tests/harness.lua", 1, true)
      and not l:find("tests/runner.lua", 1, true)
      and not l:find("[C]: in function 'xpcall'", 1, true)
    then
      keep[#keep + 1] = l
    end
  end
  return table.concat(keep, "\n")
end

local function run_hooks(list, ...)
  for _, fn in ipairs(list) do
    local ok, e = xpcall(fn, trace, ...)
    if not ok then
      return false, e
    end
  end
  return true
end

--- Run everything registered; print one line per test. Returns counts.
function M.run(out)
  out = out or function(s)
    io.stdout:write(s, "\n")
    io.stdout:flush()
  end
  local n = { passed = 0, failed = 0, skipped = 0 }

  local function report(kind, name, detail, secs)
    n[kind] = n[kind] + 1
    local label = ({ passed = "ok  ", failed = "FAIL", skipped = "SKIP" })[kind]
    local line = ("%s %s"):format(label, name)
    if kind == "skipped" and detail then
      line = line .. " (" .. detail .. ")"
    end
    if secs and secs >= 1 then
      line = line .. (" [%.1fs]"):format(secs)
    end
    out(line)
    if kind == "failed" and detail then
      for l in tostring(detail):gmatch("[^\n]+") do
        out("       " .. l)
      end
    end
  end

  local function befores(g)
    local list, chain = {}, {}
    while g do
      table.insert(chain, 1, g)
      g = g.parent
    end
    for _, x in ipairs(chain) do
      vim.list_extend(list, x.before)
    end
    return list
  end
  local function afters(g)
    local list = {}
    while g do
      vim.list_extend(list, g.after)
      g = g.parent
    end
    return list
  end

  local function walk(g)
    for _, item in ipairs(g.items) do
      if item.items then
        walk(item)
      elseif item.pending then
        report("skipped", full_name(item), item.pending)
      else
        local t0 = vim.uv.hrtime()
        local name = full_name(item)
        local ok, err = run_hooks(befores(item.group))
        if ok then
          ok, err = xpcall(item.fn, trace)
        end
        -- after_each always runs; its failure only counts when the test passed
        local aok, aerr = run_hooks(afters(item.group))
        if ok and not aok then
          ok, err = false, aerr
        end
        local secs = (vim.uv.hrtime() - t0) / 1e9
        if ok then
          report("passed", name, nil, secs)
        elseif is_skip(err) then
          report("skipped", name, err.reason, secs)
        else
          report("failed", name, err, secs)
        end
      end
    end
  end
  walk(root)
  return n
end

return M
