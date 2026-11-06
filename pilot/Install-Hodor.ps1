# Install-Hodor.ps1 - One-step install of the Hodor pilot (AI hooks).
#
# Usage (PowerShell, no admin rights needed). The script clones the repo itself, so this is the only step:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/PlainConceptsPlatform/Hodor/main/pilot/Install-Hodor.ps1)))"
# or, with the file downloaded / from a clone:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Hodor.ps1 [-Token <TOKEN>]
# Hodor itself is always installed from a git clone (never a zip: the version is stamped from git).
#
# What it does:
#   1. Checks prerequisites (Git) and asks for the ingest token
#   2. Clones the repo into %USERPROFILE%\Hodor (or git-pulls it if already there / if run from a clone)
#   3. Resolves your corporate UPN (whoami /upn) as identity
#   4. Runs install-local.ps1 with the Atlas endpoint and the token
#   5. Enables chat.useHooks in VS Code (if installed)
#   6. Runs the selftest to check telemetry gets through
param(
    [string]$Token,
    [string]$Email,
    [string]$RepoDir = (Join-Path $env:USERPROFILE 'Hodor')
)

# --- Pilot configuration --------------------------------------------------------
$RepoUrl      = 'https://github.com/PlainConceptsPlatform/Hodor.git'
$OtelEndpoint = 'https://atlas-api.plainconcepts.com/api/v1/ai-hooks'
$DefaultToken = ''   # optional: fill in before handing out the script so it does not ask for the token
$InstallDir   = Join-Path $env:LOCALAPPDATA 'PlainConcepts\ai-hooks'
# -------------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
function Step($n, $msg) { Write-Host ""; Write-Host "[$n/6] $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [!]  $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "  [X]  $msg" -ForegroundColor Red; exit 1 }

Write-Host "== Hodor pilot installation ==" -ForegroundColor White

# 1. Prerequisites ----------------------------------------------------------------
Step 1 "Checking prerequisites"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail "Git is not installed or not on the PATH. Install it (https://git-scm.com/download/win) and run this again."
}
Ok "Git found"

if (-not $Token) { $Token = $DefaultToken }
if (-not $Token -and $env:HODOR_TOKEN) { $Token = $env:HODOR_TOKEN }
if (-not $Token) { $Token = Read-Host "  Paste the Atlas token (without 'Bearer')" }
$Token = ($Token -replace '^\s*Bearer\s+', '').Trim()
if (-not $Token) { Fail "No token provided." }
Ok "Token received"

# 2. Repo -------------------------------------------------------------------------
# Run from a clone (pilot\Install-Hodor.ps1)? Use that clone unless -RepoDir was given.
# ($PSScriptRoot is empty when the script runs straight from the web via irm.)
$selfRepo = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { '' }
if ($selfRepo -and -not $PSBoundParameters.ContainsKey('RepoDir') -and (Test-Path (Join-Path $selfRepo '.git')) -and (Test-Path (Join-Path $selfRepo 'install-local.ps1'))) {
    $RepoDir = $selfRepo
}
Step 2 "Getting Hodor into $RepoDir"
if (Test-Path (Join-Path $RepoDir '.git')) {
    & git -C $RepoDir pull --ff-only
    if ($LASTEXITCODE -ne 0) { Warn "Could not update $RepoDir (git pull); installing the local copy as is." }
    else { Ok "Repo updated" }
} elseif (Test-Path $RepoDir) {
    Fail "$RepoDir already exists and is not a git repo. Delete it or pass -RepoDir <another folder>."
} else {
    & git clone $RepoUrl $RepoDir
    if ($LASTEXITCODE -ne 0) { Fail "Could not clone $RepoUrl" }
    Ok "Repo cloned"
}

