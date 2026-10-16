-- The website (site/, scripts/build-site.py, .github/workflows/pages.yml).
-- Everything is hermetic: the site is built into a temp directory and read as
-- text; no browser, no network (links to github.com are not checked here).
local H = require("xynotest.helpers")

local repo = H.repo
local CANON = "https://xynorash.github.io/xynovim/"

local function read(path)
  local f = assert(io.open(path, "rb"), "cannot read " .. path)
  local s = f:read("*a")
  f:close()
  return s
end

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function size(path)
  local st = vim.uv.fs_stat(path)
  return st and st.size or 0
end

local function sh(cmd, opts)
  local r = vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait(120000)
  r.out = (r.stdout or "") .. (r.stderr or "")
  return r
end

local readme = read(repo .. "/README.md")
local workflow = read(repo .. "/.github/workflows/pages.yml")
-- the workflow without its comment lines (the header talks about deploy-pages and git push)
local code_only = workflow:gsub("\n%s*#[^\n]*", "")

-- ------------------------------------------------------------------ build once

local out, build
local function built()
  if not build then
    out = H.tmpdir() .. "/_site"
    build = sh({ "python3", repo .. "/scripts/build-site.py", "--out", out, "--check" }, { cwd = repo })
  end
  return build
end

local function page()
  built()
  return read(out .. "/index.html")
end

--- Tags of an HTML text: { name, attrs = {k = v}, pos, text-after = until next tag }
local function tags(html)
  local list = {}
  for close, name, rest, pos in html:gmatch("<(/?)([%w]+)([^>]-)>()") do
    if close == "" and not name:match("^!") then
      local attrs = {}
      for k, v in rest:gmatch('([%w:%-]+)="([^"]*)"') do
        attrs[k] = v
      end
      for k in rest:gsub('"[^"]*"', ""):gmatch("%s([%w:%-]+)") do
        attrs[k] = attrs[k] or true
      end
      table.insert(list, { name = name:lower(), attrs = attrs, pos = pos })
    end
  end
  return list
end

local function find(html, name)
  local r = {}
  for _, t in ipairs(tags(html)) do
    if t.name == name then
      table.insert(r, t)
    end
  end
  return r
end

local function meta(html, key, val)
  for _, t in ipairs(find(html, "meta")) do
    if t.attrs[key] == val then
      return t.attrs.content
    end
  end
end

local function is_local(ref)
  return not ref:match("^%a[%w+.-]*:") and not ref:match("^//")
end

--- every local reference of src/href/poster/srcset
local function refs(html)
  local list = {}
  for _, t in ipairs(tags(html)) do
    for _, k in ipairs({ "src", "href", "poster" }) do
      if type(t.attrs[k]) == "string" then
        table.insert(list, { tag = t.name, attr = k, ref = t.attrs[k], rel = t.attrs.rel })
      end
    end
    if type(t.attrs.srcset) == "string" then
      for part in t.attrs.srcset:gmatch("[^,]+") do
        table.insert(list, { tag = t.name, attr = "srcset", ref = vim.trim(part):match("^%S+") })
      end
    end
  end
  return list
end

-- ------------------------------------------------------------------ build

