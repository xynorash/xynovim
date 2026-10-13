-- lua/config/agent_sandbox.lua: the bubblewrap wrapper around `claude` (99).
-- Structure tests build the wrapped command against a FAKE $HOME (the module
-- reads os_homedir() once at load, so it is reloaded per fake home); the
-- behavioural tests run real commands inside bwrap against that same fake
-- home, never against the real one. No rust-analyzer needed.
local H = require("xynotest.helpers")
local harness = require("xynotest.harness")

local MOD = "config.agent_sandbox"
local real_mod = require(MOD)
local uid = vim.uv.os_get_passwd().uid

-- ------------------------------------------------------------------ helpers

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text or "x\n")
  f:close()
end

local function mkdir(path)
  vim.fn.mkdir(path, "p")
end

local env_restore = {}
local function setenv(name, value)
  env_restore[#env_restore + 1] = { name, vim.uv.os_getenv(name) }
  vim.uv.os_setenv(name, value)
end

--- A fresh directory on the real filesystem (not /tmp: the sandbox hides it)
--- used as a fake $HOME. Removed by H.cleanup().
local function fake_home(opts)
  local base = vim.uv.os_homedir() .. "/.cache"
  mkdir(base)
  local dir = assert(vim.uv.fs_mkdtemp(base .. "/xyno-sandbox-spec-XXXXXX"))
  H._dirs[#H._dirs + 1] = dir
  dir = vim.uv.fs_realpath(dir)
  if not (opts or {}).no_claude then
    mkdir(dir .. "/.claude") -- bwrap needs it as the parent of the ~/.claude/<x> masks
  end
  return dir
end

--- Run `fn`; if it fails, report the test as skipped with `reason` (a confirmed
--- bug in the module under test, kept as the assertion of the CORRECT behaviour).
local function known_bug(reason, fn)
  local ok, err = pcall(fn)
  if not ok then
    if harness.is_skip(err) then
      error(err, 0)
    end
    harness.skip("KNOWN BUG: " .. reason .. " | " .. tostring(err):gsub("\n.*", ""))
  end
end

--- agent_sandbox loaded as if $HOME were `home`.
local function load_for(home)
  local old = vim.uv.os_getenv("HOME")
  vim.uv.os_setenv("HOME", home)
  package.loaded[MOD] = nil
  local m = require(MOD)
  vim.uv.os_setenv("HOME", old)
  package.loaded[MOD] = real_mod
  return m
end

--- wrap() with nvim's cwd set to `cwd` (default project), restoring it after.
local function wrap(m, cmd, project, tmp, cwd)
  local prev = vim.fn.chdir(cwd or project)
  local ok, a = pcall(m.wrap, cmd, project, tmp)
  vim.fn.chdir(prev)
  assert(ok, a)
  return a
end

--- Index of the consecutive run `...` in list `a`, or nil.
local function find_seq(a, ...)
  local seq = { ... }
  for i = 1, #a - #seq + 1 do
    local hit = true
    for j = 1, #seq do
      if a[i + j - 1] ~= seq[j] then
        hit = false
        break
      end
    end
    if hit then
      return i
    end
  end
end

local function expect_seq(a, ...)
  H.ok(find_seq(a, ...), "missing in wrapped command: " .. table.concat({ ... }, " "))
end

local function expect_no_seq(a, ...)
  H.not_ok(find_seq(a, ...), "unexpected in wrapped command: " .. table.concat({ ... }, " "))
end

local function contains(list, v)
  return vim.tbl_contains(list, v)
end

--- Run `script` (bash) inside the sandbox built by module `m` (fake home `home`
--- exported as $HOME). Skips the test when bwrap cannot work here.
local function sb(m, home, script, project, opts)
  H.need_sandbox()
  local tmp = H.tmpdir()
  local cmd = wrap(m, { "bash", "-c", script }, project, tmp)
  local env = { HOME = home }
  for k, v in pairs((opts or {}).env or {}) do
    env[k] = v
  end
  local r = vim.system(cmd, { cwd = project, text = true, env = env }):wait((opts or {}).timeout or 60000)
  return r, tmp
end

local function out(r)
  return (r.stdout or "") .. (r.stderr or "")
end

after_each(function()
  for i = #env_restore, 1, -1 do
    local e = env_restore[i]
    vim.uv.os_setenv(e[1], e[2] or "")
    if e[2] == nil then
      vim.uv.os_unsetenv(e[1])
    end
  end
  env_restore = {}
  package.loaded[MOD] = real_mod
end)

-- ------------------------------------------------------------ 1, 17: opt-out

describe("opt-out", function()
  it("returns the bare command when vim.g.xynovim_99_sandbox == false", function()
    local cmd = { "claude", "--version" }
    local old = vim.g.xynovim_99_sandbox
    vim.g.xynovim_99_sandbox = false
    local ok, got = pcall(real_mod.wrap, cmd, "/tmp", "/tmp")
    vim.g.xynovim_99_sandbox = old
    assert(ok, got)
    H.eq(cmd, got)
    H.ok(got == cmd, "the same table comes back")
  end)

  it("returns the bare command when bwrap is not executable", function()
    local cmd = { "claude", "--version" }
    setenv("PATH", "/nonexistent-xyno-path")
    H.eq(0, vim.fn.executable("bwrap"))
    H.eq(cmd, real_mod.wrap(cmd, "/tmp", "/tmp"))
  end)
end)

-- ---------------------------------------------------- 2, 3: layout and binds

describe("wrapped command layout", function()
  it("starts with the fixed isolation flags and ends with --chdir <cwd> -- <cmd>", function()
    if vim.fn.executable("bwrap") ~= 1 then
      return harness.skip("bwrap not found")
    end
    local home = fake_home()
    local m = load_for(home)
    local project, tmp = H.tmpdir(), H.tmpdir()
    local cwd = H.tmpdir()
    local a = wrap(m, { "echo", "hi there" }, project, tmp, cwd)
    local prefix = {
      "bwrap", "--die-with-parent", "--new-session", "--unshare-user", "--disable-userns", "--unshare-pid",
      "--unshare-ipc", "--unshare-uts", "--unshare-cgroup-try", "--cap-drop", "ALL", "--ro-bind", "/", "/",
      "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
    }
    H.eq(prefix, vim.list_slice(a, 1, #prefix))
    local n = #a
    H.eq({ "--chdir", cwd, "--", "echo", "hi there" }, vim.list_slice(a, n - 4, n))
  end)

  it("binds project and tmp_dir writable, but not a missing tmp_dir", function()
    if vim.fn.executable("bwrap") ~= 1 then
      return harness.skip("bwrap not found")
    end
    local m = load_for(fake_home())
    local project, tmp = H.tmpdir(), H.tmpdir()
    local a = wrap(m, { "true" }, project, tmp)
    expect_seq(a, "--bind", project, project)
    expect_seq(a, "--bind", tmp, tmp)
    local gone = tmp .. "/does-not-exist"
    expect_no_seq(wrap(m, { "true" }, project, gone), "--bind", gone, gone)
  end)

  it("never binds $HOME or / as the project", function()
    if vim.fn.executable("bwrap") ~= 1 then
      return harness.skip("bwrap not found")
    end
    local home = fake_home()
    local m = load_for(home)
    local tmp = H.tmpdir()
    local a = wrap(m, { "true" }, home, tmp)
    expect_no_seq(a, "--bind", home, home)
    expect_seq(a, "--bind", tmp, tmp)
    -- "/" itself (readonly_paths scans it, read-only, a few seconds at most)
    local prev = vim.fn.chdir(home)
    local ok, w = pcall(m.wrap, { "true" }, "/", tmp)
    vim.fn.chdir(prev)
    assert(ok, w)
    expect_no_seq(w, "--bind", "/", "/")
  end)

  it("binds the WRITABLE paths only when they exist, and never the exec-ish ones", function()
    if vim.fn.executable("bwrap") ~= 1 then
      return harness.skip("bwrap not found")
    end
    local home = fake_home()
    local m = load_for(home)
    local project, tmp = H.tmpdir(), H.tmpdir()
    local writable = {
      "/.claude", "/.cache/claude", "/.local/state/claude", "/.cargo/registry", "/.cargo/git",
      "/.cargo/.package-cache", "/.cargo/.package-cache-mutate",
    }
    local never = { "/.local/share/claude", "/.cargo/bin", "/.cargo/config.toml" }

    vim.fn.delete(home .. "/.claude", "rf")
    local a = wrap(m, { "true" }, project, tmp)
    for _, p in ipairs(writable) do
      if p ~= "/.claude" then -- wrap() creates it itself (the ~/.claude/<x> masks need it)
        expect_no_seq(a, "--bind", home .. p, home .. p)
      end
    end
    H.eq(1, vim.fn.isdirectory(home .. "/.claude"), "wrap creates ~/.claude")

    for _, p in ipairs(writable) do
      mkdir(home .. p)
    end
    for _, p in ipairs(never) do
      if p:find("config.toml", 1, true) then
        write(home .. p)
      else
        mkdir(home .. p)
      end
    end
    a = wrap(m, { "true" }, project, tmp)
    for _, p in ipairs(writable) do
      expect_seq(a, "--bind", home .. p, home .. p)
    end
    for _, p in ipairs(never) do
      expect_no_seq(a, "--bind", home .. p, home .. p)
    end
  end)
end)

-- ---------------------------------------------------------- 4, 5: scrub_names

describe("scrub_names", function()
  local m = real_mod

  it("hits names containing a secret-ish word", function()
    local words = {
      "TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "APIKEY", "CREDENTIAL", "PRIVATE_KEY", "ACCESS_KEY",
      "AUTH_SOCK", "AGENT_INFO", "PASSPHRASE", "ASKPASS",
    }
    local env, want = {}, {}
    for _, w in ipairs(words) do
      local n = "MY_" .. w .. "_X"
      env[n] = "1"
      want[#want + 1] = n
    end
    env.XYNO_PLAIN = "1"
    table.sort(want)
    H.eq(want, m.scrub_names(env, true))
  end)

  it("hits the listed prefixes", function()
    local prefixes = {
      "AWS_", "AZURE_", "GOOGLE_", "GCP_", "GCLOUD_", "DOCKER_", "KUBE", "GH_", "GITHUB_", "GITLAB_", "NPM_",
      "CARGO_REGISTR", "VAULT_", "OPENAI_", "STRIPE_",
    }
    local env, want = {}, {}
    for _, p in ipairs(prefixes) do
      env[p .. "FOO"] = "1"
      want[#want + 1] = p .. "FOO"
    end
    -- the prefix must be a prefix: these merely contain it
    env.MY_AWS_FOO, env.XGH_FOO, env.CARGO_HOME = "1", "1", "1"
    table.sort(want)
    H.eq(want, m.scrub_names(env, true))
  end)

  it("hits the exact names", function()
    local names = {
      "DATABASE_URL", "DBUS_SESSION_BUS_ADDRESS", "DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "SSH_AUTH_SOCK",
      "GPG_AGENT_INFO", "KUBECONFIG", "MYSQL_PWD", "SSHPASS",
    }
    local env = { PWD = "/home/x/proj", DATABASE_URL_X = "1", MYDISPLAY = "1" }
    for _, n in ipairs(names) do
      env[n] = "1"
    end
    table.sort(names)
    H.eq(names, m.scrub_names(env, true))
  end)

  it("matches case-insensitively on the upper-cased name, returns sorted, keeps PATH/HOME/LANG", function()
    local env = {
      github_token = "1", My_Secret = "1", aws_region = "1", display = "1", Zeta_Password = "1",
      PATH = "/bin", HOME = "/h", LANG = "C", EDITOR = "nvim",
    }
    H.eq({ "My_Secret", "Zeta_Password", "aws_region", "display", "github_token" }, m.scrub_names(env, true))
  end)

  it("keeps the claude auth variables with a non-file login and scrubs them with a file login", function()
    local env = { ANTHROPIC_API_KEY = "1", ANTHROPIC_AUTH_TOKEN = "1", CLAUDE_CODE_OAUTH_TOKEN = "1", OTHER_TOKEN = "1" }
    H.eq({ "OTHER_TOKEN" }, m.scrub_names(env, false))
    H.eq({ "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "OTHER_TOKEN" }, m.scrub_names(env, true))
  end)

  it("computes file_login from ~/.claude/.credentials.json when not given", function()
    local home = fake_home()
    local fm = load_for(home)
    local env = { ANTHROPIC_API_KEY = "1", CLAUDE_CODE_OAUTH_TOKEN = "1" }
    H.eq({}, fm.scrub_names(env))
    write(home .. "/.claude/.credentials.json", "{}")
    H.eq({ "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN" }, fm.scrub_names(env))
  end)

  it("defaults env to the live environment", function()
    setenv("XYNO_SPEC_SENTINEL_TOKEN", "1")
    H.has(m.scrub_names(nil, true), "XYNO_SPEC_SENTINEL_TOKEN")
  end)
end)

-- --------------------------------------------------------------- 6: unsetenv

describe("environment scrub in the wrapper", function()
  it("emits --unsetenv for every scrub name", function()
    if vim.fn.executable("bwrap") ~= 1 then
      return harness.skip("bwrap not found")
    end
    setenv("XYNO_SPEC_SENTINEL_TOKEN", "s3cret")
    setenv("XYNO_SPEC_HARMLESS", "ok")
    local m = load_for(fake_home())
    local a = wrap(m, { "true" }, H.tmpdir(), H.tmpdir())
    local names = m.scrub_names()
    H.has(names, "XYNO_SPEC_SENTINEL_TOKEN")
    H.not_ok(contains(names, "XYNO_SPEC_HARMLESS"))
    for _, n in ipairs(names) do
      expect_seq(a, "--unsetenv", n)
    end
    expect_no_seq(a, "--unsetenv", "XYNO_SPEC_HARMLESS")
  end)

  it("really unsets a sentinel GITHUB_TOKEN inside the sandbox", function()
    H.need_sandbox()
    setenv("GITHUB_TOKEN", "ghp_sentinel")
    setenv("XYNO_SPEC_KEEP", "kept")
    local home = fake_home()
    local m = load_for(home)
    local r = sb(m, home, 'echo "gh=${GITHUB_TOKEN-unset} keep=${XYNO_SPEC_KEEP-unset}"', H.tmpdir())
    H.eq(0, r.code, out(r))
    H.match(r.stdout, "gh=unset keep=kept", true)
  end)
end)

-- --------------------------------------------------- 7, 8: hidden paths/files

describe("hidden credentials", function()
  local hidden_dirs = {
    "/.ssh", "/.gnupg", "/.aws", "/.azure", "/.gsutil", "/.boto", "/.docker", "/.kube", "/.terraform.d",
    "/.pki", "/.password-store",
    "/.config/gh", "/.config/rclone", "/.config/pulumi", "/.config/helm", "/.config/gcloud", "/.config/op",
    "/.config/doctl", "/.config/hub", "/.config/Bitwarden", "/.config/1Password", "/.config/keepassxc",
    "/.config/pulse", "/.config/Slack", "/.config/discord", "/.config/Signal", "/.config/rustdesk",
    "/.config/winapps", "/.config/freerdp", "/.config/obs-studio", "/.config/JetBrains",
    "/.config/google-chrome", "/.config/chromium", "/.config/BraveSoftware", "/.config/microsoft-edge",
    "/.config/vivaldi", "/.config/opera", "/.mozilla", "/.thunderbird", "/.cache/google-chrome",
    "/.local/share/keyrings", "/.local/share/password-store", "/.local/share/gnome-keyring",
    "/.local/share/kwalletd", "/.local/share/TelegramDesktop", "/.local/share/fish",
    "/.claude/daemon", "/.claude/sessions",
  }
  local hidden_files = {
    "/.vault-token", "/.netrc", "/.git-credentials", "/.npmrc", "/.pypirc", "/.cargo/credentials",
    "/.cargo/credentials.toml", "/.pub-cache/credentials.json", "/.android/adbkey", "/.Xauthority",
    "/.pulse-cookie", "/.config/git/credentials", "/.bash_history", "/.zsh_history", "/.python_history",
    "/.lesshst", "/.config/fish/fish_history", "/.claude/history.jsonl",
  }

  local function populated()
    local home = fake_home()
    for _, p in ipairs(hidden_dirs) do
      write(home .. p .. "/secret", "s")
    end
    for _, p in ipairs(hidden_files) do
      write(home .. p, "s")
    end
    return home
  end

  it("hides existing credential dirs with --tmpfs and files with --ro-bind /dev/null", function()
    if vim.fn.executable("bwrap") ~= 1 then
      return harness.skip("bwrap not found")
    end
    local home = populated()
    local a = wrap(load_for(home), { "true" }, H.tmpdir(), H.tmpdir())
    for _, p in ipairs(hidden_dirs) do
      expect_seq(a, "--tmpfs", home .. p)
    end
    for _, p in ipairs(hidden_files) do
      expect_seq(a, "--ro-bind", "/dev/null", home .. p)
    end
  end)

  it("hides nothing that does not exist", function()
    if vim.fn.executable("bwrap") ~= 1 then
      return harness.skip("bwrap not found")
    end
    local home = fake_home()
    local a = wrap(load_for(home), { "true" }, H.tmpdir(), H.tmpdir())
    for _, p in ipairs(hidden_dirs) do
      expect_no_seq(a, "--tmpfs", home .. p)
    end
    for _, p in ipairs(hidden_files) do
      expect_no_seq(a, "--ro-bind", "/dev/null", home .. p)
    end
  end)

  it("hides the existing system sockets and /run/user/<uid>", function()
    if vim.fn.executable("bwrap") ~= 1 then
      return harness.skip("bwrap not found")
    end
    local a = wrap(load_for(fake_home()), { "true" }, H.tmpdir(), H.tmpdir())
    local sys = {
      "/run/user/" .. uid, "/run/docker.sock", "/run/docker", "/run/containerd", "/run/podman", "/run/libvirt",
      "/run/dbus", "/run/snapd.socket", "/run/snapd-snap.socket",
    }
    local seen = 0
    for _, p in ipairs(sys) do
      local st = vim.uv.fs_stat(p)
      if st then
        seen = seen + 1
        if st.type == "directory" then
          expect_seq(a, "--tmpfs", p)
        else
          expect_seq(a, "--ro-bind", "/dev/null", p)
        end
      else
        expect_no_seq(a, "--tmpfs", p)
        expect_no_seq(a, "--ro-bind", "/dev/null", p)
      end
    end
    if seen == 0 then
      harness.skip("none of the system paths exist on this machine (list was checked for absence only)")
    end
  end)

  it("really hides credentials inside the sandbox (dir empty, file empty)", function()
    H.need_sandbox()
    local home = populated()
    local m = load_for(home)
    local r = sb(
      m, home,
      'echo "ssh=[$(ls -A "$HOME/.ssh" | wc -l)] netrc=[$(cat "$HOME/.netrc" 2>/dev/null | wc -c)] hist=[$(cat "$HOME/.bash_history" 2>/dev/null | wc -c)] '
        .. 'daemon=[$(ls -A "$HOME/.claude/daemon" | wc -l)] prompts=[$(cat "$HOME/.claude/history.jsonl" 2>/dev/null | wc -c)]"',
      H.tmpdir()
    )
    H.eq(0, r.code, out(r))
    H.match(r.stdout, "ssh=[0] netrc=[0] hist=[0] daemon=[0] prompts=[0]", true)
    -- the real files are untouched
    H.eq("s", vim.fn.readfile(home .. "/.ssh/secret")[1])
  end)
end)

-- ----------------------------------------------- 9, 15: ~/.claude.json copy

describe("~/.claude.json", function()
  it("is replaced by a private 0600 copy bound over it", function()
    if vim.fn.executable("bwrap") ~= 1 then
      return harness.skip("bwrap not found")
    end
    local home = fake_home()
    write(home .. "/.claude.json", '{"mcpServers":{}}\n')
    local a = wrap(load_for(home), { "true" }, H.tmpdir(), H.tmpdir())
    local copy
    for j = 1, #a - 2 do
      if a[j] == "--bind" and a[j + 2] == home .. "/.claude.json" then
        copy = a[j + 1]
      end
    end
    H.ok(copy, "no --bind <copy> ~/.claude.json")
    H.ok(copy ~= home .. "/.claude.json")
    H.eq({ '{"mcpServers":{}}' }, vim.fn.readfile(copy))
    H.eq(tonumber("600", 8), bit.band(vim.uv.fs_stat(copy).mode, tonumber("777", 8)))
    vim.fn.delete(copy)
  end)

  it("is not bound when ~/.claude.json does not exist", function()
    if vim.fn.executable("bwrap") ~= 1 then
      return harness.skip("bwrap not found")
    end
    local home = fake_home()
    local a = wrap(load_for(home), { "true" }, H.tmpdir(), H.tmpdir())
    for j = 1, #a - 2 do
      H.not_ok(a[j] == "--bind" and a[j + 2] == home .. "/.claude.json")
    end
  end)

  it("a write inside the sandbox hits only the copy", function()
    H.need_sandbox()
    local home = fake_home()
    write(home .. "/.claude.json", '{"orig":true}\n')
    local m = load_for(home)
    local r = sb(m, home, 'echo \'{"planted":true}\' > "$HOME/.claude.json" && cat "$HOME/.claude.json"', H.tmpdir())
    H.eq(0, r.code, out(r))
    H.match(r.stdout, "planted", true)
    H.eq({ '{"orig":true}' }, vim.fn.readfile(home .. "/.claude.json"))
  end)
end)

-- ------------------------------------------------------ 10, 11: readonly_paths

describe("readonly_paths", function()
  local function set(list)
    local s = {}
    for _, p in ipairs(list) do
      s[p] = true
    end
    return s
  end

  it("finds every .git up to 2 levels deep and resolves gitdir/commondir from a .git file", function()
    local home = fake_home()
    local m = load_for(home)
    local base = H.tmpdir()
    local project = base .. "/proj"
    -- main repo and a worktree-like checkout with a RELATIVE gitdir and a commondir
    mkdir(project .. "/.git")
    mkdir(base .. "/store/wt/x")
    mkdir(base .. "/store/common")
    write(base .. "/store/wt/x/commondir", "../../common\n")
    write(project .. "/sub/.git", "gitdir: ../../store/wt/x\n")
    mkdir(project .. "/a/b/.git") -- depth 2: locked
    mkdir(project .. "/a/b/c/.git") -- depth 3: not locked
    mkdir(project .. "/target/.git") -- skipped
    mkdir(project .. "/node_modules/.git")
    mkdir(project .. "/.cache/.git")
    local ro = set((m.readonly_paths(project)))
    H.ok(ro[project .. "/.git"])
    H.ok(ro[project .. "/sub/.git"])
    H.ok(ro[vim.uv.fs_realpath(base .. "/store/wt/x")], "gitdir behind the .git file")
    H.ok(ro[vim.uv.fs_realpath(base .. "/store/common")], "commondir")
    H.ok(ro[project .. "/a/b/.git"])
    H.not_ok(ro[project .. "/a/b/c/.git"], "deeper than 2 is not locked (documented residual)")
    H.not_ok(ro[project .. "/target/.git"])
    H.not_ok(ro[project .. "/node_modules/.git"])
    H.not_ok(ro[project .. "/.cache/.git"])
  end)

  it("handles an absolute gitdir and an unreadable or empty .git file", function()
    local m = load_for(fake_home())
    local base = H.tmpdir()
    local project = base .. "/proj"
    mkdir(base .. "/abs-gitdir")
    write(project .. "/m1/.git", "gitdir: " .. base .. "/abs-gitdir\n")
    write(project .. "/m2/.git", "garbage\n")
    write(project .. "/m3/.git", "gitdir: /does/not/exist\n")
    local ro = set((m.readonly_paths(project)))
    H.ok(ro[vim.uv.fs_realpath(base .. "/abs-gitdir")])
    H.ok(ro[project .. "/m1/.git"])
    H.ok(ro[project .. "/m2/.git"])
    H.ok(ro[project .. "/m3/.git"])
  end)

  it("locks existing PROJECT_READONLY entries only", function()
    local m = load_for(fake_home())
    local project = H.tmpdir()
    local present = {
      ".gitmodules", ".envrc", ".mise.toml", ".tool-versions", ".nvim.lua", ".nvimrc", ".exrc",
      ".vscode/tasks.json", ".vscode/settings.json", ".mcp.json",
    }
    for _, p in ipairs(present) do
      write(project .. "/" .. p)
    end
    mkdir(project .. "/.cargo")
    local ro = set((m.readonly_paths(project)))
    for _, p in ipairs(present) do
      H.ok(ro[project .. "/" .. p], p)
    end
    H.ok(ro[project .. "/.cargo"])
    H.ok(ro[project .. "/.vscode"], "the whole .vscode dir")
    local empty = H.tmpdir()
    local ro2 = m.readonly_paths(empty)
    for _, p in ipairs(ro2) do
      H.no_match(p, empty .. "/.", true)
    end
  end)

  it("locks .cargo and .envrc of members up to depth 3, not hidden or skipped dirs", function()
    local m = load_for(fake_home())
    local project = H.tmpdir()
    mkdir(project .. "/m1/.cargo")
    write(project .. "/m1/.envrc")
    mkdir(project .. "/x/y/.cargo")
    write(project .. "/x/y/z/.envrc")
    mkdir(project .. "/x/y/z/w/.cargo") -- depth 4: not locked
    mkdir(project .. "/.hid/.cargo")
    mkdir(project .. "/target/foo/.cargo")
    mkdir(project .. "/node_modules/foo/.cargo")
    local ro = set((m.readonly_paths(project)))
    H.ok(ro[project .. "/m1/.cargo"])
    H.ok(ro[project .. "/m1/.envrc"])
    H.ok(ro[project .. "/x/y/.cargo"])
    H.ok(ro[project .. "/x/y/z/.envrc"])
    H.not_ok(ro[project .. "/x/y/z/w/.cargo"])
    H.not_ok(ro[project .. "/.hid/.cargo"])
    H.not_ok(ro[project .. "/target/foo/.cargo"])
    H.not_ok(ro[project .. "/node_modules/foo/.cargo"])
  end)

  it("locks existing HOME_READONLY entries and ~/.claude/projects/*/memory", function()
    local home = fake_home()
    local m = load_for(home)
    local files = { "settings.json", "settings.local.json", "CLAUDE.md", "keybindings.json" }
    local dirs = { "hooks", "commands", "agents", "skills", "plugins", "output-styles", "ide", "rules", "chrome", "security" }
    for _, f in ipairs(files) do
      write(home .. "/.claude/" .. f)
    end
    for _, d in ipairs(dirs) do
      mkdir(home .. "/.claude/" .. d)
    end
    mkdir(home .. "/.claude/projects/-p1/memory")
    mkdir(home .. "/.claude/projects/-p2/memory")
    mkdir(home .. "/.claude/projects/-p3") -- no memory
    local ro = set((m.readonly_paths(H.tmpdir())))
    for _, f in ipairs(files) do
      H.ok(ro[home .. "/.claude/" .. f], f)
    end
    for _, d in ipairs(dirs) do
      H.ok(ro[home .. "/.claude/" .. d], d)
    end
    H.ok(ro[home .. "/.claude/projects/-p1/memory"])
    H.ok(ro[home .. "/.claude/projects/-p2/memory"])
    H.not_ok(ro[home .. "/.claude/projects/-p3/memory"])
    H.not_ok(ro[home .. "/.claude/projects/-p3"])
  end)

  it("masks absent project/.claude and project/.cargo, locks them when present", function()
    local m = load_for(fake_home())
    local project = H.tmpdir()
    local ro, masks = m.readonly_paths(project)
    H.has(masks, project .. "/.claude")
    H.has(masks, project .. "/.cargo")
    H.not_ok(set(ro)[project .. "/.claude"])
    mkdir(project .. "/.claude")
    mkdir(project .. "/.cargo")
    ro, masks = m.readonly_paths(project)
    H.not_ok(contains(masks, project .. "/.claude"))
    H.not_ok(contains(masks, project .. "/.cargo"))
    H.ok(set(ro)[project .. "/.claude"])
    H.ok(set(ro)[project .. "/.cargo"])
  end)

  it("masks .cargo of member crates that lack one", function()
    local m = load_for(fake_home())
    local project = H.tmpdir()
    write(project .. "/c1/Cargo.toml")
    write(project .. "/c2/Cargo.toml")
    mkdir(project .. "/c2/.cargo")
    mkdir(project .. "/plain") -- no Cargo.toml
    write(project .. "/deep/er/crate/Cargo.toml")
    local _, masks = m.readonly_paths(project)
    H.has(masks, project .. "/c1/.cargo")
    H.not_ok(contains(masks, project .. "/c2/.cargo"))
    H.not_ok(contains(masks, project .. "/plain/.cargo"))
    H.has(masks, project .. "/deep/er/crate/.cargo")
  end)

  it("masks absent ~/.claude/{hooks,...} and this project's memory dir (also via realpaths)", function()
    local home = fake_home({ no_claude = true })
    local m = load_for(home)
    local base = H.tmpdir()
    mkdir(base .. "/real/proj")
    vim.uv.fs_symlink(base .. "/real", base .. "/link")
    local project = base .. "/link/proj" -- symlinked path
    local real = vim.uv.fs_realpath(project)
    H.ok(real ~= project)
    local name = function(p)
      return home .. "/.claude/projects/" .. p:gsub("[^%w]", "-") .. "/memory"
    end

    -- no ~/.claude: no memory masks, and no ~/.claude/<x> masks
    local prev = vim.fn.chdir(project)
    local _, masks0 = m.readonly_paths(project)
    H.not_ok(contains(masks0, name(project)))

    mkdir(home .. "/.claude")
    mkdir(home .. "/.claude/skills") -- present: not masked, locked
    local ro, masks = m.readonly_paths(project)
    vim.fn.chdir(prev)
    for _, d in ipairs({ "hooks", "commands", "agents", "rules", "output-styles" }) do
      H.has(masks, home .. "/.claude/" .. d)
    end
    H.not_ok(contains(masks, home .. "/.claude/skills"))
    H.ok(set(ro)[home .. "/.claude/skills"])
    H.has(masks, name(project))
    H.has(masks, name(real))

    -- existing memory dir: locked rather than masked
    mkdir(name(real))
    prev = vim.fn.chdir(project)
    ro, masks = m.readonly_paths(project)
    vim.fn.chdir(prev)
    H.not_ok(contains(masks, name(real)))
    H.ok(set(ro)[name(real)])
  end)

  it("uses cwd as well as project for the memory mask", function()
    local home = fake_home()
    local m = load_for(home)
    mkdir(home .. "/.claude")
    local project, cwd = H.tmpdir(), H.tmpdir()
    local prev = vim.fn.chdir(cwd)
    local _, masks = m.readonly_paths(project)
    vim.fn.chdir(prev)
    H.has(masks, home .. "/.claude/projects/" .. vim.uv.fs_realpath(cwd):gsub("[^%w]", "-") .. "/memory")
    H.has(masks, home .. "/.claude/projects/" .. project:gsub("[^%w]", "-") .. "/memory")
  end)

  it("skips project-relative masks for project == $HOME but keeps the ~/.claude ones", function()
    if vim.fn.executable("bwrap") ~= 1 then
      return harness.skip("bwrap not found")
    end
    local home = fake_home()
    mkdir(home .. "/.claude")
    local m = load_for(home)
    local a = wrap(m, { "true" }, home, H.tmpdir())
    expect_no_seq(a, "--tmpfs", home .. "/.cargo")
    expect_no_seq(a, "--tmpfs", home .. "/.claude", "--remount-ro", home .. "/.claude")
    expect_seq(a, "--tmpfs", home .. "/.claude/hooks", "--remount-ro", home .. "/.claude/hooks")
    expect_seq(a, "--tmpfs", home .. "/.claude/projects/" .. home:gsub("[^%w]", "-") .. "/memory")

    -- a normal project does get its masks
    local project = H.tmpdir()
    local b = wrap(m, { "true" }, project, H.tmpdir())
    expect_seq(b, "--tmpfs", project .. "/.cargo", "--remount-ro", project .. "/.cargo")
    expect_seq(b, "--tmpfs", project .. "/.claude", "--remount-ro", project .. "/.claude")
  end)

  it("emits --ro-bind for the locked paths and ephemeral tmpfs for shell-snapshots/session-env", function()
    if vim.fn.executable("bwrap") ~= 1 then
      return harness.skip("bwrap not found")
    end
    local home = fake_home()
    local m = load_for(home)
    local project = H.tmpdir()
    mkdir(project .. "/.git")
    mkdir(home .. "/.claude/shell-snapshots")
    mkdir(home .. "/.claude/session-env")
    local a = wrap(m, { "true" }, project, H.tmpdir())
    expect_seq(a, "--ro-bind", project .. "/.git", project .. "/.git")
    expect_seq(a, "--tmpfs", home .. "/.claude/shell-snapshots")
    expect_seq(a, "--tmpfs", home .. "/.claude/session-env")
    -- the ro-bind of .git comes after the writable bind of the project
    H.ok(find_seq(a, "--bind", project, project) < find_seq(a, "--ro-bind", project .. "/.git", project .. "/.git"))
    local b = wrap(m, { "true" }, project, H.tmpdir())
    H.ok(b)
    vim.fn.delete(home .. "/.claude/session-env", "rf")
    local c = wrap(m, { "true" }, project, H.tmpdir())
    expect_no_seq(c, "--tmpfs", home .. "/.claude/session-env")
  end)
end)

-- ------------------------------------------------------------ 13: behavioural

describe("sandbox behaviour", function()
  --- A fake home plus a git project, the module loaded for it.
  local function env()
    H.need_sandbox()
    local home = fake_home()
    for _, d in ipairs({ ".config/autostart", ".config/systemd/user", ".claude", ".ssh", ".aws" }) do
      mkdir(home .. "/" .. d)
    end
    write(home .. "/.bashrc", "# real\n")
    write(home .. "/.profile", "# real\n")
    write(home .. "/.ssh/id_rsa", "PRIVATE\n")
    write(home .. "/.aws/credentials", "SECRET\n")
    local project = H.fixture("basic", { git = true })
    return home, load_for(home), project
  end

  it("keeps the project writable and the home read-only", function()
    local home, m, project = env()
    local r = sb(m, home, 'echo ok > inside.txt && cat inside.txt && ! touch "$HOME/xyno-sandbox-probe"', project)
    H.eq(0, r.code, out(r))
    H.eq("ok", vim.trim(vim.fn.readfile(project .. "/inside.txt")[1]))
    H.eq(0, vim.fn.filereadable(home .. "/xyno-sandbox-probe"))
  end)

  it("cannot commit: .git is read-only", function()
    local home, m, project = env()
    local r = sb(
      m, home,
      "echo change >> src/lib.rs; git add -A 2>&1; git -c user.name=t -c user.email=t@t commit -m x 2>&1; "
        .. "echo hook > .git/hooks/pre-commit 2>&1; echo rc=$?",
      project
    )
    H.match(out(r), "Read-only file system", true)
    H.match(r.stdout, "rc=1", true, "a hook cannot be planted: " .. out(r))
    H.eq(1, tonumber(H.git(project, "rev-list", "--count", "HEAD")))
    H.eq(0, vim.fn.filereadable(project .. "/.git/hooks/pre-commit"))
  end)

  it("blocks writes to shell rc files, autostart, systemd and cron, and symlink tricks", function()
    local home, m, project = env()
    local script = table.concat({
      'fail() { if "$@" 2>/dev/null; then echo "WROTE: $*"; fi; }',
      'fail sh -c \'echo x >> "$HOME/.bashrc"\'',
      'fail sh -c \'echo x >> "$HOME/.profile"\'',
      'fail sh -c \'echo x > "$HOME/.config/autostart/evil.desktop"\'',
      'fail sh -c \'echo x > "$HOME/.config/systemd/user/evil.service"\'',
      "fail sh -c 'echo x > /etc/cron.d/evil'",
      "fail sh -c 'echo x > /var/spool/cron/evil'",
      'ln -s "$HOME/.bashrc" link-to-bashrc',
      "fail sh -c 'echo x > link-to-bashrc'",
      "echo done",
    }, "\n")
    local r = sb(m, home, script, project)
    H.match(r.stdout, "done", true, out(r))
    H.no_match(r.stdout, "WROTE", true, out(r))
    H.eq({ "# real" }, vim.fn.readfile(home .. "/.bashrc"))
    H.eq({ "# real" }, vim.fn.readfile(home .. "/.profile"))
  end)

  it("blocks /proc/self/root and /proc/1/root writes, mount, unshare, nested bwrap", function()
    local home, m, project = env()
    local script = table.concat({
      'fail() { if "$@" 2>/dev/null; then echo "WROTE: $*"; fi; }',
      'fail sh -c \'echo x > "/proc/self/root$HOME/.bashrc"\'',
      'fail sh -c \'echo x > "/proc/1/root$HOME/.bashrc"\'',
      "fail mount -t tmpfs none /mnt",
      "fail unshare -r true",
      "fail unshare -U true",
      "fail bwrap --ro-bind / / true",
      "echo done",
    }, "\n")
    local r = sb(m, home, script, project)
    H.match(r.stdout, "done", true, out(r))
    H.no_match(r.stdout, "WROTE", true, out(r))
    H.eq({ "# real" }, vim.fn.readfile(home .. "/.bashrc"))
  end)

  it("shows only a handful of pids", function()
    local home, m, project = env()
    local r = sb(m, home, "ls /proc | grep -c '^[0-9][0-9]*$'", project)
    H.eq(0, r.code, out(r))
    local n = tonumber(vim.trim(r.stdout))
    H.ok(n and n >= 1 and n <= 12, "visible pids: " .. tostring(r.stdout))
  end)

  it("makes ~/.ssh and ~/.aws empty, the docker socket and /run/user/UID invisible", function()
    local home, m, project = env()
    local script = table.concat({
      'echo "ssh=$(cat "$HOME/.ssh/id_rsa" 2>/dev/null | wc -c) aws=$(cat "$HOME/.aws/credentials" 2>/dev/null | wc -c)"',
      "[ -S /run/docker.sock ] && echo DOCKER-VISIBLE",
      "echo run_user=$(ls -A /run/user/" .. uid .. " 2>/dev/null | wc -l)",
    }, "\n")
    local r = sb(m, home, script, project)
    H.eq(0, r.code, out(r))
    H.match(r.stdout, "ssh=0 aws=0", true)
    H.no_match(r.stdout, "DOCKER-VISIBLE", true)
    H.match(r.stdout, "run_user=0", true)
  end)

  it("has no controlling tty (TIOCSTI blocked)", function()
    local home, m, project = env()
    local r = sb(m, home, "(exec 3</dev/tty) 2>/dev/null && echo HAS-TTY || echo no-tty", project)
    H.match(r.stdout, "no-tty", true, out(r))
  end)

  it("builds and compiles tests with cargo inside", function()
    H.need_sandbox()
    if vim.fn.executable("cargo") ~= 1 then
      return harness.skip("cargo not found")
    end
    local project = H.fixture("basic")
    -- the real module and real $HOME: ~/.cargo/registry is bound writable there
    local tmp = H.tmpdir()
    local prev = vim.fn.chdir(project)
    local cmd = real_mod.wrap({ "bash", "-c", "cargo build --offline 2>&1 && cargo test --no-run --offline 2>&1" }, project, tmp)
    vim.fn.chdir(prev)
    local r = vim.system(cmd, { cwd = project, text = true }):wait(240000)
    H.eq(0, r.code, out(r))
    H.eq(1, vim.fn.isdirectory(project .. "/target/debug"))
  end)

  it("runs claude --version inside (when claude is installed)", function()
    H.need_sandbox()
    if vim.fn.executable("claude") ~= 1 then
      return harness.skip("claude not found")
    end
    local tmp = H.tmpdir()
    local project = H.tmpdir()
    local prev = vim.fn.chdir(project)
    local cmd = real_mod.wrap({ "timeout", "60", "claude", "--version" }, project, tmp)
    vim.fn.chdir(prev)
    local r = vim.system(cmd, { cwd = project, text = true }):wait(90000)
    H.eq(0, r.code, out(r))
    H.match(r.stdout, "%d+%.%d+")
  end)
end)

-- ---------------------------------------------------------------- 14: memory

describe("project memory directory", function()
  it("cannot be created, planted, renamed or symlinked, while transcripts stay writable", function()
    H.need_sandbox()
    local home = fake_home()
    mkdir(home .. "/.claude")
    local m = load_for(home)
    local base = H.tmpdir()
    mkdir(base .. "/proj")
    local project = vim.uv.fs_realpath(base .. "/proj")
    local d = home .. "/.claude/projects/" .. project:gsub("[^%w]", "-")
    local script = table.concat({
      'd="' .. d .. '"',
      'fail() { if "$@" 2>/dev/null; then echo "WROTE: $*"; fi; }',
      'fail mkdir -p "$d/memory/sub"',
      'fail sh -c \'echo planted > "$d/memory/MEMORY.md"\'',
      'fail mv "$d/memory" "$d/memory-moved"',
      'fail sh -c \'mkdir /tmp/x && mv /tmp/x "$d/memory2" && mv "$d/memory2" "$d/memory"\'',
      'fail ln -sfn /tmp "$d/memory"',
      'fail sh -c \'rm -rf "$d" && ln -s /tmp "$d"\'',
      'echo transcript > "$d/s.jsonl" && echo transcript-ok',
    }, "\n")
    local r = sb(m, home, script, project)
    H.match(r.stdout, "transcript-ok", true, out(r))
    H.no_match(r.stdout, "WROTE", true, out(r))
    H.eq({ "transcript" }, vim.fn.readfile(d .. "/s.jsonl"))
    H.eq({}, vim.fn.glob(d .. "/memory/*", true, true))
    H.eq(0, vim.fn.filereadable(d .. "/memory/MEMORY.md"))
  end)
end)

describe("former known bugs", function()
  it("renaming ~/.claude/projects/<name> cannot be used to plant memory/MEMORY.md", function()
    H.need_sandbox()
    local home = fake_home()
    local m = load_for(home)
    local base = H.tmpdir()
    mkdir(base .. "/proj")
    local project = vim.uv.fs_realpath(base .. "/proj")
    local d = home .. "/.claude/projects/" .. project:gsub("[^%w]", "-")
    local script = table.concat({
      'd="' .. d .. '"',
      'mv "$d" "$d-moved" 2>/dev/null && echo MOVED',
      'mkdir -p "$d/memory" 2>/dev/null',
      'echo planted > "$d/memory/MEMORY.md" 2>/dev/null && echo PLANTED',
      -- other projects' transcripts are read-only too
      'mkdir -p "' .. home .. '/.claude/projects/other" 2>/dev/null && echo OTHER-CREATED',
      'echo ok',
    }, "\n")
    local r = sb(m, home, script, project)
    H.match(r.stdout, "ok", true, out(r))
    H.no_match(r.stdout, "MOVED", true, out(r))
    H.no_match(r.stdout, "PLANTED", true, out(r))
    H.no_match(r.stdout, "OTHER-CREATED", true, out(r))
    H.eq(0, vim.fn.filereadable(d .. "/memory/MEMORY.md"), "MEMORY.md planted in the real ~/.claude")
    H.eq(0, vim.fn.isdirectory(d .. "-moved"))
  end)

  it("wrap works when ~/.claude does not exist (fresh machine)", function()
    H.need_sandbox()
    local home = fake_home({ no_claude = true })
    local m = load_for(home)
    local r = sb(m, home, "echo alive", H.tmpdir())
    H.eq(0, r.code, out(r))
    H.match(r.stdout, "alive", true)
  end)

  it("~/.claude/security (the hook's python venv) is read-only, also when it did not exist", function()
    H.need_sandbox()
    local home = fake_home()
    local m = load_for(home)
    mkdir(home .. "/.claude/security/agent-sdk-venv/lib")
    local project = H.tmpdir()
    local r = sb(m, home, 'touch "' .. home .. '/.claude/security/agent-sdk-venv/lib/x.pth" 2>/dev/null && echo WRITABLE; echo done', project)
    H.match(r.stdout, "done", true, out(r))
    H.no_match(r.stdout, "WRITABLE", true, out(r))
    H.eq(0, vim.fn.filereadable(home .. "/.claude/security/agent-sdk-venv/lib/x.pth"))

    local home2 = fake_home()
    local m2 = load_for(home2)
    local r2 = sb(m2, home2, 'mkdir "' .. home2 .. '/.claude/security" 2>/dev/null && echo CREATED; echo done', project)
    H.match(r2.stdout, "done", true, out(r2))
    H.no_match(r2.stdout, "CREATED", true, out(r2))
  end)
end)

-- --------------------------------------------------------------- 16: network

describe("network", function()
  local function listener(host)
    local srv = vim.uv.new_tcp()
    local ok = srv:bind(host, 0)
    if not ok or not srv:listen(8, function() end) then
      srv:close()
      return nil
    end
    return srv, srv:getsockname().port
  end

  it("reaches loopback listeners (documented residual; ::1 too, the netns is shared) but not /run/user/UID", function()
    H.need_sandbox()
    local srv, port = listener("127.0.0.1")
    H.ok(srv, "could not listen on 127.0.0.1")
    local srv6, port6 = listener("::1")
    local home = fake_home()
    local m = load_for(home)
    local script = table.concat({
      "(exec 3<>/dev/tcp/127.0.0.1/" .. port .. ") 2>/dev/null && echo v4=reachable || echo v4=blocked",
      port6 and ("(exec 3<>/dev/tcp/::1/" .. port6 .. ") 2>/dev/null && echo v6=reachable || echo v6=blocked") or "echo v6=nolistener",
      "[ -e /run/user/" .. uid .. "/bus ] && echo bus=visible || echo bus=hidden",
    }, "\n")
    local r = sb(m, home, script, H.tmpdir())
    srv:close()
    if srv6 then
      srv6:close()
    end
    H.eq(0, r.code, out(r))
    H.match(r.stdout, "v4=reachable", true)
    H.match(r.stdout, "bus=hidden", true)
    if srv6 then
      -- README says ::1 is not reachable; with a real listener it is (shared network namespace)
      H.match(r.stdout, "v6=reachable", true)
    end
  end)
end)

-- ------------------------------------------------------------ 18: CI skipping

describe("headless skip", function()
  it("sandbox_available reports why when bwrap is missing, and need_sandbox skips", function()
    setenv("PATH", "/nonexistent-xyno-path")
    local ok, why = H.sandbox_available()
    H.eq(false, ok)
    H.match(why, "bwrap not found", true)
    local pok, err = pcall(H.need_sandbox)
    H.not_ok(pok)
    H.ok(harness.is_skip(err), "need_sandbox raises a skip, not an error")
    H.match(err.reason, "bwrap not found", true)
  end)

  it("need_sandbox skips with the bwrap message when a user namespace cannot be created", function()
    -- a fake bwrap that fails like a CI container without userns
    local bin = H.tmpdir()
    write(bin .. "/bwrap", "#!/bin/sh\necho 'bwrap: No permissions to create a new namespace' >&2\nexit 1\n")
    vim.uv.fs_chmod(bin .. "/bwrap", tonumber("755", 8))
    setenv("PATH", bin .. ":" .. vim.uv.os_getenv("PATH"))
    local ok, why = H.sandbox_available()
    H.eq(false, ok)
    H.match(why, "bwrap cannot create a sandbox here", true)
    H.match(why, "No permissions to create a new namespace", true)
  end)
end)

-- ------------------------------------------------------------ 19: README docs

describe("README residual-risk claims", function()
  it("documents the residual risks that cannot be tested mechanically", function()
    local f = assert(io.open(H.repo .. "/README.md"))
    local text = f:read("a")
    f:close()
    for _, claim in ipairs({
      "`~/.claude/.credentials.json` must stay readable",
      "everything unlisted under `$HOME` is readable",
      "loopback services",
      "nested `.git` deeper than 2 levels is not locked",
    }) do
      H.has(text, claim)
    end
  end)
end)
