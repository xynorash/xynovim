-- Per-file line coverage of the repo's own Lua modules.
--   nvim -l scripts/coverage.lua <repo> <dir with *.json dumps>
-- (scripts/test.sh --coverage runs it.) The dumps come from
-- tests/coverage_hook.lua: the lines that executed. The denominator is an
-- ESTIMATE of the executable lines, read from the source text: blank lines,
-- comments (also --[[ ]] blocks), lines of only `end`, `else`, `)`, `}` and
-- long-string bodies are not counted. Treat the percentages as a guide.
local repo, dir = arg[1], arg[2]
if not repo or not dir then
  io.stderr:write("usage: nvim -l scripts/coverage.lua <repo> <dump dir>\n")
  os.exit(2)
end

-- union of all dumps: rel -> { [line] = true }
local hit = {}
for _, name in ipairs(vim.fn.glob(dir .. "/*.json", false, true)) do
  local f = io.open(name)
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  if ok then
    for rel, lines in pairs(data) do
      hit[rel] = hit[rel] or {}
      for _, l in ipairs(lines) do
        hit[rel][l] = true
      end
    end
  end
end

--- Set of executable line numbers (estimate, see header).
local function executable(path)
  local set, n = {}, 0
  local in_block, in_long = false, false
  local ln = 0
  for line in io.lines(path) do
    ln = ln + 1
    local s = line
    if in_block then
      if s:find("%]%]") then
        in_block = false
      end
      s = ""
    elseif in_long then
      if s:find("%]%]") then
        in_long = false
      end
      s = ""
    else
      if s:match("^%s*%-%-%[%[") then
        in_block = not s:find("%]%]")
        s = ""
      else
        s = s:gsub("%-%-.*$", "") -- comment tail (a `--` inside a string is rare here)
        -- a line that opens a long string: the line counts, the body does not
        local a = s:find("%[%[")
        if a and not s:find("%]%]", a + 2) then
          in_long = true
        end
      end
    end
    local t = s:gsub("%s+", "")
    -- only closers / `else` / `end` / `do` / `then` / bare braces
    if
      t ~= ""
      and not t:match("^[%)%}%]%,;]*$")
      and not t:match("^[%)%}%]%,;]*end[%)%}%]%,;]*$")
      and t ~= "else"
      and t ~= "do"
      and t ~= "then"
      and t ~= "return"
    then
      set[ln] = true
      n = n + 1
    end
  end
  return set, n
end

local files = {}
local p = io.popen(("cd %q && find lua colors plugin after -name '*.lua' 2>/dev/null | sort"):format(repo))
for l in p:lines() do
  files[#files + 1] = l
end
p:close()

local rows, tot_exec, tot_hit = {}, 0, 0
for _, rel in ipairs(files) do
  local set, n = executable(repo .. "/" .. rel)
  local h = 0
  for l in pairs(hit[rel] or {}) do
    if set[l] then
      h = h + 1
    end
  end
  rows[#rows + 1] = { rel = rel, hit = h, n = n }
  tot_exec, tot_hit = tot_exec + n, tot_hit + h
end

local width = 0
for _, r in ipairs(rows) do
  width = math.max(width, #r.rel)
end
print("Line coverage (lines executed by the specs; executable lines estimated)")
for _, r in ipairs(rows) do
  local pct = r.n > 0 and (100 * r.hit / r.n) or 100
  print(("  %-" .. width .. "s  %3d/%-4d %5.1f%%"):format(r.rel, r.hit, r.n, pct))
end
print(
  ("  %-" .. width .. "s  %3d/%-4d %5.1f%%"):format(
    "TOTAL",
    tot_hit,
    tot_exec,
    tot_exec > 0 and 100 * tot_hit / tot_exec or 100
  )
)
