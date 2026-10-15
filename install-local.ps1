# install-local.ps1 - LOCAL test installation (this is not the Intune installer)
# Run as Administrator (writes to C:\ProgramData):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-local.ps1
# Without admin rights, use a different target folder:
#   ... -File .\install-local.ps1 -Dest "$env:LOCALAPPDATA\PlainConcepts\ai-hooks"
# Optional settings (applied on top of the installed config; existing values are otherwise preserved):
#   -OtelEndpoint http://localhost:4318  -OtelToken <ingest token>  -IdentityEmail me@corp.com  -IdentityMode email|hash  -TrackFileReads
#   (-OtelToken is stored in clear text in settings.json as otel.headers.Authorization = 'Bearer <token>':
#    fine for a collector ingest token, never use a real secret here)
param(
    [string]$Dest = 'C:\ProgramData\PlainConcepts\ai-hooks',
    [switch]$SkipTests,
    [string]$OtelEndpoint,
    [string]$OtelToken,
    [string]$IdentityEmail,
    [ValidateSet('', 'hash', 'email')][string]$IdentityMode = '',
    [switch]$TrackFileReads
)
$ErrorActionPreference = 'Stop'
$Src = $PSScriptRoot

Write-Host "== Company AI Hooks: local test installation =="

# 0. Keep the values of an existing installed config (a reinstall must not wipe endpoint/email)
$destSettings = Join-Path $Dest 'config\settings.json'
$previous = $null
if (Test-Path $destSettings) { try { $previous = Get-Content $destSettings -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }

# 1. Copy scripts to the machine-wide folder (exclude the repo's .git history)
if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
Get-ChildItem -Path $Src -Force | Where-Object { $_.Name -ne '.git' } |
    Copy-Item -Destination $Dest -Recurse -Force
# Remove any stale .git left by older installs: version must come from build-info.json here, not a frozen repo.
$destGit = Join-Path $Dest '.git'
if (Test-Path $destGit) { Remove-Item $destGit -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "[OK] Removed stale .git from install" }
# Drop the Mark of the Web (repo downloaded as a zip): under RemoteSigned, Copilot runs the hook without
# -ExecutionPolicy Bypass and would refuse to load lib\*.ps1 ("not digitally signed").
Get-ChildItem -Path $Dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
Write-Host "[OK] Scripts copied to $Dest"

# 1a. Merge: new defaults from the repo, previous installed values on top, then explicit parameters
$cfg = Get-Content $destSettings -Raw -Encoding UTF8 | ConvertFrom-Json
if ($previous) {
    foreach ($sec in $previous.PSObject.Properties) {
        if ($sec.Value -is [System.Management.Automation.PSCustomObject] -and $cfg.PSObject.Properties[$sec.Name]) {
            foreach ($k in $sec.Value.PSObject.Properties) { $cfg.($sec.Name) | Add-Member -NotePropertyName $k.Name -NotePropertyValue $k.Value -Force }
        } else {
            $cfg | Add-Member -NotePropertyName $sec.Name -NotePropertyValue $sec.Value -Force
        }
    }
}
function Set-Cfg($Section, $Key, $Value) {
    if (-not $cfg.PSObject.Properties[$Section]) { $cfg | Add-Member -NotePropertyName $Section -NotePropertyValue ([pscustomobject]@{}) -Force }
    $cfg.$Section | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
}
if ($OtelEndpoint) { Set-Cfg 'otel' 'endpoint' $OtelEndpoint }
if ($OtelToken) {
    $h = if ($cfg.otel.PSObject.Properties['headers'] -and $cfg.otel.headers) { $cfg.otel.headers } else { [pscustomobject]@{} }
    $h | Add-Member -NotePropertyName 'Authorization' -NotePropertyValue "Bearer $OtelToken" -Force
    Set-Cfg 'otel' 'headers' $h
}
if ($IdentityEmail) { Set-Cfg 'identity' 'email' $IdentityEmail }
if ($IdentityMode) { Set-Cfg 'identity' 'mode' $IdentityMode }
if ($TrackFileReads) { Set-Cfg 'usage' 'trackFileReads' $true }
[System.IO.File]::WriteAllText($destSettings, ($cfg | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[OK] Config: $destSettings (previous values kept)"

# 1b. Stamp build-info.json (version derived from git in the SOURCE repo) into the install
& (Join-Path $Src 'tools\stamp-build-info.ps1') -SourceRoot $Src -OutFile (Join-Path $Dest 'build-info.json')

# 2. User log folder
$logDir = Join-Path $env:LOCALAPPDATA 'PlainConcepts\ai-hooks\logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
Write-Host "[OK] Log folder: $logDir"

# 3. Copilot hook (VS Code and Copilot CLI both read ~/.copilot/hooks)
$copilotHooksDir = Join-Path $env:USERPROFILE '.copilot\hooks'
if (-not (Test-Path $copilotHooksDir)) { New-Item -ItemType Directory -Path $copilotHooksDir -Force | Out-Null }
$hookJson = Get-Content (Join-Path $Src 'adapters\copilot\company-hooks.json') -Raw -Encoding UTF8
$hookJson = $hookJson.Replace('C:\\ProgramData\\PlainConcepts\\ai-hooks', ($Dest -replace '\\', '\\'))
# No BOM: Copilot CLI rejects the whole file otherwise ("Invalid JSON: expected value at line 1 column 1")
[System.IO.File]::WriteAllText((Join-Path $copilotHooksDir 'company-hooks.json'), $hookJson, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[OK] Copilot hook installed at $copilotHooksDir\company-hooks.json"

# 4. Claude Code hooks (user settings for testing; in production: managed settings)
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$claudeSettingsPath = Join-Path $claudeDir 'settings.json'
$fragment = Get-Content (Join-Path $Src 'adapters\claude\hooks-fragment.json') -Raw -Encoding UTF8
$fragment = $fragment.Replace('C:\\ProgramData\\PlainConcepts\\ai-hooks', ($Dest -replace '\\', '\\'))
$fragmentObj = $fragment | ConvertFrom-Json
# Opt-in heuristic: also hook Read|Bash to count skills/agents loaded by reading their .md
$trackReads = $TrackFileReads -or ($cfg.PSObject.Properties['usage'] -and $cfg.usage.trackFileReads)
if ($trackReads) {
    $extra = $fragmentObj._trackFileReads | Select-Object matcher, hooks
    $fragmentObj.hooks.PreToolUse = @($fragmentObj.hooks.PreToolUse) + @($extra)
    Write-Host "[OK] File-read tracking enabled (PreToolUse Read|Bash)"
}

if (-not (Test-Path $claudeSettingsPath)) {
    if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($claudeSettingsPath, (@{ hooks = $fragmentObj.hooks } | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[OK] Claude Code hooks created at $claudeSettingsPath"
} else {
    # Refresh our hooks so their paths always point to THIS install (fixes stale paths from an
    # earlier install to a different folder). Non-Hodor hooks on the same events are preserved.
    $settings = Get-Content $claudeSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Copy-Item $claudeSettingsPath "$claudeSettingsPath.bak" -Force
    if (-not ($settings.PSObject.Properties['hooks'])) {
        $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    foreach ($ev in $fragmentObj.hooks.PSObject.Properties.Name) {
        $kept = @()
        if ($settings.hooks.PSObject.Properties[$ev]) {
            foreach ($grp in @($settings.hooks.$ev)) {
                $isOurs = $false
                foreach ($h in @($grp.hooks)) { if ($h.command -and $h.command -match 'PlainConcepts\\ai-hooks\\dispatch\.ps1') { $isOurs = $true } }
                if (-not $isOurs) { $kept += $grp }
            }
        }
        $settings.hooks | Add-Member -NotePropertyName $ev -NotePropertyValue (@($kept) + @($fragmentObj.hooks.$ev)) -Force
    }
    [System.IO.File]::WriteAllText($claudeSettingsPath, ($settings | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[OK] Claude Code hooks point to $Dest (backup: .bak)"
}

# 5. Verify the install: doctor (version + wiring) then the regression suite
Write-Host ""
Write-Host "== Installed version =="
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dest 'tools\hodor-version.ps1')

if (-not $SkipTests) {
    Write-Host ""
    Write-Host "== Verifying install (regression suite) =="
    $testScript = Join-Path $Dest 'tests\run.ps1'
    if (Test-Path $testScript) {
        # Run in a child process so the suite's own 'exit' code can't terminate this installer.
        & powershell -NoProfile -ExecutionPolicy Bypass -File $testScript | Select-Object -Last 1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Install verified: all tests passed." -ForegroundColor Green
        } else {
            Write-Host "[FAIL] Regression suite reported failures (exit $LASTEXITCODE). Run for detail:" -ForegroundColor Red
            Write-Host ('  powershell -NoProfile -ExecutionPolicy Bypass -File "' + $testScript + '"')
        }
    } else {
        Write-Host "[!] tests\run.ps1 not found in the install (skipping verification)."
    }
}

Write-Host ""
Write-Host "== Remaining manual steps =="
Write-Host "1. VS Code: enable the 'chat.useHooks' setting (agent hooks are in preview)."
Write-Host "2. Check $Dest\config\settings.json -> identity.email/mode and otel.endpoint (or pass -OtelEndpoint / -OtelToken / -IdentityEmail / -IdentityMode)."
Write-Host "   Check end to end: powershell -NoProfile -File $Dest\dispatch.ps1 -Event selftest"
Write-Host "3. Restart Claude Code / reload VS Code so the hooks load."
Write-Host ""
Write-Host "== Quick manual check (no IDE needed) =="
Write-Host "  A critical secret must BLOCK the prompt (exit 2, decision:block):"
Write-Host ('  ''{"prompt":"token ghp_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcd"}'' | powershell -NoProfile -ExecutionPolicy Bypass -File "' + $Dest + '\dispatch.ps1" -Event UserPromptSubmit -Agent claude-code')
Write-Host "  Re-check the version anytime with:"
Write-Host ('  powershell -NoProfile -ExecutionPolicy Bypass -File "' + $Dest + '\dispatch.ps1" -Event version')
