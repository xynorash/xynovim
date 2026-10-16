-- :checkhealth xynovim - external tools the Rust workflow in this config
-- relies on, and what each one is used for.
local M = {}

local function first_line(cmd)
  local ok, o = pcall(function()
    return vim.system(cmd, { text = true }):wait(5000)
  end)
  if not ok or o.code ~= 0 then
    return nil
  end
  return vim.split(o.stdout ~= "" and o.stdout or o.stderr, "\n")[1]:sub(1, 80)
end

--- Mason's bin dir first (installed by `ensure_installed`), then PATH.
local function find(bin, mason)
  if mason then
    for _, ext in ipairs(vim.fn.has("win32") == 1 and { "", ".cmd", ".exe" } or { "" }) do
      local p = vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "bin", bin .. ext)
      if vim.fn.executable(p) == 1 then
        return p, "Mason"
      end
    end
  end
  local p = vim.fn.exepath(bin)
  if p ~= "" then
    return p, "PATH"
  end
end

-- { binary, purpose, check Mason too, version args, severity when missing }
local TOOLS = {
  -- what scripts/bootstrap.sh and lazy/Mason need to bring the config up
  { "git", "plugin manager (lazy.nvim clones and checks out the lockfile)", false, { "--version" }, "error" },
  { "curl", "Mason downloads, tree-sitter parsers", false, { "--version" }, "warn" },
  { "tar", "Mason and tree-sitter archives", false, { "--version" }, "warn" },
  { "unzip", "Mason package archives", false, { "-v" }, "warn" },
  { "gzip", "Mason unpacks .gz archives", false, { "--version" }, "warn" },
  { "gcc", "compiles tree-sitter parsers", false, { "--version" }, "warn" },
  { "tree-sitter", "CLI nvim-treesitter builds parsers with (Mason supplies it as tree-sitter-cli)", true, { "--version" }, "warn" },
  { "node", "Mason's npm tools and yaml-language-server", false, { "--version" }, "warn" },
  { "cargo", "builds, clippy, tests (every Rust key)", false, { "--version" }, "error" },
  { "rust-analyzer", "language server (rustaceanvim)", false, { "--version" }, "error" },
  { "bacon-ls", "clippy diagnostics tier", true, { "--version" }, "error" },
  { "codelldb", "debugger (dap.core)", true, nil, "warn" },
  { "taplo", "Cargo.toml LSP/formatter (lang.toml)", true, { "--version" }, "warn" },
  { "wgsl-analyzer", "WGSL / Bevy shader LSP (plugins/domain.lua)", true, { "--version" }, "warn" },
  { "cargo-nextest", "test runner (neotest, :RustTargets, coverage)", false, { "--version" }, "warn" },
  { "cargo-deny", "supply-chain diagnostics (supply-chain.lua)", false, { "--version" }, "warn" },
  { "cargo-expand", "full macro expansion (cargo expand; <leader>rm covers the rest)", false, { "--version" }, "warn" },
  { "lazygit", "git UI (<leader>gg)", false, { "--version" }, "warn" },
  { "delta", "diff pager (git config)", false, { "--version" }, "warn" },
  { "mold", "fast linker (~/.cargo/config.toml)", false, { "--version" }, "warn" },
  { "clang", "linker driver for mold (~/.cargo/config.toml)", false, { "--version" }, "warn" },
  { "npm", "Mason installs markdownlint-cli2, markdown-toc, yaml-language-server", false, { "--version" }, "warn" },
  { "bwrap", "bubblewrap sandbox for the 99 agent (Linux only; without it 99 refuses to run unless vim.g.xynovim_99_allow_unsandboxed = true)", false, { "--version" }, "warn" },
}

-- Not needed (or not available) on Windows: Mason there unpacks with PowerShell / tar,
-- mold is a Linux linker, bubblewrap is Linux only (99 then refuses to run).
local WIN_SKIP = { unzip = true, gzip = true, mold = true, clang = true, bwrap = true }
-- A C compiler for tree-sitter parsers: gcc, or any of these on Windows.
local WIN_CC = { "cc", "clang", "cl", "zig" }

function M.check()
  vim.health.start("xynovim: external tools")
  local win = vim.fn.has("win32") == 1
  for _, t in ipairs(TOOLS) do
    local bin, purpose, mason, vargs, level = t[1], t[2], t[3], t[4], t[5]
    local path, where = find(bin, mason)
    if win and bin == "gcc" and not path then
      for _, cc in ipairs(WIN_CC) do
        if vim.fn.exepath(cc) ~= "" then
          bin, path, where = cc, vim.fn.exepath(cc), "PATH"
          vargs = nil
          break
        end
      end
    end
    if win and WIN_SKIP[bin] then
      goto continue
    end
    local v = path and vargs and first_line(vim.list_extend({ path }, vargs))
    if path and vargs and not v then
      -- e.g. rustup's rust-analyzer proxy when the component is not installed
      vim.health[level](
        ("%s found (%s: %s) but `%s` fails: %s"):format(bin, where, path, table.concat(vargs, " "), purpose),
        bin == "rust-analyzer" and "rustup component add rust-analyzer" or "reinstall it"
      )
    elseif path then
      vim.health.ok(("%s (%s)%s: %s"):format(bin, where, v and (" " .. v) or "", purpose))
    else
      local hint = mason and "install it with :Mason or put it on PATH" or "install it and put it on PATH"
      if bin == "rust-analyzer" then
        hint = "rustup component add rust-analyzer (or put a rust-analyzer binary on PATH)"
      end
      vim.health[level](("%s not found: %s"):format(bin, purpose), hint)
    end
    ::continue::
  end

  vim.health.start("xynovim: rust toolchain")
  if vim.fn.executable("rustup") == 0 then
    vim.health.warn("rustup not found", "components cannot be checked; install rustup")
    return
  end
  local out = vim.system({ "rustup", "component", "list", "--toolchain", "stable", "--installed" }, { text = true })
    :wait(10000)
  if out.code ~= 0 then
    vim.health.warn("stable toolchain not installed", "rustup toolchain install stable")
    return
  end
  local comps = out.stdout
  for _, c in ipairs({
    { "clippy", "clippy", "clippy tier and rust-analyzer lints" },
    { "llvm%-tools", "llvm-tools", "cargo-llvm-cov coverage (<leader>tc)" },
  }) do
    if comps:find("\n" .. c[1]) or comps:find("^" .. c[1]) then
      vim.health.ok(("stable has %s: %s"):format(c[2], c[3]))
    else
      vim.health.warn(("stable lacks %s: %s"):format(c[2], c[3]), "rustup component add --toolchain stable " .. c[2])
    end
  end
  -- :RustContext's target step lists the installed targets: web/WASM crates need this one
  local targets = vim.system({ "rustup", "target", "list", "--toolchain", "stable", "--installed" }, { text = true }):wait(10000)
  if targets.code == 0 then
    if (targets.stdout or ""):find("wasm32-unknown-unknown", 1, true) then
      vim.health.ok("stable has the wasm32-unknown-unknown target: web/WASM crates (:RustContext target)")
    else
      vim.health.warn(
        "stable lacks the wasm32-unknown-unknown target: web/WASM crates (:RustContext target)",
        "rustup target add --toolchain stable wasm32-unknown-unknown"
      )
    end
  end
end

return M
