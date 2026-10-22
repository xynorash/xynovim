-- The bubblewrap sandbox of the 99 agent, from the xyno-sandbox.nvim plugin. Lazy: 99 depends on it
-- (plugins/ninety-nine.lua) and require("xyno_sandbox") loads it. No :XynoSandbox* commands and no
-- keymap (commands = false): xynovim never had them. Everything else of 99 (the guarded provider,
-- the checkpoint, the auto-save toggle) stays in ninety-nine.lua.
return {
  "xynorash/xyno-sandbox.nvim",
  lazy = true,
  config = function()
    local sandbox = require("xyno_sandbox")
    sandbox.setup({ commands = false, keymaps = false })
    -- vim.g.xynovim_99_sandbox (= false: deliberate opt-out) and vim.g.xynovim_99_allow_unsandboxed
    -- (= true: run anyway when NO backend exists) are the setup options sandbox and allow_unsandboxed,
    -- still read at every status()/wrap() call, as before (setup() replaces M.config, so this follows it)
    sandbox.config = setmetatable({}, {
      __index = function(_, key)
        if key == "sandbox" then
          return vim.g.xynovim_99_sandbox
        elseif key == "allow_unsandboxed" then
          return vim.g.xynovim_99_allow_unsandboxed
        end
      end,
    })
  end,
}
