-- xyno-timeout: 400
-- Global keymaps of this repo (lua/config/keymaps.lua, diffview, coverage,
-- ninety-nine, harpoon, editing-ui, navigation, dap) and the LazyVim keys the
-- enabled extras are expected to provide. Needs rust-analyzer only for the
-- tests that look at buffer-local Rust maps (they skip without it).
local H = require("xynotest.helpers")

local leader = vim.g.mapleader or " "

--- Map dictionary (maparg) for `lhs` ("<leader>" expands) in `mode`, {} if unmapped.
local function md(lhs, mode)
  return vim.fn.maparg(lhs, mode or "n", false, true)
end

local function plugin(name)
  return require("lazy.core.config").plugins[name]
end

--- lazy key specs of a plugin: { lhs, mode (string|table|nil), desc }.
local function lazy_keys(name)
  local p = plugin(name)
  H.ok(p, "plugin " .. name .. " is not in the spec")
  local out = {}
  for _, k in ipairs(p.keys or {}) do
    if type(k) == "string" then
      k = { k }
    end
    out[#out + 1] = { lhs = k[1], mode = k.mode, desc = k.desc }
  end
  return out
end

local function lazy_key(name, lhs, mode)
  for _, k in ipairs(lazy_keys(name)) do
    local modes = type(k.mode) == "table" and k.mode or { k.mode or "n" }
    if k.lhs == lhs and (not mode or vim.tbl_contains(modes, mode)) then
      return k
    end
  end
end

local function lower(s)
  return (s or ""):lower()
end

-- ------------------------------------------------------------------ startup
-- (first: nothing below may have used the lazy keys yet)

describe("lazy loading of the key-driven plugins", function()
  before_each(function()
    H.open(H.fixture("standalone.rs"))
  end)

  it("harpoon, nvim-coverage and 99 stay unloaded after startup", function()
    H.is_nil(package.loaded["harpoon"], "package.loaded.harpoon")
    H.is_nil(package.loaded["coverage"], "package.loaded.coverage")
    H.is_nil(package.loaded["99"], "package.loaded.99")
    for _, n in ipairs({ "harpoon", "nvim-coverage", "99" }) do
      H.ok(plugin(n), n .. " in spec")
      H.not_ok(plugin(n)._.loaded, n .. " must not be loaded yet")
    end
  end)
end)

-- ------------------------------------------------------------------ item 1/2

describe("global normal maps defined by this repo", function()
  before_each(function()
    H.open(H.fixture("standalone.rs"))
  end)

  local expected = {
    { "n", "<leader>uB", "olourblind" },
    { "n", "<leader>gH", "Local history (file)" },
    { "n", "<leader>uu", "Undotree" },
    { "n", "<leader>uO", nil },
    { "n", "<leader>gv", "Diffview: working tree / conflicts" },
    { "n", "<leader>gV", "Diffview: branch vs origin" },
    { "n", "<leader>gF", "Diffview: file history" },
    { "x", "<leader>gF", "Diffview: selection history" },
    { "n", "<leader>gq", "Diffview: close" },
    { "n", "<leader>tc", "Coverage: run + show" },
    { "n", "<leader>tg", "Coverage: toggle signs" },
    { "n", "<leader>tG", "Coverage: summary" },
    { "n", "<leader>H", "Harpoon: Add file" },
    { "n", "<C-e>", "Harpoon: Quick menu" },
    { "n", "<M-1>", "Harpoon: Jump to file 1" },
    { "n", "<M-2>", "Harpoon: Jump to file 2" },
    { "n", "<M-3>", "Harpoon: Jump to file 3" },
    { "n", "<M-4>", "Harpoon: Jump to file 4" },
    { "n", "<leader>cI", "Incoming calls (tree)" },
    { "n", "<leader>cO", "Outgoing calls (tree)" },
    { "n", "<leader>cj", "Split/join (treesitter)" },
    { "n", "<leader>dR", "Rust Debuggables (whole workspace)" },
    { "n", "<leader>9s", "99: Search" },
    { "n", "<leader>9v", "99: Vibe" },
    { "v", "<leader>9vv", "99: Visual" },
    { "n", "<leader>9o", "99: Open last interaction" },
    { "n", "<leader>9l", "99: View logs" },
    { "n", "<leader>9c", "99: Clear previous" },
    { "n", "<leader>9x", "99: Stop all requests" },
    { "n", "<leader>9w", "99: Worker search" },
    { "n", "<leader>9W", "99: Worker set work" },
    { "n", "<leader>9m", "99: Select model" },
    { "n", "<leader>9P", "99: Select provider" },
  }

  for _, e in ipairs(expected) do
    local mode, lhs, want = e[1], e[2], e[3]
    it(("%s %s is mapped globally%s"):format(mode, lhs, want and (" (" .. want .. ")") or ""), function()
      local m = md(lhs, mode)
      H.ok(next(m), lhs .. " is not mapped in mode " .. mode)
      H.eq(0, m.buffer, lhs .. " must be a global map")
      if want then
        H.match(m.desc or "", want, true, lhs .. " desc")
      else
        H.ok((m.desc or "") ~= "", lhs .. " has no desc")
      end
    end)
  end
end)

describe("Diffview keys", function()
  local calls
  local root

  before_each(function()
    -- load diffview first (loading defines the real commands), then replace
    -- the commands by recorders: the keys are what is under test
    require("lazy").load({ plugins = { "diffview.nvim" } })
    calls = {}
    for _, c in ipairs({ "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" }) do
      vim.api.nvim_create_user_command(c, function(o)
        calls[#calls + 1] = { cmd = c, args = o.args, range = o.range, line1 = o.line1, line2 = o.line2 }
      end, { nargs = "*", range = true, force = true })
    end
    root = H.tmpdir()
    vim.fn.writefile({ "one", "two", "three" }, root .. "/a.txt")
    H.git_init(root)
    vim.cmd.cd(vim.fn.fnameescape(root))
    H.open(root .. "/a.txt")
  end)

  it("<leader>gv runs :DiffviewOpen (working tree / conflicts)", function()
    H.eq("Diffview: working tree / conflicts", md("<leader>gv").desc)
    H.feed("<leader>gv")
    H.eq({ { cmd = "DiffviewOpen", args = "", range = 0, line1 = calls[1] and calls[1].line1, line2 = calls[1] and calls[1].line2 } }, calls)
  end)

  it("<leader>gq runs :DiffviewClose", function()
    H.eq("Diffview: close", md("<leader>gq").desc)
    H.feed("<leader>gq")
    H.eq(1, #calls)
    H.eq("DiffviewClose", calls[1].cmd)
    -- unsaved buffers are written first (a raw E445 from tabclose otherwise)
    H.match(lower(md("<leader>gq").rhs), "silent! wall", true)
  end)

  it("<leader>gF (n) is :DiffviewFileHistory % for the current file", function()
    H.eq("Diffview: file history", md("<leader>gF", "n").desc)
    H.match(lower(md("<leader>gF", "n").rhs), "diffviewfilehistory %%")
    H.feed("<leader>gF")
    H.eq(1, #calls)
    H.eq("DiffviewFileHistory", calls[1].cmd)
    -- the % is passed through as the file argument (diffview expands it)
    H.eq("%", calls[1].args)
  end)

  it("<leader>gF (x) is :DiffviewFileHistory on the selection (range)", function()
    local m = md("<leader>gF", "x")
    H.eq("Diffview: selection history", m.desc)
    H.match(lower(m.rhs), "^:diffviewfilehistory<cr>$")
    vim.cmd("normal! gg")
    H.feed("Vj<leader>gF")
    H.eq(1, #calls)
    H.eq("DiffviewFileHistory", calls[1].cmd)
    H.eq(2, calls[1].range)
    H.eq({ 1, 2 }, { calls[1].line1, calls[1].line2 })
  end)

  it("<leader>gV opens origin/HEAD...HEAD when origin/HEAD exists, preferring it over main and master", function()
    H.git(root, "update-ref", "refs/remotes/origin/master", "HEAD")
    H.git(root, "update-ref", "refs/remotes/origin/main", "HEAD")
    H.git(root, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master")
    H.feed("<leader>gV")
    H.eq(1, #calls)
    H.eq({ "DiffviewOpen", "origin/HEAD...HEAD" }, { calls[1].cmd, calls[1].args })
  end)

  it("<leader>gV falls back to origin/main, then origin/master", function()
    H.git(root, "update-ref", "refs/remotes/origin/master", "HEAD")
    H.feed("<leader>gV")
    H.eq("origin/master...HEAD", calls[1].args)
    H.git(root, "update-ref", "refs/remotes/origin/main", "HEAD")
    H.feed("<leader>gV")
    H.eq("origin/main...HEAD", calls[2].args)
  end)

  it("<leader>gV warns when there is no origin/HEAD, origin/main or origin/master", function()
    local cap = H.capture_notify()
    H.feed("<leader>gV")
    cap.restore()
    H.eq(0, #calls)
    H.eq(1, #cap.list)
    H.eq(
      "no origin/HEAD, origin/main or origin/master here (git remote set-head origin -a sets it)",
      cap.list[1].msg
    )
    H.eq(vim.log.levels.WARN, cap.list[1].level)
  end)
end)

-- ------------------------------------------------------------------ item 4-6

describe("99 (agent) keys", function()
  before_each(function()
    H.open(H.fixture("standalone.rs"))
  end)

  it("which-key names the <leader>9 group '99 (agent)'", function()
    local found
    local seen = {} -- a spec may reference shared tables: never revisit one (a cycle hung the covered run)
    local function walk(spec)
      if seen[spec] then
        return
      end
      seen[spec] = true
      for _, s in ipairs(spec) do
        if type(s) == "table" then
          if s[1] == "<leader>9" and s.group == "99 (agent)" then
            found = true
          end
          walk(s)
        end
      end
    end
    -- which-key consumes the spec of its opts when it is set up (it empties it in place), so what
    -- the walks see depends on whether it was loaded by an earlier test: the source text is the
    -- fixed check, the two walks are informational
    local src = table.concat(vim.fn.readfile(H.repo .. "/lua/plugins/editing-ui.lua"), "\n")
    H.match(src, '"<leader>9", group = "99 %(agent%)"')
    local opts = require("lazy.core.plugin").values(plugin("which-key.nvim"), "opts", false)
    walk(opts.spec or {})
    local in_opts = found
    found = false
    seen = {}
    walk(require("which-key.config").options.spec or {})
    print(("INFO <leader>9 group seen in the opts spec: %s, in which-key's resolved spec: %s"):format(tostring(in_opts), tostring(found)))
  end)

  -- README table of keys of 99: key -> documented desc
  local documented = {
    s = "Search",
    v = "Vibe",
    o = "Open last interaction",
    l = "View logs",
    c = "Clear previous",
    x = "Stop all requests",
    w = "Worker search",
    W = "Worker set work",
    m = "Select model",
    P = "Select provider",
  }
  for key, text in pairs(documented) do
    it("<leader>9" .. key .. " is '99: " .. text .. "' in normal mode", function()
      local m = md("<leader>9" .. key, "n")
      H.eq("99: " .. text, m.desc)
      H.eq(0, m.buffer)
    end)
  end

  it("<leader>9vv is a visual-only map, <leader>9v a normal-mode one", function()
    local function in_mode(mode, lhs)
      for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
        if m.lhs == lhs:gsub("<leader>", "<Space>") or m.lhs == lhs:gsub("<leader>", leader) then
          return m
        end
      end
    end
    H.ok(in_mode("v", "<leader>9vv"), "<leader>9vv missing in visual mode")
    H.eq("99: Visual", in_mode("v", "<leader>9vv").desc)
    H.is_nil(in_mode("n", "<leader>9vv"), "<leader>9vv must not exist in normal mode")
    H.is_nil(in_mode("i", "<leader>9vv"), "<leader>9vv must not exist in insert mode")
    H.ok(in_mode("n", "<leader>9v"), "<leader>9v missing in normal mode")
    H.is_nil(in_mode("v", "<leader>9v"), "<leader>9v must not exist in visual mode")
    -- lazy's spec says the same
    H.eq("v", lazy_key("99", "<leader>9vv").mode)
  end)
end)

-- ------------------------------------------------------------------ item 7-9

describe("harpoon, claudecode and coverage keys", function()
  before_each(function()
    H.open(H.fixture("standalone.rs"))
  end)

  it("harpoon keys carry their descriptions and are lazy keys of the harpoon plugin", function()
    local want = {
      ["<leader>H"] = "Harpoon: Add file",
      ["<C-e>"] = "Harpoon: Quick menu",
      ["<M-1>"] = "Harpoon: Jump to file 1",
      ["<M-2>"] = "Harpoon: Jump to file 2",
      ["<M-3>"] = "Harpoon: Jump to file 3",
      ["<M-4>"] = "Harpoon: Jump to file 4",
    }
    for lhs, desc in pairs(want) do
      local k = lazy_key("harpoon", lhs)
      H.ok(k, lhs .. " is not a harpoon key")
      H.eq(desc, k.desc)
      H.eq(desc, md(lhs).desc, lhs .. " live map desc")
    end
    H.eq(6, #lazy_keys("harpoon"))
  end)

  it("<leader>a belongs to claudecode (+ai group, ab ac af ar aC aa ad, as in visual), not harpoon", function()
    for _, k in ipairs(lazy_keys("harpoon")) do
      H.no_match(k.lhs, "^<leader>a", false, "harpoon key " .. k.lhs)
    end
    for _, lhs in ipairs({ "<leader>ab", "<leader>ac", "<leader>af", "<leader>ar", "<leader>aC", "<leader>aa", "<leader>ad" }) do
      local m = md(lhs, "n")
      H.ok(next(m), lhs .. " not mapped")
      H.no_match(m.desc or "", "Harpoon")
    end
    H.eq("Send to Claude", md("<leader>as", "v").desc)
    -- the extra's empty-rhs "+ai" stub became a real no-op mapping that shadowed which-key's
    -- trigger (no popup when typed fast): it is off, the group comes from which-key's spec
    for _, mode in ipairs({ "n", "v" }) do
      local m = md("<leader>a", mode)
      H.ok(not next(m) or (m.desc or ""):find("which-key-trigger", 1, true), "no stub mapping on <leader>a (" .. mode .. ")")
    end
    local nt = md("<leader>t", "n")
    H.ok(not next(nt) or (nt.desc or ""):find("which-key-trigger", 1, true), "no stub mapping on <leader>t")
    H.eq("Run File (Neotest)", md("<leader>tt", "n").desc, "the real neotest keys stay")
    require("lazy").load({ plugins = { "which-key.nvim" } })
    local groups = {}
    for _, km in ipairs(require("which-key.config").mappings) do
      if km.group then
        groups[km.lhs] = type(km.desc) == "string" and km.desc or true
      end
    end
    for _, k in ipairs({ "<leader>a", "<leader>t", "<leader>R", "<leader>r" }) do
      H.ok(groups[k], "which-key group " .. k)
    end
  end)

  it("coverage keys are lazy: present with their descs while nvim-coverage stays unloaded", function()
    local want = {
      ["<leader>tc"] = "Coverage: run + show",
      ["<leader>tg"] = "Coverage: toggle signs",
      ["<leader>tG"] = "Coverage: summary",
    }
    for lhs, desc in pairs(want) do
      H.eq(desc, md(lhs).desc, lhs)
      H.eq(desc, lazy_key("nvim-coverage", lhs).desc)
    end
    H.is_nil(package.loaded["coverage"], "package.loaded.coverage")
    H.not_ok(plugin("nvim-coverage")._.loaded, "nvim-coverage loaded")
  end)
end)

-- ------------------------------------------------------------------ item 10

describe("<leader>dR (Rust debuggables for the workspace)", function()
  it("is a lazy key of nvim-dap", function()
    H.open(H.fixture("standalone.rs"))
    local k = lazy_key("nvim-dap", "<leader>dR")
    H.ok(k, "<leader>dR is not a key of nvim-dap")
    H.eq("Rust Debuggables (whole workspace)", k.desc)
    H.eq("Rust Debuggables (whole workspace)", md("<leader>dR").desc)
  end)

  it("warns '<leader>dR works from a Rust buffer' in a non-Rust buffer", function()
    local dir = H.tmpdir()
    vim.fn.writefile({ "print('x')" }, dir .. "/a.lua")
    H.open(dir .. "/a.lua")
    H.eq("lua", vim.bo.filetype)
    local cap = H.capture_notify()
    H.feed("<leader>dR")
    H.wait_for(function()
      return #cap.list > 0
    end, 10000, "the warning")
    cap.restore()
    H.eq("<leader>dR works from a Rust buffer", cap.list[1].msg)
    H.eq(vim.log.levels.WARN, cap.list[1].level)
  end)
end)

-- ------------------------------------------------------------------ item 11

describe("LazyVim keys of the enabled extras", function()
  before_each(function()
    H.open(H.fixture("standalone.rs"))
  end)

  local groups = {
    neotest = { "n", { "tt", "tr", "tT", "tl", "tw", "ts", "to", "tO", "tS", "ta", "td" } },
    dap = {
      "n",
      { "db", "dB", "dc", "dC", "da", "dg", "di", "dj", "dk", "dl", "do", "dO", "dP", "dr", "ds", "dt", "du", "dw", "de" },
    },
    overseer = { "n", { "oo", "ow", "ot" } },
    ["neo-tree"] = { "n", { "e", "E", "fe", "fE", "ge", "be" } },
    trouble = { "n", { "xx", "xX", "cs", "cS", "xL", "xQ", "xT" } },
    lazygit = { "n", { "gg", "gG", "gl", "gL", "gf", "gb", "gB" } },
    noice = { "n", { "snl", "snh", "sna", "snd" } },
    neogen = { "n", { "cn" } },
  }
  for name, g in pairs(groups) do
    it(name .. " keys are mapped: <leader>" .. table.concat(g[2], " "), function()
      if name == "lazygit" and vim.fn.executable("lazygit") ~= 1 then
        skip("lazygit is not installed (LazyVim only maps the keys when it is on PATH)")
      end
      local missing = {}
      for _, k in ipairs(g[2]) do
        if not next(md("<leader>" .. k, g[1])) then
          missing[#missing + 1] = "<leader>" .. k
        end
      end
      H.eq({}, missing)
    end)
  end

  it("<leader>gY (lazygit: open remote URL) is mapped (n)", function()
    H.ok(next(md("<leader>gY", "n")), "<leader>gY")
  end)

  it("mini-surround gsa gsd gsf gsF gsh gsr gsn are mapped", function()
    local missing = {}
    for _, k in ipairs({ "gsa", "gsd", "gsf", "gsF", "gsh", "gsr", "gsn" }) do
      if not next(md(k, "n")) then
        missing[#missing + 1] = k
      end
    end
    H.eq({}, missing)
  end)

  it("flash s S and todo-comments [t ]t are mapped", function()
    for _, lhs in ipairs({ "s", "S", "[t", "]t" }) do
      H.ok(next(md(lhs, "n")), lhs .. " not mapped")
    end
  end)

  it("inc-rename provides :IncRename (lazy command), <leader>cr is its buffer LSP map", function()
    H.eq(2, vim.fn.exists(":IncRename"))
    H.eq(0, md("<leader>cr", "n").buffer or 0, "<leader>cr is not a global map")
  end)

  it("kulala: <leader>R group, Rb and Rr exist in an .http buffer", function()
    local dir = H.tmpdir()
    vim.fn.writefile({ "GET https://example.invalid/ HTTP/1.1" }, dir .. "/r.http")
    H.open(dir .. "/r.http")
    H.eq("http", vim.bo.filetype)
    H.wait_for(function()
      return next(md("<leader>Rb", "n")) ~= nil
    end, 10000, "<leader>Rb in the http buffer")
    H.ok(next(md("<leader>Rr", "n")), "<leader>Rr")
    -- (the extra's empty "+Rest" stub shadowed which-key's trigger: off, which-key's spec names it)
    local m = md("<leader>R", "n")
    H.ok(not next(m) or (m.desc or ""):find("which-key-trigger", 1, true), "no stub mapping on <leader>R")
  end)
end)

describe("<leader>r outside Rust buffers", function()
  it("an unbound <leader>r<key> in Cargo.toml notifies instead of replacing a character (<Space>rv made `name` into `nvme`)", function()
    local dir = H.fixture("basic")
    H.open(dir .. "/Cargo.toml")
    local before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local l = vim.fn.search("^name", "cw")
    H.ok(l > 0)
    vim.api.nvim_win_set_cursor(0, { l, 0 })
    -- per-key stubs, no `<leader>r` leaf: a leaf blocking in getcharstr() made which-key skip its popup
    H.eq(0, next(md("<leader>r", "n")) and 1 or 0, "no <leader>r leaf mapping")
    H.eq("which_key_ignore", md("<leader>rv", "n").desc)
    H.eq("which_key_ignore", md("<leader>rv", "x").desc)
    H.eq("which_key_ignore", md("<leader>r/", "n").desc)
    local cap = H.capture_notify()
    H.feed("<leader>rv")
    H.feed("<leader>rr")
    cap.restore()
    H.eq(before, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    H.not_ok(vim.bo.modified)
    H.eq(2, #cap.list)
    H.match(cap.list[1].msg, "Rust buffers only", true)
    -- a visual-mode press: the selection is not touched either
    H.feed("v<leader>rv")
    H.eq(before, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    H.feed("<Esc>")
  end)

  it("in a Rust buffer an unbound <leader>r<key> says so (not 'Rust buffers only')", function()
    H.open(H.fixture("standalone.rs"))
    H.eq("rust", vim.bo.filetype)
    local before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local cap = H.capture_notify()
    H.feed("<leader>rz")
    cap.restore()
    H.eq(before, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    H.eq(1, #cap.list)
    H.match(cap.list[1].msg, "<leader>rz is not bound", true)
  end)
end)

-- ------------------------------------------------------------------ item 13

describe("colourscheme picker", function()
  it("<leader>uC is mapped and island-dark can be (re)applied without an error", function()
    H.open(H.fixture("standalone.rs"))
    H.ok(next(md("<leader>uC")), "<leader>uC not mapped")
    H.match(md("<leader>uC").desc or "", "olorscheme")
    H.has(vim.fn.getcompletion("", "color"), "island-dark")
    H.clear_messages()
    local ok, err = pcall(vim.cmd.colorscheme, "island-dark")
    H.ok(ok, tostring(err))
    H.eq("island-dark", vim.g.colors_name)
    H.eq("dark", vim.o.background)
    H.eq("", vim.trim(H.messages()))
  end)

  it("opening the picker on island-dark neither errors nor changes the scheme", function()
    if vim.env.XYNO_COV_OUT then
      -- the line hook makes the preview loads of the picker take 20+ minutes (nvim busy, never done)
      require("xynotest.harness").skip("under --coverage (the line hook makes the colourscheme previews take 20+ minutes)")
    end
    H.open(H.fixture("standalone.rs"))
    H.clear_messages()
    H.feed("<leader>uC")
    local picker = H.wait_for(function()
      return Snacks.picker.get()[1]
    end, 10000, "the colourscheme picker")
    -- move over the first entries: each move applies a preview
    H.wait_for(function()
      return #picker.list.items > 3
    end, 20000, "picker items")
    picker:action("list_down")
    vim.wait(300)
    picker:action("cancel")
    H.wait_for(function()
      return #Snacks.picker.get() == 0
    end, 30000, "the picker to close")
    H.eq("", vim.v.errmsg)
    H.no_match(H.messages(), "E%d+:")
    -- the restore after a cancel is asynchronous
    H.wait_for(function()
      return vim.g.colors_name == "island-dark"
    end, 30000, "island-dark restored after cancelling the picker")
  end)
end)

-- ------------------------------------------------------------------ item 14

describe("keymap uniqueness", function()
  local function modes_of(text)
    local mt = text:match("mode%s*=%s*(%b{})")
    local modes = {}
    if mt then
      for m in mt:gmatch('"(%a+)"') do
        modes[#modes + 1] = m
      end
    else
      modes[1] = text:match('mode%s*=%s*"(%a+)"') or "n"
    end
    return modes
  end

  --- Every keymap this repo defines, found in the sources:
  --- { file, scope, mode, lhs, desc, ft }.
  local function scan()
    local out = {}
    local files = vim.fn.globpath(H.repo .. "/lua", "**/*.lua", false, true)
    vim.list_extend(files, vim.fn.globpath(H.repo .. "/after", "**/*.lua", false, true))
    vim.list_extend(files, vim.fn.globpath(H.repo .. "/plugin", "**/*.lua", false, true))
    for _, f in ipairs(files) do
      local rel = f:sub(#H.repo + 2)
      local lines = vim.fn.readfile(f)
      local i = 1
      while i <= #lines do
        -- lazy keys: `{ "<lhs>", rhs, mode = .., desc = ".." }`, possibly over several lines
        local lhs = lines[i]:match('^%s*{%s*"(<[^"]+)"') or lines[i]:match('^%s*"(<[^"]+)",')
        if lhs and not lines[i]:find("keymap") then
          local acc, j = lines[i], i
          while not acc:find('desc%s*=%s*"') and j < i + 30 and j < #lines do
            j = j + 1
            acc = acc .. "\n" .. lines[j]
          end
          local desc = acc:match('desc%s*=%s*"([^"]+)"')
          if desc then
            for _, m in ipairs(modes_of(acc)) do
              out[#out + 1] = { file = rel, scope = "global", mode = m, lhs = lhs, desc = desc, ft = acc:find("ft%s*=") ~= nil }
            end
          end
        end
        i = i + 1
      end
      -- map(mode, lhs, rhs, desc) of the Rust attach block: buffer scope
      if rel == "lua/config/keymaps.lua" then
        local text = table.concat(lines, "\n")
        for modespec, lhs in text:gmatch('map%(%s*(%b{}),%s*"([^"]+)"') do
          for m in modespec:gmatch('"(%a+)"') do
            out[#out + 1] = { file = rel, scope = "buffer", mode = m, lhs = lhs, desc = "(rust attach)" }
          end
        end
        for m, lhs in text:gmatch('map%(%s*"(%a+)",%s*"([^"]+)"') do
          out[#out + 1] = { file = rel, scope = "buffer", mode = m, lhs = lhs, desc = "(rust attach)" }
        end
      end
    end
    return out
  end

  it("no (scope, mode, lhs) is defined twice in the repo's sources", function()
    local seen, dup = {}, {}
    for _, e in ipairs(scan()) do
      local key = ("%s %s %s"):format(e.scope, e.mode, e.lhs)
      if seen[key] then
        dup[#dup + 1] = ("%s: %s (%s and %s)"):format(key, e.desc, seen[key].file, e.file)
      end
      seen[key] = e
    end
    H.eq({}, dup)
  end)

  it("every global lazy key of this repo is live with the desc its source gives (nothing overrides it)", function()
    H.open(H.fixture("standalone.rs"))
    local mine = {}
    for _, f in ipairs({ "diffview", "coverage", "ninety-nine", "harpoon", "navigation", "dap" }) do
      mine["lua/plugins/" .. f .. ".lua"] = true
    end
    local n, bad = 0, {}
    for _, e in ipairs(scan()) do
      if e.scope == "global" and not e.ft and mine[e.file] then
        local m = md(e.lhs, e.mode)
        n = n + 1
        if (m.desc or "") ~= e.desc then
          bad[#bad + 1] = ("%s %s: source %q, live %q"):format(e.mode, e.lhs, e.desc, m.desc)
        end
      end
    end
    H.ok(n >= 25, "scanned only " .. n .. " keys")
    H.eq({}, bad)
  end)
end)

-- ------------------------------------------------------------------ Rust buffers

describe("keys in a Rust buffer", function()
  local buf

  before_each(function()
    if vim.env.XYNO_COV_OUT then
      -- with the line hook an attaching rust-analyzer left nvim busy for 20+ minutes (never done)
      require("xynotest.harness").skip("under --coverage (hang with the line hook while rust-analyzer attaches; keymaps-rust covers the same code)")
    end
    H.need_rust()
    _, buf = H.open_fixture("basic", "src/lib.rs")
    H.wait_lsp("rust-analyzer", buf)
  end)

  --- the buffer-local map of the current buffer (nil when global/absent)
  local function bmap(lhs, mode)
    local m = md(lhs, mode)
    if next(m) and m.buffer == 1 then
      return m
    end
  end

  it("<leader>cR becomes LazyVim's 'Rename File' as a buffer map after rust-analyzer attaches", function()
    local m = H.wait_for(function()
      return bmap("<leader>cR", "n")
    end, 15000, "buffer-local <leader>cR")
    H.eq("Rename File", m.desc)
    H.ok(m.callback, "callback")
  end)

  it("<leader>r* maps are buffer-local and the <leader>r group is named 'rust'", function()
    H.wait_for(function()
      return bmap("<leader>ra", "n")
    end, 15000, "<leader>ra")
    H.eq("Refactor actions", bmap("<leader>ra", "n").desc)
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      -- the only global ones are the hidden "not bound" stubs
      if (m.lhs:match("^ r%a") or m.lhs:match("^<Space>r%a")) and m.desc ~= "which_key_ignore" then
        error("global <leader>r* map " .. m.lhs .. " is not a stub")
      end
    end
  end)

  it("inc-rename's <leader>cr is a buffer map once the LSP is attached", function()
    local m = H.wait_for(function()
      return bmap("<leader>cr", "n")
    end, 15000, "buffer-local <leader>cr")
    H.eq("Rename (inc-rename.nvim)", m.desc)
  end)

  it("<leader>dr is rustaceanvim's 'Rust Debuggables' here (shadows the REPL toggle)", function()
    local m = H.wait_for(function()
      return bmap("<leader>dr", "n")
    end, 15000, "buffer-local <leader>dr")
    H.match(m.desc or "", "Rust Debuggables", true)
    -- the global one is the dap REPL toggle
    local g
    for _, k in ipairs(vim.api.nvim_get_keymap("n")) do
      if k.lhs == " dr" or k.lhs == "<Space>dr" then
        g = k
      end
    end
    H.ok(g, "global <leader>dr")
    H.eq("Toggle REPL", g.desc)
  end)

  it("insert-mode ' is the unpaired quote here, <C-S> is LazyVim's save", function()
    local q = md("'", "i")
    H.eq(1, q.buffer)
    H.eq("Quote (no pairing: lifetimes)", q.desc)
    H.eq("'", q.rhs)
    local s = md("<C-S>", "i")
    H.ok(next(s), "<C-S> in insert mode")
    H.match(lower(s.desc), "save")
  end)

  it("typing a ' in insert mode inserts one quote only (no mini.pairs closer)", function()
    vim.cmd("normal! G")
    vim.cmd("normal! o")
    H.feed("i&'", "x")
    vim.cmd("stopinsert")
    H.eq("&'", vim.api.nvim_get_current_line())
  end)

  it("which-key health reports no duplicate/overlap for <leader>r* (env dependent)", function()
    H.wait_for(function()
      return bmap("<leader>ra", "n")
    end, 15000, "<leader>ra")
    vim.cmd("checkhealth which-key")
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local text = table.concat(lines, "\n")
    H.match(text, "which%-key")
    local bad = {}
    for _, l in ipairs(lines) do
      if (l:find("ERROR", 1, true) or l:find("WARNING", 1, true)) and l:find("<[Ll]eader>r", 1, true) then
        bad[#bad + 1] = l
      end
    end
    vim.cmd("silent! bwipeout!")
    H.eq({}, bad)
  end)

  it("README claim 'gc vs gcc/gco/gcO overlaps' not reproduced: recorded only (informational)", function()
    vim.cmd("checkhealth which-key")
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local hits = {}
    for _, l in ipairs(lines) do
      if l:find("gc", 1, true) and (l:lower():find("overlap", 1, true) or l:lower():find("duplicate", 1, true)) then
        hits[#hits + 1] = vim.trim(l)
      end
    end
    vim.cmd("silent! bwipeout!")
    -- informational: record, do not fail (the claim itself is "not reproduced")
    io.stdout:write(("INFO gc overlap lines in :checkhealth which-key: %d%s\n"):format(#hits, #hits > 0 and (" " .. vim.inspect(hits)) or ""))
    H.ok(true)
  end)
end)

describe("keys in a non-Rust buffer", function()
  local function open_lua()
    local dir = H.tmpdir()
    vim.fn.writefile({ "local x = 1" }, dir .. "/a.lua")
    H.open(dir .. "/a.lua")
    H.eq("lua", vim.bo.filetype)
  end

  it("<leader>cR is LazyVim's own (or absent), never the repo's Rust buffer map", function()
    open_lua()
    local m = md("<leader>cR", "n")
    -- LazyVim maps 'Rename File' per buffer once an LSP supporting file rename
    -- attaches; without one there is no map at all. Either way not the Rust one.
    if next(m) then
      H.eq("Rename File", m.desc)
    end
    H.not_ok(next(m) and m.desc and m.desc:find("ust"), "Rust code action map in a Lua buffer")
  end)

  it("<leader>dr is the dap 'Toggle REPL' here", function()
    open_lua()
    local m = md("<leader>dr", "n")
    H.eq(0, m.buffer)
    H.eq("Toggle REPL", m.desc)
  end)

  it("insert-mode ' is not remapped (Rust buffers only) and <C-S> is the save map", function()
    open_lua()
    local q = md("'", "i")
    H.not_ok(next(q) and q.desc == "Quote (no pairing: lifetimes)", "the Rust ' map leaked into a Lua buffer")
    local s = md("<C-S>", "i")
    H.ok(next(s), "<C-S> in insert mode")
    H.eq(0, s.buffer)
    H.match(lower(s.desc), "save")
  end)
end)
