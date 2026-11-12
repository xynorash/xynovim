return {
  {
    "mrcjkb/rustaceanvim",
    -- rustaceanvim only advertises the `rust-analyzer.debugSingle` client command (the "Debug"
    -- codelens) when nvim-dap is already loaded as the client is created. It used to be a
    -- `dependencies` entry, which ran the whole dap stack (nvim-dap, dap-ui, virtual text,
    -- mason-nvim-dap, overseer) before the first paint of a .rs file. Now only the `dap` module
    -- (0.9 ms) is required when rustaceanvim loads, and the plugin proper (config, UI listeners,
    -- adapters) follows on VeryLazy, i.e. right after the first screen update. Measured (4 alternating
    -- rounds, medians): UIEnter with a .rs file 192.5 -> 186.4 ms, fully loaded 309.8 -> 295.4 ms
    -- (docs/bench/perf-2026-11.md). Debugging before VeryLazy still works:
    -- every dap key loads the plugin through lazy.nvim as before.
    init = function()
      vim.api.nvim_create_autocmd("User", {
        pattern = "VeryLazy",
        once = true,
        callback = function()
          vim.g.xynovim_very_lazy_done = true
        end,
      })
      -- rustaceanvim's workspaceSymbol prompt (<leader>rw / rW) calls
      -- vim.npcall, which moved to vim.F.npcall in nvim 0.12.
      vim.npcall = vim.npcall or vim.F.npcall
      -- Upstream default: every rust-analyzer attach runs `cargo test --no-run
      -- --all-targets` to build the debuggables list (measured: up to 5 at
      -- once, fighting your own cargo for the build lock). <leader>dr / dR
      -- and :RustLsp debuggables ask rust-analyzer on demand instead. Set in
      -- init because LazyVim's rust extra overwrites `opts.dap`.
      vim.g.rustaceanvim = vim.tbl_deep_extend("force", vim.g.rustaceanvim or {}, {
        dap = { autoload_configurations = false },
      })
      -- LazyVim's `*` server config advertises workspace.fileOperations.willRename
      -- to every client. With it rust-analyzer answers a module rename
      -- (`vim.lsp.buf.rename`) with the file rename ALONE and expects the client
      -- to send workspace/willRenameFiles, which nvim does not do for the
      -- RenameFile of a workspace edit: `pub mod util;` and every `util::` path
      -- stayed behind. Without the capability the response carries those edits
      -- too. (<leader>cR still asks willRenameFiles itself, see keymaps.lua.)
      vim.lsp.config("rust-analyzer", {
        capabilities = { workspace = { fileOperations = { willRename = false } } },
      })
    end,
    opts = {
      server = {
        -- glibc gives every thread its own malloc arena; rust-analyzer's worker threads fragment them
        -- and the freed memory stays in the process. Two arenas: -120 MB RSS on the demo crate
        -- (median of 3: 825 -> 702 MB, docs/bench/perf-2026-11.md), no change in latency. A value
        -- the user exported is kept. Only this server: cargo / rustc / other servers are untouched.
        cmd_env = { MALLOC_ARENA_MAX = vim.env.MALLOC_ARENA_MAX or "2" },
        -- A crashed server is restarted (xyno_rust.rust_restart).
        on_exit = function(...)
          return require("xyno_rust.rust_restart").on_exit("rust-analyzer")(...)
        end,
        -- Layer the per-project Cargo context (:RustContext) over the defaults.
        settings = function(root, default_settings)
          local settings = require("rustaceanvim.config.server").load_rust_analyzer_settings(
            root,
            { default_settings = vim.deepcopy(default_settings) }
          )
          local ctx = require("xyno_rust.rust_context")
          local cargo = ctx.ra_cargo(ctx.get(ctx.root(root and (root .. "/x"))))
          if cargo then
            local ra = settings["rust-analyzer"]
            ra.cargo = vim.tbl_extend("force", ra.cargo or {}, cargo)
          end
          -- the hint kinds (:Hints, vim.g.xynovim_hints; lifetimes are off unless asked for) are in the settings
          -- the server starts with, not only sent later
          local okui, ui = pcall(require, "config.ui")
          if okui then
            local ra = settings["rust-analyzer"]
            ra.inlayHints = vim.tbl_deep_extend("force", ra.inlayHints or {}, ui.hint_settings(ui.hint_state()))
          end
          -- Restricted mode (config/workspace_trust.lua): in a workspace nobody trusted, no build
          -- scripts, no proc macros, no cargo check; trusted workspaces keep the settings above as is.
          return require("config.workspace_trust").settings_for(ctx.root(root and (root .. "/x")), settings)
        end,
        default_settings = {
          ["rust-analyzer"] = {
            -- Two diagnostic tiers: rust-analyzer's NATIVE diagnostics are
            -- computed in-memory as you type (no cargo run) - instant type
            -- errors, unresolved names, typos. Clippy depth still comes from
            -- bacon-ls ~1s later (see bacon-ls.lua). checkOnSave stays off
            -- (the extra disables it) so no cargo pipeline is duplicated;
            -- overlap is only visual: a type error may briefly show from both
            -- sources. styleLints stay off - that's clippy's job.
            -- diagnostics.experimental stays off on purpose: it adds
            -- unresolved name/method/import errors but gave 82 false errors
            -- (E0282, axum Handler E0277) in a 196-file workspace that
            -- builds cleanly (README, Rust). Those come from bacon-ls.
            diagnostics = { enable = true },
            -- Separate target dir for rust-analyzer's own cargo runs (build
            -- scripts, proc-macros) so they never contend for the build-dir
            -- file lock with terminal `cargo run`/`cargo test`.
            cargo = { targetDir = true },
            -- Inline type/lifetime annotations (inspired by JetBrains' inlay hints).
            inlayHints = {
              closureReturnTypeHints = { enable = "with_block" },
              -- off by default (also rust-analyzer's default); :Hints lifetimes turns them on (config/ui.lua)
              lifetimeElisionHints = { enable = "never", useParameterNames = true },
              expressionAdjustmentHints = { enable = "never" },
            },
            -- Completion niceties: auto-import granularity + fill call args.
            imports = {
              granularity = { group = "module" },
              prefix = "self",
            },
            completion = {
              callable = { snippets = "fill_arguments" },
              fullFunctionSignatures = { enable = true },
              -- Term search: complete whole expressions that satisfy the
              -- expected type (`Some(foo.bar().baz())`). Cheap, fuel-limited.
              termSearch = { enable = true },
              -- Postfix snippets. This REPLACES rust-analyzer's default map
              -- (it is not merged), so the defaults (ok/err/some/arc/rc/pinbox)
              -- are repeated here, followed by our additions.
              snippets = {
                custom = {
                  ["Ok"] = {
                    postfix = "ok",
                    body = "Ok(${receiver})",
                    description = "Wrap in `Result::Ok`",
                    scope = "expr",
                  },
                  ["Err"] = {
                    postfix = "err",
                    body = "Err(${receiver})",
                    description = "Wrap in `Result::Err`",
                    scope = "expr",
                  },
                  ["Some"] = {
                    postfix = "some",
                    body = "Some(${receiver})",
                    description = "Wrap in `Option::Some`",
                    scope = "expr",
                  },
                  ["Box::pin"] = {
                    postfix = "pinbox",
                    body = "Box::pin(${receiver})",
                    requires = "std::boxed::Box",
                    description = "Put into a pinned `Box`",
                    scope = "expr",
                  },
                  ["Arc::new"] = {
                    postfix = "arc",
                    body = "Arc::new(${receiver})",
                    requires = "std::sync::Arc",
                    description = "Put into an `Arc`",
                    scope = "expr",
                  },
                  ["Rc::new"] = {
                    postfix = "rc",
                    body = "Rc::new(${receiver})",
                    requires = "std::rc::Rc",
                    description = "Put into an `Rc`",
                    scope = "expr",
                  },
                  ["RefCell::new"] = {
                    postfix = "refcell",
                    body = "RefCell::new(${receiver})",
                    requires = "std::cell::RefCell",
                    description = "Put into a `RefCell`",
                    scope = "expr",
                  },
                  ["Mutex::new"] = {
                    postfix = "mutex",
                    body = "Mutex::new(${receiver})",
                    requires = "std::sync::Mutex",
                    description = "Put into a `Mutex`",
                    scope = "expr",
                  },
                  ["Arc<Mutex>"] = {
                    postfix = "arcmutex",
                    body = "Arc::new(Mutex::new(${receiver}))",
                    requires = { "std::sync::Arc", "std::sync::Mutex" },
                    description = "Put into an `Arc<Mutex<_>>`",
                    scope = "expr",
                  },
                },
              },
            },
            -- Find usages (`gr`, call hierarchy): drop `use` lines and test
            -- code. Toggle tests back in live with <leader>rT (keymaps.lua).
            references = { excludeImports = true, excludeTests = true },
            -- Resource budget (16 cores / 15 GiB box): cap the main loop and
            -- the startup cache priming instead of "all cores". Do NOT turn
            -- procMacro.attributes off: it breaks tokio::main / axum.
            numThreads = 8,
            cachePriming = { numThreads = 4 },
          },
        },
      },
    },
  },

  -- Its own spec entry: lazy.nvim applies an `opts` function after the tables of the earlier specs.
  {
    "mrcjkb/rustaceanvim",
    opts = function(_, opts)
      -- runs when rustaceanvim loads, before its ftplugin creates the client (see the comment on top)
      local dir = vim.fn.stdpath("data") .. "/lazy/nvim-dap"
      if not package.loaded["dap"] and vim.uv.fs_stat(dir) then
        vim.opt.rtp:append(dir)
        pcall(require, "dap")
        local function full()
          require("lazy").load({ plugins = { "nvim-dap" } })
        end
        if vim.g.xynovim_very_lazy_done then
          vim.schedule(full)
        else
          vim.api.nvim_create_autocmd("User", {
            pattern = "VeryLazy",
            once = true,
            callback = function()
              vim.schedule(full)
            end,
          })
        end
      end
      return opts
    end,
  },
}
