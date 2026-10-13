-- Snippets, completion guard and SQL injections: snippets/rust.json,
-- lua/config/ux.lua (snippets_allowed), lua/plugins/editing-ui.lua (blink
-- provider wiring), lua/plugins/no-ghost-text.lua, after/queries/rust/injections.scm
-- and lua/plugins/domain.lua (parsers). No rust-analyzer needed: the buffers
-- are opened with FileType autocmds ignored, so no LSP client starts.
local H = require("xynotest.helpers")
local ux = require("config.ux")

-- ------------------------------------------------------------------ local helpers

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

--- Run fn with FileType autocmds ignored (no rustaceanvim/LSP start).
local function quiet(fn)
  local saved = vim.o.eventignore
  vim.o.eventignore = "FileType"
  local ok, a, b = pcall(fn)
  vim.o.eventignore = saved
  if not ok then
    error(a, 0)
  end
  return a, b
end

--- A scratch buffer of filetype `ft` holding `lines`, made current.
local function scratch(lines, ft)
  return quiet(function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = ft or "rust"
    return buf
  end)
end

--- blink context for the cursor at `|` in `text` (one line, marker removed).
local function allowed(text, ft)
  local col = assert(text:find("|", 1, true)) - 1
  local line = text:gsub("|", "", 1)
  local buf = scratch({ line }, ft)
  if (ft or "rust") == "rust" then
    vim.treesitter.get_parser(buf, "rust"):parse()
  end
  return ux.snippets_allowed({ line = line, cursor = { 1, col }, bufnr = buf })
end

