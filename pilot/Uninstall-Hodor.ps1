# Uninstall-Hodor.ps1 - Uninstalls the Hodor pilot (AI hooks).
#
# Usage (PowerShell, no admin rights needed). Close Claude Code and VS Code first:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-Hodor.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-Hodor.ps1 -KeepRepo -KeepLogs
#
# What it does:
#   1. Stops Hodor background processes (telemetry sending)
#   2. Removes Hodor's hooks from ~/.claude/settings.json (other hooks and settings are kept)
#   3. Removes the Copilot hook (~/.copilot/hooks/company-hooks.json)
#   4. Deletes the install (%LOCALAPPDATA%\PlainConcepts\ai-hooks) and, by default, the repo copy
#   5. Turns chat.useHooks in VS Code back off if Install-Hodor.ps1 enabled it
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'PlainConcepts\ai-hooks'),
    [string]$RepoDir    = (Join-Path $env:USERPROFILE 'Hodor'),
    [switch]$KeepRepo,   # do not delete %USERPROFILE%\Hodor
    [switch]$KeepLogs    # zip the logs to the Desktop before deleting
)

$ErrorActionPreference = 'Stop'
$script:problems = 0
# Run from a clone (pilot\Uninstall-Hodor.ps1)? That clone is the repo to remove unless -RepoDir was given.
$selfRepo = Split-Path $PSScriptRoot -Parent
if (-not $PSBoundParameters.ContainsKey('RepoDir') -and (Test-Path (Join-Path $selfRepo 'install-local.ps1'))) { $RepoDir = $selfRepo }
# Do not keep the repo folder busy as the current directory (it could not be deleted)
Set-Location $env:USERPROFILE
function Step($n, $msg) { Write-Host ""; Write-Host "[$n/5] $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Info($msg) { Write-Host "  [-]  $msg" -ForegroundColor DarkGray }
function Warn($msg) { Write-Host "  [!]  $msg" -ForegroundColor Yellow; $script:problems++ }
function Save-Json($path, $obj) {
    [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
}
# Matches any Hodor install (LOCALAPPDATA or ProgramData)
$HodorPattern = 'PlainConcepts\\ai-hooks\\dispatch\.ps1'

Write-Host "== Hodor uninstall ==" -ForegroundColor White
Write-Host "Recommended: close Claude Code and VS Code before continuing." -ForegroundColor DarkGray

# 1. Background processes ----------------------------------------------------------
Step 1 "Stopping Hodor background processes"
$procs = @()
try {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $HodorPattern -and $_.ProcessId -ne $PID })
} catch { }
foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { } }
if ($procs.Count) { Ok "$($procs.Count) process(es) stopped" } else { Info "No processes running" }

