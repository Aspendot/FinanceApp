<#
Installs the privacy guard for this clone and all of its worktrees.

It copies guard.py, gitleaks.toml and the hooks to a folder outside the repo, so an
edit inside a working tree can't weaken the installed copy, and points git at them.
Run it again after changing anything in tools/privacy.

  powershell -ExecutionPolicy Bypass -File tools/privacy/install.ps1 -Denylist <path>
#>
param(
    [Parameter(Mandatory = $true)][string]$Denylist,
    [string]$Target = (Join-Path $env:LOCALAPPDATA 'FinanceAppGuard')
)
$ErrorActionPreference = 'Stop'

$src = $PSScriptRoot
$repo = (git -C $src rev-parse --show-toplevel).Trim() -replace '/', '\'
if (-not (Test-Path -LiteralPath $Denylist -PathType Leaf)) { throw 'Denylist file not found.' }
$deny = (Resolve-Path -LiteralPath $Denylist).Path
if ($deny.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The denylist must live outside the repo.' }
if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) { throw 'gitleaks is not on PATH.' }

$hooks = Join-Path $Target 'hooks'
New-Item -ItemType Directory -Force $hooks | Out-Null
Copy-Item -LiteralPath (Join-Path $src 'guard.py'), (Join-Path $src 'gitleaks.toml') -Destination $Target -Force
Copy-Item -Path (Join-Path $src 'hooks\*') -Destination $hooks -Force

git -C $repo config privacy.denylist ($deny -replace '\\', '/')
if ($LASTEXITCODE -ne 0) { throw 'Could not configure the privacy denylist.' }
git -C $repo config core.hooksPath ($hooks -replace '\\', '/')
if ($LASTEXITCODE -ne 0) { throw 'Could not configure the Git hooks path.' }
Write-Output 'Privacy guard installed for this clone.'
