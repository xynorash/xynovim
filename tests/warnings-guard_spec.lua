-- Warnings and errors guard: a clean start of the real config in BOTH plugin modes (pinned plugins, and
-- the local clones through XYNOVIM_DEV_PLUGINS) must print nothing unexpected. Needs cargo and
-- rust-analyzer; the dev mode skips with a message without the clones (default ~/projects/xyno-plugins).
-- xyno-os: linux (health output and tool environment are the Linux ones)
-- xyno-timeout: 700
--
-- Per mode one child nvim starts with EMPTY state and cache directories (a first start), trusts and opens
-- the `basic` fixture crate, waits for rust-analyzer, loads every lazy plugin and runs `:checkhealth` for
-- ALL providers (vim.*, lazy, mason, nvim-treesitter, blink.cmp, snacks, noice, which-key, conform, dap,
-- telescope, lspconfig, rustaceanvim, xyno_*, ...). It FAILS on any
--   - `:messages` line that is not a file-written echo, any E-code, or a non-empty v:errmsg,
--   - vim.deprecate() call (an API the config or a plugin uses that Neovim is removing),
--   - WARN/ERROR notification (vim.notify, snacks and noice included),
--   - `:checkhealth` WARNING or ERROR line that ENV_LIMITS below does not cover.
-- ENV_LIMITS is the explicit allowlist: every entry says why it cannot be fixed from this repo (a tool the
-- user may not want installed, a terminal capability, an upstream health check of a feature this config
-- switches off, a headless-child artefact). A finding this repo CAN fix gets fixed, not listed here
-- (CHANGELOG.md, "Warnings and errors sweep 1").
local H = require("xynotest.helpers")

-- ----------------------------------------------------------------- the allowlist

