-- The bubblewrap sandbox of the 99 agent, from the xyno-sandbox.nvim plugin. Lazy: 99 depends on it
-- (plugins/ninety-nine.lua) and require("xyno_sandbox") loads it, or one of its commands does.
-- Commands: :XynoSandboxStatus, :XynoSandboxPolicy (what the sandbox will allow, with exceptions that
-- are approved and logged), :XynoSandboxApprovals, :XynoSandboxRun. Everything else of 99 (the guarded
-- provider, the checkpoint, the auto-save toggle) stays in ninety-nine.lua.
return {
  "xynorash/xyno-sandbox.nvim",
  cmd = { "XynoSandboxStatus", "XynoSandboxPolicy", "XynoSandboxApprovals", "XynoSandboxRun" },
  config = function()
    local sandbox = require("xyno_sandbox")
    -- vim.g.xynovim_99_sandbox (= false: deliberate opt-out) and vim.g.xynovim_99_allow_unsandboxed
    -- (= true: run anyway when NO working backend exists) are the setup options sandbox and
    -- allow_unsandboxed, still read at every status()/wrap() call, as before.
    local opts = {
      commands = true,
      keymaps = false,
      preview = "once", -- the policy is shown before the first 99 request of each project
      agent_cmd = { "claude", "--dangerously-skip-permissions" }, -- what :XynoSandboxPolicy previews
    }
    if sandbox.validate_opts then
      -- plugin with the policy preview: the two switches may be functions
      opts.sandbox = function()
        return vim.g.xynovim_99_sandbox
      end
      opts.allow_unsandboxed = function()
        return vim.g.xynovim_99_allow_unsandboxed
      end
      sandbox.setup(opts)
    else
      -- older plugin (before the lock file points at the preview release): same switches through a
      -- config proxy; it has neither the preview nor :XynoSandboxPolicy / :XynoSandboxApprovals
      sandbox.setup({ commands = true, keymaps = false })
      sandbox.config = setmetatable({}, {
        __index = function(_, key)
          if key == "sandbox" then
            return vim.g.xynovim_99_sandbox
          elseif key == "allow_unsandboxed" then
            return vim.g.xynovim_99_allow_unsandboxed
          end
        end,
      })
    end
  end,
}
