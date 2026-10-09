return {
  "mrcjkb/rustaceanvim",
  opts = {
    server = {
      default_settings = {
        ["rust-analyzer"] = {
          -- Two diagnostic tiers: rust-analyzer's NATIVE diagnostics are
          -- computed in-memory as you type (no cargo run) - instant type
          -- errors, unresolved names, typos. Clippy depth still comes from
          -- bacon-ls ~1s later (see bacon-ls.lua). checkOnSave stays off
          -- (the extra disables it) so no cargo pipeline is duplicated;
          -- overlap is only visual: a type error may briefly show from both
          -- sources. styleLints stay off - that's clippy's job.
          diagnostics = { enable = true },
          -- Separate target dir for rust-analyzer's own cargo runs (build
          -- scripts, proc-macros) so they never contend for the build-dir
          -- file lock with terminal `cargo run`/`cargo test`.
          cargo = { targetDir = true },
          -- RustRover-style inline type/lifetime annotations.
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
                ["Arc<Mutex>"] = { postfix = "arcmutex", body = "Arc::new(Mutex::new(${receiver}))", requires = "std::sync::Mutex", description = "Put into an `Arc<Mutex<_>>`", scope = "expr" },
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
