-- Cargo targets picker (RustRover's Cargo tool window / run configurations,
-- minimal) and a project scaffold command. Honors the :RustContext choice.
local M = {}

local rc = require("config.rust_context")

local function cargo_metadata(root)
  local o = vim.system({ "cargo", "metadata", "--format-version", "1", "--no-deps" }, { cwd = root, text = true }):wait(30000)
  if o.code ~= 0 then
    return nil, o.stderr
  end
  return vim.json.decode(o.stdout)
end

--- Run in a bottom terminal that stays open after exit 0 (Snacks closes it
--- by default and the output is gone). A rerun replaces the previous one:
--- Snacks.terminal would just toggle the finished window.
local function term(cmd, root)
  local old = Snacks.terminal.get(cmd, { cwd = root, create = false })
  if old then
    old:close({ buf = true })
  end
  Snacks.terminal.open(cmd, { cwd = root, auto_close = false, win = { position = "bottom" } })
end

--- Feature/target flags of the context (the default is --all-features).
local function ctx_flags(root)
  return rc.cargo_flags(rc.get(root))
end

--- cargo-flamegraph has no --all-features: spell the package's features out.
local function flamegraph_flags(root, pkg)
  local flags = ctx_flags(root)
  local i = vim.fn.index(flags, "--all-features")
  if i >= 0 then
    table.remove(flags, i + 1)
    local names = vim.tbl_filter(function(n)
      return n ~= "default"
    end, vim.tbl_keys(pkg.features))
    table.sort(names)
    if #names > 0 then
      vim.list_extend(flags, { "--features", table.concat(names, ",") })
    end
  end
  return flags
end

-- target kind -> { label, cargo subcommand words, target selector flag }
local ACTIONS = {
  bin = { { "run", "run", "--bin" }, { "test", "test", "--bin" }, { "build", "build", "--bin" } },
  example = { { "run", "run", "--example" }, { "build", "build", "--example" } },
  test = { { "test", "test", "--test" } },
  bench = { { "bench", "bench", "--bench" } },
  lib = { { "test", "test", "--lib" }, { "doc-test", "test", "--doc" }, { "build", "build", "--lib" } },
}

