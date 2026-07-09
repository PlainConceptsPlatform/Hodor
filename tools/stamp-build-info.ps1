# tools/stamp-build-info.ps1
# Computes the full Hodor version from git and writes build-info.json.
# Shared by install-local.ps1 (local) and the CI packaging workflow (future).
#
# Full version = "<base>.<commitCount>+g<shortSha>"   e.g. 1.2.42+gabc1234
#   base        = MAJOR.MINOR from the VERSION file
#   commitCount = git rev-list --count HEAD   (patch bumps automatically per commit)
#   shortSha    = git rev-parse --short HEAD
#
# Usage:
#   tools/stamp-build-info.ps1 [-SourceRoot <repo>] [-OutFile <path\build-info.json>]
# Defaults: SourceRoot = repo root (parent of this tools/ dir); OutFile = <SourceRoot>\build-info.json
param(
    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
if (-not $OutFile) { $OutFile = Join-Path $SourceRoot 'build-info.json' }

$base = '0.0'
$versionFile = Join-Path $SourceRoot 'VERSION'
if (Test-Path $versionFile) {
    $line = (Get-Content $versionFile -Encoding UTF8 | Select-Object -First 1)
    if ($line) { $base = $line.Trim() }
}

$commit = 'unknown'
$commitCount = 0
try {
    $sha = (& git -C $SourceRoot rev-parse --short HEAD 2>$null)
    $cnt = (& git -C $SourceRoot rev-list --count HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $sha) {
        $commit = "$sha".Trim()
        if ($cnt) { $commitCount = [int]("$cnt".Trim()) }
    }
} catch { }

$version = if ($commit -eq 'unknown') { "$base.0+gunknown" } else { "$base.$commitCount+g$commit" }

$info = [ordered]@{
    version     = $version
    base        = $base
    commit      = $commit
    commitCount = $commitCount
    buildDate   = (Get-Date).ToUniversalTime().ToString('o')
}
($info | ConvertTo-Json -Compress) | Set-Content -Path $OutFile -Encoding UTF8
Write-Host "[OK] build-info.json -> $OutFile  ($version)"
