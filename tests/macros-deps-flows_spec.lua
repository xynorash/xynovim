-- xyno-timeout: 600
-- Cross-module flows of the macros-and-dependencies phase, each on a temp copy
-- of a fixture with the real modules wired together (no stubs of the modules
-- under test):
--   (a) a name no dependency offers -> "Add crate and import" -> builds
--       (no-deps-lab; real crates.io, cargo add, rust-analyzer, cargo check)
--   (b) serde without `derive` -> "Enable feature" -> builds
--       (deps-lab-nofeature; the diagnostic is hand-made like bacon-ls writes it)
--   (c) attribute completion inside #[serde( after (b), accepting a key and its value (deps-lab-nofeature, real cargo metadata)
--   (d) an ambiguous `Error` is left alone by auto-import until a choice is
--       remembered, then imported and builds (deps-lab, real rust-analyzer)
-- Each flow skips with a message without the tool or network it needs.
local H = require("xynotest.helpers")
local E = require("xyno_imports.engine")
local ci = require("xyno_crates.crate_import")
local cf = require("xyno_crates.crate_features")
local ma = require("xyno_macros.attrs")
local cm = require("xyno_rust.crate_meta")
local ca = require("xyno_rust.code_actions")

local restores = {}
local function stub(t, k, v)
  local orig = t[k]
  t[k] = v
  restores[#restores + 1] = function()
    t[k] = orig
  end
end

before_each(function()
  stub(E, "state_file", H.tmpdir() .. "/state/imports.json")
  E.reload_memory()
end)

after_each(function()
  for i = #restores, 1, -1 do
    pcall(restores[i])
  end
  restores = {}
  E.reload_memory()
  cm.invalidate()
  pcall(vim.cmd, "silent! %bwipeout!")
end)

local function read(path)
  local f = assert(io.open(path, "r"))
  local t = f:read("*a")
  f:close()
  return t
end

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function cargo_check(dir, offline)
  local argv = { "cargo", "check", "--quiet", "--target-dir", H.tmpdir() }
  if offline then
    table.insert(argv, 3, "--offline")
  end
  return vim.system(argv, { cwd = dir, text = true }):wait(170000)
end

local function names(list)
  return vim.tbl_map(function(a)
    return a.label or a.title or a.path
  end, list)
end

-- ----------------------------------------------------------------------- (a)

describe("flow (a): unknown crate -> add crate and import -> builds", function()
  it("Uuid in a crate without dependencies", function()
    H.known_issue({ "windows" }, "live rust-analyzer flow fails or hangs on Windows (windows-latest run 39647013043; cause not diagnosed)")
    H.need_rust()
    if not cm.info("uuid", { index_only = true }) then
      return skip("crates.io is not reachable")
    end
    local dir = H.fixture("no-deps-lab")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/src/main.rs")
    H.wait_lsp("rust-analyzer", buf)
    ci.setup()
    -- the picker's list: rust-analyzer offers nothing, crates.io guesses do
    local res
    E.resolve("Uuid", {
      bufnr = buf,
      cb = function(r)
        res = r
      end,
    })
    H.wait_for(function()
      return res
    end, 60000, "resolve")
    local cand
    for _, c in ipairs(res.candidates) do
      if c.path == "uuid::Uuid" then
        cand = c
      end
    end
    H.ok(cand and cand.add_crate and cand.guess, "the guess is offered: " .. vim.inspect(names(res.candidates)))
    -- the choice goes through the picker seam (what :ImportName does)
    stub(E, "select", function(items, _, on_choice)
      for _, it in ipairs(items) do
        if it.path == "uuid::Uuid" then
          return on_choice(it)
        end
      end
      on_choice(nil)
    end)
    local cap = H.capture_notify()
    vim.api.nvim_win_set_cursor(0, { 3, 13 })
    E.import_name("Uuid")
    H.wait_for(function()
      return text(buf):find("use uuid::Uuid;", 1, true)
    end, 120000, "the import")
    cap.restore()
    H.match(read(dir .. "/Cargo.toml"), "uuid", true)
    vim.cmd("silent write")
    local r = cargo_check(dir)
    H.eq(0, r.code, (r.stderr or ""):sub(-1500))
  end)
end)

-- ------------------------------------------------------------------ (b) + (c)

--- A copy of deps-lab-nofeature (nil + skip when the registry lacks its crates).
local function nofeature()
  H.need_rust()
  local dir = H.fixture("deps-lab-nofeature")
  local meta, err = cm.metadata(dir)
  if not meta then
    skip("registry lacks the fixture's crates offline: " .. tostring(err):sub(1, 100))
  end
  return dir
end

--- The buffer of dir/src/main.rs with the in-process feature client and the
--- diagnostic of the first `#[derive(.., Serialize ..)]`, as bacon-ls reports it.
local function derive_buffer(dir)
  local main = dir .. "/src/main.rs"
  local lines = vim.fn.readfile(main)
  local lnum
  for i, l in ipairs(lines) do
    if l:find("#[derive(Debug, Serialize, Deserialize)]", 1, true) then
      lnum = i - 1
    end
  end
  H.ok(lnum, "fixture still derives Serialize")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, main)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = ""
  cf.attach(buf)
  H.eq(1, #vim.lsp.get_clients({ bufnr = buf, name = cf.client_name }), "the in-process client attached")
  local ns = vim.api.nvim_create_namespace("flows-spec")
  vim.diagnostic.set(ns, buf, {
    { lnum = lnum, col = 0, end_lnum = lnum, end_col = 5, severity = 1, message = "cannot find derive macro `Serialize` in this scope", source = "bacon-ls" },
  })
  return buf, lnum
end

describe("flow (b): serde without derive -> enable the feature -> builds", function()
  it("the action edits Cargo.toml, cargo check passes", function()
    local dir = nofeature()
    local buf, lnum = derive_buffer(dir)
    stub(ca, "client_name", cf.client_name)
    local list = ca.request_wait(buf, { start = { lnum, 0 }, ["end"] = { lnum, 1 } }, {})
    local hits = ca.filter(list, { title = "Enable feature `derive` of `serde`", plain = true })
    H.eq(1, #hits, vim.inspect(names(list)))
    local ok, err = ca.apply(hits[1], { timeout = 60000 })
    H.eq(true, ok, tostring(err))
    H.match(read(dir .. "/Cargo.toml"), 'serde = { version = "1", features = ["derive"] }', true)
    local r = cargo_check(dir, true)
    H.eq(0, r.code, (r.stderr or ""):sub(-1500))
  end)
end)

describe("flow (c): attribute completion on a crate whose feature was just enabled", function()
  it("#[serde( after the feature fix: the keys, accepting rename_all and then camelCase", function()
    local dir = nofeature()
    local buf, lnum = derive_buffer(dir)
    -- an empty #[serde()] on the struct, cursor inside the parentheses
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local arow
    for i = lnum + 2, #lines do
      if lines[i]:find("#[serde(", 1, true) then
        arow = i
        break
      end
    end
    H.ok(arow, "the struct has a #[serde(...)] line")
    lines[arow] = "#[serde()]"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local col = #"#[serde("
    local function labels()
      cm.invalidate()
      -- real metadata first: before it has loaded the source guesses from Cargo.toml
      -- and cannot tell that serde's derive feature is off
      H.ok(cm.metadata(dir), "cargo metadata")
      local items = ma.items(buf, arow, col)
      return vim.tbl_map(function(i)
        return i.label
      end, items), items
    end
    -- (the schema is offered by dependency + derive on the item, not by the crate's
    -- features: the keys are also listed while serde's derive feature is off; the
    -- feature fix is what makes the attribute compile)
    -- (b): enable the feature, as the code action does
    stub(ca, "client_name", cf.client_name)
    local list = ca.request_wait(buf, { start = { lnum, 0 }, ["end"] = { lnum, 1 } }, {})
    local hits = ca.filter(list, { title = "Enable feature `derive` of `serde`", plain = true })
    H.eq(1, #hits)
    H.eq(true, (ca.apply(hits[1], { timeout = 60000 })))
    local after, items = labels()
    H.ok(vim.tbl_contains(after, "rename_all"), "serde keys are offered: " .. table.concat(after, " "))
    -- accept rename_all: a snippet with the cursor inside the quotes
    local item
    for _, it in ipairs(items) do
      if it.label == "rename_all" then
        item = it
      end
    end
    H.eq(vim.lsp.protocol.InsertTextFormat.Snippet, item.insertTextFormat)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { arow, col })
    vim.cmd("startinsert")
    vim.snippet.expand(item.insertText)
    H.eq('#[serde(rename_all = "")]', vim.api.nvim_buf_get_lines(buf, arow - 1, arow, false)[1])
    -- the values menu inside the quotes, accept camelCase
    local cur = vim.api.nvim_win_get_cursor(0)
    local values = ma.items(buf, cur[1], cur[2])
    local value
    for _, it in ipairs(values) do
      if it.label == "camelCase" then
        value = it
      end
    end
    H.ok(value, "the values of rename_all are offered inside the quotes: " .. table.concat(vim.tbl_map(function(i)
      return i.label
    end, values), " "))
    vim.snippet.stop()
    vim.api.nvim_put({ value.insertText }, "c", false, true)
    vim.cmd("stopinsert")
    H.eq('#[serde(rename_all = "camelCase")]', vim.api.nvim_buf_get_lines(buf, arow - 1, arow, false)[1])
  end)
end)

-- ----------------------------------------------------------------------- (d)

describe("flow (d): an ambiguous Error import with a remembered choice", function()
  it("auto-import leaves Error alone, then applies the remembered std::io::Error, builds", function()
    H.need_rust()
    local dir = H.fixture("deps-lab")
    if not cm.metadata(dir) then
      return skip("registry lacks the deps-lab crates offline")
    end
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/src/main.rs")
    H.wait_lsp("rust-analyzer", buf)
    local lines = vim.fn.readfile(dir .. "/src/main.rs")
    vim.list_extend(lines, { "", "#[allow(dead_code)]", "fn lonely() -> Result<(), Error> {", "    Ok(())", "}" })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local row = #lines - 3 -- the `fn lonely` line, 0-based
    local ecol = lines[row + 1]:find("Error", 1, true) - 1
    local hits = ca.wait_for(buf, { start = { row, ecol }, ["end"] = { row, ecol + 5 } }, { kind = "quickfix", title = "^Import `std::io::Error`" }, { timeout = 120000, only = { "quickfix" } })
    H.ok(#hits > 0, "rust-analyzer offers the std::io::Error import")
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("let &undolevels = &undolevels")
    end)
    local function run()
      local done, n
      E.run(buf, 0, #lines - 1, {
        mode = "single",
        done = function(c)
          done, n = true, c
        end,
      })
      H.wait_for(function()
        return done
      end, 60000, "import run")
      return n
    end
    -- several candidates and no memory: never guessed
    H.eq(0, run())
    H.no_match(text(buf), "use std::io::Error", true)
    -- the project remembers a choice (what :ImportName does after a pick)
    local root = cm.root(dir .. "/src/main.rs")
    E.remember(root, "Error", "std::io::Error")
    H.eq(1, run())
    H.match(text(buf), "use std::io::Error;", true)
    vim.cmd("silent write")
    local r = cargo_check(dir, true)
    H.eq(0, r.code, (r.stderr or ""):sub(-1500))
  end)
end)
