-- Rust debugging UX against a REAL codelldb session driven through nvim-dap (skips without codelldb/cargo):
-- value rendering of Rust types (rust's lldb formatters + scripts/lldb/xyno_rust_preview.py), the value float,
-- inline virtual text, frame marking, breakpoint kinds (conditional, hit count, logpoint, exception filters),
-- stepping, formatter health. The fixture is tests/fixtures/debug-values.
local H = require("xynotest.helpers")
local DV = require("config.dap_values")

local undo = {}
after_each(function()
  for i = #undo, 1, -1 do
    pcall(undo[i])
  end
  undo = {}
  pcall(function()
    require("dap").terminate()
  end)
  pcall(function()
    require("dap.breakpoints").clear()
  end)
end)

local S -- { dir, bin, buf, lines = { STOP, LOOP, IN_TEST } }

local function need()
  H.need_rust()
  if not vim.uv.fs_stat(vim.fn.stdpath("data") .. "/mason/bin/codelldb") then
    H.skip_file("Mason's codelldb is not installed")
  end
  if not vim.uv.fs_stat(vim.fn.stdpath("data") .. "/mason/packages/codelldb") then
    H.skip_file("Mason's codelldb package is missing")
  end
end

local function session_setup()
  need()
  if S then
    vim.cmd.cd(vim.fn.fnameescape(S.dir))
    vim.cmd.edit(vim.fn.fnameescape(S.dir .. "/src/main.rs"))
    return S
  end
  local dir = vim.uv.fs_realpath(H.tmpdir())
  vim.fn.system({ "cp", "-r", H.fixtures .. "/debug-values/.", dir })
  vim.cmd.cd(vim.fn.fnameescape(dir))
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/src/main.rs"))
  H.very_lazy()
  local b = vim.system({ "cargo", "build" }, { cwd = dir, text = true }):wait(180000)
  H.eq(0, b.code, "building the fixture: " .. (b.stderr or ""))
  local lines = {}
  for i, l in ipairs(vim.fn.readfile(dir .. "/src/main.rs")) do
    for _, tag in ipairs({ "STOP", "LOOP", "IN_TEST" }) do
      if l:find("// " .. tag, 1, true) then
        lines[tag] = i
      end
    end
  end
  S = { dir = dir, bin = dir .. "/target/debug/debug-values", buf = vim.api.nvim_get_current_buf(), lines = lines }
  return S
end

local function codelldb_cfg()
  return {
    name = "codelldb",
    adapters = require("mason-nvim-dap.mappings.adapters").codelldb,
    configurations = require("mason-nvim-dap.mappings.configurations").codelldb,
    filetypes = require("mason-nvim-dap.mappings.filetypes").codelldb,
  }
end

--- Launch the fixture binary under codelldb with the plugin spec's own listeners; returns the output collector.
local function launch(env)
  local s = session_setup()
  require("lazy.core.config").plugins["mason-nvim-dap.nvim"].opts.handlers.codelldb(codelldb_cfg())
  local dap = require("dap")
  local outs = {}
  dap.listeners.after.event_output["spec"] = function(_, b)
    outs[#outs + 1] = b.output
  end
  undo[#undo + 1] = function()
    dap.listeners.after.event_output["spec"] = nil
  end
  local cfg = vim.deepcopy(dap.configurations.rust[1])
  cfg.program = s.bin
  cfg.env = env
  dap.run(cfg)
  return outs
end

local function stopped(timeout)
  local dap = require("dap")
  return H.wait_for(function()
    local x = dap.session()
    return x and x.stopped_thread_id and x.current_frame and x
  end, timeout or 90000, "the debugger to stop")
end

local function request(s, cmd, args)
  local res
  s:request(cmd, args, function(err, body)
    res = { err = err, body = body }
  end)
  H.wait_for(function()
    return res
  end, 20000, "dap " .. cmd)
  H.is_nil(res.err and res.err.message, "dap " .. cmd)
  return res.body
end

local function locals(s)
  local scopes = request(s, "scopes", { frameId = s.current_frame.id }).scopes
  local out = {}
  for _, sc in ipairs(scopes) do
    if sc.name:find("Local") then
      for _, v in ipairs(request(s, "variables", { variablesReference = sc.variablesReference }).variables) do
        out[v.name] = v
      end
    end
  end
  return out
end

local function bp(line, cond, hit, log)
  require("dap.breakpoints").set({ condition = cond, hit_condition = hit, log_message = log }, S.buf, line)
end

local function wait_gone()
  local dap = require("dap")
  dap.terminate()
  pcall(function()
    H.wait_for(function()
      return dap.session() == nil
    end, 15000, "the session to end")
  end)
end

describe("value rendering (real codelldb)", function()
  it("Rust types read as their content, not their fields", function()
    local s0 = session_setup()
    bp(s0.lines.STOP)
    launch()
    local s = stopped()
    local v = locals(s)
    local function val(n)
      return v[n] and v[n].value
    end
    H.eq('"hello"', val("owned"))
    H.eq('"world"', val("borrowed"))
    H.eq("size=3 [1, 2, 3]", val("v"))
    H.eq('size=1 {"a": 1}', val("m"))
    H.eq("Some(5)", val("some"))
    H.eq("None", val("none"))
    H.eq("Ok(1)", val("ok"))
    H.eq('Err("bad")', val("err"))
    H.eq('strong=2, weak=0 "rc"', val("rc"))
    H.eq("strong=1, weak=0 size=2 [1, 2]", val("arc"))
    H.eq("borrow=0 5", val("cell"))
    H.eq("Rect{w:2, h:3}", val("shape"))
    H.eq("Unit", val("unit"))
    H.eq("size=2 [2, 3]", val("slice"))
    H.ok(#val("long") > 600, "a 600 character String arrives whole (" .. #val("long") .. ")")
    -- containers still expand into elements
    H.ok((v.v.variablesReference or 0) > 0 and (v.m.variablesReference or 0) > 0)
    wait_gone()
  end)

  it("formatter health: codelldb reported the Rust formatters, so no warning", function()
    local s0 = session_setup()
    bp(s0.lines.STOP)
    local seen = H.capture_notify()
    launch()
    local s = stopped()
    H.eq(true, s.xyno_formatters)
    H.eq(nil, s.xyno_formatter_warned)
    wait_gone()
    _ = seen
  end)

  it("a session whose formatters did not load gets one visible warning", function()
    local msgs = {}
    local old = vim.notify
    vim.notify = function(m, l)
      msgs[#msgs + 1] = { m, l }
    end
    undo[#undo + 1] = function()
      vim.notify = old
    end
    DV.setup()
    local fake = { config = { type = "codelldb", sourceLanguages = { "rust" } } }
    local fire = require("dap").listeners.after.event_stopped["xynovim_formatters"]
    fire(fake)
    fire(fake)
    local n = 0
    for _, m in ipairs(msgs) do
      if m[1] == DV.FORMATTER_WARNING and m[2] == vim.log.levels.WARN then
        n = n + 1
      end
    end
    H.eq(1, n)
  end)
end)

describe("call stack (real codelldb)", function()
  it("runtime frames are subtle (hidden by dap-ui's stacks, `t` shows them), user frames stay normal", function()
    local s0 = session_setup()
    bp(s0.lines.STOP)
    launch()
    local s = stopped()
    local st = request(s, "stackTrace", { threadId = s.stopped_thread_id })
    local names, hints = {}, {}
    for _, f in ipairs(s.threads[s.stopped_thread_id].frames) do
      names[#names + 1] = f.name
      hints[f.name] = f.presentationHint
    end
    H.eq("debug_values::work", names[1])
    H.eq("debug_values::main", names[2])
    H.eq(nil, hints["debug_values::work"])
    local subtle = 0
    for n, h in pairs(hints) do
      if n:find("lang_start", 1, true) then
        H.eq("subtle", h, n)
        subtle = subtle + 1
      end
    end
    H.ok(subtle > 0, "std::rt::lang_start frames are in the stack and subtle")
    H.ok(#st.stackFrames >= #names, "the raw reply is untouched where the adapter sent it")
    wait_gone()
  end)

  it("closures and async frames get readable names; the async count drives the hint", function()
    local frames = {
      { name = "app::run::{closure#0}", source = { path = "/w/src/a.rs" } },
      { name = "app::fetch::{async_fn#0}", source = { path = "/w/src/a.rs" } },
      { name = "app::{async_block#2}", source = { path = "/w/src/a.rs" } },
      { name = "std::rt::lang_start::{closure#0}", source = { path = "/rustc/abc/library/std/src/rt.rs" } },
    }
    local n = DV.process_frames(frames)
    H.eq(2, n)
    H.eq("app::run::<closure>", frames[1].name)
    H.eq("app::fetch::<async fn>", frames[2].name)
    H.eq("app::<async block>", frames[3].name)
    H.eq("subtle", frames[4].presentationHint)
    H.eq("std::rt::lang_start::{closure#0}", frames[4].name, "runtime frames keep the adapter's name")
  end)
end)

describe("value float, hover, inline text (real codelldb)", function()
  local function float_lines()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].filetype == "xynodapvalue" then
        return vim.api.nvim_buf_get_lines(b, 0, -1, false), w
      end
    end
  end

  it("<leader>dv shows the whole value of a long String, wrapped, and a HashMap with its entries", function()
    local s0 = session_setup()
    bp(s0.lines.STOP)
    launch()
    local s = stopped()
    DV.show_value("long")
    local lines = H.wait_for(float_lines, 10000, "the value float")
    H.match(lines[1], "long : String", true)
    local body = table.concat(lines, "\n")
    H.ok(#body:gsub("[^x]", "") >= 600, "all 600 characters are in the float")
    local _, w = float_lines()
    H.eq(true, vim.wo[w].wrap)
    vim.api.nvim_win_close(w, true)
    DV.show_value("m")
    lines = H.wait_for(float_lines, 10000, "the map float")
    H.eq("m : HashMap<String, int>", lines[1])
    H.match(table.concat(lines, "\n"), "size=1", true)
    H.match(table.concat(lines, "\n"), '"a"', true)
    _, w = float_lines()
    vim.api.nvim_win_close(w, true)
    wait_gone()
    _ = s
  end)

  it("a value that cannot be evaluated is a notice, not an error", function()
    local s0 = session_setup()
    bp(s0.lines.STOP)
    launch()
    stopped()
    local msgs = {}
    local old = vim.notify
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    undo[#undo + 1] = function()
      vim.notify = old
    end
    DV.show_value("no_such_variable_here")
    H.wait_for(function()
      return #msgs > 0
    end, 10000, "the notice")
    H.match(msgs[1], "cannot evaluate", true)
    wait_gone()
  end)

  it("K is the value float while stopped (the map exists in the Rust buffer after the session starts)", function()
    local s0 = session_setup()
    bp(s0.lines.STOP)
    launch()
    stopped()
    vim.api.nvim_set_current_buf(s0.buf)
    local m = H.wait_for(function()
      local x = vim.fn.maparg("K", "n", false, true)
      return x.buffer == 1 and x.desc == "Value (debugger) / hover" and x
    end, 10000, "the K map")
    H.ok(m.callback)
    wait_gone()
  end)

  it("inline virtual text carries the previews and cuts long values at 60 characters", function()
    local s0 = session_setup()
    bp(s0.lines.STOP)
    launch()
    stopped()
    vim.api.nvim_set_current_buf(s0.buf)
    local ns = vim.api.nvim_create_namespace("nvim-dap-virtual-text")
    local text = H.wait_for(function()
      local all = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s0.buf, ns, 0, -1, { details = true })) do
        for _, chunk in ipairs(m[4].virt_text or {}) do
          all[#all + 1] = chunk[1]
        end
      end
      local t = table.concat(all, "\n")
      return t:find("size=3 [1, 2, 3]", 1, true) and t
    end, 15000, "inline values")
    H.match(text, 'size=1 {"a": 1}', true)
    for chunk in text:gmatch("[^\n]+") do
      H.ok(vim.fn.strchars(chunk) <= 70, "short enough: " .. chunk:sub(1, 80))
    end
    wait_gone()
  end)

  it("inline_text unit: inline mode drops the name, end-of-line keeps it, long values end with an ellipsis", function()
    H.eq(" = 5", DV.inline_text({ name = "x", value = "5" }, { virt_text_pos = "inline" }))
    H.eq("x = 5", DV.inline_text({ name = "x", value = "5" }, { virt_text_pos = "eol" }))
    local t = DV.inline_text({ name = "x", value = string.rep("a", 100) }, { virt_text_pos = "inline" })
    H.eq(3 + 59 + 1, vim.fn.strchars(t))
    H.eq("\226\128\166", vim.fn.strcharpart(t, vim.fn.strchars(t) - 1))
  end)

  it("render_value: multi-line strings are unescaped, types shortened, children indented", function()
    local lines = DV.render_value({
      name = "s",
      type = "alloc::string::String",
      value = '"a\\nb"',
      children = { { name = "[0]", value = "1", children = { { name = "x", value = "2" } } } },
      more = 0,
    })
    H.eq({ "s : String", "", "a", "b", "", "[0]: 1", "  x: 2" }, lines)
    H.eq("HashMap<String, int>", DV.type_short("std::collections::hash::map::HashMap<alloc::string::String, int, std::hash::random::RandomState, alloc::alloc::Global>"))
  end)
end)

describe("breakpoints and stepping (real codelldb)", function()
  local function loop_i(s)
    return locals(s).i and locals(s).i.value
  end

  it("conditional: stops in the loop only when i == 3", function()
    local s0 = session_setup()
    bp(s0.lines.LOOP, "i == 3")
    launch()
    local s = stopped()
    H.eq("3", loop_i(s))
    wait_gone()
  end)

  it("hit count: stops on the third hit (i == 2)", function()
    local s0 = session_setup()
    bp(s0.lines.LOOP, nil, "3")
    launch()
    local s = stopped()
    H.eq("2", loop_i(s))
    wait_gone()
  end)

  it("logpoint: prints the evaluated message for every iteration and does not stop", function()
    local s0 = session_setup()
    bp(s0.lines.LOOP, nil, nil, "loop i={i}")
    local outs = launch()
    H.wait_for(function()
      return require("dap").session() ~= nil
    end, 30000, "the session to start")
    H.wait_for(function()
      return require("dap").session() == nil
    end, 60000, "the program to run to its end without stopping")
    local text = table.concat(outs)
    for i = 0, 4 do
      H.match(text, "loop i=" .. i, true, text)
    end
  end)

  it("the helpers set what the keys promise (logpoint, hit count through the real functions)", function()
    local s0 = session_setup()
    vim.api.nvim_set_current_buf(s0.buf)
    vim.api.nvim_win_set_cursor(0, { s0.lines.LOOP, 0 })
    DV.logpoint("n={total}")
    DV.hit_count(">= 2")
    local bps = require("dap.breakpoints").get(s0.buf)[s0.buf]
    local b = bps[#bps]
    H.ok(b.logMessage == "n={total}" or b.hitCondition == ">= 2", vim.inspect(bps))
  end)

  it("exception breakpoints: codelldb advertises rust_panic; choosing it is sent and acknowledged", function()
    local s0 = session_setup()
    bp(s0.lines.STOP)
    launch()
    local s = stopped()
    local filters = DV.exception_filters()
    H.ok(filters and #filters > 0, "the adapter advertises exceptionBreakpointFilters " .. vim.inspect(s.capabilities))
    local names = vim.tbl_map(function(f)
      return f.filter
    end, filters)
    H.ok(vim.tbl_contains(names, "rust_panic"), vim.inspect(names))
    local picked
    local old = vim.ui.select
    vim.ui.select = function(items, _, cb)
      picked = items
      cb(items[1])
    end
    undo[#undo + 1] = function()
      vim.ui.select = old
    end
    DV.exception_breakpoints()
    H.ok(picked)
    H.eq(true, DV.active_exceptions[filters[1].filter])
    DV.active_exceptions = nil
    wait_gone()
    _ = s
  end)

  it("a panic stops (rust_panic) with the user's frame selected and its locals", function()
    local s0 = session_setup()
    launch({ DV_PANIC = "1" })
    local s = stopped()
    local frames = s.threads[s.stopped_thread_id].frames
    H.match(frames[1].name, "rust_panic", true, vim.inspect(vim.tbl_map(function(f) return f.name end, frames)))
    local cur = H.wait_for(function()
      local f = s.current_frame
      return f and f.name:find("debug_values::main", 1, true) and f
    end, 20000, "main() to be selected")
    H.match(cur.source.path, "src/main.rs", true)
    wait_gone()
    _ = s0
  end)

  it("stepping: over moves to the next line, out returns to the caller", function()
    local s0 = session_setup()
    bp(s0.lines.LOOP)
    launch()
    local s = stopped()
    local dap = require("dap")
    local line0 = s.current_frame.line
    dap.step_over()
    H.wait_for(function()
      local x = dap.session()
      return x and x.stopped_thread_id and x.current_frame and x.current_frame.line ~= line0 and x
    end, 20000, "step over")
    dap.clear_breakpoints() -- the loop breakpoint would stop the next iteration before the frame returns
    dap.step_out()
    local f = H.wait_for(function()
      local x = dap.session()
      local c = x and x.stopped_thread_id and x.current_frame
      return c and c.name:find("debug_values::main", 1, true) and c
    end, 20000, "step out to main")
    H.match(f.name, "main", true)
    wait_gone()
  end)
end)

describe("debugging a test through neotest (strategy dap, real codelldb + rust-analyzer)", function()
  it("<leader>td runs the nearest test under codelldb: stops at the breakpoint inside the test with its locals", function()
    local s0 = session_setup()
    H.wait_lsp("rust-analyzer", vim.api.nvim_get_current_buf(), 120000)
    H.wait_for(function()
      return require("xyno_rust.lsp_status").component():match("^RA ready") ~= nil
    end, 120000, "rust-analyzer ready")
    bp(s0.lines.IN_TEST)
    local nt = require("neotest")
    local nio = require("nio")
    local id = s0.dir .. "/src/main.rs::tests::adds"
    -- a run started before the adapter discovered the file's tests finds none: retry until the dap session starts
    local ran
    local s
    for _ = 1, 8 do
      nio.run(function()
        nt.run.run({ id, strategy = "dap" })
        ran = true
      end)
      local ok, got = pcall(stopped, 20000)
      if ok then
        s = got
        break
      end
    end
    H.ok(s, "the neotest dap run never reached the breakpoint")
    H.eq("debug_values::add", s.current_frame.name)
    local v = locals(s)
    H.eq("2", v.a.value)
    H.eq("3", v.b.value)
    -- and the Rust formatters / preview script are active in this launch too
    H.eq("rust", s.config.sourceLanguages[1])
    H.ok(vim.iter(s.config.initCommands or {}):any(function(c)
      return c:find("xyno_rust_preview.py", 1, true)
    end), "the preview import is in the test launch's initCommands")
    require("dap").continue()
    H.wait_for(function()
      return ran
    end, 120000, "the neotest run to finish")
    wait_gone()
  end)
end)

describe("variable types (real codelldb)", function()
  it("the variables reply carries short type names; vim.g.xynovim_dap_full_types keeps the adapter's", function()
    local s0 = session_setup()
    bp(s0.lines.STOP)
    launch()
    local s = stopped()
    local v = locals(s)
    H.eq("Vec<int>", v.v.type)
    H.eq("HashMap<String, int>", v.m.type)
    H.eq("Rc<String>", v.rc.type)
    H.eq("Option<i32>", v.some.type)
    wait_gone()
    vim.g.xynovim_dap_full_types = true
    undo[#undo + 1] = function()
      vim.g.xynovim_dap_full_types = nil
    end
    launch()
    s = stopped()
    H.eq("alloc::vec::Vec<int, alloc::alloc::Global>", locals(s).v.type)
    wait_gone()
  end)
end)

describe(":checkhealth xynovim: debugger value rendering", function()
  it("reports rust's lldb formatters and the preview script, or says what is missing", function()
    H.need_rust()
    local seen = {}
    local real = vim.health
    local stub = setmetatable({}, {
      __index = function(_, k)
        return function(msg)
          seen[#seen + 1] = k .. ": " .. tostring(msg)
        end
      end,
    })
    vim.health = stub
    local ok, err = pcall(function()
      require("xynovim.health").check()
    end)
    vim.health = real
    H.ok(ok, tostring(err))
    local text = table.concat(seen, "\n")
    H.match(text, "start: xynovim: debugger value rendering", true)
    H.match(text, "content previews (Vec [1, 2, 3], HashMap, Rc, RefCell)", true)
    H.ok(text:find("ok: rust's lldb formatters", 1, true) or text:find("lldb_lookup.py is not in the active toolchain", 1, true))
  end)
end)