# 3. Identity (UPN) ---------------------------------------------------------------
Step 3 "Resolving your corporate identity"
if (-not $Email) {
    # Full path: with Git for Windows on the PATH, 'whoami' may be Git's, which does not accept /upn
    $whoami = Join-Path $env:WINDIR 'System32\whoami.exe'
    try { $Email = ("" + (& $whoami /upn 2>$null)).Trim() } catch { $Email = '' }
}
if ($Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    Warn "Could not resolve your UPN automatically."
    $Email = (Read-Host "  Type your corporate email (@plainconcepts.com)").Trim()
}
if ($Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { Fail "Invalid email: '$Email'" }
if ($Email -notmatch '@plainconcepts\.com$') { Warn "Identity '$Email' is not @plainconcepts.com. Make sure it is your corporate account." }
Ok "Identity: $Email"

# 4. Install ----------------------------------------------------------------------
Step 4 "Installing hooks into $InstallDir"
$installer = Join-Path $RepoDir 'install-local.ps1'
if (-not (Test-Path $installer)) { Fail "$installer not found" }
& powershell -NoProfile -ExecutionPolicy Bypass -File $installer `
    -Dest $InstallDir `
    -OtelEndpoint $OtelEndpoint `
    -OtelToken $Token `
    -IdentityEmail $Email
if ($LASTEXITCODE -ne 0) { Fail "The installer failed (exit $LASTEXITCODE). Check the output above." }
Ok "Hooks installed for Claude Code and Copilot"

# 5. VS Code: chat.useHooks -------------------------------------------------------
Step 5 "Enabling chat.useHooks in VS Code"
$vsDir = Join-Path $env:APPDATA 'Code\User'
$vsSettings = Join-Path $vsDir 'settings.json'
if (-not (Test-Path $vsDir)) {
    Warn "VS Code does not seem to be installed for this user. Skipped."
} else {
    $done = $false
    try {
        if (Test-Path $vsSettings) {
            $raw = Get-Content $vsSettings -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '{}' }
            $obj = $raw | ConvertFrom-Json   # fails if the file has comments or trailing commas (JSONC)
        } else {
            $obj = [pscustomobject]@{}
        }
        if ($obj.PSObject.Properties['chat.useHooks'] -and $obj.'chat.useHooks' -eq $true) {
            Ok "Already enabled"
        } else {
            if (Test-Path $vsSettings) { Copy-Item $vsSettings "$vsSettings.hodor.bak" -Force }
            $obj | Add-Member -NotePropertyName 'chat.useHooks' -NotePropertyValue $true -Force
            [System.IO.File]::WriteAllText($vsSettings, ($obj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
            Ok "Enabled (backup: settings.json.hodor.bak)"
        }
        $done = $true
    } catch { }
    if (-not $done) {
        Warn "Your VS Code settings.json has comments or non-standard formatting; leaving it untouched."
        Warn "Enable it by hand: Settings > search 'chat.useHooks' > tick it."
    }
}

# 6. Selftest ---------------------------------------------------------------------
Step 6 "Checking telemetry delivery (selftest)"
$dispatch = Join-Path $InstallDir 'dispatch.ps1'
$out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $dispatch -Event selftest 2>&1 | Out-String).Trim()
$selftestOk = ($LASTEXITCODE -eq 0) -and ($out -match '"ok"\s*:\s*true')
if ($selftestOk) {
    Ok "Telemetry reaches Atlas"
} else {
    Warn "The selftest failed. Send this output to whoever gave you this script:"
    Write-Host $out
}

# Summary -------------------------------------------------------------------------
Write-Host ""
Write-Host "== Done ==" -ForegroundColor Green
Write-Host "Next steps:"
Write-Host "  1. Close and reopen Claude Code."
Write-Host "  2. In VS Code: Ctrl+Shift+P > 'Developer: Reload Window'."
Write-Host "  3. Run the test battery:"
Write-Host "     https://github.com/PlainConceptsPlatform/Hodor/blob/main/docs/manual-test-battery.md"
Write-Host ""
Write-Host "Diagnostics if something goes wrong:"
Write-Host ('  powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $InstallDir 'tools\hodor-version.ps1') + '"')
if (-not $selftestOk) { exit 2 }
