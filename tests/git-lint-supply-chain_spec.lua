-- lua/plugins/diffview.lua, gitsigns.lua, supply-chain.lua (nvim-lint sources:
-- cargo-deny, cargo-machete, actionlint, zizmor). coverage.lua is covered by
-- dap-neotest-coverage_spec.lua. Parser/condition units use canned output and
-- need no tool; the integration tests skip when the tool (or the cached
-- advisory DB) is missing. Global git config (mergiraf, delta, zdiff3, rerere,
-- dft/dlog aliases) and the README per-repo opt-ins live outside the repo and
-- are not testable here (see the pending tests at the end).
local H = require("xynotest.helpers")

local SEV = vim.diagnostic.severity

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(type(lines) == "table" and lines or vim.split(lines, "\n", { plain = true }), path)
end

local function linter(name)
  require("lazy").load({ plugins = { "nvim-lint" } })
  return H.ok(require("lint").linters[name], "linter " .. name)
end

--- A scratch buffer named `path` (never written) holding `lines`.
local function named_buf(path, lines)
  local old = vim.fn.bufnr(path)
  if old ~= -1 then
    vim.api.nvim_buf_delete(old, { force = true })
  end
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(b, path)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function plugin(name)
  return require("lazy.core.config").plugins[name]
end

local function json_lines(list)
  local out = {}
  for _, t in ipairs(list) do
    out[#out + 1] = type(t) == "string" and t or vim.json.encode(t)
  end
  return table.concat(out, "\n") .. "\n"
end

local function diag(fields)
  return { type = "diagnostic", fields = fields }
end

local function by_source(bufnr, source)
  return H.diagnostics(source, bufnr)
end

-- ------------------------------------------------------------------ diffview

describe("diffview.nvim", function()
  it("is lazy on its four commands with the diff3_mixed / enhanced_diff_hl opts", function()
    local p = H.ok(plugin("diffview.nvim"), "diffview.nvim spec")
    H.eq({ "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory", "DiffviewToggleFiles" }, p.cmd)
    H.eq(true, p.opts.enhanced_diff_hl)
    H.eq("diff3_mixed", p.opts.view.merge_tool.layout)
    H.eq(2, vim.fn.exists(":DiffviewOpen"), "command stub exists")
  end)

  it(":DiffviewOpen on a repo with a change opens a file-panel tab", function()
    local dir = H.tmpdir()
    write(dir .. "/a.txt", { "one", "two" })
    H.git_init(dir)
    write(dir .. "/a.txt", { "one", "TWO", "three" })
    vim.cmd.cd(vim.fn.fnameescape(dir))
    H.open(dir .. "/a.txt")
    local tabs = vim.fn.tabpagenr("$")
    vim.cmd("DiffviewOpen")
    H.wait_for(function()
      return vim.fn.tabpagenr("$") > tabs
    end, 15000, "a new tab")
    H.wait_for(function()
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "DiffviewFiles" then
          return true
        end
      end
    end, 15000, "the Diffview file panel")
    vim.cmd("DiffviewClose")
    H.wait_for(function()
      return vim.fn.tabpagenr("$") == tabs
    end, 5000, "tab closed")
  end)

  describe("<leader>gV base selection", function()
    local function scratch_repo()
      local dir = H.tmpdir()
      write(dir .. "/f.txt", { "x" })
      H.git_init(dir)
      vim.cmd.cd(vim.fn.fnameescape(dir))
      H.open(dir .. "/f.txt")
      return dir
    end

    --- Press <leader>gV with vim.cmd and notify stubbed. Returns the
    --- DiffviewOpen command lines issued and the notifications.
    local function press()
      local cap = H.capture_notify()
      local cmds = {}
      local orig = vim.cmd
      vim.cmd = setmetatable({}, {
        __index = orig,
        __call = function(_, c, ...)
          if type(c) == "string" and c:find("^Diffview") then
            cmds[#cmds + 1] = c
            return
          end
          return orig(c, ...)
        end,
      })
      local ok, err = pcall(H.feed, "<leader>gV")
      vim.cmd = orig
      cap.restore()
      H.ok(ok, tostring(err))
      return cmds, cap.list
    end

    it("origin/HEAD wins over origin/main and origin/master", function()
      local dir = scratch_repo()
      for _, r in ipairs({ "main", "master" }) do
        H.git(dir, "update-ref", "refs/remotes/origin/" .. r, "HEAD")
      end
      H.git(dir, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master")
      local cmds = press()
      H.eq({ "DiffviewOpen origin/HEAD...HEAD" }, cmds)
    end)

    it("origin/main wins over origin/master", function()
      local dir = scratch_repo()
      for _, r in ipairs({ "main", "master" }) do
        H.git(dir, "update-ref", "refs/remotes/origin/" .. r, "HEAD")
      end
      H.eq({ "DiffviewOpen origin/main...HEAD" }, (press()))
    end)

    it("origin/master is used when it is the only one", function()
      local dir = scratch_repo()
      H.git(dir, "update-ref", "refs/remotes/origin/master", "HEAD")
      H.eq({ "DiffviewOpen origin/master...HEAD" }, (press()))
    end)

    it("outside a git repository: WARN `not a git repository`, not `no origin`", function()
      local dir = H.tmpdir()
      write(dir .. "/f.txt", { "x" })
      vim.cmd.cd(vim.fn.fnameescape(dir))
      H.open(dir .. "/f.txt")
      local cmds, notes = press()
      H.eq({}, cmds)
      H.eq(1, #notes)
      H.match(notes[1].msg, "not a git repository", true)
    end)

    it("without any origin ref: one WARN notification, no DiffviewOpen, no git error", function()
      scratch_repo()
      H.clear_messages()
      local cmds, notes = press()
      H.eq({}, cmds)
      H.eq(1, #notes)
      H.eq(vim.log.levels.WARN, notes[1].level)
      H.match(notes[1].msg, "no origin/HEAD, origin/main or origin/master", true)
      H.no_match(H.messages(), "fatal", true)
      H.no_match(notes[1].msg, "fatal", true)
    end)
  end)
end)

-- ------------------------------------------------------------------ gitsigns

describe("gitsigns attach_to_untracked", function()
  local function sign_count(bufnr)
    local ns = vim.api.nvim_get_namespaces()["gitsigns_signs_"]
    if not ns then
      return 0
    end
    return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  end

  local function untracked_repo()
    local dir = H.tmpdir()
    H.git(dir, "init", "-q", "-b", "main") -- no commit at all
    write(dir .. "/new.txt", { "a", "b", "c" })
    vim.cmd.cd(vim.fn.fnameescape(dir))
    return dir
  end

  it("the plugin opts set it to true", function()
    H.eq(true, H.ok(plugin("gitsigns.nvim"), "gitsigns spec").opts.attach_to_untracked)
  end)

  it("an untracked file in a repo without commits gets 3 signs; 0 without the override", function()
    local dir = untracked_repo()
    local b = H.open(dir .. "/new.txt")
    H.wait_for(function()
      return sign_count(b) == 3
    end, 15000, "3 gitsigns extmarks on the untracked file")

    -- same file with the default (false): nothing attaches
    local gs = require("gitsigns")
    gs.detach(b)
    local cfg = require("gitsigns.config").config
    cfg.attach_to_untracked = false
    local ok, err = pcall(function()
      gs.attach(b)
      vim.wait(2500, function()
        return sign_count(b) > 0
      end, 50)
      H.eq(0, sign_count(b), "signs without attach_to_untracked")
    end)
    cfg.attach_to_untracked = true
    H.ok(ok, tostring(err))
  end)
end)

-- ---------------------------------------------------- supply-chain: config

describe("supply-chain linters_by_ft", function()
  it("toml and yaml linters", function()
    linter("cargo_deny")
    local lint = require("lint")
    H.eq({ "cargo_deny", "cargo_machete" }, lint.linters_by_ft.toml)
    H.eq({ "actionlint", "zizmor" }, lint.linters_by_ft.yaml)
  end)
end)

describe("actionlint / zizmor condition", function()
  for _, name in ipairs({ "actionlint", "zizmor" }) do
    it(name .. " only runs under /.github/workflows/", function()
      local l = linter(name)
      local function cond(f)
        return l.condition({ filename = f, dirname = vim.fs.dirname(f) })
      end
      H.ok(cond("/p/.github/workflows/ci.yml"))
      H.ok(cond("/p/.github/workflows/sub/x.yaml"))
      H.not_ok(cond("/p/ci.yml"))
      H.not_ok(cond("/p/docker-compose.yaml"))
      H.not_ok(cond("/p/.github/dependabot.yml"))
      H.not_ok(cond("/p/github/workflows/ci.yml"))
    end)
  end
end)

describe("cargo_deny condition", function()
  local function cond(f)
    return linter("cargo_deny").condition({ filename = f, dirname = vim.fs.dirname(f) })
  end

  it("Cargo.toml / Cargo.lock with a deny.toml upward", function()
    local d = H.tmpdir()
    write(d .. "/Cargo.toml", "")
    write(d .. "/Cargo.lock", "")
    write(d .. "/other.toml", "")
    write(d .. "/rustfmt.toml", "")
    H.not_ok(cond(d .. "/Cargo.toml"), "no deny.toml yet")
    write(d .. "/deny.toml", "")
    H.ok(cond(d .. "/Cargo.toml"))
    H.ok(cond(d .. "/Cargo.lock"))
    H.not_ok(cond(d .. "/rustfmt.toml"), "plain .toml never")
    H.not_ok(cond(d .. "/deny.toml"), "not even deny.toml")
    write(d .. "/sub/deeper/Cargo.toml", "")
    H.ok(cond(d .. "/sub/deeper/Cargo.toml"), "found upward")
  end)

  it("also accepts .cargo/deny.toml", function()
    local d = H.tmpdir()
    write(d .. "/m/Cargo.toml", "")
    H.not_ok(cond(d .. "/m/Cargo.toml"))
    write(d .. "/m/.cargo/deny.toml", "")
    H.ok(cond(d .. "/m/Cargo.toml"))
  end)
end)

describe("cargo_deny config", function()
  it("cmd, flags and resolved args", function()
    local l = linter("cargo_deny")
    H.eq("cargo", l.cmd)
    H.eq(false, l.stdin)
    H.eq(false, l.append_fname)
    H.eq("stderr", l.stream)
    H.eq(true, l.ignore_exitcode)
    local d = H.tmpdir()
    write(d .. "/Cargo.toml", "")
    H.open(d .. "/Cargo.toml")
    local args = vim.tbl_map(function(a)
      return type(a) == "function" and a() or a
    end, l.args)
    H.eq(
      { "deny", "--manifest-path", d .. "/Cargo.toml", "--offline", "--format", "json", "check", "advisories", "bans" },
      args
    )
  end)
end)

-- ------------------------------------------------------ cargo_deny parser

describe("cargo_deny parser", function()
  local TOML = {
    "[package]",
    'name = "p"',
    "",
    "[dependencies]",
    'time = "=0.1.45"',
    '  serde = { version = "1" }',
    "",
    "[dependencies.regex]",
    'version = "1"',
    "[dev-dependencies.foo-bar]",
    'version = "1"',
    'serde_json = "1"',
    "",
    'wild = "*"',
  }
  local d = H.tmpdir()
  local function parse(file, lines, out)
    local b = named_buf(d .. "/" .. file, lines or {})
    return linter("cargo_deny").parser(out, b), b
  end

  it("maps a diagnostic: source, code, message plus ' - label message'", function()
    local r = parse(
      "Cargo.toml",
      TOML,
      json_lines({
        diag({
          severity = "error",
          code = "vulnerability",
          message = "Potential segfault",
          labels = { { line = 5, column = 1, message = "security vulnerability detected" } },
          graphs = { { Krate = { name = "time", version = "0.1.45" } } },
        }),
      })
    )
    H.eq(1, #r)
    H.eq("cargo-deny", r[1].source)
    H.eq("vulnerability", r[1].code)
    H.eq("Potential segfault - security vulnerability detected", r[1].message)
    H.eq(SEV.ERROR, r[1].severity)
  end)

  it("message has no suffix without a label message", function()
    local r = parse(
      "Cargo.toml",
      TOML,
      json_lines({ diag({ severity = "warning", code = "x", message = "plain", labels = {} }) })
    )
    H.eq("plain", r[1].message)
    H.eq(0, r[1].lnum)
  end)

  it("severities error/warning/note/help -> ERROR/WARN/INFO/HINT, unknown -> WARN", function()
    local list = {}
    for _, s in ipairs({ "error", "warning", "note", "help", "bogus" }) do
      list[#list + 1] = diag({ severity = s, code = s, message = s })
    end
    local r = parse("Cargo.toml", TOML, json_lines(list))
    H.eq({ SEV.ERROR, SEV.WARN, SEV.INFO, SEV.HINT, SEV.WARN }, vim.tbl_map(function(x)
      return x.severity
    end, r))
  end)

  it("Cargo.lock: lnum/col are label.line/column minus 1", function()
    local r = parse(
      "Cargo.lock",
      { "x" },
      json_lines({
        diag({
          severity = "error",
          code = "vulnerability",
          message = "m",
          labels = { { line = 12, column = 4, message = "l" } },
          graphs = { { Krate = { name = "time", version = "1" } } },
        }),
      })
    )
    H.eq(11, r[1].lnum)
    H.eq(3, r[1].col)
  end)

  it("Cargo.lock: the line is the `name = ...` of the package with that name and version", function()
    local lock = {
      "# This file is automatically @generated by Cargo.",
      "version = 4",
      "",
      "[[package]]",
      'name = "libc"',
      'version = "0.2.1"',
      "",
      "[[package]]",
      'name = "time"',
      'version = "0.1.44"',
      "",
      "[[package]]",
      'name = "time"',
      'version = "0.1.45"',
    }
    local r = parse(
      "Cargo.lock",
      lock,
      json_lines({
        diag({
          severity = "error",
          code = "vulnerability",
          message = "m",
          labels = { { line = 5, column = 1, message = "l" } }, -- cargo-deny's synthetic rendering: line 5 is libc
          graphs = { { Krate = { name = "time", version = "0.1.45" } } },
        }),
      })
    )
    H.eq(12, r[1].lnum)
    H.eq(0, r[1].col)
  end)

  it("a `log` entry with level ERROR (broken deny.toml, unreachable source) becomes a line-0 WARN 'deny-failed'", function()
    local r = parse(
      "Cargo.toml",
      TOML,
      json_lines({
        { type = "log", fields = { level = "INFO", message = "just chatter" } },
        { type = "log", fields = { level = "ERROR", message = "failed to parse config from 'deny.toml'" } },
      })
    )
    H.eq(1, #r)
    H.eq(0, r[1].lnum)
    H.eq(SEV.WARN, r[1].severity)
    H.eq("cargo-deny", r[1].source)
    H.eq("deny-failed", r[1].code)
    H.match(r[1].message, "failed to parse config", true)
  end)

  it("a JSON `null` line (vim.NIL is truthy) does not crash the parser", function()
    local r = parse("Cargo.toml", TOML, "null\n" .. json_lines({ diag({ severity = "note", code = "ok", message = "kept" }) }))
    H.eq(1, #r)
  end)

  it("Cargo.toml: a wildcard label past the end of a short manifest (virtual workspace root) is clamped", function()
    local r = parse(
      "Cargo.toml",
      { "[workspace]", 'members = ["app"]', 'resolver = "2"' },
      json_lines({
        diag({
          severity = "error",
          code = "wildcard",
          message = "w",
          labels = { { line = 6, column = 8, message = "wildcard dependency" } },
          graphs = { { Krate = { name = "app", version = "0.1.0" } } },
        }),
      })
    )
    H.eq(2, r[1].lnum)
  end)

  it("Cargo.lock: code 'wildcard' is skipped, others kept", function()
    local r = parse(
      "Cargo.lock",
      { "x" },
      json_lines({
        diag({ severity = "error", code = "wildcard", message = "w", labels = { { line = 3, column = 3 } } }),
        diag({ severity = "warning", code = "unmaintained", message = "u", labels = { { line = 3, column = 3 } } }),
      })
    )
    H.eq(1, #r)
    H.eq("unmaintained", r[1].code)
  end)

  it("Cargo.toml: lnum from the dependency line of graphs[1].Krate.name", function()
    local function line_of(name)
      local r = parse(
        "Cargo.toml",
        TOML,
        json_lines({
          diag({
            severity = "error",
            code = "vulnerability",
            message = "m",
            labels = { { line = 99, column = 9, message = "l" } }, -- lock coordinates, must be ignored
            graphs = { { Krate = { name = name, version = "1" } } },
          }),
        })
      )
      return r[1].lnum, r[1].col
    end
    H.eq(4, (line_of("time")))
    H.eq(5, (line_of("serde")), "indented dep, not serde_json")
    H.eq(7, (line_of("regex")), "[dependencies.regex]")
    H.eq(9, (line_of("foo-bar")), "[dev-dependencies.foo-bar] (magic chars escaped)")
    H.eq(11, (line_of("serde_json")))
    H.eq(0, (line_of("libc")), "transitive / unknown crate")
    H.eq(0, (line_of("serd")), "no prefix match")
    local _, col = line_of("time")
    H.eq(0, col)
  end)

  it("Cargo.toml: no graphs -> line 0", function()
    local r = parse("Cargo.toml", TOML, json_lines({ diag({ severity = "error", code = "x", message = "m" }) }))
    H.eq(0, r[1].lnum)
  end)

  it("Cargo.toml: wildcard uses label.line-1 / label.column-1", function()
    local r = parse(
      "Cargo.toml",
      TOML,
      json_lines({
        diag({
          severity = "error",
          code = "wildcard",
          message = "found 1 wildcard dependency for crate 'p'",
          labels = { { line = 14, column = 10, message = "wildcard dependency" } },
          graphs = { { Krate = { name = "p", version = "0.1.0" } } },
        }),
      })
    )
    H.eq(13, r[1].lnum)
    H.eq(9, r[1].col)
    H.match(r[1].message, "wildcard dependency", true)
  end)

  it("ignores malformed lines, summaries, blanks and non-diagnostics", function()
    local r = parse(
      "Cargo.toml",
      TOML,
      "not json at all\n\n{broken\n"
        .. json_lines({
          { type = "summary", fields = { advisories = {} } },
          diag({ severity = "note", code = "ok", message = "kept" }),
          "[1,2,3]",
        })
    )
    H.eq(1, #r)
    H.eq("kept", r[1].message)
    H.eq({}, parse("Cargo.toml", TOML, ""))
  end)
end)

-- ---------------------------------------------------- cargo_machete

describe("cargo_machete", function()
  it("condition: Cargo.toml only", function()
    local l = linter("cargo_machete")
    local function cond(f)
      return l.condition({ filename = f, dirname = vim.fs.dirname(f) })
    end
    H.ok(cond("/p/Cargo.toml"))
    H.not_ok(cond("/p/Cargo.lock"))
    H.not_ok(cond("/p/rustfmt.toml"))
    H.not_ok(cond("/p/sub/deny.toml"))
  end)

  it("config: cmd, append_fname=false, ignore_exitcode, args = manifest dir", function()
    local l = linter("cargo_machete")
    H.eq("cargo-machete", l.cmd)
    H.eq(false, l.stdin)
    H.eq(false, l.append_fname)
    H.eq(true, l.ignore_exitcode)
    H.eq(1, #l.args)
    local d = H.tmpdir()
    write(d .. "/Cargo.toml", "")
    H.open(d .. "/Cargo.toml")
    H.eq(d, l.args[1]())
  end)

  describe("parser", function()
    local d = H.tmpdir()
    local MANIFEST = { "[package]", 'name = "p"', "", "[dependencies]", 'time = "1"', 'serde = "1"', 'other = "1"' }

    local function parse(file, output)
      local b = named_buf(d .. "/" .. file, MANIFEST)
      return linter("cargo_machete").parser(output, b)
    end

    local function msgs(r)
      return vim.tbl_map(function(x)
        return x.message
      end, r)
    end

    it("two crates, relative './' paths: only this buffer's manifest", function()
      local out = table.concat({
        "Analyzing dependencies of crates in " .. d .. "...",
        "cargo-machete found the following unused dependencies in " .. d .. ":",
        "p -- ./Cargo.toml:",
        "\tserde",
        "\ttime",
        "",
        "q -- ./sub/Cargo.toml:",
        "\tother",
        "",
        "If you believe cargo-machete has detected an unused dependency incorrectly,",
        "you can add the dependency to the list of dependencies to ignore in the",
        "`[package.metadata.cargo-machete]` section of the appropriate Cargo.toml.",
        "",
        "Done!",
        "",
      }, "\n")
      local r = parse("Cargo.toml", out)
      H.eq({ "unused dependency `serde`", "unused dependency `time`" }, msgs(r))
      for _, x in ipairs(r) do
        H.eq("cargo-machete", x.source)
        H.eq(SEV.WARN, x.severity)
        H.eq(0, x.col)
      end
      H.eq({ 5, 4 }, { r[1].lnum, r[2].lnum }, "dep_line of each dependency")
    end)

    it("absolute paths: matches own manifest, ignores a sibling's", function()
      local out = table.concat({
        "p -- " .. d .. "/Cargo.toml:",
        "\ttime",
        "q -- " .. d .. "/sub/Cargo.toml:",
        "\tserde",
        "\tother",
      }, "\n")
      H.eq({ "unused dependency `time`" }, msgs(parse("Cargo.toml", out)))
    end)

    it("a dependency missing from the manifest lands on line 0; no findings -> empty", function()
      local r = parse("Cargo.toml", "p -- " .. d .. "/Cargo.toml:\n\tghost\n")
      H.eq(0, r[1].lnum)
      H.eq({}, parse("Cargo.toml", "Analyzing dependencies...\nDone!\n"))
      H.eq({}, parse("Cargo.toml", ""))
    end)

    it("a single section is not doubled", function()
      local r = parse("Cargo.toml", "p -- ./Cargo.toml:\n\ttime\n")
      H.eq(1, #r)
    end)
  end)
end)

-- ------------------------------------------------------ integration helpers

local function need_tool(name)
  if vim.fn.executable(name) ~= 1 then
    skip(name .. " not installed")
  end
end

--- Diagnostics from nvim-lint for `names`, waiting until `pred(list)` holds.
local function lint_until(bufnr, name, source, pred, msg)
  vim.api.nvim_set_current_buf(bufnr)
  require("lint").try_lint(name)
  return H.wait_for(function()
    local l = by_source(bufnr, source)
    return pred(l) and l
  end, 120000, msg)
end

--- A scratch crate depending on time =0.1.45 (RUSTSEC-2020-0071) and a
--- wildcard serde, with a deny.toml; lockfile generated offline from the
--- local registry cache (skips the test when that is impossible).
local function deny_crate()
  need_tool("cargo")
  local d = H.tmpdir()
  write(d .. "/Cargo.toml", {
    "[package]",
    'name = "p"',
    'version = "0.1.0"',
    'edition = "2021"',
    "",
    "[dependencies]",
    'time = "=0.1.45"',
    'serde = "*"',
  })
  write(d .. "/src/main.rs", "fn main() {}")
  write(d .. "/deny.toml", { "[advisories]", "[bans]", 'wildcards = "deny"' })
  local r = vim.system({ "cargo", "generate-lockfile", "--offline" }, { cwd = d, text = true }):wait(60000)
  if r.code ~= 0 then
    skip("cargo generate-lockfile --offline failed (time 0.1.45 not in the local registry cache): " .. vim.trim(r.stderr))
  end
  return d
end

--- Raw cargo-deny diagnostics, or skip when the advisory DB is not cached.
local function raw_deny(d)
  local r = vim.system(
    { "cargo", "deny", "--manifest-path", d .. "/Cargo.toml", "--offline", "--format", "json", "check", "advisories", "bans" },
    { cwd = d, text = true }
  ):wait(120000)
  local out = {}
  for line in vim.gsplit(r.stderr or "", "\n", { plain = true, trimempty = true }) do
    local ok, j = pcall(vim.json.decode, line)
    if ok and type(j) == "table" and j.type == "diagnostic" then
      out[#out + 1] = j.fields
    end
  end
  local vuln
  for _, f in ipairs(out) do
    if f.advisory and f.advisory.id == "RUSTSEC-2020-0071" then
      vuln = f
    end
  end
  if not vuln then
    skip("cargo-deny reports no RUSTSEC-2020-0071 offline (advisory DB not cached?): " .. (r.stderr or ""):sub(1, 200))
  end
  return out, vuln
end

local function line_index(file, pat)
  for i, l in ipairs(vim.fn.readfile(file)) do
    if l:find(pat) then
      return i - 1
    end
  end
end

-- ------------------------------------------------------ integration: deny

describe("integration: cargo-deny", function()
  before_each(function()
    need_tool("cargo-deny")
  end)

  it("Cargo.toml: RUSTSEC-2020-0071 on the `time` line, wildcard on the serde line", function()
    local d = deny_crate()
    local _, vuln = raw_deny(d)
    local b = H.open(d .. "/Cargo.toml")
    local l = lint_until(b, "cargo_deny", "cargo-deny", function(x)
      return #x >= 2
    end, "cargo-deny diagnostics on Cargo.toml")
    local v, w
    for _, x in ipairs(l) do
      if x.code == "vulnerability" then
        v = x
      elseif x.code == "wildcard" then
        w = x
      end
    end
    H.ok(v, "vulnerability diagnostic")
    H.eq(line_index(d .. "/Cargo.toml", "^time ="), v.lnum)
    H.eq(SEV.ERROR, v.severity)
    H.match(v.message, vuln.message, true)
    H.ok(w, "wildcard diagnostic")
    H.eq(line_index(d .. "/Cargo.toml", "^serde ="), w.lnum)
    H.eq(9, w.col, "column of the `*` span (label.column 10 - 1)")
  end)

  it("Cargo.lock: reported on the package, wildcard skipped", function()
    local d = deny_crate()
    raw_deny(d)
    local b = H.open(d .. "/Cargo.lock")
    local l = lint_until(b, "cargo_deny", "cargo-deny", function(x)
      return #x >= 1
    end, "cargo-deny diagnostics on Cargo.lock")
    H.eq(1, #l, "only the advisory: wildcard is skipped on the lockfile")
    H.eq("vulnerability", l[1].code)
    -- cargo-deny labels a synthetic rendering of the lockfile (line 5 was the
    -- first [[package]]): the line comes from the crate name and version
    local name_line = H.ok(line_index(d .. "/Cargo.lock", '^name = "time"'))
    H.eq(name_line, l[1].lnum)
  end)

  it("a broken deny.toml gives a deny-failed diagnostic instead of silence", function()
    local d = deny_crate()
    write(d .. "/deny.toml", "this is [[ broken")
    local b = H.open(d .. "/Cargo.toml")
    local l = lint_until(b, "cargo_deny", "cargo-deny", function(x)
      return #x >= 1
    end, "cargo-deny failure diagnostic")
    H.eq("deny-failed", l[1].code)
    H.eq(SEV.WARN, l[1].severity)
    H.match(l[1].message, "failed to parse config", true)
  end)
end)

-- ------------------------------------------------------ integration: machete

describe("integration: cargo-machete", function()
  it("flags both unused deps once each in a scratch crate", function()
    need_tool("cargo-machete")
    local d = H.tmpdir()
    write(d .. "/Cargo.toml", {
      "[package]",
      'name = "p"',
      'version = "0.1.0"',
      'edition = "2021"',
      "",
      "[dependencies]",
      'serde = "1"',
      'time = "0.1"',
    })
    write(d .. "/src/main.rs", "fn main() {}")
    local b = H.open(d .. "/Cargo.toml")
    local l = lint_until(b, "cargo_machete", "cargo-machete", function(x)
      return #x >= 2
    end, "cargo-machete diagnostics")
    vim.wait(1500) -- a doubled run would add more
    l = by_source(b, "cargo-machete")
    table.sort(l, function(a, c)
      return a.lnum < c.lnum
    end)
    H.eq(2, #l, "findings are not doubled")
    H.eq("unused dependency `serde`", l[1].message)
    H.eq(6, l[1].lnum)
    H.eq("unused dependency `time`", l[2].message)
    H.eq(7, l[2].lnum)
    H.eq(SEV.WARN, l[1].severity)
  end)
end)

-- ------------------------------------------------------ integration: workflows

describe("integration: actionlint / zizmor", function()
  local BAD = {
    "name: bad",
    "on: push",
    "jobs:",
    "  build:",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - uses: actions/checkout@v4",
    "      - run: echo ${{ github.event.head_commit.message }} ${{ nope.x }}",
  }

  --- Spy on nvim-lint's try_lint to see which linters the LazyVim wrapper picks.
  local function spy()
    require("lazy").load({ plugins = { "nvim-lint" } })
    local lint = require("lint")
    local orig = lint.try_lint
    local calls = {}
    lint.try_lint = function(names, ...)
      calls[#calls + 1] = names
      return orig(names, ...)
    end
    H._restore[#H._restore + 1] = function()
      lint.try_lint = orig
    end
    return calls
  end

  it("report on a bad workflow (events: BufReadPost)", function()
    need_tool("actionlint")
    need_tool("zizmor")
    local d = H.tmpdir()
    write(d .. "/.github/workflows/bad.yml", BAD)
    spy()
    local b = H.open(d .. "/.github/workflows/bad.yml")
    H.eq("yaml", vim.bo[b].filetype)
    H.wait_for(function()
      return #by_source(b, "actionlint") > 0 and #by_source(b, "zizmor") > 0
    end, 60000, "actionlint and zizmor diagnostics")
    local a = by_source(b, "actionlint")
    H.eq(7, a[1].lnum, "actionlint reports the `run:` line")
    H.match(a[1].source, "^actionlint")
    for _, x in ipairs(by_source(b, "zizmor")) do
      H.ok(x.code, "zizmor diagnostics carry the audit id")
    end
  end)

  it("never run on a plain Cargo-less toml or a non-workflow yml/yaml", function()
    local d = H.tmpdir()
    write(d .. "/rustfmt.toml", { 'edition = "2021"' })
    write(d .. "/compose.yml", BAD)
    write(d .. "/other.yaml", BAD)
    write(d .. "/.github/dependabot.yml", BAD)
    local calls = spy()
    for _, f in ipairs({ "rustfmt.toml", "compose.yml", "other.yaml", ".github/dependabot.yml" }) do
      local b = H.open(d .. "/" .. f)
      vim.wait(1200, function() -- the autocmd debounces 100 ms
        return false
      end)
      H.eq({}, by_source(b, "actionlint"), f)
      H.eq({}, by_source(b, "zizmor"), f)
      H.eq({}, by_source(b, "cargo-deny"), f)
      H.eq({}, by_source(b, "cargo-machete"), f)
    end
    for _, names in ipairs(calls) do
      for _, n in ipairs(type(names) == "table" and names or { names }) do
        H.not_ok(vim.tbl_contains({ "actionlint", "zizmor", "cargo_deny", "cargo_machete" }, n), "try_lint called with " .. n)
      end
    end
  end)

  it("this repo's .github/workflows/ci.yml is clean under actionlint and zizmor", function()
    need_tool("actionlint")
    need_tool("zizmor")
    local ci = H.repo .. "/.github/workflows/ci.yml"
    local a = vim.system({ "actionlint", ci }, { text = true }):wait(60000)
    H.eq(0, a.code, "actionlint: " .. (a.stdout or "") .. (a.stderr or ""))
    -- the exact invocation of the nvim-lint zizmor definition (stdin)
    local z = vim.system({ "zizmor", "--format", "json-v1", "-" }, { text = true, stdin = table.concat(vim.fn.readfile(ci), "\n") .. "\n" }):wait(120000)
    local ok, list = pcall(vim.json.decode, z.stdout)
    H.ok(ok, "zizmor output: " .. tostring(z.stdout) .. tostring(z.stderr))
    H.eq(0, #list, "zizmor (regular persona) findings: " .. vim.inspect(vim.tbl_map(function(x)
      return x.ident
    end, list)))
  end)
end)

-- ------------------------------------------------------ documentation items

pending(
  "global git config (mergiraf, delta, zdiff3, rerere, dft/dlog aliases), lazygit <leader>gg and git-delta availability",
  "lives in the user's global ~/.gitconfig, outside the repo; the binaries are checked by :checkhealth xynovim"
)
pending("README per-repo opt-ins (.git-blame-ignore-revs, lefthook.yml)", "documentation only, no code to run")
