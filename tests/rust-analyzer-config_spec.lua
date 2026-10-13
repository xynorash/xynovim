-- rust-analyzer configuration (lua/plugins/rustaceanvim.lua, editing-ui.lua,
-- domain.lua): the effective settings the server really gets, the two
-- diagnostic tiers, codelens/inlay hints, taplo, wgsl-analyzer, kulala.
-- Needs rust-analyzer and cargo (run with TEST_TIMEOUT=600); tests that need Mason's taplo / wgsl-analyzer,
-- the network, curl or python3 skip with a message when those are missing.
local H = require("xynotest.helpers")
local harness = require("xynotest.harness")

local Config = require("lazy.core.config")
local Plugin = require("lazy.core.plugin")

--- Merged `opts` of a lazy plugin, as the plugin's setup() would receive them.
local function opts_of(name)
  return Plugin.values(Config.plugins[name], "opts", false)
end

local function ra_opts()
  return opts_of("rustaceanvim").server
end

-- Messages the servers push (window/showMessage, window/logMessage), collected
-- from before the first attach on.
local server_msgs = {}
local function collect(method)
  local orig = vim.lsp.handlers[method]
  vim.lsp.handlers[method] = function(err, result, ctx, config)
    if result and result.message then
      server_msgs[#server_msgs + 1] = result.message
    end
    return orig(err, result, ctx, config)
  end
end
collect("window/showMessage")
collect("window/logMessage")

local function msgs_match(pat)
  for _, m in ipairs(server_msgs) do
    if m:find(pat) then
      return m
    end
  end
end

--- One rust-analyzer session on a copy of `basic`, shared by the tests (a
--- cold start costs seconds). Returns dir, bufnr (main.rs), client.
local session
local function basic()
  if session then
    -- other tests open other buffers; keymap tests act on the current one
    vim.api.nvim_set_current_buf(session.buf)
    return session.dir, session.buf, session.client
  end
  local dir, buf = H.open_fixture("basic", "src/main.rs", { git = true })
  local client = H.wait_lsp("rust-analyzer", buf)
  H.wait_for(function()
    local res = vim.lsp.buf_request_sync(
      buf,
      "textDocument/documentSymbol",
      { textDocument = vim.lsp.util.make_text_document_params(buf) },
      5000
    )
    for _, r in pairs(res or {}) do
      for _, sym in ipairs(r.result or {}) do
        if sym.name == "main" then
          return true
        end
      end
    end
  end, 90000, "documentSymbol to list `main`")
  session = { dir = dir, buf = buf, client = client }
  return dir, buf, client
end

local function ra_settings()
  local _, _, client = basic()
  return client.settings["rust-analyzer"]
end

local function request(buf, method, params, timeout)
  local res = vim.lsp.buf_request_sync(buf, method, params, timeout or 10000)
  for _, r in pairs(res or {}) do
    if r.err then
      error(method .. " failed: " .. vim.inspect(r.err))
    end
    return r.result
  end
end

local function lens_params(buf)
  return { textDocument = vim.lsp.util.make_text_document_params(buf) }
end

local function buffer_map(bufnr, lhs)
  local k = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
  if k.lhs and k.buffer == 1 then
    return k
  end
end

local function global_map(lhs)
  local k = vim.fn.maparg(lhs, "n", false, true)
  if k.lhs and k.buffer ~= 1 then
    return k
  end
end

local function online()
  return vim.system({ "curl", "-sS", "-m", "8", "-o", "/dev/null", "https://json.schemastore.org/cargo.json" }):wait(15000).code == 0
end

-- =========================================================== plugin specs (no server)

describe("rustaceanvim spec", function()
  it("1. depends on nvim-dap", function()
    local deps = Config.plugins["rustaceanvim"].dependencies
    H.has(deps, "nvim-dap")
  end)

  it("2. init: vim.npcall is vim.F.npcall, dap autoload_configurations stays false", function()
    H.ok(vim.npcall, "vim.npcall missing (rustaceanvim's workspaceSymbol prompt needs it)")
    H.eq(vim.F.npcall, vim.npcall)
    H.eq(false, vim.g.rustaceanvim.dap.autoload_configurations)
    -- the rust extra's opts.dap would overwrite a setting made in `opts`
    local eff = require("rustaceanvim.config.internal")
    H.eq(false, eff.dap.autoload_configurations)
  end)

  it("8. server.on_exit restarts after a crash, server.settings layers project + context", function()
    -- on_exit: a clean exit is silent, a crash is reported as a restart
    local on_exit = ra_opts().on_exit
    H.eq("function", type(on_exit))
    local cap = H.capture_notify()
    on_exit(0, 0, 99999)
    vim.wait(100)
    H.eq(0, #cap.list)
    on_exit(1, 0, 99999)
    H.wait_for(function()
      return #cap.list > 0
    end, 3000, "the restart notice")
    H.match(cap.list[1].msg, "rust-analyzer exited (code 1, signal 0); restarting", true)
    cap.restore()

    -- settings: the defaults pass through (rustaceanvim's loader ignores the
    -- root; it no longer reads a project rust-analyzer.json) and are not mutated
    local settings_fn = ra_opts().settings
    H.eq("function", type(settings_fn))
    local root = H.tmpdir()
    local defaults = vim.deepcopy(ra_opts().default_settings)
    local s = settings_fn(root, defaults)
    H.eq(defaults, ra_opts().default_settings)
    H.eq("clippy", s["rust-analyzer"].check.command)
    H.eq(4, s["rust-analyzer"].cachePriming.numThreads)
    H.eq(8, s["rust-analyzer"].numThreads)

    -- ... and the stored :RustContext cargo settings win over the cargo table
    vim.fn.writefile({ '[package]', 'name = "x"', 'version = "0.1.0"', 'edition = "2021"' }, root .. "/Cargo.toml")
    local ctx = require("config.rust_context")
    local real_root = vim.uv.fs_realpath(root)
    local function with_ctx(c)
      local orig_get = ctx.get
      ctx.get = function(r)
        return r == real_root and c or orig_get(r)
      end
    end
    local orig_get = ctx.get
    with_ctx({ all = false, no_default = true, features = { "ssr" }, target = "wasm32-unknown-unknown" })
    local ok, s2 = pcall(settings_fn, root, vim.deepcopy(ra_opts().default_settings))
    ctx.get = orig_get
    H.ok(ok, s2)
    local cargo = s2["rust-analyzer"].cargo
    H.eq(false, cargo.allFeatures)
    H.eq(true, cargo.noDefaultFeatures)
    H.eq({ "ssr" }, cargo.features)
    H.eq("wasm32-unknown-unknown", cargo.target)
    H.eq(true, cargo.buildScripts.enable, "the rest of the cargo table survives")
  end)

  it("5. diagnostics.experimental is off and procMacro.attributes stays on (spec level)", function()
    local ra = ra_opts().default_settings["rust-analyzer"]
    local exp = ra.diagnostics and ra.diagnostics.experimental
    H.ok(not (exp and exp.enable), "diagnostics.experimental.enable must not be set")
    local pm = ra.procMacro
    H.ok(not (pm and pm.attributes and pm.attributes.enable == false), "procMacro.attributes.enable must not be false")
  end)

  it("6. completion.snippets.custom: exactly the 9 postfix snippets", function()
    local custom = ra_opts().default_settings["rust-analyzer"].completion.snippets.custom
    local want = {
      ok = { "Ok(${receiver})" },
      err = { "Err(${receiver})" },
      some = { "Some(${receiver})" },
      pinbox = { "Box::pin(${receiver})", "std::boxed::Box" },
      arc = { "Arc::new(${receiver})", "std::sync::Arc" },
      rc = { "Rc::new(${receiver})", "std::rc::Rc" },
      refcell = { "RefCell::new(${receiver})", "std::cell::RefCell" },
      mutex = { "Mutex::new(${receiver})", "std::sync::Mutex" },
      arcmutex = { "Arc::new(Mutex::new(${receiver}))", "std::sync::Mutex" },
    }
    local seen, n = {}, 0
    for _, snip in pairs(custom) do
      n = n + 1
      local w = want[snip.postfix]
      H.ok(w, "unexpected postfix " .. tostring(snip.postfix))
      seen[snip.postfix] = true
      H.eq(w[1], snip.body, snip.postfix .. " body")
      H.eq(w[2], snip.requires, snip.postfix .. " requires")
      H.eq("expr", snip.scope, snip.postfix .. " scope")
    end
    H.eq(9, n)
    for k in pairs(want) do
      H.ok(seen[k], "missing postfix " .. k)
    end
  end)

  it("7. every default_settings key is a key of the installed binary's config schema", function()
    H.need_rust()
    local r = vim.system({ "rust-analyzer", "--print-config-schema" }, { text = true }):wait(20000)
    H.eq(0, r.code, "rust-analyzer --print-config-schema")
    local schema = vim.json.decode(r.stdout)
    -- a list of { title, properties = { ["rust-analyzer.x.y"] = {...} } }
    local known = {}
    for _, section in ipairs(schema) do
      for k in pairs(section.properties or {}) do
        known[k] = true
      end
    end
    H.ok(next(known), "could not read keys from the schema")
    local function is_prefix(path)
      for k in pairs(known) do
        if k:sub(1, #path + 1) == path .. "." then
          return true
        end
      end
    end
    local unknown = {}
    local function walk(tbl, path)
      for key, v in pairs(tbl) do
        local p = path .. "." .. key
        if known[p] then
          -- a documented leaf (arrays and free-form objects like snippets.custom included)
        elseif type(v) == "table" and not vim.islist(v) and is_prefix(p) then
          walk(v, p)
        else
          unknown[#unknown + 1] = p
        end
      end
    end
    walk(ra_opts().default_settings["rust-analyzer"], "rust-analyzer")
    -- Legacy names (set by LazyVim's rust extra and config.rust_context) that
    -- the schema no longer lists but the server still honours: no warning is
    -- sent (7b) and allFeatures still switches the features on (the
    -- all-features test below).
    local legacy = { ["rust-analyzer.cargo.allFeatures"] = true, ["rust-analyzer.cargo.loadOutDirsFromCheck"] = true }
    unknown = vim.tbl_filter(function(k)
      return not legacy[k]
    end, unknown)
    table.sort(unknown)
    H.eq({}, unknown, "keys rust-analyzer does not know")
  end)
end)

-- =========================================================== the running server

describe("rust-analyzer effective settings", function()
  before_each(function()
    H.need_rust()
  end)

  it("9. attaches to basic (documentSymbol lists main, no errors), workspace and standalone.rs", function()
    local _, buf = basic()
    H.eq(
      {},
      vim.tbl_filter(function(d)
        return d.severity == vim.diagnostic.severity.ERROR and d.source == "rust-analyzer"
      end, H.diagnostics(nil, buf))
    )
    local _, wbuf = H.open_fixture("workspace", "core/src/lib.rs")
    H.eq(true, wbuf ~= nil)
    H.wait_lsp("rust-analyzer", wbuf)
    local sdir, sbuf = H.open_fixture("standalone.rs")
    local c = H.wait_lsp("rust-analyzer", sbuf)
    H.ok(c, "standalone attach")
    H.eq(sdir, vim.fs.dirname(vim.api.nvim_buf_get_name(sbuf)))
  end)

  it("9b. the broken crate reports the type error (E0308) from rust-analyzer in under 60 s", function()
    local _, buf = H.open_fixture("broken", "src/main.rs")
    local t0 = vim.uv.hrtime()
    H.wait_lsp("rust-analyzer", buf)
    local d = H.wait_for(function()
      for _, x in ipairs(H.diagnostics("rust-analyzer", buf)) do
        -- rust-analyzer words it "expected `i32`, found `&str`"; "mismatched
        -- types" is rustc's text (the clippy tier, bacon-ls)
        if x.code == "E0308" then
          return x
        end
      end
    end, 180000, "a rust-analyzer E0308 diagnostic")
    H.match(d.message, "expected", true)
    -- the 60 s budget holds on an idle machine; on a heavily loaded one (other
    -- builds running) only the diagnostic itself is asserted
    local load, cores = vim.uv.loadavg(), #vim.uv.cpu_info()
    if load < cores then
      local secs = (vim.uv.hrtime() - t0) / 1e9
      H.ok(secs < 60, ("took %.0f s (load %.1f)"):format(secs, load))
    end
  end)

  it("3. no `cargo test --no-run --all-targets` child after attach (dap autoload off)", function()
    basic()
    vim.wait(4000) -- rustaceanvim would start it right after the attach
    local pid = tostring(vim.uv.os_getpid())
    local children = {}
    local function ppid(p)
      local f = io.open("/proc/" .. p .. "/stat")
      if not f then
        return
      end
      local s = f:read("*a")
      f:close()
      return s:match("^%d+ %b() %S (%d+)")
    end
    for _, name in ipairs(vim.fn.readdir("/proc")) do
      if name:match("^%d+$") then
        local f = io.open("/proc/" .. name .. "/cmdline")
        local cmd = f and f:read("*a") or ""
        if f then
          f:close()
        end
        if cmd:find("--no-run", 1, true) then
          -- belongs to this nvim when it is in its process tree
          local p, depth = name, 0
          while p and p ~= "1" and depth < 10 do
            if p == pid then
              children[#children + 1] = cmd:gsub("%z", " ")
              break
            end
            p, depth = ppid(p), depth + 1
          end
        end
      end
    end
    H.eq({}, children)
  end)

  it("4. effective client.settings['rust-analyzer'] (measured)", function()
    local ra = ra_settings()
    H.eq(4, ra.cachePriming.numThreads)
    H.eq(8, ra.numThreads)
    H.eq(true, ra.cargo.allFeatures)
    H.eq(true, ra.cargo.buildScripts.enable)
    H.eq(true, ra.cargo.loadOutDirsFromCheck)
    H.eq(true, ra.cargo.targetDir)
    H.eq("clippy", ra.check.command)
    H.eq({ "--no-deps" }, ra.check.extraArgs)
    H.eq(false, ra.checkOnSave)
    H.eq("fill_arguments", ra.completion.callable.snippets)
    H.eq(true, ra.completion.fullFunctionSignatures.enable)
    H.eq(true, ra.completion.termSearch.enable)
    H.eq(true, ra.diagnostics.enable)
    H.eq("client", ra.files.watcher)
    local excl = vim.deepcopy(ra.files.exclude)
    table.sort(excl)
    local want = { ".direnv", ".git", ".jj", ".github", ".gitlab", "bin", "node_modules", "target", "venv", ".venv" }
    table.sort(want)
    H.eq(want, excl)
    H.eq("module", ra.imports.granularity.group)
    H.eq("self", ra.imports.prefix)
    H.eq("with_block", ra.inlayHints.closureReturnTypeHints.enable)
    H.eq("never", ra.inlayHints.expressionAdjustmentHints.enable)
    H.eq("skip_trivial", ra.inlayHints.lifetimeElisionHints.enable)
    H.eq(true, ra.inlayHints.lifetimeElisionHints.useParameterNames)
    H.eq(true, ra.procMacro.enable)
    H.eq(true, ra.references.excludeImports)
    H.eq(true, ra.references.excludeTests)
  end)

  it("5b. diagnostics.experimental off and procMacro.attributes on in the effective settings", function()
    local ra = ra_settings()
    local exp = ra.diagnostics.experimental
    H.ok(not (exp and exp.enable), "diagnostics.experimental.enable is set")
    local attrs = ra.procMacro and ra.procMacro.attributes
    H.ok(not (attrs and attrs.enable == false), "procMacro.attributes.enable is false")
  end)

  it("6b. the snippets reach the server", function()
    local custom = ra_settings().completion.snippets.custom
    local posts = {}
    for _, s in pairs(custom) do
      posts[#posts + 1] = s.postfix
    end
    table.sort(posts)
    H.eq({ "arc", "arcmutex", "err", "mutex", "ok", "pinbox", "rc", "refcell", "some" }, posts)
  end)

  it("7b. the server sent no 'unknown config' complaint", function()
    basic()
    vim.wait(1500)
    for _, pat in ipairs({ "[Uu]nknown", "invalid config", "Invalid config" }) do
      local m = msgs_match(pat)
      if m and (m:lower():find("config") or m:lower():find("rust%-analyzer%.")) then
        error("server complained about the configuration: " .. m)
      end
    end
    local log = vim.lsp.log.get_filename()
    if vim.fn.filereadable(log) == 1 then
      for _, line in ipairs(vim.fn.readfile(log)) do
        if line:lower():find("unknown config") or line:lower():find("invalid config change") then
          error("lsp.log: " .. line)
        end
      end
    end
  end)

  it("10. the instant tier: native rust-analyzer E0308 appears quickly when warm", function()
    local _, buf = H.open_fixture("broken", "src/main.rs")
    H.wait_lsp("rust-analyzer", buf)
    H.wait_for(function()
      return H.diagnostics("rust-analyzer", buf)[1]
    end, 60000, "the first (cold) diagnostic")
    -- warm: edit the line to a different mismatch, time until the new message shows
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '    let x: u8 = "not a number";' })
    local t0 = vim.uv.hrtime()
    H.wait_for(function()
      for _, d in ipairs(H.diagnostics("rust-analyzer", buf)) do
        if d.code == "E0308" and d.message:find("u8", 1, true) then
          return true
        end
      end
    end, 5000, "the E0308 for the edited line")
    local secs = (vim.uv.hrtime() - t0) / 1e9
    -- the design target is ~0.15 s; the bound is loose so a loaded machine does not flake
    H.ok(secs < 2, ("E0308 took %.2f s"):format(secs))
  end)

  it("11. codelens: textDocument/codeLens succeeds, <leader>cc is mapped and runs a lens", function()
    local _, buf = basic()
    local lenses = H.wait_for(function()
      local r = request(buf, "textDocument/codeLens", lens_params(buf))
      return r and #r > 0 and r
    end, 30000, "code lenses for main.rs")
    local on_main
    for _, l in ipairs(lenses) do
      if l.range.start.line == 2 then
        on_main = l
      end
    end
    H.ok(on_main, "a lens on `fn main`")
    H.eq(true, require("lazy.core.plugin").values(Config.plugins["nvim-lspconfig"], "opts", false).codelens.enabled)
    local map = buffer_map(buf, "<leader>cc") or global_map("<leader>cc")
    H.ok(map, "<leader>cc")
    -- run: with the cursor on `fn main` the lens command is executed (one
    -- lens) or offered in a picker (several); the commands are stubbed so no
    -- cargo/terminal starts
    local seen, picked = {}, nil
    local orig_select = vim.ui.select
    local orig_cmds = {}
    for _, name in ipairs({ "rust-analyzer.runSingle", "rust-analyzer.debugSingle", "rust-analyzer.showReferences" }) do
      orig_cmds[name] = vim.lsp.commands[name]
      vim.lsp.commands[name] = function()
        seen[#seen + 1] = name
      end
    end
    vim.ui.select = function(items, _, cb)
      picked = items
      cb(items[1], 1)
    end
    vim.api.nvim_win_set_cursor(0, { 3, 4 })
    local ok, err = pcall(H.feed, "<leader>cc")
    vim.wait(3000, function()
      return #seen > 0
    end)
    vim.ui.select = orig_select
    for name, f in pairs(orig_cmds) do
      vim.lsp.commands[name] = f
    end
    H.ok(ok, err)
    H.ok(#seen > 0, "<leader>cc executed no lens command (picker offered: " .. vim.inspect(picked) .. ")")
  end)

  it("12. inlay hints: capability, <leader>uh toggle, hints for typed lets", function()
    local _, buf, client = basic()
    H.ok(client:supports_method("textDocument/inlayHint"), "inlayHint capability")
    H.ok(vim.lsp.inlay_hint, "vim.lsp.inlay_hint")
    H.ok(global_map("<leader>uh") or buffer_map(buf, "<leader>uh"), "<leader>uh")
    local before = vim.lsp.inlay_hint.is_enabled({ bufnr = buf })
    H.feed("<leader>uh")
    H.eq(not before, vim.lsp.inlay_hint.is_enabled({ bufnr = buf }))
    H.feed("<leader>uh")
    H.eq(before, vim.lsp.inlay_hint.is_enabled({ bufnr = buf }))
    -- the server really produces hints: a `let` without a type gets `: i32`
    -- (the buffer is edited in memory only and restored)
    local orig = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.api.nvim_buf_set_lines(buf, 3, 3, false, { "    let n = answer();" })
    local hints = H.wait_for(function()
      local r = request(buf, "textDocument/inlayHint", {
        textDocument = vim.lsp.util.make_text_document_params(buf),
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 5, character = 1 } },
      })
      return r and #r > 0 and r
    end, 60000, "inlay hints")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, orig)
    vim.bo[buf].modified = false
    local labels = {}
    for _, h in ipairs(hints) do
      labels[#labels + 1] = type(h.label) == "string" and h.label or vim.iter(h.label):map(function(p) return p.value end):join("")
    end
    H.has(labels, ": i32")
  end)

  it("19. debug codelens: a lens resolves to rust-analyzer.debugSingle (nvim-dap loaded)", function()
    local _, buf = basic()
    H.ok(package.loaded["dap"], "nvim-dap is loaded with the first Rust buffer")
    local lenses = H.wait_for(function()
      local r = request(buf, "textDocument/codeLens", lens_params(buf))
      return r and #r > 0 and r
    end, 30000, "code lenses")
    local found = {}
    for _, l in ipairs(lenses) do
      local resolved = l.command and l or request(buf, "codeLens/resolve", l)
      if resolved and resolved.command then
        found[#found + 1] = resolved.command.command
      end
    end
    H.has(found, "rust-analyzer.debugSingle")
  end)

  it("1b. the debugSingle client command is advertised to the server (dap was loaded before the client)", function()
    local _, _, client = basic()
    local cmds = vim.tbl_get(client.config, "capabilities", "experimental", "commands", "commands") or {}
    H.has(cmds, "rust-analyzer.debugSingle")
    H.has(cmds, "rust-analyzer.runSingle")
  end)

  it("4b. allFeatures is honoured: the workspace's mutually exclusive features are both on", function()
    local _, buf = H.open_fixture("workspace", "core/src/lib.rs")
    H.wait_lsp("rust-analyzer", buf)
    H.wait_for(function()
      for _, d in ipairs(H.diagnostics("rust-analyzer", buf)) do
        if d.message:find("mutually exclusive", 1, true) then
          return true
        end
      end
    end, 120000, "rust-analyzer's compile_error! (needs ssr AND csr: --all-features)")
  end)

  it("20. type hierarchy is unsupported; gI (goto implementation) is the substitute", function()
    local _, buf, client = basic()
    H.not_ok(client:supports_method("textDocument/prepareTypeHierarchy"), "type hierarchy is not offered")
    local map = buffer_map(buf, "gI") or global_map("gI")
    H.ok(map, "gI")
    H.eq("Goto Implementation", map.desc)
    H.ok(client:supports_method("textDocument/implementation"))
  end)
end)

-- =========================================================== editing-ui / domain

describe("editing-ui and domain specs", function()
  it("13. diagnostic virtual text: no separate source, format = ux.diagnostic_text", function()
    local vt = opts_of("nvim-lspconfig").diagnostics.virtual_text
    H.eq(false, vt.source)
    H.eq("function", type(vt.format))
    local ux = require("config.ux")
    local d = { message = "mismatched types\nmore", source = "rust-analyzer" }
    H.eq(ux.diagnostic_text(d), vt.format(d))
    H.eq("mismatched types [rust-analyzer]", vt.format(d))
    -- and the live vim.diagnostic config uses it
    local live = vim.diagnostic.config().virtual_text
    H.ok(type(live) == "table" and live.source == false and type(live.format) == "function", vim.inspect(live))
  end)

  it("14. taplo: root markers and the Cargo.toml schema association", function()
    local taplo = opts_of("nvim-lspconfig").servers.taplo
    H.eq({ ".taplo.toml", "taplo.toml", "Cargo.toml", ".git" }, taplo.root_markers)
    H.eq(
      "https://json.schemastore.org/cargo.json",
      taplo.settings.evenBetterToml.schema.associations["^(.*/)?Cargo\\.toml$"]
    )
  end)

  it("14b. taplo roots a lone Cargo.toml (no .git) and reports `edtion` (optional: network)", function()
    if vim.fn.executable("taplo") ~= 1 and vim.fn.filereadable(vim.fn.stdpath("data") .. "/mason/bin/taplo") ~= 1 then
      harness.skip("taplo not installed")
    end
    local dir = H.tmpdir()
    vim.fn.writefile({ "[package]", 'name = "lone"', 'version = "0.1.0"', 'edtion = "2021"' }, dir .. "/Cargo.toml")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/Cargo.toml")
    local c = H.wait_lsp("taplo", buf, 30000)
    H.eq(vim.uv.fs_realpath(dir), vim.uv.fs_realpath(c.root_dir), "taplo root")
    if not online() then
      harness.skip("no network: the Cargo schema cannot be fetched, so `edtion` is not reported")
    end
    local d = H.wait_for(function()
      for _, x in ipairs(vim.diagnostic.get(buf)) do
        if x.message:lower():find("edtion", 1, true) then
          return x
        end
      end
    end, 40000, "taplo to report `edtion`")
    H.ok(d)
  end)

  it("15. domain.lua: kulala pinned to v5.3.4 without submodules, parsers, Mason package, server entry", function()
    local k = Config.plugins["kulala.nvim"]
    H.eq("v5.3.4", k.tag)
    H.eq(false, k.submodules)
    local ts = opts_of("nvim-treesitter").ensure_installed
    H.has(ts, "sql")
    H.has(ts, "wgsl")
    H.has(opts_of("mason.nvim").ensure_installed, "wgsl-analyzer")
    local servers = opts_of("nvim-lspconfig").servers
    H.eq({}, servers.wgsl_analyzer)
    -- the installed checkout is that tag
    local head = vim.system({ "git", "-C", k.dir, "rev-parse", "--short=7", "HEAD" }, { text = true }):wait(10000)
    if head.code == 0 then
      H.eq("6656c9d", vim.trim(head.stdout))
    end
  end)

  local function wgsl_available()
    return vim.fn.executable("wgsl-analyzer") == 1 or vim.fn.filereadable(vim.fn.stdpath("data") .. "/mason/bin/wgsl-analyzer") == 1
  end

  it("15b. wgsl-analyzer attaches to a .wgsl file and reports a type mismatch", function()
    if not wgsl_available() then
      harness.skip("Mason's wgsl-analyzer is not installed")
    end
    local dir = H.tmpdir()
    local file = dir .. "/shader.wgsl"
    vim.fn.writefile({
      "@fragment",
      "fn fs_main() -> @location(0) vec4<f32> {",
      "    let x: f32 = 1u;",
      "    return vec4<f32>(x, x, x, 1.0);",
      "}",
    }, file)
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(file)
    H.eq("wgsl", vim.bo[buf].filetype)
    H.wait_lsp("wgsl_analyzer", buf, 60000)
    local d = H.wait_for(function()
      return vim.diagnostic.get(buf)[1]
    end, 60000, "a wgsl diagnostic")
    H.match(d.message, "expected f32, found u32", true)
  end)

  it("16. wgsl-analyzer in a Cargo crate: still attaches ('Project discovery failed' is harmless)", function()
    if not wgsl_available() then
      harness.skip("Mason's wgsl-analyzer is not installed")
    end
    local dir = H.fixture("basic", { git = true })
    vim.fn.writefile({ "fn main() -> f32 { return 1.0; }" }, dir .. "/src/s.wgsl")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/src/s.wgsl")
    H.wait_lsp("wgsl_analyzer", buf, 60000)
    vim.wait(3000)
    -- known: the message may be logged; it must not take the client down
    H.eq(1, #H.clients(buf, "wgsl_analyzer"))
    H.ok(not H.clients(buf, "wgsl_analyzer")[1]:is_stopped())
  end)

  it("17. kulala: <leader>Rs/Re/Rc only in .http buffers, <leader>Rb global, GET returns 200", function()
    -- the keys come from the util.rest extra
    H.ok(global_map("<leader>Rb"), "<leader>Rb is global")
    for _, lhs in ipairs({ "<leader>Rs", "<leader>Re", "<leader>Rc" }) do
      H.not_ok(global_map(lhs), lhs .. " must not be global")
    end
    local dir = H.tmpdir()
    vim.fn.writefile({ "GET http://127.0.0.1:1/ HTTP/1.1" }, dir .. "/a.http")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/a.http")
    H.eq("http", vim.bo[buf].filetype)
    for _, lhs in ipairs({ "<leader>Rs", "<leader>Re", "<leader>Rc" }) do
      H.wait_for(function()
        return buffer_map(buf, lhs)
      end, 5000, lhs .. " in the .http buffer")
    end
    -- a rust buffer does not get them
    local fx = H.fixture("standalone.rs")
    vim.cmd.edit(vim.fn.fnameescape(fx))
    for _, lhs in ipairs({ "<leader>Rs", "<leader>Re", "<leader>Rc" }) do
      H.not_ok(buffer_map(0, lhs), lhs .. " leaked into a Rust buffer")
    end
  end)

  it("17b. kulala sends a GET to a local http.server and shows Status 200 (needs curl, python3)", function()
    if vim.fn.executable("curl") ~= 1 or vim.fn.executable("python3") ~= 1 then
      harness.skip("curl or python3 missing")
    end
    local dir = H.tmpdir()
    vim.fn.writefile({ "hello" }, dir .. "/index.html")
    -- a free port
    local srv = vim.uv.new_tcp()
    srv:bind("127.0.0.1", 0)
    local port = srv:getsockname().port
    srv:close()
    H.spawn({ "python3", "-m", "http.server", tostring(port), "--bind", "127.0.0.1", "--directory", dir })
    H.wait_for(function()
      return vim.system({ "curl", "-s", "-m", "2", "-o", "/dev/null", ("http://127.0.0.1:%d/index.html"):format(port) }):wait(5000).code == 0
    end, 10000, "the http.server")
    vim.fn.writefile({ ("GET http://127.0.0.1:%d/index.html HTTP/1.1"):format(port) }, dir .. "/req.http")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/req.http")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    H.wait_for(function()
      return buffer_map(buf, "<leader>Rs")
    end, 5000, "<leader>Rs")
    H.feed("<leader>Rs")
    local text = H.wait_for(function()
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        local all = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
        if b ~= buf and (all:find("Status: 200", 1, true) or all:find("HTTP/1.1 200", 1, true) or all:find("Status 200", 1, true)) then
          return all
        end
      end
      -- kulala may show the status in the winbar of its result window
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local wb = vim.wo[w].winbar or ""
        if wb:find("200", 1, true) then
          return wb
        end
      end
    end, 20000, "Status 200 in the kulala result")
    H.match(text, "200", true)
  end)

  it("18. Snacks bigfile: enabled with the 1.5 MB default limit", function()
    local bf = opts_of("snacks.nvim").bigfile
    H.ok(bf and bf.enabled ~= false, "bigfile must be enabled")
    -- the plugin default is used unless the config sets `size`
    H.is_nil(bf.size, "bigfile.size is overridden")
    local defaults = vim.fn.readfile(Config.plugins["snacks.nvim"].dir .. "/lua/snacks/bigfile.lua")
    H.ok(table.concat(defaults, "\n"):find("size = 1.5 * 1024 * 1024", 1, true), "snacks default size is 1.5 MB")
  end)

  it("18b. a Rust file over 1.5 MB gets the bigfile treatment and no LSP", function()
    H.need_rust()
    local dir = H.tmpdir()
    vim.fn.writefile({ "[package]", 'name = "big"', 'version = "0.1.0"', 'edition = "2021"' }, dir .. "/Cargo.toml")
    vim.fn.mkdir(dir .. "/src")
    local line = "pub const X: u8 = 1; // padding padding padding padding padding padding padding\n"
    local f = assert(io.open(dir .. "/src/main.rs", "w"))
    f:write("fn main() {}\n")
    for _ = 1, math.ceil(1.6 * 1024 * 1024 / #line) do
      f:write(line)
    end
    f:close()
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/src/main.rs")
    H.eq("bigfile", vim.bo[buf].filetype)
    vim.wait(4000)
    H.eq(0, #H.clients(buf, "rust-analyzer"))
  end)
end)
