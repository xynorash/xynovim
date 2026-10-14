# Assessment probes

Headless scripts behind the measurements in [../PLAN_MACROS_DEPS.md](../PLAN_MACROS_DEPS.md). They drive a real rust-analyzer through nvim and print `T:` / `ACT` / `COMPL` lines. They expect to run as `nvim --headless -S <script>` with the working directory set to a throwaway crate like this one (edition 2024):

```toml
[dependencies]
anyhow = "1"
clap = { version = "4", features = ["derive"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
thiserror = "2"
tokio = { version = "1", features = ["macros", "rt-multi-thread"] }
```

with a `src/main.rs` that derives `Serialize`, `Deserialize`, `Error` and `Parser`, uses `#[serde(...)]`, `#[arg(...)]`, `#[error(...)]` and `#[tokio::main]`. Measured 2026-10-14 with rust-analyzer 1.99.0 and this config.

| Script | What it measures |
| --- | --- |
| `dep-recognition-timeline.lua` | adds `rand = "0.9"` to `Cargo.toml` in nvim and samples both diagnostic tiers and hover every 3 s |
| `import-and-completion.lua` | import code actions for unresolved names, completion items with auto-import edits, derive completion |
| `attribute-completion.lua` | completion inside `#[derive(`, `#[cfg(`, `#[allow(`, `#[repr(` |
| `attribute-arguments.lua` | completion inside `#[serde(`, `#[arg(`, `#[command(`, `#[error(` |
| `completion-and-actions.lua` | a wider first sweep (path completion, auto-import items, code actions) |
