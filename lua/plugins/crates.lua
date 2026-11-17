-- crates.nvim (LazyVim's lang.rust extra): "There is an upgrade available" appeared twice per line.
--
-- crates.nvim appends to a per-buffer list and publishes the whole list with vim.diagnostic.set on
-- every display_diagnostics call. A crate's diagnostics are added once by the update that runs when a
-- crates.io answer arrives and once by the next update that finds the answer cached, so every
-- diagnostic of the crate (not only the upgrade one) is set twice: two bullets in the virtual text,
-- two entries in Trouble and the location list. Upstream behaviour (checked with crates.nvim
-- 7039bc1, 2026-09-12, against serde = "0.9"); here the two namespaces crates.nvim owns are
-- de-duplicated on their way to vim.diagnostic.set.
local function key(d)
  return table.concat(
    { d.lnum, d.col, d.end_lnum or "", d.end_col or "", d.severity or "", d.source or "", d.message or "" },
    "\0"
  )
end

--- The diagnostics without exact repeats, in order.
local function unique(diagnostics)
  local seen, out = {}, {}
  for _, d in ipairs(diagnostics) do
    local k = key(d)
    if not seen[k] then
      seen[k] = true
      out[#out + 1] = d
    end
  end
  return out
end

local installed = false

local function dedupe_crates_diagnostics()
  if installed then
    return
  end
  installed = true
  local own = {
    [vim.api.nvim_create_namespace("crates.nvim")] = true,
    [vim.api.nvim_create_namespace("crates.nvim.diagnostic")] = true,
  }
  local set = vim.diagnostic.set
  vim.diagnostic.set = function(namespace, bufnr, diagnostics, opts)
    if own[namespace] and type(diagnostics) == "table" then
      diagnostics = unique(diagnostics)
    end
    return set(namespace, bufnr, diagnostics, opts)
  end
end

return {
  "Saecki/crates.nvim",
  config = function(_, opts)
    dedupe_crates_diagnostics()
    require("crates").setup(opts)
  end,
}
