-- The glue of the xyno-imports.nvim plugin (lua/plugins/xyno-imports.lua): the plugin is installed and
-- set up at VeryLazy, :ImportName / :ImportForget / :ImportOrganize and the buffer-local <leader>rI /
-- <leader>rO exist, the old vim.g.xynovim_auto_import still decides the mode, the remembered choices
-- stay in the old state file, the crates.io source of config/crate_import.lua is registered, and no local
-- copy is left. The engine itself (scoring, memory, scan, the flows) is specced in the xyno-imports.nvim
-- repository; crate-import and macros-deps-flows here use it through xyno_imports.engine.
-- xyno-os: linux,macos
local H = require("xynotest.helpers")

local saved_old = vim.g.xynovim_auto_import
local saved_new = vim.g.xyno_auto_import
after_each(function()
  vim.g.xynovim_auto_import = saved_old
  vim.g.xyno_auto_import = saved_new
  pcall(vim.cmd, "silent! %bwipeout!")
end)

describe("xyno-imports.nvim glue", function()
  local plugin = require("lazy.core.config").plugins["xyno-imports.nvim"]

  it("is installed, a plugin spec of xynorash/xyno-imports.nvim needing xyno-rust.nvim, loaded at VeryLazy", function()
    H.ok(plugin and plugin._.installed, "xyno-imports.nvim is not installed")
    H.eq("xynorash/xyno-imports.nvim", plugin[1])
    H.eq({ "xyno-rust.nvim" }, plugin.dependencies)
    H.eq("VeryLazy", plugin.event[1] or plugin.event)
    H.very_lazy()
    H.ok(plugin._.loaded, "xyno-imports.nvim did not load at VeryLazy")
  end)

  it("setup() ran: the three commands and the engine's autocommands exist", function()
    H.very_lazy()
    for _, c in ipairs({ "ImportName", "ImportForget", "ImportOrganize" }) do
      H.eq(2, vim.fn.exists(":" .. c), c)
    end
    H.ok(#vim.api.nvim_get_autocmds({ group = "xyno_imports" }) > 0, "augroup xyno_imports")
  end)

  it("<leader>rI and <leader>rO are mapped in Rust buffers (buffer-local)", function()
    H.very_lazy()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "rust"
    vim.api.nvim_exec_autocmds("FileType", { buffer = buf })
    local ri = vim.fn.maparg("<leader>rI", "n", false, true)
    local ro = vim.fn.maparg("<leader>rO", "n", false, true)
    H.eq(1, ri.buffer, "<leader>rI")
    H.eq(1, ro.buffer, "<leader>rO")
    H.eq("Import name (ranked)", ri.desc)
    H.eq("Organize imports", ro.desc)
  end)

  it("vim.g.xynovim_auto_import still decides the mode (ask by default, bogus values ignored)", function()
    H.very_lazy()
    local E = require("xyno_imports.engine")
    vim.g.xyno_auto_import = nil
    vim.g.xynovim_auto_import = nil
    H.eq("ask", E.mode())
    vim.g.xynovim_auto_import = "bogus"
    H.eq("ask", E.mode())
    for _, m in ipairs({ "single", "off", "ask" }) do
      vim.g.xynovim_auto_import = m
      H.eq(m, E.mode())
    end
  end)

  it("the plugin's own vim.g.xyno_auto_import wins over the old variable", function()
    H.very_lazy()
    local E = require("xyno_imports.engine")
    vim.g.xynovim_auto_import = "single"
    vim.g.xyno_auto_import = "off"
    H.eq("off", E.mode())
  end)

  it("the remembered choices stay in stdpath('state')/xynovim/imports.json", function()
    H.very_lazy()
    H.eq(vim.fn.stdpath("state") .. "/xynovim/imports.json", require("xyno_imports.engine").state_file)
  end)

  it("a child nvim started with vim.g.xynovim_auto_import = 'off' reports off", function()
    local out = vim.system({
      vim.v.progpath, "--headless",
      "--cmd", "lua vim.g.xynovim_auto_import = 'off'",
      "-c", "doautocmd User VeryLazy",
      "-c", "lua io.stdout:write(require('xyno_imports.engine').mode())",
      "-c", "qa!",
    }, { text = true, timeout = 60000 }):wait()
    H.eq(0, out.code, out.stderr)
    H.eq("off", out.stdout)
  end)

  it("the crates.io source of config/crate_import.lua is registered on the engine", function()
    H.very_lazy()
    local ci = require("config.crate_import")
    local registered
    for i = 1, 20 do
      local name, value = debug.getupvalue(ci.setup, i)
      if not name then
        break
      end
      if name == "unregister" then
        registered = type(value) == "function"
      end
    end
    H.ok(registered, "crate_import.setup() did not register its source")
  end)

  it("no local copy is left", function()
    H.eq(0, vim.fn.filereadable(H.repo .. "/lua/config/import_engine.lua"), "lua/config/import_engine.lua is back")
    H.ok(pcall(require, "xyno_imports.engine"), "xyno_imports.engine does not load")
  end)
end)
