# tools/hodor-version.ps1
# Doctor: prints the installed Hodor version + paths + hook wiring + recent errors.
# Run this when reporting a problem and paste the final JSON line.
#   powershell -NoProfile -ExecutionPolicy Bypass -File <install>\tools\hodor-version.ps1
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

. (Join-Path $Root 'lib\logrotate.ps1')
. (Join-Path $Root 'lib\common.ps1')

$bi = Get-HooksBuildInfo
$settings = $null
try { $settings = Get-AiHooksSettings } catch { }
$logDir = if ($settings) { [string]$settings.log.dir } else { '' }

Write-Host "Hodor - version check"
Write-Host "  version    : $($bi.version)"
Write-Host "  commit     : $($bi.commit)"
Write-Host "  commitCount: $($bi.commitCount)"
Write-Host "  buildDate  : $(if ($bi.buildDate) { $bi.buildDate } else { '(dev / not stamped)' })"
Write-Host "  root       : $Root"
Write-Host "  config     : $(Join-Path $Root 'config\settings.json')"
Write-Host "  logs       : $logDir"
Write-Host "  otel       : $(if ($settings -and $settings.otel.endpoint) { 'configured' } else { 'not set (queued to disk)' })"

# Hook wiring
$claude = Join-Path $env:USERPROFILE '.claude\settings.json'
$claudeOk = $false
if (Test-Path $claude) {
    try {
        $c = Get-Content $claude -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($c.PSObject.Properties['hooks']) { $claudeOk = (($c.hooks | ConvertTo-Json -Depth 20) -match 'dispatch') }
    } catch { }
}
Write-Host "  claude hook : $(if ($claudeOk) { 'OK' } else { 'missing' })  ($claude)"
$copilot = Join-Path $env:USERPROFILE '.copilot\hooks\company-hooks.json'
$copilotOk = Test-Path $copilot
Write-Host "  copilot hook: $(if ($copilotOk) { 'OK' } else { 'missing' })  ($copilot)"

# Recent errors
$errPath = if ($logDir) { Join-Path $logDir 'hooks-error.jsonl' } else { $null }
if ($errPath -and (Test-Path $errPath)) {
    Write-Host "  recent errors:"
    Get-Content $errPath -Tail 3 | ForEach-Object { Write-Host "    $_" }
}

# Machine-readable line for reports
[pscustomobject]@{
    name        = 'hodor'
    version     = $bi.version
    commit      = $bi.commit
    commitCount = $bi.commitCount
    buildDate   = $bi.buildDate
    root        = $Root
    claudeHook  = $claudeOk
    copilotHook = $copilotOk
} | ConvertTo-Json -Compress
