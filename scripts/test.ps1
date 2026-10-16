# Portable entry for the spec suite on Windows (PowerShell 5.1 or 7): runs
# scripts/test.lua with Neovim, no bash needed. Same options as scripts/test.sh
# (pattern..., --list, --timeout N, -v), except --coverage.
#   scripts\test.ps1 [options] [pattern...]
# Needs the plugins in place first (scripts\bootstrap.ps1).
$nvim = Get-Command nvim -ErrorAction SilentlyContinue
if (-not $nvim) {
  [Console]::Error.WriteLine('test.ps1: nvim not found')
  exit 2
}
$lua = Join-Path $PSScriptRoot 'test.lua'
& $nvim.Source --clean -l $lua @args
exit $LASTEXITCODE
