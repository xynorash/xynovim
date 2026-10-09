-- bacon-ls 0.29+ has a native "cargo" backend that runs clippy itself and
-- pushes diagnostics - no bacon process or .bacon-locations export needed
-- (the older "bacon" backend still works and is configured globally in
-- ~/.config/bacon/prefs.toml if we ever want to switch back).
--
-- updateOnInsert is the RustRover-style part: bacon-ls mirrors the workspace
-- into a hardlinked shadow under target/bacon-ls-live/, writes dirty buffers
-- into it on every didChange, and runs clippy against the shadow - so
-- diagnostics update as you type, before any save. It MUST be set in
-- init_options (not settings): the server needs it at initialize-time to
-- advertise Full didChange sync - and it must stay ON: without it the server
-- advertises no static sync at all and Neovim ignores its late dynamic
-- registration, so saves/changes never reach it and diagnostics never
-- refresh (measured: marker diagnostic never arrived in 300s).
local bacon_ls_settings = {
  backend = "cargo",
  cargo = {
    command = "clippy",
    -- no --all-targets: it doubles every run's scope (bin + test targets);
    -- clippy-on-tests can run manually/CI instead. --no-deps: don't re-lint
    -- dependency crates after their recompilation.
    extraArgs = { "--workspace", "--all-features", "--no-deps" },
    updateOnInsert = true,
    -- Measured (multi-crate ws, warm): edit-to-clippy-diagnostic is
    -- debounce + ~60ms, and any debounce >= the typing cadence coalesces a
    -- burst into exactly 1 cargo spawn (500 and 800 both spawned 1 for an
    -- 18-keystroke burst; 300 spawned 18). 500ms is the sweet spot: 0.56s
    -- median latency, no extra churn. The old 800ms was compensating for
    -- the abort bug fixed upstream in 0.31.0.
    updateOnInsertDebounceMillis = 500,
    -- OFF deliberately: with ~1s auto-save, checkOnSave is a second run
    -- pipeline racing the updateOnInsert one - runs cancel each other and
    -- serialize on cargo's build-dir lock, stacking "checking (0%)" progress
    -- rows for ages. Single pipeline measured 0.8-0.9s edit-to-diagnostic
    -- vs 5.6s with both pipelines on.
    checkOnSave = false,
  },
}

return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      bacon_ls = {
        -- Uses Mason's bacon-ls (>= 0.31.0). The run-abort / stale-diagnostics
        -- fixes we needed were merged upstream as crisidev/bacon-ls#139 and
        -- shipped in 0.31.0, so the old local patched-build `cmd` override
        -- (~/.cargo/bin/bacon-ls) is gone.
        init_options = bacon_ls_settings,
        -- Match the per-project Cargo context (:RustContext) so both
        -- diagnostic tiers see the same features/target. Settings reach the
        -- server in two ways, init_options (initialize) and the
        -- workspace/configuration pull, so patch both.
        before_init = function(params, config)
          local rc = require("config.rust_context")
          local ctx = rc.get(rc.root((config.root_dir or vim.uv.cwd()) .. "/x"))
          if not ctx then
            return
          end
          local s = vim.deepcopy(bacon_ls_settings)
          s.cargo.extraArgs = rc.bacon_args(ctx)
          params.initializationOptions = s
          -- in place: the client already holds a reference to this table
          config.settings.bacon_ls = s
        end,
        -- Also answered to the server's workspace/configuration pull.
        settings = { bacon_ls = bacon_ls_settings },
      },
    },
  },
}
