# lib/otel.ps1 - OTLP/HTTP (logs) sender with local queue when network/endpoint is unavailable
# Requires common.ps1 and logrotate.ps1 loaded first.

function ConvertTo-OtlpAttributes {
    param([hashtable]$Attributes)
    $list = @()
    foreach ($k in $Attributes.Keys) {
        $list += @{ key = $k; value = @{ stringValue = [string]$Attributes[$k] } }
    }
    return , $list
}

function Send-OtelEvent {
    param(
        $Settings,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Attributes
    )
    if (-not $Settings.otel.enabled) { return }
    $endpoint = [string]$Settings.otel.endpoint

    if (-not [string]::IsNullOrWhiteSpace($endpoint)) {
        $record = @{
            timeUnixNano = ([System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000000).ToString()
            severityText = 'WARN'
            body         = @{ stringValue = $Name }
            attributes   = (ConvertTo-OtlpAttributes -Attributes $Attributes)
        }
        $payload = @{
            resourceLogs = @(@{
                resource  = @{ attributes = @(@{ key = 'service.name'; value = @{ stringValue = 'pc-ai-hooks' } }) }
                scopeLogs = @(@{ logRecords = @($record) })
            })
        } | ConvertTo-Json -Depth 15 -Compress
        try {
            Invoke-RestMethod -Method Post -Uri ($endpoint.TrimEnd('/') + '/v1/logs') `
                -ContentType 'application/json' -Body $payload -TimeoutSec 3 | Out-Null
            return
        } catch {
            # no network or endpoint down -> fall back to local queue
        }
    }
    Add-OtelQueue -Settings $Settings -Record ([pscustomobject]@{
        ts         = (Get-Date).ToUniversalTime().ToString('o')
        name       = $Name
        attributes = $Attributes
    })
}

function Add-OtelQueue {
    param($Settings, $Record)
    $dir = $Settings.log.dir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'telemetry-queue.jsonl'
    Invoke-LogRotation -Path $path -MaxSizeMB ([int]$Settings.otel.queueMaxSizeMB) -MaxFiles 2
    ($Record | ConvertTo-Json -Compress -Depth 8) | Add-Content -Path $path -Encoding UTF8
}

function Invoke-OtelQueueFlush {
    param($Settings)
    $endpoint = [string]$Settings.otel.endpoint
    if (-not $Settings.otel.enabled -or [string]::IsNullOrWhiteSpace($endpoint)) { return }
    $path = Join-Path $Settings.log.dir 'telemetry-queue.jsonl'
    if (-not (Test-Path $path)) { return }

    $records = @()
    foreach ($line in (Get-Content $path -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $records += ($line | ConvertFrom-Json) } catch { }
    }
    if ($records.Count -eq 0) { Remove-Item $path -Force -ErrorAction SilentlyContinue; return }

    $logRecords = @()
    foreach ($r in $records) {
        $attrs = @{}
        if ($r.attributes) {
            foreach ($p in $r.attributes.PSObject.Properties) { $attrs[$p.Name] = $p.Value }
        }
        $logRecords += @{
            timeUnixNano = ([System.DateTimeOffset]::Parse($r.ts).ToUnixTimeMilliseconds() * 1000000).ToString()
            severityText = 'WARN'
            body         = @{ stringValue = [string]$r.name }
            attributes   = (ConvertTo-OtlpAttributes -Attributes $attrs)
        }
    }
    $payload = @{
        resourceLogs = @(@{
            resource  = @{ attributes = @(@{ key = 'service.name'; value = @{ stringValue = 'pc-ai-hooks' } }) }
            scopeLogs = @(@{ logRecords = $logRecords })
        })
    } | ConvertTo-Json -Depth 15 -Compress
    try {
        Invoke-RestMethod -Method Post -Uri ($endpoint.TrimEnd('/') + '/v1/logs') `
            -ContentType 'application/json' -Body $payload -TimeoutSec 5 | Out-Null
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    } catch {
        # will retry on the next sessionEnd
    }
}
