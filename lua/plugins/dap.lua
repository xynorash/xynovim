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
--- Windows spells a drive "C:" or "c:" depending on who reports the path
--- (cargo metadata, the buffer name, rust_context's canonical root): compare
--- with the drive letter folded.
local function drive_fold(p)
  if vim.fn.has("win32") == 1 then
    return (p:gsub("^%a:", string.lower))
  end
  return p
end

local function current_binary()
  local file = drive_fold(vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
  local meta, root = metadata(file ~= "" and file or (vim.uv.cwd() .. "/x"))
  if not meta then
    return nil
  end
  local best, best_len, rootpkg, firstbin
  for _, pkg in ipairs(meta.packages) do
    local dir = drive_fold(vim.fs.normalize(vim.fs.dirname(pkg.manifest_path)))
    if #bins_of(pkg, "bin") > 0 then
      firstbin = firstbin or pkg
      if dir == drive_fold(vim.fs.normalize(root)) then
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
    path = meta.target_directory .. "/debug/" .. bin.name .. (vim.fn.has("win32") == 1 and ".exe" or ""),
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

local sysroot_script

--- `<rustc sysroot>/lib/rustlib/etc/lldb_lookup.py` (rust's lldb formatters:
--- String, Vec, Option, enums...) or nil when the toolchain does not ship it.
--- Resolved once, on the first launch (not at startup).
local function lldb_lookup_script()
  if sysroot_script == nil then
    local o = vim.system({ "rustc", "--print", "sysroot" }, { text = true }):wait(10000)
    local script = o.code == 0 and vim.trim(o.stdout) .. "/lib/rustlib/etc/lldb_lookup.py"
    sysroot_script = script and vim.uv.fs_stat(script) and script or false
  end
  return sysroot_script or nil
end

--- Every codelldb launch of Rust code (configs 1-3 below, <leader>dr via
--- rustaceanvim, <leader>dR, launch.json: all carry sourceLanguages = rust)
--- gets rust's lldb formatters and a breakpoint on `rust_panic`, so a panic
--- stops at the panicking frame instead of the session ending with exit 101.
--- Done here, not in the configs, because rustaceanvim overwrites initCommands
--- on its own launches. A `#[should_panic]` test stops there too. Only the
--- lldb_lookup.py import is added, never `command source .../lldb_commands`
--- (that file does not exist on current toolchains).
local function rust_lldb_init(config)
  if config.type ~= "codelldb" or not vim.tbl_contains(config.sourceLanguages or {}, "rust") then
    return config
  end
  local cmds = vim.deepcopy(type(config.initCommands) == "table" and config.initCommands or {})
  local script = lldb_lookup_script()
  if script and not vim.iter(cmds):any(function(c)
    return c:find("lldb_lookup.py", 1, true)
  end) then
    table.insert(cmds, 1, 'command script import "' .. script .. '"')
  end
  if not vim.tbl_contains(cmds, "breakpoint set -n rust_panic") then
    cmds[#cmds + 1] = "breakpoint set -n rust_panic"
  end
  config.initCommands = cmds
  return config
end

--- Replace mason-nvim-dap's generic codelldb configs for Rust.
local function rust_configurations()
  return {
    {
      name = "LLDB: Launch",
      type = "codelldb",
      request = "launch",
      sourceLanguages = { "rust" },
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
      sourceLanguages = { "rust" },
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
      sourceLanguages = { "rust" },
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
    -- per-test entries differ only in executableArgs (the test name)
    local key = table.concat(args.cargoArgs, " ") .. " -- " .. table.concat(args.executableArgs or {}, " ")
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
        "test/run: " .. table.concat(c.args.cargoArgs, " ") .. " -- " .. table.concat(c.args.executableArgs or {}, " "),
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

--- <leader>dP: dap.pause() picks from session.threads, which codelldb fills only when it stops, so
--- on a running process it saw no thread ("No thread to stop") and did nothing. Ask for the threads first.
local function pause()
  local dap = require("dap")
  local session = dap.session()
  if not session then
    return notify("no debug session", vim.log.levels.WARN)
  end
  if next(session.threads or {}) then
    return dap.pause()
  end
  session:request("threads", nil, function(err, resp)
    local t = not err and resp and resp.threads and resp.threads[1]
    if not t then
      return notify("no thread to pause", vim.log.levels.WARN)
    end
    dap.pause(t.id)
  end)
end

return {
  {
    "mfussenegger/nvim-dap",
    keys = {
      { "<leader>dR", pick_workspace_debuggable, desc = "Rust Debuggables (whole workspace)" },
      { "<leader>dP", pause, desc = "Pause" },
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
          require("dap").listeners.on_config["xynovim_rust_lldb"] = rust_lldb_init
        end,
      },
    },
  },
  {
    "rcarriga/nvim-dap-ui",
    -- LazyVim's dap.core closes the UI on terminated/exited: the program's
    -- output then lived only in the hidden [dap-terminal] buffer. Keep it open
    -- (close with <leader>du) once the session is over.
    init = function()
      vim.api.nvim_create_autocmd("User", {
        pattern = "LazyLoad",
        callback = function(ev)
          if ev.data == "nvim-dap-ui" then
            vim.schedule(function()
              local l = require("dap").listeners.before
              l.event_terminated["dapui_config"] = nil
              l.event_exited["dapui_config"] = nil
              -- the Console (a terminal window) kept a stale topline after the layout resized:
              -- the output was in the buffer, the window showed blank lines
              local la = require("dap").listeners.after
              local function rescroll()
                vim.defer_fn(function()
                  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                    local b = vim.api.nvim_win_get_buf(w)
                    if vim.bo[b].filetype == "dapui_console" and vim.fn.getwininfo(w)[1].topline >= vim.api.nvim_buf_line_count(b) then
                      vim.api.nvim_win_call(w, function()
                        vim.cmd("normal! gg")
                      end)
                    end
                  end
                end, 50)
              end
              for _, ev in ipairs({ "event_stopped", "event_terminated", "event_exited" }) do
                la[ev]["xynovim_console"] = rescroll
              end
              -- LazyVim gives the breakpoint signs DiagnosticInfo (blue) unless the icon carries a group;
              -- the theme's red / yellow / grey groups exist
              for name, hl in pairs({ DapBreakpoint = "DapBreakpoint", DapBreakpointCondition = "DapBreakpointCondition", DapBreakpointRejected = "DapBreakpointRejected" }) do
                local def = vim.fn.sign_getdefined(name)[1]
                if def then
                  vim.fn.sign_define(name, { text = def.text, texthl = hl, linehl = def.linehl, numhl = def.numhl })
                end
              end
            end)
          end
        end,
      })
    end,
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
