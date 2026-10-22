-- lua/config/ux.lua (diagnostic virtual text, right-click menu, colourblind
-- palette, Neovide), lua/plugins/editing-ui.lua (noice, dashboard, which-key,
-- virtual text format) and lua/plugins/lualine.lua.
local H = require("xynotest.helpers")

local ux = require("config.ux")
local Config = require("lazy.core.config")

-- ------------------------------------------------------------------ helpers

local function opts_of(name)
  local plugin = H.ok(Config.plugins[name], name .. " not in the spec")
  return require("lazy.core.plugin").values(plugin, "opts", false), plugin
end

local function hexc(n)
  return n and string.format("#%06x", n) or nil
end

local function hl(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

--- Scratch buffer with `n` empty-ish lines.
local function scratch(n)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, n or 3 do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

--- Two fresh namespaces; the first has the lower id.
local function two_ns()
  local a = vim.api.nvim_create_namespace("ux-test-a-" .. vim.uv.hrtime())
  local b = vim.api.nvim_create_namespace("ux-test-b-" .. vim.uv.hrtime())
  H.ok(a < b)
  return a, b
end

local function diag(lnum, message, extra)
  return vim.tbl_extend("force", { lnum = lnum, col = 0, message = message, severity = 1 }, extra or {})
end

--- diagnostic_text of the diagnostic `i` stored for `ns` in `buf` (as the
--- real format callback sees it: with bufnr and namespace).
local function text_of(buf, ns, i)
  return ux.diagnostic_text(vim.diagnostic.get(buf, { namespace = ns })[i or 1])
end

local function leafs(items, acc)
  acc = acc or {}
  for _, it in ipairs(items) do
    if it.submenus then
      leafs(it.submenus, acc)
    else
      acc[#acc + 1] = it
    end
  end
  return acc
end

local function menu_names(items, prefix, acc)
  acc = acc or {}
  for _, it in ipairs(items) do
    local path = (prefix and (prefix .. ".") or "") .. it.name
    if it.submenus then
      menu_names(it.submenus, path, acc)
    else
      acc[#acc + 1] = path
    end
  end
  return acc
end

local function rust_buf()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  -- content, so nvim's own ctx-menu (MenuPopup) handler finds a tree
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fn main() {}" })
  vim.bo[buf].filetype = "rust"
  return buf
end

-- LazyVim's keymaps (<leader>cd) and keymaps.lua's toggle load on VeryLazy
H.very_lazy()

local created_ns_bufs = {}
local function track(buf)
  created_ns_bufs[#created_ns_bufs + 1] = buf
  return buf
end

after_each(function()
  vim.diagnostic.reset()
end)

-- ------------------------------------------------------- 1-3 diagnostic_text

describe("ux.diagnostic_text", function()
  it("returns the first non-empty line plus [source]", function()
    H.eq("first [rustc]", ux.diagnostic_text({ message = "\n\nfirst\nsecond", source = "rustc" }))
  end)

  it("returns the bare text without a source", function()
    H.eq("just text", ux.diagnostic_text({ message = "just text\nmore" }))
  end)

  it("reduces a 14 line clippy message to line 1", function()
    local lines = { "warning: this could be written as `let...else`" }
    for i = 2, 14 do
      lines[i] = "  --> src/main.rs:" .. i .. " detail " .. i
    end
    local out = ux.diagnostic_text({ message = table.concat(lines, "\n"), source = "bacon-ls" })
    H.eq("warning: this could be written as `let...else` [bacon-ls]", out)
    H.no_match(out, "\n", true)
  end)

  it("returns '' for an empty message (no source)", function()
    H.eq("", ux.diagnostic_text({ message = "" }))
  end)
end)

describe("ux.diagnostic_text dedupe across namespaces", function()
  it("shows rust-analyzer's (code) over clippy's for the same E-code on a line", function()
    local buf = track(scratch())
    local a, b = two_ns()
    -- the clippy tier has the LOWER namespace id but no `code`
    vim.diagnostic.set(a, buf, {
      diag(1, "error[E0308]: mismatched types\n  --> src/main.rs:2\n  expected `u32`", { source = "bacon-ls" }),
    })
    vim.diagnostic.set(b, buf, { diag(1, "mismatched types", { code = "E0308", source = "rust-analyzer" }) })
    H.is_nil(text_of(buf, a), "clippy duplicate has no virtual text")
    H.eq("mismatched types [rust-analyzer]", text_of(buf, b))
  end)

  it("rust-analyzer's lint name unsafe_op_in_unsafe_fn and clippy's warning[E0133] are one problem (field test: shown twice)", function()
    local buf = track(scratch())
    local a, b = two_ns()
    vim.diagnostic.set(a, buf, {
      diag(1, "warning[E0133]: dereference of raw pointer is unsafe and requires unsafe block\n  --> src/lib.rs:2", { source = "bacon-ls" }),
    })
    vim.diagnostic.set(b, buf, {
      diag(1, "unsafe operation in unsafe function", { code = "unsafe_op_in_unsafe_fn", source = "rust-analyzer" }),
    })
    H.is_nil(text_of(buf, a), "clippy duplicate has no virtual text")
    H.eq("unsafe operation in unsafe function [rust-analyzer]", text_of(buf, b))
  end)

  it("matches by the code inside the first line when `code` is absent on both", function()
    local buf = track(scratch())
    local a, b = two_ns()
    vim.diagnostic.set(a, buf, { diag(0, "error[E0599]: no method named `x`", { source = "one" }) })
    vim.diagnostic.set(b, buf, { diag(0, "error[E0599]: no method named `x` found", { source = "two" }) })
    -- same code, neither coded property: the lower namespace id wins
    H.eq("error[E0599]: no method named `x` [one]", text_of(buf, a))
    H.is_nil(text_of(buf, b))
  end)

  it("without a code, the key is the first line minus 'error: ', case and trailing punctuation", function()
    local buf = track(scratch())
    local a, b = two_ns()
    vim.diagnostic.set(a, buf, { diag(2, "error: Unused variable: `x`. ", { source = "s1" }) })
    vim.diagnostic.set(b, buf, { diag(2, "unused variable: `x`", { source = "s2" }) })
    -- 'error: ' is stripped, 'unused variable: `x`' equal; lower id (a) wins
    H.eq("error: Unused variable: `x`.  [s1]", text_of(buf, a))
    H.is_nil(text_of(buf, b))
  end)

  it("strips a 'warning: ' prefix for the key too", function()
    local buf = track(scratch())
    local a, b = two_ns()
    vim.diagnostic.set(a, buf, { diag(0, "unused import: `std::fmt`", { source = "s1" }) })
    vim.diagnostic.set(b, buf, { diag(0, "warning: unused import: `std::fmt`\n --> x", { source = "s2" }) })
    H.eq("unused import: `std::fmt` [s1]", text_of(buf, a))
    H.is_nil(text_of(buf, b))
  end)

  it("a code on the higher id beats the lower id without one", function()
    local buf = track(scratch())
    local a, b = two_ns()
    vim.diagnostic.set(a, buf, { diag(0, "error[E0001]: y", { source = "s1" }) })
    vim.diagnostic.set(b, buf, { diag(0, "x", { code = "E0001", source = "s2" }) })
    H.is_nil(text_of(buf, a), "uncoded loses although its namespace id is lower")
    H.eq("x [s2]", text_of(buf, b))
  end)
end)

describe("ux.diagnostic_text keeps what is not a duplicate", function()
  it("shows both when the keys differ on the same line", function()
    local buf = track(scratch())
    local a, b = two_ns()
    vim.diagnostic.set(a, buf, { diag(0, "first problem", { source = "s1" }) })
    vim.diagnostic.set(b, buf, { diag(0, "second problem", { source = "s2" }) })
    H.eq("first problem [s1]", text_of(buf, a))
    H.eq("second problem [s2]", text_of(buf, b))
  end)

  it("does not dedupe the same key in the SAME namespace", function()
    local buf = track(scratch())
    local a = two_ns()
    vim.diagnostic.set(a, buf, { diag(0, "same", { source = "s" }), diag(0, "same", { source = "s" }) })
    H.eq("same [s]", text_of(buf, a, 1))
    H.eq("same [s]", text_of(buf, a, 2))
  end)

  it("does not dedupe across different lines", function()
    local buf = track(scratch())
    local a, b = two_ns()
    vim.diagnostic.set(a, buf, { diag(0, "same", { source = "s1" }) })
    vim.diagnostic.set(b, buf, { diag(1, "same", { source = "s2" }) })
    H.eq("same [s1]", text_of(buf, a))
    H.eq("same [s2]", text_of(buf, b))
  end)

  it("skips the dedupe for an invalid bufnr", function()
    local buf = track(scratch())
    local a, b = two_ns()
    vim.diagnostic.set(a, buf, { diag(0, "same", { source = "s1" }) })
    vim.diagnostic.set(b, buf, { diag(0, "same", { source = "s2" }) })
    -- the duplicate would lose with a valid buffer; a bogus bufnr never looks
    local d = vim.deepcopy(vim.diagnostic.get(buf, { namespace = b })[1])
    d.bufnr = 99999
    H.eq("same [s2]", ux.diagnostic_text(d))
    d.bufnr = nil
    H.eq("same [s2]", ux.diagnostic_text(d))
  end)

  it("is the virtual_text.format of the lspconfig opts", function()
    local o = opts_of("nvim-lspconfig")
    H.eq(false, o.diagnostics.virtual_text.source)
    H.eq("fmt [src]", o.diagnostics.virtual_text.format({ message = "fmt\nmore", source = "src" }))
  end)
end)

-- ----------------------------------------------------- 4 DiagnosticChanged

describe("DiagnosticChanged re-render (xynovim_ux)", function()
  local orig_show, calls
  before_each(function()
    orig_show = vim.diagnostic.show
    calls = {}
    vim.diagnostic.show = function(ns, buf, ...)
      calls[#calls + 1] = { ns = ns, buf = buf }
      return orig_show(ns, buf, ...)
    end
  end)
  after_each(function()
    vim.diagnostic.show = orig_show
  end)

  local function full_renders(buf)
    local n = 0
    for _, c in ipairs(calls) do
      if c.ns == nil and c.buf == buf then
        n = n + 1
      end
    end
    return n
  end

  it("has the autocmd in the xynovim_ux group", function()
    local acs = vim.api.nvim_get_autocmds({ group = "xynovim_ux", event = "DiagnosticChanged" })
    H.eq(1, #acs)
  end)

  it("schedules one vim.diagnostic.show(nil, buf), coalescing several changes", function()
    local buf = track(scratch())
    local a, b = two_ns()
    vim.diagnostic.set(a, buf, { diag(0, "one", { source = "s1" }) })
    vim.diagnostic.set(b, buf, { diag(0, "two", { source = "s2" }) })
    vim.diagnostic.set(a, buf, { diag(1, "three", { source = "s1" }) })
    H.eq(0, full_renders(buf), "nothing synchronous")
    H.wait_for(function()
      return full_renders(buf) > 0
    end, 10000, "the scheduled re-render")
    vim.wait(100)
    H.eq(1, full_renders(buf))
    -- the flag is reset: a later change renders again
    vim.diagnostic.set(a, buf, { diag(0, "four", { source = "s1" }) })
    H.wait_for(function()
      return full_renders(buf) == 2
    end, 10000, "second render")
  end)

  it("ignores a buffer that is gone by the time the schedule runs", function()
    local buf = scratch()
    local a = two_ns()
    vim.diagnostic.set(a, buf, { diag(0, "one", { source = "s1" }) })
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.wait(150)
    H.eq(0, full_renders(buf))
  end)
end)

-- -------------------------------------------------------------- 5 <leader>cd

describe("<leader>cd", function()
  it("is LazyVim's line diagnostics and the float shows the full message", function()
    local buf = track(scratch())
    vim.api.nvim_set_current_buf(buf)
    local a = two_ns()
    vim.diagnostic.set(a, buf, { diag(0, "head line\ndetail line two\ndetail line three", { source = "src" }) })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local m = vim.fn.maparg("<leader>cd", "n", false, true)
    H.eq("Line Diagnostics", m.desc)
    m.callback()
    local float
    H.wait_for(function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          float = w
          return true
        end
      end
    end, 2000, "diagnostic float")
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), "\n")
    H.has(text, "head line")
    H.has(text, "detail line two")
    H.has(text, "detail line three")
    pcall(vim.api.nvim_win_close, float, true)
  end)
end)

-- ------------------------------------------------------- 6-8 right-click menu

describe("right-click menu PopUp.Rust", function()
  local function popup(buf)
    vim.api.nvim_set_current_buf(buf)
    -- nvim's own ctx-menu handler asserts on a highlighter whose tree was
    -- never parsed (a buffer that was never drawn)
    pcall(vim.treesitter.stop, buf)
    vim.cmd("doautocmd MenuPopup")
    local ok, items = pcall(vim.fn.menu_get, "PopUp.Rust")
    return ok and items or {}
  end

  it("a MenuPopup autocmd exists in xynovim_ux", function()
    H.eq(1, #vim.api.nvim_get_autocmds({ group = "xynovim_ux", event = "MenuPopup" }))
  end)

  it("leaves no PopUp.Rust in a toml buffer (and removes a stale one)", function()
    local rb = track(rust_buf())
    H.eq(1, #popup(rb))
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "[package]" })
    vim.bo[buf].filetype = "toml"
    H.eq({}, popup(buf))
  end)

  it("builds 10 leaf entries in a Rust buffer", function()
    local items = popup(track(rust_buf()))
    H.eq(1, #items)
    local names = menu_names(items[1].submenus, "Rust")
    table.sort(names)
    local want = {
      "Rust.Rename",
      "Rust.Find Usages",
      "Rust.Refactor.Actions ...",
      "Rust.Refactor.Extract Variable",
      "Rust.Refactor.Extract Function",
      "Rust.Refactor.Extract Constant",
      "Rust.Refactor.Extract Module",
      "Rust.Refactor.Inline",
      "Rust.Expand Macro",
      "Rust.Run Target ...",
    }
    table.sort(want)
    H.eq(want, names)
    H.eq(10, #leafs(items[1].submenus))
  end)

  it("Rename and Find Usages call lua directly, the others go through ux.leader", function()
    local items = popup(track(rust_buf()))
    local by = {}
    for _, it in ipairs(leafs(items[1].submenus)) do
      by[it.name:gsub("\\", "")] = it.mappings.n.rhs
    end
    H.match(by["Rename"], "lua vim.lsp.buf.rename()", true)
    H.match(by["Find Usages"], "lua Snacks.picker.lsp_references()", true)
    local suffix = {
      ["Actions ..."] = "ra",
      ["Extract Variable"] = "rv",
      ["Extract Function"] = "rf",
      ["Extract Constant"] = "rc",
      ["Extract Module"] = "rM",
      ["Inline"] = "ri",
      ["Expand Macro"] = "rm",
      ["Run Target ..."] = "rX",
    }
    for name, s in pairs(suffix) do
      H.match(by[name], "require('config.ux').leader('" .. s .. "')", true, name)
    end
  end)

  it("rebuilds rather than duplicating on a second MenuPopup", function()
    local buf = track(rust_buf())
    popup(buf)
    local items = popup(buf)
    H.eq(10, #leafs(items[1].submenus))
  end)

  it("a menu entry actually runs ux.leader (Expand Macro feeds <leader>rm)", function()
    local buf = track(rust_buf())
    popup(buf)
    local got
    local orig = ux.leader
    ux.leader = function(s)
      got = s
    end
    local ok, err = pcall(vim.cmd, "emenu PopUp.Rust.Expand\\ Macro")
    ux.leader = orig
    H.ok(ok, tostring(err))
    H.eq("rm", got)
  end)
end)

describe("ux.leader", function()
  local mapped
  after_each(function()
    pcall(vim.keymap.del, "n", "<leader>zQ")
    mapped = nil
  end)

  it("feeds <leader>+suffix with mode 'mt'", function()
    local orig = vim.api.nvim_feedkeys
    local args
    vim.api.nvim_feedkeys = function(...)
      args = { ... }
    end
    local ok, err = pcall(ux.leader, "ra")
    vim.api.nvim_feedkeys = orig
    H.ok(ok, tostring(err))
    H.eq(vim.keycode("<leader>") .. "ra", args[1])
    H.eq("mt", args[2])
  end)

  it("runs the real mapping", function()
    vim.keymap.set("n", "<leader>zQ", function()
      mapped = true
    end)
    ux.leader("zQ")
    H.feed("", "x")
    H.eq(true, mapped)
  end)
end)

-- ----------------------------------------------------------- 9-11 colourblind

describe("colourblind diagnostics", function()
  local OKABE = { Error = "#e06a0e", Warn = "#f0e442", Info = "#56b4e9", Hint = "#009e73", Ok = "#0072b2" }
  local FG = { "Diagnostic", "DiagnosticSign", "DiagnosticFloating", "DiagnosticVirtualText", "DiagnosticVirtualLines" }

  before_each(function()
    ux.colorblind(false)
    vim.cmd("colorscheme island-dark")
  end)
  after_each(function()
    ux.colorblind(false)
    vim.cmd("colorscheme island-dark")
  end)

  local function check_on()
    for kind, color in pairs(OKABE) do
      for _, p in ipairs(FG) do
        H.eq(color, hexc(hl(p .. kind).fg), p .. kind .. " fg")
        if p:find("Virtual") then
          H.is_nil(hl(p .. kind).bg, p .. kind .. " bg")
        end
      end
      H.eq(color, hexc(hl("DiagnosticUnderline" .. kind).sp), "underline " .. kind)
    end
  end

  it("is off by default", function()
    H.eq(false, ux.colorblind_enabled())
    H.eq("#f75464", hexc(hl("DiagnosticError").fg))
  end)

  it("uses the Okabe-Ito colours when on", function()
    H.eq(true, ux.colorblind(true))
    H.eq(true, ux.colorblind_enabled())
    check_on()
    H.eq("#e06a0e", hexc(hl("DiagnosticError").fg))
    H.eq("#f0e442", hexc(hl("DiagnosticWarn").fg))
    H.eq("#56b4e9", hexc(hl("DiagnosticInfo").fg))
    H.eq("#009e73", hexc(hl("DiagnosticHint").fg))
    H.eq("#0072b2", hexc(hl("DiagnosticOk").fg))
  end)

  it("survives :colorscheme habamax", function()
    ux.colorblind(true)
    vim.cmd("colorscheme habamax")
    H.eq("habamax", vim.g.colors_name)
    check_on()
  end)

  it("survives `highlight clear` + :colorscheme tokyonight-moon", function()
    ux.colorblind(true)
    vim.cmd("highlight clear")
    vim.cmd("colorscheme tokyonight-moon")
    H.eq("tokyonight-moon", vim.g.colors_name)
    check_on()
  end)

  it("off re-runs the colourscheme and restores the island colours", function()
    ux.colorblind(true)
    H.eq("#e06a0e", hexc(hl("DiagnosticError").fg))
    H.eq(false, ux.colorblind(false))
    H.eq("island-dark", vim.g.colors_name)
    H.eq("#f75464", hexc(hl("DiagnosticError").fg))
  end)

  it("colorblind(nil) toggles, true/false set, and the new state is returned", function()
    H.eq(true, ux.colorblind())
    H.eq(false, ux.colorblind(nil))
    H.eq(true, ux.colorblind(true))
    H.eq(true, ux.colorblind(true))
    H.eq(false, ux.colorblind(false))
    H.eq(false, ux.colorblind(false))
    H.eq(false, ux.colorblind_enabled())
  end)

  it(":ColorblindDiagnostics toggles and notifies on/off", function()
    local cap = H.capture_notify()
    vim.cmd("ColorblindDiagnostics")
    H.eq(true, ux.colorblind_enabled())
    vim.cmd("ColorblindDiagnostics")
    H.eq(false, ux.colorblind_enabled())
    cap.restore()
    local msgs = vim.tbl_map(function(n)
      return n.msg
    end, cap.list)
    H.eq({ "colourblind diagnostics on", "colourblind diagnostics off" }, msgs)
  end)

  it("<leader>uB is a Snacks toggle 'Colourblind diagnostics' on the same state", function()
    local m = vim.fn.maparg("<leader>uB", "n", false, true)
    H.ok(m.callback, "<leader>uB mapped")
    H.match(m.desc, "Colourblind diagnostics", true)
    m.callback()
    H.eq(true, ux.colorblind_enabled())
    check_on()
    m.callback()
    H.eq(false, ux.colorblind_enabled())
    -- and the other way: the state set through ux shows in the toggle
    ux.colorblind(true)
    m.callback()
    H.eq(false, ux.colorblind_enabled())
  end)

  it("vim.g.xynovim_colorblind = true at setup starts enabled", function()
    vim.g.xynovim_colorblind = true
    local ok, err = pcall(ux.setup)
    vim.g.xynovim_colorblind = nil
    H.ok(ok, tostring(err))
    H.eq(true, ux.colorblind_enabled())
    -- a ColorScheme event applies the palette (the autocmd was recreated)
    vim.cmd("colorscheme habamax")
    check_on()
  end)

  it("without the global setup keeps it off", function()
    vim.g.xynovim_colorblind = nil
    ux.setup()
    H.eq(true, ux.colorblind_enabled() == ux.colorblind_enabled())
    -- state is module-local and is not reset by setup; after_each/before_each
    -- turned it off, so it is off
    H.eq(false, ux.colorblind_enabled())
  end)
end)

-- ------------------------------------------------------------------ 12 Neovide

describe("Neovide settings", function()
  local KEYS = {
    "neovide_position_animation_length",
    "neovide_scroll_animation_length",
    "neovide_cursor_animation_length",
    "neovide_cursor_trail_size",
    "neovide_cursor_animate_in_insert_mode",
    "neovide_cursor_animate_command_line",
    "neovide_opacity",
  }
  local function clear()
    vim.g.neovide = nil
    for _, k in ipairs(KEYS) do
      vim.g[k] = nil
    end
  end
  before_each(clear)
  after_each(clear)

  it("sets nothing without g:neovide", function()
    ux.setup()
    for _, k in ipairs(KEYS) do
      H.is_nil(vim.g[k], k)
    end
  end)

  it("sets no animations and 0.9 opacity with g:neovide", function()
    vim.g.neovide = true
    ux.setup()
    H.eq(0, vim.g.neovide_position_animation_length)
    H.eq(0, vim.g.neovide_scroll_animation_length)
    H.eq(0, vim.g.neovide_cursor_animation_length)
    H.eq(0, vim.g.neovide_cursor_trail_size)
    H.eq(false, vim.g.neovide_cursor_animate_in_insert_mode)
    H.eq(false, vim.g.neovide_cursor_animate_command_line)
    H.eq(0.9, vim.g.neovide_opacity)
  end)
end)

-- ---------------------------------------------------------------------- 13 noice

describe("noice (editing-ui)", function()
  local Msg, Manager
  before_each(function()
    Msg = require("noice.ui.msg")
    Manager = require("noice.message.manager")
  end)

  it("turns on presets.lsp_doc_border", function()
    local o = opts_of("noice.nvim")
    H.eq(true, o.presets.lsp_doc_border)
  end)

  it("wraps Msg.on_showcmd once, a second evaluation does not wrap again", function()
    opts_of("noice.nvim")
    H.eq(true, Msg.xynovim_showcmd)
    local after_first = Msg.on_showcmd
    opts_of("noice.nvim")
    opts_of("noice.nvim")
    H.ok(Msg.on_showcmd == after_first, "on_showcmd was wrapped again")
    H.ok(Msg.on_showcmd ~= Msg.on_showmode, "on_showcmd is still the original alias")
  end)

  it("an empty showcmd removes the message, a non-empty one is stored", function()
    opts_of("noice.nvim")
    local ev = "msg_showcmd"
    local function stored()
      return Manager.get({ event = ev })[1]
    end
    -- start clean
    pcall(Manager.remove, Msg.get(ev))
    Msg.on_showcmd(ev, { { 0, "d" } })
    local m = H.ok(stored(), "message stored for a pending key")
    H.eq("d", m:content())
    Msg.on_showcmd(ev, {})
    H.is_nil(stored(), "empty showcmd clears the message")
    H.is_nil(Manager.get({ event = ev }, { history = true })[1], "and the history")
  end)
end)

-- --------------------------------------------------------------- 14 options

describe("float options", function()
  it("winborder is rounded and pumblend 0", function()
    H.eq("rounded", vim.o.winborder)
    H.eq(0, vim.o.pumblend)
  end)
end)

-- ----------------------------------------------------------------- 15 dashboard

describe("snacks dashboard sections", function()
  it("are header, keys (tall), keys (short), startup", function()
    local o = opts_of("snacks.nvim")
    local s = o.dashboard.sections
    H.eq(4, #s)
    H.eq("header", s[1].section)
    H.eq("keys", s[2].section)
    H.eq(1, s[2].gap)
    H.eq(1, s[2].padding)
    H.eq("keys", s[3].section)
    H.eq(0, s[3].gap)
    H.eq(1, s[3].padding)
    H.eq("startup", s[4].section)
  end)

  it("enable the right keys section from 2n + 11 rows (n entries: 39 with today's 14) and above/below", function()
    local o = opts_of("snacks.nvim")
    local s = o.dashboard.sections
    local need = 2 * #o.dashboard.preset.keys + 11
    local lines = vim.o.lines
    local ok, err = pcall(function()
      for _, n in ipairs({ 24, need - 1, need, 50 }) do
        vim.o.lines = n
        local tall = n >= need
        H.eq(tall, s[2].enabled(), "tall section at " .. n)
        H.eq(not tall, s[3].enabled(), "short section at " .. n)
      end
    end)
    vim.o.lines = lines
    H.ok(ok, tostring(err))
  end)

  it("at 80x24 the last entry and the footer are visible (tmux)", function()
    H.need_tmux()
    local session = "dash"
    local env = {}
    for _, k in ipairs({ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "TMPDIR", "HOME" }) do
      if vim.env[k] then
        env[#env + 1] = ("%s=%s"):format(k, vim.fn.shellescape(vim.env[k]))
      end
    end
    local cmd = "env " .. table.concat(env, " ") .. " " .. vim.fn.shellescape(vim.fn.exepath("nvim"))
    local r = H.tmux({ "new-session", "-d", "-s", session, "-x", "80", "-y", "24", cmd }, "dash")
    H.eq(0, r.code, r.stderr)
    local pane = ""
    local seen = pcall(H.wait_for, function()
      pane = H.tmux({ "capture-pane", "-p", "-t", session }, "dash").stdout or ""
      return pane:find("Quit", 1, true) and pane:find("loaded", 1, true)
    end, 30000, "dashboard with Quit and the startup footer")
    H.ok(seen, "dashboard did not show Quit and the footer at 80x24:\n" .. pane)
    H.has(pane, "Find File")
    H.has(pane, "Quit")
    H.match(pane, "loaded %d+/%d+ plugins")
  end)
end)

-- ---------------------------------------------------------------- 16 which-key

describe("which-key spec", function()
  it("names <leader>9 '99 (agent)'", function()
    -- which-key consumes the opts table's spec at setup (scheduled), so read
    -- the mappings it registered
    local Wk = require("which-key.config")
    H.wait_for(function()
      return Wk.loaded
    end, 5000, "which-key setup")
    local found
    for _, m in ipairs(Wk.mappings) do
      if m.group and m.desc == "99 (agent)" and (m.lhs == "<leader>9" or m.lhs == vim.g.mapleader .. "9") then
        found = true
      end
    end
    H.ok(found, "group <leader>9 = '99 (agent)' registered in which-key")
  end)

  it("registers the <leader>t (test) and <leader>a (ai) groups, whose popup was missing when typed fast", function()
    local Wk = require("which-key.config")
    H.wait_for(function()
      return Wk.loaded
    end, 5000, "which-key setup")
    for lhs, desc in pairs({ t = "test", a = "ai" }) do
      local found
      for _, m in ipairs(Wk.mappings) do
        if m.group and m.desc == desc and (m.lhs == "<leader>" .. lhs or m.lhs == vim.g.mapleader .. lhs) then
          found = true
        end
      end
      H.ok(found, "group <leader>" .. lhs .. " = '" .. desc .. "' registered in which-key")
    end
  end)
end)

describe("pickers and outline (field test)", function()
  it("the file and grep pickers exclude an anchored /target (no .gitignore needed)", function()
    local opts = {}
    for _, spec in ipairs(dofile(H.repo .. "/lua/plugins/editing-ui.lua")) do
      if spec[1] == "folke/snacks.nvim" and type(spec.opts) == "function" then
        spec.opts({}, opts)
      end
    end
    H.eq({ "/target" }, opts.picker.sources.files.exclude)
    H.eq({ "/target" }, opts.picker.sources.grep.exclude)
  end)

  it("the rust kind filter of the document outline contains Object (impl blocks) on top of the default", function()
    local opts = {}
    for _, spec in ipairs(dofile(H.repo .. "/lua/plugins/editing-ui.lua")) do
      if spec[1] == "LazyVim/LazyVim" and type(spec.opts) == "function" then
        spec.opts({}, opts)
      end
    end
    local rust = opts.kind_filter.rust
    H.ok(vim.tbl_contains(rust, "Object"), "Object")
    for _, k in ipairs(LazyVim.config.kind_filter.default) do
      H.ok(vim.tbl_contains(rust, k), k)
    end
    -- and it is what the running LazyVim uses for a rust buffer
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "rust"
    H.ok(vim.tbl_contains(LazyVim.config.get_kind_filter(buf) or {}, "Object"), "live kind filter")
  end)
end)

describe("snacks picker layout", function()
  it("a window under 30 lines and 120 columns gets the preview-less select layout (80x24 border overdraw)", function()
    local opts = {}
    for _, spec in ipairs(dofile(H.repo .. "/lua/plugins/editing-ui.lua")) do
      if spec[1] == "folke/snacks.nvim" and type(spec.opts) == "function" then
        spec.opts({}, opts)
      end
    end
    local preset = opts.picker and opts.picker.layout and opts.picker.layout.preset
    H.eq("function", type(preset))
    local cols, lines = vim.o.columns, vim.o.lines
    local function at(c, l)
      vim.o.columns, vim.o.lines = c, l
      return preset()
    end
    local ok, a, b, c, d = pcall(function()
      return at(80, 24), at(80, 40), at(160, 24), at(160, 50)
    end)
    vim.o.columns, vim.o.lines = cols, lines
    H.ok(ok, tostring(a))
    H.eq({ "select", "vertical", "default", "default" }, { a, b, c, d })
  end)
end)

-- ---------------------------------------------------------------------- 17 lualine

describe("lualine_x", function()
  it("starts with lsp_status.component, hidden when it is empty", function()
    local o = opts_of("lualine.nvim")
    local first = o.sections.lualine_x[1]
    local status = require("xyno_rust.lsp_status")
    H.ok(first[1] == status.component, "first component is lsp_status.component")
    H.eq("function", type(first.cond))
    local orig = status.component
    status.component = function()
      return ""
    end
    local ok1, hidden = pcall(first.cond)
    status.component = function()
      return "rust-analyzer ready"
    end
    local ok2, shown = pcall(first.cond)
    status.component = orig
    H.ok(ok1 and ok2)
    H.eq(false, hidden)
    H.eq(true, shown)
  end)

  it("the real component is '' in a non-Rust buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "text"
    H.eq("", require("xyno_rust.lsp_status").component())
  end)
end)

-- ----------------------------------------------------------- 18-20 elsewhere

describe("items covered elsewhere", function()
  pending("'unsafe' underline highlighting", "covered by theme-island_spec.lua")
  pending("cargo-machete findings not doubled / cargo-deny wildcard line", "covered by the git-lint-supply-chain spec")
  pending("<leader>uC previews of light themes leak background=light", "documented README limitation, informational")
  pending("v:errmsg E31 when opening markdown", "documented nvim undo_ftplugin behaviour, informational")
end)
