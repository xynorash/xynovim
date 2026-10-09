-- 99 launches `claude --dangerously-skip-permissions` with the user's full
-- privileges. Wrap it in bubblewrap: the whole filesystem is read-only except
-- the project, 99's tmp dir, claude's own state and cargo's download caches;
-- credentials dirs are hidden behind empty tmpfs mounts. Network stays open
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

-- Hidden (replaced by an empty tmpfs) when they exist.
local HIDDEN = {
  home .. "/.ssh",
  home .. "/.gnupg",
  home .. "/.aws",
  home .. "/.config/gh",
  home .. "/.config/rclone",
  home .. "/.password-store",
}

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
    if exists(p) then
      vim.list_extend(a, { "--tmpfs", p })
    end
  end
  local rw = vim.list_extend({ project, tmp_dir }, WRITABLE)
  for _, p in ipairs(rw) do
    if exists(p) then
      vim.list_extend(a, { "--bind", p, p })
    end
  end
  vim.list_extend(a, { "--chdir", vim.uv.cwd() or project, "--" })
  return vim.list_extend(a, cmd)
end

return M
