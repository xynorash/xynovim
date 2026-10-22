-- Import from a crate that is not a dependency yet (plan item 3.3, gap G5).
--
-- An import-engine source (engine.register_source, async): when rust-analyzer
-- offers nothing for an unresolved name, it proposes
--   * the crate named exactly like a lowercase name (`rand` for `rand::random()`),
--     checked in the sparse index;
--   * for other names (Rng, Utc, Uuid) the crates.io search hits whose name equals
--     or contains the lowercased name, most downloaded first, LABELLED AS GUESSES:
--     crates.io is searched by crate name, not by the items a crate exports, so
--     `Rng` finds nothing that is called "rng" in `rand`.
-- Accepting one runs crate_add's default add (newest release, no features, into
-- the package of the buffer), then waits for rust-analyzer to load the new
-- dependency (polling its import actions, bounded) and applies the import.
-- crate_add's "Add crate X" action uses the same add-and-wait path.
--
-- Everything from the network is validated (crate_meta.valid_name) before it
-- reaches an argv or a path; the engine only accepts ident paths.
local M = {}

local cm = require("xyno_rust.crate_meta")

M.config = {
  max_guesses = 3,
  min_guess_len = 3, -- shorter item names would match half of crates.io
  poll_ms = 1000,
  reload_timeout_ms = 60000,
}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "CrateImport" })
end

--- The Rust identifier of a crate name ("serde-json" -> "serde_json").
local function ident(crate)
  return (crate:gsub("-", "_"))
end

local function usable(crate)
  return type(crate) == "string" and cm.valid_name(crate) and crate:sub(1, 1) ~= "-" and ident(crate):match("^[%a_][%w_]*$") ~= nil
end

-- ----------------------------------------------------- wait and import

