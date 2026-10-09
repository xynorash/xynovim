return {
  "ThePrimeagen/99",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    -- required by 99's blink completion source
    { "saghen/blink.compat", version = "2.*" },
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
    local inflight, autosave_was_on = 0, false

    function Guarded._build_command(self, query, context)
      local cmd = Claude._build_command(self, query, context)
      local project = vim.fs.root(0, ".git") or vim.uv.cwd()
      return require("config.agent_sandbox").wrap(cmd, project, tmp_dir)
    end

    function Guarded.make_request(self, query, context, observer)
      require("config.local_history").snapshot({
        path = vim.api.nvim_buf_get_name(0),
        force = true,
        label = "before 99 request",
      })
      if inflight == 0 then
        local ok, as = pcall(require, "auto-save")
        autosave_was_on = ok and as.enabled() == true
        if autosave_was_on then
          as.off()
        end
      end
      inflight = inflight + 1
      local on_complete = observer.on_complete
      observer.on_complete = function(...)
        inflight = math.max(0, inflight - 1)
        if inflight == 0 and autosave_was_on then
          require("auto-save").on()
        end
        return on_complete(...)
      end
      -- A synchronous throw (e.g. spawn failure) never reaches on_complete.
      local ok, res = pcall(Claude.make_request, self, query, context, observer)
      if not ok then
        inflight = math.max(0, inflight - 1)
        if inflight == 0 and autosave_was_on then
          require("auto-save").on()
        end
        error(res, 0)
      end
      return res
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
  end,
}
