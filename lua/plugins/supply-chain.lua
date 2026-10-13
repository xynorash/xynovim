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

--- Line (0-based) of `name = "<name>"` of the `[[package]]` with this version in
--- a Cargo.lock buffer, else nil. (cargo-deny's own label points at a synthetic
--- rendering of the lockfile: it is not the line of this file.)
local function lock_line(bufnr, name, version)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, l in ipairs(lines) do
    if l == ('name = "%s"'):format(name) and (not version or lines[i + 1] == ('version = "%s"'):format(version)) then
      return i - 1
    end
  end
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
      -- .cargo/. --offline: never hit the network from an editor event (uses
      -- the cached advisory DB; refresh it with `cargo deny fetch`, :RustTools).
      cargo_deny = {
        condition = function(ctx)
          local name = basename(ctx.filename)
          return (name == "Cargo.toml" or name == "Cargo.lock")
            and vim.fs.find({ "deny.toml", ".cargo/deny.toml" }, { path = ctx.dirname, upward = true })[1] ~= nil
        end,
        cmd = "cargo",
        stdin = false,
        append_fname = false, -- the checks are positional args; the manifest goes via --manifest-path
        stream = "stderr",
        ignore_exitcode = true,
        args = {
          "deny",
          "--manifest-path",
          function()
            local f = vim.api.nvim_buf_get_name(0)
            return manifest_dir(f) .. "/Cargo.toml"
          end,
          "--offline",
          "--format",
          "json",
          "check",
          "advisories",
          "bans",
        },
        parser = function(output, bufnr)
          local file = vim.api.nvim_buf_get_name(bufnr)
          local is_lock = basename(file) == "Cargo.lock"
          local out = {}
          local failed -- one "cargo-deny failed" per run: a broken manifest logged it twice
          for line in vim.gsplit(output, "\n", { plain = true, trimempty = true }) do
            local ok, d = pcall(vim.json.decode, line)
            if not (ok and type(d) == "table") then -- also JSON `null` (vim.NIL is truthy)
              d = {}
            end
            local f = d.type == "diagnostic" and d.fields
            if d.type == "log" and type(d.fields) == "table" and d.fields.level == "ERROR" and not failed then
              failed = true
              -- a broken deny.toml, an unreachable crate source...: no
              -- diagnostics follow, which looked the same as a clean result
              out[#out + 1] = {
                lnum = 0,
                col = 0,
                severity = vim.diagnostic.severity.WARN,
                source = "cargo-deny",
                code = "deny-failed",
                message = "cargo-deny failed: " .. tostring(d.fields.message),
              }
            end
            if f and not (is_lock and f.code == "wildcard") then
              local label = f.labels and f.labels[1]
              local lnum, col = 0, 0
              -- `wildcard` (bans) labels the `dep = "*"` line of a Cargo.toml:
              -- skipped on the lockfile (not a Cargo.lock coordinate), and on
              -- the manifest the label gives the line (it used to land on
              -- line 1: the graph's crate is the package, not the dependency).
              local on_manifest = f.code == "wildcard" and label and label.line
              local krate = f.graphs and f.graphs[1] and f.graphs[1].Krate
              if is_lock then
                local at = krate and lock_line(bufnr, krate.name, krate.version)
                if at then
                  lnum = at
                elseif label then
                  lnum, col = (label.line or 1) - 1, (label.column or 1) - 1
                end
              elseif on_manifest then
                -- the label may belong to another manifest (a virtual workspace
                -- root has fewer lines than the member's): stay inside the buffer
                lnum = math.min(label.line - 1, math.max(vim.api.nvim_buf_line_count(bufnr) - 1, 0))
                col = (label.column or 1) - 1
              else
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
              -- several wildcard dependencies: one label (one line) each
              if on_manifest then
                for i = 2, #f.labels do
                  local l = f.labels[i]
                  if l.line then
                    local extra = vim.deepcopy(out[#out])
                    extra.lnum = math.min(l.line - 1, math.max(vim.api.nvim_buf_line_count(bufnr) - 1, 0))
                    extra.col = (l.column or 1) - 1
                    extra.message = f.message .. (l.message and (" - " .. l.message) or "")
                    out[#out + 1] = extra
                  end
                end
              end
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
        -- the directory is the argument: nvim-lint's default also appended
        -- the file name, which ran cargo-machete twice (every finding doubled)
        append_fname = false,
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
              -- relative to the scanned dir, or absolute when given an absolute dir
              local full = path:sub(1, 1) == "/" and path or (dir .. "/" .. path:gsub("^%./", ""))
              current = vim.fs.normalize(full) == file
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
