return {
  "ThePrimeagen/99",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    -- required by 99's blink completion source
    { "saghen/blink.compat", version = "2.*" },
    -- the pre-request checkpoint (not lazy itself, see plugins/xyno-history.lua)
    "xynorash/xyno-history.nvim",
    -- the sandbox policy and wrapper (fail closed)
    "xynorash/xyno-sandbox.nvim",
  },
  -- Everything is reached through these keymaps, so lazy-load on them
  -- instead of eager-loading 99 + telescope + blink.compat at startup.
  keys = {
    {
      "<leader>9s",
      function()
        require("99").search()
      end,
      desc = "99: Search",
    },
    {
      "<leader>9v",
      function()
        require("99").vibe()
      end,
      desc = "99: Vibe",
    },
    {
      "<leader>9vv",
      function()
        require("99").visual()
      end,
      mode = "v",
      desc = "99: Visual",
    },
    {
      "<leader>9o",
      function()
        require("99").open()
      end,
      desc = "99: Open last interaction",
    },
    {
      "<leader>9l",
      function()
        require("99").view_logs()
      end,
      desc = "99: View logs",
    },
    {
      "<leader>9c",
      function()
        require("99").clear_previous_requests()
      end,
      desc = "99: Clear previous",
    },
    {
      "<leader>9x",
      function()
        require("99").stop_all_requests()
      end,
      desc = "99: Stop all requests",
    },
    {
      "<leader>9w",
      function()
        require("99").Extensions.Worker.search()
      end,
      desc = "99: Worker search",
    },
    {
      "<leader>9W",
      function()
        require("99").Extensions.Worker.set_work()
      end,
      desc = "99: Worker set work",
    },
    {
      "<leader>9m",
      function()
        require("99.extensions.telescope").select_model()
      end,
      desc = "99: Select model",
    },
    -- capitalized: keeps the provider picker grouped with the model picker
    {
      "<leader>9P",
      function()
        require("99.extensions.telescope").select_provider()
      end,
      desc = "99: Select provider",
    },
  },
  config = function()
    local _99 = require("99")

    -- 99 never cleans its tmp_dir, so request files accumulate forever.
    -- Prune anything older than 7 days when 99 first loads in a session.
    local tmp_dir = vim.fn.stdpath("cache") .. "/99"
    if vim.uv.fs_stat(tmp_dir) then
      local cutoff = os.time() - 7 * 24 * 3600
      for name, kind in vim.fs.dir(tmp_dir) do
        if kind == "file" then
          local path = tmp_dir .. "/" .. name
          local stat = vim.uv.fs_stat(path)
          if stat and stat.mtime.sec < cutoff then
            vim.uv.fs_unlink(path)
          end
        end
      end
    end

    -- Safety wrapper around the stock Claude Code provider (see README
    -- roadmap step 5): checkpoint the worktree as a git ref before every
    -- request, keep auto-save from writing the agent's edits straight to disk
    -- while requests are in flight, and run claude inside bubblewrap.
    local Claude = _99.Providers.ClaudeCodeProvider
    local Guarded = setmetatable({}, { __index = Claude })
    local inflight, we_disabled_autosave = 0, false

    -- One token per request; release() is idempotent so the counter drops
    -- exactly once however the request ends (on_complete, sync throw, or a
    -- cancel that never reaches on_complete).
    local function acquire()
      if inflight == 0 then
        local ok, as = pcall(require, "auto-save")
        we_disabled_autosave = ok and as.enabled() == true
        if we_disabled_autosave then
          as.off()
        end
      end
      inflight = inflight + 1
      return { done = false, handle = nil }
    end

    local function release(token)
      if token.done then
        return
      end
      token.done = true
      -- the sandbox handle removes the private copy of the agent config and the empty placeholders
      -- the guards left in the project (older plugin versions return no handle)
      if token.handle then
        pcall(token.handle.release)
      end
      inflight = math.max(0, inflight - 1)
      if inflight == 0 and we_disabled_autosave then
        we_disabled_autosave = false
        -- Only undo our own change: if the user switched auto-save back on
        -- meanwhile, there is nothing to restore.
        local ok, as = pcall(require, "auto-save")
        if ok and as.enabled() ~= true then
          as.on()
        end
      end
    end

    -- ---- how a failed agent run reads
    -- 99's base provider reports a non-zero exit as "process exit code: N" plus vim.inspect of the whole
    -- result (with the complete stdout and stderr: megabytes for a chatty agent) and then calls
    -- logger:fatal, which is assert(false): an unhandled Lua error with a stack trace in the exit callback.
    -- Claude writes its real reason ("Not logged in - Please run /login") to stdout, bwrap writes its own to
    -- stderr; both are collected here (capped) and the failure is one message: the reason, a hint.
    local TAIL = 8192
    local function capped(buf, data)
      buf[1] = (buf[1] .. data):sub(-TAIL)
    end
    local function last_lines(text, n)
      local out = {}
      for line in tostring(text or ""):gmatch("[^\r\n]+") do
        line = vim.trim((line:gsub("\27%[[%d;?]*[%a]", "")))
        if line ~= "" then
          out[#out + 1] = line:sub(1, 300)
        end
      end
      return table.concat(vim.list_slice(out, math.max(1, #out - n + 1)), "\n")
    end
    local function failure_message(code, out, err)
      local seen = (err or "") .. "\n" .. (out or "")
      local low = seen:lower()
      local hint
      if low:find("not logged in", 1, true) or low:find("/login", 1, true) or low:find("invalid api key", 1, true) then
        hint = "run `claude` in a normal terminal and /login (the sandbox uses the same credentials), then retry"
      elseif low:find("execvp", 1, true) and low:find("no such file", 1, true) then
        hint = "the `claude` command is not on PATH inside the sandbox: install Claude Code or fix PATH"
      elseif
        low:find("creating new namespace", 1, true)
        or low:find("no permissions to create", 1, true)
        or low:find("operation not permitted", 1, true) and low:find("bwrap", 1, true)
        or low:find("unprivileged_userns", 1, true)
      then
        hint = "user namespaces are blocked here, so bubblewrap cannot start; the agent will not run unsandboxed"
          .. " unless you set vim.g.xynovim_99_allow_unsandboxed = true (see :XynoSandboxStatus)"
      elseif
        low:find("could not resolve host", 1, true)
        or low:find("econnrefused", 1, true)
        or low:find("enotfound", 1, true)
        or low:find("fetch failed", 1, true)
        or low:find("unable to connect", 1, true)
        or low:find("network", 1, true)
      then
        hint = "the agent could not reach the API: check the network, the proxy and :XynoSandboxStatus"
      elseif code == 137 or code == 143 or code == 130 then
        hint = "the agent was killed (signal), e.g. by the out-of-memory killer or <leader>9x"
      end
      local reason = last_lines(err, 3)
      if reason == "" then
        reason = last_lines(out, 3)
      end
      if reason == "" then
        reason = "no output"
      end
      return ("99: the agent exited with code %s: %s%s (details: <leader>9l)"):format(
        tostring(code),
        reason:gsub("\n", " | "),
        hint and ("\nHint: " .. hint) or ""
      )
    end

    -- The Claude provider's model list is static (the CLI cannot list models)
    -- and predates claude-sonnet-5, the model set below.
    function Guarded.fetch_models(callback)
      Claude.fetch_models(function(models, err)
        if models then
          table.insert(models, 1, "claude-sonnet-5")
        end
        callback(models, err)
      end)
    end

    local function project_root()
      return vim.fs.root(0, ".git") or vim.uv.cwd()
    end

    -- The plan the operator saw in the preview, handed to the (synchronous) Claude.make_request call
    -- so the command that runs is that plan; the sandbox handle comes back the same way.
    local pending

    function Guarded._build_command(self, query, context)
      local cmd = Claude._build_command(self, query, context)
      local project = project_root()
      local wrapped, err, handle =
        require("xyno_sandbox").wrap(cmd, project, tmp_dir, pending and { plan = pending.plan })
      if not wrapped then
        error("99 sandbox: " .. tostring(err), 0)
      end
      if pending then
        pending.handle = handle
      end
      return wrapped
    end

    function Guarded.make_request(self, query, context, observer)
      -- Fail closed before anything else happens (no snapshot, no auto-save
      -- toggle, no process): claude runs with --dangerously-skip-permissions.
      local st = require("xyno_sandbox").status()
      if st.mode == "refused" then
        local msg = "99 refused to start: "
          .. st.reason
          .. (st.hint and (" (" .. st.hint .. ")") or "")
          .. ". The agent only runs sandboxed (Linux with bubblewrap, or WSL2 with bubblewrap). To run it anyway"
          .. " set vim.g.xynovim_99_allow_unsandboxed = true: claude --dangerously-skip-permissions then runs"
          .. " with your full privileges."
        vim.notify(msg, vim.log.levels.ERROR)
        pcall(observer.on_start)
        pcall(observer.on_complete, "failed", msg)
        return nil
      elseif st.mode == "unsandboxed" then
        vim.notify(
          "99 runs claude --dangerously-skip-permissions WITHOUT a sandbox ("
            .. st.reason
            .. "): the whole filesystem, your credentials and the network are reachable.",
          vim.log.levels.WARN
        )
      end
      local function go(plan)
        local token = acquire()
        local guarded_observer = setmetatable({
          on_complete = function(...)
            release(token)
            return observer.on_complete(...)
          end,
        }, { __index = observer })
        -- <leader>9x (stop_all_requests) cancels the prompt; on_complete only
        -- follows once the process exits, and never if none was started.
        local cancel = context.cancel
        if type(cancel) == "function" then
          context.cancel = function(...)
            local ok, err = pcall(cancel, ...)
            release(token)
            if not ok then
              error(err, 0)
            end
          end
        end
        local started, result = false, nil
        -- A synchronous throw (e.g. spawn failure) never reaches on_complete.
        local function start()
          if started or token.done then -- done: cancelled while the checkpoint ran
            return
          end
          started = true
          pending = { plan = plan }
          local out, err = { "" }, { "" }
          local inner = guarded_observer
          guarded_observer = setmetatable({
            on_stdout = function(data, ...)
              if type(data) == "string" then
                capped(out, data)
              end
              return inner.on_stdout(data, ...)
            end,
            on_stderr = function(data, ...)
              if type(data) == "string" then
                capped(err, data)
              end
              return inner.on_stderr(data, ...)
            end,
            on_complete = function(status, text, ...)
              if status == "failed" and type(text) == "string" then
                local code = text:match("^process exit code: (%-?%d+)")
                if code then
                  text = failure_message(tonumber(code), out[1], err[1])
                end
                -- one readable message (the logger's print_on_error would print a JSON blob)
                vim.notify(text:sub(1, 600), vim.log.levels.ERROR)
              end
              return inner.on_complete(status, text, ...)
            end,
          }, { __index = inner })
          -- logger:fatal in the base provider is assert(false): downgrade it to an error entry
          local real_logger = context.logger
          if type(real_logger) == "table" and type(real_logger.set_area) == "function" then
            context.logger = setmetatable({
              set_area = function(_, area)
                local l = real_logger:set_area(area)
                return setmetatable({
                  fatal = function(_, msg, ...)
                    return l:error(msg, ...)
                  end,
                }, {
                  __index = function(_, k)
                    local v = l[k]
                    if type(v) == "function" then
                      return function(_, ...)
                        return v(l, ...)
                      end
                    end
                    return v
                  end,
                })
              end,
            }, { __index = real_logger })
          end
          local ok, res = pcall(Claude.make_request, self, query, context, guarded_observer)
          local handle = pending.handle
          pending = nil
          token.handle = handle
          if token.done and handle then
            pcall(handle.release) -- cancelled meanwhile
          end
          if not ok then
            release(token)
            -- a throw from the spawn (no `claude` on PATH: ENOENT; the sandbox refusing the command) would reach
            -- the keymap as an "E5108: Error executing lua" with a stack trace: one message instead
            local why = tostring(res)
            local msg = "99: could not start the agent: "
              .. (
                why:find("ENOENT", 1, true)
                  and "the `claude` command was not found on PATH (install Claude Code, then retry)"
                or why
              )
            vim.notify(msg, vim.log.levels.ERROR)
            pcall(observer.on_complete, "failed", msg)
            return
          end
          result = res
        end
        -- The agent must not start before the checkpoint holds the pre-request
        -- state (a fast agent rewrote files while the snapshot was still
        -- reading them): start from the snapshot's `done`, or after 15 s.
        local path = vim.api.nvim_buf_get_name(0)
        if path ~= "" and vim.fs.root(path, ".git") then
          vim.defer_fn(start, 15000)
          require("xyno_history").snapshot({
            path = path,
            force = true,
            label = "before 99 request",
            done = start,
          })
        else
          start()
        end
        return result
      end

      -- The policy preview (xyno-sandbox.nvim, setting `preview`): what the sandbox allows, hides and
      -- strips, and the --dangerously-skip-permissions line, before anything starts. Interactive, so
      -- the request continues from the confirm; without a UI (headless) or an older plugin it goes on
      -- at once. Cancelling ends the request as cancelled: no snapshot, no auto-save toggle, no process.
      local sandbox = require("xyno_sandbox")
      if type(sandbox.confirm) == "function" and st.mode ~= "refused" then
        local returned
        sandbox.confirm(Claude._build_command(self, query, context), project_root(), tmp_dir, function(ok, plan)
          if ok then
            returned = go(plan)
          else
            pcall(observer.on_start)
            pcall(observer.on_complete, "cancelled", tostring(plan))
          end
        end)
        return returned
      end
      return go(nil)
    end

    _99.setup({
      provider = Guarded,
      model = "claude-sonnet-5",
      provider_extra_args = { "--effort", "medium" },
      -- MUST be absolute. 99 resolves a relative tmp_dir against nvim's cwd,
      -- but claude resolves the same relative TEMP_FILE against the project
      -- it's working in - launch nvim from outside the project (e.g.
      -- `nvim Projects/foo/` from ~) and the answer lands where 99 never
      -- reads, so every response comes back empty. An absolute path is
      -- unambiguous for both sides; writing outside claude's cwd is fine
      -- because the provider passes --dangerously-skip-permissions.
      tmp_dir = tmp_dir,
      display_errors = true,
      logger = {
        -- type = "file" is required for path to take effect; without it the
        -- logger silently uses a void sink (the README example omits it).
        type = "file",
        level = _99.INFO,
        path = vim.fn.stdpath("state") .. "/99.log",
        -- off: a failed request is reported as one readable message (Guarded below); the JSON line
        -- print_on_error would print is in the log (<leader>9l) either way
        print_on_error = false,
      },
      completion = {
        -- #rules / @files completion in the prompt buffer via LazyVim's
        -- completion engine (default is the plugin's own "native" source).
        source = "blink",
      },
    })

    -- The <leader>9P picker (and anything else) swaps the provider with
    -- _99.set_provider. The stock providers of the other CLIs run with no
    -- sandbox, no checkpoint and no auto-save guard, so only the guarded
    -- provider may be selected unless the sandbox was switched off explicitly.
    local set_provider = _99.set_provider
    -- allow_unsandboxed only counts when no backend exists (status().via);
    -- with a working bwrap only sandbox = false opts out.
    local function allowed(provider)
      if provider == Guarded or vim.g.xynovim_99_sandbox == false then
        return true
      end
      local st = require("xyno_sandbox").status()
      return st.mode == "unsandboxed" and st.via == "allow_unsandboxed"
    end
    -- The opt-in is re-checked on EVERY request, not only at selection: a
    -- provider chosen under it must not keep running once it is revoked, and
    -- each unsandboxed request warns.
    local proxies = {}
    local function checked(provider)
      if provider == Guarded or provider == nil then
        return provider
      end
      if not proxies[provider] then
        proxies[provider] = setmetatable({
          _xyno_inner = provider,
          make_request = function(self, query, context, observer)
            if not allowed(provider) then
              local msg = "99 refused to start: this provider runs without the sandbox, checkpoint and auto-save"
                .. " guard, and the opt-in (vim.g.xynovim_99_sandbox = false or vim.g.xynovim_99_allow_unsandboxed"
                .. " = true) is not set any more. Select the Claude Code provider (<leader>9P)."
              vim.notify(msg, vim.log.levels.ERROR)
              pcall(observer.on_start)
              pcall(observer.on_complete, "failed", msg)
              return nil
            end
            vim.notify(
              "99 runs this provider WITHOUT a sandbox, checkpoint or auto-save guard: the whole filesystem,"
                .. " your credentials and the network are reachable.",
              vim.log.levels.WARN
            )
            return provider.make_request(self, query, context, observer)
          end,
        }, { __index = provider })
      end
      return proxies[provider]
    end
    function _99.set_provider(provider)
      if not allowed(provider) then
        vim.notify(
          "99: only the guarded Claude Code provider can be selected (the other providers run without the"
            .. " sandbox, checkpoint and auto-save guard). Set vim.g.xynovim_99_sandbox = false or"
            .. " vim.g.xynovim_99_allow_unsandboxed = true to allow them.",
          vim.log.levels.ERROR
        )
        return _99
      end
      return set_provider(checked(provider))
    end
    -- the picker announces "Provider set" after its call: skip that when refused
    local pickers = require("99.extensions.pickers")
    local on_selected = pickers.on_provider_selected
    function pickers.on_provider_selected(name, lookup)
      local provider = lookup[name]
      if provider and not allowed(provider) then
        _99.set_provider(provider) -- prints the refusal
        return
      end
      return on_selected(name, lookup)
    end
  end,
}