# 2. Claude Code -------------------------------------------------------------------
Step 2 "Removing Claude Code hooks"
$claudeSettings = Join-Path $env:USERPROFILE '.claude\settings.json'
if (-not (Test-Path $claudeSettings)) {
    Info "$claudeSettings does not exist"
} else {
    try {
        $settings = Get-Content $claudeSettings -Raw -Encoding UTF8 | ConvertFrom-Json
        $removed = 0
        if ($settings.PSObject.Properties['hooks'] -and $settings.hooks) {
            foreach ($ev in @($settings.hooks.PSObject.Properties.Name)) {
                $groups = @()
                foreach ($grp in @($settings.hooks.$ev)) {
                    if ($null -eq $grp) { continue }
                    if ($grp.PSObject.Properties['hooks']) {
                        $keep = @(@($grp.hooks) | Where-Object { -not ($_.command -and $_.command -match $HodorPattern) })
                        $removed += @($grp.hooks).Count - $keep.Count
                        if ($keep.Count -eq 0) { continue }   # group that only held Hodor hooks
                        $grp | Add-Member -NotePropertyName hooks -NotePropertyValue ([object[]]$keep) -Force
                    }
                    $groups += $grp
                }
                if ($groups.Count -eq 0) { $settings.hooks.PSObject.Properties.Remove($ev) }
                else { $settings.hooks | Add-Member -NotePropertyName $ev -NotePropertyValue ([object[]]$groups) -Force }
            }
            if (@($settings.hooks.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }
        }
        if ($removed -gt 0) {
            Copy-Item $claudeSettings "$claudeSettings.hodor-uninstall.bak" -Force
            Save-Json $claudeSettings $settings
            Ok "$removed hook(s) removed (backup: settings.json.hodor-uninstall.bak)"
        } else {
            Info "No Hodor hooks found"
        }
    } catch {
        Warn "Could not process ${claudeSettings}: $($_.Exception.Message)"
        Warn "Remove by hand the 'hooks' entries that contain PlainConcepts\ai-hooks\dispatch.ps1"
    }
}

# 3. Copilot (VS Code + Copilot CLI) -------------------------------------------------
Step 3 "Removing the Copilot hook"
$copilotHook = Join-Path $env:USERPROFILE '.copilot\hooks\company-hooks.json'
if (-not (Test-Path $copilotHook)) {
    Info "$copilotHook does not exist"
} elseif ((Get-Content $copilotHook -Raw -Encoding UTF8) -match 'ai-hooks') {
    try { Remove-Item $copilotHook -Force; Ok "Removed $copilotHook" }
    catch { Warn "Could not delete ${copilotHook}: $($_.Exception.Message)" }
} else {
    Info "$copilotHook is not Hodor's; left untouched"
}

# 4. Files -------------------------------------------------------------------------
Step 4 "Deleting files"
if ($KeepLogs) {
    $logs = Join-Path $InstallDir 'logs'
    if (Test-Path $logs) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $zip = Join-Path $desktop ("hodor-logs-{0:yyyyMMdd-HHmmss}.zip" -f (Get-Date))
        try { Compress-Archive -Path (Join-Path $logs '*') -DestinationPath $zip -Force; Ok "Logs saved to $zip" }
        catch { Warn "Could not save the logs: $($_.Exception.Message)" }
    }
}
function Remove-Dir($path, $label) {
    if (-not (Test-Path $path)) { Info "$path does not exist"; return }
    for ($i = 0; $i -lt 3; $i++) {
        try { Remove-Item $path -Recurse -Force -ErrorAction Stop; Ok "$label removed: $path"; return }
        catch { Start-Sleep -Milliseconds 700 }
    }
    Warn "Could not delete $path (a file is in use). Close Claude Code / VS Code and run this again."
}
Remove-Dir $InstallDir 'Install'
# Empty parent folder
$parent = Split-Path $InstallDir -Parent
if ((Test-Path $parent) -and -not (Get-ChildItem $parent -Force)) { Remove-Item $parent -Force -ErrorAction SilentlyContinue }
if ($KeepRepo) { Info "Keeping the repo at $RepoDir (-KeepRepo)" }
elseif (Test-Path (Join-Path $RepoDir 'install-local.ps1')) { Remove-Dir $RepoDir 'Repo' }
elseif (Test-Path $RepoDir) { Info "$RepoDir does not look like the Hodor repo; left untouched" }
else { Info "$RepoDir does not exist" }

$progData = 'C:\ProgramData\PlainConcepts\ai-hooks'
if (Test-Path $progData) { Info "Another install exists at $progData (needs admin rights to delete)" }

# 5. VS Code -----------------------------------------------------------------------
Step 5 "Checking chat.useHooks in VS Code"
$vsSettings = Join-Path $env:APPDATA 'Code\User\settings.json'
$vsBackup   = "$vsSettings.hodor.bak"
if (-not (Test-Path $vsBackup)) {
    Info "Install-Hodor.ps1 did not change VS Code; left untouched"
} else {
    try {
        $before = Get-Content $vsBackup -Raw -Encoding UTF8 | ConvertFrom-Json
        $wasOn  = $before.PSObject.Properties['chat.useHooks'] -and $before.'chat.useHooks' -eq $true
        if (-not $wasOn -and (Test-Path $vsSettings)) {
            $now = Get-Content $vsSettings -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($now.PSObject.Properties['chat.useHooks']) {
                $now.PSObject.Properties.Remove('chat.useHooks')
                Save-Json $vsSettings $now
                Ok "chat.useHooks turned off (it was off before Hodor was installed)"
            }
        } else {
            Info "chat.useHooks was already on before Hodor; left as is"
        }
        Remove-Item $vsBackup -Force -ErrorAction SilentlyContinue
    } catch {
        Warn "Could not check VS Code: $($_.Exception.Message). Turn 'chat.useHooks' off by hand if you want."
    }
}

# Summary --------------------------------------------------------------------------
Write-Host ""
if ($script:problems -eq 0) {
    Write-Host "== Hodor uninstalled ==" -ForegroundColor Green
} else {
    Write-Host "== Uninstall finished with $($script:problems) warning(s): check the [!] messages above ==" -ForegroundColor Yellow
}
Write-Host "Restart Claude Code and reload VS Code so they stop loading the hooks."
if ($script:problems -gt 0) { exit 1 }
