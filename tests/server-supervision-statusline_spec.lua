-- Server supervision and the statusline with a live bacon-ls next to rust-analyzer, and the lualine
-- component. The modules are xyno_rust.rust_restart / xyno_rust.lsp_status (xyno-rust.nvim); its
-- repository has the fake-client specs and the rust-analyzer-only ones. These run both servers on scratch
-- crates and kill them (skipped without the Rust tools).
-- The live half takes a few minutes: run it with `scripts/test.sh --timeout 600`.
-- xyno-os: linux (POSIX signals and /proc on language server processes)
local H = require("xynotest.helpers")

local function fresh_restart()
  package.loaded["xyno_rust.rust_restart"] = nil
  local rr = require("xyno_rust.rust_restart")
  rr.setup()
  return rr
end

describe("lualine component", function()
  it("lualine_x[1] is the component, shown only when it is non-empty", function()
    local status = require("xyno_rust.lsp_status")
    local spec = dofile(H.repo .. "/lua/plugins/lualine.lua")
    local opts = { sections = { lualine_x = { "other" } } }
    spec.opts(nil, opts)
    H.eq("other", opts.sections.lualine_x[2])
    local item = opts.sections.lualine_x[1]
    H.eq(status.component, item[1])
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(b)
    H.eq(false, item.cond())
    vim.b[b].xyno_rust_stopped = { bacon_ls = true }
    H.eq(true, item.cond())
    -- the running lualine got the same
    local ok, lualine = pcall(require, "lualine")
    if ok then
      local x = lualine.get_config().sections.lualine_x
      H.eq(status.component, x[1][1])
    end
  end)
end)

-- ====================================================================== live