local ENV_LIMITS = {
  -- external tools: absent on a machine that has not installed them (a user decision, never installed here)
  { "conform", "^%S+ unavailable: Command '%S+' not found$", "formatter binary not installed (fish_indent, prettier)" },
  {
    "conform",
    "^%S+ unavailable: Condition failed$",
    "LazyVim markdown formatters run only for the filetypes/roots they apply to",
  },
  { "diffview", "hg_cmd", "mercurial is not installed" },
  { "grug%-far", "ast%-grep", "ast-grep is optional" },
  { "kulala", "not found", "gRPCurl / websocat / formatters are optional HTTP client tools" },
  { "Tools", "not found", "kulala's optional tools (gRPCurl, websocat)" },
  { "Formatters", "formatter not found", "kulala's optional body formatters" },
  {
    "mason",
    "not available",
    "language toolchains for Mason packages nobody asked for (Ruby, PHP, Java, Julia, wget, luarocks)",
  },
  { "overseer", "not found", "overseer task providers for tools that are not installed (just, task, mise, ...)" },
  {
    "overseer",
    "^{%S+}: No .+ found$",
    "overseer providers look for project files this project does not have (Makefile, package.json, ...)",
  },
  { "snacks", "Tool not found", "snacks.image converters (gs, mmdc) are optional" },
  { "snacks", "None of the tools found", "snacks.image LaTeX renderer (tectonic / pdflatex) is optional" },
  { "snacks", "is required to render", "same: optional converters of snacks.image" },
  { "snacks", "kitty graphics protocol", "image rendering needs Ghostty/kitty/WezTerm; headless and tmux lack it" },
  {
    "snacks",
    "Missing Treesitter languages",
    "parsers for image rendering in css/latex/norg/scss/svelte/typst/vue docs, not Rust",
  },
  { "snacks", "treesitter parsers won't work", "same" },
  {
    "snacks",
    "^setup {disabled}$",
    "snacks features this config switches off on purpose (explorer, image, scroll, statuscolumn)",
  },
  {
    "xynovim",
    "cargo%-nextest not found",
    "nextest is optional: neotest then runs cargo test (the health line says so)",
  },
  {
    "xynovim",
    "lacks the wasm32%-unknown%-unknown target",
    "optional rustup target for web/WASM crates (the hint prints the command)",
  },
  {
    "xynovim",
    "^truecolor: tmux",
    "only when run under tmux that is not told about 24-bit colour (the hint prints the setting)",
  },
  { "xynovim", "^underlines: no curly", "only on terminals/tmux without Smulx/Setulc (the hint prints the setting)" },
  { "xyno_clipboard", "OSC 52", "tmux/terminal clipboard configuration (the advice lines carry the setting)" },
  { "xyno_clipboard", "SSH session", "SSH without tmux: depends on the terminal, which Neovim cannot detect" },
  { "xyno_clipboard", "no clipboard tool", "a machine without wl-copy/xclip/xsel" },
  { "vim%.health", "focus%-events", "terminal/tmux option of the machine running the child (headless has no UI)" },
  { "vim%.health", "True color support", "same: no UI in the headless child" },
  -- Neovim / upstream plugin behaviour
  {
    "vim%.pack",
    "Lockfile is absent",
    "`:checkhealth vim.pack` itself creates the empty plugin directory; this config uses lazy.nvim, not vim.pack",
  },
  {
    "lazy",
    "found existing packages at .*site/pack/core",
    "the empty directory that `:checkhealth vim.pack` just created (same cause)",
  },
  {
    "vim%.lsp",
    "^Unknown filetype '[%w%-]+%.[%w%-]+'",
    "compound filetypes (yaml.docker-compose, markdown.mdx, ...) in lspconfig's server defaults that Neovim does not define",
  },
  { "neo%-tree", "gio trash", "`gio trash --list` needs gvfs (the desktop trash); not part of this config" },
  -- the headless child has no UI and no display server: snacks sets up on UIEnter, and there is no clipboard
  -- tool to find (the TUI health run in tmux and Ghostty shows these as OK)
  { "snacks", "^setup did not run$", "headless child: snacks sets up on UIEnter" },
  { "snacks", "vim%.ui%.%a+` is not set to", "headless child: snacks replaces vim.ui.* on UIEnter" },
  { "vim%.provider", "No clipboard tool found", "headless child without WAYLAND_DISPLAY/DISPLAY" },
  { "blink%.cmp", 'may show up as "disabled"', "blink.cmp's own note about dynamically enabled providers" },
  {
    "which%-key",
    "overlaps with",
    "defaults of Neovim 0.12 (gr*, gc*), mini.ai/mini.surround; overlap is by design (informational)",
  },
}

-- ':messages' lines that are not problems: the write/edit echoes of the steps below
local BENIGN_MESSAGE = {
  '^"[^"]+" %d+L, %d+B', -- file written / read echo
  "^%d+ lines? yanked",
  "^%d+ more lines?",
  "^%d+ fewer lines?",
  "^%d+ lines? less",
  "^%d+ lines? changed",
  -- environment limit: the child has no display server (no WAYLAND_DISPLAY / DISPLAY), so xyno-clipboard
  -- (dev plugins) says once that yanks go through OSC 52; its text names the fix
  "^xyno%-clipboard: no clipboard tool found",
}

-- --------------------------------------------------------------------- the child

