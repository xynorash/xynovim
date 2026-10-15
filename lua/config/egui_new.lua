-- :EguiNew [name] and the "New egui Project" dashboard entry: a new project
-- from the CURRENT https://github.com/emilk/eframe_template (downloaded as a
-- ZIP, never a copy kept here), personalised the way the template's README and
-- fill_template.sh describe: crate name, authors, window / page title, the web
-- build file names in assets/sw.js.
--
-- Options (all optional):
--   vim.g.xynovim_projects_dir              parent directory (default ~/projects if it exists, else the cwd)
--   vim.g.xynovim_egui_template             { repo = "emilk/eframe_template", ref = "main", base_url = "https://github.com" }
--   vim.g.xynovim_egui_keep_toolchain_pin   true (default): keep the template's rust-toolchain file
--   vim.g.xynovim_egui_prepare_toolchain    true (default): after creating a project that keeps the pin, install the
--                                           pinned toolchain WITH rust-analyzer / clippy / rustfmt in the background
--                                           (about 200 MB, once); false: only print the command to run
--   vim.g.xynovim_egui_build_after_new      true: run `cargo build` in a terminal afterwards
--
-- The text edits (M.validate_name .. M.readme) are pure functions; every
-- external command is an argv list, nothing from the template is executed.
local M = {}

local TOKEN = "eframe_template"
local TITLE_TOKEN = "eframe template"
local UA = "xynovim (github.com/xynorash/xynovim)"
local NOTIFY_ID = "xynovim_egui_new"

-- ------------------------------------------------------------- name rules

-- cargo's restricted_names::is_keyword
local KEYWORDS = {}
for w in
  ([[Self abstract as async await become box break const continue crate do dyn else enum extern false final
  fn for gen if impl in let loop macro match mod move mut override priv pub ref return self static struct
  super trait true try type typeof unsafe unsized use virtual where while yield]]):gmatch("%S+")
do
  KEYWORDS[w] = true
end

-- cargo new: names that clash with the standard crates, plus the artifact directories of target/
local RESERVED = {}
for w in ("test core std alloc proc_macro deps examples build incremental"):gmatch("%S+") do
  RESERVED[w] = true
end

-- the template's own dependencies (a lib named like one of them cannot compile);
-- M.dependency_names adds what the downloaded Cargo.toml really lists
local DEPENDENCIES = {}
for w in ("egui eframe log serde env_logger wasm_bindgen_futures wasm_bindgen web_sys js_sys"):gmatch("%S+") do
  DEPENDENCIES[w] = true
end

--- Validate a project name. Returns crate, nil, note on success (note: what was
--- converted, or nil) and nil, reason on failure.
function M.validate_name(raw)
  local name = vim.trim(raw or "")
  if name == "" then
    return nil, "the name is empty"
  end
  local bad = name:match("[^%w_%-][\128-\191]*") -- the whole UTF-8 character
  if bad then
    return nil, ("'%s' is not allowed: use letters, digits, '_' and '-'"):format(bad)
  end
  local crate = name:gsub("-", "_")
  if #crate > 64 then
    return nil, "the name is longer than 64 characters"
  end
  if not crate:match("^[%a_]") then
    return nil, "the name must start with a letter or '_'"
  end
  if crate == "_" then
    return nil, "'_' alone is not a valid name"
  end
  if KEYWORDS[crate] then
    return nil, ("'%s' is a Rust keyword"):format(crate)
  end
  if RESERVED[crate] then
    return nil, ("'%s' is reserved by cargo / the standard library"):format(crate)
  end
  if crate == TOKEN then
    return nil, "'eframe_template' is the template's own name: pick another"
  end
  if DEPENDENCIES[crate] then
    return nil, ("'%s' is the name of a dependency of the template"):format(crate)
  end
  return crate, nil, crate ~= name and ("crate name: " .. crate) or nil
end

--- Human-readable title of a crate name: 'weather_panel' -> 'weather panel'.
function M.title(crate)
  local t = vim.trim((crate:gsub("_+", " ")))
  return t ~= "" and t or crate
end

--- Reason why `s` cannot be an author name / e-mail, or nil. TOML- and
--- format-safe: no control characters, double quote, backslash, '<' or '>'.
function M.check_author(s, is_email)
  if s:find("[%c]") then
    return "no control characters or line breaks"
  end
  if s:find('["\\<>]') then
    return [[no double quote, backslash, '<' or '>']]
  end
  if is_email and s:find("%s") then
    return "an e-mail has no spaces"
  end
  return nil
end

--- The authors entry: "" -> nil (remove the line), name only, or "Name <email>".
function M.format_author(name, email)
  name, email = vim.trim(name or ""), vim.trim(email or "")
  if name == "" and email == "" then
    return nil
  end
  if email == "" then
    return name
  end
  if name == "" then
    return "<" .. email .. ">"
  end
  return ("%s <%s>"):format(name, email)
end

-- --------------------------------------------------------- text functions

-- an occurrence right after one of these is a link to / credit for the template
local URL_PREFIXES = { "github.com/emilk/", "emilk.github.io/", "deps.rs/repo/github/emilk/", "emilk/" }

