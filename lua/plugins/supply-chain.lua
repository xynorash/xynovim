-- Supply-chain / CI diagnostics as nvim-lint sources (roadmap step 9), the
-- stuff RustRover has no built-in advisory scanning for:
--   Cargo.toml / Cargo.lock : cargo-deny (advisories + bans), cargo-machete (unused deps)
--   .github/workflows/*.yml : actionlint + zizmor
-- Everything runs on the LazyVim lint events (save, read, InsertLeave) and is
-- skipped unless its precondition holds, so ordinary projects pay nothing.
local function basename(f)
  return vim.fs.basename(f)
end

local function manifest_dir(file)
  return vim.fs.dirname(file)
end

--- Line of `name = ...` / `[dependencies.name]` in a Cargo.toml buffer (0-based), else 0.
local function dep_line(bufnr, name)
  local esc = vim.pesc(name)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:match("^%s*" .. esc .. "%s*=") or l:match("^%s*%[.*dependencies%." .. esc .. "%]") then
      return i - 1
    end
  end
  return 0
end

local deny_severity = {
  error = vim.diagnostic.severity.ERROR,
  warning = vim.diagnostic.severity.WARN,
  note = vim.diagnostic.severity.INFO,
  help = vim.diagnostic.severity.HINT,
}

local function in_workflows(ctx)
  return ctx.filename:find("/%.github/workflows/") ~= nil
end

return {
  "mfussenegger/nvim-lint",
  opts = {
    linters_by_ft = {
      toml = { "cargo_deny", "cargo_machete" },
      yaml = { "actionlint", "zizmor" },
    },
    linters = {
      actionlint = { condition = in_workflows },
      zizmor = { condition = in_workflows },

      -- Needs a deny.toml (`cargo deny init`) next to the manifest or in
      -- .cargo/. --disable-fetch: never hit the network from an editor event;
      -- refresh the advisory DB with `cargo deny fetch` (:RustTools).
      cargo_deny = {
        condition = function(ctx)
          local name = basename(ctx.filename)
          return (name == "Cargo.toml" or name == "Cargo.lock")
            and vim.fs.find({ "deny.toml", ".cargo/deny.toml" }, { path = ctx.dirname, upward = true })[1] ~= nil
        end,
        cmd = "cargo",
        stdin = false,
        stream = "stderr",
        ignore_exitcode = true,
        args = {
          "deny",
          "--manifest-path",
          function()
            local f = vim.api.nvim_buf_get_name(0)
            return manifest_dir(f) .. "/Cargo.toml"
          end,
          "--format",
          "json",
          "--disable-fetch",
          "check",
          "advisories",
          "bans",
        },
        parser = function(output, bufnr)
          local file = vim.api.nvim_buf_get_name(bufnr)
          local is_lock = basename(file) == "Cargo.lock"
          local out = {}
          for line in vim.gsplit(output, "\n", { plain = true, trimempty = true }) do
            local ok, d = pcall(vim.json.decode, line)
            local f = ok and d and d.type == "diagnostic" and d.fields
            if f then
              local label = f.labels and f.labels[1]
              local lnum, col = 0, 0
              if is_lock and label then
                lnum, col = (label.line or 1) - 1, (label.column or 1) - 1
              elseif not is_lock then
                local krate = f.graphs and f.graphs[1] and f.graphs[1].Krate
                lnum = krate and dep_line(bufnr, krate.name) or 0
              end
              out[#out + 1] = {
                lnum = lnum,
                col = col,
                severity = deny_severity[f.severity] or vim.diagnostic.severity.WARN,
                source = "cargo-deny",
                code = f.code,
                message = f.message .. (label and label.message and (" - " .. label.message) or ""),
              }
            end
          end
          return out
        end,
      },

      -- Unused dependencies. Only on Cargo.toml; heuristic (regex based), so
      -- it can false-positive on macro-only or build-script-only deps - ignore
      -- those with [package.metadata.cargo-machete] ignored = ["name"].
      cargo_machete = {
        condition = function(ctx)
          return basename(ctx.filename) == "Cargo.toml"
        end,
        cmd = "cargo-machete",
        stdin = false,
        ignore_exitcode = true,
        args = {
          function()
            return manifest_dir(vim.api.nvim_buf_get_name(0))
          end,
        },
        parser = function(output, bufnr)
          local file = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
          local dir = manifest_dir(file)
          local out, current = {}, nil
          for line in vim.gsplit(output, "\n", { plain = true, trimempty = true }) do
            local path = line:match("^%S+ %-%- (.+):$")
            if path then
              current = vim.fs.normalize(dir .. "/" .. path:gsub("^%./", "")) == file
            elseif current and line:match("^\t%S+$") then
              local dep = vim.trim(line)
              out[#out + 1] = {
                lnum = dep_line(bufnr, dep),
                col = 0,
                severity = vim.diagnostic.severity.WARN,
                source = "cargo-machete",
                message = "unused dependency `" .. dep .. "`",
              }
            end
          end
          return out
        end,
      },
    },
  },
}
