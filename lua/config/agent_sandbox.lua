-- 99 launches `claude --dangerously-skip-permissions` with the user's full
-- privileges. Wrap it in bubblewrap. The whole filesystem is read-only except
-- the project, 99's tmp dir, and the few paths claude/cargo must write.
-- Everything that would later run UNSANDBOXED (git hooks/config, claude
-- settings/hooks/plugins, direnv, editor task files, cargo config, the claude
-- binary) is read-only even inside the writable binds. Credential dirs/files
-- are hidden, credential env vars are stripped, pid/ipc/uts namespaces are
-- unshared, capabilities dropped, nested user namespaces disabled.
-- Network stays open (the model needs it). Opt out with
-- `vim.g.xynovim_99_sandbox = false`.
local M = {}

local home = vim.uv.os_homedir()
local uid = vim.uv.os_get_passwd().uid

-- Writable inside the sandbox (when they exist). Deliberately NOT here:
-- ~/.local/share/claude (the claude binary), ~/.cargo/bin, ~/.cargo/config.toml.
local WRITABLE = {
  home .. "/.claude", -- sessions/projects/todos/cache/...; exec-ish parts re-locked below
  home .. "/.cache/claude",
  home .. "/.local/state/claude",
  home .. "/.cargo/registry",
  home .. "/.cargo/git",
  home .. "/.cargo/.package-cache", -- cargo's download locks (files)
  home .. "/.cargo/.package-cache-mutate",
}

-- Re-bound read-only on top of the writable binds when they exist. Whatever an
-- agent planted here would run (or steer a tool) outside the sandbox later.
local HOME_READONLY = {
  home .. "/.claude/settings.json",
  home .. "/.claude/settings.local.json",
  home .. "/.claude/CLAUDE.md",
  home .. "/.claude/keybindings.json",
  home .. "/.claude/hooks",
  home .. "/.claude/commands",
  home .. "/.claude/agents",
  home .. "/.claude/skills",
  home .. "/.claude/plugins",
  home .. "/.claude/output-styles",
  home .. "/.claude/ide", -- IDE lock files make claude connect to a local server
  home .. "/.claude/rules",
  home .. "/.claude/chrome", -- chrome-native-host is a shell script Chrome launches unsandboxed
  home .. "/.claude/security", -- the security-guidance hook imports from agent-sdk-venv here, unsandboxed
}

-- Same dirs, but when ABSENT the agent could create them (a later unsandboxed
-- claude would load them: prompt injection), so mask them with an empty
-- read-only dir (leaves one empty dir behind in ~/.claude).
local HOME_MASK_IF_ABSENT = {
  home .. "/.claude/hooks",
  home .. "/.claude/commands",
  home .. "/.claude/agents",
  home .. "/.claude/skills",
  home .. "/.claude/rules",
  home .. "/.claude/output-styles",
  home .. "/.claude/security",
}

-- Ephemeral inside the sandbox: claude sources these before running commands.
local HOME_EPHEMERAL = {
  home .. "/.claude/shell-snapshots",
  home .. "/.claude/session-env",
}

-- Project-relative auto-executing / tool-steering files (locked when present).
local PROJECT_READONLY = {
  ".gitmodules",
  ".envrc",
  ".mise.toml",
  ".tool-versions",
  ".nvim.lua",
  ".nvimrc",
  ".exrc",
  ".vscode/tasks.json",
  ".vscode/settings.json",
  ".cargo", -- whole dir: config.toml sets runner / linker / rustflags and runs on the next cargo build
  ".vscode", -- whole dir, so tasks.json cannot be swapped by renaming the parent
  ".mcp.json",
}
-- Locked in workspace members (depth <= 3) too: cargo reads .cargo/config from
-- every ancestor of the directory it runs in; direnv reads the nearest .envrc.
local MEMBER_READONLY = { ".cargo", ".envrc" }
-- Created empty-and-read-only when absent at the project root (leaves an empty
-- .cargo dir behind): a planted .cargo/config.toml is the one that bites.
-- .git too: without one the agent ran `git init` and planted `core.fsmonitor = <cmd>` in
-- .git/config, which the user's next unsandboxed `git status` executed. (A later `git init`
-- needs `rmdir .git` first: the mask leaves an empty dir behind.)
local PROJECT_MASK_IF_ABSENT = { ".cargo", ".git" }
-- Project dir that is ALWAYS locked: read-only when present, otherwise masked
-- with an empty read-only dir (leaves one empty dir behind), because a planted
-- .claude/settings.local.json with hooks would run on the user's next claude.
local PROJECT_MASKED = ".claude"

