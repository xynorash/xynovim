-- bacon-ls 0.29+ has a native "cargo" backend that runs clippy itself and
-- pushes diagnostics - no bacon process or .bacon-locations export needed
-- (the older "bacon" backend would need the `bacon` binary and its own
-- prefs; it is not configured or used here).
--
-- updateOnInsert is the always-on part: bacon-ls mirrors the workspace
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
    -- dependency crates after their recompilation. --keep-going: a crate that fails to
    -- build no longer hides the diagnostics of the independent ones.
    extraArgs = { "--workspace", "--all-features", "--no-deps", "--keep-going" },
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

local no_cargo_told = false

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
        -- One client per Cargo WORKSPACE, rooted at the outermost manifest
        -- with a [workspace] table (config.rust_context.root), not at the
        -- nearest Cargo.toml: bacon-ls mirrors its root into a shadow, so a
        -- member-rooted shadow lacks the workspace manifest and the sibling
        -- path dependencies and cargo fails ("believes it's in a workspace
        -- when it's not"). Paths under the cargo registry/git checkouts and
        -- rustup (what `gd` into a dependency or std opens) get no client at
        -- all: each ships its own Cargo.toml and would be a root of its own,
        -- compiled by clippy with target/ written into ~/.cargo. With no
        -- root found the client is not started, so a standalone solo.rs
        -- without a crate no longer attaches and spams cargo errors;
        -- rust-analyzer's detached-file mode is a separate client and is
        -- unaffected.
        root_dir = function(bufnr, on_dir)
          local name = vim.api.nvim_buf_get_name(bufnr)
          -- no client for virtual buffers (diffview://, fugitive://, 99-prompt ...): the root of
          -- diffview:// came out as "." and started a second client that outlived Diffview
          if name == "" or name:match("^%w[%w+.-]*://") or vim.bo[bufnr].buftype ~= "" then
            return
          end
          -- bacon-ls shells out to cargo: without it the client died with a
          -- bare "No such file or directory (os error 2)"
          if vim.fn.executable("cargo") ~= 1 then
            if not no_cargo_told then
              no_cargo_told = true
              vim.notify("bacon-ls: cargo is not on PATH, the clippy tier is off", vim.log.levels.WARN)
            end
            return
          end
          name = vim.fs.normalize(name)
          for _, skip in ipairs({ "/.cargo/registry/", "/.cargo/git/", "/.rustup/" }) do
            if name:find(skip, 1, true) then
              return
            end
          end
          local root = require("config.rust_context").root(name)
          if root and (root:sub(1, 1) == "/" or root:match("^%a:[/\\]")) then
            on_dir(root)
          end
        end,
        -- A crashed server is restarted (rust_restart.lua).
        on_exit = function(...)
          return require("config.rust_restart").on_exit("bacon_ls")(...)
        end,
        -- Match the per-project Cargo context (:RustContext) so both
        -- diagnostic tiers see the same features/target. Settings reach the
        -- server in two ways, init_options (initialize) and the
        -- workspace/configuration pull, so patch both. Always rebuilt from
        -- the defaults (also with no stored context): after
        -- `:RustContext reset` the restarted client must not keep the
        -- previous context's args.
        before_init = function(params, config)
          local rc = require("config.rust_context")
          local ctx = rc.get(rc.root((config.root_dir or vim.uv.cwd()) .. "/x"))
          local s = vim.deepcopy(bacon_ls_settings)
          s.cargo.extraArgs = rc.bacon_args(ctx)
          params.initializationOptions = s
          -- in place: the client already holds a reference to this table
          config.settings = config.settings or {}
          config.settings.bacon_ls = s
        end,
        -- Also answered to the server's workspace/configuration pull.
        settings = { bacon_ls = bacon_ls_settings },
      },
    },
  },
}
