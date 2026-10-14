-- config.crate_import: import from crates that are not dependencies yet (the
-- async import-engine source, the add-and-wait path, crate_add's action wiring).
-- Hermetic except the last test: that one adds a real crate from crates.io to a
-- copy of the no-deps-lab fixture, waits for the real rust-analyzer and builds;
-- it skips without network, cargo or rust-analyzer.
local H = require("xynotest.helpers")
local ci = require("config.crate_import")
local E = require("config.import_engine")
local cm = require("config.crate_meta")
local ca = require("config.code_actions")
local cadd = require("config.crate_add")

local restores = {}
local function stub(t, k, v)
  local orig = t[k]
  t[k] = v
  restores[#restores + 1] = function()
    t[k] = orig
  end
end

after_each(function()
  for i = #restores, 1, -1 do
    pcall(restores[i])
  end
  restores = {}
  pcall(vim.cmd, "silent! %bwipeout!")
end)

--- Run the source and wait for its answer.
local function ask(name, ctx)
  local got
  ci.source(name, ctx or {}, function(list)
    got = list
  end)
  H.wait_for(function()
    return got
  end, 5000, "the source's answer")
  return got
end

local function paths(list)
  return vim.tbl_map(function(c)
    return c.path
  end, list)
end

local function no_meta()
  stub(cm, "metadata_async", function(_, cb)
    vim.schedule(function()
      cb(nil, "stubbed")
    end)
  end)
end

describe("crate_import.source", function()
  it("fills gaps only: nothing when rust-analyzer offered candidates", function()
    stub(cm, "search_async", function()
      error("must not search")
    end)
    H.eq({}, ask("Uuid", { local_candidates = { { path = "uuid::Uuid" } } }))
  end)

  it("a lowercase name that is a crate on crates.io: the crate itself, as an add-crate candidate", function()
    no_meta()
    local asked = {}
    stub(cm, "info_async", function(name, cb)
      asked[#asked + 1] = name
      vim.schedule(function()
        cb(name == "rand" and { name = "rand", newest = "0.9.1" } or nil, "not found")
      end)
    end)
    local out = ask("rand", { root = "/x" })
    H.eq({ "rand" }, paths(out))
    H.eq({ "rand" }, asked)
    H.ok(out[1].add_crate and out[1].crate == "rand" and not out[1].guess)
    H.match(out[1].note, "rand 0.9.1", true)
  end)

  it("a path head with an underscore also tries the dashed crate name", function()
    no_meta()
    stub(cm, "info_async", function(name, cb)
      vim.schedule(function()
        cb(name == "serde-json" and { name = "serde-json", newest = "1.0.0" } or nil, "not found")
      end)
    end)
    local out = ask("serde_json")
    H.eq({ "serde_json" }, paths(out))
    H.eq("serde_json", out[1].crate)
  end)

  it("an item name: crates whose name equals or contains it, by downloads, labelled as guesses", function()
    no_meta()
    stub(cm, "search_async", function(q, cb)
      H.eq("uuid", q)
      vim.schedule(function()
        cb({
          { name = "uuid-simd", version = "0.8.0", downloads = 5 },
          { name = "uuid", version = "1.10.0", downloads = 900 },
          { name = "unrelated", version = "1.0.0", downloads = 99999 },
          { name = "-uuid", version = "1.0.0", downloads = 1 }, -- would be an argv flag
          { name = "my_uuid_x", version = "1.0.0", downloads = 50 },
        })
      end)
    end)
    local out = ask("Uuid")
    H.eq({ "uuid::Uuid", "my_uuid_x::Uuid", "uuid_simd::Uuid" }, paths(out))
    for _, c in ipairs(out) do
      H.ok(c.guess and c.add_crate and type(c.apply) == "function")
      H.match(c.note, "guess", true)
    end
  end)

  it("never guesses for very short names, never for a crate that is already a dependency", function()
    no_meta()
    stub(cm, "search_async", function()
      error("must not search")
    end)
    H.eq({}, ask("Ab"))
    local root = H.tmpdir()
    stub(cm, "metadata_async", function(_, cb)
      vim.schedule(function()
        cb({ dependencies = { { name = "uuid", kind = "normal", member = "m" } } })
      end)
    end)
    stub(cm, "search_async", function(_, cb)
      vim.schedule(function()
        cb({ { name = "uuid", version = "1", downloads = 1 } })
      end)
    end)
    H.eq({}, ask("Uuid", { root = root }))
  end)

  it("offline or failing lookups give no candidates and no error", function()
    no_meta()
    stub(cm, "search_async", function(_, cb)
      vim.schedule(function()
        cb(nil, "offline")
      end)
    end)
    stub(cm, "info_async", function(_, cb)
      vim.schedule(function()
        cb(nil, "offline")
      end)
    end)
    H.eq({}, ask("Uuid"))
    H.eq({}, ask("rand"))
  end)
end)

describe("the import engine with the source", function()
  it("resolve() lists the guesses after rust-analyzer's candidates, labelled; sources = false skips them", function()
    no_meta()
    stub(cm, "search_async", function(_, cb)
      vim.schedule(function()
        cb({ { name = "uuid", version = "1.10.0", downloads = 900 } })
      end)
    end)
    stub(ca, "request", function(_, _, _, cb)
      vim.schedule(function()
        cb({}, nil)
      end)
    end)
    stub(ca, "clients", function()
      return { {} }
    end)
    ci.setup()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fn main() {", "    let id = Uuid::nil();", "}" })
    local res
    E.resolve("Uuid", {
      bufnr = buf,
      cb = function(r)
        res = r
      end,
    })
    H.wait_for(function()
      return res
    end, 8000, "resolve")
    H.eq({ "uuid::Uuid" }, paths(res.candidates))
    H.ok(res.candidates[1].add_crate and res.candidates[1].guess)
    H.match(E.format_item(res.candidates[1]), "(guess)", true)
    H.match(E.format_item(res.candidates[1]), "adds the crate", true)
    H.is_nil(res.choice, "a crate-adding guess is never taken automatically")
    local plain
    E.resolve("Uuid", {
      bufnr = buf,
      sources = false,
      cb = function(r)
        plain = r
      end,
    })
    H.wait_for(function()
      return plain
    end, 8000, "resolve without sources")
    H.eq({}, plain.candidates)
  end)

  it("a slow source does not hold resolve() beyond source_wait_ms", function()
    local un = E.register_source(function(_, _, cb) end, { async = true })
    stub(E.config, "source_wait_ms", 300)
    stub(ca, "request", function(_, _, _, cb)
      vim.schedule(function()
        cb({}, nil)
      end)
    end)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fn main() { Foo; }" })
    local t0, res = vim.uv.now(), nil
    E.resolve("Foo", {
      bufnr = buf,
      cb = function(r)
        res = r
      end,
    })
    H.wait_for(function()
      return res
    end, 8000, "resolve")
    un()
    H.ok(vim.uv.now() - t0 < 3000)
  end)
end)

describe("crate_import.add_and_import", function()
  local function setup_buf()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fn main() {", "    let id = Uuid::nil();", "}" })
    return buf
  end

  it("adds the crate, polls until rust-analyzer offers the import, applies the one of that crate", function()
    local buf = setup_buf()
    stub(ci.config, "poll_ms", 20)
    local added
    stub(cadd, "add_direct", function(_, name, cb)
      added = name
      vim.schedule(function()
        cb(true, "added")
      end)
    end)
    local polls, applied = 0, nil
    stub(E, "candidates_at", function(_, pos, cb)
      polls = polls + 1
      H.eq({ 1, 13 }, { pos.row, pos.col })
      vim.schedule(function()
        if polls < 3 then
          return cb({ E.candidate("std::fmt::Debug") }) -- someone else's, not the crate's
        end
        cb({ E.candidate("uuid::fmt::Uuid"), E.candidate("uuid::Uuid"), E.candidate("other::Uuid") })
      end)
    end)
    stub(E, "apply_candidate", function(_, cand, cb)
      applied = cand.path
      cb(true)
    end)
    local done, ok, msg
    ci.add_and_import(buf, { crate = "uuid", name = "Uuid", path = "uuid::Uuid" }, function(a, b)
      done, ok, msg = true, a, b
    end)
    H.wait_for(function()
      return done
    end, 5000, "add and import")
    H.eq("uuid", added)
    H.eq(true, ok, tostring(msg))
    H.eq("uuid::Uuid", applied)
    H.ok(polls >= 3)
    H.match(msg, "imported uuid::Uuid", true)
  end)

  it("gives up after the bounded wait, the crate stays added", function()
    local buf = setup_buf()
    stub(ci.config, "poll_ms", 20)
    stub(ci.config, "reload_timeout_ms", 150)
    stub(cadd, "add_direct", function(_, _, cb)
      vim.schedule(function()
        cb(true, "added")
      end)
    end)
    stub(E, "candidates_at", function(_, _, cb)
      vim.schedule(function()
        cb({})
      end)
    end)
    local done, ok, msg
    ci.add_and_import(buf, { crate = "uuid", name = "Uuid" }, function(a, b)
      done, ok, msg = true, a, b
    end)
    H.wait_for(function()
      return done
    end, 5000, "timeout")
    H.eq(false, ok)
    H.match(msg, "did not offer an import", true)
  end)

  it("a failed add stops there; an invalid crate name never reaches cargo", function()
    local buf = setup_buf()
    stub(cadd, "add_direct", function(_, _, cb)
      vim.schedule(function()
        cb(false, "no network")
      end)
    end)
    local done, ok, msg
    ci.add_and_import(buf, { crate = "uuid", name = "Uuid" }, function(a, b)
      done, ok, msg = true, a, b
    end)
    H.wait_for(function()
      return done
    end, 5000, "failed add")
    H.eq({ false, "no network" }, { ok, msg })
    local bad
    ci.add_and_import(buf, { crate = "--git=x" }, function(a, b)
      bad = { a, b }
    end)
    H.eq({ false, "invalid crate name" }, bad)
    bad = nil
    ci.add_and_import(buf, { crate = "a b; rm" }, function(a, b)
      bad = { a, b }
    end)
    H.eq(false, bad[1])
  end)

  it("a name without an import (a path head) only adds", function()
    local buf = setup_buf()
    local polled = false
    stub(cadd, "add_direct", function(_, _, cb)
      vim.schedule(function()
        cb(true, "added rand")
      end)
    end)
    stub(E, "candidates_at", function()
      polled = true
    end)
    local done, ok
    ci.add_and_import(buf, { crate = "rand" }, function(a)
      done, ok = true, a
    end)
    H.wait_for(function()
      return done
    end, 3000, "add only")
    H.eq(true, ok)
    H.eq(false, polled)
  end)
end)

describe("crate_add's action uses the same path", function()
  it("the 'Add crate X' command of the in-process server calls add_and_import", function()
    local buf = vim.api.nvim_create_buf(true, false)
    local got
    stub(ci, "add_and_import", function(b, spec)
      got = { b, spec.crate, spec.name }
    end)
    local srv = cadd.server({})
    srv.request("workspace/executeCommand", { command = "xynovim.crateAdd", arguments = { { name = "rand", bufnr = buf } } }, function() end)
    H.eq({ buf, "rand", nil }, got)
    got = nil
    srv.request("workspace/executeCommand", { command = "xynovim.crateAdd", arguments = { { name = "--git", bufnr = buf } } }, function() end)
    H.is_nil(got, "a flag-like name is refused")
  end)
end)

describe("real: Uuid from nothing", function()
  it("search, add the crate, wait for rust-analyzer, import, cargo build", function()
    H.need_rust()
    local info = cm.info("uuid", { index_only = true })
    if not info then
      return skip("crates.io is not reachable")
    end
    local dir = H.fixture("no-deps-lab")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/src/main.rs")
    H.wait_lsp("rust-analyzer", buf)
    ci.setup()
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
    H.ok(cand, "uuid::Uuid is among " .. vim.inspect(paths(res.candidates)))
    H.ok(cand.add_crate and cand.guess)
    local done, ok, msg
    E.apply_candidate(buf, cand, function(a, b)
      done, ok, msg = true, a, b
    end)
    H.wait_for(function()
      return done
    end, 120000, "add and import")
    H.eq(true, ok, tostring(msg))
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    H.match(text, "use uuid::Uuid;", true)
    local toml = table.concat(vim.fn.readfile(dir .. "/Cargo.toml"), "\n")
    H.match(toml, "uuid", true)
    vim.cmd("silent write")
    local r = vim.system({ "cargo", "check", "--quiet", "--target-dir", H.tmpdir() }, { cwd = dir, text = true }):wait(170000)
    H.eq(0, r.code, (r.stderr or ""):sub(-1500))
  end)
end)
