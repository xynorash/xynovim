-- lua/config/rust_assist.lua organize_on_save: the per-buffer "organizing" flag always comes off, whether
-- xyno-imports calls back, raises, never answers or the buffer goes away. (The happy path is covered by
-- rust-ide-features_spec.lua with a real rust-analyzer; here a stub engine stands in.)
local H = require("xynotest.helpers")
local ra = require("config.rust_assist")

describe("organize_on_save flag", function()
  local real_engine, real_notify, notes, buf
  before_each(function()
    real_engine = package.loaded["xyno_imports.engine"]
    real_notify = vim.notify
    notes = {}
    vim.notify = function(m)
      notes[#notes + 1] = m
    end
    vim.g.xynovim_organize_on_save = true
    vim.cmd("enew")
    buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "nofile"
  end)
  after_each(function()
    package.loaded["xyno_imports.engine"] = real_engine
    vim.notify = real_notify
    vim.g.xynovim_organize_on_save = nil
    ra.organize_timeout_ms = 20000
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("an engine that raises clears the flag, says so, and the next save organizes again", function()
    local calls = 0
    package.loaded["xyno_imports.engine"] = {
      organize = function()
        calls = calls + 1
        error("boom")
      end,
    }
    ra.organize_on_save(buf)
    H.is_nil(vim.b[buf].xynovim_organizing)
    H.match(table.concat(notes, "\n"), "boom", true)
    ra.organize_on_save(buf)
    H.eq(2, calls, "not stuck behind the flag")
  end)

  it("an engine that never calls back is released after the timeout, and a late callback writes nothing", function()
    ra.organize_timeout_ms = 60
    local late, calls = nil, 0
    package.loaded["xyno_imports.engine"] = {
      organize = function(_, cb)
        calls = calls + 1
        late = cb
      end,
    }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x" })
    ra.organize_on_save(buf)
    H.eq(true, vim.b[buf].xynovim_organizing)
    ra.organize_on_save(buf)
    H.eq(1, calls, "a second save while one is running does not start another")
    H.wait_for(function()
      return vim.b[buf].xynovim_organizing == nil
    end, 2000, "flag released by the timeout")
    local wrote = false
    vim.api.nvim_create_autocmd("BufWritePre", { buffer = buf, once = true, callback = function() wrote = true end })
    late(1)
    H.eq(false, wrote, "late callback ignored")
    ra.organize_on_save(buf)
    H.eq(2, calls)
  end)

  it("a callback that arrives normally clears the flag before anything else", function()
    package.loaded["xyno_imports.engine"] = {
      organize = function(_, cb)
        vim.schedule(function()
          cb(0)
        end)
      end,
    }
    ra.organize_on_save(buf)
    H.eq(true, vim.b[buf].xynovim_organizing)
    H.wait_for(function()
      return vim.b[buf].xynovim_organizing == nil
    end, 2000)
  end)

  it("deleting the buffer while organizing is harmless (no error, no timer fires on a dead buffer)", function()
    ra.organize_timeout_ms = 50
    local cb_saved
    package.loaded["xyno_imports.engine"] = {
      organize = function(_, cb)
        cb_saved = cb
      end,
    }
    ra.organize_on_save(buf)
    vim.cmd("enew")
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.wait(150)
    local ok, err = pcall(cb_saved, 1)
    H.ok(ok, tostring(err))
  end)
end)
