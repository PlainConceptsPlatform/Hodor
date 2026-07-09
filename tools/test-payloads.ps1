# tools/test-payloads.ps1
# Deterministic smoke tests for the Hodor dispatcher: block/warn/clean + skill/agent classification.
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test-payloads.ps1 `
#     -Dispatch "$env:LOCALAPPDATA\PlainConcepts\ai-hooks\dispatch.ps1"
# If -Dispatch is omitted it uses the dispatch.ps1 next to this repo.
param(
    [string]$Dispatch = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dispatch.ps1')
)

if (-not (Test-Path $Dispatch)) { Write-Error "dispatch.ps1 not found at: $Dispatch"; exit 1 }

$pass = 0; $fail = 0

function Invoke-Dispatch {
    param([string]$Payload, [string]$EventName, [string]$AgentName = 'claude-code')
    $out = $Payload | & powershell -NoProfile -ExecutionPolicy Bypass -File $Dispatch -Event $EventName -Agent $AgentName 2>$null
    return [pscustomobject]@{ stdout = ($out -join "`n"); exit = $LASTEXITCODE }
}

function Assert {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red; $script:fail++ }
}

Write-Host "`n== Policy: block vs warn =="

$r = Invoke-Dispatch '{"prompt":"upload with token ghp_0123456789abcdefghijklmnopqrstuvwxyz12"}' 'UserPromptSubmit'
Assert 'critical GitHub token blocks (exit 2)' ($r.exit -eq 2) "exit=$($r.exit)"
Assert 'critical emits decision:block' ($r.stdout -match '"decision"\s*:\s*"block"') $r.stdout

$r = Invoke-Dispatch '{"prompt":"call me at +34600111222"}' 'UserPromptSubmit'
Assert 'medium phone warns, not blocks (exit 0)' ($r.exit -eq 0) "exit=$($r.exit)"
Assert 'medium emits systemMessage (WARNING)' ($r.stdout -match 'systemMessage' -and $r.stdout -match 'WARNING') $r.stdout

$r = Invoke-Dispatch '{"prompt":"refactor this function please"}' 'UserPromptSubmit'
Assert 'clean prompt: no output' ([string]::IsNullOrWhiteSpace($r.stdout)) $r.stdout
Assert 'clean prompt: exit 0' ($r.exit -eq 0) "exit=$($r.exit)"

Write-Host "`n== Skills/agents classification (telemetry-queue.jsonl) =="
Write-Host "  (inspect logs\telemetry-queue.jsonl for pc.source / pc.plugin / pc.kind)"

$null = Invoke-Dispatch '{"tool_name":"Skill","tool_input":{"skill":"pc-ai:debugger"}}' 'PreToolUse'
Assert 'pc- skill accepted (exit 0)' ($LASTEXITCODE -eq 0)
$null = Invoke-Dispatch '{"tool_name":"Skill","tool_input":{"skill":"anthropic-skills:docx"}}' 'PreToolUse'
Assert 'third-party plugin skill accepted (exit 0)' ($LASTEXITCODE -eq 0)
$null = Invoke-Dispatch '{"tool_name":"Skill","tool_input":{"skill":"my-local-skill"}}' 'PreToolUse'
Assert 'personal skill accepted (exit 0)' ($LASTEXITCODE -eq 0)
$null = Invoke-Dispatch '{"tool_name":"Task","tool_input":{"subagent_type":"pc-quality:reviewer"}}' 'PreToolUse'
Assert 'pc- agent via Task accepted (exit 0)' ($LASTEXITCODE -eq 0)

Write-Host "`nResult: $pass passed, $fail failed`n"
if ($fail -gt 0) { exit 1 } else { exit 0 }
