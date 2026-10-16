# Bootstrap this config on a fresh Windows machine (PowerShell 5.1 or 7) so the
# plugins end up on exactly the commits in lazy-lock.json. The same three steps
# as scripts/bootstrap.sh (read its header for why there are two install rounds):
#   1. `Lazy! install` clones everything (the lockfile is rewritten, ignored);
#   2. the original lockfile is put back, then `Lazy! restore`;
#   3. scripts/provision.lua downloads the treesitter parsers and Mason tools.
# lazy-lock.json is left exactly as it was; the script fails if it is not.
#
# Usage: scripts\bootstrap.ps1          (config = the checkout this lives in)
# Env:   XDG_CONFIG_HOME / XDG_DATA_HOME are honoured, else Neovim's Windows
#        defaults (%LOCALAPPDATA%\nvim and \nvim-data).
#        BOOTSTRAP_SKIP_PREREQS=1 skips the prerequisite check.
# Not run through winget/scoop for you: it prints what is missing and how to
# install it. Compare with bootstrap.sh: no unzip/gzip here (Mason uses
# PowerShell and tar on Windows).
$ErrorActionPreference = 'Continue'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$lock = Join-Path $repo 'lazy-lock.json'

# nvim reads the config from $XDG_CONFIG_HOME\nvim, else %LOCALAPPDATA%\nvim.
if ($env:XDG_CONFIG_HOME) { $cfgRoot = $env:XDG_CONFIG_HOME } else { $cfgRoot = $env:LOCALAPPDATA }
$cfg = Join-Path $cfgRoot 'nvim'

function Get-RealPath([string]$p) {
  $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  if (-not $item) { return $null }
  if ($item.Target) { return (Resolve-Path -LiteralPath ($item.Target | Select-Object -First 1)).Path.TrimEnd('\') }
  return $item.FullName.TrimEnd('\')
}

if (-not (Test-Path -LiteralPath $cfg)) {
  New-Item -ItemType Directory -Force -Path $cfgRoot | Out-Null
  # a junction needs no administrator rights (a symlink does)
  & cmd.exe /c mklink /J "$cfg" "$repo" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Error "bootstrap: could not create the junction $cfg -> $repo"
    exit 1
  }
  Write-Host "bootstrap: linked $cfg -> $repo"
}
$real = Get-RealPath $cfg
if ($real -ne $repo.TrimEnd('\')) {
  [Console]::Error.WriteLine("bootstrap: $cfg is not this checkout ($repo).")
  [Console]::Error.WriteLine("  link it first:  cmd /c mklink /J `"$cfg`" `"$repo`"   (move the existing directory away first)")
  exit 1
}

# Prerequisites: tool, how to install it.
if ($env:BOOTSTRAP_SKIP_PREREQS -ne '1') {
  $missing = @()
  $needs = [ordered]@{
    'nvim'     = 'winget install Neovim.Neovim   (or scoop install neovim)'
    'git'      = 'winget install Git.Git   (or scoop install git)'
    'curl'     = 'curl.exe ships with Windows 10 and later'
    'tar'      = 'tar.exe (bsdtar) ships with Windows 10 and later'
    'node'     = 'winget install OpenJS.NodeJS.LTS   (or scoop install nodejs-lts)'
    'npm'      = 'comes with Node.js'
    'cargo'    = 'winget install Rustlang.Rustup   (or https://rustup.rs)'
    'rustup'   = 'winget install Rustlang.Rustup   (or https://rustup.rs)'
  }
  foreach ($tool in $needs.Keys) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $missing += "$tool  ->  $($needs[$tool])" }
  }
  # tree-sitter parsers are compiled: any C compiler nvim-treesitter knows will do
  $cc = $false
  foreach ($c in 'gcc', 'cc', 'clang', 'cl', 'zig') { if (Get-Command $c -ErrorAction SilentlyContinue) { $cc = $true; break } }
  if (-not $cc) { $missing += 'a C compiler (gcc, clang, cl or zig)  ->  winget install zig.zig   (or scoop install gcc; or Visual Studio Build Tools)' }
  # rustup ships a rust-analyzer proxy even when the component is absent
  $ra = Get-Command rust-analyzer -ErrorAction SilentlyContinue
  if (-not $ra) {
    $missing += 'rust-analyzer  ->  rustup component add rust-analyzer'
  } else {
    & rust-analyzer --version *> $null
    if ($LASTEXITCODE -ne 0) { $missing += 'rust-analyzer (installed as a rustup proxy only)  ->  rustup component add rust-analyzer' }
  }
  if ($missing.Count -gt 0) {
    [Console]::Error.WriteLine('bootstrap: missing prerequisites:')
    foreach ($m in $missing) { [Console]::Error.WriteLine("  - $m") }
    [Console]::Error.WriteLine('Install them (or set BOOTSTRAP_SKIP_PREREQS=1 to go on anyway) and rerun.')
    exit 1
  }
}

$orig = [IO.Path]::GetTempFileName()
try {
  Copy-Item -LiteralPath $lock -Destination $orig -Force
  $origHash = (Get-FileHash -LiteralPath $orig -Algorithm SHA256).Hash

  Write-Host 'bootstrap: step 1/3, Lazy! install'
  & nvim --headless '+Lazy! install' +qa
  if ($LASTEXITCODE -ne 0) { Write-Error "bootstrap: Lazy! install failed (exit $LASTEXITCODE)"; exit 1 }
  Copy-Item -LiteralPath $orig -Destination $lock -Force

  Write-Host 'bootstrap: step 2/3, Lazy! restore'
  & nvim --headless '+Lazy! restore' +qa
  if ($LASTEXITCODE -ne 0) { Write-Error "bootstrap: Lazy! restore failed (exit $LASTEXITCODE)"; exit 1 }

  Write-Host 'bootstrap: step 3/3, treesitter parsers and Mason tools (LazyVim downloads them lazily on a first start)'
  $prov = (Join-Path $repo 'scripts\provision.lua') -replace '\\', '/'
  & nvim --headless "+luafile $prov" +qa
  if ($LASTEXITCODE -ne 0) { Write-Error "bootstrap: provision.lua failed (exit $LASTEXITCODE)"; exit 1 }

  # compared by hash of the bytes: core.autocrlf=true can rewrite the line endings of the checkout
  if ((Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash -eq $origHash) {
    Write-Host 'bootstrap: done, lazy-lock.json unchanged.'
  } else {
    [Console]::Error.WriteLine('bootstrap: lazy-lock.json changed during restore (some plugin is not on its pinned commit).')
    Copy-Item -LiteralPath $orig -Destination $lock -Force
    exit 1
  }
} finally {
  Remove-Item -LiteralPath $orig -Force -ErrorAction SilentlyContinue
}
