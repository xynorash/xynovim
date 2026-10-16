-- "New Rust Binary / Library / Workspace" on the snacks dashboard (config/rust_new.lua,
-- :RustNewBin, :RustNewLib, :RustNewWorkspace). LazyVim's stock keys use f n p g r c s x l q and
-- the egui entry e; b (binary), i (library) and w (workspace) are free. The three sit
-- before "New egui Project" (which stays right before Quit), else before Quit.
local ENTRIES = {
  { icon = " ", key = "b", desc = "New Rust Binary", action = ":RustNewBin" },
  { icon = " ", key = "i", desc = "New Rust Library", action = ":RustNewLib" },
  { icon = "󰙅 ", key = "w", desc = "New Rust Workspace", action = ":RustNewWorkspace" },
}

return {
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      opts.dashboard = opts.dashboard or {}
      opts.dashboard.preset = opts.dashboard.preset or {}
      local keys = opts.dashboard.preset.keys or {}
      opts.dashboard.preset.keys = keys
      for _, k in ipairs(keys) do
        if k.action == ":RustNewBin" then
          return
        end
      end
      local at = #keys + 1
      for i, k in ipairs(keys) do
        if k.desc == "New egui Project" then
          at = i
          break
        elseif k.desc == "Quit" then
          at = i
        end
      end
      for n, e in ipairs(ENTRIES) do
        table.insert(keys, at + n - 1, vim.deepcopy(e))
      end
    end,
  },
}
