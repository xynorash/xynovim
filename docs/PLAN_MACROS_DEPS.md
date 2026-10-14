# Next phase: macros and dependencies

The question: when a crate is added, its macros and features are not fully exploited. What is missing, and what do we build? This page holds the measurements and the plan; the README has the summary.

## Assessment (measured 2026-10-14)

Setup: a throwaway crate with `serde` (derive), `clap` (derive), `thiserror`, `anyhow`, `serde_json` and `tokio` (macros), edition 2024, rust-analyzer 1.99.0, this config. Probes are in [assessment/](assessment/).

### What already works

- **Derive and attribute macros expand.** Hover on the clap-derived `Cli::parse` resolves to `clap_builder::derive::Parser::parse` with its bounds; `#[derive(Serialize)]`, `#[derive(Error)]`, `#[tokio::main]` produce no diagnostics. Proc macros and build scripts are enabled (LazyVim's rust extra), so this is not a configuration problem.
- **Completion carries the import.** Completing `HashM` offers `HashMap` and resolving the item returns the edit `use std::collections::HashMap;`. Items from dependencies behave the same (`Deserializer`, `DeserializeOwned`, ...).
- **Import code actions exist for names that are in a dependency**, including inside a derive: `Serialize` unresolved in `#[derive(Serialize)]` offers `Import serde::Serialize` and `Qualify as serde::Serialize`.
- **Ambiguity is handled, by a menu**: an unresolved `Error` gives eight actions (`Import` and `Qualify as` for `anyhow::Error`, `clap::Error`, `clap::error::Error`, `std::io::Error`), in alphabetical order, so the choice is a manual pick every time.
- **rust-analyzer recognises a new dependency within 10 s** of `Cargo.toml` being written from nvim (sampled every 3 s: hover on `rand::random` was empty at 6 s and resolved at 10 s).
- Built-in attributes complete: `#[cfg(` 24 items, `#[allow(` 1037 lints, `#[repr(` 16 items.

### The gaps

| # | Gap | Evidence | Effect |
| --- | --- | --- | --- |
| G1 | **No completion inside the arguments of helper attributes** | `#[serde(` (container and field), `#[arg(`, `#[command(`, `#[error(`, `#[tokio::main(` all return 0 items or only generic crate paths (`core::`, `std::`, ...), never `rename_all`, `short`, `long`, `flavor`, ... | the macro "parameters from suggestions" the user asked for do not exist |
| G2 | **`#[derive(` completion returns nothing** | 0 items in three contexts (`#[derive(`, `#[derive(Se`, `#[derive(Debug, C`); with a complete attribute `#[derive(Debug, )]` it returns item keywords. Cause not isolated (possibly a rust-analyzer 1.99 regression) | derive names, including `Serialize`, are typed from memory |
| G3 | **A crate that is not yet a dependency cannot be imported** | `rand::random::<u8>()` with `rand` absent: 0 code actions; no diagnostic in the instant tier either (experimental diagnostics are off on purpose) | the user must leave the editor to run `cargo add` |
| G4 | **A missing crate feature is silent** | with `serde = "1"` (no `derive`), rustc says `cannot find derive macro Serialize in this scope` / `cannot find attribute serde`; the code actions on that line are `Convert to manual impl`, `Wrap in cfg_attr`, `Generate impl`, none of which enables the feature | the "features not fully exploited" report: nothing tells you `derive` is off |
| G5 | **The clippy tier goes stale after a dependency is added** | after writing `rand = "0.9"` to `Cargo.toml`, rust-analyzer resolved it at 10 s, but bacon-ls kept reporting `error[E0433]: cannot find module or crate rand` for the whole 61 s observed, until a `FocusGained` event restarted it (then cleared within 3 s). A terminal that does not report focus never gets that event | a false red error right after the most common edit |
| G6 | **Ambiguous imports are not ranked** | the `Error` list above is not ordered by what the file already uses, the derive context (`thiserror::Error` in `#[derive(...)]`), or the project's dependencies; the choice is not remembered | the "unambiguous import" the user asked for needs the user to pick every time |
| G7 | **No signature help for `macro_rules!` arguments**, no view of what a derive generates besides `<leader>rm` | expansion exists (`expandMacro`) but there is no matcher hint while typing a call | macros stay opaque while typing |

Not a gap: `diagnostics.experimental` would surface unresolved names in the instant tier but gave 82 false errors on a real workspace (see DETAILS), so G3 needs its own, narrower check.

## Plan

Phases are ordered by value over effort. Every item ships with specs in `tests/`, a demo tape in `docs/media/tapes/` and an entry in the README and CHANGELOG, like the rest of the config.

### Phase 0: stop the false errors (small)

- **0.1 Refresh the clippy tier when `Cargo.toml` or `Cargo.lock` is saved from nvim** (G5): restart bacon-ls (debounced, once per save burst), not only on `FocusGained`. Acceptance: the timeline probe shows the stale error gone within 5 s of the write.
- **0.2 A dependency-resolution status**: the statusline shows `deps resolving` between the write of `Cargo.toml` and rust-analyzer's quiescence, so a red error during that window is understood as transient.

### Phase 1: dependencies from inside the editor (medium)

- **1.1 Unknown-crate check** (G3): a treesitter scan of `use` paths and `crate::`-less path heads, compared with `cargo metadata`, std/core/alloc, local modules and macro names. A first segment that is none of those becomes a hint diagnostic ("`rand` is not a dependency") with the code action **Add `rand`**.
- **1.2 `:CrateAdd`**: crates.io search (cached sparse index, offline fallback to the local registry), a picker with version, downloads and **features with their descriptions**, target choice (workspace member, `--dev`, `--build`, `workspace.dependencies`), then `cargo add`, wait for rust-analyzer to reload and re-offer the import that triggered it.
- **1.3 Missing-feature fix** (G4): turn rustc's `cannot find derive macro / attribute / macro / function X` into the code action **Enable feature `derive` of `serde`**. The map name -> feature is computed from the crate's own source in the registry (a `cfg(feature = "...")`-gated `pub use` of that name, plus the `[features]` table and optional-dependency implicit features), so it works for crates nobody wrote a rule for. Acceptance: the `serde = "1"` crate above gets the action and, once applied, builds.
- **1.4 Feature explorer**: per dependency, which features are on, what each unlocks (the gated items), and one-key toggling in `Cargo.toml` (crates.nvim already offers version and feature completion; this adds the "what does it do" and the unused-feature hint).

### Phase 2: macro depth (large)

- **2.1 Attribute-argument completion** (G1): a blink.cmp source driven by data. Each helper attribute is a small JSON schema (keys, value kinds, enumerated values, the targets it applies to: container, field, variant, conflicts, doc link), shipped for `serde`, `clap`, `thiserror`, `tokio`, `strum`, `derive_more`, `sqlx`, `utoipa`, `schemars`, `bon`, `leptos`. Completion offers keys, then values (`rename_all = "` -> `camelCase`, `snake_case`, ...), inserts snippets, and shows the doc. For crates without a schema, a **learn-from-usage** fallback ranks what the workspace and the registry sources already write inside that attribute. The context (container vs field, struct vs enum) comes from treesitter. User schemas live next to the project.
- **2.2 Derive and attribute names** (G2): the same source completes `#[derive(` from the builtin derives plus the derive macros of the dependencies (found in the crates' proc-macro declarations), and adds the `use` through the import engine (3.x). If rust-analyzer's own completion is fixed upstream, it is merged, not duplicated.
- **2.3 Macro call help** (G7): signature help for `macro_rules!` calls from the matcher arms of the definition (found with go-to-definition, so macros of external crates work); format-string aware completion for `format!`/`println!`/`write!`/`tracing` (argument count vs placeholders); bind-parameter hints for `sqlx::query!`; arm snippets for `tokio::select!` and `vec!`/`matches!`.
- **2.4 Macro lens**: expansion of whatever macro is under the cursor (`macro_rules!`, derive, attribute, function-like) in a read-only side window with treesitter highlighting, recursive stepping, "go to the generated item" for derived methods, and a `cargo expand` fallback for what rust-analyzer cannot expand.
- **2.5 Proc-macro health**: `:ProcMacroStatus` lists which proc-macro crates built and loaded, shows "proc macro not expanded" problems where they occur, suggests `procMacro.ignored` for slow macros and rebuilds with one key (`rebuildProcMacros` exists).

### Phase 3: the import engine (medium)

- **3.1 Auto-import when unambiguous**: when rust-analyzer offers exactly one `Import X` action for an unresolved name, apply it (option `vim.g.xynovim_auto_import`: `single` / `ask` / `off`, trigger `InsertLeave` and save), as one undo step with a one-line note.
- **3.2 Ranked disambiguation** (G6): order the candidates by use in this file, then module, then crate (ripgrep over `use` lines), the derive/attribute context, the function's return type (`Result` -> the error crate in use), dependency order and prelude membership; preselect the winner; **remember the choice per project** so the same ambiguity never asks twice.
- **3.3 Import for crates that are not dependencies yet**: connects 1.1/1.2: an unresolved item name searches crates.io and the registry for the item, offers `Add crate and import`, runs `cargo add` and the import.
- **3.4 Organize imports**: merge, sort and remove unused with the existing rust-analyzer assists behind one command and key, plus import-on-paste for code copied from elsewhere.

### Phase 4: prove it

Specs per item (the timeline and completion probes in `docs/assessment/` become regression tests against a fixture crate with the same dependencies), a field-test round for the new flows, three new demo recordings (add a crate and its feature, complete `#[serde(`, resolve an ambiguous `Error`), and the README/CHANGELOG entries.

### Order of work

1. 0.1, 1.3 (the reported pain, both small), 3.1, 3.2
2. 1.1, 1.2, 3.3
3. 2.1, 2.2
4. 2.3, 2.4, 2.5, 1.4, 3.4

### Risks and decisions

- **Network**: crates.io access must be optional; everything degrades to the local registry and a clear message, and results are cached.
- **Schemas rot**: attribute schemas are data with a version range and a doc link; the learn-from-usage fallback and user overrides keep unknown crates usable, and a spec checks every shipped schema against the real crate source where it is available.
- **Auto-import safety**: only when exactly one candidate exists, one undo step, off by one setting; ranking never applies without a visible choice unless the user opted in.
- **rust-analyzer limits**: no custom LSP server is planned; everything is client-side (completion source, code actions through nvim's code-action API, `cargo` and treesitter), so it survives rust-analyzer updates.
- **Non-goals**: replacing rust-analyzer's completion, an offline crates.io mirror, editing `Cargo.toml` outside `cargo add` / feature toggles.