-- Hidden (dirs: empty tmpfs, files: bound to /dev/null) when they exist.
-- This is a denylist on a read-only view of the whole filesystem, so it is
-- best effort: anything not listed is still readable, and the network is open.
local HIDDEN = {
  -- shell/CLI credentials
  "/.ssh", "/.gnupg", "/.aws", "/.azure", "/.gsutil", "/.boto", "/.docker", "/.kube",
  "/.terraform.d", "/.vault-token", "/.netrc", "/.git-credentials", "/.npmrc", "/.pypirc",
  "/.cargo/credentials", "/.cargo/credentials.toml", "/.pub-cache/credentials.json",
  "/.android/adbkey", "/.pki", "/.password-store", "/.Xauthority", "/.pulse-cookie",
  -- ~/.config
  "/.config/gh", "/.config/git/credentials", "/.config/rclone", "/.config/pulumi",
  "/.config/helm", "/.config/gcloud", "/.config/op", "/.config/doctl", "/.config/hub",
  "/.config/Bitwarden", "/.config/1Password", "/.config/keepassxc", "/.config/pulse",
  "/.config/Slack", "/.config/discord", "/.config/Signal", "/.config/rustdesk",
  "/.config/winapps", "/.config/freerdp", "/.config/obs-studio", "/.config/JetBrains",
  "/.config/spotify", "/.config/herdr", "/.anydesk", "/.neuralstark-live",
  -- browsers / mail
  "/.config/google-chrome", "/.config/google-chrome-headless", "/.config/Google",
  "/.config/chromium", "/.config/BraveSoftware", "/.config/microsoft-edge",
  "/.config/vivaldi", "/.config/opera", "/.mozilla", "/.thunderbird", "/.cache/google-chrome",
  -- ~/.local/share
  "/.local/share/keyrings", "/.local/share/password-store", "/.local/share/gnome-keyring",
  "/.local/share/kwalletd", "/.local/share/TelegramDesktop", "/.local/share/fish",
  "/.local/share/winapps",
  -- remote-control keys of other claude sessions / the claude daemon
  "/.claude/daemon", "/.claude/sessions",
  -- every prompt typed in any project (readable, and it was writable too)
  "/.claude/history.jsonl",
}
-- Globs under $HOME (shell and tool histories).
local HIDDEN_GLOBS = { "/.*_history*", "/.lesshst", "/.config/fish/fish_history" }
-- Absolute system paths: container/dbus sockets are root-equivalent (the user
-- is in group docker) or reach other services; /run/user holds the gpg/ssh
-- agent, keyring, wayland and session-bus sockets.
local HIDDEN_SYSTEM = {
  "/run/user/" .. uid,
  "/run/docker.sock", "/run/docker", "/run/containerd", "/run/podman", "/run/libvirt",
  "/run/dbus", "/run/snapd.socket", "/run/snapd-snap.socket",
  -- tailscaled.sock is mode 0666: `tailscale status` listed the peers and RunSSH was on
  "/run/tailscale", "/run/seatd.sock",
}