function M.targets()
  local root = rc.root()
  if not root then
    return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
  end
  local meta, err = cargo_metadata(root)
  if not meta then
    return vim.notify("cargo metadata failed: " .. tostring(err), vim.log.levels.ERROR)
  end
  local items = {}
  for _, p in ipairs(meta.packages) do
    for _, t in ipairs(p.targets) do
      local kind = t.kind[1]
      kind = (kind == "proc-macro" or kind == "rlib" or kind == "cdylib" or kind == "staticlib" or kind == "dylib") and "lib" or kind
      if kind == "bin" then
        -- `profiling` profile = release + debug symbols (~/.cargo/config.toml)
        local bin = ("%s/profiling/%s"):format(meta.target_directory, t.name)
        local build = { "cargo", "build", "--profile", "profiling", "-p", p.name, "--bin", t.name }
        vim.list_extend(build, ctx_flags(root))
        items[#items + 1] = {
          text = ("samply  bin %s (%s)"):format(t.name, p.name),
          cmd = { "sh", "-c", table.concat(vim.tbl_map(vim.fn.shellescape, build), " ") .. " && samply record " .. vim.fn.shellescape(bin) },
        }
        items[#items + 1] = {
          text = ("flamegraph  bin %s (%s)"):format(t.name, p.name),
          cmd = vim.list_extend({ "cargo", "flamegraph", "--profile", "profiling", "-p", p.name, "--bin", t.name }, flamegraph_flags(root, p)),
        }
      end
      for _, a in ipairs(ACTIONS[kind] or {}) do
        local cmd = { "cargo", a[2], "-p", p.name }
        if kind == "lib" then
          cmd[#cmd + 1] = a[3]
        else
          vim.list_extend(cmd, { a[3], t.name })
        end
        vim.list_extend(cmd, ctx_flags(root))
        items[#items + 1] = {
          text = ("%s  %s %s (%s)"):format(a[1], kind, t.name, p.name),
          cmd = cmd,
        }
      end
    end
  end
  Snacks.picker({
    title = "Cargo targets - " .. rc.describe(rc.get(root)),
    items = items,
    format = "text",
    layout = { preset = "select" },
    confirm = function(picker, item)
      picker:close()
      if item then
        term(item.cmd, root)
      end
    end,
  })
end

--- :RustNew [name]: cargo new (bin or lib) in the current directory and open it.
function M.new(name)
  local function create(n, kind)
    local args = { "cargo", "new", n }
    if kind == "lib" then
      table.insert(args, "--lib")
    end
    local o = vim.system(args, { cwd = vim.uv.cwd(), text = true }):wait(30000)
    if o.code ~= 0 then
      return vim.notify(o.stderr, vim.log.levels.ERROR)
    end
    local dir = vim.uv.cwd() .. "/" .. n
    vim.cmd.edit(dir .. "/src/" .. (kind == "lib" and "lib.rs" or "main.rs"))
    vim.notify("created " .. dir)
  end
  local function with_name(n)
    if not n or n == "" then
      return
    end
    vim.ui.select({ "bin", "lib" }, { prompt = "Crate type" }, function(kind)
      if kind then
        create(n, kind)
      end
    end)
  end
  if name and name ~= "" then
    with_name(name)
  else
    vim.ui.input({ prompt = "New crate name: " }, with_name)
  end
end

-- Workspace-wide tools (supply chain, size, build time).
local TOOLS = {
  { "timings (cargo build --timings; report in target/cargo-timings)", { "cargo", "build", "--timings" } },
  { "bloat by crate (release)", { "cargo", "bloat", "--release", "--crates" } },
  { "bloat by function (release, top 30)", { "cargo", "bloat", "--release", "-n", "30" } },
  { "unused dependencies (cargo machete)", { "cargo", "machete" } },
  { "deny: fetch advisory DB", { "cargo", "deny", "fetch" } },
  { "deny: check all", { "cargo", "deny", "check" } },
  { "audit (RustSec)", { "cargo", "audit" } },
  { "duplicate dependency versions", { "cargo", "tree", "-d" } },
  { "coverage report (summary in terminal)", { "cargo", "llvm-cov", "--workspace", "--summary-only" }, true },
}

function M.tools()
  local root = rc.root()
  if not root then
    return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
  end
  local items = vim.tbl_map(function(t)
    local cmd = t[2]
    if t[3] then -- builds the workspace: same features/target as the diagnostics
      cmd = vim.list_extend(vim.deepcopy(cmd), ctx_flags(root))
    end
    return { text = t[1], cmd = cmd }
  end, TOOLS)
  Snacks.picker({
    title = "Cargo tools",
    items = items,
    format = "text",
    layout = { preset = "select" },
    confirm = function(picker, item)
      picker:close()
      if item then
        term(item.cmd, root)
      end
    end,
  })
end

--- :ActJob - run the GitHub Actions job under the cursor locally with `act`.
function M.act_job()
  local file = vim.api.nvim_buf_get_name(0)
  local node = vim.treesitter.get_node()
  local job
  while node do
    if node:type() == "block_mapping_pair" then
      local pair_parent = node:parent() and node:parent():parent()
      local grand = pair_parent and pair_parent:parent()
      local gkey = grand and grand:type() == "block_mapping_pair" and grand:field("key")[1]
      if gkey and vim.treesitter.get_node_text(gkey, 0) == "jobs" then
        job = vim.treesitter.get_node_text(node:field("key")[1], 0)
        break
      end
    end
    node = node:parent()
  end
  if not job then
    return vim.notify("cursor is not inside a job under `jobs:`", vim.log.levels.WARN)
  end
  local root = vim.fs.root(file, ".git") or vim.uv.cwd()
  term({ "act", "-j", job, "-W", file }, root)
end

--- <leader>tD: neotest (nextest) cannot run doctests.
function M.doctests()
  local root = rc.root()
  if not root then
    return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
  end
  term(vim.list_extend({ "cargo", "test", "--doc", "--workspace" }, ctx_flags(root)), root)
end

function M.setup()
  vim.api.nvim_create_user_command("RustTargets", M.targets, { desc = "Run/test/bench a cargo target" })
  vim.api.nvim_create_user_command("RustTools", M.tools, { desc = "Cargo tools: deny, audit, bloat, timings, ..." })
  vim.api.nvim_create_user_command("ActJob", M.act_job, { desc = "Run the GitHub Actions job under the cursor with act" })
  vim.api.nvim_create_user_command("RustNew", function(a)
    M.new(a.args)
  end, { nargs = "?", desc = "cargo new in the current directory" })
end

return M
