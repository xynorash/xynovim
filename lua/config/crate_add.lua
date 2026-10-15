-- Crates from inside the editor (plan items 1.1 and 1.2, gap G3):
--   * an unknown-crate check: a treesitter scan of `use` paths and expression /
--     type / attribute paths whose first segment is not known (std, a
--     dependency of the file's package, the own crate, a local module, an
--     import, ...) becomes a HINT diagnostic "crate 'rand' is not a
--     dependency" (namespace xynovim-crates, source xynovim) with the code
--     action "Add crate rand";
--   * :CrateAdd [query] (<leader>rA): search crates.io, pick the features, pick
--     the target, run `cargo add`.
--
-- The code action is served by a tiny in-process LSP server (vim.lsp.config
-- with a `cmd` function, no process) rather than by wrapping
-- vim.lsp.buf.code_action: every consumer of the LSP code-action API (<leader>ca,
-- the lightbulb, vim.lsp.buf.code_action with a filter, code_actions.lua)
-- then sees it as one more client, nothing is monkey-patched, and the
-- diagnostics and the actions stay in one place. It declares codeAction and
-- executeCommand only, so it takes part in nothing else (no formatting,
-- hover, completion, semantic tokens).
--
-- False positives are worse than misses: the rule set is conservative, see
-- M.scan. Everything that runs a command uses argv lists, and crate names,
-- feature names and package names are validated before they reach one.
local M = {}

local cm = require("config.crate_meta")

M.config = {
  debounce_ms = 300,
  max_diagnostics = 50, -- per buffer
  cargo_timeout_ms = 180000,
}

M.ns = vim.api.nvim_create_namespace("xynovim-crates")
M.server_name = "xynovim-crates"
local CMD_ADD, CMD_PICK = "xynovim.crateAdd", "xynovim.crateAddPick"

-- ------------------------------------------------------------- the scan

