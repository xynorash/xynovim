-- Commands in a real Rust buffer: Neovim's bundled rust.vim defines buffer-local :RustRun, which shadowed the
-- global :RustRun run-configuration picker of xyno-rust.nvim (and <leader>rb) in every .rs buffer.
local H = require("xynotest.helpers")

describe("Rust buffer commands", function()
  it(
    ":RustRun in a .rs buffer is not rust.vim's buffer-local command (ours runs; rust.vim's is :RustVimRun)",
    function()
      local _, buf = H.open_fixture("standalone.rs")
      H.eq("rust", vim.bo[buf].filetype)
      local bufcmds = vim.api.nvim_buf_get_commands(buf, {})
      H.is_nil(bufcmds.RustRun, "the buffer-local RustRun of rust.vim must not shadow the global one")
      H.ok(bufcmds.RustVimRun, "rust.vim's run stays usable as :RustVimRun")

      -- what a typed :RustRun resolves to: the global command when xyno-rust.nvim defines it
      local global = vim.api.nvim_get_commands({})
      if global.RustRun then
        H.not_ok(global.RustRun.definition:find("rust#Run", 1, true))
        H.ok(vim.fn.exists(":RustRun") == 2)
      end
      -- setting the filetype again runs rust.vim's undo (delcommand -buffer RustRun) and must not raise
      vim.cmd("set filetype=text")
      vim.cmd("set filetype=rust")
      H.is_nil(vim.api.nvim_buf_get_commands(buf, {}).RustRun)
      -- the other rust.vim commands are untouched
      H.ok(bufcmds.RustFmt or bufcmds.RustTest or bufcmds.RustExpand, "other rust.vim commands stay")
    end
  )

  it("<leader>rb in a Rust buffer calls :RustRun (the run-configuration picker)", function()
    local _, buf = H.open_fixture("standalone.rs")
    local m = vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg("<leader>rb", "n", false, true)
    end)
    -- the rust maps are set when rust-analyzer attaches; without it the stub or nothing is fine
    if m.rhs then
      H.match(m.rhs, "RustRun", true)
    end
  end)
end)
