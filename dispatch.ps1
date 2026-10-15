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
. (Join-Path $Root 'lib\plugins.ps1')

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
    $script:OtelServiceVersion = $hooksVersion

    # Worker / diagnostic events take no stdin payload (a detached worker has no stdin to read).
    $raw = ''
    if ($Event -eq 'inventory') {
        # Background SessionStart: the hook saved its payload for this worker
        $pendingPath = Join-Path $settings.log.dir 'pending-inventory.json'
        if (Test-Path $pendingPath) { $raw = Get-Content $pendingPath -Raw -Encoding UTF8; Remove-Item $pendingPath -Force -ErrorAction SilentlyContinue }
    }
    elseif ($Event -notmatch '^(flush|selftest)$') {
        $raw = [System.Console]::In.ReadToEnd()
    }

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
    $toolInput = Get-Field $payload @('tool_input', 'toolInput', 'toolArgs', 'tool_args')
    if ($toolInput -is [string]) {
        # Copilot CLI sends toolArgs as a JSON string
        try { $toolInput = $toolInput | ConvertFrom-Json } catch { $toolInput = $null }
    }
    $cwd       = [string](Get-Field $payload @('cwd', 'workspaceFolder', 'workspace_folder'))
    $sessionId = [string](Get-Field $payload @('session_id', 'sessionId', 'conversation_id', 'conversationId'))

    # Shared who/where attributes, computed once and only when something is emitted (project = git call).
    $script:common = $null
    function Get-Common {
        if (-not $script:common) {
            $script:common = Get-CommonAttributes -Settings $settings -Agent $Agent -HooksVersion $hooksVersion `
                -SessionId $sessionId -Project (Get-ProjectName $settings $cwd)
        }
        return $script:common
    }
    function Merge-Attrs([hashtable]$Specific) {
        $a = @{}
        $c = Get-Common
        foreach ($k in $c.Keys) { $a[$k] = $c[$k] }
        foreach ($k in $Specific.Keys) { $a[$k] = $Specific[$k] }
        return $a
    }
    function Send-UsageEvents($Items) {
        # One event per distinct use; a repeat of the same skill in the same session inside the dedupe window is dropped.
        $batch = @()
        foreach ($s in @($Items)) {
            if (-not $s) { continue }
            $sid = if ($sessionId) { $sessionId } else { 'nosession' }
            if (Test-UsageDuplicate $settings "$sid|$($s.plugin)|$($s.skill)") { continue }
            $batch += @{ Name = 'pc.ai.skill_usage'; Attributes = (Merge-Attrs @{
                'pc.skill'          = $s.skill
                'pc.skill_raw'      = $s.raw
                'pc.plugin'         = $s.plugin
                'pc.source'         = $s.source
                'pc.kind'           = $s.kind
                'pc.via'            = $s.via
                'pc.plugin_version' = $s.version
                'pc.marketplace'    = $s.marketplace
            }) }
        }
        Send-OtelEvents -Settings $settings -Events $batch
    }
    function Send-Inventory {
        # ---- Inventory layer: what this user has installed (throttled: interval or fingerprint change) ----
        if (-not $settings.inventory.enabled) { return }
        $records = & (Join-Path $Root 'layers\inventory\inventory.ps1') -Root $Root -Settings $settings
        $records = @($records)   # the layer returns the list as one object
        $fingerprint = Get-ShortHash ((@($records | ForEach-Object {
            $r = $_; (@($r.Keys | Sort-Object | ForEach-Object { "$_=$($r[$_])" })) -join ';'
        }) | Sort-Object) -join '|')
        $state = Read-StateFile $settings 'state-inventory.json'
        $now = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $due = (-not $state) -or ($state.fingerprint -ne $fingerprint) -or
               (($now - [long]$state.sentAt) -ge ([double]$settings.inventory.intervalHours * 3600))
        if ($due -and $records.Count -gt 0) {
            $snapshot = [guid]::NewGuid().ToString('N').Substring(0, 12)
            $batch = @()
            foreach ($r in $records) {
                $r['pc.inventory_id'] = $snapshot
                $r['pc.inventory_size'] = [string]$records.Count
                $batch += @{ Name = 'pc.ai.inventory'; Attributes = (Merge-Attrs $r) }
            }
            Send-OtelEvents -Settings $settings -Events $batch
            Write-StateFile $settings 'state-inventory.json' ([pscustomobject]@{ sentAt = $now; fingerprint = $fingerprint })
        }
    }

    switch -Regex ($Event) {

        '^(UserPromptSubmit|userPromptSubmitted)$' {
            # ---- Policy layer: prompt policy (block on critical, warn otherwise) ----
            $findings = & (Join-Path $Root 'layers\policy\scan-prompt.ps1') -Prompt $prompt -Root $Root
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
                Send-OtelEvent -Settings $settings -Name $(if ($isBlock) { 'pc.ai.policy_block' } else { 'pc.ai.policy_warning' }) -Attributes (Merge-Attrs @{
                    'pc.rule'     = $f.rule
                    'pc.severity' = $f.severity
                    'pc.action'   = $action
                    'pc.evidence' = $red
                })
                if ($isBlock) { $blockMsgs += "$($f.rule) ($red)" } else { $warnMsgs += "$($f.rule) ($red)" }
            }

            # ---- Usage layer: skill usage detected in the prompt (namespaced tokens only) ----
            $skills = & (Join-Path $Root 'layers\usage\usage.ps1') -Prompt $prompt -Cwd $cwd -Client $Agent -Root $Root
            Send-UsageEvents $skills

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
            # ---- Usage layer: skill/agent invocation via tools ----
            # One call (toolName/toolInput), or a batch as the Copilot CLI agents window sends it: toolCalls[{name, args}]
            $calls = @()
            if ($toolName) { $calls += [pscustomobject]@{ name = $toolName; input = $toolInput } }
            else {
                foreach ($c in @(Get-Field $payload @('toolCalls', 'tool_calls'))) {
                    if (-not $c) { continue }
                    $in = Get-Field $c @('args', 'arguments', 'input')
                    if ($in -is [string]) { try { $in = $in | ConvertFrom-Json } catch { $in = $null } }
                    $calls += [pscustomobject]@{ name = [string](Get-Field $c @('name', 'toolName')); input = $in }
                }
            }
            # File-read heuristic: opt-in on Claude (needs an extra Read|Bash matcher); free on Copilot, whose
            # preToolUse already runs for every tool call.
            $trackReads = $settings.usage.trackFileReads -or $Agent -eq 'copilot'
            $skills = @()
            foreach ($c in $calls) {
                if ($c.name -match '^[Ss]kill$') {
                    $name = [string](Get-Field $c.input @('skill', 'name', 'command'))
                    if ($name) { $skills += @(& (Join-Path $Root 'layers\usage\usage.ps1') -SkillName $name -Kind skill -Cwd $cwd -Client $Agent -Root $Root) }
                }
                elseif ($c.name -match '^([Tt]ask|[Aa]gent)$') {
                    $name = [string](Get-Field $c.input @('subagent_type', 'subagentType', 'agent_type', 'agentType', 'name'))
                    if ($name) { $skills += @(& (Join-Path $Root 'layers\usage\usage.ps1') -SkillName $name -Kind agent -Cwd $cwd -Client $Agent -Root $Root) }
                }
                elseif ($trackReads -and $c.name -match '^(Read|read|view|Bash|bash|shell|powershell|PowerShell)$') {
                    # Heuristic: a skill/agent/command loaded by reading its .md instead of being invoked
                    $text = [string](Get-Field $c.input @('file_path', 'filePath', 'path', 'command'))
                    if ($text) { $skills += @(& (Join-Path $Root 'layers\usage\usage.ps1') -FileText $text -Cwd $cwd -Client $Agent -Root $Root) }
                }
            }
            Send-UsageEvents $skills
        }

        '^(SessionStart|sessionStart)$' {
            if (Test-OtelBackground $settings) {
                # Inventory scan (~1-6 s) + queue retry run in a detached worker; the session starts right away.
                if ($settings.inventory.enabled -and -not [string]::IsNullOrWhiteSpace($raw)) {
                    if (-not (Test-Path $settings.log.dir)) { New-Item -ItemType Directory -Path $settings.log.dir -Force | Out-Null }
                    Set-Content -Path (Join-Path $settings.log.dir 'pending-inventory.json') -Value $raw -Encoding UTF8
                }
                Start-OtelWorker -Settings $settings -Event 'inventory' -Agent $Agent
            } else {
                # Opportunistic retry of anything queued while offline, then the inventory
                Invoke-OtelQueueFlush -Settings $settings | Out-Null
                Send-Inventory
            }
        }

        '^inventory$' {
            # Background worker started by SessionStart
            Send-Inventory
            Invoke-OtelQueueFlush -Settings $settings | Out-Null
            $script:OtelWorkerStarted = $true
        }

        '^(SessionEnd|sessionEnd)$' {
            if (Test-OtelBackground $settings) { Start-OtelWorker -Settings $settings -Event 'flush' -Agent $Agent }
            else { Invoke-OtelQueueFlush -Settings $settings | Out-Null }
        }

        '^flush$' {
            # Background worker (or manual: dispatch.ps1 -Event flush)
            $script:OtelWorkerStarted = $true
            Invoke-OtelQueueFlush -Settings $settings | ConvertTo-Json -Compress
        }

        '^selftest$' {
            # Synchronous end-to-end check: one pc.ai.selftest record straight to the endpoint
            $script:OtelWorkerStarted = $true
            $endpoint = [string]$settings.otel.endpoint
            $r = @{ ok = $false; status = 0; error = ''; ms = 0 }
            if (-not $settings.otel.enabled) { $r.error = 'otel.enabled = false' }
            elseif ([string]::IsNullOrWhiteSpace($endpoint)) { $r.error = 'otel.endpoint is empty' }
            else {
                $rec = ConvertTo-OtlpRecordJson -Name 'pc.ai.selftest' -Attributes (Merge-Attrs @{ 'pc.selftest' = 'true' }) `
                    -TimeMs ([System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
                $r = Invoke-OtlpPost -Settings $settings -Body (New-OtlpPayload $settings @($rec)) -TimeoutSec 5
            }
            $q = Get-OtelQueueInfo $settings
            [pscustomobject][ordered]@{
                ok         = [bool]$r.ok
                endpoint   = $endpoint
                headers    = @((Get-OtelHeaders $settings).Keys)
                status     = $r.status
                ms         = $r.ms
                error      = $r.error
                background = (Test-OtelBackground $settings)
                queue      = $q
                flush      = (Read-StateFile $settings 'state-flush.json')
                version    = $hooksVersion
            } | ConvertTo-Json -Compress -Depth 5
            if (-not $r.ok) { $blockExit = 1 }
        }
    }
} catch {
    try {
        if ($settings) { Write-AiHooksError -Settings $settings -Message $_.Exception.Message -Agent $Agent -HooksVersion $hooksVersion }
    } catch { }
    # A hook failure must never block the user's flow.
    $blockExit = 0
}
# Background mode: hand anything queued to a detached flush worker (never waits for the network).
try { if ($settings) { Complete-OtelDispatch -Settings $settings -Agent $Agent } } catch { }
# Exit 2 only when a critical finding blocked the prompt; otherwise 0.
exit $blockExit
