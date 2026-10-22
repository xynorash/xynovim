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
    { "<leader>9s", function() require("99").search() end, desc = "99: Search" },
    { "<leader>9v", function() require("99").vibe() end, desc = "99: Vibe" },
    { "<leader>9vv", function() require("99").visual() end, mode = "v", desc = "99: Visual" },
    { "<leader>9o", function() require("99").open() end, desc = "99: Open last interaction" },
    { "<leader>9l", function() require("99").view_logs() end, desc = "99: View logs" },
    { "<leader>9c", function() require("99").clear_previous_requests() end, desc = "99: Clear previous" },
    { "<leader>9x", function() require("99").stop_all_requests() end, desc = "99: Stop all requests" },
    { "<leader>9w", function() require("99").Extensions.Worker.search() end, desc = "99: Worker search" },
    { "<leader>9W", function() require("99").Extensions.Worker.set_work() end, desc = "99: Worker set work" },
    {
      "<leader>9m",
      function() require("99.extensions.telescope").select_model() end,
      desc = "99: Select model",
    },
    -- capitalized: keeps the provider picker grouped with the model picker
    {
      "<leader>9P",
      function() require("99.extensions.telescope").select_provider() end,
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
      return { done = false }
    end

    local function release(token)
      if token.done then
        return
      end
      token.done = true
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

    function Guarded._build_command(self, query, context)
      local cmd = Claude._build_command(self, query, context)
      local project = vim.fs.root(0, ".git") or vim.uv.cwd()
      local wrapped, err = require("xyno_sandbox").wrap(cmd, project, tmp_dir)
      if not wrapped then
        error("99 sandbox: " .. tostring(err), 0)
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
        local ok, res = pcall(Claude.make_request, self, query, context, guarded_observer)
        if not ok then
          release(token)
          error(res, 0)
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
        print_on_error = true,
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
