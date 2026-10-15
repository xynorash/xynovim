-- "New egui Project" on the snacks dashboard (config/egui_new.lua, :EguiNew).
-- LazyVim's preset.keys list is extended in place, before "Quit"; the stock
-- keys use f n g r c s x l q, so `e` is free.
return {
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      opts.dashboard = opts.dashboard or {}
      opts.dashboard.preset = opts.dashboard.preset or {}
      local keys = opts.dashboard.preset.keys or {}
      opts.dashboard.preset.keys = keys
      for _, k in ipairs(keys) do
        if k.key == "e" then
          return
        end
      end
      local at = #keys + 1
      for i, k in ipairs(keys) do
        if k.desc == "Quit" then
          at = i
          break
        end
      end
      table.insert(keys, at, { icon = "󰏗 ", key = "e", desc = "New egui Project", action = ":EguiNew" })
    end,
  },
}
