-- The glue of the xyno-macros.nvim plugin (lua/plugins/xyno-macros.lua): the plugin is installed and set
-- up at VeryLazy with commands and keymaps on, the five commands exist, <leader>rx / <leader>rq and the
-- insert mode <C-k> are buffer-local in Rust buffers with a client, the two blink.cmp sources are
-- registered as before (macro_attrs above rust-analyzer's items, macro_tools in the defaults), the
-- snippets still follow config/ux.lua's snippets_allowed(), project schemas still come from
-- .xynovim/macro_attrs, and no local copy (nor data/) is left. The lexer, schemas, matcher and windows
-- are specced in the xyno-macros.nvim repository.
-- xyno-os: linux,macos
local H = require("xynotest.helpers")

after_each(function()
  pcall(vim.cmd, "silent! %bwipeout!")
end)

describe("xyno-macros.nvim glue", function()
  local plugin = require("lazy.core.config").plugins["xyno-macros.nvim"]

  it("is installed, a plugin spec of xynorash/xyno-macros.nvim needing xyno-rust.nvim and xyno-imports.nvim, loaded at VeryLazy", function()
    H.ok(plugin and plugin._.installed, "xyno-macros.nvim is not installed")
    H.eq("xynorash/xyno-macros.nvim", plugin[1])
    H.eq({ "xyno-rust.nvim", "xyno-imports.nvim" }, plugin.dependencies)
    H.eq("VeryLazy", plugin.event[1] or plugin.event)
    H.very_lazy()
    H.ok(plugin._.loaded, "xyno-macros.nvim did not load at VeryLazy")
  end)

  it("setup() ran: the five commands exist", function()
    H.very_lazy()
    for _, c in ipairs({ "MacroAttrs", "MacroExpand", "MacroFormatFix", "MacroSignature", "ProcMacroStatus" }) do
      H.eq(2, vim.fn.exists(":" .. c), c)
    end
    H.ok(#vim.api.nvim_get_autocmds({ group = "xyno_macros" }) > 0, "augroup xyno_macros")
  end)

  it("<leader>rx, <leader>rq and the insert mode <C-k> are buffer-local in a Rust buffer with a client, none global", function()
    H.very_lazy()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "rust"
    local ca = require("xyno_rust.code_actions")
    local orig = ca.clients
    ca.clients = function()
      return { {} }
    end
    local ok, err = pcall(function()
      vim.api.nvim_exec_autocmds("LspAttach", { buffer = buf, data = { client_id = 1 } })
      H.wait_for(function()
        return vim.fn.maparg("<leader>rx", "n", false, true).buffer == 1
      end, 3000, "<leader>rx")
      H.eq("Expand macro under cursor (lens)", vim.fn.maparg("<leader>rx", "n", false, true).desc)
      H.eq("Proc-macro status", vim.fn.maparg("<leader>rq", "n", false, true).desc)
      H.eq("Macro / signature help", vim.fn.maparg("<C-k>", "i", false, true).desc)
      H.eq(1, vim.fn.maparg("<C-k>", "i", false, true).buffer, "<C-k> is buffer-local")
    end)
    ca.clients = orig
    if not ok then
      error(err, 0)
    end
    -- keymaps.lua's rule: the only global <leader>r maps are the hidden stubs
    vim.cmd("enew")
    for _, lhs in ipairs({ " rx", " rq" }) do
      local g = vim.fn.maparg(lhs, "n", false, true)
      H.not_ok(g.rhs and g.rhs:find("Macro", 1, true), "global map on <leader>" .. lhs:sub(2))
    end
    H.eq("", vim.fn.maparg("<C-k>", "i"), "no global insert <C-k> from the plugin")
  end)
end)

describe("blink.cmp sources", function()
  it("macro_attrs (above rust-analyzer's items, for Rust, defaults kept) and macro_tools (in the defaults) are registered", function()
    require("lazy").load({ plugins = { "blink.cmp" } })
    local cfg = require("blink.cmp.config")
    local attrs = cfg.sources.providers.macro_attrs
    H.ok(attrs, "provider macro_attrs")
    H.eq("xyno_macros.attrs", attrs.module)
    H.ok((attrs.score_offset or 0) > 50, "score_offset above the lsp source")
    local rust = cfg.sources.per_filetype.rust
    H.has(rust, "macro_attrs")
    H.eq(true, rust.inherit_defaults, "the default sources stay")
    local tools = cfg.sources.providers.macro_tools
    H.ok(tools, "provider macro_tools")
    H.eq("xyno_macros.tools", tools.module)
    H.has(cfg.sources.default, "macro_tools")
    local n = 0
    for _, s in ipairs(cfg.sources.default) do
      n = n + (s == "macro_tools" and 1 or 0)
    end
    H.eq(1, n, "macro_tools once")
  end)
end)

describe("what xynovim keeps on top of the plugin", function()
  it("the snippets follow config/ux.lua's snippets_allowed() (the expression-node check included)", function()
    H.very_lazy()
    local mt = require("xyno_macros.tools")
    local ux = require("config.ux")
    H.eq("function", type(mt.config.snippets_allowed))
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "rust"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fn f() {", "    call(sel", "    x.sel", "    sel", "}" })
    for _, ctx in ipairs({
      { line = "    call(sel", cursor = { 2, 11 }, bufnr = buf }, -- inside call arguments
      { line = "    x.sel", cursor = { 3, 9 }, bufnr = buf }, -- after a dot
      { line = "    sel", cursor = { 4, 7 }, bufnr = buf }, -- statement start
    }) do
      H.eq(ux.snippets_allowed(ctx), mt.snippets_allowed(ctx), ctx.line)
    end
    H.eq(true, mt.snippets_allowed({ line = "    sel", cursor = { 4, 7 }, bufnr = buf }), "statement start offers them")
    H.eq(false, mt.snippets_allowed({ line = "    x.sel", cursor = { 3, 9 }, bufnr = buf }), "after a dot offers none")
  end)

  it("project schemas still come from <workspace>/.xynovim/macro_attrs, not .xyno-macros/attrs", function()
    H.very_lazy()
    local attrs = require("xyno_macros.attrs")
    H.eq(".xynovim/macro_attrs", attrs.config.user_dir)
    local dir = H.tmpdir() .. "/proj"
    vim.fn.mkdir(dir .. "/.xynovim/macro_attrs", "p")
    vim.fn.mkdir(dir .. "/.xyno-macros/attrs", "p")
    local function put(path, key)
      vim.fn.writefile({
        vim.json.encode({
          crate = "serde",
          attributes = { { name = "serde", derives = { "Serialize" }, applies_to = { "container" }, args = { { key = key, kind = "flag", doc = "mine" } } } },
        }),
      }, path)
    end
    put(dir .. "/.xynovim/macro_attrs/serde.json", "old_dir_key")
    put(dir .. "/.xyno-macros/attrs/serde.json", "plugin_dir_key")
    local set = attrs.schemas(dir)
    H.eq({ "old_dir_key" }, vim.tbl_map(function(a)
      return a.key
    end, set.serde.attributes[1].args))
    H.ok(attrs.shipped().tokio, "the schemas the plugin ships are found (tokio)")
  end)

  it("no local copy and no data/ directory are left; the plugin's modules load", function()
    for _, m in ipairs({ "macro_attrs", "macro_tools" }) do
      H.eq(0, vim.fn.filereadable(H.repo .. "/lua/config/" .. m .. ".lua"), "lua/config/" .. m .. ".lua is back")
    end
    H.eq(0, vim.fn.isdirectory(H.repo .. "/data"), "data/ is back")
    for _, m in ipairs({ "attrs", "tools" }) do
      H.ok(pcall(require, "xyno_macros." .. m), "xyno_macros." .. m .. " does not load")
    end
  end)
end)