--- Poll rust-analyzer for an "Import ..." action of `crate_ident` at `mark`
--- (an extmark on the name) until it shows up or the time is over, then apply
--- it. cb(ok, message). Preference: the candidate's own path, then the shortest
--- path under the crate (the least surprising re-export).
function M.wait_and_import(buf, mark_ns, mark, name, spec, cb)
  local engine = require("xyno_imports.engine")
  local ca = require("xyno_rust.code_actions")
  local started = vim.uv.now()
  local poll
  local function again()
    if vim.uv.now() - started > M.config.reload_timeout_ms then
      return cb(false, ("rust-analyzer did not offer an import of %s from %s within %d s; the crate is added, try :ImportName"):format(name, spec.ident, M.config.reload_timeout_ms / 1000))
    end
    vim.defer_fn(poll, M.config.poll_ms)
  end
  poll = function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return cb(false, "buffer closed")
    end
    local m = vim.api.nvim_buf_get_extmark_by_id(buf, mark_ns, mark, { details = true })
    if not m[1] then
      return cb(false, "the name was edited away")
    end
    local line = vim.api.nvim_buf_get_lines(buf, m[1], m[1] + 1, false)[1] or ""
    if line:sub(m[2] + 1, m[2] + #name) ~= name then
      return cb(false, "the name was edited meanwhile")
    end
    local pos = { row = m[1], col = m[2], end_col = m[2] + #name }
    engine.candidates_at(buf, pos, function(cands)
      local mine = vim.tbl_filter(function(c)
        return c.crate == spec.ident
      end, cands)
      if #mine == 0 then
        return again()
      end
      table.sort(mine, function(a, b)
        if (a.path == spec.path) ~= (b.path == spec.path) then
          return a.path == spec.path
        end
        if #a.path ~= #b.path then
          return #a.path < #b.path
        end
        return a.path < b.path
      end)
      engine.apply_candidate(buf, mine[1], function(ok, err)
        cb(ok, ok and ("imported " .. mine[1].path) or err)
      end)
    end, vim.diagnostic.get(buf, { lnum = m[1] }))
  end
  -- first look immediately only if the dependency is already loaded; otherwise
  -- give cargo and rust-analyzer a moment
  vim.defer_fn(poll, M.config.poll_ms)
end

--- Add crate `spec.crate` to the package of `buf` and, when `spec.name` is a
--- name to import (not just a path head), import it once rust-analyzer knows
--- the crate. spec = { crate = "rand", ident = "rand", name = "Rng", path =
--- "rand::Rng" }; name = nil: only add. cb(ok, message).
function M.add_and_import(buf, spec, cb)
  cb = cb or function() end
  if not usable(spec.crate) then
    return cb(false, "invalid crate name")
  end
  spec.ident = spec.ident or ident(spec.crate)
  local ns = vim.api.nvim_create_namespace("xynovim_crate_import")
  local mark
  if spec.name and spec.name:match("^[%w_]+$") and vim.api.nvim_buf_is_valid(buf) then
    local pos = spec.pos
    if not pos then
      for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if not l:match("^%s*use%s") and not l:match("^%s*//") then
          local s = 1
          while true do
            local a, b = l:find(spec.name, s, true)
            if not a then
              break
            end
            if not l:sub(a - 1, a - 1):match("[%w_]") and not l:sub(b + 1, b + 1):match("[%w_]") then
              pos = { row = i - 1, col = a - 1 }
              break
            end
            s = b + 1
          end
          if pos then
            break
          end
        end
      end
    end
    if pos then
      mark = vim.api.nvim_buf_set_extmark(buf, ns, pos.row, pos.col, { right_gravity = false })
    end
  end
  require("config.crate_add").add_direct(buf, spec.crate, function(ok, msg)
    if not ok then
      return cb(false, msg)
    end
    if not mark then
      return cb(true, msg)
    end
    notify(("added %s, waiting for rust-analyzer to load it ..."):format(spec.crate))
    M.wait_and_import(buf, ns, mark, spec.name, spec, function(done, m2)
      pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
      if done then
        notify(m2)
      else
        notify(tostring(m2), vim.log.levels.WARN)
      end
      -- the crate IS added: the add succeeded even when the import did not
      cb(done, m2)
    end)
  end)
end

-- ------------------------------------------------------------ candidates

local function candidate(crate, name, extra)
  local id = ident(crate)
  local path = name and (id .. "::" .. name) or id
  return vim.tbl_extend("force", {
    path = path,
    crate = id,
    add_crate = true,
    apply = function(cb)
      M.add_and_import(extra.bufnr, { crate = crate, ident = id, name = name, path = path, pos = extra.pos }, cb)
    end,
  }, extra.fields or {})
end

local function is_dependency(meta, id)
  for _, d in ipairs(meta and cm.dependencies(meta) or {}) do
    if ident(d.rename or d.name or "") == id then
      return true
    end
  end
  return false
end

--- Engine source: fn(name, ctx, cb). Only fills gaps: nothing when
--- rust-analyzer offered candidates, or for a name that is already a dependency.
function M.source(name, ctx, cb)
  if (ctx.local_candidates and #ctx.local_candidates > 0) or ctx.crates == false then
    return cb({})
  end
  local buf = ctx.bufnr
  local pos = ctx.pos and { row = ctx.pos.row, col = ctx.pos.col } or nil
  local out = {}
  local function emit()
    cb(out)
  end
  local function with_meta(meta)
    local lname = name:lower()
    local steps = {}
    -- 1. the crate called exactly like the name (a path head: `rand::random()`)
    if name:match("^[a-z][a-z0-9_]*$") and not is_dependency(meta, name) then
      steps[#steps + 1] = function(next_)
        local variants = { name }
        if name:find("_", 1, true) then
          variants[2] = (name:gsub("_", "-"))
        end
        local i = 0
        local function try()
          i = i + 1
          if not variants[i] then
            return next_()
          end
          cm.info_async(variants[i], function(info)
            if info and usable(info.name) and ident(info.name) == name then
              out[#out + 1] = candidate(info.name, nil, {
                bufnr = buf,
                pos = pos,
                fields = { note = ("crate %s %s on crates.io"):format(info.name, info.newest or "") },
              })
              return next_()
            end
            try()
          end, { index_only = true })
        end
        try()
      end
    end
    -- 2. crates.io search by name for item names (guesses)
    if #name >= M.config.min_guess_len and not name:match("^[a-z][a-z0-9_]*$") then
      steps[#steps + 1] = function(next_)
        cm.search_async(lname, function(list)
          local hits = {}
          for _, c in ipairs(list or {}) do
            local id = usable(c.name) and ident(c.name):lower() or nil
            if id and (id == lname or id:find(lname, 1, true)) and not is_dependency(meta, ident(c.name)) then
              hits[#hits + 1] = c
            end
          end
          table.sort(hits, function(a, b)
            return (a.downloads or 0) > (b.downloads or 0)
          end)
          for i = 1, math.min(#hits, M.config.max_guesses) do
            local c = hits[i]
            out[#out + 1] = candidate(c.name, name, {
              bufnr = buf,
              pos = pos,
              fields = {
                guess = true,
                note = ("%s %s, %s downloads: crates.io search by name, the path is a guess"):format(c.name, c.version or "", c.downloads and tostring(c.downloads) or "?"),
              },
            })
          end
          next_()
        end)
      end
    end
    local i = 0
    local function run()
      i = i + 1
      if not steps[i] then
        return emit()
      end
      steps[i](run)
    end
    run()
  end
  local root = ctx.root
  if root then
    cm.metadata_async(root, function(meta)
      with_meta(meta)
    end)
  else
    with_meta(nil)
  end
end

local unregister
function M.setup()
  if unregister then
    return
  end
  unregister = require("xyno_imports.engine").register_source(M.source, { async = true })
end

return M