local CHILD = [[
local out = assert(vim.env.XYNO_GUARD_OUT)
local root = assert(vim.env.XYNO_GUARD_ROOT)
local rec = { deprecations = {}, notes = {}, steps = {} }
local deprecate = vim.deprecate
vim.deprecate = function(name, alt, ver, plugin, backtrace)
  rec.deprecations[#rec.deprecations + 1] = ("%s -> %s (remove in %s, %s)"):format(name, alt or "?", ver or "?", plugin or "nvim")
  return deprecate(name, alt, ver, plugin, backtrace)
end
local function note(msg, level)
  rec.notes[#rec.notes + 1] = { level = level or vim.log.levels.INFO, msg = tostring(msg) }
end
local wrapped
local function hook()
  if vim.notify == wrapped then return end
  local prev = vim.notify
  wrapped = function(msg, level, o)
    note(msg, level)
    return prev(msg, level, o)
  end
  vim.notify = wrapped
end
-- NOT hooked at once: LazyVim parks vim.notify in a collector for the first 500 ms and replays what it
-- collected through whatever vim.notify is by then. A wrapper that keeps the collector as its "previous" function
-- makes that replay append to the list it iterates over, for ever (8 GB, no start): after VeryLazy instead.
-- Notifications from before that go to the notifier and show in `history` below.
vim.api.nvim_create_autocmd("User", { pattern = "VeryLazy", callback = function() vim.schedule(hook) end })

local function finish()
  local ok, health = pcall(function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].filetype == "checkhealth" then return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
    end
  end)
  local spec_notifs = {}
  pcall(function()
    for _, n in ipairs(require("lazy.core.config").spec.notifs) do spec_notifs[#spec_notifs + 1] = n[1] end
  end)
  local history = {}
  pcall(function()
    for _, n in ipairs(require("snacks").notifier.get_history()) do
      history[#history + 1] = { level = n.level, msg = n.msg or "" }
    end
  end)
  local f = assert(io.open(out, "w"))
  f:write(vim.json.encode({
    messages = vim.api.nvim_exec2("messages", { output = true }).output,
    errmsg = vim.v.errmsg,
    deprecations = rec.deprecations, notes = rec.notes, history = history, spec_notifs = spec_notifs,
    health = ok and health or {}, steps = rec.steps,
    clients = vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients()),
  }))
  f:close()
  vim.cmd("qa!")
end

vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = function()
  vim.defer_fn(function()
    local ok, err = xpcall(function()
      pcall(function() require("config.workspace_trust").store().trust(root, { recursive = true }) end)
      vim.cmd.cd(vim.fn.fnameescape(root))
      vim.cmd.edit(vim.fn.fnameescape(root .. "/src/main.rs"))
      local attached = vim.wait(90000, function()
        return #vim.lsp.get_clients({ name = "rust-analyzer", bufnr = 0 }) > 0
      end, 200)
      rec.steps[#rec.steps + 1] = "rust-analyzer attached: " .. tostring(attached)
      vim.wait(8000) -- diagnostics, bacon-ls, the started-late plugins
      vim.cmd("silent! write")
      vim.cmd("Lazy! load all")
      vim.wait(3000)
      vim.cmd("checkhealth")
      local last, since = -1, vim.uv.now()
      vim.wait(180000, function()
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.bo[b].filetype == "checkhealth" then
            local n = vim.api.nvim_buf_line_count(b)
            if n ~= last then last, since = n, vim.uv.now() end
            local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
            local seen = false
            for _, l in ipairs(lines) do if l:match("^xynovim:") then seen = true end end
            return seen and vim.uv.now() - since > 4000
          end
        end
        return false
      end, 500)
    end, debug.traceback)
    if not ok then rec.steps[#rec.steps + 1] = "child error: " .. tostring(err) end
    finish()
  end, 800)
end })
]]

-- ----------------------------------------------------------------------- driving

local function dev_dir()
  local d = vim.env.XYNOVIM_DEV_PLUGINS
  if not d or d == "" then
    d = vim.fn.expand("~/projects/xyno-plugins")
  end
  return vim.fn.isdirectory(d) == 1 and d or nil
end

local function run_mode(mode)
  local root = H.fixture("basic", { git = true })
  local work = H.tmpdir()
  local script = work .. "/guard-child.lua"
  local f = assert(io.open(script, "w"))
  f:write(CHILD)
  f:close()
  local out = work .. "/result.json"
  local env = {}
  for _, k in ipairs({ "HOME", "PATH", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "TERM", "LANG", "CARGO_HOME", "RUSTUP_HOME" }) do
    env[k] = vim.env[k]
  end
  env.XDG_STATE_HOME = work .. "/state" -- a FIRST start: nothing remembered
  env.XDG_CACHE_HOME = work .. "/cache"
  env.TMPDIR = work
  env.XYNO_GUARD_OUT = out
  env.XYNO_GUARD_ROOT = root
  env.XYNOVIM_DEV_PLUGINS = mode == "dev" and dev_dir() or nil
  vim.fn.mkdir(env.XDG_STATE_HOME, "p")
  vim.fn.mkdir(env.XDG_CACHE_HOME, "p")
  -- never download blink.cmp's library from a short-lived child (a kill mid-download leaves a v0.0.0 marker in the
  -- shared plugin directory, and the download waits on the network): the Lua matcher, as in tests/runner.lua
  local args = { vim.fn.exepath("nvim"), "--headless" }
  if vim.env.XYNO_TEST_BLINK_DOWNLOAD ~= "1" then
    vim.list_extend(args, { "--cmd", "lua vim.g.xynovim_blink_download = false" })
  end
  vim.list_extend(args, { "-S", script })
  -- Wait for the RESULT FILE, not for the process: quitting a child that ran rust-analyzer, bacon-ls and
  -- every plugin can take minutes (seen: stuck in disk wait with the file long written), and a spec must
  -- not wait for that. The child is killed once the file is complete.
  local obj = vim.system(args, { env = env, clear_env = true, text = true })
  vim.wait(420000, function()
    local st = vim.uv.fs_stat(out)
    return st ~= nil and st.size > 0
  end, 500)
  vim.wait(1000)
  pcall(function()
    obj:kill(9)
  end)
  local fh = io.open(out, "r")
  if not fh then
    error(("the %s child wrote no result within 420 s"):format(mode), 2)
  end
  local data = vim.json.decode(fh:read("*a"))
  fh:close()
  return data
end

--- { { section, kind, text } } of the WARNING and ERROR lines of a :checkhealth buffer.
local function health_findings(lines)
  local found, section = {}, "?"
  for _, l in ipairs(lines) do
    local name = l:match("^([%w_%.%-]+):%s")
    if name then
      section = name
    end
    local kind, text = l:match("^%s*%- [^%a]*%s*(WARNING)%s+(.*)$")
    if not kind then
      kind, text = l:match("^%s*%- [^%a]*%s*(ERROR)%s+(.*)$")
    end
    if kind then
      found[#found + 1] = { section, kind, text }
    end
  end
  return found
end

-- A hosted CI runner is a bare machine: it has none of the optional tools and no Nerd Font, so the
-- machine-specific ENV_LIMITS above cannot list every missing tool. On CI (the CI variable is set by
-- GitHub Actions) a health line is also accepted when it is only about a missing tool, an older Neovim
-- release or the runner's terminal. Locally the list stays strict, so a real new warning still fails.
local CI_ONLY = {
  "not found",
  "not installed",
  "not executable",
  "is required",
  "not available",
  "No Nerd Font",
  "COLORTERM",
  "command failed",
  "is available %(current",
  "lacks llvm%-tools",
}

local function allowed(section, text, strict)
  for _, e in ipairs(ENV_LIMITS) do
    if section:find(e[1]) and text:find(e[2]) then
      return true
    end
  end
  if not strict and os.getenv("CI") and os.getenv("CI") ~= "" then
    for _, p in ipairs(CI_ONLY) do
      if text:find(p) then
        return true
      end
    end
  end
  return false
end

local results = {}
local function result(mode)
  if not results[mode] then
    H.need_rust()
    if mode == "dev" and not dev_dir() then
      skip("no plugin clones (XYNOVIM_DEV_PLUGINS or ~/projects/xyno-plugins): the dev mode is not tested")
    end
    results[mode] = run_mode(mode)
  end
  return results[mode]
end

-- ----------------------------------------------------------------------- specs

for _, mode in ipairs({ "pinned", "dev" }) do
  describe("clean start, " .. mode .. " plugins, empty state", function()
    it("opens a Rust file with rust-analyzer attached", function()
      local d = result(mode)
      H.ok(
        vim.tbl_contains(d.clients, "rust-analyzer"),
        "clients: " .. vim.inspect(d.clients) .. " " .. vim.inspect(d.steps)
      )
    end)

    it("prints no unexpected :messages line and no E-code", function()
      local d = result(mode)
      local bad = {}
      for line in (d.messages or ""):gmatch("[^\n]+") do
        local benign = false
        for _, p in ipairs(BENIGN_MESSAGE) do
          benign = benign or line:find(p) ~= nil
        end
        if not benign and vim.trim(line) ~= "" then
          bad[#bad + 1] = line
        end
      end
      H.eq({}, bad, "unexpected :messages lines")
      H.eq("", d.errmsg or "", "v:errmsg")
      local codes = {}
      for _, n in ipairs(d.notes) do
        local c = n.msg:match("E%d%d%d+:")
        if c then
          codes[#codes + 1] = n.msg:sub(1, 160)
        end
      end
      H.eq({}, codes, "E-codes in notifications")
    end)

    it("calls vim.deprecate nowhere and lazy.nvim has no spec notifications", function()
      local d = result(mode)
      H.eq({}, d.deprecations, "vim.deprecate calls (the API a plugin or this config still uses)")
      H.eq({}, d.spec_notifs, "lazy.nvim spec notifications")
    end)

    it("shows no WARN or ERROR notification", function()
      local d = result(mode)
      local bad = {}
      for _, n in ipairs(d.history) do
        if
          (type(n.level) == "number" and n.level >= vim.log.levels.WARN)
          or n.level == "warn"
          or n.level == "error"
        then
          bad[#bad + 1] = ("[snacks %s] %s"):format(n.level, tostring(n.msg):sub(1, 200))
        end
      end
      for _, n in ipairs(d.notes) do
        if n.level >= vim.log.levels.WARN then
          bad[#bad + 1] = ("[%d] %s"):format(n.level, n.msg:sub(1, 200))
        end
      end
      H.eq({}, bad, "WARN/ERROR notifications during start, open, save and checkhealth")
    end)

    it(":checkhealth (all providers) has no WARNING or ERROR outside the documented environment limits", function()
      local d = result(mode)
      H.ok(#d.health > 500, "the checkhealth buffer was not filled: " .. #d.health .. " lines " .. vim.inspect(d.steps))
      local sections = {}
      for _, l in ipairs(d.health) do
        local name = l:match("^([%w_%.%-]+):%s")
        if name then
          sections[name] = true
        end
      end
      -- the providers the task names must have been run, not silently missing
      for _, want in ipairs({
        "vim.deprecated",
        "vim.lsp",
        "vim.treesitter",
        "lazy",
        "mason",
        "nvim-treesitter",
        "blink.cmp",
        "snacks",
        "noice",
        "which-key",
        "conform",
        "dap",
        "telescope",
        "lspconfig",
        "rustaceanvim",
        "xynovim",
      }) do
        H.ok(sections[want], "no health section " .. want .. " in " .. vim.inspect(vim.tbl_keys(sections)))
      end
      local bad = {}
      for _, f in ipairs(health_findings(d.health)) do
        if not allowed(f[1], f[3]) then
          bad[#bad + 1] = ("%s | %s %s"):format(f[1], f[2], f[3]:sub(1, 200))
        end
      end
      H.eq({}, bad, "health findings not on the ENV_LIMITS allowlist")
    end)
  end)
end

-- The allowlist itself is checked against a mistake that would make the guard vacuous: an entry that
-- matches EVERYTHING of a section.
describe("warnings guard allowlist", function()
  it("has no catch-all entry and a reason for every entry", function()
    for _, e in ipairs(ENV_LIMITS) do
      H.ok(#e == 3 and e[3] ~= "", "entry without a reason: " .. vim.inspect(e))
      H.ok(#e[2] >= 3 and e[2] ~= ".*", "catch-all entry: " .. vim.inspect(e))
    end
  end)
  it("lets a made-up finding fail", function()
    H.not_ok(allowed("noice", "something broke", true))
    H.not_ok(allowed("xynovim", "rust-analyzer not found", true))
  end)
end)
