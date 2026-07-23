# install-local.ps1 - LOCAL test installation (this is not the Intune installer)
# Run as Administrator (writes to C:\ProgramData):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-local.ps1
# Without admin rights, use a different target folder:
#   ... -File .\install-local.ps1 -Dest "$env:LOCALAPPDATA\PlainConcepts\ai-hooks"
param(
    [string]$Dest = 'C:\ProgramData\PlainConcepts\ai-hooks',
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
$Src = $PSScriptRoot

Write-Host "== Company AI Hooks: local test installation =="

# 1. Copy scripts to the machine-wide folder (exclude the repo's .git history)
if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
Get-ChildItem -Path $Src -Force | Where-Object { $_.Name -ne '.git' } |
    Copy-Item -Destination $Dest -Recurse -Force
# Remove any stale .git left by older installs: version must come from build-info.json here, not a frozen repo.
$destGit = Join-Path $Dest '.git'
if (Test-Path $destGit) { Remove-Item $destGit -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "[OK] Removed stale .git from install" }
Write-Host "[OK] Scripts copied to $Dest"

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
Set-Content -Path (Join-Path $copilotHooksDir 'company-hooks.json') -Value $hookJson -Encoding UTF8
Write-Host "[OK] Copilot hook installed at $copilotHooksDir\company-hooks.json"

# 4. Claude Code hooks (user settings for testing; in production: managed settings)
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$claudeSettingsPath = Join-Path $claudeDir 'settings.json'
$fragment = Get-Content (Join-Path $Src 'adapters\claude\hooks-fragment.json') -Raw -Encoding UTF8
$fragment = $fragment.Replace('C:\\ProgramData\\PlainConcepts\\ai-hooks', ($Dest -replace '\\', '\\'))
$fragmentObj = $fragment | ConvertFrom-Json

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
Write-Host "2. Edit $Dest\config\settings.json -> identity.email and, if available, otel.endpoint."
Write-Host "3. Restart Claude Code / reload VS Code so the hooks load."
Write-Host ""
Write-Host "== Quick manual check (no IDE needed) =="
Write-Host "  A critical secret must BLOCK the prompt (exit 2, decision:block):"
Write-Host ('  ''{"prompt":"token ghp_0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcd"}'' | powershell -NoProfile -ExecutionPolicy Bypass -File "' + $Dest + '\dispatch.ps1" -Event UserPromptSubmit -Agent claude-code')
Write-Host "  Re-check the version anytime with:"
Write-Host ('  powershell -NoProfile -ExecutionPolicy Bypass -File "' + $Dest + '\dispatch.ps1" -Event version')
