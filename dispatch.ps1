# dispatch.ps1 - single entry point for the Company AI Hooks (Windows)
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File dispatch.ps1 -Event <event> -Agent <agent>
# Receives the agent JSON payload via stdin. Blocks (exit 2) on a critical finding; warns (exit 0) otherwise.
param(
    [Parameter(Mandatory = $true)][string]$Event,
    [string]$Agent = 'unknown'
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

. (Join-Path $Root 'lib\logrotate.ps1')
. (Join-Path $Root 'lib\common.ps1')
. (Join-Path $Root 'lib\otel.ps1')

# 'version' is a diagnostic command: answer and exit BEFORE reading stdin (which would block interactively).
if ($Event -match '^version$') {
    $bi = Get-HooksBuildInfo
    [pscustomobject]@{
        name        = 'hodor'
        version     = $bi.version
        commit      = $bi.commit
        commitCount = $bi.commitCount
        buildDate   = $bi.buildDate
        root        = $Root
    } | ConvertTo-Json -Compress
    exit 0
}

function Get-Field {
    param($Obj, [string[]]$Names)
    if (-not $Obj) { return $null }
    foreach ($n in $Names) {
        $p = $Obj.PSObject.Properties[$n]
        if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return $p.Value }
    }
    return $null
}

$settings = $null
$hooksVersion = 'unknown'
$blockExit = 0        # set to 2 when a prompt is blocked
try {
    $settings = Get-AiHooksSettings
    $hooksVersion = Get-HooksVersion

    $raw = [System.Console]::In.ReadToEnd()

    # Optional raw-payload capture for troubleshooting (only when HODOR_DEBUG is set).
    if ($env:HODOR_DEBUG -and -not [string]::IsNullOrWhiteSpace($raw)) {
        try {
            Write-AiHooksLog -Settings $settings -FileName 'payloads-debug.jsonl' -Record ([pscustomobject]@{
                ts    = (Get-Date).ToUniversalTime().ToString('o')
                event = $Event
                agent = $Agent
                raw   = $raw.Trim()
            })
        } catch { }
    }

    $payload = $null
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try { $payload = $raw | ConvertFrom-Json } catch { }
    }

    # Cross-platform payload normalization (VS Code PascalCase, Copilot CLI camelCase, Claude Code snake_case)
    $prompt    = [string](Get-Field $payload @('prompt', 'userMessage', 'user_message'))
    $toolName  = [string](Get-Field $payload @('tool_name', 'toolName'))
    $toolInput = Get-Field $payload @('tool_input', 'toolArgs', 'tool_args')
    $userHash  = Get-UserHash $settings

    switch -Regex ($Event) {

        '^(UserPromptSubmit|userPromptSubmitted)$' {
            # ---- Layer 10: prompt policy (block on critical, warn otherwise) ----
            $findings = & (Join-Path $Root 'layers\10-policy\scan-prompt.ps1') -Prompt $prompt -Root $Root
            $threshold = Get-SeverityRank $settings.policy.blockSeverity
            $blockMsgs = @()
            $warnMsgs = @()
            foreach ($f in $findings) {
                $red = Get-RedactedText $f.evidence
                $isBlock = (Get-SeverityRank $f.severity) -ge $threshold
                $action = if ($isBlock) { 'block' } else { 'warn' }
                Write-AiHooksLog -Settings $settings -FileName 'security.jsonl' -Record ([pscustomobject]@{
                    ts       = (Get-Date).ToUniversalTime().ToString('o')
                    event    = if ($isBlock) { 'policy_block' } else { 'policy_warning' }
                    agent    = $Agent
                    rule     = $f.rule
                    severity = $f.severity
                    action   = $action
                    evidence = $red
                    version  = $hooksVersion
                })
                Send-OtelEvent -Settings $settings -Name 'pc.ai.policy_warning' -Attributes @{
                    'pc.rule'          = $f.rule
                    'pc.severity'      = $f.severity
                    'pc.action'        = $action
                    'pc.agent'         = $Agent
                    'pc.evidence'      = $red
                    'pc.user_hash'     = $userHash
                    'pc.hooks_version' = $hooksVersion
                }
                if ($isBlock) { $blockMsgs += "$($f.rule) ($red)" } else { $warnMsgs += "$($f.rule) ($red)" }
            }

            # ---- Layer 30: skill usage detected in the prompt (namespaced tokens only) ----
            $skills = & (Join-Path $Root 'layers\30-skills\skill-usage.ps1') -Prompt $prompt -Root $Root
            foreach ($s in $skills) {
                Send-OtelEvent -Settings $settings -Name 'pc.ai.skill_usage' -Attributes @{
                    'pc.skill'         = $s.skill
                    'pc.plugin'        = $s.plugin
                    'pc.source'        = $s.source
                    'pc.kind'          = $s.kind
                    'pc.agent'         = $Agent
                    'pc.user_hash'     = $userHash
                    'pc.hooks_version' = $hooksVersion
                }
            }

            $logPath = Join-Path $settings.log.dir 'security.jsonl'
            if ($blockMsgs.Count -gt 0) {
                # BLOCK: stop the prompt before it reaches the model.
                $reason = '[Plain Concepts AI policy BLOCK] Your prompt was blocked before reaching the model: possible ' +
                    ($blockMsgs -join '; ') +
                    '. Remove the sensitive data and try again. ' +
                    "Details: $logPath | Questions or false positives: $($settings.support.channel)"
                # Emit all three block signals; platforms honor different ones, Copilot CLI ignores them.
                [Console]::Error.WriteLine($reason)                                        # stderr (shown by Claude Code / VS Code)
                @{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress       # stdout JSON decision
                $blockExit = 2                                                             # blocking exit code
            }
            elseif ($warnMsgs.Count -gt 0) {
                # WARN (non-blocking): request continues.
                $warning = '[Plain Concepts AI policy WARNING] This prompt does not comply with the company AI policy: ' +
                    ($warnMsgs -join '; ') +
                    '. The request continues, but please review what you are sharing with the model. ' +
                    "Details: $logPath | Questions or false positives: $($settings.support.channel)"
                # systemMessage: shown to the user by VS Code and Claude Code; ignored by Copilot CLI (known limitation)
                @{ systemMessage = $warning } | ConvertTo-Json -Compress
            }
        }

        '^(PreToolUse|preToolUse)$' {
            # ---- Layer 30: skill/agent invocation via tools (Claude Code) ----
            $name = $null; $kind = $null
            if ($toolName -match '^[Ss]kill$') {
                $name = [string](Get-Field $toolInput @('skill', 'name', 'command'))
                $kind = 'skill'
            }
            elseif ($toolName -match '^[Tt]ask$') {
                $name = [string](Get-Field $toolInput @('subagent_type', 'subagentType', 'agent_type', 'name'))
                $kind = 'agent'
            }
            if ($name -and $kind) {
                $skills = & (Join-Path $Root 'layers\30-skills\skill-usage.ps1') -SkillName $name -Kind $kind -Root $Root
                foreach ($s in $skills) {
                    Send-OtelEvent -Settings $settings -Name 'pc.ai.skill_usage' -Attributes @{
                        'pc.skill'         = $s.skill
                        'pc.plugin'        = $s.plugin
                        'pc.source'        = $s.source
                        'pc.kind'          = $s.kind
                        'pc.agent'         = $Agent
                        'pc.user_hash'     = $userHash
                        'pc.hooks_version' = $hooksVersion
                    }
                }
            }
        }

        '^(SessionEnd|sessionEnd)$' {
            Invoke-OtelQueueFlush -Settings $settings
        }
    }
} catch {
    try {
        if ($settings) { Write-AiHooksError -Settings $settings -Message $_.Exception.Message -Agent $Agent -HooksVersion $hooksVersion }
    } catch { }
    # A hook failure must never block the user's flow.
    $blockExit = 0
}
# Exit 2 only when a critical finding blocked the prompt; otherwise 0.
exit $blockExit