-- Environment scrub: any variable whose name contains one of these ...
local ENV_CONTAINS = {
  "TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "APIKEY", "CREDENTIAL", "PRIVATE_KEY",
  "ACCESS_KEY", "AUTH_SOCK", "AGENT_INFO", "PASSPHRASE", "ASKPASS",
}
-- ... or starts with one of these ...
local ENV_PREFIX = {
  "AWS_", "AZURE_", "GOOGLE_", "GCP_", "GCLOUD_", "DOCKER_", "KUBE", "GH_", "GITHUB_", "GITLAB_",
  "NPM_", "CARGO_REGISTR", "VAULT_", "OPENAI_", "STRIPE_",
}
-- ... or is exactly one of these (session bus / display access).
local ENV_EXACT = {
  DATABASE_URL = true, DBUS_SESSION_BUS_ADDRESS = true, DISPLAY = true, WAYLAND_DISPLAY = true,
  XAUTHORITY = true, SSH_AUTH_SOCK = true, GPG_AGENT_INFO = true, KUBECONFIG = true,
  MYSQL_PWD = true, SSHPASS = true, -- not a "PASSWORD" by name; a bare PWD would also be the cwd
}
-- Variables claude itself authenticates with. Kept only when login is NOT
-- file based (no ~/.claude/.credentials.json); with file-based login claude
-- never reads them, so they are just secrets to strip.
local ENV_CLAUDE_AUTH = { "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN" }

local function exists(p)
  return vim.uv.fs_stat(p) ~= nil
end

