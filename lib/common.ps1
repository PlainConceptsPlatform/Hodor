# lib/common.ps1 - shared functions (requires logrotate.ps1 loaded first)

function Get-AiHooksRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-AiHooksSettings {
    $root = Get-AiHooksRoot
    # AIHOOKS_SETTINGS overrides the settings path (used by the test suite for isolation; unset in production).
    $path = if ($env:AIHOOKS_SETTINGS -and (Test-Path $env:AIHOOKS_SETTINGS)) { $env:AIHOOKS_SETTINGS } else { Join-Path $root 'config\settings.json' }
    $s = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $s.log.dir) {
        $s.log | Add-Member -NotePropertyName dir -NotePropertyValue '' -Force
    }
    if ([string]::IsNullOrWhiteSpace($s.log.dir)) {
        $s.log.dir = Join-Path $env:LOCALAPPDATA 'PlainConcepts\ai-hooks\logs'
    }
    # Defaults for settings that older installs may not have
    if (-not ($s.PSObject.Properties['policy'])) {
        $s | Add-Member -NotePropertyName policy -NotePropertyValue ([pscustomobject]@{ blockSeverity = 'critical' }) -Force
    } elseif ([string]::IsNullOrWhiteSpace($s.policy.blockSeverity)) {
        $s.policy | Add-Member -NotePropertyName blockSeverity -NotePropertyValue 'critical' -Force
    }
    Set-SettingDefault $s 'otel' 'queueMaxSizeMB' 2         # missing = 0 MB = the queue rotates on every write
    Set-SettingDefault $s 'otel' 'background' $true         # queue only + detached flush worker (false = send inside the hook)
    Set-SettingDefault $s 'otel' 'flushBatchSize' 200       # records per OTLP request when flushing the queue
    Set-SettingDefault $s 'otel' 'retryMinutes' 5           # an idle queue is retried at most every N minutes
    Set-SettingDefault $s 'log' 'maxSizeMB' 5
    Set-SettingDefault $s 'log' 'maxFiles' 3
    Set-SettingDefault $s 'skills' 'orgPluginPrefix' 'pc-'
    Set-SettingDefault $s 'identity' 'mode' 'hash'          # hash | email (email also sends pc.user)
    Set-SettingDefault $s 'telemetry' 'projectMode' 'name'  # name | hash
    Set-SettingDefault $s 'telemetry' 'dedupeSeconds' 120   # same skill in the same session within N s = 1 use (0 = off)
    Set-SettingDefault $s 'usage' 'trackFileReads' $false   # heuristic: count skills/agents loaded by reading their .md (Claude; always on for Copilot)
    Set-SettingDefault $s 'inventory' 'enabled' $true
    Set-SettingDefault $s 'inventory' 'intervalHours' 24    # resend the inventory at most every N h (or when it changes)
    return $s
}

function Set-SettingDefault {
    param($Settings, [string]$Section, [string]$Key, $Value)
    if (-not $Settings.PSObject.Properties[$Section]) {
        $Settings | Add-Member -NotePropertyName $Section -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $p = $Settings.$Section.PSObject.Properties[$Key]
    if (-not $p -or $null -eq $p.Value -or "$($p.Value)" -eq '') {
        $Settings.$Section | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
    }
}

function Get-ShortHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 16).ToLower()
    } finally { $sha.Dispose() }
}

function Invoke-NativeQuiet {
    # Runs a native command and returns trimmed stdout, or '' on any failure (never throws, even with EAP=Stop).
    param([string]$Exe, [string[]]$Arguments)
    $eap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = & $Exe @Arguments 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return ("$(@($out)[0])").Trim() }
    } catch { } finally { $ErrorActionPreference = $eap }
    return ''
}

function Get-SeverityRank {
    param([string]$Severity)
    switch (("$Severity").ToLower()) {
        'critical' { 3 }
        'high'     { 2 }
        'medium'   { 1 }
        'none'     { 99 }  # threshold 'none' = warn-only (nothing reaches it)
        default    { 0 }
    }
}

function Get-HooksBuildInfo {
    # Full version identity. Precedence: build-info.json (installed/packaged) -> live git (dev) -> fallback.
    $root = Get-AiHooksRoot
    $biPath = Join-Path $root 'build-info.json'
    if (Test-Path $biPath) {
        try {
            $bi = Get-Content $biPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($bi.version) { return $bi }
        } catch { }
    }
    $base = '0.0'
    $vf = Join-Path $root 'VERSION'
    if (Test-Path $vf) { $l = (Get-Content $vf | Select-Object -First 1); if ($l) { $base = $l.Trim() } }
    $commit = 'unknown'; $count = 0
    try {
        $sha = (& git -C $root rev-parse --short HEAD 2>$null)
        $cnt = (& git -C $root rev-list --count HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $sha) { $commit = "$sha".Trim(); if ($cnt) { $count = [int]("$cnt".Trim()) } }
    } catch { }
    $version = if ($commit -eq 'unknown') { "$base.0+gunknown" } else { "$base.$count+g$commit" }
    return [pscustomobject]@{ version = $version; base = $base; commit = $commit; commitCount = $count; buildDate = '' }
}

function Get-HooksVersion {
    return (Get-HooksBuildInfo).version
}

function Get-RedactedText {
    param([string]$Text)
    if (-not $Text) { return '[REDACTED]' }
    $t = $Text.Trim()
    if ($t.Length -le 12) { return '[REDACTED]' }
    return $t.Substring(0, 4) + '...' + $t.Substring($t.Length - 4)
}