local function in_template_url(text, s)
  for _, p in ipairs(URL_PREFIXES) do
    if s > #p and text:sub(s - #p, s - 1) == p then
      return true
    end
  end
  return false
end

--- 'eframe_template' -> crate everywhere except inside links to the template.
function M.replace_token(text, crate)
  local out, pos = {}, 1
  while true do
    local s, e = text:find(TOKEN, pos, true)
    if not s then
      break
    end
    out[#out + 1] = text:sub(pos, s - 1)
    out[#out + 1] = in_template_url(text, s) and TOKEN or crate
    pos = e + 1
  end
  out[#out + 1] = text:sub(pos)
  return table.concat(out)
end

--- 'eframe template' (the window / page title and heading) -> title.
function M.replace_title(text, title)
  local out, pos = {}, 1
  while true do
    local s, e = text:find(TITLE_TOKEN, pos, true)
    if not s then
      break
    end
    out[#out + 1] = text:sub(pos, s - 1)
    out[#out + 1] = title
    pos = e + 1
  end
  out[#out + 1] = text:sub(pos)
  return table.concat(out)
end

--- Cargo.toml: package.name and the authors line (only inside [package]);
--- authors = nil removes the line. Everything else is kept byte for byte.
function M.edit_cargo_toml(text, crate, authors)
  local lines = vim.split(text, "\n", { plain = true })
  local out, in_pkg, name_at, has_authors = {}, false, nil, false
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local header = line:match("^%s*(%[.-%])%s*") -- [package] possibly followed by a comment
    if header then
      in_pkg = header == "[package]"
      out[#out + 1] = line
    elseif in_pkg and line:match("^%s*name%s*=") then
      local pre, post = line:match('^(%s*name%s*=%s*)"[^"]*"(.*)$')
      out[#out + 1] = pre and (pre .. '"' .. crate .. '"' .. post) or line
      name_at = #out
    elseif in_pkg and line:match("^%s*authors%s*=") then
      has_authors = true
      -- a multi-line array runs to its closing bracket
      local j = i
      while not lines[j]:find("]", 1, true) and j < #lines do
        j = j + 1
      end
      local cr = line:sub(-1) == "\r" and "\r" or ""
      if authors then
        out[#out + 1] = ('authors = ["%s"]%s'):format(authors, cr)
      end
      i = j
    else
      out[#out + 1] = line
    end
    i = i + 1
  end
  if authors and not has_authors and name_at then
    local cr = out[name_at]:sub(-1) == "\r" and "\r" or ""
    table.insert(out, name_at + 1, ('authors = ["%s"]%s'):format(authors, cr))
  end
  return table.concat(out, "\n")
end

--- Names of the dependencies a Cargo.toml lists (- turned into _).
function M.dependency_names(text)
  local names, in_deps = {}, false
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local header = line:match("^%s*%[(.-)%]")
    if header then
      in_deps = header:match("dependencies$") ~= nil
    elseif in_deps then
      local key = line:match("^%s*([%w_%-]+)%s*=")
      if key then
        names[key:gsub("-", "_")] = true
      end
    end
  end
  return names
end

--- Cargo.lock: rename the [[package]] entry of the template itself, keep the rest.
--- cargo sorts the entries by name, so the entry moves to its sorted place
--- (otherwise `cargo build --locked` would want to rewrite the file).
function M.edit_cargo_lock(text, crate)
  local starts, pos = {}, 1
  if text:sub(1, 12) == "[[package]]\n" then
    starts[1] = 1
  end
  while true do
    local s = text:find("\n[[package]]\n", pos, true)
    if not s then
      break
    end
    starts[#starts + 1] = s + 1
    pos = s + 1
  end
  local blocks, names, hit = {}, {}, nil
  local head = starts[1] and text:sub(1, starts[1] - 1) or text
  local tail
  for k, s in ipairs(starts) do
    local e = (starts[k + 1] or (#text + 1)) - 1
    local b = text:sub(s, e)
    if k == #starts then
      local t = b:find("\n\n%[", 1)
      if t then -- [metadata] / [[patch.unused]] after the last package
        tail = b:sub(t + 2)
        b = b:sub(1, t - 1)
      end
    end
    b = b:gsub("\n+$", "")
    blocks[k] = b
    names[k] = b:match('\nname = "(.-)"')
    if names[k] == TOKEN and not hit then
      hit = k
    end
  end
  if not hit then
    return text
  end
  local renamed = blocks[hit]:gsub('\nname = "' .. TOKEN .. '"', function()
    return '\nname = "' .. crate .. '"'
  end, 1)
  local prev, nxt = names[hit - 1], names[hit + 1]
  local sorted = (not prev or prev <= crate) and (not nxt or nxt >= crate)
  if sorted then -- stays where it is: a plain substitution keeps every other byte
    local s = starts[hit]
    local before = text:sub(1, s - 1)
    local old = blocks[hit]
    return before .. renamed .. text:sub(s + #old)
  end
  table.remove(blocks, hit)
  table.remove(names, hit)
  local at = #blocks + 1
  for k = 1, #blocks do
    if names[k] and names[k] > crate then
      at = k
      break
    end
  end
  table.insert(blocks, at, renamed)
  local body = table.concat(blocks, "\n\n")
  if tail then
    return head .. body .. "\n\n" .. tail
  end
  return head .. body .. "\n"
end

--- The body of the first markdown section whose heading contains `pat`
--- (case-insensitive), up to the next heading of the same or a higher level.
function M.md_section(md, pat)
  local out, level, fence = nil, nil, false
  for _, line in ipairs(vim.split(md or "", "\n", { plain = true })) do
    if line:match("^%s*```") then
      fence = not fence
    end
    local hashes, title = nil, nil
    if not fence then
      hashes, title = line:match("^(#+)%s+(.-)%s*$")
    end
    if hashes then
      if out and #hashes <= level then
        break
      end
      if not out and title:lower():find(pat:lower(), 1, true) then
        out, level = {}, #hashes
      end
    elseif out then
      out[#out + 1] = line
    end
  end
  if not out then
    return nil
  end
  local body = vim.trim(table.concat(out, "\n"))
  return body ~= "" and body or nil
end

--- The generated README. o: title, template_readme (text or nil), pin (toolchain
--- channel or nil).
function M.readme(o)
  local run = M.md_section(o.template_readme, "testing locally")
    or "`cargo run --release`\n\nOn Linux the egui / eframe build needs the usual system packages (xcb, xkbcommon, openssl and pkg-config headers): see the template's README."
  local web = M.md_section(o.template_readme, "web locally")
    or "Install the target and Trunk, then serve:\n\n"
      .. "1. `rustup target add wasm32-unknown-unknown`\n2. `cargo install --locked trunk`\n"
      .. "3. `trunk serve` (open `http://127.0.0.1:8080/index.html#dev`)\n\n`trunk build --release` writes the site to `dist/`."
  local parts = {
    "# " .. o.title,
    "An [egui](https://github.com/emilk/egui) app that runs natively and in the browser, generated from "
      .. "[emilk/eframe_template](https://github.com/emilk/eframe_template) by xynovim's `:EguiNew`.",
    "## Run natively\n\n" .. run,
    "## Run on the web\n\n" .. web,
  }
  if o.pin then
    parts[#parts + 1] = ("## Toolchain\n\n`rust-toolchain` (from the template) pins Rust %s: the first `cargo` run "
      .. "downloads it through rustup. Delete the file to use your default toolchain."):format(o.pin)
  end
  parts[#parts + 1] = "## License\n\nThe template is dual licensed (MIT OR Apache-2.0), see `LICENSE-MIT` and `LICENSE-APACHE`; "
    .. "`Cargo.toml` keeps its `license` field."
  return M.replace_token(table.concat(parts, "\n\n") .. "\n", o.crate)
end

-- ------------------------------------------------------------ file system

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
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

--- All regular files below dir (relative paths); .git and symlinks are skipped.
local function walk(dir, rel, acc)
  acc = acc or {}
  local h = vim.uv.fs_scandir(rel and (dir .. "/" .. rel) or dir)
  while h do
    local name, typ = vim.uv.fs_scandir_next(h)
    if not name then
      break
    end
    local r = rel and (rel .. "/" .. name) or name
    if typ == "directory" then
      if name ~= ".git" then
        walk(dir, r, acc)
      end
    elseif typ == "file" then
      acc[#acc + 1] = r
    end
  end
  return acc
end

--- The tree has no symlink, no '..' entry and nothing but regular files and directories.
function M.check_tree(dir)
  local function scan(path)
    local h = vim.uv.fs_scandir(path)
    while h do
      local name, typ = vim.uv.fs_scandir_next(h)
      if not name then
        break
      end
      if name == ".." or typ == "link" then
        return nil, ("unsafe entry in the template archive: %s/%s (%s)"):format(path, name, typ)
      end
      if typ == "directory" then
        local ok, err = scan(path .. "/" .. name)
        if not ok then
          return nil, err
        end
      elseif typ ~= "file" then
        return nil, ("unexpected entry type %s: %s/%s"):format(tostring(typ), path, name)
      end
    end
    return true
  end
  return scan(dir)
end

local MAX_TEXT = 1024 * 1024

--- Personalise the unpacked template in `dir`. o: crate, title, authors (string
--- or nil), keep_pin (default true). Returns { changed = {...}, pin = channel|nil }.
function M.personalise(dir, o)
  local res = { changed = {}, pin = nil }
  local template_readme = read_file(dir .. "/README.md")
  for _, rel in ipairs(walk(dir)) do
    local base = vim.fs.basename(rel)
    local path = dir .. "/" .. rel
    local st = vim.uv.fs_stat(path)
    local skip = not st
      or st.size > MAX_TEXT
      or rel == "README.md" -- regenerated below
      or base:match("^LICEN[CS]E") ~= nil
      or base:match("^COPYING") ~= nil
    local text = not skip and read_file(path) or nil
    if text and not text:find("\0", 1, true) then
      local new
      if base == "Cargo.lock" then
        new = M.edit_cargo_lock(text, o.crate)
      else
        new = M.replace_title(M.replace_token(text, o.crate), o.title)
        if rel == "Cargo.toml" then
          new = M.edit_cargo_toml(new, o.crate, o.authors)
        end
      end
      if new ~= text then
        write_file(path, new)
        res.changed[#res.changed + 1] = rel
      end
    end
  end
  -- the template's own personalisation scripts are obsolete now
  for _, f in ipairs({ "fill_template.sh", "fill_template.ps1" }) do
    if vim.uv.fs_stat(dir .. "/" .. f) then
      vim.uv.fs_unlink(dir .. "/" .. f)
    end
  end
  -- toolchain pin
  for _, f in ipairs({ "rust-toolchain", "rust-toolchain.toml" }) do
    local t = read_file(dir .. "/" .. f)
    if t then
      if o.keep_pin == false then
        vim.uv.fs_unlink(dir .. "/" .. f)
      else
        res.pin = res.pin or t:match('channel%s*=%s*"([^"]+)"') or t:match("^%s*([%w%.%-_]+)%s*$") or "a specific toolchain"
      end
    end
  end
  write_file(
    dir .. "/README.md",
    M.readme({ title = o.title, crate = o.crate, template_readme = template_readme, pin = res.pin })
  )
  return res
end

-- ------------------------------------------------------------- fetching

local function cfg()
  local c = vim.tbl_extend("force", {
    repo = "emilk/eframe_template",
    ref = "main",
    base_url = "https://github.com",
  }, vim.g.xynovim_egui_template or {})
  if type(c.repo) ~= "string" or not c.repo:match("^[%w_.-]+/[%w_.-]+$") then
    return nil, "vim.g.xynovim_egui_template.repo must look like owner/name"
  end
  if type(c.ref) ~= "string" or not c.ref:match("^[%w_][%w_./-]*$") or c.ref:find("..", 1, true) then
    return nil, "vim.g.xynovim_egui_template.ref is not a valid branch, tag or commit"
  end
  local base = type(c.base_url) == "string" and c.base_url:gsub("/+$", "") or ""
  local scheme = base:match("^(%a+)://[^%s]+$")
  if scheme ~= "https" and scheme ~= "http" and scheme ~= "file" then
    return nil, "vim.g.xynovim_egui_template.base_url must be an https://, http:// or file:// URL"
  end
  local proto = scheme == "https" and "=https" or scheme == "http" and "=http,https" or "=file"
  return {
    url = ("%s/%s/archive/%s.zip"):format(base, c.repo, c.ref),
    proto = proto,
    repo = c.repo,
    ref = c.ref,
  }
end
M.config = cfg

local function cache_paths()
  local dir = vim.fn.stdpath("cache") .. "/xynovim"
  return dir, dir .. "/egui-template.zip", dir .. "/egui-template.json"
end

local function valid_etag(e)
  return type(e) == "string" and #e > 0 and #e <= 200 and e:match("^[\32-\126]+$") ~= nil
end

--- Cached template for this url: zip path, etag (or nil).
local function cached(url)
  local _, zip, meta = cache_paths()
  if not vim.uv.fs_stat(zip) then
    return nil
  end
  local ok, m = pcall(vim.json.decode, read_file(meta) or "")
  if not (ok and type(m) == "table" and m.url == url) then
    return nil
  end
  return zip, valid_etag(m.etag) and m.etag or nil
end

local steppers = {}

--- vim.system inside run_async: yields until the command finished.
local function sys(cmd, opts)
  local co = assert(coroutine.running())
  vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {}), function(o)
    vim.schedule(function()
      steppers[co](o)
    end)
  end)
  return coroutine.yield()
end

local function run_async(fn, cb)
  local co = coroutine.create(fn)
  local function step(...)
    local ok, res = coroutine.resume(co, ...)
    if not ok then
      steppers[co] = nil
      cb(tostring(res))
    elseif coroutine.status(co) == "dead" then
      steppers[co] = nil
      cb(nil, res)
    end
  end
  steppers[co] = step
  step()
end

local function fail(msg)
  error(msg, 0)
end

local function progress(msg)
  vim.notify("EguiNew: " .. msg, vim.log.levels.INFO, { id = NOTIFY_ID, title = "EguiNew" })
end

--- Download (conditionally) or reuse the cached ZIP; returns the path of a ZIP.
local function fetch(tmp)
  local c, err = cfg()
  if not c then
    fail(err)
  end
  if vim.fn.executable("curl") ~= 1 then
    fail("curl not found")
  end
  local cdir, czip, cmeta = cache_paths()
  local have, etag = cached(c.url)
  progress(("%s %s/%s ..."):format(have and etag and "checking" or "downloading", c.repo, c.ref))
  local out, hdr = tmp .. "/download.zip", tmp .. "/headers.txt"
  local cmd = {
    "curl", "--silent", "--show-error", "--fail", "--location",
    "--proto", c.proto, "--proto-redir", c.proto,
    "--max-time", "60", "--max-filesize", "30000000",
    "--user-agent", UA,
    "--dump-header", hdr, "--output", out, "--write-out", "%{http_code}",
  }
  if have and etag then
    vim.list_extend(cmd, { "--header", "If-None-Match: " .. etag })
  end
  vim.list_extend(cmd, { "--url", c.url })
  local r = sys(cmd)
  if r.code == 0 and vim.trim(r.stdout or "") == "304" and have then
    return have
  end
  local st = r.code == 0 and vim.uv.fs_stat(out) or nil
  if st and st.size > 0 and vim.fn.executable("unzip") == 1 and have then
    -- a captive portal or proxy can answer 200 with HTML: never replace the cache with that
    if sys({ "unzip", "-Z1", out }).code ~= 0 then
      st = nil
      r.stderr = "the download is not a ZIP file"
    end
  end
  if st and st.size > 0 then
    -- the ETag of the last response (the redirect target's, not the redirect's)
    local new_etag
    for line in (read_file(hdr) or ""):gmatch("[^\r\n]+") do
      local v = line:match("^[Ee][Tt][Aa][Gg]:%s*(.-)%s*$")
      if v then
        new_etag = v
      end
    end
    vim.fn.mkdir(cdir, "p")
    if vim.uv.fs_copyfile(out, czip .. ".new") and vim.uv.fs_rename(czip .. ".new", czip) then
      write_file(cmeta, vim.json.encode({ url = c.url, etag = valid_etag(new_etag) and new_etag or vim.NIL }))
    end
    return out
  end
  if have then
    vim.notify(
      ("EguiNew: could not reach %s (%s): using the cached template (it may be out of date)"):format(
        c.url, vim.trim((r.stderr or ""):match("[^\n]+") or "curl failed")
      ),
      vim.log.levels.WARN,
      { title = "EguiNew" }
    )
    return have
  end
  fail(
    ("could not download the template from %s: %s (no cached copy to fall back on)"):format(
      c.url, vim.trim((r.stderr or ""):match("[^\n]+") or ("curl exit " .. tostring(r.code)))
    )
  )
end

--- Unpack `zip` into tmp/extract and return the one top-level directory.
local function unpack(zip, tmp)
  if vim.fn.executable("unzip") ~= 1 then
    fail("unzip not found")
  end
  local l = sys({ "unzip", "-Z1", zip })
  if l.code ~= 0 then
    fail("the template archive is not a valid ZIP file")
  end
  for name in (l.stdout or ""):gmatch("[^\n]+") do
    if name:sub(1, 1) == "/" or name:find("\\", 1, true) or name:match("^%.%.$") or name:match("^%.%./")
      or name:find("/%.%./") or name:match("/%.%.$")
    then
      fail("the template archive has an unsafe entry: " .. name)
    end
  end
  local sz = sys({ "unzip", "-Zt", zip })
  local bytes = tonumber((sz.stdout or ""):match("([%d]+) bytes uncompressed"))
  if bytes and bytes > 300 * 1024 * 1024 then
    fail("the template archive unpacks to more than 300 MB")
  end
  local ex = tmp .. "/extract"
  vim.fn.mkdir(ex, "p")
  local u = sys({ "unzip", "-q", "-d", ex, zip })
  if u.code ~= 0 then
    fail("unzip failed: " .. vim.trim((u.stderr or ""):match("[^\n]+") or tostring(u.code)))
  end
  local ok, err = M.check_tree(ex)
  if not ok then
    fail(err)
  end
  local entries = {}
  local h = vim.uv.fs_scandir(ex)
  while h do
    local name, typ = vim.uv.fs_scandir_next(h)
    if not name then
      break
    end
    entries[#entries + 1] = { name = name, type = typ }
  end
  if #entries ~= 1 or entries[1].type ~= "directory" then
    fail("the template archive does not contain exactly one top-level directory")
  end
  return ex .. "/" .. entries[1].name
end

-- ------------------------------------------------------------- the pinned toolchain

-- rustup installs a pinned channel on first use WITHOUT rust-analyzer, so the proxy fails and the new
-- project has no LSP. These functions read the pin and install what the editor needs (argv only).

local NAME_PAT = "^[A-Za-z0-9._-]+$"
local EDITOR_COMPONENTS = { "rust-analyzer", "clippy", "rustfmt" }

local function valid_name(n)
  return type(n) == "string" and n:match(NAME_PAT) ~= nil and n:sub(1, 1) ~= "-"
end

local function toml_strings(body)
  local out = {}
  for q, v in body:gmatch("([\"'])(.-)%1") do
    out[#out + 1] = v
  end
  return out
end

--- Parse rust-toolchain / rust-toolchain.toml text (legacy one-line form or [toolchain] table).
--- Returns { channel = string|nil, components = {..}, targets = {..} } or nil when nothing is found.
function M.parse_pin(text)
  if type(text) ~= "string" then
    return nil
  end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    -- drop comments outside quotes (a "#" inside a quoted string stays)
    local out, quote = {}, nil
    for ch in line:gmatch(".") do
      if quote then
        if ch == quote then
          quote = nil
        end
      elseif ch == '"' or ch == "'" then
        quote = ch
      elseif ch == "#" then
        break
      end
      out[#out + 1] = ch
    end
    local l = vim.trim(table.concat(out))
    if l ~= "" then
      lines[#lines + 1] = l
    end
  end
  if #lines == 0 then
    return nil
  end
  local pin = { components = {}, targets = {} }
  if #lines == 1 and not lines[1]:find("[=%[]") then
    pin.channel = lines[1]
    return pin
  end
  local body = table.concat(lines, "\n")
  pin.channel = body:match("channel%s*=%s*[\"']([^\"'\n]*)[\"']") or body:match("channel%s*=%s*([^%s\"',%]]+)")
  local comps = body:match("components%s*=%s*%[(.-)%]")
  if comps then
    pin.components = toml_strings(comps)
  end
  local targs = body:match("targets%s*=%s*%[(.-)%]")
  if targs then
    pin.targets = toml_strings(targs)
  end
  if not pin.channel then
    return nil
  end
  return pin
end

--- The install plan for a parsed pin: { channel, components, targets, skipped = {notes} } or nil, note.
function M.toolchain_plan(pin)
  if not pin or not pin.channel then
    return nil, "no channel found in the toolchain file"
  end
  if not valid_name(pin.channel) then
    return nil, ("the pinned channel '%s' is not a plain toolchain name (a path or odd characters): not touched"):format(
      pin.channel
    )
  end
  local plan = { channel = pin.channel, components = {}, targets = {}, skipped = {} }
  local seen = {}
  local function add_component(c)
    if valid_name(c) and not seen[c] then
      seen[c] = true
      plan.components[#plan.components + 1] = c
    end
  end
  for _, c in ipairs(EDITOR_COMPONENTS) do
    add_component(c)
  end
  for _, c in ipairs(pin.components or {}) do
    if valid_name(c) then
      add_component(c)
    else
      plan.skipped[#plan.skipped + 1] = c
    end
  end
  local tseen = {}
  for _, t in ipairs(pin.targets or {}) do
    if valid_name(t) then
      if not tseen[t] then
        tseen[t] = true
        plan.targets[#plan.targets + 1] = t
      end
    else
      plan.skipped[#plan.skipped + 1] = t
    end
  end
  return plan
end

function M.install_argv(plan)
  local a = { "rustup", "toolchain", "install", plan.channel, "--profile", "minimal" }
  for _, c in ipairs(plan.components) do
    vim.list_extend(a, { "--component", c })
  end
  for _, t in ipairs(plan.targets) do
    vim.list_extend(a, { "--target", t })
  end
  return a
end

M.list_argv = { "rustup", "toolchain", "list" }

function M.components_argv(channel)
  return { "rustup", "component", "list", "--installed", "--toolchain", channel }
end

--- True when `rustup toolchain list` output names `channel` (e.g. "1.95.0-x86_64-unknown-linux-gnu (default)").
function M.toolchain_listed(out, channel)
  for line in (out or ""):gmatch("[^\n]+") do
    local name = line:match("^(%S+)")
    if name and (name == channel or name:sub(1, #channel + 1) == channel .. "-") then
      return true
    end
  end
  return false
end

--- True when `rustup component list --installed` output contains rust-analyzer.
function M.has_rust_analyzer(out)
  for line in (out or ""):gmatch("[^\n]+") do
    if line:match("^rust%-analyzer") then
      return true
    end
  end
  return false
end

--- Injectable for the specs: runs argv, calls cb({ code, stdout, stderr }) on the main loop.
function M.runner(argv, cb)
  local ok, err = pcall(vim.system, argv, { text = true }, function(o)
    vim.schedule(function()
      cb(o)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb({ code = 127, stdout = "", stderr = tostring(err) })
    end)
  end
end

function M.have_rustup()
  return vim.fn.executable("rustup") == 1
end

--- Injectable for the specs.
function M.restart_lsp()
  require("config.rust_restart").restart()
end

local TC_ID = "xynovim_egui_toolchain"

local function tc_notify(msg, level)
  vim.notify("EguiNew: " .. msg, level or vim.log.levels.INFO, { id = TC_ID, title = "EguiNew" })
end

--- Make sure the toolchain pinned in `dir` has what the editor needs, in the background.
--- done(state) is optional (specs): "skipped" | "installed" | "failed" | "refused" | "no-rustup" | "off" | "nopin".
function M.prepare_toolchain(dir, done)
  done = done or function() end
  local text
  for _, f in ipairs({ "rust-toolchain", "rust-toolchain.toml" }) do
    text = text or read_file(dir .. "/" .. f)
  end
  if not text then
    return done("nopin")
  end
  local plan, note = M.toolchain_plan(M.parse_pin(text))
  if not plan then
    tc_notify(note, vim.log.levels.WARN)
    return done("refused")
  end
  local cmd = table.concat(M.install_argv(plan), " ")
  if vim.g.xynovim_egui_prepare_toolchain == false then
    tc_notify("the toolchain is not prepared (vim.g.xynovim_egui_prepare_toolchain = false); to get rust-analyzer run:\n" .. cmd)
    return done("off")
  end
  if not M.have_rustup() then
    tc_notify("rustup not found: no rust-analyzer for the pinned toolchain. Install rustup, then run:\n" .. cmd, vim.log.levels.WARN)
    return done("no-rustup")
  end
  local function install()
    tc_notify(("preparing toolchain %s (download of about 200 MB, once) ..."):format(plan.channel))
    M.runner(M.install_argv(plan), function(o)
      if o.code ~= 0 then
        local why = vim.trim((o.stderr or ""):match("[^\n]+") or ("exit " .. tostring(o.code)))
        tc_notify(("could not prepare toolchain %s (%s). The project is fine; later, online, run:\n%s"):format(plan.channel, why, cmd), vim.log.levels.WARN)
        return done("failed")
      end
      local ok, err = pcall(M.restart_lsp)
      tc_notify(
        ("toolchain %s is ready (rust-analyzer, clippy, rustfmt)%s"):format(
          plan.channel, ok and "; restarting the Rust language servers" or ("; :RustRestart failed: " .. tostring(err))
        )
      )
      done("installed")
    end)
  end
  M.runner(M.list_argv, function(l)
    if l.code ~= 0 or not M.toolchain_listed(l.stdout, plan.channel) then
      return install()
    end
    M.runner(M.components_argv(plan.channel), function(c)
      if c.code == 0 and M.has_rust_analyzer(c.stdout) then
        return done("skipped")
      end
      install()
    end)
  end)
end

-- ------------------------------------------------------------- the flow

local running = false

--- Create the project (no prompts). p: crate, author_name, author_email, parent.
--- cb(err, dir) runs when done; the temp directory is gone on every path.
function M.create(p, cb)
  local tmp, created = nil, {}
  local function cleanup()
    if tmp then
      vim.fn.delete(tmp, "rf")
    end
    for i = #created, 1, -1 do
      vim.uv.fs_rmdir(created[i]) -- only what this run created, and only while empty
    end
  end
  run_async(function()
    local crate = M.validate_name(p.crate)
    if not crate then
      fail("invalid crate name: " .. tostring(p.crate))
    end
    for _, f in ipairs({ { p.author_name, false }, { p.author_email, true } }) do
      local why = M.check_author(vim.trim(f[1] or ""), f[2])
      if why then
        fail("invalid author: " .. why)
      end
    end
    local target = p.parent .. "/" .. crate
    if vim.uv.fs_lstat(target) then
      fail("the target already exists: " .. target)
    end
    -- missing parent directories (the caller asked the user before)
    local missing, d = {}, p.parent
    while d ~= "/" and not vim.uv.fs_stat(d) do
      table.insert(missing, 1, d)
      d = vim.fs.dirname(d)
    end
    for _, m in ipairs(missing) do
      if not vim.uv.fs_mkdir(m, 493) then
        fail("could not create " .. m)
      end
      created[#created + 1] = m
    end
    tmp = vim.uv.fs_mkdtemp(p.parent .. "/.egui-new-XXXXXX")
    if not tmp then
      fail("cannot write in " .. p.parent)
    end
    local zip = fetch(tmp)
    progress("unpacking ...")
    local top = unpack(zip, tmp)
    local proj = tmp .. "/" .. crate
    if not vim.uv.fs_rename(top, proj) then
      fail("could not rename the unpacked template")
    end
    local deps = M.dependency_names(read_file(proj .. "/Cargo.toml") or "")
    if deps[crate] then
      fail(("'%s' is the name of a dependency of the template"):format(crate))
    end
    progress("personalising ...")
    local res = M.personalise(proj, {
      crate = crate,
      title = M.title(crate),
      authors = M.format_author(p.author_name, p.author_email),
      keep_pin = vim.g.xynovim_egui_keep_toolchain_pin ~= false,
    })
    local git_note
    if vim.fn.executable("git") == 1 then
      local g = sys({ "git", "init", "-q", "-b", "main" }, { cwd = proj })
      if g.code ~= 0 then
        git_note = "git init failed: " .. vim.trim((g.stderr or ""):match("[^\n]+") or "")
      end
    else
      git_note = "git not found: no repository was created"
    end
    if vim.uv.fs_lstat(target) then
      fail("the target already exists: " .. target)
    end
    if not vim.uv.fs_rename(proj, target) then
      fail("could not move the project to " .. target)
    end
    vim.fn.delete(tmp, "rf")
    tmp = nil
    created = {} -- the parents stay: the project lives in them
    return { dir = target, pin = res.pin, git_note = git_note }
  end, function(err, info)
    cleanup()
    cb(err, info)
  end)
end

--- Switch to the project, open its entry point and say what to do next.
function M.finish(info)
  local dir = info.dir
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  local main = dir .. "/src/main.rs"
  if not vim.uv.fs_stat(main) then
    main = dir .. "/Cargo.toml"
  end
  vim.cmd.edit(vim.fn.fnameescape(main))
  local lines = {
    "created " .. dir,
    "next: `cargo run --release` | <leader>rX lists the cargo targets | `trunk serve` for the web",
  }
  if info.pin then
    lines[#lines + 1] = ("rust-toolchain pins Rust %s: it is prepared in the background (with rust-analyzer) "
      .. "(vim.g.xynovim_egui_prepare_toolchain = false skips that, vim.g.xynovim_egui_keep_toolchain_pin = false drops the file)"):format(info.pin)
  end
  if info.git_note then
    lines[#lines + 1] = info.git_note
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { id = NOTIFY_ID, title = "EguiNew" })
  if info.pin then
    M.prepare_toolchain(dir)
  end
  if vim.g.xynovim_egui_build_after_new == true and _G.Snacks and Snacks.terminal then
    Snacks.terminal.open({ "cargo", "build" }, { cwd = dir, auto_close = false, win = { position = "bottom" } })
  end
end

-- ------------------------------------------------------------- the prompts

local function git_config(key)
  if vim.fn.executable("git") ~= 1 then
    return ""
  end
  local ok, o = pcall(function()
    return vim.system({ "git", "config", key }, { text = true }):wait(3000)
  end)
  return ok and o.code == 0 and vim.trim(o.stdout or "") or ""
end

local function default_parent()
  local d = vim.g.xynovim_projects_dir
  if type(d) ~= "string" or d == "" then
    d = vim.uv.os_homedir() .. "/projects"
    if vim.fn.isdirectory(d) ~= 1 then
      d = vim.uv.cwd()
    end
  end
  return d
end

local function expand_dir(s)
  s = vim.trim(s)
  if s == "~" or s:sub(1, 2) == "~/" then
    s = vim.uv.os_homedir() .. s:sub(2)
  end
  s = vim.fn.fnamemodify(vim.fs.normalize(s), ":p"):gsub("/+$", "")
  return s == "" and "/" or s
end
M.expand_dir = expand_dir

local MAX_RETRIES = 10

--- Ask in sequence; a cancelled prompt (nil) ends everything silently.
local function ask(prompt, default, check, cb, tries)
  tries = tries or 0
  vim.ui.input({ prompt = prompt, default = default }, function(v)
    if v == nil then
      return
    end
    local value, why = check(v)
    if why then
      vim.notify("EguiNew: " .. why, vim.log.levels.WARN, { title = "EguiNew" })
      if tries >= MAX_RETRIES then
        return
      end
      local base = prompt:gsub(" %(.-%):", ":"):gsub(":%s*$", "")
      return ask(base .. " (" .. why .. "): ", v, check, cb, tries + 1)
    end
    cb(value)
  end)
end

--- :EguiNew [name]: prompt for the details, then create the project.
function M.new(name_arg)
  if running then
    return vim.notify("EguiNew: a project is being created already", vim.log.levels.WARN)
  end
  local p = {}
  local function go()
    running = true
    M.create(p, function(err, info)
      running = false
      if err then
        return vim.notify("EguiNew: " .. err, vim.log.levels.ERROR, { id = NOTIFY_ID, title = "EguiNew" })
      end
      M.finish(info)
    end)
  end
  local function ask_parent(default)
    ask("Parent directory: ", default, function(v)
      local d = expand_dir(v)
      local st = vim.uv.fs_stat(d)
      if st and st.type ~= "directory" then
        return nil, d .. " is not a directory"
      end
      if vim.uv.fs_lstat(d .. "/" .. p.crate) then
        return nil, ("%s/%s exists already"):format(d, p.crate)
      end
      if not st and vim.fn.confirm(("Create %s?"):format(d), "&Yes\n&No", 2) ~= 1 then
        return nil, "not created"
      end
      return d
    end, function(d)
      p.parent = d
      go()
    end)
  end
  local function ask_email()
    ask("Author e-mail (empty: none): ", git_config("user.email"), function(v)
      local why = M.check_author(vim.trim(v), true)
      return vim.trim(v), why
    end, function(v)
      p.author_email = v
      ask_parent(default_parent())
    end)
  end
  local function ask_author()
    ask("Author name (empty: none): ", git_config("user.name"), function(v)
      local why = M.check_author(vim.trim(v), false)
      return vim.trim(v), why
    end, function(v)
      p.author_name = v
      ask_email()
    end)
  end
  local function after_name(crate, note)
    p.crate = crate
    if note then
      vim.notify(note, vim.log.levels.INFO, { title = "EguiNew" })
    end
    ask_author()
  end
  local function check_name(v)
    local crate, why, note = M.validate_name(v)
    if not crate then
      return nil, why
    end
    return { crate, note }
  end
  if name_arg and name_arg ~= "" then
    local c = check_name(name_arg)
    if c then
      return after_name(c[1], c[2])
    end
    local _, why = check_name(name_arg)
    vim.notify("EguiNew: " .. why, vim.log.levels.WARN, { title = "EguiNew" })
    return ask("Project name (" .. why .. "): ", name_arg, check_name, function(c)
      after_name(c[1], c[2])
    end)
  end
  ask("Project name: ", nil, check_name, function(c)
    after_name(c[1], c[2])
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("EguiNew", function(a)
    M.new(a.args)
  end, { nargs = "?", desc = "New egui project from the current eframe_template" })
end

return M