local function sql_regions(src)
  local buf = scratch(vim.split(src, "\n", { plain = true }))
  local parser = vim.treesitter.get_parser(buf, "rust")
  parser:parse(true)
  local out = {}
  for lang, child in pairs(parser:children()) do
    if lang == "sql" then
      for _, region in ipairs(child:included_regions()) do
        for _, r in ipairs(region) do
          local text = vim.api.nvim_buf_get_text(buf, r[1], r[2], r[4], r[5], {})
          out[#out + 1] = table.concat(text, "\n")
        end
      end
    end
  end
  table.sort(out)
  return out
end

local function body(s)
  return "fn f() {\n    " .. s .. "\n}"
end

local function snippets()
  return vim.json.decode(read(H.repo .. "/snippets/rust.json"))
end

local function joined(name)
  return table.concat(snippets()[name].body, "\n")
end

--- Type `typed` at the end of line `row` in insert mode, then run fn() with
--- insert mode still active (so blink works); returns fn's result.
local function in_insert(row, typed, fn)
  local res, err
  _G.__snip_spec_cb = function()
    local ok, e = pcall(function()
      res = fn()
    end)
    if not ok then
      err = e
    end
  end
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  H.feed("A" .. typed .. "<Cmd>lua _G.__snip_spec_cb()<CR><Esc>")
  _G.__snip_spec_cb = nil
  vim.wait(300) -- let blink handle the InsertLeave before the next insert
  if err then
    error(err, 0)
  end
  return res
end

--- Show blink's menu and wait until a snippets item matches; returns the items.
local function menu_items(want_label, typed, timeout)
  local list = require("blink.cmp.completion.list")
  -- drop the menu of an earlier insert so its items cannot be mistaken for this one's
  if require("blink.cmp").is_visible() then
    require("blink.cmp").hide()
  end
  list.items = {}
  require("blink.cmp").show()
  local function fresh()
    return list.context and list.context.line:find(typed, 1, true)
  end
  vim.wait(timeout or 5000, function()
    if not require("blink.cmp").is_visible() or not fresh() then
      return false
    end
    for _, i in ipairs(list.items) do
      if i.label == want_label then
        return true
      end
    end
    return false
  end, 20)
  return require("blink.cmp").is_visible() and fresh() and list.items or {}
end

local function snippet_labels(items)
  local out = {}
  for _, i in ipairs(items) do
    if i.source_id == "snippets" then
      out[#out + 1] = i.label
    end
  end
  return out
end

-- A rust file in a temp dir (no Cargo.toml, FileType ignored), cursor in insert-able lines.
local function open_rust_file()
  local dir = H.tmpdir()
  vim.cmd.cd(vim.fn.fnameescape(dir))
  local path = dir .. "/a.rs"
  vim.fn.writefile({ "fn main() {", "    ", "    ", "}" }, path)
  return quiet(function()
    local buf = H.open(path)
    vim.bo[buf].filetype = "rust"
    -- the first insert loads the plugins hanging off InsertEnter and keys; do it
    -- before the typed text so none of it is replayed into the buffer
    H.feed("A<Esc>")
    vim.wait(500)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fn main() {", "    ", "    ", "}" })
    return buf
  end)
end

local function lazy_opts(name)
  local plugin = require("lazy.core.config").plugins[name]
  return require("lazy.core.plugin").values(plugin, "opts", false)
end

-- ------------------------------------------------------------ snippets/rust.json

local NAMES = {
  ["Test module"] = "testmod",
  ["Test fn"] = "testfn",
  ["Tokio test"] = "ttest",
  ["Tokio main"] = "tmain",
  ["impl Display"] = "impldisp",
  ["impl From"] = "implfrom",
  ["Derive common"] = "dcommon",
}

describe("snippets/rust.json", function()
  it("is valid JSON with exactly the 7 snippets, each with prefix, body (array) and description", function()
    local ok, data = pcall(vim.json.decode, read(H.repo .. "/snippets/rust.json"))
    H.ok(ok, "invalid JSON: " .. tostring(data))
    local names = vim.tbl_keys(data)
    table.sort(names)
    local want = vim.tbl_keys(NAMES)
    table.sort(want)
    H.eq(want, names)
    for name, prefix in pairs(NAMES) do
      local s = data[name]
      H.eq(prefix, s.prefix, name .. " prefix")
      H.eq("table", type(s.body), name .. " body")
      H.ok(#s.body >= 1, name .. " body is a non-empty array")
      H.ok(vim.islist(s.body), name .. " body is a list")
      for _, line in ipairs(s.body) do
        H.eq("string", type(line))
      end
      H.eq("string", type(s.description), name .. " description")
      H.ok(s.description ~= "", name .. " description is not empty")
    end
  end)

  it("has the documented bodies", function()
    H.eq(
      "#[cfg(test)]\nmod tests {\n\tuse super::*;\n\n\t#[test]\n\tfn ${1:it_works}() {\n\t\t$0\n\t}\n}",
      joined("Test module")
    )
    H.eq("#[test]\nfn ${1:name}() {\n\t$0\n}", joined("Test fn"))
    H.eq("#[tokio::test]\nasync fn ${1:name}() {\n\t$0\n}", joined("Tokio test"))
    H.eq(
      "#[tokio::main]\nasync fn main() -> ${1:anyhow::Result<()>} {\n\t$0\n\tOk(())\n}",
      joined("Tokio main")
    )
    local disp = joined("impl Display")
    H.has(disp, "impl std::fmt::Display for ${1:Type} {")
    H.has(disp, "fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {")
    H.has(disp, 'write!(f, "${2}")$0')
    local from = joined("impl From")
    H.has(from, "impl From<${1:Source}> for ${2:Target} {")
    H.has(from, "fn from(value: ${1:Source}) -> Self {", "the source type is mirrored")
    H.eq("#[derive(Debug, Clone, PartialEq, Eq)]", joined("Derive common"))
  end)

  it("every body expands as an LSP snippet (vim.snippet.expand) with its defaults filled in", function()
    local expect = {
      ["Test module"] = { "#[cfg(test)]", "mod tests {", "fn it_works() {" },
      ["Test fn"] = { "#[test]", "fn name() {" },
      ["Tokio test"] = { "#[tokio::test]", "async fn name() {" },
      ["Tokio main"] = { "#[tokio::main]", "-> anyhow::Result<()> {", "Ok(())" },
      ["impl Display"] = { "impl std::fmt::Display for Type {", 'write!(f, "")' },
      ["impl From"] = { "impl From<Source> for Target {", "fn from(value: Source) -> Self {" },
      ["Derive common"] = { "#[derive(Debug, Clone, PartialEq, Eq)]" },
    }
    for name, frags in pairs(expect) do
      local buf = scratch({ "" })
      local ok, err = pcall(vim.snippet.expand, joined(name))
      H.ok(ok, name .. ": " .. tostring(err))
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      for _, frag in ipairs(frags) do
        H.has(text, frag, name)
      end
      H.no_match(text, "%$%d", false, name .. " has an unexpanded placeholder")
      vim.snippet.stop()
    end
  end)
end)

-- ---------------------------------------------------------------- blink config

describe("blink.cmp configuration", function()
  it("picks up stdpath('config')/snippets by default; no snippets.search_paths field is set", function()
    local dir = vim.fn.stdpath("config") .. "/snippets"
    H.ok(vim.uv.fs_stat(dir .. "/rust.json"), "snippets/rust.json missing in " .. dir)
    local opts = lazy_opts("blink.cmp")
    H.is_nil(opts.snippets and opts.snippets.search_paths, "top-level snippets.search_paths")
    H.is_nil(opts.sources.providers.snippets.opts and opts.sources.providers.snippets.opts.search_paths)
    -- the registry blink builds scans the config dir and registers our file for rust
    local registry = require("blink.cmp.sources.snippets.default.registry").new(
      vim.tbl_deep_extend("force", { friendly_snippets = false }, opts.sources.providers.snippets.opts or {})
    )
    H.has(registry.config.search_paths, vim.fs.normalize(dir))
    local files = registry.registry.rust or {}
    local found = false
    for _, f in ipairs(files) do
      found = found or f:find("snippets/rust.json", 1, true) ~= nil
    end
    H.ok(found, "rust files in registry: " .. vim.inspect(files))
  end)

  it("re-validating the merged blink opts raises no 'Unexpected field' warning", function()
    local cap = H.capture_notify()
    H.clear_messages()
    require("lazy").load({ plugins = { "blink.cmp" } })
    local ok, err = pcall(require("blink.cmp.config").merge_with, lazy_opts("blink.cmp"))
    cap.restore()
    H.ok(ok, tostring(err))
    local seen = H.messages() .. vim.inspect(cap.list)
    H.no_match(seen, "Unexpected field", true)
  end)

  it("the snippets provider has should_show_items wired to ux.snippets_allowed", function()
    require("lazy").load({ plugins = { "blink.cmp" } })
    local provider = require("blink.cmp.config").sources.providers.snippets
    H.eq("function", type(provider.should_show_items))
    local buf = scratch({ "ok.if" })
    local function call(line, col)
      return provider.should_show_items({ line = line, cursor = { 1, col }, bufnr = buf })
    end
    H.eq(false, call("ok.if", 5))
    H.eq(true, call("ok", 2))
  end)

  it("ghost text is disabled in insert mode and in the cmdline", function()
    require("lazy").load({ plugins = { "blink.cmp" } })
    local cfg = require("blink.cmp.config")
    local ins = cfg.completion.ghost_text.enabled
    if type(ins) == "function" then
      ins = ins()
    end
    H.eq(false, ins, "completion.ghost_text.enabled")
    local cmd = cfg.cmdline.completion.ghost_text.enabled
    if type(cmd) == "function" then
      cmd = cmd()
    end
    H.eq(false, cmd, "cmdline.completion.ghost_text.enabled")
  end)
end)

-- ------------------------------------------------------------ blink menu (insert)

describe("blink menu in a Rust buffer", function()
  it("offers testmod (not tmod: rust-analyzer's own tmod outranked ours), and ttest which expands to the Tokio test snippet", function()
    open_rust_file()
    local labels = in_insert(2, "testm", function()
      return snippet_labels(menu_items("testmod", "testm"))
    end)
    H.has(labels, "testmod")
    local result = in_insert(3, "tte", function()
      local items = menu_items("ttest", "tte")
      local idx
      for i, item in ipairs(items) do
        if item.label == "ttest" and item.source_id == "snippets" then
          idx = i
        end
      end
      H.ok(idx, "ttest in the menu: " .. vim.inspect(snippet_labels(items)))
      require("blink.cmp").accept({ index = idx })
      vim.wait(3000, function()
        return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("#[tokio::test]", 1, true)
      end, 20)
      return {
        text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
        active = vim.snippet.active(),
      }
    end)
    pcall(vim.snippet.stop)
    H.has(result.text, "#[tokio::test]")
    H.has(result.text, "async fn name() {")
    H.eq(true, result.active, "snippet session active (placeholder jumps)")
  end)

  it("friendly-snippets `if` is offered at a statement start but not after `x.`", function()
    open_rust_file()
    local at_start = in_insert(2, "if", function()
      return snippet_labels(menu_items("if", "if"))
    end)
    H.has(at_start, "if", "control: `if` snippet at statement start")
    vim.api.nvim_buf_set_lines(0, 2, 3, false, { "    " })
    local after_dot = in_insert(3, "x.if", function()
      return snippet_labels(menu_items("if", "x.if", 2000))
    end)
    H.eq({}, after_dot, "snippets offered after `x.`")
  end)
end)

-- ------------------------------------------------------ ux.snippets_allowed

describe("ux.snippets_allowed", function()
  it("is false right after a `.` and true after a `..` range", function()
    H.eq(false, allowed("ok.if|"))
    H.eq(false, allowed("x.i|"))
    H.eq(false, allowed("x.|"))
    H.eq(true, allowed("let _ = 0..i|"))
    H.eq(true, allowed("if|"))
  end)

  it("is false inside strings, raw strings, line and block comments; true in plain code", function()
    H.eq(false, allowed('let s = "ab|c";'), "string_literal")
    H.eq(false, allowed('let s = "abc|";'), "just before the closing quote")
    H.eq(false, allowed('let s = r#"ab|c"#;'), "raw_string_literal")
    H.eq(false, allowed("let x = 1; // fo|o"), "line_comment")
    H.eq(false, allowed("/* fo|o */ let x = 1;"), "block_comment")
    H.eq(true, allowed("let x = 1|;"), "plain code")
    H.eq(true, allowed("fn f() { le| }"), "plain code in a body")
  end)

  it("is true just behind the closing quote of a literal on the same line", function()
    H.eq(true, allowed('let s = "abc"|;'))
    H.eq(true, allowed('let s = r#"abc"#|;'))
    H.eq(true, allowed('foo("abc") |'))
  end)

  it("is true when treesitter's get_node errors", function()
    local orig = vim.treesitter.get_node
    vim.treesitter.get_node = function()
      error("no parser")
    end
    local ok, res = pcall(allowed, 'let s = "ab|c";')
    vim.treesitter.get_node = orig
    H.ok(ok, tostring(res))
    H.eq(true, res)
  end)

  it("is true in a non-Rust buffer without string or comment nodes", function()
    H.eq(true, allowed("hello wor|ld", "text"))
    H.eq(true, allowed("local x = 1|", "lua"))
  end)
end)

-- --------------------------------------------------------- injections.scm

local INJ = H.repo .. "/after/queries/rust/injections.scm"

describe("injections.scm", function()
  it("extends the runtime query and parses without error", function()
    local src = read(INJ)
    H.match(src, "^;; extends")
    local ok, q = pcall(vim.treesitter.query.parse, "rust", src)
    H.ok(ok, tostring(q))
    -- the runtime lookup (all files for rust/injections, ours is in after/) parses too
    local files = vim.treesitter.query.get_files("rust", "injections")
    H.ok(#files >= 2, "bundled + after query files: " .. vim.inspect(files))
    local found = false
    for _, f in ipairs(files) do
      found = found or vim.fs.normalize(f):find("after/queries/rust/injections.scm", 1, true) ~= nil
    end
    H.ok(found, "after/queries/rust/injections.scm is on the runtimepath: " .. vim.inspect(files))
    H.ok(vim.treesitter.query.get("rust", "injections"), "merged injections query")
  end)

  it("injects SQL into the string of the sqlx macros (identifier or scoped, plain or raw string)", function()
    local macros = { "query", "query_as", "query_scalar", "query_unchecked", "query_as_unchecked", "query_scalar_unchecked" }
    for _, m in ipairs(macros) do
      for _, prefix in ipairs({ "", "sqlx::" }) do
        local first = m == "query" and "" or "Row, "
        local call = prefix .. m .. "!(" .. first
        H.eq({ "select 1" }, sql_regions(body(call .. '"select 1");')), call .. '"..."')
        H.eq({ "select 2" }, sql_regions(body(call .. 'r#"select 2"#);')), call .. 'r#"..."#')
      end
    end
  end)

  it("no nested Rust layer over the SQL string of a sqlx macro (it painted @string on top of the SQL highlights)", function()
    -- field test: `:Inspect` on SELECT in `query!("SELECT ...")` listed @string.rust twice; the
    -- headless captures-at-pos check passed because the SQL layer was there too. The nested
    -- rust layer (nvim-treesitter parses every macro's token_tree as Rust) is skipped for the
    -- sqlx macros in queries/rust/injections.scm.
    local function rust_layers_over_sql(src)
      local buf = scratch(vim.split(src, "\n", { plain = true }))
      local parser = vim.treesitter.get_parser(buf, "rust")
      parser:parse(true)
      local sql = parser:children().sql
      H.ok(sql, "sql layer exists")
      local srow = sql:included_regions()[1][1][1]
      local n = 0
      for lang, child in pairs(parser:children()) do
        if lang == "rust" then
          for _, region in ipairs(child:included_regions()) do
            for _, r in ipairs(region) do
              if r[1] <= srow and r[4] >= srow then
                n = n + 1
              end
            end
          end
        end
      end
      return n
    end
    H.eq(0, rust_layers_over_sql(body('let s = sqlx::query!("SELECT id FROM users WHERE id = $1", 1);')))
    H.eq(0, rust_layers_over_sql(body('let s = query_as!(Row, "select 1");')))
    -- other macros keep their nested Rust layer
    local buf = scratch(vim.split(body('vec![1, 2];'), "\n", { plain = true }))
    local parser = vim.treesitter.get_parser(buf, "rust")
    parser:parse(true)
    H.ok(parser:children().rust, "vec! token tree is still parsed as Rust")
  end)

  it("injects SQL into the string of the runtime calls query, query_as, query_scalar (also scoped and with turbofish)", function()
    local cases = {
      'query("select 1")',
      'sqlx::query("select 1")',
      'query_as::<_, Row>("select 1")',
      'sqlx::query_as::<_, Row>("select 1")',
      'query_scalar("select 1")',
      'sqlx::query_scalar::<_, i64>("select 1")',
      'query(r#"select 1"#)',
    }
    for _, c in ipairs(cases) do
      H.eq({ "select 1" }, sql_regions(body(c .. ";")), c)
    end
  end)

  it("does not inject into the *_unchecked runtime functions (only the macros have them)", function()
    for _, c in ipairs({
      'query_unchecked("select 1")',
      'sqlx::query_as_unchecked("select 1")',
      'query_scalar_unchecked::<_, i64>("select 1")',
      'execute("select 1")',
    }) do
      H.eq({}, sql_regions(body(c .. ";")), c)
    end
  end)

  it("injects only strings starting with a SQL keyword as a whole word (any case, leading whitespace/newlines)", function()
    local kws = vim.split(
      "select insert update delete with create alter drop replace values pragma begin commit rollback truncate explain vacuum analyze attach detach reindex savepoint release set show grant revoke call merge lock",
      " "
    )
    H.eq(30, #kws)
    local calls, want = {}, {}
    for i, kw in ipairs(kws) do
      local text = (i % 3 == 0 and kw:upper()) or (i % 3 == 1 and kw) or (kw:sub(1, 1):upper() .. kw:sub(2))
      calls[#calls + 1] = 'query("' .. text .. ' x");'
      want[#want + 1] = text .. " x"
    end
    table.sort(want)
    H.eq(want, sql_regions(body(table.concat(calls, "\n    "))))

    -- not SQL: bind arguments, prose, a keyword that is only a prefix of a word
    H.eq({}, sql_regions(body('query("not sql here");')))
    H.eq({}, sql_regions(body('query("selection");')))
    H.eq({}, sql_regions(body('query("settings");')))
    H.eq({}, sql_regions(body('query("set_x");')))
    H.eq({}, sql_regions(body('query("");')))
    H.eq({}, sql_regions(body('query("   ");')))
    -- the bind argument "alice" next to the statement is left alone
    H.eq({ "select 1" }, sql_regions(body('query!("select 1", "alice");')))
    H.eq({ "select $1" }, sql_regions(body('query_as!(User, "select $1", "alice");')))

    -- leading newline/indent, multi-line statement
    local multi = "\n        UPDATE users\n        SET name = $1\n        WHERE id = $2"
    local got = sql_regions(body('query("' .. multi .. '");'))
    H.eq({ multi }, got)
    H.eq({ "  \tselect 1" }, sql_regions(body('query("  \tselect 1");')))
  end)

  it("tests/fixtures/sql_and_routes.rs: sql children for the query! string and the multi-line query string", function()
    local src = read(H.fixtures .. "/sql_and_routes.rs")
    local got = sql_regions(src)
    H.eq(2, #got)
    local texts = table.concat(got, "\n---\n")
    H.has(texts, "SELECT id, name FROM users WHERE id = $1")
    H.has(texts, "UPDATE users\n         SET name = $1\n         WHERE id = $2")
    -- the route strings and "ok" are not SQL
    H.no_match(texts, "/health", true)
  end)

  it("known imprecision: any macro or function named query is injected (other::query!(\"select 2\"))", function()
    H.eq({ "select 2" }, sql_regions(body('other::query!("select 2");')))
    H.eq({ "select 2" }, sql_regions(body('other::query("select 2");')))
    H.eq({ "select 2" }, sql_regions(body('my::inner::query!("select 2");')))
  end)
end)

-- ------------------------------------------------------- parsers and extras

describe("treesitter parsers and extras", function()
  it("installs rust, sql, wgsl, toml, yaml, markdown, json, http; ensure_installed includes sql and wgsl", function()
    local ensure = lazy_opts("nvim-treesitter").ensure_installed
    H.has(ensure, "sql")
    H.has(ensure, "wgsl")
    local dir = vim.fn.stdpath("data") .. "/site/parser"
    local ok, d = pcall(function()
      return require("nvim-treesitter.config").get_install_dir("parser")
    end)
    if ok and d then
      dir = d
    end
    for _, lang in ipairs({ "rust", "sql", "wgsl", "toml", "yaml", "markdown", "json", "http" }) do
      H.ok(vim.uv.fs_stat(dir .. "/" .. lang .. ".so"), lang .. ".so missing in " .. dir)
      local loaded, err = pcall(vim.treesitter.language.add, lang)
      H.ok(loaded, lang .. ": " .. tostring(err))
    end
  end)

  it("lang.sql (dadbod) is not enabled", function()
    local extras = vim.json.decode(read(H.repo .. "/lazyvim.json")).extras
    for _, e in ipairs(extras) do
      H.no_match(e, "lang.sql", true)
    end
    local lock = read(H.repo .. "/lazy-lock.json")
    H.no_match(lock, "dadbod", true)
    H.is_nil(require("lazy.core.config").plugins["vim-dadbod"])
  end)

  it("treesitter-context (3 lines) and navic breadcrumb config load without errors", function()
    H.eq(3, lazy_opts("nvim-treesitter-context").max_lines)
    H.eq("cursor", lazy_opts("nvim-treesitter-context").mode)
    require("lazy").load({ plugins = { "nvim-treesitter-context" } })
    H.eq(3, require("treesitter-context.config").max_lines)

    local navic = lazy_opts("nvim-navic")
    H.eq(5, navic.depth_limit)
    H.eq(true, navic.highlight)
    H.eq(true, navic.lazy_update_context)
    require("lazy").load({ plugins = { "nvim-navic" } })
    H.eq("function", type(require("nvim-navic").attach))

    -- LazyVim adds the navic component only when Trouble's symbols are not the breadcrumb
    local c = lazy_opts("lualine.nvim").sections.lualine_c
    local has_navic = false
    for _, comp in ipairs(c) do
      has_navic = has_navic or comp == "navic" or (type(comp) == "table" and comp[1] == "navic")
    end
    H.eq(not vim.g.trouble_lualine, has_navic, "lualine navic component matches vim.g.trouble_lualine")
  end)
end)
