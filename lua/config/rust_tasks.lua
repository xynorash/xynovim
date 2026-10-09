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

--- Feature/target flags of the stored context.
local function ctx_flags(root)
  local ctx = rc.get(root)
  local f = {}
  if ctx then
    if ctx.all then
      f[#f + 1] = "--all-features"
    else
      if ctx.no_default then
        f[#f + 1] = "--no-default-features"
      end
      if ctx.features and #ctx.features > 0 then
        vim.list_extend(f, { "--features", table.concat(ctx.features, ",") })
      end
    end
    if ctx.target then
      vim.list_extend(f, { "--target", ctx.target })
    end
  end
  return f
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
        Snacks.terminal(item.cmd, { cwd = root, win = { position = "bottom" } })
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

function M.setup()
  vim.api.nvim_create_user_command("RustTargets", M.targets, { desc = "Run/test/bench a cargo target" })
  vim.api.nvim_create_user_command("RustNew", function(a)
    M.new(a.args)
  end, { nargs = "?", desc = "cargo new in the current directory" })
end

return M
