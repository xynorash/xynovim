-- The glue of the xyno-crates.nvim plugin (lua/plugins/xyno-crates.lua): the plugin is installed and set
-- up at VeryLazy with commands and keymaps on, :CrateAdd / :CrateFeatures and the buffer-local
-- <leader>rA / <leader>rG exist (and no global map), the old vim.g.xynovim_crate_check still switches the
-- hint off, the crates.io source of "Add crate X and import" is registered on the import engine, and no
-- local copy is left. The modules themselves (scan, picker flow, manifest editor, code actions, import)
-- are specced in the xyno-crates.nvim repository.
-- xyno-os: linux,macos
local H = require("xynotest.helpers")

local saved_old = vim.g.xynovim_crate_check
local saved_new = vim.g.xyno_crate_check
after_each(function()
  vim.g.xynovim_crate_check = saved_old
  vim.g.xyno_crate_check = saved_new
  pcall(vim.cmd, "silent! %bwipeout!")
end)

describe("xyno-crates.nvim glue", function()
  local plugin = require("lazy.core.config").plugins["xyno-crates.nvim"]

  it("is installed, a plugin spec of xynorash/xyno-crates.nvim needing xyno-rust.nvim and xyno-imports.nvim, loaded at VeryLazy", function()
    H.ok(plugin and plugin._.installed, "xyno-crates.nvim is not installed")
    H.eq("xynorash/xyno-crates.nvim", plugin[1])
    H.eq({ "xyno-rust.nvim", "xyno-imports.nvim" }, plugin.dependencies)
    H.eq("VeryLazy", plugin.event[1] or plugin.event)
    H.very_lazy()
    H.ok(plugin._.loaded, "xyno-crates.nvim did not load at VeryLazy")
  end)

  it("setup() ran: :CrateAdd and :CrateFeatures exist, the module autocommands and in-process clients are there", function()
    H.very_lazy()
    H.eq(2, vim.fn.exists(":CrateAdd"))
    H.eq(2, vim.fn.exists(":CrateFeatures"))
    H.ok(#vim.api.nvim_get_autocmds({ group = "xyno-crates-add" }) > 0, "augroup xyno-crates-add")
    H.ok(#vim.api.nvim_get_autocmds({ group = "xyno_crates_features" }) > 0, "augroup xyno_crates_features")
  end)

  it("<leader>rA is buffer-local in Rust and Cargo.toml buffers, <leader>rG in Rust buffers, neither global", function()
    H.very_lazy()
    H.open_fixture("basic")
    H.wait_for(function()
      return vim.fn.maparg(" rA", "n", false, true).buffer == 1 and vim.fn.maparg(" rG", "n", false, true).buffer == 1
    end, 3000, "the buffer-local <leader>rA and <leader>rG")
    local ra = vim.fn.maparg(" rA", "n", false, true)
    local rg = vim.fn.maparg(" rG", "n", false, true)
    H.match(ra.rhs or "", "CrateAdd", true)
    H.eq("Add crate (crates.io search)", ra.desc)
    H.eq("Fix missing crate feature", rg.desc)
    -- keymaps.lua's rule: the only global <leader>r maps are the hidden stubs
    vim.cmd("enew")
    for _, lhs in ipairs({ " rA", " rG" }) do
      local g = vim.fn.maparg(lhs, "n", false, true)
      H.not_ok(g.rhs and g.rhs ~= "" and not (g.desc or ""):find("which_key_ignore", 1, true), "global map on <leader>" .. lhs:sub(2))
    end
    -- <leader>rE keeps its meaning
    local e = vim.fn.maparg(" rE", "n", false, true)
    H.ok(e.desc == nil or not e.desc:find("feature", 1, true), "<leader>rE is not taken over")
  end)

  it("vim.g.xynovim_crate_check = false reaches the plugin's switch (child nvim)", function()
    local out = vim.system({
      vim.v.progpath, "--headless",
      "--cmd", "lua vim.g.xynovim_crate_check = false",
      "-c", "doautocmd User VeryLazy",
      "-c", "lua io.stdout:write(vim.inspect(vim.g.xyno_crate_check))",
      "-c", "qa!",
    }, { text = true, timeout = 60000 }):wait()
    H.eq(0, out.code, out.stderr)
    H.eq("false", out.stdout)
  end)

  it("the hint stays on when neither global is set", function()
    local out = vim.system({
      vim.v.progpath, "--headless",
      "-c", "doautocmd User VeryLazy",
      "-c", "lua io.stdout:write(vim.inspect(vim.g.xyno_crate_check))",
      "-c", "qa!",
    }, { text = true, timeout = 60000 }):wait()
    H.eq(0, out.code, out.stderr)
    H.eq("nil", out.stdout)
  end)

  it("the crates.io source of 'Add crate X and import' is registered on the import engine", function()
    H.very_lazy()
    local ci = require("xyno_crates.crate_import")
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
    for _, m in ipairs({ "crate_add", "crate_features", "crate_import" }) do
      H.eq(0, vim.fn.filereadable(H.repo .. "/lua/config/" .. m .. ".lua"), "lua/config/" .. m .. ".lua is back")
      H.ok(pcall(require, "xyno_crates." .. m), "xyno_crates." .. m .. " does not load")
    end
  end)
end)
