# infra/local/smoke.ps1 - end-to-end smoke test: current dispatcher -> local OTel Collector.
# Prerequisite: docker compose up -d (in infra/local). Uses isolated temp settings/logs (AIHOOKS_SETTINGS),
# so it never touches your installed config. Exit code 1 if any check fails.
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\infra\local\smoke.ps1
param(
    [string]$Endpoint = 'http://localhost:4318',
    [string]$HealthUrl = 'http://localhost:13133',
    [int]$WaitSeconds = 15,
    [string]$Token = ''          # collector with bearer auth (docker-compose.auth.yml overlay)
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dispatch = Join-Path $Root 'dispatch.ps1'
$exportFile = Join-Path $PSScriptRoot 'data\telemetry.jsonl'
$psExe = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

$script:fail = 0
function Ok($n)  { Write-Host "  PASS  $n" -ForegroundColor Green }
function Bad($n, $d) { Write-Host "  FAIL  $n" -ForegroundColor Red; if ($d) { Write-Host "        $d" -ForegroundColor DarkYellow }; $script:fail++ }

# 0. Collector up?
try { Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 3 | Out-Null; Ok "collector healthy ($HealthUrl)" }
catch { Bad "collector healthy ($HealthUrl)" 'Run: docker compose up -d (in infra/local)'; exit 1 }

$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$work = Join-Path ([System.IO.Path]::GetTempPath()) "hodor-smoke-$runId"
$logDir = Join-Path $work 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$settingsFile = Join-Path $work 'settings.json'
$queue = Join-Path $logDir 'telemetry-queue.jsonl'

function Set-SmokeSettings([string]$ep, [bool]$background = $false) {
    $otel = @{ enabled = $true; endpoint = $ep; queueMaxSizeMB = 2; background = $background }
    if ($Token) { $otel.headers = @{ Authorization = "Bearer $Token" } }
    $s = @{
        otel     = $otel
        log      = @{ dir = $logDir; maxSizeMB = 5; maxFiles = 3 }
        identity = @{ email = "smoke-$runId@local"; salt = 'SMOKE' }
        policy   = @{ blockSeverity = 'critical' }
        skills   = @{ orgPluginPrefix = 'pc-' }
        support  = @{ channel = 'smoke' }
    }
    Set-Content -Path $settingsFile -Value ($s | ConvertTo-Json -Depth 5) -Encoding UTF8
}

function Invoke-Hook([string]$Event, [string]$Payload = '') {
    $in = Join-Path $work 'in.json'
    [System.IO.File]::WriteAllText($in, $Payload, (New-Object System.Text.UTF8Encoding($false)))  # no BOM on stdin
    $p = Start-Process -FilePath $psExe `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dispatch, '-Event', $Event, '-Agent', 'claude-code') `
        -RedirectStandardInput $in -RedirectStandardOutput (Join-Path $work 'out.txt') -RedirectStandardError (Join-Path $work 'err.txt') `
        -PassThru -Wait -NoNewWindow
    return $p.ExitCode
}

$env:AIHOOKS_SETTINGS = $settingsFile
try {
    Write-Host "`n== Selftest (run $runId) =="
    Set-SmokeSettings $Endpoint
    $code = Invoke-Hook 'selftest'
    $st = Get-Content (Join-Path $work 'out.txt') -Raw
    if ($code -eq 0 -and $st.Contains('"ok":true')) { Ok 'dispatch -Event selftest' } else { Bad 'dispatch -Event selftest' $st }

    Write-Host "`n== Direct send (otel.background = false) =="
    Invoke-Hook 'PreToolUse' "{`"tool_name`":`"Skill`",`"tool_input`":{`"skill`":`"pc-smoke:skill-$runId`"}}" | Out-Null
    Invoke-Hook 'PreToolUse' "{`"tool_name`":`"Task`",`"tool_input`":{`"subagent_type`":`"pc-smoke:agent-$runId`"}}" | Out-Null
    Invoke-Hook 'UserPromptSubmit' "{`"prompt`":`"run /pc-smoke:prompt-$runId and call me at +34600111222`"}" | Out-Null
    if (-not (Test-Path $queue)) { Ok 'events sent directly (nothing queued)' }
    else { Bad 'events sent directly (nothing queued)' (Get-Content $queue -Raw) }

    Write-Host "`n== Offline queue + flush on SessionEnd =="
    Set-SmokeSettings 'http://127.0.0.1:4399'   # unreachable -> must queue
    Invoke-Hook 'PreToolUse' "{`"tool_name`":`"Skill`",`"tool_input`":{`"skill`":`"pc-smoke:queued-$runId`"}}" | Out-Null
    if (Test-Path $queue) { Ok 'event queued while endpoint is down' } else { Bad 'event queued while endpoint is down' }
    Set-SmokeSettings $Endpoint
    Invoke-Hook 'SessionEnd' '{}' | Out-Null
    if (-not (Test-Path $queue)) { Ok 'queue flushed on SessionEnd' } else { Bad 'queue flushed on SessionEnd' (Get-Content $queue -Raw) }

    Write-Host "`n== Background send (otel.background = true: queue + detached worker) =="
    Set-SmokeSettings $Endpoint $true
    Invoke-Hook 'PreToolUse' "{`"tool_name`":`"Skill`",`"tool_input`":{`"skill`":`"pc-smoke:background-$runId`"}}" | Out-Null
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Test-Path $queue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-Path $queue)) { Ok 'queue delivered by the background worker' } else { Bad 'queue delivered by the background worker' }

    Write-Host "`n== Collector received (file exporter: $exportFile) =="
    $expected = @("skill-$runId", "agent-$runId", "prompt-$runId", "queued-$runId", "background-$runId", 'pc.ai.policy_warning', 'pc.ai.selftest')
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $content = ''
    do {
        Start-Sleep -Milliseconds 500
        if (Test-Path $exportFile) { $content = Get-Content $exportFile -Raw -Encoding UTF8 }
        $missing = @($expected | Where-Object { -not $content.Contains($_) })
    } while ($missing.Count -gt 0 -and (Get-Date) -lt $deadline)
    foreach ($e in $expected) { if ($content.Contains($e)) { Ok "received $e" } else { Bad "received $e" } }

    $errLog = Join-Path $logDir 'hooks-error.jsonl'
    if (Test-Path $errLog) { Bad 'no hook errors' (Get-Content $errLog -Raw) } else { Ok 'no hook errors' }
}
finally {
    $env:AIHOOKS_SETTINGS = $null
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host 'SMOKE OK - open http://localhost:18888 (Structured logs) to browse the events.' -ForegroundColor Green; exit 0 }
Write-Host "SMOKE FAILED ($script:fail check(s))" -ForegroundColor Red
exit 1
