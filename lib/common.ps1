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
    if (-not ($s.PSObject.Properties['skills'])) {
        $s | Add-Member -NotePropertyName skills -NotePropertyValue ([pscustomobject]@{ orgPluginPrefix = 'pc-' }) -Force
    } elseif ([string]::IsNullOrWhiteSpace($s.skills.orgPluginPrefix)) {
        $s.skills | Add-Member -NotePropertyName orgPluginPrefix -NotePropertyValue 'pc-' -Force
    }
    return $s
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
    $raw = $email + $Settings.identity.salt
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 16).ToLower()
    } finally { $sha.Dispose() }
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
