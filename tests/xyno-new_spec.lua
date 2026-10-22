-- xyno-timeout: 300
-- The glue of the xyno-new.nvim plugin (lua/plugins/xyno-new.lua): the plugin is installed and set up with
-- the options derived from the old xynovim_* globals, the commands exist, no local copy is left, and the
-- snacks dashboard entries (New Rust Binary / Library / Workspace on b, i, w and New egui Project on e)
-- are in the merged preset and render at several window sizes (tmux). The project flows themselves
-- (:RustNewBin, :EguiNew, ...) are specced in the xyno-new.nvim repository.
-- xyno-os: linux,macos (tmux dashboard)
local H = require("xynotest.helpers")

describe("xyno-new.nvim glue", function()
  local plugin = require("lazy.core.config").plugins["xyno-new.nvim"]

  it("is installed, a plugin spec of xynorash/xyno-new.nvim needing xyno-rust.nvim", function()
    H.ok(plugin and plugin._.installed, "xyno-new.nvim is not installed")
    H.eq("xynorash/xyno-new.nvim", plugin[1])
    H.eq({ "xyno-rust.nvim" }, plugin.dependencies)
  end)

  it("is loaded at startup (the dashboard asks it for its entries) and setup() ran", function()
    H.ok(plugin._.loaded, "xyno-new.nvim is not loaded")
    H.eq(2, vim.fn.exists(":RustNewBin"))
  end)

  it("the five commands exist", function()
    local cmds = vim.api.nvim_get_commands({})
    for _, c in ipairs({ "RustNewBin", "RustNewLib", "RustNewWorkspace", "RustNewMember", "EguiNew" }) do
      H.ok(cmds[c], "user command :" .. c .. " missing")
    end
  end)

  it("no keymap is set (keymaps = false): the dashboard keys call the commands", function()
    for _, lhs in ipairs({ "<leader>rnb", "<leader>rni", "<leader>rnw", "<leader>rnm", "<leader>rne" }) do
      H.eq("", vim.fn.maparg(lhs, "n"), lhs .. " is mapped")
    end
  end)

  it("the opts are commands = true, keymaps = false", function()
    local opts = require("lazy.core.plugin").values(plugin, "opts", false)
    H.eq(true, opts.commands)
    H.eq(false, opts.keymaps)
  end)

  it("the old globals work: set before startup, they reach the plugin (child nvim)", function()
    local out = vim.system({
      vim.v.progpath, "--headless",
      "--cmd", "lua vim.g.xynovim_projects_dir = '/old/dir'; vim.g.xynovim_egui_template = { base_url = 'file:///t' }; vim.g.xynovim_egui_build_after_new = true",
      "-c", "lua io.stdout:write(vim.inspect({ vim.g.xyno_new_projects_dir, vim.g.xyno_new_egui_template.base_url, vim.g.xyno_new_egui_build_after_new }))",
      "-c", "qa!",
    }, { text = true, timeout = 60000 }):wait()
    H.eq(0, out.code, out.stderr)
    H.match(out.stdout, '"/old/dir"')
    H.match(out.stdout, '"file:///t"')
    H.match(out.stdout, "true")
  end)

  it("no local copy is left", function()
    for _, m in ipairs({ "rust_new", "egui_new" }) do
      H.eq(0, vim.fn.filereadable(H.repo .. "/lua/config/" .. m .. ".lua"), "lua/config/" .. m .. ".lua is back")
    end
    for _, m in ipairs({ "rust", "egui", "dashboard" }) do
      H.ok(pcall(require, "xyno_new." .. m), "xyno_new." .. m .. " does not load")
    end
  end)
end)

