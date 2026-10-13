-- :RustRoutes (lua/config/rust_routes.lua): treesitter scanner, workspace walk,
-- picker and the <leader>rN map. No LSP and no cargo needed.
local H = require("xynotest.helpers")
local R = require("config.rust_routes")

local function scan(src)
  return R.scan_source(src)
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function summary(items)
  return vim.tbl_map(function(r)
    return r.kind .. " " .. r.path .. " " .. r.detail
  end, items)
end

describe("rust_routes command", function()
  it("defines :RustRoutes with no arguments and the picker description", function()
    local cmd = vim.api.nvim_get_commands({})["RustRoutes"]
    H.ok(cmd, "RustRoutes is not defined")
    H.eq("0", cmd.nargs)
    H.eq("Pick an axum/actix/rocket route in the workspace", cmd.definition)
  end)
end)

describe("rust_routes.scan_source", function()
  it("finds the 3 routes of the fixture (attribute + two .route calls)", function()
    local f = assert(io.open(H.fixtures .. "/sql_and_routes.rs"))
    local src = f:read("*a")
    f:close()
    local items = scan(src)
    H.eq(3, #items)
    local by = {}
    for _, r in ipairs(items) do
      by[#by + 1] = r.kind .. " " .. r.path
    end
    table.sort(by)
    H.eq({ "GET /health", "ROUTE /health", "ROUTE /users/:id" }, by)
  end)

  it("returns {path, kind, detail, row, col} sorted by row, 0-based position of the string content", function()
    local src = table.concat({
      'fn app() -> Router {', -- row 0
      '    Router::new().route("/b", get(b))', -- row 1
      '}',
      '#[get("/a")]', -- row 3
      'async fn a() {}',
    }, "\n")
    local items = scan(src)
    H.eq(2, #items)
    H.eq({ path = "/b", kind = "ROUTE", detail = "get(b)", row = 1, col = 25 }, items[1])
    H.eq({ path = "/a", kind = "GET", detail = "a", row = 3, col = 7 }, items[2])
    -- the position points at the first char of the content, after the quote
    local line = vim.split(src, "\n")[items[1].row + 1]
    H.eq("/b", line:sub(items[1].col + 1, items[1].col + 2))
    local line2 = vim.split(src, "\n")[items[2].row + 1]
    H.eq("/a", line2:sub(items[2].col + 1, items[2].col + 2))
    H.eq(true, items[1].row <= items[2].row)
  end)

  it("sorts items out of source order by row (attribute after a later .route is impossible, so mix)", function()
    local src = '#[post("/p")]\nfn p() {}\nfn x(){ r.route("/q", any(q)); }\n#[put("/r")]\nfn r() {}\n'
    H.eq({ "POST /p p", "ROUTE /q any(q)", "PUT /r r" }, summary(scan(src)))
  end)

  it("axum .route with chained methods is a ROUTE, detail is the handler expression", function()
    local items = scan('fn a(){ Router::new().route("/p", get(h).delete(g)); }')
    H.eq({ "ROUTE /p get(h).delete(g)" }, summary(items))
  end)

  it("squeezes whitespace of multi-line handler expressions to single spaces", function()
    local src = 'fn a(){ r.route("/p",\n    get(h)\n        .delete(g)\n        .post(\n  k),\n); }'
    local items = scan(src)
    H.eq(1, #items)
    H.eq("get(h) .delete(g) .post( k)", items[1].detail)
    H.no_match(items[1].detail, "[\n\t]")
    H.no_match(items[1].detail, "  ", true)
  end)

  it("lists actix web::get().to(h) and any(h) handler expressions as ROUTE", function()
    local items = scan('fn c(){ cfg.route("/a", web::get().to(h)); r.route("/b", any(h2)); }')
    H.eq({ "ROUTE /a web::get().to(h)", "ROUTE /b any(h2)" }, summary(items))
  end)

  it("attribute routes: kind is the upper-cased verb, detail the following fn name", function()
    local verbs =
      { "get", "post", "put", "delete", "patch", "head", "options", "trace", "connect", "route" }
    for _, v in ipairs(verbs) do
      local items = scan(('#[%s("/x")]\nasync fn h_%s() {}\n'):format(v, v))
      H.eq({ v:upper() .. " /x h_" .. v }, summary(items), v)
    end
  end)

  it("handles actix, rocket and poem style attributes", function()
    local src = table.concat({
      '#[actix_web::post("/a")]',
      "async fn create() {}",
      '#[get("/b/<id>")]',
      "fn rocket_get(id: u32) {}",
      '#[handler]',
      "fn poem_unrelated() {}",
      '#[get("/c")]',
      "async fn poem_get() -> String { String::new() }",
      '#[route("/d", method = "GET")]',
      "async fn generic() {}",
    }, "\n")
    H.eq({
      "POST /a create",
      "GET /b/<id> rocket_get",
      "GET /c poem_get",
      "ROUTE /d generic",
    }, summary(scan(src)))
  end)

  it("ignores attributes that are not HTTP verbs", function()
    local src = table.concat({
      '#[derive(Debug)]',
      "struct S;",
      '#[cfg(test)]',
      "mod t {}",
      '#[tokio::main]',
      "async fn main() {}",
      '#[test]',
      "fn t() {}",
      '#[allow("x")]',
      "fn q() {}",
      '#[cfg(feature = "get")]',
      "fn r() {}",
    }, "\n")
    H.eq({}, scan(src))
  end)

  it("gives detail '?' when the attribute is not followed by a function", function()
    local src = '#[get("/s")]\nstruct S;\n#[post("/e")]\n'
    H.eq({ "GET /s ?", "POST /e ?" }, summary(scan(src)))
  end)

  it("resolves the fn name through several stacked attributes", function()
    local src = table.concat({
      '#[get("/x")]',
      "#[allow(clippy::unused_async)]",
      '#[tracing::instrument]',
      "async fn h() {}",
    }, "\n")
    H.eq({ "GET /x h" }, summary(scan(src)))
  end)

  it("takes the last identifier of a scoped attribute as the verb", function()
    H.eq({ "GET /p h" }, summary(scan('#[actix_web::get("/p")]\nfn h() {}')))
    H.eq({ "DELETE /p h" }, summary(scan('#[a::b::delete("/p")]\nfn h() {}')))
  end)

  it("returns {} for an empty string and never raises on junk", function()
    H.eq({}, scan(""))
    local ok, res = pcall(scan, "}}} ((( .route( #[get( \"")
    H.ok(ok, "scan_source raised on garbage")
    H.eq("table", type(res))
    -- junk is not turned into a route
    for _, r in ipairs(res) do
      H.eq("string", type(r.path))
    end
  end)

  it("returns {} when the parser cannot be created", function()
    local orig = vim.treesitter.get_string_parser
    vim.treesitter.get_string_parser = function()
      error("no parser for rust")
    end
    local ok, res = pcall(scan, 'fn a(){ r.route("/p", get(h)); }')
    vim.treesitter.get_string_parser = orig
    H.ok(ok, "error escaped scan_source")
    H.eq({}, res)
  end)

  it("does not recognise nest, web::resource or macro-built routes", function()
    local src = table.concat({
      "fn app() -> Router {",
      '    Router::new().nest("/api", api_router())',
      "}",
      "fn cfg(c: &mut web::ServiceConfig) {",
      '    c.service(web::resource("/res").route(web::get().to(h)));',
      "}",
      "fn m() { routes![index, about]; my_route!(\"/m\", h); }",
    }, "\n")
    local items = scan(src)
    -- web::resource("/res") produces nothing; its inner .route(...) has a
    -- non-string first argument, so nothing is listed at all
    H.eq({}, items)
    H.eq({}, scan('fn a(){ Router::new().nest("/api", sub); }'))
  end)
end)

describe("rust_routes.collect", function()
  local function item_by_rel(items)
    local m = {}
    for _, i in ipairs(items) do
      m[i.rel] = m[i.rel] or {}
      table.insert(m[i.rel], i)
    end
    return m
  end

  it("walks .rs files, skips target/.git/node_modules/bacon-ls-live, fills the item fields", function()
    local root = H.tmpdir()
    local good = '#[get("/g")]\nasync fn g() {}\n'
    write(root .. "/src/main.rs", 'fn a(){ r.route("/m", get(m)); }\n')
    write(root .. "/src/api/users.rs", good)
    for _, d in ipairs({ "target", ".git", "node_modules", "bacon-ls-live" }) do
      write(root .. "/" .. d .. "/x.rs", good)
    end
    write(root .. "/src/notes.txt", good)
    write(root .. "/src/readme.md", good)
    write(root .. "/src/lib.rs", "pub fn plain() {}\n") -- no pre-filter hit
    write(root .. "/src/lookalike.rs", '// get("/nope")\nfn x() {}\n') -- no ".route(" nor "#["

    local items = R.collect(root)
    local by = item_by_rel(items)
    local rels = vim.tbl_keys(by)
    table.sort(rels)
    H.eq({ "src/api/users.rs", "src/main.rs" }, rels)
    H.eq(2, #items)

    local m = by["src/main.rs"][1]
    H.eq({
      text = "ROUTE /m  get(m)  src/main.rs",
      file = root .. "/src/main.rs",
      pos = { 1, 17 },
      kind = "ROUTE",
      route = "/m",
      detail = "get(m)",
      rel = "src/main.rs",
    }, m)
    local g = by["src/api/users.rs"][1]
    H.eq("GET /g  g  src/api/users.rs", g.text)
    H.eq({ 1, 7 }, g.pos) -- row + 1 (1-based line), col as the scanner gives it
    H.eq(root .. "/src/api/users.rs", g.file)
  end)

  it("skips target/.git/node_modules/bacon-ls-live below the root too (workspace members)", function()
    local root = H.tmpdir()
    local good = '#[get("/g")]\nasync fn g() {}\n'
    write(root .. "/crates/a/src/lib.rs", good)
    for _, d in ipairs({ "target", ".git", "node_modules", "bacon-ls-live" }) do
      write(root .. "/crates/a/" .. d .. "/x.rs", good)
    end
    local rels = vim.tbl_map(function(i)
      return i.rel
    end, R.collect(root))
    table.sort(rels)
    H.eq({ "crates/a/src/lib.rs" }, rels)
  end)

  it("pre-filter: only files containing '.route(' or '#[' are parsed", function()
    local root = H.tmpdir()
    write(root .. "/a.rs", 'fn a(){ r.route("/a", h); }')
    write(root .. "/b.rs", 'fn a(){ r.route ("/b", h); }') -- space: filtered out
    write(root .. "/c.rs", '#[get("/c")]\nfn c() {}')
    local seen = {}
    for _, i in ipairs(R.collect(root)) do
      seen[#seen + 1] = i.rel
    end
    table.sort(seen)
    H.eq({ "a.rs", "c.rs" }, seen)
  end)

  it("walks to depth 12 and no further", function()
    local root = H.tmpdir()
    local function deep(n)
      local parts = {}
      for i = 1, n - 1 do
        parts[i] = "d" .. i
      end
      parts[#parts + 1] = "f.rs"
      return table.concat(parts, "/")
    end
    local src = '#[get("/deep")]\nfn f() {}\n'
    write(root .. "/" .. deep(12), src)
    write(root .. "/x/" .. deep(12), src) -- 13 components
    local rels = vim.tbl_map(function(i)
      return i.rel
    end, R.collect(root))
    H.has(rels, deep(12))
    H.eq(1, #rels, "a file below depth 12 was listed: " .. vim.inspect(rels))
  end)

  it("returns {} for a workspace without routes", function()
    local root = H.tmpdir()
    write(root .. "/src/main.rs", "fn main() {}\n")
    H.eq({}, R.collect(root))
  end)
end)

describe("rust_routes.pick", function()
  local orig_snacks, picked

  -- swapped in right before pick() only: :edit lets Snacks load itself
  local function stub_snacks()
    orig_snacks = orig_snacks or _G.Snacks
    _G.Snacks = {
      picker = function(opts)
        picked[#picked + 1] = opts
      end,
    }
  end

  before_each(function()
    picked = {}
    orig_snacks = nil
  end)

  after_each(function()
    if orig_snacks then
      _G.Snacks = orig_snacks
    end
  end)

  local function crate(files)
    local dir = H.tmpdir()
    write(dir .. "/Cargo.toml", '[package]\nname = "t"\nversion = "0.1.0"\nedition = "2021"\n')
    for rel, text in pairs(files) do
      write(dir .. "/" .. rel, text)
    end
    return dir
  end

  it("warns 'no Cargo.toml found' outside a crate and opens no picker", function()
    local dir = H.tmpdir()
    write(dir .. "/lone.rs", '#[get("/x")]\nfn h() {}\n')
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/lone.rs"))
    -- a Cargo.toml in a parent of the temp dir would make this test meaningless
    if #vim.fs.find("Cargo.toml", { upward = true, path = dir }) > 0 then
      H.skip_file("a Cargo.toml exists above the temp dir")
    end
    stub_snacks()
    local cap = H.capture_notify()
    R.pick()
    cap.restore()
    H.eq({ { msg = "no Cargo.toml found", level = vim.log.levels.WARN } }, cap.list)
    H.eq(0, #picked)
  end)

  it("notifies INFO when the crate has no routes", function()
    local dir = crate({ ["src/main.rs"] = "fn main() {}\n" })
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/src/main.rs"))
    stub_snacks()
    local cap = H.capture_notify()
    vim.cmd("RustRoutes")
    cap.restore()
    H.eq({
      { msg = 'no routes found (.route("/p", ..) or #[get("/p")])', level = vim.log.levels.INFO },
    }, cap.list)
    H.eq(0, #picked)
  end)

  it("opens Snacks.picker titled 'Routes' with the items and a file preview", function()
    local dir = crate({
      ["src/main.rs"] = 'fn a(){ r.route("/m", get(m)); }\n',
      ["src/h.rs"] = '#[post("/h")]\nasync fn hh() {}\n',
    })
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/src/main.rs"))
    stub_snacks()
    local cap = H.capture_notify()
    vim.cmd("RustRoutes")
    cap.restore()
    H.eq({}, cap.list)
    H.eq(1, #picked)
    local p = picked[1]
    H.eq("Routes", p.title)
    H.eq("file", p.preview)
    H.eq(2, #p.items)
    local routes = vim.tbl_map(function(i)
      return i.kind .. " " .. i.route
    end, p.items)
    table.sort(routes)
    H.eq({ "POST /h", "ROUTE /m" }, routes)
    for _, i in ipairs(p.items) do
      H.eq(dir, vim.fs.dirname(vim.fs.dirname(i.file)))
    end
  end)

  it("format() returns 4 chunks: kind padded to 7 (Keyword), route (String), detail (Function), rel (Comment)", function()
    local dir = crate({ ["src/main.rs"] = 'fn a(){ r.route("/m", get(m)); }\n' })
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/src/main.rs"))
    stub_snacks()
    R.pick()
    local p = H.ok(picked[1], "picker was not opened")
    local chunks = p.format(p.items[1])
    H.eq({
      { "ROUTE  ", "Keyword" },
      { "/m  ", "String" },
      { "get(m)  ", "Function" },
      { "src/main.rs", "Comment" },
    }, chunks)
    H.eq(7, #chunks[1][1])
    H.eq({ "GET    ", "Keyword" }, p.format({ kind = "GET", route = "/", detail = "d", rel = "r" })[1])
  end)
end)

describe("<leader>rN", function()
  it("maps to :RustRoutes buffer-locally when rust-analyzer attaches", function()
    -- the real LspAttach handler (keymaps.lua) needs a rust-analyzer client;
    -- hand it a fake one so the test stays independent of the server
    vim.cmd("doautocmd User VeryLazy")
    local dir = H.tmpdir()
    write(dir .. "/a.rs", "fn main() {}\n")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/a.rs"))
    local buf = vim.api.nvim_get_current_buf()
    local function lookup(b)
      return vim.api.nvim_buf_call(b, function()
        return vim.fn.maparg(vim.g.mapleader .. "rN", "n", false, true)
      end)
    end
    H.eq(0, vim.tbl_count(lookup(buf)) == 0 and 0 or 1, "map exists before attach")

    local orig = vim.lsp.get_client_by_id
    vim.lsp.get_client_by_id = function(id)
      if id == 987654 then
        return { name = "rust-analyzer", id = id }
      end
      return orig(id)
    end
    local ok, err = pcall(function()
      -- only this config's own handler: other LspAttach handlers expect a real client
      local acs = vim.api.nvim_get_autocmds({ event = "LspAttach", group = "xynovim_rust_keymaps" })
      H.eq(1, #acs)
      acs[1].callback({ buf = buf, data = { client_id = 987654 } })
      H.wait_for(function()
        return lookup(buf).rhs
      end, 20000, "<leader>rN map")
    end)
    vim.lsp.get_client_by_id = orig
    if not ok then
      error(err, 0)
    end
    local m = lookup(buf)
    H.eq("<cmd>rustroutes<cr>", m.rhs:lower())
    H.eq(1, m.buffer)
    H.eq("HTTP routes (axum / actix / rocket)", m.desc)
    -- not global: another buffer has no such map
    vim.cmd.enew()
    H.eq(0, vim.tbl_count(lookup(vim.api.nvim_get_current_buf())) == 0 and 0 or 1)
  end)
end)

describe("mixed-style scratch crate (README verification)", function()
  it("lists 4 routes with the right verbs, handlers and lines", function()
    local dir = H.tmpdir()
    write(dir .. "/Cargo.toml", '[package]\nname = "scratch"\nversion = "0.1.0"\nedition = "2021"\n')
    write(
      dir .. "/src/main.rs",
      table.concat({
        "use axum::{routing::get, Router};", -- 1
        "", -- 2
        '#[actix_web::post("/orders")]', -- 3
        "async fn create_order() {}", -- 4
        "", -- 5
        "fn app() -> Router {", -- 6
        "    Router::new()", -- 7
        '        .route("/health", get(health))', -- 8
        '        .route("/users/{id}", get(show).delete(remove))', -- 9
        "}", -- 10
        "",
        '#[get("/ping")]',
        "#[allow(dead_code)]",
        "async fn ping() {}",
      }, "\n") .. "\n"
    )
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local items = R.collect(dir)
    table.sort(items, function(a, b)
      return a.pos[1] < b.pos[1]
    end)
    local got = vim.tbl_map(function(i)
      return ("%s %s %s @%d"):format(i.kind, i.route, i.detail, i.pos[1])
    end, items)
    H.eq({
      "POST /orders create_order @3",
      "ROUTE /health get(health) @8",
      "ROUTE /users/{id} get(show).delete(remove) @9",
      "GET /ping ping @12",
    }, got)
  end)
end)