describe("the build", function()
  it("scripts/build-site.py succeeds and checks its own references", function()
    if vim.fn.executable("python3") == 0 then
      skip("python3 is missing")
    end
    H.eq(0, built().code, built().out)
    H.match(built().out, "all resolve", true)
  end)

  it("the required files exist, with .nojekyll and no source README", function()
    for _, f in ipairs({ "index.html", "404.html", "robots.txt", "sitemap.xml", ".nojekyll", "assets/style.css", "assets/app.js", "assets/favicon.svg", "assets/og.png" }) do
      H.ok(exists(out .. "/" .. f), f)
    end
    H.not_ok(exists(out .. "/README.md"))
  end)

  it("only the referenced media is copied", function()
    local want = {}
    for _, r in ipairs(refs(page())) do
      local name = r.ref:match("^media/([^#?]+)")
      if name then
        want[name] = true
        H.ok(exists(out .. "/media/" .. name), name)
      end
    end
    local have = vim.fn.readdir(out .. "/media")
    H.eq(vim.tbl_count(want), #have, "media files copied vs referenced")
    for _, n in ipairs(have) do
      H.ok(want[n], "unreferenced " .. n)
    end
  end)

  it("fails on a placeholder it does not know and on a missing media file", function()
    local tmp = H.tmpdir() .. "/fake"
    vim.fn.mkdir(tmp .. "/scripts", "p")
    vim.fn.mkdir(tmp .. "/site", "p")
    vim.fn.mkdir(tmp .. "/docs/media", "p")
    vim.fn.mkdir(tmp .. "/tests", "p")
    vim.uv.fs_copyfile(repo .. "/scripts/build-site.py", tmp .. "/scripts/build-site.py")
    vim.uv.fs_copyfile(repo .. "/README.md", tmp .. "/README.md")
    vim.fn.writefile({ '<img src="media/none.png">' }, tmp .. "/site/index.html")
    local r = sh({ "python3", tmp .. "/scripts/build-site.py", "--out", tmp .. "/o" })
    H.not_ok(r.code == 0)
    H.match(r.out, "none.png", true)
    vim.fn.writefile({ "<p>{{WHAT}}</p>" }, tmp .. "/site/index.html")
    r = sh({ "python3", tmp .. "/scripts/build-site.py", "--out", tmp .. "/o" })
    H.not_ok(r.code == 0)
    H.match(r.out, "{{WHAT}}", true)
  end)

  it("refuses a media reference that leaves docs/media", function()
    local tmp = H.tmpdir() .. "/esc"
    vim.fn.mkdir(tmp .. "/scripts", "p")
    vim.fn.mkdir(tmp .. "/site", "p")
    vim.fn.mkdir(tmp .. "/docs/media", "p")
    vim.fn.mkdir(tmp .. "/tests", "p")
    vim.uv.fs_copyfile(repo .. "/scripts/build-site.py", tmp .. "/scripts/build-site.py")
    vim.uv.fs_copyfile(repo .. "/README.md", tmp .. "/README.md")
    vim.fn.writefile({ "secret" }, tmp .. "/secret.txt")
    vim.fn.writefile({ '<img src="media/../../secret.txt">' }, tmp .. "/site/index.html")
    local r = sh({ "python3", tmp .. "/scripts/build-site.py", "--out", tmp .. "/o" })
    H.not_ok(r.code == 0)
    H.match(r.out, "leaves docs/media", true)
  end)
end)

-- ------------------------------------------------------------------ head

describe("index.html head", function()
  it("has lang, charset, viewport, one unique title, description, canonical, theme-color", function()
    local html = page()
    H.match(html, "^<!doctype html>\n<html lang=\"en\">")
    H.ok(find(html, "meta")[1].attrs.charset, "charset first")
    H.match(meta(html, "name", "viewport"), "width=device-width", true)
    H.eq(1, #find(html, "title"))
    local title = html:match("<title>(.-)</title>")
    H.ok(title and #title > 8)
    H.ok(#meta(html, "name", "description") > 40)
    H.ok(meta(html, "name", "theme-color"))
    local canon
    for _, t in ipairs(find(html, "link")) do
      if t.attrs.rel == "canonical" then
        canon = t.attrs.href
      end
    end
    H.eq(CANON, canon)
  end)

  it("Open Graph and Twitter tags use absolute https URLs on the canonical host", function()
    local html = page()
    local host = CANON:match("^https://([^/]+)/")
    for _, key in ipairs({ "og:url", "og:image", "twitter:image" }) do
      local v = meta(html, "property", key) or meta(html, "name", key)
      H.ok(v, key)
      H.match(v, "^https://" .. host:gsub("%p", "%%%0") .. "/xynovim/")
    end
    H.eq(CANON, meta(html, "property", "og:url"))
    H.eq(CANON .. "assets/og.png", meta(html, "property", "og:image"))
    H.eq("summary_large_image", meta(html, "name", "twitter:card"))
    for _, key in ipairs({ "og:title", "og:description", "og:type", "og:image:alt" }) do
      H.ok(meta(html, "property", key), key)
    end
    H.ok(meta(html, "name", "twitter:title"))
    -- the card itself is the size it claims
    local png = io.open(out .. "/assets/og.png", "rb"):read(24)
    local function be32(i)
      local a, b, c, d = png:byte(i, i + 3)
      return ((a * 256 + b) * 256 + c) * 256 + d
    end
    local w, h = be32(17), be32(21)
    H.eq(1200, w)
    H.eq(630, h)
    H.eq("1200", meta(html, "property", "og:image:width"))
    H.eq("630", meta(html, "property", "og:image:height"))
  end)

  it("has a strict CSP meta tag", function()
    for _, file in ipairs({ "index.html", "404.html" }) do
      local csp = meta(read(out .. "/" .. file), "http-equiv", "Content-Security-Policy")
      H.ok(csp, file)
      for _, d in ipairs({ "default-src 'self'", "img-src 'self' data:", "media-src 'self'", "style-src 'self'", "script-src 'self'", "base-uri 'none'", "form-action 'none'" }) do
        H.match(csp, d, true, file .. ": " .. d)
      end
      H.no_match(csp, "unsafe", true)
    end
  end)
end)

-- ------------------------------------------------------------------ structure

describe("index.html structure", function()
  it("has landmarks, a skip link, exactly one h1 and no skipped heading levels", function()
    local html = page()
    for _, t in ipairs({ "<header", "<nav", "<main", "<footer" }) do
      H.match(html, t, true)
    end
    H.match(html, 'class="skip" href="#main"', true)
    H.match(html, '<main id="main"', true)
    local level = 0
    local h1 = 0
    for l in html:gmatch("<h(%d)[ >]") do
      l = tonumber(l)
      if l == 1 then
        h1 = h1 + 1
      end
      H.ok(l <= level + 1, ("heading level jumps from %d to %d"):format(level, l))
      level = l
    end
    H.eq(1, h1)
  end)

  it("ids are unique and every local reference and #anchor resolves", function()
    local html = page()
    local ids = {}
    for _, t in ipairs(tags(html)) do
      if t.attrs.id then
        H.not_ok(ids[t.attrs.id], "duplicate id " .. t.attrs.id)
        ids[t.attrs.id] = true
      end
    end
    for _, r in ipairs(refs(html)) do
      if r.ref:sub(1, 1) == "#" then
        H.ok(ids[r.ref:sub(2)], "anchor " .. r.ref)
      elseif is_local(r.ref) then
        H.ok(exists(out .. "/" .. r.ref:gsub("[#?].*$", "")), r.ref)
        H.no_match(r.ref, "^/", false, "absolute path " .. r.ref)
      end
    end
  end)

  it("makes no external request: only github.com links and nexte.st as <a href>", function()
    local html = page()
    for _, r in ipairs(refs(html)) do
      if not is_local(r.ref) and r.rel ~= "canonical" then
        H.eq("a", r.tag, "external " .. r.attr .. " on <" .. r.tag .. ">: " .. r.ref)
        H.eq("href", r.attr)
        H.ok(r.ref:match("^https://github%.com/") or r.ref:match("^https://nexte%.st$"), r.ref)
      end
    end
    for _, t in ipairs(find(html, "link")) do
      if t.attrs.rel ~= "canonical" then
        H.ok(is_local(t.attrs.href), "link " .. t.attrs.href)
      end
    end
    H.no_match(html, "@import", true)
    H.no_match(read(out .. "/assets/style.css"), "url%(%s*['\"]?https?:")
    H.no_match(read(out .. "/assets/style.css"), "@import", true)
    H.no_match(read(out .. "/assets/app.js"), "https?://")
    H.no_match(read(out .. "/assets/app.js"), "fetch%(")
    H.no_match(read(out .. "/assets/app.js"), "XMLHttpRequest")
  end)

  it("every img has alt, width and height; images below the fold are lazy", function()
    local imgs = find(page(), "img")
    H.ok(#imgs > 30, "images: " .. #imgs)
    local eager = 0
    for _, t in ipairs(imgs) do
      local a = t.attrs
      H.ok(type(a.alt) == "string", "alt on " .. a.src)
      if a.src ~= "assets/favicon.svg" then -- the logo is decorative: alt=""
        H.ok(#a.alt > 10, "alt of " .. a.src)
      end
      H.ok(tonumber(a.width) and tonumber(a.height), "size of " .. a.src)
      if a.loading ~= "lazy" then
        eager = eager + 1
      else
        H.eq("async", a.decoding)
      end
      H.no_match(a.src, "%.gif$")
    end
    H.eq(2, eager, "the logo and the hero screenshot load eagerly")
  end)

  it("every video has a poster, an mp4 source, controls, muted, preload none and a size", function()
    local html = page()
    local n = 0
    for _, t in ipairs(find(html, "video")) do
      n = n + 1
      local a = t.attrs
      H.ok(a.poster and exists(out .. "/" .. a.poster), "poster")
      H.eq("none", a.preload)
      H.ok(a.controls and a.muted and a.playsinline and a.loop)
      H.ok(tonumber(a.width) and tonumber(a.height))
      H.ok(a["aria-label"] and #a["aria-label"] > 10)
    end
    H.eq(13, n, "recordings 02-09 and 11-15")
    H.match(html, 'download the MP4', true)
    local sources = find(html, "source")
    H.eq(13, #sources)
    for _, s in ipairs(sources) do
      H.match(s.attrs.src, "^media/%d%d%-[%w%-]+%.mp4$")
      H.eq("video/mp4", s.attrs.type)
    end
  end)

  it("has no inline script, style or event handler (CSP)", function()
    for _, file in ipairs({ "index.html", "404.html" }) do
      local html = read(out .. "/" .. file)
      for _, t in ipairs(find(html, "script")) do
        H.ok(t.attrs.src, "inline script in " .. file)
      end
      H.eq(0, #find(html, "style"), "<style> in " .. file)
      for _, t in ipairs(tags(html)) do
        H.not_ok(t.attrs.style, "style attribute on <" .. t.name .. "> in " .. file)
        for k in pairs(t.attrs) do
          H.no_match(k, "^on%a+$", false, "handler " .. k)
        end
      end
      H.no_match(html, 'href="javascript:', true)
    end
  end)

  it("works without JavaScript: the menu is a CSS checkbox and the copy buttons are added by the script", function()
    local html = page()
    H.match(html, 'id="nav-toggle"', true)
    H.eq(0, #find(html, "button"), "no dead buttons without JS")
    local css = read(out .. "/assets/style.css")
    H.not_ok(css:find("%f[%w-]order:"), "no CSS order: the tab order is the visual order")
    H.match(read(out .. "/assets/app.js"), "createElement%(\"button\"%)")
    H.match(read(out .. "/assets/style.css"), ".nav-toggle:checked ~ #site-nav", true)
  end)
end)

-- ------------------------------------------------------------------ content = README

describe("the page says what the README says", function()
  local function readme_numbers()
    local tests = readme:match("badge/tests%-(%d+)%%20passing")
    local specs, checks, skipped, failing = readme:match("%*%*(%d+) spec files, (%d+) checks passing, (%d+) skipped with a stated reason, (%d+) failing%*%*")
    return tests, specs, checks, skipped, failing
  end

  it("the numbers are the README's and the spec count is the directory's", function()
    local html = page()
    local tests, specs, checks, skipped, failing = readme_numbers()
    H.ok(tests and specs, "README numbers")
    H.eq(tests, checks, "badge vs summary line in the README")
    local files = 0
    for _, n in ipairs(vim.fn.readdir(repo .. "/tests")) do
      if n:match("_spec%.lua$") then
        files = files + 1
      end
    end
    H.eq(files, tonumber(specs), "README spec files vs tests/*_spec.lua")
    for _, want in ipairs({
      { specs, "spec files" }, { tests, "checks passing" }, { skipped, "skipped with a stated reason" }, { failing, "failing" },
    }) do
      H.match(html, "<b>" .. want[1] .. "</b><span>" .. want[2] .. "</span>", true, want[2])
    end
    H.match(html, "tests <b>" .. tests .. " passing</b>", true)
    H.match(html, tests .. " passing checks across " .. files .. " spec files", true)
    H.no_match(html, "{{", true)
  end)

  it("the install command is the README's, byte for byte", function()
    local html = page()
    local block = readme:match("\n## Install\n.-\n```sh\n(.-)\n```")
    H.ok(block, "README install block")
    local function text_of(id)
      local inner = html:match('<code id="' .. id:gsub("%-", "%%-") .. '">(.-)</code>')
      H.ok(inner, id)
      return (inner:gsub("<[^>]+>", ""):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
    end
    H.eq(block, text_of("install-cmd"))
    H.eq(block, text_of("install-cmd-2"))
  end)

  it("the test commands are the README's", function()
    local html = page()
    for cmd in readme:match("## Tests: run them yourself.-```sh\n(.-)\n```"):gmatch("[^\n]+") do
      local c = cmd:match("^(.-)%s+#")
      H.match(html, c, true, c)
    end
  end)

  it("every command and every key group named on the page exists in the README", function()
    local html = page()
    local cmds = html:match('<h3 class="sub">Commands</h3>(.-)</ul>')
    H.ok(cmds)
    local n = 0
    for c in cmds:gmatch("<code>(:[%w ]+)</code>") do
      n = n + 1
      H.match(readme, c, true, c)
    end
    H.ok(n >= 25, "commands listed: " .. n)
    for key in html:gmatch("<code>(&lt;leader&gt;[%w]+)</code>") do
      local k = key:gsub("&lt;", "<"):gsub("&gt;", ">")
      H.match(readme, k:gsub("^<leader>", "", 1):sub(1, 1), true)
    end
  end)

  it("the tagline, the badges' facts and the docs links come from the repo", function()
    local html = page()
    local pitch = readme:match("%*%*(A Neovim config for Rust that goes after RustRover:.-)%*%*")
    H.ok(pitch)
    H.match(html, pitch, true)
    H.match(html, "Neovim <b>0.12</b>", true)
    H.match(html, "Apache-2.0", true)
    for _, d in ipairs({ "docs/DETAILS.md", "docs/KNOWN_ISSUES.md", "docs/TESTING.md", "tests/COVERAGE.md", "docs/PLAN_MACROS_DEPS.md", "CHANGELOG.md" }) do
      H.ok(exists(repo .. "/" .. d), d)
      H.match(html, "https://github.com/xynorash/xynovim/blob/main/" .. d, true)
    end
    H.match(html, "https://github.com/xynorash/xynovim/tree/main/demo/netwatch", true)
    H.ok(exists(repo .. "/demo/netwatch"))
    H.match(html, "Built from commit", true)
  end)

  it("the README links to the site and says where it is published from", function()
    H.match(readme, "Website: https://xynorash.github.io/xynovim/", true)
    H.match(readme, "gh-pages", true)
    H.match(readme, "pages.yml", true)
    H.match(readme, "site/", true)
  end)
end)

-- ------------------------------------------------------------------ sitemap, robots, 404, budgets

describe("sitemap, robots, 404", function()
  it("sitemap.xml and robots.txt are consistent with the canonical URL", function()
    built()
    local sm = read(out .. "/sitemap.xml")
    H.eq(CANON, sm:match("<loc>(.-)</loc>"))
    H.match(sm, "<lastmod>%d%d%d%d%-%d%d%-%d%d</lastmod>")
    H.match(sm, "http://www.sitemaps.org/schemas/sitemap/0.9", true)
    local robots = read(out .. "/robots.txt")
    H.match(robots, "Sitemap: " .. CANON .. "sitemap.xml", true)
    H.match(robots, "User-agent: *", true)
    H.no_match(robots, "Disallow: /\n")
  end)

  it("404.html is the only page with absolute paths, all under /xynovim/ and all existing", function()
    built()
    local html = read(out .. "/404.html")
    H.match(html, "ONLY file of the site that uses absolute paths", true)
    H.match(html, 'lang="en"', true)
    H.eq(1, select(2, html:gsub("<h1[ >]", "")))
    for _, r in ipairs(refs(html)) do
      if is_local(r.ref) then
        H.match(r.ref, "^/xynovim/")
        H.ok(exists(out .. "/" .. r.ref:gsub("^/xynovim/", ""):gsub("[#?].*$", "")), r.ref)
      end
    end
    -- and index.html has none
    for _, r in ipairs(refs(page())) do
      H.not_ok(r.ref:match("^/"), r.ref)
    end
  end)
end)

describe("budgets and assets", function()
  it("HTML < 80 KB, CSS < 40 KB, JS < 12 KB, initial load < 1.5 MB", function()
    built()
    H.ok(size(out .. "/index.html") < 80 * 1024, "html " .. size(out .. "/index.html"))
    H.ok(size(out .. "/assets/style.css") < 40 * 1024, "css")
    H.ok(size(out .. "/assets/app.js") < 12 * 1024, "js")
    local first = size(out .. "/index.html") + size(out .. "/assets/style.css") + size(out .. "/assets/app.js") + size(out .. "/assets/favicon.svg")
    for _, t in ipairs(find(page(), "img")) do
      if t.attrs.loading ~= "lazy" then
        first = first + size(out .. "/" .. t.attrs.src)
      end
    end
    H.ok(first < 1.5 * 1024 * 1024, "initial load " .. first)
  end)

  it("assets/app.js passes node --check", function()
    if vim.fn.executable("node") == 0 then
      skip("node is missing")
    end
    local r = sh({ "node", "--check", repo .. "/site/assets/app.js" })
    H.eq(0, r.code, r.out)
  end)

  it("honours prefers-reduced-motion and prefers-color-scheme", function()
    local css = read(repo .. "/site/assets/style.css")
    H.match(css, "prefers-reduced-motion: no-preference", true)
    H.match(css, "prefers-reduced-motion: reduce", true)
    H.match(css, "prefers-color-scheme: light", true)
    H.match(css, ":focus-visible", true)
    local js = read(repo .. "/site/assets/app.js")
    H.match(js, "prefers-reduced-motion", true)
    H.match(js, "IntersectionObserver", true)
  end)

  it("text colours reach WCAG AA (4.5:1) on every surface, dark and light", function()
    local css = read(repo .. "/site/assets/style.css")
    local function vars(block)
      local v = {}
      for k, hex in block:gmatch("%-%-([%w%-]+):%s*(#%x%x%x%x%x%x);") do
        v[k] = hex
      end
      return v
    end
    local function lum(hex)
      local c = {}
      for i = 1, 3 do
        local x = tonumber(hex:sub(2 * i, 2 * i + 1), 16) / 255
        c[i] = x <= 0.03928 and x / 12.92 or ((x + 0.055) / 1.055) ^ 2.4
      end
      return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3]
    end
    local function ratio(a, b)
      local la, lb = lum(a), lum(b)
      if la < lb then
        la, lb = lb, la
      end
      return (la + 0.05) / (lb + 0.05)
    end
    local dark = vars(css:match(":root%s*{(.-)}"))
    local light = vim.tbl_extend("force", dark, vars(css:match("prefers%-color%-scheme: light%)%s*{%s*:root%s*{(.-)}")))
    H.ok(dark.bg and light.bg and light.bg ~= dark.bg, "two palettes")
    for name, v in pairs({ dark = dark, light = light }) do
      for _, fg in ipairs({ "text", "strong", "muted", "blue", "green", "orange", "purple", "yellow" }) do
        for _, bg in ipairs({ "bg", "panel", "code-bg" }) do
          local r = ratio(v[fg], v[bg])
          H.ok(r >= 4.5, ("%s: %s on %s is %.2f"):format(name, fg, bg, r))
        end
      end
      H.ok(ratio(v["on-accent"], v.blue) >= 4.5, name .. ": button text")
    end
    -- the dark palette is Island Dark's
    H.eq({ "#1e1f22", "#2b2d30", "#bcbec4", "#9da0a8", "#56a8f5", "#6aab73", "#cf8e6d", "#c77dbb", "#f2c55c" },
      { dark.bg, dark.panel, dark.text, dark.muted, dark.blue, dark.green, dark.orange, dark.purple, dark.yellow })
    local palette = read(repo .. "/lua/island/palette.lua"):lower()
    for _, hex in pairs(dark) do
      if hex ~= "#ffffff" and hex ~= "#17181b" and hex ~= "#e6e8ec" and hex ~= "#4b5059" and hex ~= "#393b40" then
        H.match(palette .. read(repo .. "/tools/Dark.icls"):lower(), hex, true, hex .. " is in the Island Dark sources")
      end
    end
  end)
end)

-- ------------------------------------------------------------------ the workflow

describe(".github/workflows/pages.yml", function()
  it("passes actionlint", function()
    if vim.fn.executable("actionlint") == 0 then
      skip("actionlint is missing")
    end
    local r = sh({ "actionlint", repo .. "/.github/workflows/pages.yml" })
    H.eq(0, r.code, r.out)
  end)

  it("passes zizmor", function()
    if vim.fn.executable("zizmor") == 0 then
      skip("zizmor is missing")
    end
    local r = sh({ "zizmor", repo .. "/.github/workflows/pages.yml" })
    H.eq(0, r.code, r.out)
  end)

  it("pins every action by full SHA and uses no third-party deploy action", function()
    local n = 0
    for line in workflow:gmatch("[^\n]+") do
      local uses = line:match("^%s*%-?%s*uses:%s*(%S+)")
      if uses then
        n = n + 1
        H.match(uses, "^actions/checkout@%x+$")
        H.eq(40, #uses:match("@(%x+)$"))
        H.match(line, "# v%d+%.%d+%.%d+$")
      end
    end
    H.eq(1, n)
    for _, bad in ipairs({ "deploy-pages", "upload-pages-artifact", "peaceiris", "JamesIves", "configure-pages", "gh-pages@" }) do
      H.no_match(code_only, bad, true)
    end
  end)

  it("reads by default and writes only in the publish job", function()
    H.match(workflow, "\npermissions:\n  contents: read\n", true)
    local top, jobs = workflow:match("^(.-)\njobs:\n(.*)$")
    H.eq(1, select(2, workflow:gsub("contents: write", "")))
    H.no_match(top, "contents: write", true)
    H.match(jobs, "  publish:\n.-permissions:\n      contents: write", false)
    H.no_match(workflow, "write%-all")
    H.match(workflow, "persist-credentials: false", true)
  end)

  it("never runs on pull requests; push to main with paths, and manual runs; only in this repository", function()
    H.no_match(workflow, "pull_request", true)
    H.match(workflow, "on:\n  push:\n    branches: [main]\n    paths:", true)
    for _, p in ipairs({ "site/**", "docs/media/**", "README.md", "scripts/build-site.py", ".github/workflows/pages.yml" }) do
      H.match(workflow, '"' .. p .. '"', true)
    end
    H.match(workflow, "workflow_dispatch:", true)
    H.match(workflow, "github.repository == 'xynorash/xynovim'", true)
    H.match(workflow, "github.ref == 'refs/heads/main'", true)
    H.match(workflow, "group: pages\n  cancel-in-progress: false", true)
  end)

  it("only ever pushes to the branch gh-pages, with the token in a one-shot header", function()
    local pushes = 0
    for line in code_only:gmatch("[^\n]+") do
      if line:match("git .*push") then
        pushes = pushes + 1
        H.match(line, 'HEAD:refs/heads/${branch}', true)
        H.match(line, "http.extraheader", true)
      end
    end
    H.eq(1, pushes)
    H.match(workflow, "branch=gh-pages\n", true)
    H.no_match(workflow, "git remote add", true)
    H.no_match(workflow, "git config[^\n]*extraheader", false)
    H.no_match(workflow, "echo[^\n]*GITHUB_TOKEN", false)
    H.match(workflow, "GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}", true)
    H.match(workflow, "git init -q -b", true)
    H.match(workflow, "Deploy ${short} from main", true)
    H.match(workflow, "github-actions[bot]", true)
    H.match(workflow, "ls-remote", true)
    H.match(workflow, 'if [ "$after" != "$local_sha" ]', true)
    H.match(workflow, "scripts/build-site.py --out _site --check", true)
    H.match(workflow, "Deploy from a branch", true)
  end)

  it("the repo ignores _site/", function()
    H.match("\n" .. read(repo .. "/.gitignore"), "\n_site/\n", true)
  end)
end)
