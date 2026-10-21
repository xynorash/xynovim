return {
  "mrcjkb/rustaceanvim",
  -- nvim-dap is lazy-loaded, and rustaceanvim only advertises the
  -- `rust-analyzer.debugSingle` client command (the "Debug" codelens) when
  -- dap is already loaded as the client is created, so load it first.
  dependencies = { "mfussenegger/nvim-dap" },
  init = function()
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
      -- A crashed server is restarted (rust_restart.lua).
      on_exit = function(...)
        return require("config.rust_restart").on_exit("rust-analyzer")(...)
      end,
      -- Layer the per-project Cargo context (:RustContext) over the defaults.
      settings = function(root, default_settings)
        local settings = require("rustaceanvim.config.server").load_rust_analyzer_settings(
          root,
          { default_settings = vim.deepcopy(default_settings) }
        )
        local ctx = require("config.rust_context")
        local cargo = ctx.ra_cargo(ctx.get(ctx.root(root and (root .. "/x"))))
        if cargo then
          local ra = settings["rust-analyzer"]
          ra.cargo = vim.tbl_extend("force", ra.cargo or {}, cargo)
        end
        return settings
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
            lifetimeElisionHints = { enable = "skip_trivial", useParameterNames = true },
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
                ["Ok"] = { postfix = "ok", body = "Ok(${receiver})", description = "Wrap in `Result::Ok`", scope = "expr" },
                ["Err"] = { postfix = "err", body = "Err(${receiver})", description = "Wrap in `Result::Err`", scope = "expr" },
                ["Some"] = { postfix = "some", body = "Some(${receiver})", description = "Wrap in `Option::Some`", scope = "expr" },
                ["Box::pin"] = { postfix = "pinbox", body = "Box::pin(${receiver})", requires = "std::boxed::Box", description = "Put into a pinned `Box`", scope = "expr" },
                ["Arc::new"] = { postfix = "arc", body = "Arc::new(${receiver})", requires = "std::sync::Arc", description = "Put into an `Arc`", scope = "expr" },
                ["Rc::new"] = { postfix = "rc", body = "Rc::new(${receiver})", requires = "std::rc::Rc", description = "Put into an `Rc`", scope = "expr" },
                ["RefCell::new"] = { postfix = "refcell", body = "RefCell::new(${receiver})", requires = "std::cell::RefCell", description = "Put into a `RefCell`", scope = "expr" },
                ["Mutex::new"] = { postfix = "mutex", body = "Mutex::new(${receiver})", requires = "std::sync::Mutex", description = "Put into a `Mutex`", scope = "expr" },
                ["Arc<Mutex>"] = { postfix = "arcmutex", body = "Arc::new(Mutex::new(${receiver}))", requires = { "std::sync::Arc", "std::sync::Mutex" }, description = "Put into an `Arc<Mutex<_>>`", scope = "expr" },
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
}