function Get-UserHash {
    param($Settings)
    $email = $Settings.identity.email
    if ([string]::IsNullOrWhiteSpace($email)) { $email = "$($env:USERNAME)@local" }
    return Get-ShortHash ($email + $Settings.identity.salt)
}

function Get-UserEmail {
    # Clear-text identity (identity.mode = email): settings -> git global user.email -> USERNAME@local
    param($Settings)
    $email = [string]$Settings.identity.email
    if ([string]::IsNullOrWhiteSpace($email)) { $email = Invoke-NativeQuiet 'git' @('config', '--global', 'user.email') }
    if ([string]::IsNullOrWhiteSpace($email)) { $email = "$($env:USERNAME)@local" }
    return $email.Trim().ToLower()
}

function ConvertTo-RepoName {
    # git remote URL -> "org/repo" (GitHub) or "project/repo" (Azure DevOps)
    param([string]$Url)
    $u = $Url.Trim() -replace '\.git$', ''
    $u = $u -replace '^[^@/]+@([^:/]+):', '$1/'   # scp-like: git@github.com:org/repo
    $parts = @($u -split '[/\\]' | Where-Object { $_ -and $_ -ne '_git' })
    if ($parts.Count -ge 2) { return ($parts[$parts.Count - 2] + '/' + $parts[$parts.Count - 1]) }
    if ($parts.Count -eq 1) { return $parts[0] }
    return ''
}

function Get-ProjectName {
    # Project of the session: git origin of the payload cwd -> folder name -> 'unknown'. Hashed if telemetry.projectMode = hash.
    param($Settings, [string]$Cwd)
    if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = (Get-Location).Path }
    $name = ''
    if (Test-Path -LiteralPath $Cwd) {
        $url = Invoke-NativeQuiet 'git' @('-C', $Cwd, 'remote', 'get-url', 'origin')
        if ($url) { $name = ConvertTo-RepoName $url }
    }
    if (-not $name) { $name = Split-Path -Leaf ($Cwd.TrimEnd('\', '/')) }
    if (-not $name) { return 'unknown' }
    if ("$($Settings.telemetry.projectMode)" -eq 'hash') { return Get-ShortHash ($name.ToLower() + $Settings.identity.salt) }
    return $name
}

function Get-CommonAttributes {
    # Attributes shared by every event: who, where, which session, which build.
    param($Settings, [string]$Agent, [string]$HooksVersion, [string]$SessionId, [string]$Project)
    $a = @{
        'pc.agent'         = $Agent
        'pc.user_hash'     = (Get-UserHash $Settings)
        'pc.hooks_version' = $HooksVersion
    }
    if ("$($Settings.identity.mode)" -eq 'email') { $a['pc.user'] = Get-UserEmail $Settings }
    if ($Project) { $a['pc.project'] = $Project }
    if ($SessionId) { $a['pc.session_id'] = $SessionId }
    return $a
}

function Read-StateFile {
    param($Settings, [string]$Name)
    $path = Join-Path $Settings.log.dir $Name
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Write-StateFile {
    param($Settings, [string]$Name, $Object)
    $dir = $Settings.log.dir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -Path (Join-Path $dir $Name) -Value ($Object | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8
}

function Test-UsageDuplicate {
    # True when the same key was already counted within telemetry.dedupeSeconds
    # (e.g. a /plugin:skill prompt followed by the Skill tool call for the same skill).
    param($Settings, [string]$Key)
    $window = [int]$Settings.telemetry.dedupeSeconds
    if ($window -le 0) { return $false }
    $now = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $live = @{}
    $state = Read-StateFile $Settings 'state-dedupe.json'
    if ($state) {
        foreach ($p in $state.PSObject.Properties) {
            if (($now - [long]$p.Value) -lt $window) { $live[$p.Name] = [long]$p.Value }
        }
    }
    $k = $Key.ToLower()
    if ($live.ContainsKey($k)) { return $true }
    $live[$k] = $now
    Write-StateFile $Settings 'state-dedupe.json' ([pscustomobject]$live)
    return $false
}

function Write-AiHooksLog {
    param(
        $Settings,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)]$Record
    )
    $dir = $Settings.log.dir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir $FileName
    Invoke-LogRotation -Path $path -MaxSizeMB ([int]$Settings.log.maxSizeMB) -MaxFiles ([int]$Settings.log.maxFiles)
    ($Record | ConvertTo-Json -Compress -Depth 8) | Add-Content -Path $path -Encoding UTF8
}

function Write-AiHooksError {
    param($Settings, [string]$Message, [string]$Agent, [string]$HooksVersion)
    $rec = [pscustomobject]@{
        ts      = (Get-Date).ToUniversalTime().ToString('o')
        event   = 'hook_issue'
        agent   = $Agent
        version = $HooksVersion
        error   = $Message
    }
    Write-AiHooksLog -Settings $Settings -FileName 'hooks-error.jsonl' -Record $rec
    if (Get-Command Send-OtelEvent -ErrorAction SilentlyContinue) {
        Send-OtelEvent -Settings $Settings -Name 'pc.ai.hook_issue' -Attributes @{
            'pc.agent'         = $Agent
            'pc.hooks_version' = $HooksVersion
            'pc.error'         = $Message
        }
    }
}