--- Names to `--unsetenv`, computed from the live environment.
--- @param env? table<string,string> defaults to vim.fn.environ()
--- @param file_login? boolean defaults to: ~/.claude/.credentials.json exists
--- @return string[]
function M.scrub_names(env, file_login)
  env = env or vim.fn.environ()
  if file_login == nil then
    file_login = exists(home .. "/.claude/.credentials.json")
  end
  local keep = {}
  if not file_login then
    for _, v in ipairs(ENV_CLAUDE_AUTH) do
      keep[v] = true
    end
  end
  local out = {}
  for name in pairs(env) do
    local u = name:upper()
    local hit = ENV_EXACT[u] or false
    for _, s in ipairs(ENV_CONTAINS) do
      hit = hit or u:find(s, 1, true) ~= nil
    end
    for _, s in ipairs(ENV_PREFIX) do
      hit = hit or u:sub(1, #s) == s
    end
    if hit and not keep[name] then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

--- Real gitdir (and shared commondir) behind a `.git` FILE ("gitdir: ..." of
--- worktrees, submodules and bare-repo layouts).
local function resolve_gitfile(dotgit, dir)
  local out = {}
  local f = io.open(dotgit, "r")
  if not f then
    return out
  end
  local line = f:read("l") or ""
  f:close()
  local gd = line:match("^gitdir:%s*(.-)%s*$")
  if not gd or gd == "" then
    return out
  end
  if not gd:match("^/") then
    gd = dir .. "/" .. gd
  end
  gd = vim.uv.fs_realpath(gd)
  if not gd then
    return out
  end
  out[#out + 1] = gd
  local cf = io.open(gd .. "/commondir", "r")
  if cf then
    local cd = cf:read("l")
    cf:close()
    if cd and cd ~= "" then
      cd = vim.uv.fs_realpath(cd:match("^/") and cd or (gd .. "/" .. cd))
      if cd then
        out[#out + 1] = cd
      end
    end
  end
  return out
end

local SCAN_SKIP = { target = true, node_modules = true, [".git"] = true, [".cache"] = true }

--- Every `.git` (dir or file) in the project and 2 levels below (submodules,
--- nested checkouts) plus the real gitdirs behind `.git` files.
--- @return string[]
local function git_paths(project)
  local out, seen = {}, {}
  local function add(p)
    if not seen[p] and exists(p) then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  local function scan(dir, depth)
    local dotgit = dir .. "/.git"
    local st = vim.uv.fs_stat(dotgit)
    if st then
      if st.type == "file" then
        for _, p in ipairs(resolve_gitfile(dotgit, dir)) do
          add(p)
        end
      end
      add(dotgit)
    end
    if depth < 2 then
      for name, t in vim.fs.dir(dir) do
        if t == "directory" and not SCAN_SKIP[name] then
          scan(dir .. "/" .. name, depth + 1)
        end
      end
    end
  end
  scan(project, 0)
  return out
end

--- ~/.claude/projects/<name> of this project: claude names it after its cwd
--- (every non-alphanumeric character as "-"), project root and cwd, real and
--- as given. These are the only parts of ~/.claude/projects left writable.
--- @return string[]
local function own_project_dirs(project)
  local cwd = vim.uv.cwd() or project
  local out, seen = {}, {}
  for _, d in ipairs({ project, cwd, vim.uv.fs_realpath(project) or project, vim.uv.fs_realpath(cwd) or cwd }) do
    local dir = home .. "/.claude/projects/" .. d:gsub("[^%w]", "-")
    if not seen[dir] then
      seen[dir] = true
      out[#out + 1] = dir
    end
  end
  return out
end

--- Paths re-bound read-only on top of the writable binds.
--- @param project string
--- @return string[] ro, string[] masks  masks: absent dirs to cover with an empty read-only tmpfs
function M.readonly_paths(project)
  local ro = git_paths(project)
  local seen = {}
  for _, p in ipairs(ro) do
    seen[p] = true
  end
  local function lock(p)
    if not seen[p] and exists(p) then
      seen[p] = true
      ro[#ro + 1] = p
    end
  end
  -- Started in $HOME (or /): the project-relative locks would hit ~/.claude and ~/.cargo, the
  -- writable binds claude needs; $HOME is not writable here anyway.
  local at_home = project == home or project == "/"
  for _, rel in ipairs(at_home and {} or PROJECT_READONLY) do
    lock(project .. "/" .. rel)
  end
  local member_masks = {}
  local function scan_members(dir, depth)
    for name, t in vim.fs.dir(dir) do
      if t == "directory" and not SCAN_SKIP[name] and name:sub(1, 1) ~= "." then
        local d = dir .. "/" .. name
        for _, rel in ipairs(MEMBER_READONLY) do
          lock(d .. "/" .. rel)
        end
        if exists(d .. "/Cargo.toml") and not exists(d .. "/.cargo") then
          member_masks[#member_masks + 1] = d .. "/.cargo"
        end
        if depth < 3 then
          scan_members(d, depth + 1)
        end
      end
    end
  end
  if not at_home then
    scan_members(project, 1)
  end
  for _, p in ipairs(HOME_READONLY) do
    lock(p)
  end
  for _, p in ipairs(vim.fn.glob(home .. "/.claude/projects/*/memory", true, true)) do
    lock(p) -- MEMORY.md auto-loads into the next unsandboxed session
  end
  -- Absent dirs to mask with an empty read-only tmpfs.
  local masks = member_masks
  -- This project's own memory dir, also while it does not exist yet (claude
  -- names it ~/.claude/projects/<path with every non-alphanumeric as "-">/memory
  -- from its cwd): otherwise the agent could plant a MEMORY.md that the next
  -- unsandboxed session loads. Needs ~/.claude (the mask is made inside it).
  if exists(home .. "/.claude") then
    for _, d in ipairs(own_project_dirs(project)) do
      local mem = d .. "/memory"
      if not seen[mem] and not exists(mem) then
        seen[mem] = true
        masks[#masks + 1] = mem
      end
    end
  end
  for _, rel in ipairs(at_home and {} or PROJECT_MASK_IF_ABSENT) do
    if not exists(project .. "/" .. rel) then
      masks[#masks + 1] = project .. "/" .. rel
    end
  end
  if at_home then
    -- (~/.claude is writable here: HOME_READONLY locks what must not change)
  elseif not exists(project .. "/" .. PROJECT_MASKED) then
    masks[#masks + 1] = project .. "/" .. PROJECT_MASKED
  else
    lock(project .. "/" .. PROJECT_MASKED)
  end
  for _, p in ipairs(HOME_MASK_IF_ABSENT) do
    if not exists(p) then
      masks[#masks + 1] = p
    end
  end
  return ro, masks
end

--- @param cmd string[] command to wrap
--- @param project string project root (writable)
--- @param tmp_dir string 99's tmp dir (writable)
--- @return string[]
function M.wrap(cmd, project, tmp_dir)
  assert(type(tmp_dir) == "string" and tmp_dir ~= "", "agent_sandbox.wrap: tmp_dir is required")
  if vim.g.xynovim_99_sandbox == false or vim.fn.executable("bwrap") ~= 1 then
    return cmd
  end
  -- The ~/.claude/<x> masks need the dir (bwrap cannot mkdir parents on the
  -- read-only root), and a fresh machine has none until claude first runs.
  vim.fn.mkdir(home .. "/.claude", "p")
  local a = {
    "bwrap", "--die-with-parent",
    "--new-session", -- no controlling tty: TIOCSTI keystroke injection
    "--unshare-user", "--disable-userns", -- no nested bwrap / unshare -r
    "--unshare-pid", -- other processes (/proc/PID/environ, /proc/PID/root) invisible
    "--unshare-ipc", "--unshare-uts", "--unshare-cgroup-try",
    "--cap-drop", "ALL",
    "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
  }

  for _, v in ipairs(M.scrub_names()) do
    vim.list_extend(a, { "--unsetenv", v })
  end

  -- Never make $HOME or / writable just because nvim was started there.
  local rw = { tmp_dir }
  if project ~= home and project ~= "/" then
    table.insert(rw, 1, project)
  end
  vim.list_extend(rw, WRITABLE)
  for _, p in ipairs(rw) do
    if exists(p) then
      vim.list_extend(a, { "--bind", p, p })
    end
  end

  -- After the writable binds: hides inside ~/.claude must sit on top of it.
  -- A hidden file reads as empty: /dev/null bound there gave EACCES (the bind is nodev),
  -- an empty regular file does not.
  local empty
  local function hide(p)
    local st = vim.uv.fs_stat(p)
    if st then
      if st.type ~= "directory" and not empty then
        empty = vim.fn.tempname() .. ".empty"
        vim.fn.writefile({}, empty)
      end
      vim.list_extend(a, st.type == "directory" and { "--tmpfs", p } or { "--ro-bind", empty, p })
    end
  end
  for _, p in ipairs(HIDDEN_SYSTEM) do
    hide(p)
  end
  for _, p in ipairs(HIDDEN) do
    hide(home .. p)
  end
  for _, g in ipairs(HIDDEN_GLOBS) do
    for _, p in ipairs(vim.fn.glob(home .. g, true, true)) do
      hide(p)
    end
  end

  -- ~/.claude.json holds user-scope mcpServers (= commands the next claude
  -- runs unsandboxed). Give the sandbox a private COPY: it works, but nothing
  -- it writes reaches the real file.
  local cj = home .. "/.claude.json"
  if exists(cj) then
    local copy = vim.fn.tempname() .. ".claude.json"
    if vim.uv.fs_copyfile(cj, copy) then
      vim.uv.fs_chmod(copy, tonumber("600", 8))
      vim.list_extend(a, { "--bind", copy, cj })
    end
  end

  -- ~/.claude/projects is read-only except this project's own transcript dir:
  -- a bind mount point cannot be renamed, so `mv projects/<name> ...; mkdir -p
  -- projects/<name>/memory` cannot get round the memory mask (other projects'
  -- transcripts and memory are read-only too).
  local projects = home .. "/.claude/projects"
  vim.fn.mkdir(projects, "p")
  vim.list_extend(a, { "--ro-bind", projects, projects })
  for _, d in ipairs(own_project_dirs(project)) do
    vim.fn.mkdir(d, "p")
    vim.list_extend(a, { "--bind", d, d })
  end

  local ro, masks = M.readonly_paths(project)
  for _, p in ipairs(ro) do
    vim.list_extend(a, { "--ro-bind", p, p })
  end
  for _, p in ipairs(masks) do
    -- project-relative masks (.cargo, .claude) would hit $HOME's own when the
    -- project is $HOME; the ones inside ~/.claude are safe either way
    if (project ~= home and project ~= "/") or p:find(home .. "/.claude/", 1, true) == 1 then
      vim.list_extend(a, { "--tmpfs", p, "--remount-ro", p })
    end
  end
  for _, p in ipairs(HOME_EPHEMERAL) do
    if exists(p) then
      vim.list_extend(a, { "--tmpfs", p })
    end
  end

  -- nvim's own cwd only when it is inside the project: from $HOME the agent started in $HOME, and
  -- a cwd outside the project (e.g. under /tmp, which is a tmpfs here) made bwrap fail on chdir
  local cwd = vim.uv.cwd()
  local inside = cwd and (cwd == project or project == "/" or cwd:sub(1, #project + 1) == project .. "/")
  vim.list_extend(a, { "--chdir", inside and cwd or project, "--" })
  return vim.list_extend(a, cmd)
end

return M