describe("live servers", function()
  local status = require("xyno_rust.lsp_status")
  local crate, buf, lib

  local function bacon()
    return H.clients(nil, "bacon_ls")[1]
  end
  local function ra()
    return H.clients(nil, "rust-analyzer")[1]
  end
  local function comp()
    return status.component()
  end
  local function state()
    local names = vim.tbl_map(function(c)
      return c.name .. "#" .. c.id
    end, vim.lsp.get_clients())
    return ("component %q, clients %s, buf %s"):format(comp(), table.concat(names, ","), vim.api.nvim_buf_get_name(0))
  end
  --- finished and idle: "clippy ok", or "clippy 1E" while the crate has a clippy error on screen
  local function ready()
    local c = comp()
    return c == "RA ready | clippy ok" or c:match("^RA ready | clippy %d+E$") ~= nil
  end
  local function wait_ready(msg)
    if not vim.wait(120000, ready, 20) then
      error((msg or "'RA ready | clippy ok'") .. ": " .. state(), 2)
    end
  end
  local function sh(cmd)
    local r = vim.system({ "bash", "-c", cmd }, { cwd = crate, text = true }):wait(30000)
    H.eq(0, r.code, r.stderr)
  end
  local function focus()
    vim.cmd("doautocmd FocusGained")
  end
  local function bacon_diags(c)
    c = c or bacon()
    local n = {}
    for _, d in ipairs(vim.diagnostic.get(buf)) do
      local ns = vim.diagnostic.get_namespaces()[d.namespace]
      if ns and ns.name:find(("%d"):format(c.id), 1, true) and ns.name:find("bacon", 1, true) then
        n[#n + 1] = d
      end
    end
    return n
  end
  --- pid of the language server process of client `c`: a direct child of THIS
  --- nvim whose command is the server's binary (vim.lsp.rpc exposes no pid)
  local function pid(c)
    if not c then
      return nil
    end
    local comm = c.name == "bacon_ls" and "bacon-ls" or c.name
    local out = vim.fn.systemlist({ "ps", "-o", "pid=,comm=", "--ppid", tostring(vim.uv.os_getpid()) })
    local found
    for _, l in ipairs(out) do
      local p, name = l:match("^%s*(%d+)%s+(.+)$")
      if name == comm then
        found = tonumber(p) -- the newest one wins (ps lists by pid)
      end
    end
    return found
  end
  --- wait for a bacon_ls client attached to buf whose id is not `old_id`
  local function new_bacon(old_id, ms)
    return H.wait_for(function()
      local c = bacon()
      return c and c.id ~= old_id and H.clients(buf, "bacon_ls")[1]
    end, ms or 60000, "a new bacon_ls client")
  end

  before_each(function()
    H.need_rust()
    if vim.fn.executable("bacon-ls") ~= 1 then
      skip("bacon-ls not found")
    end
    if not crate then
      crate = H.fixture("basic", { git = true })
      vim.cmd.cd(vim.fn.fnameescape(crate))
      lib = crate .. "/src/lib.rs"
    end
  end)

  it("status sequence on a scratch crate: starting/running -> loading/indexing -> ready/ok, then stale -> running -> ok", function()
    local samples = {}
    local function sample()
      local c = comp()
      if c ~= "" and samples[#samples] ~= c then
        samples[#samples + 1] = c
      end
    end
    local au = vim.api.nvim_create_autocmd({ "LspAttach", "LspProgress" }, { callback = sample })
    buf = H.open(lib)
    if not vim.wait(120000, function()
      sample()
      return comp() == "RA ready | clippy ok"
    end, 20) then
      error("ready and ok: " .. state() .. " samples: " .. vim.inspect(samples))
    end
    vim.api.nvim_del_autocmd(au)
    local seq = table.concat(samples, "\n")
    H.match(seq, "RA starting", true)
    H.match(seq, "clippy running", true)
    H.match(seq, "RA %S.* %d+%%", false, "a progress line with a percentage")
    H.eq("RA ready | clippy ok", samples[#samples])

    -- an edit: stale -> running -> ok
    samples = {}
    local au2 = vim.api.nvim_create_autocmd({ "LspProgress" }, { callback = sample })
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "// edit" })
    sample()
    H.eq("RA ready | clippy stale", comp())
    H.wait_for(function()
      sample()
      return #samples > 1 and comp() == "RA ready | clippy ok"
    end, 60000, "stale -> running -> ok; samples: " .. vim.inspect(samples))
    vim.api.nvim_del_autocmd(au2)
    H.eq({ "RA ready | clippy stale", "RA ready | clippy running", "RA ready | clippy ok" }, samples)
  end)

  it("typing with auto-save on settles on 'clippy ok', not stale", function()
    vim.cmd.buffer(buf)
    H.feed("Goconst TYPED: i32 = 1;<Esc>")
    if not vim.wait(20000, function()
      return table.concat(vim.fn.readfile(lib), "\n"):find("TYPED", 1, true) ~= nil
    end, 50) then
      error("auto-save did not write the typed line: " .. vim.inspect(vim.api.nvim_buf_get_lines(buf, -5, -1, false)))
    end
    H.wait_for(function()
      return comp() == "RA ready | clippy ok"
    end, 60000, "'clippy ok' after the auto-save; is " .. comp())
    vim.wait(2500, function()
      return comp() ~= "RA ready | clippy ok"
    end, 50)
    H.eq("RA ready | clippy ok", comp(), "stays ok")
    H.match(table.concat(vim.fn.readfile(lib), "\n"), "const TYPED: i32 = 1;", true)
  end)

  it("sed -i on an open file then FocusGained restarts bacon-ls and the new clippy error appears", function()
    vim.cmd.buffer(buf)
    vim.cmd("silent! write")
    local old = bacon()
    -- clippy::eq_op is deny-by-default: an error that only clippy reports
    sh([[sed -i 's/return 42;/if 1 == 1 { return 1; } return 42;/' src/lib.rs]])
    focus()
    local new = new_bacon(old.id)
    H.match(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[17] or table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "1 == 1", true)
    H.wait_for(function()
      return #bacon_diags(new) > 0
    end, 90000, "clippy diagnostics from the new bacon-ls")
    local msgs = vim.tbl_map(function(d)
      return d.message
    end, bacon_diags(new))
    -- the message quotes the source line: it is the NEW content, not the shadow's old one
    H.match(table.concat(msgs, "\n"), "1 == 1", true)
    wait_ready()
  end)

  it("files not open in nvim changed on disk without a HEAD move are not noticed", function()
    local old = bacon()
    sh([[sed -i 's/println!/print!/' src/main.rs]])
    focus()
    vim.wait(2500, function()
      return bacon() == nil or bacon().id ~= old.id
    end, 50)
    H.ok(bacon() and bacon().id == old.id, "bacon-ls was not restarted")
  end)

  it("a new commit (HEAD moved) restarts bacon-ls on FocusGained; no change does not", function()
    local old = bacon()
    focus()
    vim.wait(2500, function()
      return bacon() == nil or bacon().id ~= old.id
    end, 50)
    H.ok(bacon() and bacon().id == old.id, "no change, no restart")
    H.git(crate, "commit", "-q", "--allow-empty", "-m", "moved")
    focus()
    local new = new_bacon(old.id)
    H.ok(new)
    wait_ready()
  end)

  it("a broken manifest gives 'clippy failed', repairing it gives 'clippy ok'", function()
    -- Cargo.toml open in nvim: its reload on FocusGained is what triggers the bacon-ls restart
    -- (in a window: checktime does not reload a hidden buffer)
    vim.cmd("split " .. vim.fn.fnameescape(crate .. "/Cargo.toml"))
    local toml = vim.api.nvim_get_current_buf()
    vim.cmd("wincmd p")
    local old = bacon()
    sh([[sed -i 's/^\[package\]/[packge]/' Cargo.toml]])
    focus()
    new_bacon(old.id)
    H.wait_for(function()
      return comp():find("clippy failed", 1, true) and true or false
    end, 60000, "'clippy failed'; is " .. comp())
    local broken = bacon()
    sh([[sed -i 's/^\[packge\]/[package]/' Cargo.toml]])
    focus()
    new_bacon(broken.id)
    H.wait_for(ready, 90000, "'clippy ok' after the repair; is " .. comp())
    pcall(vim.api.nvim_buf_delete, toml, { force = true })
    vim.cmd.buffer(buf)
  end)

  it("deleting a crate under a live bacon-ls client removes the client after FocusGained", function()
    local dir2 = H.fixture("basic", { git = true })
    local b2 = H.open(dir2 .. "/src/lib.rs")
    H.wait_for(function()
      for _, c in ipairs(H.clients(b2, "bacon_ls")) do
        if c.config.root_dir == dir2 then
          return c
        end
      end
    end, 60000, "bacon_ls for the second crate")
    vim.fn.delete(dir2, "rf")
    focus()
    H.wait_for(function()
      for _, c in ipairs(H.clients(nil, "bacon_ls")) do
        if c.config.root_dir == dir2 then
          return false
        end
      end
      return true
    end, 20000, "the client of the deleted crate to be gone")
    pcall(vim.api.nvim_buf_delete, b2, { force = true })
    vim.cmd.buffer(buf)
  end)

  it("kill -9 of both servers: 'RA stopped | clippy stopped', then both back with new pids and ok + clippy diagnostics", function()
    vim.cmd.buffer(buf)
    fresh_restart()
    local ra_old, bc_old = ra(), bacon()
    local pids = { ra = pid(ra_old), bc = pid(bc_old) }
    H.ok(pids.ra and pids.bc, "client pids")
    H.ok(pids.ra ~= pids.bc)
    vim.uv.kill(pids.ra, "sigkill")
    vim.uv.kill(pids.bc, "sigkill")
    H.wait_for(function()
      return comp() == "RA stopped | clippy stopped"
    end, 15000, "'RA stopped | clippy stopped'; is " .. comp())
    wait_ready("both servers back; is " .. comp())
    local ra_new, bc_new = ra(), bacon()
    H.ok(ra_new.id ~= ra_old.id and bc_new.id ~= bc_old.id, "new clients")
    H.ok(pid(ra_new) ~= pids.ra and pid(bc_new) ~= pids.bc, "new pids")
    H.wait_for(function()
      return #bacon_diags(bc_new) > 0
    end, 90000, "clippy diagnostics from the new bacon-ls")
  end)

  it(":RustRestart revives SIGSTOPped (hung) rust-analyzer and bacon-ls: new pids, ok again", function()
    vim.cmd.buffer(buf)
    fresh_restart()
    wait_ready()
    local ra_old, bc_old = ra(), bacon()
    local pids = { ra = pid(ra_old), bc = pid(bc_old) }
    H.ok(pids.ra and pids.bc, "client pids")
    vim.uv.kill(pids.ra, "sigstop")
    vim.uv.kill(pids.bc, "sigstop")
    local ok, err = pcall(function()
      vim.cmd("RustRestart")
      H.wait_for(function()
        local r, b = ra(), bacon()
        return r and b and r.id ~= ra_old.id and b.id ~= bc_old.id and pid(r) ~= pids.ra and pid(b) ~= pids.bc
      end, 60000, "new clients with new pids; is " .. state())
      wait_ready("both servers back after the hang; is " .. state())
    end)
    for _, p in pairs(pids) do
      vim.uv.kill(p, "sigkill") -- whatever is left of the stopped ones
    end
    if not ok then
      error(err, 0)
    end
  end)

  it("a SIGTERM exit counts as abnormal and restarts the server", function()
    vim.cmd.buffer(buf)
    fresh_restart()
    local cap = H.capture_notify()
    local old = bacon()
    vim.uv.kill(pid(old), "sigterm")
    new_bacon(old.id)
    local seen
    for _, n in ipairs(cap.list) do
      if n.msg:find("bacon_ls exited", 1, true) then
        seen = n
      end
    end
    H.ok(seen, "an 'exited' warning; got " .. vim.inspect(cap.list))
    H.match(seen.msg, "signal 15", true)
    H.eq(vim.log.levels.WARN, seen.level)
    wait_ready()
    cap.restore()
  end)

  it("four quick kills end at 'clippy stopped'; :RustRestart revives it", function()
    vim.cmd.buffer(buf)
    fresh_restart()
    local cap = H.capture_notify()
    local c = bacon()
    for i = 1, 3 do
      vim.uv.kill(pid(c), "sigkill")
      c = new_bacon(c.id)
    end
    vim.uv.kill(pid(c), "sigkill")
    H.wait_for(function()
      for _, n in ipairs(cap.list) do
        if n.level == vim.log.levels.ERROR and n.msg:find("keeps exiting", 1, true) then
          return true
        end
      end
    end, 20000, "the give-up error; got " .. vim.inspect(cap.list))
    vim.wait(2500, function()
      return bacon() ~= nil and not bacon().is_stopped()
    end, 50)
    H.eq("clippy stopped", status.bacon(buf), "no automatic restart; is " .. comp())
    cap.restore()
    vim.cmd("RustRestart")
    wait_ready("clippy back after :RustRestart; is " .. comp())
    H.ok(bacon())
  end)
end)
