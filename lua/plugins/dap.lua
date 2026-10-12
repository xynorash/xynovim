-- Debugging on top of LazyVim's dap.core + lang.rust extras.
--   * Rust launch configs that default to the package binary under
--     <target dir>/debug/ instead of the project root,
--   * a wider dap-ui sidebar (long Rust type names) with wrapping on,
--   * <leader>dR: debuggables for the WHOLE workspace (binaries, examples and
--     the current file's rust-analyzer runnables) - <leader>dr only offers
--     what rust-analyzer returns for the current file (lib.rs: just tests).
-- Locals need full debuginfo: see profile.dev in ~/.cargo/config.toml.
local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "dap" })
end

--- `cargo metadata --no-deps` for the workspace holding `path`, or nil.
local function metadata(path)
  local root = require("config.rust_context").root(path)
  if not root then
    return nil
  end
  local o = vim
    .system({ "cargo", "metadata", "--format-version", "1", "--no-deps" }, { cwd = root, text = true })
    :wait(30000)
  if o.code ~= 0 then
    return nil
  end
  local ok, meta = pcall(vim.json.decode, o.stdout)
  return ok and meta or nil, root
end

local function bins_of(pkg, kind)
  local r = {}
  for _, t in ipairs(pkg.targets) do
    if vim.tbl_contains(t.kind, kind) then
      r[#r + 1] = t
    end
  end
  return r
end

--- The package/binary the current buffer belongs to: the package containing
--- the file (else the workspace root package, else the first one) and its bin
--- named like the package (else its first bin). Returns { pkg, bin, dir, path }.
local function current_binary()
  local file = vim.api.nvim_buf_get_name(0)
  local meta, root = metadata(file ~= "" and file or (vim.uv.cwd() .. "/x"))
  if not meta then
    return nil
  end
  local best, best_len, rootpkg, firstbin
  for _, pkg in ipairs(meta.packages) do
    local dir = vim.fs.dirname(pkg.manifest_path)
    if #bins_of(pkg, "bin") > 0 then
      firstbin = firstbin or pkg
      if dir == root then
        rootpkg = pkg
      end
      if file:sub(1, #dir + 1) == dir .. "/" and #dir > (best_len or 0) then
        best, best_len = pkg, #dir
      end
    end
  end
  local pkg = best or rootpkg or firstbin
  if not pkg then
    return nil
  end
  local bins = bins_of(pkg, "bin")
  local bin = bins[1]
  for _, b in ipairs(bins) do
    if b.name == pkg.name then
      bin = b
    end
  end
  return {
    pkg = pkg.name,
    bin = bin.name,
    dir = vim.fs.dirname(pkg.manifest_path),
    path = meta.target_directory .. "/debug/" .. bin.name,
  }
end

local function default_program()
  local b = current_binary()
  return b and b.path or vim.fn.getcwd() .. "/"
end

local function prompt_program()
  return vim.fn.input("Path to executable: ", default_program(), "file")
end

local function prompt_args()
  return vim.split(vim.fn.input("Args: "), " +", { trimempty = true })
end

--- Build the current package's binary (yielding when run inside nvim-dap's
--- coroutine so the UI stays responsive) and return its path.
local function build_current_binary()
  local b = current_binary()
  if not b then
    notify("no Cargo package with a binary found for this buffer", vim.log.levels.ERROR)
    return require("dap").ABORT
  end
  notify("cargo build --package " .. b.pkg .. " --bin " .. b.bin)
  local cmd = { "cargo", "build", "--package", b.pkg, "--bin", b.bin }
  local co = coroutine.running()
  local res
  if co then
    vim.system(cmd, { cwd = b.dir, text = true }, function(o)
      vim.schedule(function()
        coroutine.resume(co, o)
      end)
    end)
    res = coroutine.yield()
  else
    res = vim.system(cmd, { cwd = b.dir, text = true }):wait()
  end
  if res.code ~= 0 then
    notify("cargo build failed:\n" .. (res.stderr or ""), vim.log.levels.ERROR)
    return require("dap").ABORT
  end
  return b.path
end

local function package_dir()
  local b = current_binary()
  return b and b.dir or vim.fn.getcwd()
end

--- Replace mason-nvim-dap's generic codelldb configs for Rust.
local function rust_configurations()
  return {
    {
      name = "LLDB: Launch",
      type = "codelldb",
      request = "launch",
      program = prompt_program,
      cwd = "${workspaceFolder}",
      stopOnEntry = false,
      args = {},
      console = "integratedTerminal",
    },
    {
      name = "LLDB: Launch (args)",
      type = "codelldb",
      request = "launch",
      program = prompt_program,
      cwd = "${workspaceFolder}",
      stopOnEntry = false,
      args = prompt_args,
      console = "integratedTerminal",
    },
    {
      name = "Rust: run current package binary (args prompt)",
      type = "codelldb",
      request = "launch",
      program = build_current_binary,
      cwd = package_dir,
      stopOnEntry = false,
      args = prompt_args,
      console = "integratedTerminal",
    },
  }
end

--- All debuggable cargo runnables of the workspace: bins/examples from cargo
--- metadata plus rust-analyzer's runnables for the current file, as
--- rustaceanvim runnables ({ label, args = { cargoArgs, workspaceRoot, ... } }).
local function workspace_debuggables(ra_result)
  local ra_runnables = require("rustaceanvim.runnables")
  local items, seen = {}, {}
  local function add(label, args)
    local key = table.concat(args.cargoArgs, " ")
    if not seen[key] then
      seen[key] = true
      items[#items + 1] = { label = label, args = args }
    end
  end
  local meta, root = metadata(vim.api.nvim_buf_get_name(0))
  for _, pkg in ipairs(meta and meta.packages or {}) do
    for _, kind in ipairs({ "bin", "example" }) do
      for _, t in ipairs(bins_of(pkg, kind)) do
        add(("%s %s (%s)"):format(kind, t.name, pkg.name), {
          cargoArgs = { "build", "--package", pkg.name, "--" .. kind, t.name },
          cargoExtraArgs = {},
          executableArgs = {},
          workspaceRoot = root,
          cwd = vim.fs.dirname(pkg.manifest_path),
        })
      end
    end
  end
  local overrides = require("rustaceanvim.overrides")
  for _, r in ipairs(ra_result or {}) do
    local c = ra_runnables.as_cargo_runnable(r)
    if c and c.args.cargoArgs[1] ~= "check" then
      overrides.sanitize_command_for_debugging(c.args.cargoArgs)
      add(
        "test/run: " .. table.concat(c.args.cargoArgs, " ") .. " " .. table.concat(c.args.executableArgs or {}, " "),
        c.args
      )
    end
  end
  return items
end

local function pick_workspace_debuggable()
  if vim.bo.filetype ~= "rust" then
    return notify("<leader>dR works from a Rust buffer", vim.log.levels.WARN)
  end
  local function choose(items)
    if #items == 0 then
      return notify("no debuggable targets found", vim.log.levels.WARN)
    end
    vim.ui.select(items, {
      prompt = "Debuggables (workspace)",
      kind = "rust-tools/debuggables",
      format_item = function(i)
        return i.label
      end,
    }, function(choice)
      if not choice then
        return
      end
      require("rustaceanvim.dap").start(choice.args, true, require("dap").run)
      require("rustaceanvim.cached_commands").set_last_debuggable(choice.args)
    end)
  end
  -- current file's rust-analyzer runnables (tests...), merged with the bins
  local params = { textDocument = vim.lsp.util.make_text_document_params(), position = nil }
  require("rustaceanvim.rust_analyzer").buf_request(0, "experimental/runnables", params, function(_, result)
    choose(workspace_debuggables(result))
  end)
end

return {
  {
    "mfussenegger/nvim-dap",
    keys = {
      { "<leader>dR", pick_workspace_debuggable, desc = "Rust Debuggables (whole workspace)" },
    },
  },
  {
    "jay-babu/mason-nvim-dap.nvim",
    opts = {
      handlers = {
        codelldb = function(config)
          require("mason-nvim-dap").default_setup(config)
          -- default_setup extends c/cpp/rust with the same shared tables;
          -- give Rust its own list.
          require("dap").configurations.rust = rust_configurations()
        end,
      },
    },
  },
  {
    "rcarriga/nvim-dap-ui",
    opts = function()
      -- wide enough for `alloc::vec::Vec<alloc::string::String, alloc::alloc::Global>`
      -- on a normal terminal, but never more than a third of a narrow one.
      local width = math.max(40, math.min(60, math.floor(vim.o.columns * 0.35)))
      return {
        wrap = true,
        layouts = {
          {
            elements = {
              { id = "scopes", size = 0.4 },
              { id = "breakpoints", size = 0.15 },
              { id = "stacks", size = 0.25 },
              { id = "watches", size = 0.2 },
            },
            position = "left",
            size = width,
          },
          {
            elements = {
              { id = "repl", size = 0.5 },
              { id = "console", size = 0.5 },
            },
            position = "bottom",
            size = 10,
          },
        },
      }
    end,
  },
}
