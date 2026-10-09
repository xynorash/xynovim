-- 99 launches `claude --dangerously-skip-permissions` with the user's full
-- privileges. Wrap it in bubblewrap: the whole filesystem is read-only except
-- the project, 99's tmp dir, claude's own state and cargo's download caches;
-- credential dirs are hidden behind empty tmpfs mounts, and git/claude hook
-- and settings paths stay read-only inside the writable binds. Network stays open
-- (the model needs it). Opt out with `vim.g.xynovim_99_sandbox = false`.
local M = {}

local home = vim.uv.os_homedir()

-- Writable inside the sandbox when they exist.
local WRITABLE = {
  home .. "/.claude",
  home .. "/.claude.json",
  home .. "/.config/claude",
  home .. "/.cache/claude",
  home .. "/.local/share/claude",
  home .. "/.local/state/claude",
  home .. "/.cargo/registry",
  home .. "/.cargo/git",
}

-- Hidden (dirs: empty tmpfs, files: bound to /dev/null) when they exist.
-- This is a denylist on a read-only view of the whole filesystem, so it is
-- best effort: anything not listed is still readable, and the network is open.
local HIDDEN = {
  home .. "/.ssh",
  home .. "/.gnupg",
  home .. "/.aws",
  home .. "/.config/gh",
  home .. "/.config/rclone",
  home .. "/.password-store",
  home .. "/.local/share/keyrings",
  home .. "/.config/google-chrome",
  home .. "/.docker",
  home .. "/.kube",
  home .. "/.netrc",
  home .. "/.git-credentials",
  home .. "/.npmrc",
  home .. "/.cargo/credentials.toml",
  home .. "/.bash_history",
  "/run/user/" .. vim.uv.os_get_passwd().uid, -- gpg/ssh agent, keyring and dbus sockets
}

-- Credential variables stripped from the environment.
local UNSET = { "GITHUB_TOKEN", "GH_TOKEN", "SSH_AUTH_SOCK", "GPG_AGENT_INFO", "AWS_SECRET_ACCESS_KEY" }

-- Re-bound read-only on top of the writable binds: whatever the agent plants
-- here would later run unsandboxed (git hooks, claude hooks/settings).
local function readonly_paths(project)
  return {
    project .. "/.git/hooks",
    project .. "/.git/config",
    home .. "/.claude/settings.json",
    home .. "/.claude/settings.local.json",
    home .. "/.claude/hooks",
    home .. "/.claude/commands",
    home .. "/.claude/CLAUDE.md",
  }
end

local function exists(p)
  return vim.uv.fs_stat(p) ~= nil
end

--- @param cmd string[] command to wrap
--- @param project string project root (writable)
--- @param tmp_dir string 99's tmp dir (writable)
--- @return string[]
function M.wrap(cmd, project, tmp_dir)
  if vim.g.xynovim_99_sandbox == false or vim.fn.executable("bwrap") ~= 1 then
    return cmd
  end
  local a = { "bwrap", "--die-with-parent", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp" }
  for _, p in ipairs(HIDDEN) do
    local st = vim.uv.fs_stat(p)
    if st then
      vim.list_extend(a, st.type == "directory" and { "--tmpfs", p } or { "--ro-bind", "/dev/null", p })
    end
  end
  for _, v in ipairs(UNSET) do
    vim.list_extend(a, { "--unsetenv", v })
  end
  -- Never make $HOME or / writable just because nvim was started there.
  local rw = vim.list_extend({ tmp_dir }, WRITABLE)
  if project ~= home and project ~= "/" then
    table.insert(rw, 1, project)
  end
  for _, p in ipairs(rw) do
    if exists(p) then
      vim.list_extend(a, { "--bind", p, p })
    end
  end
  for _, p in ipairs(readonly_paths(project)) do
    if exists(p) then
      vim.list_extend(a, { "--ro-bind", p, p })
    end
  end
  vim.list_extend(a, { "--chdir", vim.uv.cwd() or project, "--" })
  return vim.list_extend(a, cmd)
end

return M
