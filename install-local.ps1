# install-local.ps1 - LOCAL test installation (this is not the Intune installer)
# Run as Administrator (writes to C:\ProgramData):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-local.ps1
# Without admin rights, use a different target folder:
#   ... -File .\install-local.ps1 -Dest "$env:LOCALAPPDATA\PlainConcepts\ai-hooks"
param(
    [string]$Dest = 'C:\ProgramData\PlainConcepts\ai-hooks'
)
$ErrorActionPreference = 'Stop'
$Src = $PSScriptRoot

Write-Host "== Company AI Hooks: local test installation =="

# 1. Copy scripts to the machine-wide folder
if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
Copy-Item -Path (Join-Path $Src '*') -Destination $Dest -Recurse -Force
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
    @{ hooks = $fragmentObj.hooks } | ConvertTo-Json -Depth 12 | Set-Content -Path $claudeSettingsPath -Encoding UTF8
    Write-Host "[OK] Claude Code hooks created at $claudeSettingsPath"
} else {
    $settings = Get-Content $claudeSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not ($settings.PSObject.Properties['hooks'])) {
        Copy-Item $claudeSettingsPath "$claudeSettingsPath.bak" -Force
        $settings | Add-Member -NotePropertyName hooks -NotePropertyValue $fragmentObj.hooks
        $settings | ConvertTo-Json -Depth 12 | Set-Content -Path $claudeSettingsPath -Encoding UTF8
        Write-Host "[OK] Claude Code hooks added to $claudeSettingsPath (backup: .bak)"
    } else {
        Write-Host "[!] $claudeSettingsPath already contains a 'hooks' section. Merge manually the content of:"
        Write-Host "    $Dest\adapters\claude\hooks-fragment.json"
    }
}

Write-Host ""
Write-Host "== Check the installed version =="
Write-Host ('  powershell -NoProfile -ExecutionPolicy Bypass -File "' + $Dest + '\tools\hodor-version.ps1"')
Write-Host ('  (or: ... -File "' + $Dest + '\dispatch.ps1" -Event version)')
Write-Host ""
Write-Host "== Remaining manual steps =="
Write-Host "1. VS Code: enable the 'chat.useHooks' setting (agent hooks are in preview)."
Write-Host "2. Edit $Dest\config\settings.json -> identity.email and, if available, otel.endpoint."
Write-Host ""
Write-Host "== Quick test (no IDE needed) =="
Write-Host ('  ''{"prompt":"upload this with token ghp_0123456789abcdefghijklmnopqrstuvwxyz12"}'' | powershell -NoProfile -ExecutionPolicy Bypass -File "' + $Dest + '\dispatch.ps1" -Event userPromptSubmitted -Agent test')
Write-Host "  It must print a warning systemMessage and write to $logDir\security.jsonl"