describe("dashboard entries 'New Rust Binary / Library / Workspace'", function()
  local function snacks_opts()
    local plugin = H.ok(require("lazy.core.config").plugins["snacks.nvim"], "snacks.nvim")
    return require("lazy.core.plugin").values(plugin, "opts", false)
  end

  local WANT = {
    { "b", "New Rust Binary", ":RustNewBin" },
    { "i", "New Rust Library", ":RustNewLib" },
    { "w", "New Rust Workspace", ":RustNewWorkspace" },
  }

  it("three entries with unique keys and distinct icons, in order, before the egui entry and Quit", function()
    local keys = snacks_opts().dashboard.preset.keys
    local seen, icons, pos = {}, {}, {}
    for i, k in ipairs(keys) do
      H.is_nil(seen[k.key], "duplicate dashboard key " .. tostring(k.key))
      seen[k.key] = true
      H.is_nil(icons[k.icon or ""], "duplicate icon for " .. tostring(k.desc))
      icons[k.icon or ""] = true
      pos[k.desc] = i
    end
    for n, w in ipairs(WANT) do
      local i = H.ok(pos[w[2]], w[2] .. " is in the merged preset")
      H.eq(w[1], keys[i].key)
      H.eq(w[3], keys[i].action)
      H.ok(keys[i].icon and #keys[i].icon > 0)
      if n > 1 then
        H.eq(pos[WANT[n - 1][2]] + 1, i, "the three are consecutive")
      end
    end
    H.eq(pos["Quit"] - 1, pos["New egui Project"], "the egui entry stays right before Quit")
    H.ok(pos["New Rust Workspace"] < pos["New egui Project"])
    for _, k in ipairs({ "f", "n", "p", "g", "r", "c", "s", "x", "l", "q", "e" }) do
      H.ok(seen[k], "the existing key " .. k .. " is unchanged")
    end
  end)

  it("the layout thresholds follow the number of entries", function()
    local o = snacks_opts()
    local n = #o.dashboard.preset.keys
    local s = o.dashboard.sections
    local lines = vim.o.lines
    vim.o.lines = 2 * n + 11
    H.ok(s[2].enabled() and not s[3].enabled() and s[1].enabled(), "tall at 2n+11")
    vim.o.lines = 2 * n + 10
    H.ok(not s[2].enabled() and s[3].enabled() and s[1].enabled(), "short with the header below")
    vim.o.lines = n + 12
    H.ok(s[1].enabled(), "header at n+12")
    vim.o.lines = n + 11
    H.ok(not s[1].enabled(), "no header below n+12")
    vim.o.lines = lines
  end)

  local function in_tmux(cols, rows, session)
    H.need_tmux()
    local env = {}
    for _, k in ipairs({ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "TMPDIR", "HOME" }) do
      if vim.env[k] then
        env[#env + 1] = ("%s=%s"):format(k, vim.fn.shellescape(vim.env[k]))
      end
    end
    local cmd = "env " .. table.concat(env, " ") .. " " .. vim.fn.shellescape(vim.fn.exepath("nvim"))
    local r = H.tmux({ "new-session", "-d", "-s", session, "-x", tostring(cols), "-y", tostring(rows), cmd }, session)
    H.eq(0, r.code, r.stderr)
    local function capture()
      return H.tmux({ "capture-pane", "-p", "-t", session }, session).stdout or ""
    end
    return capture, function(keys)
      H.tmux({ "send-keys", "-t", session, keys }, session)
    end
  end

  -- every entry with its key on one screen line, at the sizes the layouts are made for
  for _, c in ipairs({ { 80, 24 }, { 100, 30 }, { 190, 50 }, { 80, 18 }, { 120, 38 }, { 120, 39 } }) do
    it(("every entry and key is on screen at %dx%d"):format(c[1], c[2]), function()
      local capture = in_tmux(c[1], c[2], ("d%dx%d"):format(c[1], c[2]))
      H.wait_for(function()
        local p = capture()
        return p:find("Quit", 1, true) and p:find("loaded", 1, true)
      end, 30000, ("dashboard at %dx%d:\n%s"):format(c[1], c[2], capture()))
      local pane = capture()
      for _, k in ipairs(snacks_opts().dashboard.preset.keys) do
        local found
        for line in pane:gmatch("[^\n]+") do
          if line:find(k.desc, 1, true) and line:match("%s" .. vim.pesc(k.key) .. "%s*$") then
            found = true
          end
        end
        H.ok(found, ("'%s' (%s) is missing at %dx%d:\n%s"):format(k.desc, k.key, c[1], c[2], pane))
      end
      H.match(pane, "loaded %d+/%d+ plugins")
    end)
  end

  for _, w in ipairs(WANT) do
    it(("pressing %s at 80x24 opens the prompt of %s"):format(w[1], w[2]), function()
      local capture, send = in_tmux(80, 24, "key" .. w[1])
      H.wait_for(function()
        return capture():find("Quit", 1, true)
      end, 30000, "dashboard")
      send(w[1])
      local want = w[1] == "w" and "Workspace name" or "Project name"
      H.wait_for(function()
        return capture():find(want, 1, true)
      end, 10000, "the prompt after pressing " .. w[1] .. ":\n" .. capture())
      send("Escape")
    end)
  end
end)

describe("dashboard entry 'New egui Project'", function()
  local function snacks_opts()
    local plugin = H.ok(require("lazy.core.config").plugins["snacks.nvim"], "snacks.nvim")
    return require("lazy.core.plugin").values(plugin, "opts", false)
  end

  it("sits before Quit with a unique key, in the merged preset", function()
    local keys = snacks_opts().dashboard.preset.keys
    local idx, quit, seen = nil, nil, {}
    for i, k in ipairs(keys) do
      H.is_nil(seen[k.key], "duplicate dashboard key " .. tostring(k.key))
      seen[k.key] = true
      if k.desc == "New egui Project" then
        idx = i
      elseif k.desc == "Quit" then
        quit = i
      end
    end
    H.ok(idx and quit, "entries present")
    H.eq(quit - 1, idx)
    H.eq("e", keys[idx].key)
    H.eq(":EguiNew", keys[idx].action)
    H.ok(keys[idx].icon and #keys[idx].icon > 0)
    for _, d in ipairs({ "Find File", "New File", "Find Text", "Recent Files", "Config", "Restore Session", "Lazy Extras", "Lazy", "Quit" }) do
      local found
      for _, k in ipairs(keys) do
        found = found or k.desc == d
      end
      H.ok(found, "LazyVim's '" .. d .. "' entry is still there")
    end
  end)

  it("both layouts (tall and short) render the preset keys", function()
    local s = snacks_opts().dashboard.sections
    H.eq("keys", s[2].section)
    H.eq("keys", s[3].section)
    H.ok(s[2].enabled() ~= s[3].enabled())
  end)

  local function in_tmux(rows, session)
    H.need_tmux()
    local env = {}
    for _, k in ipairs({ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "TMPDIR", "HOME" }) do
      if vim.env[k] then
        env[#env + 1] = ("%s=%s"):format(k, vim.fn.shellescape(vim.env[k]))
      end
    end
    local cmd = "env " .. table.concat(env, " ") .. " " .. vim.fn.shellescape(vim.fn.exepath("nvim"))
    local r = H.tmux({ "new-session", "-d", "-s", session, "-x", "80", "-y", tostring(rows), cmd }, session)
    H.eq(0, r.code, r.stderr)
    local pane = ""
    local function capture()
      pane = H.tmux({ "capture-pane", "-p", "-t", session }, session).stdout or ""
      return pane
    end
    return capture, function(keys)
      H.tmux({ "send-keys", "-t", session, keys }, session)
    end
  end

  for _, c in ipairs({ { 24, "short" }, { 50, "tall" } }) do
    it(("is visible at 80x%d (%s layout) with Quit and the footer, and `e` opens the name prompt"):format(c[1], c[2]), function()
      local capture, send = in_tmux(c[1], "egui" .. c[2])
      H.wait_for(function()
        local p = capture()
        return p:find("Quit", 1, true) and p:find("loaded", 1, true)
      end, 30000, "dashboard")
      H.has(capture(), "New egui Project")
      H.has(capture(), "Find File")
      H.match(capture(), "loaded %d+/%d+ plugins")
      send("e")
      H.wait_for(function()
        return capture():find("Project name", 1, true)
      end, 10000, "the prompt after pressing e:\n" .. capture())
      send("Escape") -- cancel: nothing is created
    end)
  end
end)
