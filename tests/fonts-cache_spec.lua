-- fc-list (lua/config/ui.lua fonts_*, lua/xynovim/term.lua): never run on the main thread, answer cached in
-- stdpath("cache") and keyed on fontconfig's directories, so it is asked again only after fonts changed.
-- xyno-os: linux (a sh stub for fc-list)
local H = require("xynotest.helpers")
local ui = require("config.ui")

local function write(path, s)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end

describe("fonts cache", function()
  local saved, dir, log
  before_each(function()
    saved = { PATH = vim.env.PATH, HOME = vim.env.HOME, XDG_DATA_HOME = vim.env.XDG_DATA_HOME, XDG_CACHE_HOME = vim.env.XDG_CACHE_HOME }
    dir = H.tmpdir()
    log = dir .. "/calls"
    vim.env.HOME = dir .. "/home"
    vim.env.XDG_DATA_HOME, vim.env.XDG_CACHE_HOME = nil, nil
    vim.fn.mkdir(dir .. "/home/.local/share/fonts", "p")
    write(dir .. "/bin/fc-list", ("#!/bin/sh\necho x >> %s\nsleep ${FC_SLEEP:-0}\ncat %s/fonts.txt\n"):format(log, dir))
    vim.fn.system({ "chmod", "+x", dir .. "/bin/fc-list" })
    write(dir .. "/fonts.txt", "/usr/share/fonts/a.ttf: DejaVu Sans:style=Book\n/x/b.ttf: JetBrainsMono Nerd Font:style=Regular\n")
    vim.env.PATH = dir .. "/bin:" .. saved.PATH
    os.remove(vim.fs.joinpath(vim.fn.stdpath("cache"), "xynovim-fonts.json"))
  end)
  after_each(function()
    for k, v in pairs(saved) do
      vim.env[k] = v
    end
    os.remove(vim.fs.joinpath(vim.fn.stdpath("cache"), "xynovim-fonts.json"))
  end)

  local function calls()
    local ok, l = pcall(vim.fn.readfile, log)
    return ok and #l or 0
  end

  local function ask()
    local got, done
    ui.fonts_async(function(s)
      got, done = s, true
    end)
    H.wait_for(function()
      return done
    end, 5000, "fonts_async")
    return got
  end

  it("a slow fc-list does not block: the call returns at once and the callback comes later", function()
    vim.env.FC_SLEEP = "1"
    local t = vim.uv.hrtime()
    local got, done
    ui.fonts_async(function(s)
      got, done = s, true
    end)
    H.ok((vim.uv.hrtime() - t) / 1e6 < 100, "returned without waiting for fc-list")
    H.is_nil(done)
    H.wait_for(function()
      return done
    end, 6000)
    H.match(got, "Nerd Font", true)
    H.no_match(got, "DejaVu", true, "only the Nerd Font lines are kept")
    vim.env.FC_SLEEP = nil
  end)

  it("the second ask is answered from the cache file without running fc-list", function()
    ask()
    H.eq(1, calls())
    H.ok(vim.uv.fs_stat(vim.fs.joinpath(vim.fn.stdpath("cache"), "xynovim-fonts.json")), "cache file written")
    local t = vim.uv.hrtime()
    H.match(ask(), "Nerd Font", true)
    H.eq(1, calls())
    H.ok(ui.fonts_cached() ~= nil)
    H.ok((vim.uv.hrtime() - t) / 1e6 < 100)
  end)

  it("installing a font (the font directory's mtime changes) asks fc-list again", function()
    ask()
    write(dir .. "/fonts.txt", "/usr/share/fonts/a.ttf: DejaVu Sans:style=Book\n")
    vim.uv.fs_utime(dir .. "/home/.local/share/fonts", os.time() + 100, os.time() + 100)
    H.is_nil(ui.fonts_cached(), "stale entry is not served")
    H.eq("", ask())
    H.eq(2, calls())
    H.match(ui.font_hint(ui.fonts_cached()), "No Nerd Font found", true)
  end)

  it("font_hint without an argument never runs fc-list; font_hint_async answers", function()
    H.is_nil(ui.font_hint())
    H.eq(0, calls())
    write(dir .. "/fonts.txt", "/x/a.ttf: DejaVu Sans:style=Book\n")
    local hint, done
    ui.font_hint_async(function(h)
      hint, done = h, true
    end)
    H.wait_for(function()
      return done
    end, 5000)
    H.match(hint, "No Nerd Font found", true)
  end)

  it("two askers at once share one fc-list run", function()
    vim.env.FC_SLEEP = "0.3"
    local n = 0
    ui.fonts_async(function() n = n + 1 end)
    ui.fonts_async(function() n = n + 1 end)
    H.wait_for(function()
      return n == 2
    end, 5000)
    H.eq(1, calls())
    vim.env.FC_SLEEP = nil
  end)

  it("no fc-list and a failing fc-list give nil (no hint), not an error", function()
    write(dir .. "/bin/fc-list", "#!/bin/sh\nexit 2\n")
    H.is_nil(ask())
    vim.env.PATH = "/nonexistent"
    H.is_nil(ask())
  end)

  it("term.collect runs its commands without a blocking :wait()", function()
    local src = table.concat(vim.fn.readfile(H.repo .. "/lua/xynovim/term.lua"), "\n") .. table.concat(vim.fn.readfile(H.repo .. "/lua/config/ui.lua"), "\n")
    H.no_match(src, ":wait(3000)", true)
  end)
end)
