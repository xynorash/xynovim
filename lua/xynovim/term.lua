-- Terminal compatibility for :checkhealth xynovim (docs/comparison/ui-community.md item 5): truecolor,
-- curly/coloured underlines (tmux needs overrides), and what Ghostty, WezTerm and kitty need.
-- `diagnose` is pure: every input comes through `env`, so the specs can feed any terminal.
local M = {}

--- @class xynovim.TermEnv
--- @field vars table<string,string>   environment variables
--- @field infocmp? string             `infocmp -x $TERM` output (nil: not available)
--- @field tmux? string                `tmux show-options -s` + `-g` output (only inside tmux)
--- @field ghostty_config? string      the user's Ghostty config text
--- @field fonts? string               `fc-list` output

--- @param env xynovim.TermEnv
--- @return { level: "ok"|"warn"|"info", msg: string, fix?: string|string[] }[]
function M.diagnose(env)
  local v = env.vars
  local out = {}
  local function add(level, msg, fix)
    out[#out + 1] = { level = level, msg = msg, fix = fix }
  end
  local term = v.TERM or ""
  local in_tmux = (v.TMUX or "") ~= ""
  local program = (v.TERM_PROGRAM or ""):lower()
  local kind
  if v.GHOSTTY_RESOURCES_DIR or term == "xterm-ghostty" or program == "ghostty" then
    kind = "Ghostty"
  elseif v.WEZTERM_EXECUTABLE or program == "wezterm" then
    kind = "WezTerm"
  elseif v.KITTY_WINDOW_ID or term == "xterm-kitty" then
    kind = "kitty"
  elseif v.WT_SESSION then
    kind = "Windows Terminal"
  end
  -- inside tmux the outer terminal is hidden behind TERM=tmux-256color/screen; the env of the
  -- attached client usually still carries it
  add(
    "info",
    ("terminal: TERM=%s%s%s"):format(
      term == "" and "(unset)" or term,
      kind and (", " .. kind) or "",
      in_tmux and ", inside tmux" or ""
    )
  )

  if term == "linux" or term == "dumb" then
    add(
      "warn",
      "TERM=" .. term .. " cannot draw Nerd Font glyphs, truecolor or curly underlines",
      "use :XynoIcons ascii (icons are chosen automatically here), and a graphical terminal for the full theme"
    )
  end

  -- truecolor
  local colorterm = (v.COLORTERM or ""):lower()
  local rgb = colorterm == "truecolor" or colorterm == "24bit"
  local info = env.infocmp or ""
  local info_rgb = info:find("[%s,]RGB[,%s]")
    or info:find("[%s,]Tc[,%s]")
    or info:find("colors#0x1000000", 1, true)
    or info:find("colors#16777216", 1, true)
  local tmux = env.tmux or ""
  local tmux_rgb = tmux:find("RGB", 1, true) or tmux:find("[,:]Tc") or tmux:find("truecolor", 1, true)
  if in_tmux then
    if tmux_rgb or info_rgb then
      add("ok", "truecolor: tmux passes 24-bit colour (RGB / Tc set)")
    else
      add(
        "warn",
        "truecolor: tmux is not told the outer terminal does 24-bit colour; the Island Dark colours fall back to 256",
        {
          "set -as terminal-features ',*:RGB'     # tmux >= 3.2, in ~/.tmux.conf",
          "set -ga terminal-overrides ',*:Tc'     # older tmux",
        }
      )
    end
  elseif rgb or info_rgb then
    add("ok", "truecolor: " .. (rgb and ("COLORTERM=" .. colorterm) or "terminfo advertises RGB"))
  else
    add(
      "warn",
      "truecolor: COLORTERM is not truecolor/24bit; the Island Dark colours may be approximated to 256",
      "export COLORTERM=truecolor (most terminals support it; check the terminal's docs)"
    )
  end

  -- curly and coloured underlines (diagnostics: undercurl for errors, dashed / dotted for the rest)
  local smulx = info:find("Smulx", 1, true) ~= nil
  local setulc = info:find("Setulc", 1, true) ~= nil
  local t_smulx = tmux:find("Smulx", 1, true) ~= nil or tmux:find("usstyle", 1, true) ~= nil
  local t_setulc = tmux:find("Setulc", 1, true) ~= nil or tmux:find("usstyle", 1, true) ~= nil
  local curly, coloured
  if in_tmux then
    curly, coloured = t_smulx, t_setulc
  else
    curly, coloured = smulx, setulc
  end
  if curly and coloured then
    add("ok", "underlines: curly and coloured underlines are available (Smulx, Setulc)")
  else
    local fix
    if in_tmux then
      fix = {
        "set -as terminal-features ',*:usstyle'                # tmux >= 3.4: curly, dashed, dotted + colour",
        "# older tmux, in ~/.tmux.conf:",
        "set -as terminal-overrides ',*:Smulx=\\E[4::%p1%dm'",
        "set -as terminal-overrides ',*:Setulc=\\E[58::2::%p1%{65536}%/%d::%p1%{256}%/%{255}%&%d::%p1%{255}%&%d%;m'",
      }
    else
      fix =
        "use a terminal whose terminfo has Smulx and Setulc (Ghostty, kitty, WezTerm, foot, Alacritty >= 0.12); Neovim falls back to a plain underline, severity is still shown by glyph and colour"
    end
    add(
      "warn",
      ("underlines: %s%s; error/warning squiggles become plain underlines (the diagnostic glyphs still differ)"):format(
        curly and "" or "no curly underline (Smulx)",
        coloured and "" or (curly and "" or " and ") .. (coloured and "" or "no coloured underline (Setulc)")
      ),
      fix
    )
  end

  -- terminal-specific notes
  if kind == "Ghostty" then
    local mc = tonumber((env.ghostty_config or ""):match("\n?%s*minimum%-contrast%s*=%s*([%d%.]+)"))
    if mc and mc > 1 then
      add(
        "warn",
        ("Ghostty: minimum-contrast = %s re-colours text below that WCAG ratio, so dim hints, comments and the high-contrast tones can differ from the theme"):format(
          mc
        ),
        "set minimum-contrast = 1 (the default) in the Ghostty config to see the theme's own colours"
      )
    else
      add(
        "ok",
        "Ghostty: minimum-contrast is " .. (mc and "1" or "unset (1)") .. ": the theme's colours are shown as defined"
      )
    end
  elseif kind == "WezTerm" then
    add(
      "info",
      "WezTerm: curly underlines work with its bundled terminfo (`tempfile=$(mktemp) && curl -o $tempfile https://raw.githubusercontent.com/wezterm/wezterm/main/termwiz/data/wezterm.terminfo && tic -x -o ~/.terminfo $tempfile`, then TERM=wezterm); nothing else to set"
    )
  elseif kind == "kitty" then
    add("info", "kitty: full support (undercurl, coloured underlines, truecolor); nothing to set")
  end

  -- icons
  local ui = require("config.ui")
  local mode = ui.icon_mode({ icons = v.XYNOVIM_ICONS, term = v.TERM, lang = v.LC_ALL or v.LC_CTYPE or v.LANG })
  if mode == "ascii" then
    add("info", "icons: plain text mode (no Nerd Font needed)")
  else
    local hint = ui.font_hint(env.fonts or "")
    if env.fonts and hint then
      add("warn", "icons: " .. hint)
    elseif not env.fonts then
      add("info", "icons: Nerd Font glyphs; if they show as boxes, :XynoIcons ascii switches to plain text")
    else
      add(
        "ok",
        "icons: a Nerd Font is installed on this system; the terminal must use it (:XynoIcons ascii for plain text)"
      )
    end
  end
  return out
end

--- Run the commands at the same time without blocking the editor's main thread on any single one:
--- each has its own 3 s allowance, the wait is for the slowest (not the sum). Returns stdout (nil on failure).
local function run_all(cmds)
  local out, pending = {}, 0
  for i, cmd in ipairs(cmds) do
    pending = pending + 1
    local ok = pcall(vim.system, cmd, { text = true, timeout = 3000 }, function(o)
      out[i] = o.code == 0 and o.stdout or nil
      pending = pending - 1
    end)
    if not ok then
      pending = pending - 1
    end
  end
  vim.wait(3500, function()
    return pending <= 0
  end, 5)
  return out
end

--- The real environment.
--- @return xynovim.TermEnv
function M.collect()
  local vars = {}
  for _, k in ipairs({
    "TERM",
    "COLORTERM",
    "TMUX",
    "TERM_PROGRAM",
    "GHOSTTY_RESOURCES_DIR",
    "WEZTERM_EXECUTABLE",
    "KITTY_WINDOW_ID",
    "WT_SESSION",
    "XYNOVIM_ICONS",
    "LC_ALL",
    "LC_CTYPE",
    "LANG",
  }) do
    vars[k] = vim.env[k]
  end
  local env = { vars = vars }
  local cmds, want = {}, {}
  if vim.fn.executable("infocmp") == 1 and vars.TERM then
    cmds[#cmds + 1] = { "infocmp", "-x", vars.TERM }
    want.infocmp = #cmds
  end
  if (vars.TMUX or "") ~= "" and vim.fn.executable("tmux") == 1 then
    cmds[#cmds + 1] = { "tmux", "show-options", "-s" }
    want.tmux_s = #cmds
    cmds[#cmds + 1] = { "tmux", "show-options", "-g" }
    want.tmux_g = #cmds
  end
  local outs = run_all(cmds)
  env.infocmp = want.infocmp and outs[want.infocmp] or nil
  if want.tmux_s then
    env.tmux = (outs[want.tmux_s] or "") .. (outs[want.tmux_g] or "")
  end
  local cfg =
    vim.fs.joinpath(vim.env.XDG_CONFIG_HOME or vim.fs.joinpath(vim.env.HOME or "", ".config"), "ghostty", "config")
  local f = io.open(cfg, "r")
  if f then
    env.ghostty_config = "\n" .. f:read("*a")
    f:close()
  end
  if vim.fn.executable("fc-list") == 1 then
    env.fonts = require("config.ui").fonts_wait(3000) -- background fc-list + cache (stdpath("cache")), not a blocking run
  end
  return env
end

function M.report()
  vim.health.start("xynovim: terminal")
  for _, r in ipairs(M.diagnose(M.collect())) do
    local fn = vim.health[r.level]
    if r.fix then
      fn(r.msg, r.fix)
    else
      fn(r.msg)
    end
  end
end

return M
