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
  return vim.split(o.stdout ~= "" and o.stdout or o.stderr, "\n")[1]
end

--- Mason's bin dir first (installed by `ensure_installed`), then PATH.
local function find(bin, mason)
  if mason then
    local p = vim.fn.stdpath("data") .. "/mason/bin/" .. bin
    if vim.fn.executable(p) == 1 then
      return p, "Mason"
    end
  end
  local p = vim.fn.exepath(bin)
  if p ~= "" then
    return p, "PATH"
  end
end

-- { binary, purpose, check Mason too, version args, severity when missing }
local TOOLS = {
  { "rust-analyzer", "language server (rustaceanvim)", false, { "--version" }, "error" },
  { "bacon-ls", "clippy diagnostics tier", true, { "--version" }, "error" },
  { "codelldb", "debugger (dap.core)", true, nil, "warn" },
  { "taplo", "Cargo.toml LSP/formatter (lang.toml)", true, { "--version" }, "warn" },
  { "cargo-nextest", "test runner (neotest, :RustTargets, coverage)", false, { "--version" }, "warn" },
  { "cargo-deny", "supply-chain diagnostics (supply-chain.lua)", false, { "--version" }, "warn" },
  { "lazygit", "git UI (<leader>gg)", false, { "--version" }, "warn" },
  { "delta", "diff pager (git config)", false, { "--version" }, "warn" },
  { "mold", "fast linker (~/.cargo/config.toml)", false, { "--version" }, "warn" },
  { "clang", "linker driver for mold (~/.cargo/config.toml)", false, { "--version" }, "warn" },
  { "bwrap", "bubblewrap sandbox for the 99 agent (agent_sandbox.lua)", false, { "--version" }, "warn" },
}

function M.check()
  vim.health.start("xynovim: external tools")
  for _, t in ipairs(TOOLS) do
    local bin, purpose, mason, vargs, level = t[1], t[2], t[3], t[4], t[5]
    local path, where = find(bin, mason)
    if path then
      local v = vargs and first_line(vim.list_extend({ path }, vargs))
      vim.health.ok(("%s (%s)%s: %s"):format(bin, where, v and (" " .. v) or "", purpose))
    else
      local hint = mason and "install it with :Mason or put it on PATH" or "install it and put it on PATH"
      vim.health[level](("%s not found: %s"):format(bin, purpose), hint)
    end
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
end

return M
