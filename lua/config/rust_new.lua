-- New Rust projects: :RustNewBin [name], :RustNewLib [name], :RustNewWorkspace [name],
-- :RustNewMember [name] and the three dashboard entries 'New Rust Binary', 'New Rust Library',
-- 'New Rust Workspace' (lua/plugins/rust-new.lua). The older :RustNew (rust_tasks.lua) stays.
--
-- A binary / library is `cargo new --vcs git` in the chosen parent directory. cargo has no
-- one-step workspace command, so the workspace is built here: <parent>/<name>/Cargo.toml
-- ([workspace] with members = ["crates/*"], [workspace.package] with version and the edition
-- THIS cargo uses for new projects, an empty [workspace.dependencies]), .gitignore (/target),
-- the first member made by `cargo new --vcs none crates/<member>` whose version and edition
-- then inherit from the workspace, and `git init -b main` (no commit).
--
-- Options: vim.g.xynovim_projects_dir (parent directory, default ~/projects if it exists, else the cwd).
--
-- The text functions (M.name .. M.add_member_path) are pure; every external command is an argv
-- list run asynchronously (the coroutine helpers of config.egui_new); nothing is left behind
-- when a step fails.
local E = require("config.egui_new")

local M = {}

local NOTIFY_ID = "xynovim_rust_new"
local LABEL = "RustNew"

-- ------------------------------------------------------------- pure functions

