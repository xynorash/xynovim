-- Startup, options, lazy.nvim setup, lockfile, extras and the small plugin
-- spec files (news, scrolling, telescope, ghost text, gitsigns, codelens,
-- harpoon, navigation) plus config/remote_clipboard.lua.
--
-- Facts about a FRESH startup (what is loaded, which messages appeared) come
-- from child nvim processes (`child()`), because the runner's own editor is
-- changed by the earlier tests. Everything else runs in the runner's nvim.
-- xyno-os: linux (reads /proc, uses sh stubs for wl-copy, wl-paste)
local H = require("xynotest.helpers")

local repo = H.repo
local Config = require("lazy.core.config")

-- ------------------------------------------------------------------ helpers

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function write(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

local function json(path)
  return vim.json.decode(read(path))
end

--- Set of the keys of a list.
local function set(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

--- Run a headless child nvim with the full config. `body` is Lua run after
--- VimEnter (+ a short wait for the config's own scheduled work); it returns a
--- table that is printed as JSON between markers. opts: env, clear_env, args,
--- cmd (executable). Returns decoded result, raw vim.system result, wall ms.
local function child(body, opts)
  opts = opts or {}
  local dir = H.tmpdir()
  local script = dir .. "/child.lua"
  write(
    script,
    ([[
vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = function()
  vim.defer_fn(function()
    local ok, res = xpcall(function() %s end, debug.traceback)
    io.stdout:write("\nXYNO_JSON " .. vim.json.encode({ ok = ok, res = res }) .. "\n")
    vim.cmd("qa!")
  end, 300)
end })
]]):format(body)
  )
  local cmd = { opts.cmd or vim.fn.exepath("nvim"), "--headless" }
  vim.list_extend(cmd, opts.args or {})
  vim.list_extend(cmd, { "-S", script })
  local t0 = vim.uv.hrtime()
  local r = vim.system(cmd, { text = true, env = opts.env, clear_env = opts.clear_env, cwd = dir }):wait(60000)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  local line = ((r.stdout or "") .. (r.stderr or "")):match("XYNO_JSON (%b{})")
  if not line then
    error(("child nvim printed no result (exit %s)\nstdout: %s\nstderr: %s"):format(r.code, r.stdout, r.stderr), 2)
  end
  local out = vim.json.decode(line)
  if not out.ok then
    error("child script failed: " .. tostring(out.res), 2)
  end
  return out.res, r, ms
end

local MESSAGES = [[
  return {
    messages = vim.api.nvim_exec2("messages", { output = true }).output,
    errmsg = vim.v.errmsg,
  }
]]

local function xdg_env()
  local env = {}
  for _, k in ipairs({ "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "TMPDIR" }) do
    env[k] = vim.env[k]
  end
  return env
end

-- Facts of one fresh startup, computed once.
local probe_cache
local function probe()
  if not probe_cache then
    probe_cache = child([[
      local function map(lhs)
        local m = vim.fn.maparg(lhs, "n", false, true)
        if vim.tbl_isempty(m) then return vim.NIL end
        return { desc = m.desc, rhs = m.rhs, buffer = m.buffer }
      end
      local s = require("lazy").stats()
      return {
        messages = vim.api.nvim_exec2("messages", { output = true }).output,
        errmsg = vim.v.errmsg,
        notifs = #require("lazy.core.config").spec.notifs,
        count = s.count, loaded = s.loaded,
        leader = vim.g.mapleader,
        manage = package.loaded["lazy.manage"] ~= nil,
        checker = package.loaded["lazy.manage.checker"] ~= nil,
        telescope = package.loaded["telescope"] ~= nil,
        harpoon = package.loaded["harpoon"] ~= nil,
        harpoon_plugin_loaded = require("lazy.core.config").plugins.harpoon._.loaded ~= nil,
        telescope_plugin_loaded = require("lazy.core.config").plugins["telescope.nvim"]._.loaded ~= nil,
        maps = {
          H = map("<Space>H"), ce = map("<C-e>"), m1 = map("<M-1>"), m2 = map("<M-2>"),
          m3 = map("<M-3>"), m4 = map("<M-4>"), a = map("<Space>a"),
          cI = map("<Space>cI"), cO = map("<Space>cO"), cj = map("<Space>cj"),
        },
        loaded_vars = {
          gzip = vim.g.loaded_gzip, tarPlugin = vim.g.loaded_tarPlugin, tohtml = vim.g.loaded_2html_plugin,
          tutor = vim.g.loaded_tutor_mode_plugin, zipPlugin = vim.g.loaded_zipPlugin,
          matchparen = vim.g.loaded_matchparen, netrwPlugin = vim.g.loaded_netrwPlugin,
        },
        groups = (function()
          local g = {}
          for _, n in ipairs({ "gzip", "tar", "zip", "matchparen" }) do
            g[n] = pcall(vim.api.nvim_get_autocmds, { group = n })
          end
          return g
        end)(),
        cmds = {
          DoMatchParen = vim.fn.exists(":DoMatchParen") == 2,
          Explore = vim.fn.exists(":Explore") == 2,
          Tutor = vim.fn.exists(":Tutor") == 2,
          TOhtml = vim.fn.exists(":TOhtml") == 2,
        },
      }
    ]])
  end
  return probe_cache
end

-- ------------------------------------------------------------ 1 - 4 startup

describe("init.lua", function()
  it("only requires config.lazy", function()
    local code = {}
    for line in read(repo .. "/init.lua"):gmatch("[^\n]+") do
      if not line:match("^%s*%-%-") and line:match("%S") then
        code[#code + 1] = vim.trim(line)
      end
    end
    H.eq({ 'require("config.lazy")' }, code)
  end)
end)

describe("fresh headless startup", function()
  it("prints no messages, leaves v:errmsg empty and has no lazy spec notifications", function()
    local p = probe()
    H.eq("", vim.trim(p.messages))
    H.eq("", p.errmsg)
    H.eq(0, p.notifs)
    -- the runner's own editor agrees
    H.eq({}, Config.spec.notifs)
  end)

  it("is well under 3000 ms (--startuptime and wall clock)", function()
    local log = H.tmpdir() .. "/startup.log"
    local _, _, ms = child("return {}", { args = { "--startuptime", log } })
    local last = vim.trim(read(log)):match("([^\n]+)$")
    local stamp = tonumber(last:match("^%s*(%d+%.%d+)"))
    H.ok(stamp, "no timestamp in the last startuptime line: " .. last)
    H.match(last, "NVIM STARTED", true)
    -- the child also waits 300 ms in its script before quitting
    H.ok(stamp < 3000, ("--startuptime reports %.1f ms"):format(stamp))
    H.ok(ms < 6000, ("child wall clock %.0f ms (includes 300 ms wait and nvim exit)"):format(ms))
  end)

  it("loads only a handful of plugins at startup", function()
    local p = probe()
    -- README: "~5 of 80 plugins loaded". DISCREPANCY recorded: lazy.stats().count is
    -- the number of plugins in the spec (61 on this machine, equal to the
    -- lockfile), not 80 as the README says.
    H.ok(p.loaded >= 1 and p.loaded <= 20, "loaded " .. p.loaded)
    H.ok(p.loaded < p.count / 2, ("loaded %d of %d"):format(p.loaded, p.count))
  end)

  it("has more than 50 plugins and <Space> as the leader", function()
    local p = probe()
    H.ok(p.count > 50, "count " .. p.count)
    H.eq(" ", p.leader)
    H.eq(" ", vim.g.mapleader)
  end)
end)

-- ------------------------------------------------------------- 5 - 9 lazy.lua

describe("PATH", function()
  it("~/.cargo/bin is appended when a non-login start lacks it (rust-analyzer not found)", function()
    local cargo_bin = vim.uv.os_homedir() .. "/.cargo/bin"
    if vim.fn.isdirectory(cargo_bin) == 0 then
      return require("xynotest.harness").skip("no ~/.cargo/bin on this machine")
    end
    local env = xdg_env()
    env.PATH = "/usr/bin:/bin"
    local res = child("return { path = vim.env.PATH }", { env = env })
    H.eq("/usr/bin:/bin:" .. cargo_bin, res.path)
    env.PATH = cargo_bin .. ":/usr/bin"
    H.eq(cargo_bin .. ":/usr/bin", child("return { path = vim.env.PATH }", { env = env }).path, "not added twice")
  end)
end)

describe("config/lazy.lua", function()
  pending(
    "clones lazy.nvim with --filter=blob:none --branch=stable when missing, 'Failed to clone lazy.nvim' + exit 1 on failure",
    "needs network (or a faked git on PATH) and an empty stdpath('data'): not testable offline without touching the shared data dir"
  )

  it("bootstrap code targets stdpath('data')/lazy/lazy.nvim with a blobless stable clone", function()
    -- static check of the part that cannot run here
    local src = read(repo .. "/lua/config/lazy.lua")
    H.match(src, 'vim.fn.stdpath("data") .. "/lazy/lazy.nvim"', true)
    H.match(src, '"clone", "--filter=blob:none", "--branch=stable"', true)
    H.match(src, "Failed to clone lazy.nvim", true)
    H.match(src, "os.exit(1)", true)
    -- and the running instance really has lazy.nvim there on the rtp
    H.has(vim.opt.rtp:get(), vim.fn.stdpath("data") .. "/lazy/lazy.nvim")
  end)

  it("uses LazyVim + import lazyvim.plugins and import plugins as the spec", function()
    H.eq({
      { "LazyVim/LazyVim", import = "lazyvim.plugins" },
      { import = "plugins" },
    }, Config.options.spec)
  end)

  it("defaults: lazy = false, version = false", function()
    H.eq(false, Config.options.defaults.lazy)
    H.eq(false, Config.options.defaults.version)
  end)

  it("install.colorscheme = island-dark, tokyonight, habamax", function()
    -- lazy.nvim itself appends "habamax" to the configured list
    local cs = Config.options.install.colorscheme
    H.eq({ "island-dark", "tokyonight", "habamax" }, { cs[1], cs[2], cs[3] })
  end)

  it("rocks are disabled and :checkhealth lazy has no luarocks error", function()
    H.eq(false, Config.options.rocks.enabled)
    local r = child([[
      vim.cmd("checkhealth lazy")
      return { lines = vim.api.nvim_buf_get_lines(0, 0, -1, false) }
    ]])
    local text = table.concat(r.lines, "\n")
    H.match(text, "lazy", true)
    for _, l in ipairs(r.lines) do
      if l:find("ERROR", 1, true) then
        H.no_match(l:lower(), "luarocks", true, "luarocks reported as an error")
        H.no_match(l:lower(), "hererocks", true, "hererocks reported as an error")
      end
    end
  end)

  it("the update checker is off and never started at startup", function()
    H.eq(false, Config.options.checker.enabled)
    H.eq(false, Config.options.checker.notify)
    H.eq(false, probe().checker, "lazy.manage.checker is loaded")
  end)

  -- The brief (and the README) say package.loaded["lazy.manage"] is nil at
  -- startup. It is not: lazy.view.commands (required unconditionally by
  -- lazy.core.config.setup) indexes a lazy_require proxy of lazy.manage, so
  -- lazy.nvim itself loads it whatever `checker` says. Not a config bug; the
  -- observable effect of checker.enabled=false is that lazy.manage.checker
  -- stays unloaded (test above).
  it("lazy.manage is loaded by lazy.nvim's own command setup, not by the checker", function()
    H.eq(true, probe().manage)
  end)

  it("an unwritable XDG_CACHE_HOME turns lazy's module cache off instead of aborting init.lua (E739)", function()
    local env = xdg_env()
    env.XDG_CACHE_HOME = "/proc/xyno-unwritable-cache"
    local r = child([[
      return {
        cache = require("lazy.core.config").options.performance.cache.enabled,
        lazyvim = package.loaded["lazyvim.config"] ~= nil,
        messages = vim.api.nvim_exec2("messages", { output = true }).output,
      }
    ]], { env = env })
    H.eq(false, r.cache)
    H.eq(true, r.lazyvim, "LazyVim was set up")
    H.no_match(r.messages, "E739", true)
  end)

  it("with a writable cache dir the module cache stays on", function()
    H.eq(true, Config.options.performance.cache.enabled)
  end)

  it("disables exactly gzip, tarPlugin, tohtml, tutor, zipPlugin of the rtp plugins", function()
    local disabled = Config.options.performance.rtp.disabled_plugins
    table.sort(disabled)
    H.eq({ "gzip", "tarPlugin", "tohtml", "tutor", "zipPlugin" }, disabled)
    local s = set(disabled)
    for _, keep in ipairs({ "matchit", "matchparen", "netrwPlugin" }) do
      H.not_ok(s[keep], keep .. " must stay enabled")
    end
  end)

  it("the disabled runtime plugins did not run; matchparen and netrw did", function()
    local p = probe()
    -- (the brief expected g:loaded_gzip etc. to be SET; it is the other way
    -- round: lazy removes the plugin from the runtime path, so its script never
    -- runs and never sets its own g:loaded_ guard)
    H.is_nil(p.loaded_vars.gzip)
    H.is_nil(p.loaded_vars.tarPlugin)
    H.is_nil(p.loaded_vars.zipPlugin)
    for _, g in ipairs({ "gzip", "tar", "zip" }) do
      H.not_ok(p.groups[g], "augroup " .. g .. " exists: the plugin ran")
    end
    H.not_ok(p.cmds.TOhtml, ":TOhtml must not exist")
    H.not_ok(p.cmds.Tutor, ":Tutor must not exist")
    -- the not-disabled plugins were sourced (they define their own commands);
    -- note matchparen.vim itself sets g:loaded_matchparen = 1, so "unset" is
    -- not what an enabled matchparen looks like
    H.ok(p.cmds.DoMatchParen, ":DoMatchParen missing: matchparen was disabled")
    H.eq(1, p.loaded_vars.matchparen)
    H.ok(p.groups.matchparen, "matchparen augroup missing")
    H.ok(p.cmds.Explore, ":Explore missing: netrw was disabled")
    H.ok(p.loaded_vars.netrwPlugin, "g:loaded_netrwPlugin unset: netrw did not run")
  end)
end)

-- ------------------------------------------------------------ 10 - 13 options

describe("config/options.lua (field-test fixes)", function()
  it("hides nextest's progress bar (neotest's pty output) and keeps the navic breadcrumb", function()
    H.eq("1", vim.env.NEXTEST_HIDE_PROGRESS_BAR)
    H.eq(false, vim.g.trouble_lualine)
  end)

  it("the lualine config has navic's breadcrumb and no Trouble symbols component", function()
    H.very_lazy()
    local c = require("lualine").get_config().sections.lualine_c
    local has_navic, has_trouble = false, false
    for _, item in ipairs(c) do
      if type(item) == "table" and item[1] == "navic" then
        has_navic = true
      end
      if type(item) == "table" and type(item[1]) == "function" then
        has_trouble = has_trouble or (item.cond ~= nil and tostring(item.cond):find("trouble", 1, true) ~= nil)
      end
    end
    H.ok(has_navic, "navic component in lualine_c: " .. vim.inspect(c))
    H.not_ok(has_trouble)
  end)

  it("diagnostics update while typing (update_in_insert)", function()
    H.very_lazy()
    require("lazy").load({ plugins = { "nvim-lspconfig" } })
    H.eq(true, vim.diagnostic.config().update_in_insert)
  end)
end)

describe("config/options.lua", function()
  it("relativenumber off, autoformat off, rounded borders, pumblend 0", function()
    H.eq(false, vim.o.relativenumber)
    H.eq(false, vim.g.autoformat)
    H.eq("rounded", vim.o.winborder)
    H.eq(0, vim.o.pumblend)
  end)

  it("skips the python3, ruby, perl and node providers", function()
    for _, p in ipairs({ "python3", "ruby", "perl", "node" }) do
      H.eq(0, vim.g["loaded_" .. p .. "_provider"], p)
    end
  end)

  it("selects bacon-ls for Rust diagnostics, and the rust extra turns rust-analyzer's checkOnSave off", function()
    H.eq("bacon-ls", vim.g.lazyvim_rust_diagnostics)
    -- observable effect: the lang.rust extra reads the variable
    local src = read(Config.plugins.LazyVim.dir .. "/lua/lazyvim/plugins/extras/lang/rust.lua")
    H.match(src, "lazyvim_rust_diagnostics", true)
    local plugin = Config.plugins.rustaceanvim
    H.ok(plugin, "rustaceanvim is not in the spec")
    local opts = require("lazy.core.plugin").values(plugin, "opts", false)
    local ra = vim.tbl_get(opts, "server", "default_settings", "rust-analyzer") or {}
    -- rustaceanvim.lua sets its own server settings through opts; the extra
    -- computes checkOnSave when bacon-ls is selected
    local cfg = vim.g.rustaceanvim
    if type(cfg) == "function" then
      cfg = cfg()
    end
    local settings = vim.tbl_get(cfg or {}, "server", "default_settings", "rust-analyzer")
      or ra
    H.ok(settings and next(settings), "no rust-analyzer default_settings visible")
    H.eq(false, settings.checkOnSave)
  end)

  it("sets up every config module: augroups and user commands exist", function()
    for _, g in ipairs({
      "xynovim_local_history",
      "xynovim_disk_guard",
      "xynovim_lsp_status",
      "xynovim_rust_restart",
      "xynovim_ux",
    }) do
      local ok, acs = pcall(vim.api.nvim_get_autocmds, { group = g })
      H.ok(ok and #acs > 0, "augroup " .. g .. " missing or empty")
    end
    local cmds = vim.api.nvim_get_commands({})
    for _, c in ipairs({
      "RustContext",
      "RustTargets",
      "RustTools",
      "ActJob",
      "RustNew",
      "RustRoutes",
      "RustRestart",
      "LocalHistory",
      "LocalHistoryPrune",
      "LocalHistoryRestore",
      "ColorblindDiagnostics",
    }) do
      H.ok(cmds[c], "user command :" .. c .. " missing")
    end
  end)
end)

describe("after/ftplugin/http.lua", function()
  it("conceallevel is 0 in an http buffer (JSON quotes stay visible), LazyVim's 2 elsewhere", function()
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(other)
    vim.bo[other].filetype = "lua"
    H.eq(2, vim.wo.conceallevel)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "http"
    H.eq(0, vim.wo.conceallevel)
  end)
end)

describe("config/autocmds.lua", function()
  it("is comments only and defines no autocmds", function()
    local path = repo .. "/lua/config/autocmds.lua"
    for l in read(path):gmatch("[^\n]+") do
      H.ok(not l:match("%S") or l:match("^%s*%-%-"), "non-comment line: " .. l)
    end
    local before = #vim.api.nvim_get_autocmds({})
    local groups_before = vim.api.nvim_exec2("augroup", { output = true }).output
    dofile(path)
    H.eq(before, #vim.api.nvim_get_autocmds({}))
    H.eq(groups_before, vim.api.nvim_exec2("augroup", { output = true }).output)
  end)
end)

-- ------------------------------------------------------- 15 - 18 json files

describe("lazyvim.json", function()
  local expected = {
    "ai.claudecode",
    "coding.mini-surround",
    "coding.neogen",
    "dap.core",
    "editor.inc-rename",
    "editor.navic",
    "editor.neo-tree",
    "editor.overseer",
    "lang.git",
    "lang.json",
    "lang.markdown",
    "lang.rust",
    "lang.toml",
    "lang.yaml",
    "test.core",
    "ui.treesitter-context",
    "util.rest",
  }
  local prefix = "lazyvim.plugins.extras."

  local function extras()
    local ok, data = pcall(json, repo .. "/lazyvim.json")
    H.ok(ok, "lazyvim.json is not valid JSON: " .. tostring(data))
    return data
  end

  it("lists exactly the 17 extras, version 8, install_version 8", function()
    local d = extras()
    H.eq(8, d.version)
    H.eq(8, d.install_version)
    local names = {}
    for _, e in ipairs(d.extras) do
      H.eq(prefix, e:sub(1, #prefix), e)
      names[#names + 1] = e:sub(#prefix + 1)
    end
    table.sort(names)
    H.eq(17, #names)
    H.eq(expected, names)
  end)

  it("matches the README 'LazyVim extras enabled' list", function()
    local line = H.docs_text():match("LazyVim extras enabled[^\n]*")
    H.ok(line, "README line not found")
    local readme = {}
    for name in line:gmatch("`([%w%.%-]+)`") do
      if name ~= "lazyvim.json" then
        readme[#readme + 1] = name
      end
    end
    table.sort(readme)
    H.eq(expected, readme)
  end)

  it("every extra module exists in the installed LazyVim and is requirable", function()
    for _, e in ipairs(extras().extras) do
      local ok, mod = pcall(require, e)
      H.ok(ok, e .. ": " .. tostring(mod))
      H.eq("table", type(mod), e)
    end
  end)
end)

describe("lazy-lock.json", function()
  local lock = json(repo .. "/lazy-lock.json")
  local names = vim.tbl_keys(lock)
  table.sort(names)

  it("is valid JSON and every entry has a branch and a 40-hex commit", function()
    -- the task brief said 63 entries; the file has 61 (= lazy.stats().count)
    H.ok(#names >= 55, "entries: " .. #names)
    for _, n in ipairs(names) do
      H.eq("string", type(lock[n].branch), n .. " branch")
      H.match(tostring(lock[n].commit), "^%x+$", false, n .. " commit")
      H.eq(40, #lock[n].commit, n .. " commit length")
    end
  end)

  it("pins kulala.nvim at v5.3.4 and keeps tokyonight and catppuccin", function()
    H.eq("6656c9d332735ca6a27725e0fb45a1715c4372d9", lock["kulala.nvim"].commit)
    H.ok(lock["tokyonight.nvim"], "tokyonight.nvim")
    H.ok(lock["catppuccin"], "catppuccin")
  end)

  it("has no Omarchy-only theme plugins", function()
    for _, n in ipairs(names) do
      local l = n:lower()
      for _, bad in ipairs({
        "monokai",
        "omarchy",
        "gruvbox",
        "rose-pine",
        "kanagawa",
        "everforest",
        "nord",
        "flexoki",
        "osaka",
        "ristretto",
        "hackerman",
        "matte",
        "ethereal",
        "vantablack",
        "white",
        "miasma",
      }) do
        H.no_match(l, bad, true, "theme plugin in lockfile: " .. n)
      end
    end
  end)

  it("has no entry that is absent from the plugin spec, and covers the whole spec", function()
    for _, n in ipairs(names) do
      H.ok(Config.plugins[n], "lockfile entry not in the spec: " .. n)
    end
    local spec = 0
    for _, p in pairs(Config.plugins) do
      if not p._.is_local and not p.dev then
        spec = spec + 1
      end
    end
    H.eq(spec, #names, "spec plugins vs lockfile entries")
  end)

  it("every locked plugin is installed with its git HEAD at the pinned commit", function()
    local dir = vim.fn.stdpath("data") .. "/lazy"
    local bad = {}
    for _, n in ipairs(names) do
      local plugin_dir = (Config.plugins[n] and Config.plugins[n].dir) or (dir .. "/" .. n)
      if vim.fn.isdirectory(plugin_dir) ~= 1 then
        bad[#bad + 1] = n .. ": not installed"
      else
        local r = vim.system({ "git", "-C", plugin_dir, "rev-parse", "HEAD" }, { text = true }):wait(10000)
        if vim.trim(r.stdout or "") ~= lock[n].commit then
          bad[#bad + 1] = ("%s: HEAD %s, pinned %s"):format(n, vim.trim(r.stdout or "?"), lock[n].commit)
        end
      end
    end
    H.eq({}, bad)
    -- kulala sits exactly on its tag
    local r = vim.system({ "git", "-C", dir .. "/kulala.nvim", "describe", "--tags", "--exact-match" }, { text = true })
      :wait(10000)
    H.eq("v5.3.4", vim.trim(r.stdout or ""))
  end)
end)

-- --------------------------------------------------------- 19 - 29 plugin files

local function opts_of(name)
  local plugin = H.ok(Config.plugins[name], name .. " not in the spec")
  return require("lazy.core.plugin").values(plugin, "opts", false), plugin
end

describe("plugins/disable-news-alert.lua", function()
  it("turns both LazyVim news checks off", function()
    local o = opts_of("LazyVim")
    H.eq(false, o.news.lazyvim)
    H.eq(false, o.news.neovim)
    -- the merged options LazyVim.config was set up with
    H.eq(false, require("lazyvim.config").news.lazyvim)
    H.eq(false, require("lazyvim.config").news.neovim)
  end)
end)

describe("plugins/snacks-animated-scrolling-off.lua", function()
  it("disables snacks scrolling and keeps the <leader>uS toggle", function()
    H.eq(false, opts_of("snacks.nvim").scroll.enabled)
    H.eq(false, Snacks.config.scroll.enabled)
    H.open(H.fixture("standalone.rs"))
    local m = vim.fn.maparg(" uS", "n", false, true)
    H.ok(not vim.tbl_isempty(m), "<leader>uS is not mapped")
    H.match(m.desc or "", "croll")
  end)
end)

describe("plugins/telescope.lua", function()
  it("is lazy and not loaded at startup", function()
    local _, plugin = opts_of("telescope.nvim")
    H.eq(true, plugin.lazy)
    local p = probe()
    H.eq(false, p.telescope, "package.loaded.telescope")
    H.eq(false, p.telescope_plugin_loaded, "lazy marks it loaded")
  end)
end)

describe("plugins/no-ghost-text.lua", function()
  it("sets ghost_text off for the completion menu and the cmdline in the opts", function()
    local o = opts_of("blink.cmp")
    H.eq(false, o.completion.ghost_text.enabled)
    H.eq(false, o.cmdline.completion.ghost_text.enabled)
  end)

  it("the loaded blink.cmp config has ghost text off", function()
    require("lazy").load({ plugins = { "blink.cmp" } })
    local c = require("blink.cmp.config")
    -- blink turns settings that also exist under `cmdline` into per-mode
    -- functions, so call it (we are in normal mode)
    local function val(e)
      if type(e) == "function" then
        return e()
      end
      return e
    end
    H.eq(false, val(c.completion.ghost_text.enabled))
    H.eq(false, val(c.cmdline.completion.ghost_text.enabled))
  end)
end)

describe("plugins/gitsigns.lua", function()
  it("attach_to_untracked is on, and an untracked file in a repo without commits gets signs", function()
    H.eq(true, opts_of("gitsigns.nvim").attach_to_untracked)
    local dir = H.tmpdir()
    H.git(dir, "init", "-q", "-b", "main")
    write(dir .. "/new.txt", "one\ntwo\nthree\n")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/new.txt")
    local st = H.wait_for(function()
      local s = vim.b[buf].gitsigns_status_dict
      return s and s.head and s or nil
    end, 15000, "gitsigns to attach to the untracked file")
    H.ok(st, "no status dict")
    H.wait_for(function()
      local hunks = require("gitsigns").get_hunks(buf)
      return hunks and #hunks > 0
    end, 10000, "gitsigns hunks for the untracked file")
    local hunks = require("gitsigns").get_hunks(buf)
    H.eq("add", hunks[1].type)
    H.eq(3, hunks[1].added.count)
  end)
end)

describe("plugins/codelens.lua", function()
  it("enables LazyVim's codelens option", function()
    H.eq(true, opts_of("nvim-lspconfig").codelens.enabled)
  end)

  it("maps <leader>cc and <leader>cC buffer-locally in a buffer with a codelens-capable LSP client", function()
    local dir = H.tmpdir()
    write(dir .. "/a.txt", "hello\n")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    local buf = H.open(dir .. "/a.txt")
    for _, lhs in ipairs({ " cc", " cC" }) do
      H.eq(0, vim.fn.maparg(lhs, "n", false, true).buffer or 0, lhs .. " is mapped before an LSP attaches")
    end
    -- an in-process fake server that only advertises codeLens
    local function fake(dispatchers)
      local closed = false
      return {
        request = function(method, _, callback)
          if method == "initialize" then
            callback(nil, { capabilities = { codeLensProvider = { resolveProvider = false } } })
          elseif method == "textDocument/codeLens" then
            callback(nil, {})
          else
            callback(nil, vim.NIL)
          end
          return true, 1
        end,
        notify = function()
          return true
        end,
        is_closing = function()
          return closed
        end,
        terminate = function()
          closed = true
        end,
      }
    end
    local id = vim.lsp.start({ name = "xyno-fake-codelens", cmd = fake, root_dir = dir }, { bufnr = buf })
    H.ok(id, "fake LSP client did not start")
    H.wait_for(function()
      return #H.clients(buf, "xyno-fake-codelens") > 0
    end, 10000, "fake client attach")
    local cc = H.wait_for(function()
      local m = vim.fn.maparg(" cc", "n", false, true)
      return m.buffer == 1 and m or nil
    end, 5000, "<leader>cc buffer-local mapping")
    local cC = vim.fn.maparg(" cC", "n", false, true)
    H.eq(1, cC.buffer, "<leader>cC buffer-local")
    H.match(cc.desc, "Run Codelens", true)
    H.match(cC.desc, "Refresh & Display Codelens", true)
    for _, c in ipairs(H.clients(buf, "xyno-fake-codelens")) do
      c:stop(true)
    end
  end)
end)

describe("plugins/harpoon.lua", function()
  it("uses branch harpoon2", function()
    H.eq("harpoon2", Config.plugins.harpoon.branch)
  end)

  it("registers its lazy keys globally while harpoon is not loaded at startup", function()
    local p = probe()
    H.eq(false, p.harpoon, "package.loaded.harpoon")
    H.eq(false, p.harpoon_plugin_loaded, "harpoon plugin marked loaded")
    local want = {
      H = "Harpoon: Add file",
      ce = "Harpoon: Quick menu",
      m1 = "Harpoon: Jump to file 1",
      m2 = "Harpoon: Jump to file 2",
      m3 = "Harpoon: Jump to file 3",
      m4 = "Harpoon: Jump to file 4",
    }
    for k, desc in pairs(want) do
      local m = p.maps[k]
      H.ok(m ~= vim.NIL and m, "no global mapping for " .. k)
      H.eq(desc, m.desc, k)
      H.not_ok(m.buffer and m.buffer ~= 0, k .. " must be global")
    end
  end)

  it("<C-e> opens the quick menu with a rounded border (harpoon hardcodes 'single')", function()
    require("lazy").load({ plugins = { "harpoon" } })
    local harpoon = require("harpoon")
    local seen
    local orig = harpoon.ui.toggle_quick_menu
    harpoon.ui.toggle_quick_menu = function(_, _, o)
      seen = o
    end
    local def
    for _, k in ipairs(Config.plugins.harpoon.keys or {}) do
      if k[1] == "<C-e>" then
        def = k
      end
    end
    H.ok(def, "<C-e> not in harpoon's keys")
    local ok, err = pcall(def[2])
    harpoon.ui.toggle_quick_menu = orig
    H.ok(ok, err)
    H.eq({ border = "rounded" }, seen)
  end)

  it("does not claim <leader>a, which is the claudecode +ai group", function()
    for _, k in ipairs(Config.plugins.harpoon.keys or {}) do
      H.not_ok(k[1] == "<leader>a", "harpoon key on <leader>a")
    end
    local p = probe()
    if p.maps.a ~= vim.NIL then
      H.no_match(p.maps.a.desc or "", "arpoon")
    end
    -- the extra's empty "+ai" key stub is switched off (it shadowed which-key's trigger): the
    -- spec entry is the `false` one
    local found
    for _, k in ipairs(Config.plugins["claudecode.nvim"].keys or {}) do
      if k[1] == "<leader>a" then
        found = k
      end
    end
    H.ok(found, "claudecode has no <leader>a entry")
    H.eq(false, found[2], "disabled")
  end)
end)

describe("plugins/navigation.lua", function()
  it("satellite.nvim: VeryLazy, current_only off, winblend 60 and the excluded filetypes", function()
    local o, plugin = opts_of("satellite.nvim")
    H.eq({ "VeryLazy" }, type(plugin.event) == "table" and plugin.event or { plugin.event })
    H.eq(false, o.current_only)
    H.eq(60, o.winblend)
    H.eq({ "neo-tree", "snacks_dashboard", "snacks_picker_list", "help", "lazy", "mason" }, o.excluded_filetypes)
  end)

  it("trouble: <leader>cI and <leader>cO toggle the call hierarchy trees", function()
    local p = probe()
    local want = {
      cI = { "<leader>cI", "Incoming calls (tree)", "Trouble lsp_incoming_calls toggle focus=true" },
      cO = { "<leader>cO", "Outgoing calls (tree)", "Trouble lsp_outgoing_calls toggle focus=true" },
    }
    local keys = Config.plugins["trouble.nvim"].keys
    for k, w in pairs(want) do
      -- the lazy key is mapped globally (trouble stays unloaded until used) ...
      local m = p.maps[k]
      H.ok(m ~= vim.NIL and m, "no global mapping for " .. k)
      H.eq(w[2], m.desc, k)
      -- ... and its definition runs the Trouble command
      local def
      for _, key in ipairs(keys) do
        if key[1] == w[1] then
          def = key
        end
      end
      H.ok(def, w[1] .. " not in trouble's keys")
      H.match(def[2], w[3], true, k)
    end
  end)

  local custom = {
    S = { { "Some%b()", "^Some%(().*()%)$" }, "Some(", ")" },
    O = { { "Ok%b()", "^Ok%(().*()%)$" }, "Ok(", ")" },
    N = { { "Box::new%b()", "^Box::new%(().*()%)$" }, "Box::new(", ")" },
    D = { { "dbg!%b()", "^dbg!%(().*()%)$" }, "dbg!(", ")" },
    U = { { "unsafe%s*%b{}", "^unsafe%s*{ ?().-() ?}$" }, "unsafe { ", " }" },
  }

  it("mini.surround: custom surroundings S, O, N, D, U with the documented patterns", function()
    local o = opts_of("mini.surround")
    local keys = vim.tbl_keys(o.custom_surroundings)
    table.sort(keys)
    H.eq({ "D", "N", "O", "S", "U" }, keys)
    require("lazy").load({ plugins = { "mini.surround" } })
    local cs = MiniSurround.config.custom_surroundings
    for k, want in pairs(custom) do
      H.eq(want[1], cs[k].input, k .. " input")
      H.eq({ left = want[2], right = want[3] }, cs[k].output, k .. " output")
    end
  end)

  it("mini.surround: gsa, gsr and gsd work with the Rust surroundings", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    local function line()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    end
    local function reset(text)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
      vim.api.nvim_win_set_cursor(0, { 1, 1 })
    end
    reset("word")
    H.feed("gsaiwS")
    H.eq("Some(word)", line())
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    H.feed("gsrSO")
    H.eq("Ok(word)", line())
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    H.feed("gsdO")
    H.eq("word", line())
    for key, want in pairs({ N = "Box::new(word)", D = "dbg!(word)", U = "unsafe { word }" }) do
      reset("word")
      H.feed("gsaiw" .. key)
      H.eq(want, line(), "gsaiw" .. key)
    end
    vim.cmd("silent! bwipeout! " .. buf)
  end)

  it("mini.surround: S, O, N, D, U delete the RIGHT wrapper when the content has its own brackets", function()
    require("lazy").load({ plugins = { "mini.surround" } })
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    local function try(text, col, keys)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
      vim.api.nvim_win_set_cursor(0, { 1, col })
      H.feed(keys)
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    end
    H.eq("x = vec![f(1), g(2)]", try("x = Ok(vec![f(1), g(2)])", 8, "gsdO"))
    H.eq("x = f(a(1), b)", try("x = Some(f(a(1), b))", 12, "gsdS"))
    H.eq("x = f(a(1), b)", try("x = Box::new(f(a(1), b))", 16, "gsdN"))
    H.eq("x = f(g(1))", try("x = dbg!(f(g(1)))", 12, "gsdD"))
    H.eq("let y = if a { 1 } else { 2 };", try("let y = unsafe { if a { 1 } else { 2 } };", 20, "gsdU"))
    -- replace and the simple case still work
    H.eq("x = Some(f(a(1), b))", try("x = Ok(f(a(1), b))", 8, "gsrOS"))
    vim.cmd("silent! bwipeout! " .. buf)
  end)

  it("treesj: default keymaps off, max_join_length 160, <leader>cj runs TSJToggle", function()
    local o = opts_of("treesj")
    H.eq(false, o.use_default_keymaps)
    H.eq(160, o.max_join_length)
    local m = probe().maps.cj
    H.ok(m ~= vim.NIL and m, "no global mapping for <leader>cj")
    H.eq("Split/join (treesitter)", m.desc)
    local def
    for _, key in ipairs(Config.plugins.treesj.keys) do
      if key[1] == "<leader>cj" then
        def = key
      end
    end
    H.ok(def, "<leader>cj not in treesj's keys")
    H.match(def[2], "TSJToggle", true)
  end)
end)

-- --------------------------------------------------------- 30 - 35 clipboard

describe("config/remote_clipboard.lua", function()
  local ENV = { "TMUX", "SSH_TTY", "SSH_CONNECTION", "HERDR_PANE_ID", "WAYLAND_DISPLAY", "PATH", "XYNO_FAKE_RC" }
  local saved
  local real_osc52

  -- fake ancestor chain: { [pid] = { ppid = n, comm = "x" } }
  local function with_fake_proc(chain, fn)
    local real_readfile, real_getpid = vim.fn.readfile, vim.fn.getpid
    local reads = {}
    rawset(vim.fn, "getpid", function()
      return 1000
    end)
    rawset(vim.fn, "readfile", function(path, ...)
      local pid, file = tostring(path):match("^/proc/(%d+)/(%a+)$")
      if not pid then
        return real_readfile(path, ...)
      end
      reads[#reads + 1] = path
      local e = chain[tonumber(pid)]
      if not e then
        error("E484: Can't open file " .. path)
      end
      if file == "status" then
        if e.unreadable then
          error("E484: Can't open file " .. path)
        end
        return { "Name:\t" .. e.comm, "PPid:\t" .. e.ppid }
      end
      return { e.comm }
    end)
    local ok, err = pcall(fn, reads)
    rawset(vim.fn, "readfile", nil)
    rawset(vim.fn, "getpid", nil)
    if not ok then
      error(err, 0)
    end
  end

  --- Run setup() with the given env and return vim.g.clipboard.
  local function setup(env)
    for _, k in ipairs({ "TMUX", "SSH_TTY", "SSH_CONNECTION", "HERDR_PANE_ID" }) do
      vim.env[k] = nil
    end
    for k, v in pairs(env or {}) do
      vim.env[k] = v
    end
    vim.g.clipboard = nil
    require("config.remote_clipboard").setup()
    return vim.g.clipboard
  end

  local plain_chain = { [1000] = { ppid = 500, comm = "nvim" }, [500] = { ppid = 400, comm = "bash" }, [400] = { ppid = 1, comm = "init" } }

  before_each(function()
    saved = { g = vim.g.clipboard, flag = vim.g.xynovim_remote_clipboard_osc52, old = vim.g.omarchy_remote_clipboard_osc52 }
    for _, k in ipairs(ENV) do
      saved[k] = vim.env[k]
    end
    real_osc52 = package.loaded["vim.ui.clipboard.osc52"]
  end)

  after_each(function()
    rawset(vim.fn, "readfile", nil)
    rawset(vim.fn, "getpid", nil)
    for _, k in ipairs(ENV) do
      vim.env[k] = saved[k]
    end
    package.loaded["vim.ui.clipboard.osc52"] = real_osc52
    vim.g.xynovim_remote_clipboard_osc52 = saved.flag
    vim.g.omarchy_remote_clipboard_osc52 = saved.old
    vim.g.clipboard = saved.g
  end)

  --- A recording replacement for vim.ui.clipboard.osc52.
  local function fake_osc52()
    local rec = { emitted = {}, paste = {} }
    package.loaded["vim.ui.clipboard.osc52"] = {
      copy = function(reg)
        return function(lines)
          rec.emitted[#rec.emitted + 1] = { reg = reg, lines = lines }
        end
      end,
      paste = function(reg)
        local f = function()
          return { "osc52 " .. reg }
        end
        rec.paste[reg] = f
        return f
      end,
    }
    return rec
  end

  --- A directory with fake wl-copy / wl-paste recording their calls.
  local function fake_wl()
    local dir = H.tmpdir()
    write(
      dir .. "/wl-copy",
      ("#!/bin/sh\nprintf '%%s\\n' \"$@\" > %s/copy.args\ncat > %s/copy.stdin\n"):format(dir, dir)
    )
    write(
      dir .. "/wl-paste",
      ("#!/bin/sh\nprintf '%%s\\n' \"$@\" > %s/paste.args\nprintf 'one\\ntwo'\nexit ${XYNO_FAKE_RC:-0}\n"):format(dir)
    )
    vim.fn.system({ "chmod", "+x", dir .. "/wl-copy", dir .. "/wl-paste" })
    return dir
  end

  it("does nothing outside tmux/ssh/herdr when no ancestor is herdr", function()
    with_fake_proc(plain_chain, function()
      H.is_nil(setup({}))
    end)
  end)

  it("detects an ancestor process whose comm contains 'herdr'", function()
    local chain = {
      [1000] = { ppid = 500, comm = "nvim" },
      [500] = { ppid = 400, comm = "herdr-server" },
      [400] = { ppid = 1, comm = "init" },
    }
    with_fake_proc(chain, function()
      local c = setup({})
      H.ok(c, "no clipboard provider although an ancestor is herdr")
      H.eq("XynovimRemoteClipboard", c.name)
    end)
  end)

  it("installs the provider for each of TMUX, SSH_CONNECTION, SSH_TTY and HERDR_PANE_ID", function()
    for _, var in ipairs({ "TMUX", "SSH_CONNECTION", "SSH_TTY", "HERDR_PANE_ID" }) do
      with_fake_proc(plain_chain, function(reads)
        local c = setup({ [var] = "x" })
        H.ok(c, var .. ": no clipboard provider")
        H.eq("XynovimRemoteClipboard", c.name, var)
        H.eq(0, c.cache_enabled, var)
        for _, reg in ipairs({ "+", "*" }) do
          H.eq("function", type(c.copy[reg]), var .. " copy " .. reg)
          H.eq("function", type(c.paste[reg]), var .. " paste " .. reg)
        end
        H.eq(0, #reads, var .. ": the /proc walk must be skipped when an env var decides")
      end)
    end
  end)

  it("without a Wayland display or wl-copy/wl-paste: OSC52 copy only, paste is osc52.paste", function()
    local rec = fake_osc52()
    local wl = fake_wl()
    -- (a) no WAYLAND_DISPLAY although the tools exist
    vim.env.PATH = wl .. ":" .. saved.PATH
    vim.env.WAYLAND_DISPLAY = nil
    local c = setup({ TMUX = "x" })
    c.copy["+"]({ "hi", "there" })
    H.eq({ { reg = "+", lines = { "hi", "there" } } }, rec.emitted)
    H.eq(0, vim.fn.filereadable(wl .. "/copy.args"), "wl-copy must not run without WAYLAND_DISPLAY")
    H.ok(rawequal(rec.paste["+"], c.paste["+"]), "paste + is not osc52.paste")
    H.ok(rawequal(rec.paste["*"], c.paste["*"]), "paste * is not osc52.paste")
    -- (b) WAYLAND_DISPLAY but no wl-copy/wl-paste on PATH
    rec.emitted = {}
    vim.env.WAYLAND_DISPLAY = "wayland-fake"
    vim.env.PATH = H.tmpdir()
    c = setup({ TMUX = "x" })
    c.copy["*"]({ "x" })
    H.eq({ { reg = "*", lines = { "x" } } }, rec.emitted)
    H.ok(rawequal(rec.paste["*"], c.paste["*"]), "paste * is not osc52.paste without wl-paste")
  end)

  it("with Wayland: copy runs wl-copy --sensitive --type text/plain (--primary for *) and emits OSC52", function()
    local rec = fake_osc52()
    local wl = fake_wl()
    vim.env.PATH = wl .. ":" .. saved.PATH
    vim.env.WAYLAND_DISPLAY = "wayland-fake"
    local c = setup({ TMUX = "x" })
    c.copy["+"]({ "a", "b" })
    H.eq({ "--sensitive", "--type", "text/plain" }, vim.fn.readfile(wl .. "/copy.args"))
    H.eq({ "a", "b" }, vim.fn.readfile(wl .. "/copy.stdin"))
    c.copy["*"]({ "c" })
    H.eq({ "--sensitive", "--type", "text/plain", "--primary" }, vim.fn.readfile(wl .. "/copy.args"))
    H.eq(2, #rec.emitted)
    H.eq("*", rec.emitted[2].reg)
  end)

  it("with Wayland: paste runs wl-paste --no-newline (--primary for *), {} on a non-zero exit", function()
    fake_osc52()
    local wl = fake_wl()
    vim.env.PATH = wl .. ":" .. saved.PATH
    vim.env.WAYLAND_DISPLAY = "wayland-fake"
    local c = setup({ TMUX = "x" })
    H.eq({ "one", "two" }, c.paste["+"]())
    H.eq({ "--no-newline" }, vim.fn.readfile(wl .. "/paste.args"))
    H.eq({ "one", "two" }, c.paste["*"]())
    H.eq({ "--no-newline", "--primary" }, vim.fn.readfile(wl .. "/paste.args"))
    vim.env.XYNO_FAKE_RC = "1"
    H.eq({}, c.paste["+"]())
    H.eq({}, c.paste["*"]())
  end)

  it("vim.g.xynovim_remote_clipboard_osc52 = false suppresses the OSC52 emit; the omarchy_ name is ignored", function()
    local rec = fake_osc52()
    local wl = fake_wl()
    vim.env.PATH = wl .. ":" .. saved.PATH
    vim.env.WAYLAND_DISPLAY = "wayland-fake"
    local c = setup({ TMUX = "x" })
    vim.g.xynovim_remote_clipboard_osc52 = false
    c.copy["+"]({ "quiet" })
    H.eq({}, rec.emitted)
    H.eq({ "quiet" }, vim.fn.readfile(wl .. "/copy.stdin"), "the local copy still happens")
    vim.g.xynovim_remote_clipboard_osc52 = nil
    vim.g.omarchy_remote_clipboard_osc52 = false
    c.copy["+"]({ "loud" })
    H.eq(1, #rec.emitted, "the old omarchy_ variable must not suppress the emit")
  end)

  it("the ancestor walk stops at ppid <= 1, is bounded to 16 steps and survives unreadable /proc entries", function()
    -- stops at ppid <= 1: a herdr 'above' init is never looked at
    local chain = {
      [1000] = { ppid = 500, comm = "nvim" },
      [500] = { ppid = 1, comm = "bash" },
      [1] = { ppid = 0, comm = "herdr" },
    }
    with_fake_proc(chain, function(reads)
      H.is_nil(setup({}))
      for _, r in ipairs(reads) do
        H.no_match(r, "/proc/1/", true)
      end
    end)
    -- unreadable status of the first parent: no error, no provider
    with_fake_proc({ [1000] = { ppid = 500, comm = "nvim", unreadable = true } }, function()
      H.is_nil(setup({}))
    end)
    -- a missing /proc entry deeper in the chain
    with_fake_proc({ [1000] = { ppid = 500, comm = "nvim" }, [500] = { ppid = 400, comm = "x" } }, function()
      H.is_nil(setup({}))
    end)
    -- a cycle that never reaches init: at most 16 status reads, herdr at step 17 is not seen
    local cyc = { [1000] = { ppid = 2000, comm = "nvim" } }
    for i = 0, 20 do
      cyc[2000 + i] = { ppid = 2000 + i + 1, comm = i == 17 and "herdr" or "sh" }
    end
    with_fake_proc(cyc, function(reads)
      H.is_nil(setup({}))
      local status = 0
      for _, r in ipairs(reads) do
        if r:match("/status$") then
          status = status + 1
        end
      end
      H.ok(status <= 16, "status reads: " .. status)
    end)
  end)
end)

-- ------------------------------------------------- 34 clean starts, odd envs

describe("clean startup in unusual environments", function()
  local function check(res)
    H.eq("", vim.trim(res.messages))
    H.eq("", res.errmsg)
  end

  it("with TMUX set", function()
    local env = xdg_env()
    env.PATH = vim.env.PATH
    env.TMUX = "/tmp/fake-tmux,1,0"
    local res = child(
      [[ return { messages = vim.api.nvim_exec2("messages", { output = true }).output, errmsg = vim.v.errmsg,
        clip = vim.g.clipboard and vim.g.clipboard.name } ]],
      { env = env, clear_env = true }
    )
    check(res)
    H.eq("XynovimRemoteClipboard", res.clip)
  end)

  it("with an empty environment (only HOME and the XDG dirs)", function()
    local res = child(MESSAGES, { env = xdg_env(), clear_env = true })
    check(res)
  end)

  it("with a PATH holding only nvim, git and timeout, and no WAYLAND_DISPLAY", function()
    local bin = H.tmpdir()
    for _, tool in ipairs({ "nvim", "git", "timeout" }) do
      local exe = vim.fn.exepath(tool)
      H.ok(exe ~= "", tool .. " not on PATH")
      vim.uv.fs_symlink(exe, bin .. "/" .. tool)
    end
    local env = xdg_env()
    env.PATH = bin
    env.TMUX = "/tmp/fake-tmux,1,0"
    local res = child(
      [[ return { messages = vim.api.nvim_exec2("messages", { output = true }).output, errmsg = vim.v.errmsg,
        clip = vim.g.clipboard and vim.g.clipboard.name } ]],
      { env = env, clear_env = true, cmd = bin .. "/nvim" }
    )
    check(res)
    H.eq("XynovimRemoteClipboard", res.clip)
  end)
end)
