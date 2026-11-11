-- Supply-chain pins, lint configuration and the CI templates for the plugin repositories:
-- .github/workflows/ci.yml, .github/dependabot.yml, SECURITY.md, lua/plugins/mason-pin.lua,
-- stylua.toml, .luarc.json, docs/plugin-ci-templates/. The two lint tools also run for real when
-- Mason has installed them (the suite then fails on a formatting or static-check regression).
local H = require("xynotest.helpers")

local repo = H.repo

local function read(rel)
  local f = assert(io.open(repo .. "/" .. rel, "rb"), "cannot read " .. rel)
  local s = f:read("*a")
  f:close()
  return s
end

local function exists(rel)
  return vim.uv.fs_stat(repo .. "/" .. rel) ~= nil
end

describe("workflow downloads are checksum-pinned", function()
  local ci = read(".github/workflows/ci.yml")
  local platforms = read(".github/workflows/platforms.yml")

  it("ci.yml downloads a pinned Neovim, not `stable`, and verifies its sha256", function()
    H.no_match(ci, "download/stable", true, "no floating Neovim release")
    local version = ci:match("\n  NVIM_VERSION: (v%d+%.%d+%.%d+)\n")
    H.ok(version, "NVIM_VERSION is an exact tag")
    H.eq(platforms:match("\n  NVIM_VERSION: (v%d+%.%d+%.%d+)\n"), version, "the same Neovim as platforms.yml")
    local sha = ci:match("\n  NVIM_LINUX_SHA256: (%x+)\n")
    H.eq(64, #(sha or ""), "a sha256")
    H.match(ci, 'echo "${NVIM_LINUX_SHA256}  nvim.tar.gz" | sha256sum -c -', true)
    -- the check sits between the download and the unpacking
    local dl = ci:find("releases/download/${NVIM_VERSION}/nvim-linux-x86_64.tar.gz", 1, true)
    local check = ci:find("sha256sum -c -", dl, true)
    local unpack = ci:find("tar -xzf nvim.tar.gz", dl, true)
    H.ok(dl and check and unpack and dl < check and check < unpack, "download, check, unpack in this order")
  end)

  it("every curl download in the workflows is followed by a checksum check", function()
    for _, name in ipairs({ "ci.yml", "platforms.yml" }) do
      local text = read(".github/workflows/" .. name)
      local downloads, checks = 0, 0
      for _ in text:gmatch("curl %-fsSL %-o") do
        downloads = downloads + 1
      end
      for _ in text:gmatch("sha256sum %-c") do
        checks = checks + 1
      end
      for _ in text:gmatch("shasum %-a 256 %-c") do
        checks = checks + 1
      end
      H.ok(downloads > 0)
      H.ok(checks >= downloads, name .. ": " .. downloads .. " downloads, " .. checks .. " checks")
    end
  end)

  it("every `uses:` is pinned to a full commit SHA", function()
    for _, name in ipairs(vim.fn.readdir(repo .. "/.github/workflows")) do
      for ref in read(".github/workflows/" .. name):gmatch("uses:%s*(%S+)") do
        H.match(
          ref,
          "@%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$",
          false,
          name .. ": " .. ref
        )
      end
    end
  end)

  it("ci.yml has a lint job with pinned, checksum-verified StyLua and lua-language-server", function()
    H.match(ci, "\n  lint:\n", true)
    H.match(ci, "stylua --check .", true)
    H.match(ci, "lua-language-server --check . --checklevel=Warning", true)
    for _, v in ipairs({ "STYLUA_SHA256", "LUALS_SHA256" }) do
      H.eq(64, #(ci:match("\n  " .. v .. ": (%x+)\n") or ""), v)
      H.match(ci, "${" .. v .. "}", true)
    end
  end)
end)

describe("dependabot.yml", function()
  local dep = read(".github/dependabot.yml")

  it("covers github-actions at the root and the cargo crate that exists", function()
    H.match(dep, "package-ecosystem: github-actions\n    directory: /\n", true)
    H.match(dep, "package-ecosystem: cargo\n    directory: /demo/netwatch\n", true)
    H.ok(exists("demo/netwatch/Cargo.toml"), "the cargo directory exists")
  end)

  it("lists an ecosystem for every manifest the repository has (outside the test fixtures)", function()
    H.not_ok(
      exists("package.json") or exists("requirements.txt") or exists("pyproject.toml"),
      "a manifest without an ecosystem"
    )
  end)
end)

describe("SECURITY.md", function()
  local sec = read("SECURITY.md")

  it("says how to report and what the sandbox is not", function()
    H.match(sec, "Report a vulnerability", true)
    H.match(sec, "seatbelt, not a jail", true)
    H.match(sec, "The network stays open", true)
    H.match(sec, "No sandbox on Windows or macOS", true)
  end)

  it("the pins it lists exist", function()
    H.match(sec, "lua/plugins/mason-pin.lua", true)
    H.ok(exists("lua/plugins/mason-pin.lua"))
    H.ok(exists(".github/dependabot.yml"))
  end)
end)

describe("Mason registry pin", function()
  it("the registry is a release tag of mason-org/mason-registry and reaches mason.setup", function()
    local plugin = H.ok(require("lazy.core.config").plugins["mason.nvim"], "mason.nvim in the spec")
    local opts = require("lazy.core.plugin").values(plugin, "opts", false)
    H.eq(1, #(opts.registries or {}), "exactly one registry")
    H.match(opts.registries[1], "^github:mason%-org/mason%-registry@%d%d%d%d%-%d%d%-%d%d%-[%a%-]+$")
    -- the version lines in the file's comment name the tools the specs and README rely on
    H.match(read("lua/plugins/mason-pin.lua"), "bacon-ls 0.31.0", true)
  end)

  it("the tag in the file is the one Mason has cached, when a cache exists", function()
    local info = vim.fn.stdpath("data") .. "/mason/registries/github/mason-org/mason-registry/info.json"
    if vim.uv.fs_stat(info) == nil then
      return
    end
    local cached = vim.json.decode(table.concat(vim.fn.readfile(info), "\n")).version
    local pinned = read("lua/plugins/mason-pin.lua"):match('registry@([%w%-]+)"')
    -- not an equality failure when somebody bumped the pin and has not run :MasonUpdate yet
    if cached ~= pinned then
      skip(("Mason cached %s, the pin is %s (run :MasonUpdate)"):format(cached, pinned))
    end
  end)
end)

describe("lint configuration", function()
  it("stylua.toml and .luarc.json are well formed", function()
    H.match(read("stylua.toml"), "column_width = 120", true)
    H.match(read("stylua.toml"), 'indent_type = "Spaces"', true)
    local luarc = vim.json.decode(read(".luarc.json"))
    H.eq("LuaJIT", luarc["runtime.version"])
    H.has(luarc["diagnostics.globals"], "vim")
  end)

  it("the Neovim globals the config uses are declared, not silenced", function()
    local luarc = vim.json.decode(read(".luarc.json"))
    H.not_ok(vim.tbl_contains(luarc["diagnostics.disable"], "undefined-global"), "undefined-global stays on")
    H.not_ok(vim.tbl_contains(luarc["diagnostics.disable"], "lowercase-global"), "lowercase-global stays on")
  end)

  local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/"
  local function tool(name)
    local p = mason_bin .. name
    if vim.fn.executable(p) == 1 then
      return p
    end
    return vim.fn.executable(name) == 1 and name or nil
  end

  it("stylua --check . passes on the whole repository", function()
    local stylua = tool("stylua")
    if not stylua then
      return skip("stylua is not installed (Mason installs it)")
    end
    local r = vim.system({ stylua, "--check", "." }, { cwd = repo, text = true }):wait(120000)
    H.eq(0, r.code, "stylua --check . (run `stylua .`):\n" .. (r.stdout or ""):sub(1, 1500))
  end)

  it("lua-language-server --check finds no warning", function()
    local luals = tool("lua-language-server")
    if not luals then
      return skip("lua-language-server is not installed (Mason installs it)")
    end
    local logs = H.tmpdir()
    local r = vim
      .system({ luals, "--check", ".", "--checklevel=Warning", "--logpath", logs }, { cwd = repo, text = true })
      :wait(240000)
    local out = ((r.stdout or "") .. (r.stderr or "")):gsub("\27%[[%d;]*m", "")
    H.eq(0, r.code, "lua-language-server --check:\n" .. out:sub(-1500))
  end)
end)

describe("docs/plugin-ci-templates", function()
  local plugins = {
    "xyno-history",
    "xyno-sandbox",
    "xyno-clipboard",
    "xyno-guard",
    "xyno-rust",
    "xyno-new",
    "xyno-imports",
    "xyno-crates",
    "xyno-macros",
  }

  it("has the files, and the README names all nine repositories", function()
    for _, f in ipairs({
      "lint.yml",
      "dependabot.yml",
      "luarc.json",
      "stylua.toml",
      "SECURITY.md",
      "apply.sh",
      "README.md",
    }) do
      H.ok(exists("docs/plugin-ci-templates/" .. f), f)
    end
    local readme = read("docs/plugin-ci-templates/README.md")
    for _, p in ipairs(plugins) do
      H.match(readme, p, true)
    end
  end)

  it("the template uses the same pins as the main repository's lint job", function()
    local ci, tpl = read(".github/workflows/ci.yml"), read("docs/plugin-ci-templates/lint.yml")
    for _, v in ipairs({ "STYLUA_VERSION", "STYLUA_SHA256", "LUALS_VERSION", "LUALS_SHA256" }) do
      H.eq(ci:match("\n  " .. v .. ": (%S+)\n"), tpl:match("\n  " .. v .. ": (%S+)\n"), v)
    end
    H.eq(read("stylua.toml"), read("docs/plugin-ci-templates/stylua.toml"))
  end)

  it("apply.sh copies the files into a plugin checkout and keeps existing ones", function()
    H.need_posix("apply.sh is a bash script")
    local dest = H.tmpdir()
    vim.fn.mkdir(dest .. "/lua", "p")
    vim.fn.writefile({ "keep" }, dest .. "/.stylua.toml")
    local r = vim.system({ H.bash, repo .. "/docs/plugin-ci-templates/apply.sh", dest }, { text = true }):wait(20000)
    H.eq(0, r.code, r.stderr)
    for _, f in ipairs({ ".github/workflows/lint.yml", ".github/dependabot.yml", ".luarc.json", "SECURITY.md" }) do
      H.ok(vim.uv.fs_stat(dest .. "/" .. f), f)
    end
    H.eq({ "keep" }, vim.fn.readfile(dest .. "/.stylua.toml"), "an existing file is kept")
    H.match(r.stdout, "kept    .stylua.toml", true)
    local bad = vim
      .system({ H.bash, repo .. "/docs/plugin-ci-templates/apply.sh", H.tmpdir() }, { text = true })
      :wait(20000)
    H.eq(2, bad.code, "a directory without lua/ is refused")
  end)
end)