--- Validate a package name with cargo's rules (config.egui_new.cargo_name) and the one extra
--- rule that a name must not start with '-' (cargo would take it as an option).
--- Returns name, crate, note (crate: the library's identifier) or nil, reason.
function M.name(raw)
  local name = vim.trim(raw or "")
  local crate, why = E.cargo_name(name)
  if not crate then
    return nil, why
  end
  if not name:match("^[%a_]") then
    return nil, "the name must start with a letter or '_'"
  end
  return name, crate
end

--- The note shown for a library whose name has hyphens, or nil.
function M.lib_note(name, crate)
  if crate ~= name then
    return ("library crate name: %s (use %s in Rust code)"):format(crate, crate)
  end
end

--- The first line of a command's stderr that says what failed (an `error` line, else the first).
function M.first_line(stderr)
  local first
  for line in (stderr or ""):gmatch("[^\r\n]+") do
    line = vim.trim(line)
    if line ~= "" then
      first = first or line
      if line:match("^error") then
        return line
      end
    end
  end
  return first or "no output"
end

--- Edition of the [package] table of a cargo-generated Cargo.toml, or nil.
function M.parse_edition(text)
  local in_package = false
  for line in (text or ""):gmatch("[^\r\n]+") do
    local header = line:match("^%s*%[([^%]]*)%]")
    if header then
      in_package = vim.trim(header) == "package"
    elseif in_package then
      local e = line:match('^%s*edition%s*=%s*"(%d+)"')
      if e then
        return e
      end
    end
  end
end

--- The resolver that goes with an edition: "3" for 2024 and newer, else "2".
function M.resolver(edition)
  return (tonumber(edition) or 0) >= 2024 and "3" or "2"
end

--- The workspace's Cargo.toml.
function M.workspace_toml(edition)
  return table.concat({
    "[workspace]",
    ('resolver = "%s"'):format(M.resolver(edition)),
    'members = ["crates/*"]',
    "",
    "[workspace.package]",
    'version = "0.1.0"',
    ('edition = "%s"'):format(edition),
    "",
    "[workspace.dependencies]",
    "",
  }, "\n")
end

--- Make `version` and `edition` of the [package] table inherit from the workspace; nothing else
--- changes. which: { version = bool, edition = bool } (default both).
function M.inherit(text, which)
  which = which or { version = true, edition = true }
  local out, in_package = {}, false
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local header = line:match("^%s*%[([^%]]*)%]")
    if header then
      in_package = vim.trim(header) == "package"
    elseif in_package then
      for _, key in ipairs({ "version", "edition" }) do
        if which[key] then
          local indent, rest = line:match("^(%s*)" .. key .. '%s*=%s*"[^"]*"(.*)$')
          if indent then
            line = indent .. key .. ".workspace = true" .. rest
          end
        end
      end
    end
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

--- Find the `members = [...]` array of the [workspace] table: returns the list of strings and the
--- byte range { first = index of '[', last = index of ']' } in `text`; or nil, reason.
local function members_array(text)
  local pos, in_ws = 1, false
  while pos <= #text do
    local eol = text:find("\n", pos, true) or (#text + 1)
    local line = text:sub(pos, eol - 1)
    local header = line:match("^%s*%[([^%]]*)%]")
    if header then
      in_ws = vim.trim(header) == "workspace"
    elseif in_ws then
      local before = line:match("^(%s*members%s*=%s*)%[")
      if before then
        local first = pos + #before
        local list, quote, i = {}, nil, first + 1
        local cur
        while i <= #text do
          local c = text:sub(i, i)
          if quote then
            if c == "\\" and quote == '"' then
              cur = cur .. text:sub(i, i + 1)
              i = i + 1
            elseif c == quote then
              list[#list + 1] = cur
              quote, cur = nil, nil
            else
              cur = cur .. c
            end
          elseif c == '"' or c == "'" then
            quote, cur = c, ""
          elseif c == "#" then
            i = (text:find("\n", i, true) or #text) -- a comment up to the end of the line
          elseif c == "]" then
            return list, { first = first, last = i }
          end
          i = i + 1
        end
        return nil, "the members list of [workspace] is not closed"
      end
    end
    pos = eol + 1
  end
  return nil, "no `members = [...]` list in [workspace]"
end

--- The `[workspace.package]` keys of a Cargo.toml: { version = bool, edition = bool }.
local function workspace_package_keys(text)
  local keys, in_pkg = {}, false
  for line in text:gmatch("[^\r\n]+") do
    local header = line:match("^%s*%[([^%]]*)%]")
    if header then
      in_pkg = vim.trim(header) == "workspace.package"
    elseif in_pkg then
      for _, k in ipairs({ "version", "edition" }) do
        if line:match("^%s*" .. k .. "%s*=") then
          keys[k] = true
        end
      end
    end
  end
  return keys
end

local function is_glob(s)
  return s:find("[%*%?%[]") ~= nil
end

--- A members entry (maybe a glob with * ? [..]) matches a relative path.
local function member_matches(entry, path)
  entry = entry:gsub("^%./", "")
  if entry == path then
    return true
  end
  if not is_glob(entry) then
    return false
  end
  return vim.fn.match(path, vim.fn.glob2regpat(entry)) >= 0
end

--- Read what :RustNewMember needs from a workspace root manifest: { members, dir, inherits }.
--- dir: where new members go (the directory of the first `dir/*` glob, else "crates").
--- Returns nil, reason when the manifest has no [workspace] members list.
function M.workspace_info(text)
  local list, range_or_why = members_array(text)
  if not list then
    return nil, range_or_why
  end
  local dir = "crates"
  for _, m in ipairs(list) do
    local d = m:match("^(.+)/%*$")
    if d and not is_glob(d) then
      dir = d:gsub("^%./", "")
      break
    end
  end
  return { members = list, dir = dir, inherits = workspace_package_keys(text) }
end

--- Add `path` to the members list unless an entry already covers it; the rest of the file keeps
--- its bytes, the list keeps its layout (single line, or one entry per line with its indent).
--- Returns the new text, or nil, reason.
function M.add_member_path(text, path)
  local list, range = members_array(text)
  if not list then
    return nil, range
  end
  for _, m in ipairs(list) do
    if member_matches(m, path) then
      return text
    end
  end
  local quoted = '"' .. path .. '"'
  local body = text:sub(range.first + 1, range.last - 1)
  if not body:find("\n", 1, true) then -- one line: [a, b] -> [a, b, new]
    local trimmed_len = #body:gsub("%s+$", "")
    local head, tail = body:sub(1, trimmed_len), body:sub(trimmed_len + 1)
    local sep
    if head:match("^%s*$") then
      sep = ""
    elseif head:match(",$") then
      sep = " "
    else
      sep = ", "
    end
    return text:sub(1, range.first) .. head .. sep .. quoted .. tail .. text:sub(range.last)
  end
  -- one entry per line: after the last line that holds an entry, same indent
  local lines = vim.split(body, "\n", { plain = true })
  local cr = text:find("\r\n", 1, true) and "\r" or "" -- a CRLF manifest keeps its line endings
  local last
  for i, l in ipairs(lines) do
    if l:gsub("#.*$", ""):find("[\"']") then
      last = i
    end
  end
  if not last then
    -- empty multi-line list: put the entry on its own line before the closing bracket
    local close = lines[#lines]
    local first = lines[1]:find("#", 1, true) and lines[1] or cr -- keep a comment after the `[`
    return text:sub(1, range.first)
      .. first
      .. "\n"
      .. close
      .. "  "
      .. quoted
      .. ","
      .. cr
      .. "\n"
      .. close
      .. text:sub(range.last)
  end
  local indent = lines[last]:match("^%s*")
  -- the last entry needs a comma before the new one: after the closing quote of the LAST entry
  -- on the line (a line can hold several; a comment can hold quotes)
  local code = lines[last]
  local quote, last_close = nil, nil
  for i = 1, #code do
    local c = code:sub(i, i)
    if quote then
      if c == quote then
        quote, last_close = nil, i
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == "#" then
      break
    end
  end
  if last_close and not code:sub(last_close + 1):gsub("#.*$", ""):find(",", 1, true) then
    code = code:sub(1, last_close) .. "," .. code:sub(last_close + 1)
  end
  lines[last] = code
  table.insert(lines, last + 1, indent .. quoted .. "," .. cr)
  return text:sub(1, range.first) .. table.concat(lines, "\n") .. text:sub(range.last)
end

-- ------------------------------------------------------------- the commands

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { id = NOTIFY_ID, title = LABEL })
end

local function progress(msg)
  notify(LABEL .. ": " .. msg)
end

local function fail(msg)
  error(msg, 0)
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_file(path, s)
  local f, err = io.open(path, "wb")
  if not f then
    fail("cannot write " .. path .. ": " .. tostring(err))
  end
  f:write(s)
  f:close()
end

--- Run cargo (argv) inside run_async; fails with cargo's first stderr line.
local function cargo(args, cwd)
  local cmd = { "cargo" }
  vim.list_extend(cmd, args)
  local ok, o = pcall(E.sys, cmd, { cwd = cwd })
  if not ok then
    fail("cargo could not be started: " .. tostring(o))
  end
  if o.code ~= 0 then
    fail("cargo " .. args[1] .. " failed: " .. M.first_line(o.stderr))
  end
  return o
end

local edition_cache
--- The edition this cargo gives a new project (`cargo new --vcs none` in a temp directory, read
--- back from the generated Cargo.toml; once per session). Inside run_async.
function M.cargo_edition()
  if edition_cache then
    return edition_cache
  end
  local tmp = vim.uv.fs_mkdtemp(vim.uv.os_tmpdir() .. "/xynovim-edition-XXXXXX")
  if not tmp then
    fail("cannot write in " .. vim.uv.os_tmpdir())
  end
  local ok, res = pcall(function()
    cargo({ "new", "--vcs", "none", "--bin", "probe" }, tmp)
    local e = M.parse_edition(read_file(tmp .. "/probe/Cargo.toml") or "")
    if not e then
      fail("could not read the edition cargo uses for new projects")
    end
    return e
  end)
  vim.fn.delete(tmp, "rf")
  if not ok then
    error(res, 0)
  end
  edition_cache = res
  return res
end

--- Forget the remembered edition (specs).
function M.reset_edition()
  edition_cache = nil
end

local function need_cargo()
  if vim.fn.executable("cargo") ~= 1 then
    fail("cargo not found")
  end
end

--- Create the missing parent directories; returns the list of those made.
local function make_parents(parent)
  local missing, d = {}, parent
  while d ~= "/" and not vim.uv.fs_stat(d) do
    table.insert(missing, 1, d)
    d = vim.fs.dirname(d)
  end
  local created = {}
  for _, m in ipairs(missing) do
    if not vim.uv.fs_mkdir(m, 493) then
      for i = #created, 1, -1 do
        vim.uv.fs_rmdir(created[i])
      end
      fail("could not create " .. m)
    end
    created[#created + 1] = m
  end
  return created
end

local function rmdirs(created)
  for i = #created, 1, -1 do
    vim.uv.fs_rmdir(created[i]) -- only what this run created, and only while empty
  end
end

local function kind_flag(kind)
  return kind == "library" and "--lib" or "--bin"
end

local function main_file(kind)
  return kind == "library" and "src/lib.rs" or "src/main.rs"
end

--- Create a binary or library (no prompts). p: name, parent, kind ("binary"|"library").
--- cb(err, info) runs when done; nothing is left behind on an error.
function M.create_project(p, cb)
  local created, target, target_made = {}, nil, false
  E.run_async(function()
    local name = M.name(p.name)
    if not name then
      fail("invalid name: " .. tostring(p.name))
    end
    if p.kind ~= "binary" and p.kind ~= "library" then
      fail("unknown kind: " .. tostring(p.kind))
    end
    need_cargo()
    target = p.parent .. "/" .. name
    if vim.uv.fs_lstat(target) then
      fail("the target already exists: " .. target)
    end
    created = make_parents(p.parent)
    progress(("cargo new (%s) ..."):format(p.kind))
    target_made = true
    cargo({ "new", kind_flag(p.kind), "--vcs", "git", name }, p.parent)
    return { dir = target, kind = p.kind, name = name, file = target .. "/" .. main_file(p.kind) }
  end, function(err, info)
    if err then
      if target_made and target and vim.uv.fs_lstat(target) then
        vim.fn.delete(target, "rf")
      end
      rmdirs(created)
    end
    cb(err, info)
  end)
end

--- Create a workspace (no prompts). p: name, parent, kind, member (the first member's name).
--- cb(err, info) runs when done; a failed run leaves no directory behind.
function M.create_workspace(p, cb)
  local created, root, root_made = {}, nil, false
  E.run_async(function()
    local name = M.name(p.name)
    if not name then
      fail("invalid workspace name: " .. tostring(p.name))
    end
    local member = M.name(p.member)
    if not member then
      fail("invalid member name: " .. tostring(p.member))
    end
    if p.kind ~= "binary" and p.kind ~= "library" then
      fail("unknown kind: " .. tostring(p.kind))
    end
    need_cargo()
    root = p.parent .. "/" .. name
    if vim.uv.fs_lstat(root) then
      fail("the target already exists: " .. root)
    end
    progress("asking cargo for the edition of new projects ...")
    local edition = M.cargo_edition()
    created = make_parents(p.parent)
    if not vim.uv.fs_mkdir(root, 493) then
      fail("cannot write in " .. p.parent)
    end
    root_made = true
    write_file(root .. "/Cargo.toml", M.workspace_toml(edition))
    write_file(root .. "/.gitignore", "/target\n")
    progress(("cargo new (%s %s) ..."):format(p.kind, member))
    cargo({ "new", kind_flag(p.kind), "--vcs", "none", "crates/" .. member }, root)
    local mdir = root .. "/crates/" .. member
    local manifest = mdir .. "/Cargo.toml"
    local text = read_file(manifest)
    if not text then
      fail("cargo did not write " .. manifest)
    end
    write_file(manifest, M.inherit(text))
    local git_note
    if vim.fn.executable("git") == 1 then
      local g = E.sys({ "git", "init", "-q", "-b", "main" }, { cwd = root })
      if g.code ~= 0 then
        git_note = "git init failed: " .. M.first_line(g.stderr)
      end
    else
      git_note = "git not found: no repository was created"
    end
    return {
      dir = root,
      name = name,
      kind = p.kind,
      member = member,
      edition = edition,
      resolver = M.resolver(edition),
      file = mdir .. "/" .. main_file(p.kind),
      git_note = git_note,
    }
  end, function(err, info)
    if err then
      if root_made and root and vim.uv.fs_lstat(root) then
        vim.fn.delete(root, "rf")
      end
      rmdirs(created)
    end
    cb(err, info)
  end)
end

--- Add a member to the workspace at `root` (no prompts). p: root, kind, name, taken (a set of
--- the existing package identifiers). cb(err, info) runs when done; the manifest is restored on
--- an error and the new directory removed.
function M.create_member(p, cb)
  local manifest = p.root .. "/Cargo.toml"
  local original, mdir, mdir_made
  E.run_async(function()
    local name, crate = M.name(p.name)
    if not name then
      fail("invalid member name: " .. tostring(p.name))
    end
    if p.kind ~= "binary" and p.kind ~= "library" then
      fail("unknown kind: " .. tostring(p.kind))
    end
    if (p.taken or {})[crate] then
      fail(("a workspace member named '%s' exists already"):format(crate))
    end
    need_cargo()
    original = read_file(manifest)
    if not original then
      fail("cannot read " .. manifest)
    end
    local ws, why = M.workspace_info(original)
    if not ws then
      fail("not a workspace with a members list: " .. why)
    end
    local rel = ws.dir .. "/" .. name
    mdir = p.root .. "/" .. rel
    if vim.uv.fs_lstat(mdir) then
      fail("the target already exists: " .. mdir)
    end
    progress(("cargo new (%s %s) ..."):format(p.kind, name))
    mdir_made = true
    cargo({ "new", kind_flag(p.kind), "--vcs", "none", rel }, p.root)
    -- cargo adds the new path to an explicit list itself, but rewrites the list's layout: the
    -- manifest is put back and the path added here, keeping the formatting
    local edited = M.add_member_path(original, rel)
    if (edited or original) ~= read_file(manifest) then
      write_file(manifest, edited or original)
    end
    local mm = mdir .. "/Cargo.toml"
    local text = read_file(mm)
    if not text then
      fail("cargo did not write " .. mm)
    end
    write_file(mm, M.inherit(text, ws.inherits))
    local missing = {}
    for _, k in ipairs({ "version", "edition" }) do
      if not ws.inherits[k] then
        missing[#missing + 1] = k
      end
    end
    return {
      dir = p.root,
      name = name,
      kind = p.kind,
      member = name,
      rel = rel,
      file = mdir .. "/" .. main_file(p.kind),
      not_inherited = missing,
    }
  end, function(err, info)
    if err then
      if mdir_made and mdir and vim.uv.fs_lstat(mdir) then
        vim.fn.delete(mdir, "rf")
      end
      if original then
        pcall(write_file, manifest, original)
      end
    end
    cb(err, info)
  end)
end

-- ------------------------------------------------------------- finishing

local function enter(dir, file)
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  vim.cmd.edit(vim.fn.fnameescape(file))
end

function M.finish_project(info)
  enter(info.dir, info.file)
  local lines = { "created " .. info.dir }
  if info.kind == "library" then
    local _, crate = M.name(info.name)
    lines[#lines + 1] = M.lib_note(info.name, crate)
    lines[#lines + 1] = "next: `cargo test` | <leader>rX lists the cargo targets"
  else
    lines[#lines + 1] = "next: `cargo run` | <leader>rX lists the cargo targets"
  end
  notify(table.concat(lines, "\n"))
end

--- The layout of a new workspace as text.
function M.layout(info)
  local mf = main_file(info.kind)
  return table.concat({
    info.name .. "/",
    "  Cargo.toml        [workspace] resolver " .. info.resolver .. ', members = ["crates/*"], edition ' .. info.edition,
    "  .gitignore        /target",
    "  crates/" .. info.member .. "/",
    "    Cargo.toml      version and edition inherited",
    "    " .. mf,
  }, "\n")
end

function M.finish_workspace(info)
  enter(info.dir, info.file)
  local lines = { "created " .. info.dir, M.layout(info) }
  if info.kind == "library" then
    local _, crate = M.name(info.member)
    lines[#lines + 1] = M.lib_note(info.member, crate)
    lines[#lines + 1] = ("next: `cargo test -p %s` | <leader>rX lists the cargo targets | :RustNewMember adds a crate"):format(
      info.member
    )
  else
    lines[#lines + 1] = ("next: `cargo run -p %s` | <leader>rX lists the cargo targets | :RustNewMember adds a crate"):format(
      info.member
    )
  end
  if info.git_note then
    lines[#lines + 1] = info.git_note
  end
  notify(table.concat(lines, "\n"))
end

function M.finish_member(info)
  vim.cmd.edit(vim.fn.fnameescape(info.file))
  local lines = { "added " .. info.rel .. " to " .. info.dir }
  if info.kind == "library" then
    local _, crate = M.name(info.member)
    lines[#lines + 1] = M.lib_note(info.member, crate)
  else
    lines[#lines + 1] = ("next: `cargo run -p %s`"):format(info.member)
  end
  if #info.not_inherited > 0 then
    lines[#lines + 1] = "[workspace.package] has no " .. table.concat(info.not_inherited, " / ") .. ": kept in the member"
  end
  notify(table.concat(lines, "\n"))
end

--- Why a workspace `name` in `parent` would nest badly, or nil: an enclosing workspace whose
--- members cover it (cargo then finds two workspace roots) or an enclosing git work tree.
function M.nesting_warning(parent, name)
  local dir = require("xyno_rust.fsutil").slash(parent):gsub("/+$", "")
  while dir ~= "" do
    local rel = (parent:sub(#dir + 1) .. "/" .. name):gsub("^/", "")
    local text = read_file(dir .. "/Cargo.toml")
    local ws = text and M.workspace_info(text)
    if ws then
      for _, m in ipairs(ws.members) do
        if member_matches(m, rel) then
          return ("%s is a workspace whose members cover %s: it would stop working"):format(dir, rel)
        end
      end
    end
    if vim.uv.fs_stat(dir .. "/.git") then
      return ("%s is inside the git repository %s: the new one would be nested"):format(parent, dir)
    end
    local up = dir:match("^(.*)/[^/]*$")
    if not up or up == dir then
      break
    end
    dir = up
  end
end

-- ------------------------------------------------------------- the prompts

local running = false

--- Whether a project is being created.
function M.running()
  return running
end

local function ask(prompt, default, check, cb)
  E.ask(prompt, default, check, cb, nil, LABEL)
end

--- The check for the parent-directory prompt: an existing directory without `target` in it, or a
--- missing one after a confirmation (created later by the run).
local function parent_check(target)
  return function(v)
    local d = E.expand_dir(v)
    local st = vim.uv.fs_stat(d)
    if st and st.type ~= "directory" then
      return nil, d .. " is not a directory"
    end
    if vim.uv.fs_lstat(d .. "/" .. target) then
      return nil, ("%s/%s exists already"):format(d, target)
    end
    if not st and vim.fn.confirm(("Create %s?"):format(d), "&Yes\n&No", 2) ~= 1 then
      return nil, "not created"
    end
    return d
  end
end

local function name_check(v)
  local name, crate_or_why = M.name(v)
  if not name then
    return nil, crate_or_why
  end
  return { name, crate_or_why }
end

--- Ask for a name (taking `arg` if it is valid); cb(name, crate).
local function ask_name(prompt, arg, default, cb, extra)
  local function check(v)
    local c, why = name_check(v)
    if c and extra then
      why = extra(c[1], c[2])
      if why then
        return nil, why
      end
    end
    return c, why
  end
  if arg and arg ~= "" then
    local c, why = check(arg)
    if c then
      return cb(c[1], c[2])
    end
    notify(LABEL .. ": " .. why, vim.log.levels.WARN)
    return ask(prompt:gsub(":%s*$", "") .. " (" .. why .. "): ", arg, check, function(r)
      cb(r[1], r[2])
    end)
  end
  ask(prompt, default, check, function(r)
    cb(r[1], r[2])
  end)
end

local function ask_kind(cb)
  vim.ui.select({ "binary", "library" }, { prompt = "Kind of the first member" }, function(kind)
    if kind then
      cb(kind)
    end
  end)
end

local function done_with(finish)
  return function(err, info)
    running = false
    if err then
      return notify(LABEL .. ": " .. err, vim.log.levels.ERROR)
    end
    finish(info)
  end
end

local function busy()
  if running then
    vim.notify(LABEL .. ": a project is being created already", vim.log.levels.WARN)
    return true
  end
end

--- :RustNewBin / :RustNewLib: name, parent directory, then cargo new.
function M.new_project(kind, name_arg)
  if busy() then
    return
  end
  ask_name("Project name: ", name_arg, nil, function(name, crate)
    if kind == "library" then
      local note = M.lib_note(name, crate)
      if note then
        notify(note)
      end
    end
    ask("Parent directory: ", E.default_parent(), parent_check(name), function(parent)
      running = true
      M.create_project({ name = name, parent = parent, kind = kind }, done_with(M.finish_project))
    end)
  end)
end

--- :RustNewWorkspace: name, parent directory, kind and name of the first member.
function M.new_workspace(name_arg)
  if busy() then
    return
  end
  ask_name("Workspace name: ", name_arg, nil, function(name)
    ask("Parent directory: ", E.default_parent(), parent_check(name), function(parent)
      local warning = M.nesting_warning(parent, name)
      if warning and vim.fn.confirm(warning .. ". Create it anyway?", "&Yes\n&No", 2) ~= 1 then
        return
      end
      ask_kind(function(kind)
        local default = name .. (kind == "library" and "-core" or "-app")
        ask_name("First member name: ", nil, default, function(member)
          running = true
          M.create_workspace(
            { name = name, parent = parent, kind = kind, member = member },
            done_with(M.finish_workspace)
          )
        end)
      end)
    end)
  end)
end

--- The workspace root for the current buffer (or the cwd), and its manifest text.
local function current_workspace()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    path = vim.uv.cwd() .. "/x"
  end
  local root = require("xyno_rust.rust_context").root(path)
  if not root then
    return nil, "not inside a cargo project"
  end
  local text = read_file(root .. "/Cargo.toml")
  if not text then
    return nil, "cannot read " .. root .. "/Cargo.toml"
  end
  local ws, why = M.workspace_info(text)
  if not ws then
    return nil, ("%s is not a workspace with a members list (%s)"):format(root, why)
  end
  return root, ws
end

--- :RustNewMember: kind, name; adds the crate to the workspace of the current buffer.
function M.new_member(name_arg)
  if busy() then
    return
  end
  local root, ws = current_workspace()
  if not root then
    return vim.notify(LABEL .. ": " .. ws, vim.log.levels.ERROR, { title = LABEL })
  end
  running = true
  local taken = {}
  E.run_async(function()
    local o = E.sys({ "cargo", "metadata", "--no-deps", "--offline", "--format-version", "1" }, { cwd = root })
    if o.code == 0 then
      local ok, meta = pcall(vim.json.decode, o.stdout)
      if ok and type(meta) == "table" then
        for _, pkg in ipairs(meta.packages or {}) do
          taken[(pkg.name:gsub("-", "_"))] = true
        end
      end
    end
  end, function()
    running = false
    ask_kind(function(kind)
      ask_name("Member name: ", name_arg, nil, function(name)
        running = true
        M.create_member({ root = root, kind = kind, name = name, taken = taken }, done_with(M.finish_member))
      end, function(member, crate)
        if taken[crate] then
          return ("a workspace member named '%s' exists already"):format(crate)
        end
        if vim.uv.fs_lstat(("%s/%s/%s"):format(root, ws.dir, member)) then
          return ("%s/%s exists already"):format(ws.dir, member)
        end
      end)
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("RustNewBin", function(a)
    M.new_project("binary", a.args)
  end, { nargs = "?", desc = "New Rust binary (cargo new --bin)" })
  vim.api.nvim_create_user_command("RustNewLib", function(a)
    M.new_project("library", a.args)
  end, { nargs = "?", desc = "New Rust library (cargo new --lib)" })
  vim.api.nvim_create_user_command("RustNewWorkspace", function(a)
    M.new_workspace(a.args)
  end, { nargs = "?", desc = "New Rust workspace with a first member" })
  vim.api.nvim_create_user_command("RustNewMember", function(a)
    M.new_member(a.args)
  end, { nargs = "?", desc = "Add a member crate to the current workspace" })
end

return M
