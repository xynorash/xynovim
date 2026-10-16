-- Small file-system helpers whose behaviour differs between platforms.
local M = {}

--- uv.fs_rename(tmp, dest) that survives Windows' sharing violations: renaming
--- over a file another process holds open (rust-analyzer, an editor) fails
--- with EPERM/EACCES/EBUSY until it lets go, so retry a few times there.
--- Returns what fs_rename returns (true, or nil + error).
function M.rename(tmp, dest)
  local ok, err, name = vim.uv.fs_rename(tmp, dest)
  if ok or vim.fn.has("win32") ~= 1 then
    return ok, err, name
  end
  for _ = 1, 5 do
    vim.wait(60)
    ok, err, name = vim.uv.fs_rename(tmp, dest)
    if ok then
      return ok
    end
  end
  return ok, err, name
end

--- Forward slashes (Windows only; elsewhere the path is returned untouched):
--- buffer names, cwd and LSP roots come back with backslashes there, while the
--- code compares prefixes and matches "/.cargo/registry/" style fragments.
function M.slash(p)
  if p and vim.fn.has("win32") == 1 then
    return (p:gsub("\\", "/"))
  end
  return p
end

return M