-- first segments that are never crates: tool attributes (#[rustfmt::skip],
-- #[clippy::...]) and primitive types (u32::MAX)
local NEVER = {}
for _, n in ipairs(vim.split("rustfmt clippy rustc rustdoc miri rust_analyzer diagnostic u8 u16 u32 u64 u128 usize i8 i16 i32 i64 i128 isize f32 f64 bool char str", " ")) do
  NEVER[n] = true
end

local function text(node, buf)
  return vim.treesitter.get_node_text(node, buf)
end

local function field(node, name)
  return node:field(name)[1]
end

--- The leftmost segment of a use tree when it is a plain identifier reached
--- through a path (`rand` of `rand::Rng`, of `rand::{a, b}`, of `rand::*`,
--- of `rand::x as y`); bare `use foo;` and `crate` / `self` / `super` give nil.
local function use_head(n)
  local t = n:type()
  if t == "scoped_identifier" or t == "scoped_use_list" or t == "use_as_clause" then
    local p = field(n, "path") or (t == "use_as_clause" and n:named_child(0)) or nil
    if not p then
      return nil
    end
    if p:type() == "identifier" then
      return t ~= "use_as_clause" and p or nil
    end
    return use_head(p)
  elseif t == "use_wildcard" then
    local c = n:named_child(0)
    if c and c:type() == "scoped_identifier" then
      return use_head(c)
    elseif c and c:type() == "identifier" then
      return c
    end
  end
  return nil
end

--- Names a use tree binds (alias or last segment; `self` binds its parent's
--- last segment). Wildcards are collected in `globs` (the first path token).
local function use_bound(n, buf, out, globs, last, top)
  local t = n:type()
  if t == "identifier" then
    out[text(n, buf)] = true
  elseif t == "scoped_identifier" then
    out[text(field(n, "name"), buf)] = true
  elseif t == "use_as_clause" then
    local a = field(n, "alias")
    if a then
      out[text(a, buf)] = true
    end
  elseif t == "scoped_use_list" then
    local p = field(n, "path")
    local l = field(n, "list")
    local plast = p and (p:type() == "identifier" and text(p, buf) or (p:type() == "scoped_identifier" and text(field(p, "name"), buf))) or nil
    -- a wildcard inside the list (`a::{b::*}`) comes from the outer head
    local h = p
    while h and h:type() == "scoped_identifier" do
      h = field(h, "path")
    end
    if l then
      use_bound(l, buf, out, globs, plast, top or (h and text(h, buf)))
    end
  elseif t == "use_list" then
    for c in n:iter_children() do
      if c:named() then
        if c:type() == "self" then
          if last then
            out[last] = true
          end
        else
          use_bound(c, buf, out, globs, last, top)
        end
      end
    end
  elseif t == "use_wildcard" then
    local c = n:named_child(0)
    local head = c
    while head and head:type() == "scoped_identifier" do
      head = field(head, "path")
    end
    globs[#globs + 1] = { head = top or (head and text(head, buf)) or "", node = n }
  end
end

local function inside(node, types)
  local p = node:parent()
  while p do
    if types[p:type()] then
      return true
    end
    p = p:parent()
  end
  return false
end

local function has_ancestor_mod(node)
  return inside(node, { mod_item = true })
end

--- Is this the buffer of a file the check applies to (a .rs file of a
--- package, not dependency sources or build output)?
function M.applicable_file(file)
  if file == "" or not file:match("%.rs$") then
    return false
  end
  if file:find("/.cargo/registry/", 1, true) or file:find("/.cargo/git/", 1, true) or file:find("/target/", 1, true) then
    return false
  end
  return true
end

--- Scan buffer `bufnr` and return the unknown crate heads:
--- { { name, lnum, col, end_col } ... } (0-based), or nil when the check does
--- not apply (no rust parser, not a member file, edition 2015, a glob import
--- of something that could bring any name into scope).
---
--- NOT flagged (each is a miss in the worst case, never a false error):
---   * std / core / alloc / proc_macro / test, `crate` `self` `super`, and
---     anything crate_meta.is_known_path_head knows: dependencies of THIS
---     package (renames by their alias, dev- and build-dependencies, target-
---     specific ones), the package's own lib name, modules (`mod x`, x.rs,
---     x/mod.rs), local items, macro_rules names
---   * names bound by a `use` anywhere in the file (`use std::io; io::x()`,
---     `use foo as bar`), `extern crate foo [as bar]`
---   * heads starting with an uppercase letter (types, enum variants, Self),
---     lowercase generic parameters, primitive types, tool attributes
---   * everything inside macro_rules! definitions and macro arguments (the
---     tokens are not parsed paths)
---   * the whole file when it has a glob import from the own crate or from
---     another file (`use crate::prelude::*`, `use super::*` of a file module):
---     the glob may bring modules into scope. `use super::*` inside an inline
---     `mod tests {}` is fine: its names are in this file.
---   * edition 2015 packages (paths are relative to the crate root there)
function M.scan(bufnr, meta)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if not M.applicable_file(file) or not meta then
    return nil
  end
  local member = cm.member_of(meta, file)
  if not member then
    return nil
  end
  for _, t in ipairs(member.targets or {}) do
    if t.edition == "2015" then
      return nil
    end
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "rust")
  if not ok or not parser then
    return nil
  end
  local tree = parser:parse()[1]
  if not tree then
    return nil
  end
  local root = tree:root()

  local known_local = {} -- names bound by use / extern crate / generics
  local globs = {}
  local heads = {} -- { node, name }
  local function walk(n)
    local t = n:type()
    if t == "macro_definition" or t == "token_tree" or t == "ERROR" then
      return
    end
    if t == "use_declaration" then
      local arg = field(n, "argument") or n:named_child(n:named_child_count() - 1)
      if arg then
        use_bound(arg, bufnr, known_local, globs)
        if arg:type() == "use_list" then
          for c in arg:iter_children() do
            if c:named() then
              local h = use_head(c)
              if h then
                heads[#heads + 1] = h
              end
            end
          end
        else
          local h = use_head(arg)
          if h then
            heads[#heads + 1] = h
          end
        end
      end
      return
    elseif t == "extern_crate_declaration" then
      for c in n:iter_children() do
        if c:type() == "identifier" then
          known_local[text(c, bufnr)] = true
        end
      end
      return
    elseif t == "type_parameter" or t == "const_parameter" then
      local c = field(n, "name") or n:named_child(0)
      if c then
        known_local[text(c, bufnr)] = true
      end
    elseif t == "scoped_identifier" or t == "scoped_type_identifier" then
      local p = field(n, "path")
      if p and p:type() == "identifier" then
        heads[#heads + 1] = p
      end
    end
    for c in n:iter_children() do
      if c:named() then
        walk(c)
      end
    end
  end
  walk(root)

  local rootdir = meta.root
  local memo = {}
  local function known(name)
    if memo[name] == nil then
      memo[name] = cm.is_known_path_head(rootdir, name, { file = file, meta = meta }) ~= nil
    end
    return memo[name]
  end

  for _, g in ipairs(globs) do
    local h = g.head
    local harmless = h == "std" or h == "core" or h == "alloc" or h:match("^%u") ~= nil
    if not harmless and (h == "super" or h == "self") and has_ancestor_mod(g.node) then
      harmless = true
    end
    if not harmless and h ~= "" and h ~= "crate" and h ~= "super" and h ~= "self" then
      local kind = cm.is_known_path_head(rootdir, h, { file = file, meta = meta })
      harmless = kind == "dependency"
    end
    if not harmless then
      return {}
    end
  end

  local hits, seen = {}, {}
  for _, h in ipairs(heads) do
    local name = text(h, bufnr)
    local r, c, _, ec = h:range()
    if
      not NEVER[name]
      and not known_local[name]
      and not name:match("^%u")
      and cm.valid_name(name)
      and not name:find("-", 1, true)
      and not known(name)
      and not seen[r .. ":" .. c]
    then
      seen[r .. ":" .. c] = true
      hits[#hits + 1] = { name = name, lnum = r, col = c, end_col = ec }
      if #hits >= M.config.max_diagnostics then
        break
      end
    end
  end
  return hits
end

-- --------------------------------------------------------- diagnostics

local function enabled()
  return vim.g.xynovim_crate_check ~= false
end

--- Re-scan one buffer now (metadata is cached by crate_meta; the first call
--- of a workspace runs cargo metadata). cb(hits | nil) when done.
function M.refresh(bufnr, cb)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  if not enabled() or not M.applicable_file(file) then
    vim.diagnostic.reset(M.ns, bufnr)
    return cb and cb(nil)
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local root = cm.root(file)
  if not root then
    return cb and cb(nil)
  end
  cm.metadata_async(root, function(meta)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
      return M.schedule(bufnr) -- typed meanwhile: the next scan sees the new text
    end
    if not meta then
      -- cargo metadata failed (broken manifest, no network for a first
      -- resolve): say nothing rather than call every crate unknown
      vim.diagnostic.reset(M.ns, bufnr)
      return cb and cb(nil)
    end
    local ok, hits = pcall(M.scan, bufnr, meta)
    if not ok or not hits then
      vim.diagnostic.reset(M.ns, bufnr)
      return cb and cb(nil)
    end
    local ds = {}
    for _, h in ipairs(hits) do
      ds[#ds + 1] = {
        lnum = h.lnum,
        col = h.col,
        end_lnum = h.lnum,
        end_col = h.end_col,
        severity = vim.diagnostic.severity.HINT,
        source = "xynovim",
        code = "unknown-crate",
        message = ("crate '%s' is not a dependency"):format(h.name),
        user_data = { xynovim_crate = h.name },
      }
    end
    vim.diagnostic.set(M.ns, bufnr, ds)
    if cb then
      cb(hits)
    end
  end)
end

local timers = {}
--- Debounced refresh (one timer per buffer).
function M.schedule(bufnr, delay)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local t = timers[bufnr]
  if not t then
    t = assert(vim.uv.new_timer())
    timers[bufnr] = t
  end
  t:stop()
  t:start(
    delay or M.config.debounce_ms,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.refresh(bufnr)
      end
    end)
  )
end

local function refresh_all()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "rust" then
      M.schedule(b)
    end
  end
end

-- ----------------------------------------------------------- cargo add

local FEATURE_PAT = "^[A-Za-z0-9_.+-]+$"

--- spec = { name, features = {}, default_features = true|false, kind =
--- "normal"|"dev"|"build", package = member name, offline = bool }.
--- Returns the argv, or nil + a reason. Version is left to cargo (it picks the
--- newest release compatible with the package's rust-version).
function M.build_argv(spec)
  -- valid_name allows a leading "-": `cargo add --git` would be a flag
  if not cm.valid_name(spec.name) or spec.name:sub(1, 1) == "-" then
    return nil, "invalid crate name"
  end
  local argv = { "cargo", "add", spec.name }
  if spec.package ~= nil then
    if not cm.valid_name(spec.package) then
      return nil, "invalid package name"
    end
    vim.list_extend(argv, { "-p", spec.package })
  end
  if spec.kind == "dev" then
    argv[#argv + 1] = "--dev"
  elseif spec.kind == "build" then
    argv[#argv + 1] = "--build"
  elseif spec.kind ~= nil and spec.kind ~= "normal" then
    return nil, "invalid dependency kind"
  end
  if spec.default_features == false then
    argv[#argv + 1] = "--no-default-features"
  end
  if spec.features and #spec.features > 0 then
    for _, f in ipairs(spec.features) do
      if type(f) ~= "string" or not f:match(FEATURE_PAT) then
        return nil, "invalid feature name"
      end
    end
    vim.list_extend(argv, { "-F", table.concat(spec.features, ",") })
  end
  if spec.offline then
    argv[#argv + 1] = "--offline"
  end
  return argv
end

--- The manifest line `cargo add` wrote for `name` in the table of `kind`.
local HEADERS = { normal = "dependencies", dev = "dev-dependencies", build = "build-dependencies" }
function M.added_line(manifest, name, kind)
  local f = io.open(manifest, "r")
  if not f then
    return nil
  end
  local want = HEADERS[kind or "normal"]
  local section
  for l in f:lines() do
    local h = l:match("^%s*%[([^%]]+)%]")
    if h then
      section = h
    elseif section == want or (section and section:match("^target%..*%." .. want .. "$")) then
      local key = l:match("^%s*([%w_.-]+)%s*=")
      if key and (key == name or key:match("^" .. vim.pesc(name) .. "%.")) then
        f:close()
        return vim.trim(l)
      end
    end
  end
  f:close()
end

--- Does [workspace.dependencies] of the workspace root list `name`? (cargo
--- add then writes `name.workspace = true` into a member by itself.)
function M.in_workspace_table(root, name)
  local f = io.open(root .. "/Cargo.toml", "r")
  if not f then
    return false
  end
  local section
  local found = false
  for l in f:lines() do
    local h = l:match("^%s*%[([^%]]+)%]")
    if h then
      section = h
      if h == "workspace.dependencies." .. name then
        found = true
      end
    elseif section == "workspace.dependencies" then
      local key = l:match("^%s*([%w_.-]+)%s*=")
      if key == name or (key and key:match("^" .. vim.pesc(name) .. "%.")) then
        found = true
      end
    end
  end
  f:close()
  return found
end

local function notify(msg, level, id)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "CrateAdd", id = id or "xynovim-crate-add" })
end

--- Run cargo add (async) for `spec` (see build_argv) in workspace `root`.
--- spec.manifest (member manifest, for the report). cb(ok, message).
function M.run_add(root, spec, cb)
  local argv, err = M.build_argv(spec)
  if not argv then
    notify("cannot add: " .. err, vim.log.levels.ERROR)
    return cb and cb(false, err)
  end
  notify("cargo add " .. table.concat(vim.list_slice(argv, 3), " ") .. " ...")
  cm.exec(argv, { cwd = root, timeout = M.config.cargo_timeout_ms }, function(r)
    cm.invalidate(root)
    if r.code ~= 0 then
      local msg = vim.trim(r.stderr) ~= "" and vim.trim(r.stderr) or ("cargo add exited " .. r.code)
      if msg:find("index", 1, true) and (msg:find("resolve", 1, true) or msg:find("network", 1, true) or msg:find("download", 1, true)) then
        msg = msg .. "\n(offline? cargo could not reach the registry; the crate may be added with --offline once it is cached)"
      end
      notify("cargo add failed:\n" .. msg, vim.log.levels.ERROR)
      return cb and cb(false, msg)
    end
    local line = spec.manifest and M.added_line(spec.manifest, spec.name, spec.kind)
    local where = ("[%s]%s"):format(HEADERS[spec.kind or "normal"], spec.package and (" of " .. spec.package) or "")
    local msg = line and ("added %s  (%s)"):format(line, where) or ("added %s to %s"):format(spec.name, where)
    notify(msg)
    -- no BufWritePost ran for this edit: restart bacon-ls (and show "deps resolving") like a
    -- save would, or its stale E0433 / "cannot find derive macro" errors stay for minutes
    pcall(require("config.rust_restart").manifest_saved, spec.manifest or (root .. "/Cargo.toml"))
    refresh_all()
    if cb then
      cb(true, msg, line)
    end
  end)
end

-- ------------------------------------------------------------------ UI

--- Seam for the pickers (specs replace M.ui.pick). spec = { title, items =
--- { { text, display, preselect? } }, multi = bool }; cb(selected items).
M.ui = {}
function M.ui.pick(spec, cb)
  Snacks.picker({
    title = spec.title,
    items = spec.items,
    format = function(item)
      return { { item.display or item.text } }
    end,
    layout = { preset = "select" },
    on_show = function(p)
      for _, it in ipairs(spec.items) do
        if it.preselect then
          p.list:select(it)
        end
      end
    end,
    confirm = function(p, item)
      -- multi: exactly what is ticked, also nothing (`default` unticked and no
      -- feature ticked means --no-default-features); a plain pick: the item
      local sel = spec.multi and p:selected() or { item }
      p:close()
      if spec.multi or sel[1] then
        cb(sel)
      end
    end,
  })
end

function M.ui.input(prompt, cb)
  vim.ui.input({ prompt = prompt }, function(v)
    if v and vim.trim(v) ~= "" then
      cb(vim.trim(v))
    end
  end)
end

local function human(n)
  n = tonumber(n)
  if not n then
    return "?"
  elseif n >= 1e9 then
    return ("%.1fG"):format(n / 1e9)
  elseif n >= 1e6 then
    return ("%.1fM"):format(n / 1e6)
  elseif n >= 1e3 then
    return ("%.0fk"):format(n / 1e3)
  end
  return tostring(n)
end

local function one_line(s, n)
  s = tostring(s or ""):gsub("%s+", " ")
  return #s > n and (s:sub(1, n - 1) .. "...") or s
end

--- Features of `info` as picker items: `default` first (preselected), then
--- alphabetical, each with its dependency list.
function M.feature_items(info)
  local names = vim.tbl_keys(info.features or {})
  table.sort(names, function(a, b)
    if (a == "default") ~= (b == "default") then
      return a == "default"
    end
    return a < b
  end)
  local items = {}
  for _, n in ipairs(names) do
    local deps = info.features[n]
    local d = #deps > 0 and table.concat(deps, ", ") or "(no dependencies)"
    local label = n == "default" and "default  (on by default: deselect for --no-default-features)" or n
    items[#items + 1] = {
      text = n .. " " .. d,
      display = ("%-24s %s"):format(label, d),
      feature = n,
      preselect = n == "default",
    }
  end
  return items
end

--- Target choices for the package(s) of `meta`: { { member, kind, text } }.
--- `current` is the member of the buffer (listed first).
function M.target_items(meta, root, name, current)
  local members = vim.list_slice(meta.members)
  table.sort(members, function(a, b)
    if (a.name == current) ~= (b.name == current) then
      return a.name == current
    end
    return a.name < b.name
  end)
  local inherit = M.in_workspace_table(root, name)
  local items = {}
  for _, m in ipairs(members) do
    for _, k in ipairs({ "normal", "dev", "build" }) do
      local tbl = HEADERS[k]
      local extra = (k == "normal" and inherit) and "  (inherits [workspace.dependencies])" or ""
      local lead = #members > 1 and (m.name .. "  ") or ""
      items[#items + 1] = {
        text = ("%s[%s]"):format(lead, tbl),
        display = ("%s[%s]%s"):format(lead, tbl, extra),
        member = m,
        kind = k,
      }
    end
  end
  return items
end

--- Steps 3 and 4 of the flow: features, target, run. `ctx` = { root, meta,
--- file, offline }.
local function choose_and_add(name, info, ctx, cb)
  local function target_step(features, default_on)
    local items = M.target_items(ctx.meta, ctx.meta.root or ctx.root, name, ctx.current)
    M.ui.pick({ title = "Add " .. name .. " to", items = items }, function(sel)
      local t = sel[1]
      M.run_add(ctx.root, {
        name = name,
        features = features,
        default_features = default_on,
        kind = t.kind,
        package = t.member.name,
        manifest = t.member.manifest_path,
        offline = ctx.offline,
      }, cb)
    end)
  end
  local fitems = info and M.feature_items(info) or {}
  if #fitems == 0 then
    return target_step({}, true)
  end
  M.ui.pick({
    title = ("Features of %s %s  (Tab: toggle, Enter: confirm)"):format(name, info.newest or ""),
    items = fitems,
    multi = true,
  }, function(sel)
    local features, default_on = {}, false
    for _, it in ipairs(sel) do
      if it.feature == "default" then
        default_on = true
      else
        features[#features + 1] = it.feature
      end
    end
    -- a crate without a `default` feature has nothing to switch off
    if not (info.features and info.features.default) then
      default_on = true
    end
    target_step(features, default_on)
  end)
end

--- :CrateAdd [query]. cb(ok, message) when the add finished (specs).
function M.add(query, cb)
  local file = vim.api.nvim_buf_get_name(0)
  local root = cm.root(file ~= "" and file or vim.uv.cwd())
  if not root then
    return notify("not in a cargo workspace (no Cargo.toml above " .. (file ~= "" and file or vim.uv.cwd()) .. ")", vim.log.levels.WARN)
  end
  local function with_query(q)
    notify("searching crates.io for '" .. q .. "' ...")
    cm.search_async(q, function(list, err)
      if not list then
        return notify(("crates.io search failed: %s\n(offline: results appear here again once a search has been cached)"):format(err), vim.log.levels.ERROR)
      end
      if #list == 0 then
        return notify("no crate matches '" .. q .. "'", vim.log.levels.WARN)
      end
      local items = {}
      for _, c in ipairs(list) do
        items[#items + 1] = {
          text = c.name .. " " .. (c.description or ""),
          display = ("%-26s %-10s %7s  %s"):format(c.name, c.version or "?", human(c.downloads), one_line(c.description, 80)),
          crate = c,
        }
      end
      local stale = list.stale or list.from_cache
      M.ui.pick({
        title = ("crates.io: %s%s  (name, version, downloads)"):format(q, list.stale and "  [cached, offline?]" or ""),
        items = items,
      }, function(sel)
        local name = sel[1].crate.name
        cm.info_async(name, function(info, ierr)
          local offline = (stale or (info and info.stale)) and true or false
          if not info then
            notify(("no feature list for %s (%s); adding with defaults"):format(name, ierr), vim.log.levels.WARN)
          end
          cm.metadata_async(root, function(meta, merr)
            if not meta then
              return notify("cargo metadata failed: " .. tostring(merr), vim.log.levels.ERROR)
            end
            local member = file ~= "" and cm.member_of(meta, file) or nil
            choose_and_add(name, info, {
              root = root,
              meta = meta,
              current = member and member.name or nil,
              offline = offline,
            }, cb)
          end)
        end)
      end)
    end)
  end
  if query and vim.trim(query) ~= "" then
    with_query(vim.trim(query))
  else
    M.ui.input("Search crates.io: ", with_query)
  end
end

--- The code action "Add crate rand": newest release, no features, into
--- [dependencies] (or [dev-dependencies] for files of tests/, benches/,
--- examples/) of the package of the buffer.
function M.add_direct(bufnr, name, cb)
  local file = vim.api.nvim_buf_get_name(bufnr)
  local root = cm.root(file)
  if not root then
    return cb and cb(false, "not in a cargo workspace")
  end
  cm.metadata_async(root, function(meta, err)
    local member = meta and cm.member_of(meta, file)
    if not member then
      notify("cannot add " .. name .. ": " .. tostring(err or "file is not in a workspace member"), vim.log.levels.ERROR)
      return cb and cb(false, err)
    end
    local rel = file:sub(#member.dir + 2)
    local kind = (rel:match("^tests/") or rel:match("^benches/") or rel:match("^examples/")) and "dev" or "normal"
    M.run_add(root, { name = name, kind = kind, package = member.name, manifest = member.manifest_path }, function(ok, msg)
      if ok then
        M.schedule(bufnr, 50)
      end
      if cb then
        cb(ok, msg)
      end
    end)
  end)
end

-- ------------------------------------------------- the in-process server

local function byte_pos(bufnr, pos)
  local line = vim.api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1] or ""
  local ok, b = pcall(vim.str_byteindex, line, "utf-16", pos.character, false)
  return { pos.line, ok and b or pos.character }
end

local function before(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
end

--- Code actions for the range of a codeAction request.
function M.actions_for(bufnr, range)
  local from, to = byte_pos(bufnr, range.start), byte_pos(bufnr, range["end"])
  local actions, done = {}, {}
  for _, d in ipairs(vim.diagnostic.get(bufnr, { namespace = M.ns })) do
    local name = d.user_data and d.user_data.xynovim_crate
    if name and not done[name] then
      local ds, de = { d.lnum, d.col }, { d.end_lnum or d.lnum, d.end_col or d.col }
      if not before(to, ds) and not before(de, from) then
        done[name] = true
        local diag = {
          range = {
            start = { line = d.lnum, character = d.col },
            ["end"] = { line = d.end_lnum or d.lnum, character = d.end_col or d.col },
          },
          message = d.message,
          severity = d.severity,
          source = d.source,
          code = d.code,
        }
        actions[#actions + 1] = {
          title = "Add crate " .. name,
          kind = "quickfix",
          isPreferred = true,
          diagnostics = { diag },
          command = { title = "Add crate " .. name, command = CMD_ADD, arguments = { { name = name, bufnr = bufnr } } },
        }
        actions[#actions + 1] = {
          title = "Add crate " .. name .. " (choose features and target)",
          kind = "quickfix",
          diagnostics = { diag },
          command = { title = "Add crate " .. name, command = CMD_PICK, arguments = { { name = name, bufnr = bufnr } } },
        }
      end
    end
  end
  return actions
end

--- vim.lsp.rpc-style in-process server (cmd function of vim.lsp.config).
function M.server(dispatchers)
  local closing = false
  local id = 0
  local srv = {}
  local function reply(cb, err, result)
    vim.schedule(function()
      cb(err, result)
    end)
  end
  function srv.request(method, params, cb)
    id = id + 1
    if method == "initialize" then
      reply(cb, nil, {
        capabilities = {
          codeActionProvider = { codeActionKinds = { "quickfix" } },
          executeCommandProvider = { commands = { CMD_ADD, CMD_PICK } },
        },
        serverInfo = { name = M.server_name },
      })
    elseif method == "textDocument/codeAction" then
      local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
      reply(cb, nil, vim.api.nvim_buf_is_valid(bufnr) and M.actions_for(bufnr, params.range) or {})
    elseif method == "workspace/executeCommand" then
      local arg = params.arguments and params.arguments[1] or {}
      if type(arg.name) == "string" and cm.valid_name(arg.name) and arg.name:sub(1, 1) ~= "-" and type(arg.bufnr) == "number" and vim.api.nvim_buf_is_valid(arg.bufnr) then
        if params.command == CMD_ADD then
          -- one add path for the diagnostic action and the import picker
          require("config.crate_import").add_and_import(arg.bufnr, { crate = arg.name })
        elseif params.command == CMD_PICK then
          vim.api.nvim_buf_call(arg.bufnr, function()
            M.add(arg.name)
          end)
        end
      end
      reply(cb, nil, vim.NIL)
    else
      reply(cb, nil, vim.NIL)
    end
    return true, id
  end
  function srv.notify(method)
    if method == "exit" then
      closing = true
    end
    return true
  end
  function srv.is_closing()
    return closing
  end
  function srv.terminate()
    closing = true
  end
  return srv
end

-- ---------------------------------------------------------------- setup

local did_setup = false
function M.setup()
  if did_setup then
    return
  end
  did_setup = true

  vim.lsp.config(M.server_name, {
    cmd = M.server,
    filetypes = { "rust" },
    -- one client per package, none for dependency sources and build output
    root_dir = function(bufnr, on_dir)
      local f = vim.api.nvim_buf_get_name(bufnr)
      if enabled() and M.applicable_file(f) then
        local r = vim.fs.root(f, "Cargo.toml")
        if r then
          on_dir(r)
        end
      end
    end,
  })
  vim.lsp.enable(M.server_name)

  local group = vim.api.nvim_create_augroup("xynovim-crate-add", { clear = true })
  vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged", "BufWritePost", "BufReadPost" }, {
    group = group,
    pattern = "*.rs",
    callback = function(a)
      if vim.bo[a.buf].filetype == "rust" or a.event == "BufReadPost" then
        M.schedule(a.buf)
      end
    end,
  })
  -- a new or changed dependency list: rescan what is open
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "Cargo.toml", "Cargo.lock" },
    callback = function()
      cm.invalidate()
      refresh_all()
    end,
  })
  -- auto-save writes with noautocmd, so BufWritePost never fires for it
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AutoSaveWritePost",
    callback = function(a)
      local b = a.data and a.data.saved_buffer
      if not (b and vim.api.nvim_buf_is_valid(b)) then
        return
      end
      local base = vim.fs.basename(vim.api.nvim_buf_get_name(b))
      if base == "Cargo.toml" or base == "Cargo.lock" then
        cm.invalidate()
        refresh_all()
      elseif vim.bo[b].filetype == "rust" then
        M.schedule(b)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(a)
      local t = timers[a.buf]
      if t then
        t:stop()
        t:close()
        timers[a.buf] = nil
      end
    end,
  })

  vim.api.nvim_create_user_command("CrateAdd", function(a)
    M.add(a.args)
  end, { nargs = "?", desc = "Search crates.io and cargo add (features, target)" })

  -- <leader>rA: buffer-local in Rust and Cargo.toml buffers only (keymaps.lua parks
  -- global "not bound" stubs on every <leader>r key and the specs allow no other global one)
  local function map(buf)
    vim.keymap.set("n", "<leader>rA", "<cmd>CrateAdd<cr>", { buffer = buf, desc = "Add crate (crates.io search)" })
  end
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "rust", "toml" },
    callback = function(a)
      if a.match == "rust" or vim.fs.basename(a.file) == "Cargo.toml" then
        map(a.buf)
      end
    end,
  })
  vim.schedule(function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "rust" then
        map(b)
        M.schedule(b)
      end
    end
  end)
end

return M
