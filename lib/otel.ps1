# lib/otel.ps1 - OTLP/HTTP (logs) sender with a local queue.
# Requires common.ps1 and logrotate.ps1 loaded first.
# otel.background = true (default) + an endpoint: events are only queued (no network in the hook path) and
# a detached 'dispatch -Event flush' worker sends the queue in batches. Otherwise: synchronous send, queue on failure.
# Queue line = one complete OTLP logRecord JSON (same schema as bash; legacy {ts,name,attributes} lines still accepted).

$script:OtelQueued = $false          # something was queued by this dispatch (the end-of-dispatch hook starts a worker)
$script:OtelWorkerStarted = $false

function Get-OtelSeverity {
    param([string]$Name)
    if ($Name -match 'policy_block|hook_issue') { return @('ERROR', 17) }
    if ($Name -match 'policy_warning') { return @('WARN', 13) }
    return @('INFO', 9)
}

function ConvertTo-OtlpAttributes {
    param([hashtable]$Attributes)
    $list = @()
    foreach ($k in $Attributes.Keys) {
        $list += @{ key = $k; value = @{ stringValue = [string]$Attributes[$k] } }
    }
    return , $list
}

function ConvertTo-OtlpRecordJson {
    # One OTLP logRecord as compact JSON (one queue line)
    param([string]$Name, [hashtable]$Attributes, [long]$TimeMs)
    $sev = Get-OtelSeverity $Name
    return (@{
        timeUnixNano   = ($TimeMs * 1000000).ToString()
        severityText   = $sev[0]
        severityNumber = $sev[1]
        body           = @{ stringValue = $Name }
        attributes     = (ConvertTo-OtlpAttributes -Attributes $Attributes)
    } | ConvertTo-Json -Depth 8 -Compress)
}

function ConvertFrom-QueueLine {
    # Queue line -> OTLP logRecord JSON ('' if unusable). Converts the legacy PowerShell schema {ts,name,attributes}.
    param([string]$Line)
    $l = $Line.Trim().TrimStart([char]0xFEFF)
    if (-not $l) { return '' }
    if ($l.Contains('"timeUnixNano"')) { return $l }
    try {
        $r = $l | ConvertFrom-Json
        $attrs = @{}
        if ($r.attributes) { foreach ($p in $r.attributes.PSObject.Properties) { $attrs[$p.Name] = $p.Value } }
        $ms = ([System.DateTimeOffset]$r.ts).ToUnixTimeMilliseconds()
        return (ConvertTo-OtlpRecordJson -Name ([string]$r.name) -Attributes $attrs -TimeMs $ms)
    } catch { return '' }
}

function Get-OtlpResourceJson {
    param($Settings)
    if (-not $script:OtelServiceVersion) { $script:OtelServiceVersion = Get-HooksVersion }
    $os = 'windows'
    if ((Get-Variable IsMacOS -ErrorAction SilentlyContinue) -and $IsMacOS) { $os = 'darwin' }
    elseif ((Get-Variable IsLinux -ErrorAction SilentlyContinue) -and $IsLinux) { $os = 'linux' }
    $hostName = [System.Environment]::MachineName
    $attrs = ConvertTo-OtlpAttributes -Attributes ([ordered]@{
        'service.name'    = 'pc-ai-hooks'
        'service.version' = $script:OtelServiceVersion
        'os.type'         = $os
        'host.name'       = $hostName
    })
    return (ConvertTo-Json -InputObject $attrs -Depth 5 -Compress)
}

function New-OtlpPayload {
    param($Settings, [string[]]$RecordJson)
    return '{"resourceLogs":[{"resource":{"attributes":' + (Get-OtlpResourceJson $Settings) +
        '},"scopeLogs":[{"scope":{"name":"pc-ai-hooks"},"logRecords":[' + ($RecordJson -join ',') + ']}]}]}'
}

function Get-OtelHeaders {
    # otel.headers (e.g. { "Authorization": "Bearer ..." }) -> hashtable
    param($Settings)
    $h = @{}
    if ($Settings.otel.PSObject.Properties['headers'] -and $Settings.otel.headers) {
        foreach ($p in $Settings.otel.headers.PSObject.Properties) { if ("$($p.Value)") { $h[$p.Name] = [string]$p.Value } }
    }
    return $h
}

function Invoke-OtlpPost {
    # POST an OTLP payload. Never throws. -> @{ ok; status; error; ms }
    param($Settings, [string]$Body, [int]$TimeoutSec = 5)
    $ProgressPreference = 'SilentlyContinue'   # the progress bar slows Invoke-WebRequest down on Windows PowerShell
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = @{ ok = $false; status = 0; error = ''; ms = 0 }
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri (([string]$Settings.otel.endpoint).TrimEnd('/') + '/v1/logs') `
            -ContentType 'application/json; charset=utf-8' -Headers (Get-OtelHeaders $Settings) `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($Body)) -TimeoutSec $TimeoutSec
        $res.status = [int]$r.StatusCode
        $res.ok = ($res.status -ge 200 -and $res.status -lt 300)
    } catch {
        $resp = $_.Exception.Response
        if ($resp) { try { $res.status = [int]$resp.StatusCode } catch { } }
        $res.error = $_.Exception.Message
    }
    $res.ms = [int]$sw.ElapsedMilliseconds
    return $res
}

function Test-OtelBackground {
    # Queue-only + detached worker? (needs an endpoint; without one there is nothing to send)
    param($Settings)
    return ([bool]$Settings.otel.enabled -and [bool]$Settings.otel.background -and
            -not [string]::IsNullOrWhiteSpace([string]$Settings.otel.endpoint))
}

function Send-OtelEvent {
    param(
        $Settings,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Attributes
    )
    Send-OtelEvents -Settings $Settings -Events @(@{ Name = $Name; Attributes = $Attributes })
}

function Send-OtelEvents {
    # Events: @(@{ Name = '...'; Attributes = @{...} }, ...). Background mode: queue only.
    # Synchronous mode: ONE OTLP request (a single timeout when the endpoint is down), queue on failure.
    param($Settings, [object[]]$Events)
    if (-not $Settings.otel.enabled -or -not $Events -or $Events.Count -eq 0) { return }
    $nowMs = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $lines = @($Events | ForEach-Object { ConvertTo-OtlpRecordJson -Name ([string]$_.Name) -Attributes $_.Attributes -TimeMs $nowMs })

    $endpoint = [string]$Settings.otel.endpoint
    if (-not (Test-OtelBackground $Settings) -and -not [string]::IsNullOrWhiteSpace($endpoint)) {
        $r = Invoke-OtlpPost -Settings $Settings -Body (New-OtlpPayload $Settings $lines) -TimeoutSec 3
        if ($r.ok) { return }
        # no network or endpoint down -> fall back to local queue
    }
    Add-OtelQueue -Settings $Settings -Lines $lines
}

function Get-QueuePath { param($Settings) return (Join-Path $Settings.log.dir 'telemetry-queue.jsonl') }

function Add-AtomicCount {
    # Adds N to a small integer state file (e.g. records dropped by queue rotation)
    param($Settings, [string]$Name, [long]$Delta)
    $path = Join-Path $Settings.log.dir $Name
    $n = 0
    if (Test-Path $path) { try { $n = [long]((Get-Content $path -Raw).Trim()) } catch { } }
    Set-Content -Path $path -Value ([string]($n + $Delta)) -Encoding ASCII
}

function Add-OtelQueue {
    param($Settings, [string[]]$Lines)
    $dir = $Settings.log.dir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Get-QueuePath $Settings
    # Bounded queue: telemetry-queue.jsonl -> .1 -> dropped (counted, reported on the next successful flush)
    if ((Test-Path $path) -and (Get-Item $path).Length -ge ([double]$Settings.otel.queueMaxSizeMB * 1MB)) {
        $old = "$path.1"
        if (Test-Path $old) {
            $lost = @(Get-Content $old | Where-Object { $_.Trim() }).Count
            if ($lost -gt 0) { Add-AtomicCount $Settings 'state-dropped.txt' $lost }
            Remove-Item $old -Force -ErrorAction SilentlyContinue
        }
        Move-Item $path $old -Force -ErrorAction SilentlyContinue
    }
    $text = (($Lines | Where-Object { $_ }) -join "`n") + "`n"
    $enc = New-Object System.Text.UTF8Encoding $false
    for ($i = 0; $i -lt 5; $i++) {
        # a concurrent hook may hold the file for a few ms
        try { [System.IO.File]::AppendAllText($path, $text, $enc); break } catch { Start-Sleep -Milliseconds 40 }
    }
    $script:OtelQueued = $true
}

function Get-OtelQueueInfo {
    param($Settings)
    $dir = $Settings.log.dir
    $files = @()
    if (Test-Path $dir) {
        $files = @(Get-ChildItem $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^telemetry-queue(\.jsonl(\.1)?|\.sending-.*\.jsonl)$' })
    }
    $lines = 0
    foreach ($f in $files) { $lines += @(Get-Content $f.FullName | Where-Object { $_.Trim() }).Count }
    return @{ files = $files.Count; records = $lines }
}

function Enter-FlushLock {
    # Only one flush at a time; a lock older than 120 s is considered stale (crashed worker).
    param($Settings)
    $lock = Join-Path $Settings.log.dir 'flush.lock'
    for ($try = 0; $try -lt 2; $try++) {
        try {
            $fs = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            $b = [System.Text.Encoding]::ASCII.GetBytes("$PID $([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds())")
            $fs.Write($b, 0, $b.Length); $fs.Close()
            return $true
        } catch {
            $item = Get-Item $lock -ErrorAction SilentlyContinue
            if ($item -and ((Get-Date) - $item.LastWriteTime).TotalSeconds -lt 120) { return $false }
            Remove-Item $lock -Force -ErrorAction SilentlyContinue
        }
    }
    return $false
}

function Invoke-OtelQueueFlush {
    # Sends the queue in batches of otel.flushBatchSize. A sent batch is gone; on the first failure the rest
    # stays in a telemetry-queue.sending-*.jsonl file that the next flush retries first. -> result hashtable
    param($Settings)
    $result = @{ ok = $true; sent = 0; pending = 0; status = 0; error = ''; skipped = '' }
    $endpoint = [string]$Settings.otel.endpoint
    if (-not $Settings.otel.enabled -or [string]::IsNullOrWhiteSpace($endpoint)) { $result.skipped = 'no endpoint'; return $result }
    $dir = $Settings.log.dir
    if (-not (Test-Path $dir)) { $result.skipped = 'empty'; return $result }
    if (-not (Enter-FlushLock $Settings)) { $result.skipped = 'locked'; return $result }
    try {
        $path = Get-QueuePath $Settings
        $i = 0
        foreach ($src in @("$path.1", $path)) {
            # Atomic move: hooks keep appending to a fresh queue while this batch is sent
            if (Test-Path $src) {
                $i++
                try { Move-Item $src (Join-Path $dir ('telemetry-queue.sending-{0}-{1}.jsonl' -f [DateTime]::UtcNow.Ticks, $i)) -ErrorAction Stop } catch { }
            }
        }
        $batchSize = [Math]::Max(1, [int]$Settings.otel.flushBatchSize)
        $failed = $false
        foreach ($f in @(Get-ChildItem $dir -File -Filter 'telemetry-queue.sending-*.jsonl' | Sort-Object Name)) {
            $lines = @(Get-Content $f.FullName -Encoding UTF8 | ForEach-Object { ConvertFrom-QueueLine $_ } | Where-Object { $_ })
            for ($s = 0; $s -lt $lines.Count; $s += $batchSize) {
                $chunk = $lines[$s..([Math]::Min($s + $batchSize, $lines.Count) - 1)]
                $r = Invoke-OtlpPost -Settings $Settings -Body (New-OtlpPayload $Settings $chunk) -TimeoutSec 10
                $result.status = $r.status
                if (-not $r.ok) {
                    $rest = $lines[$s..($lines.Count - 1)]
                    [System.IO.File]::WriteAllText($f.FullName, (($rest -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
                    $result.ok = $false; $result.error = if ($r.error) { $r.error } else { "HTTP $($r.status)" }
                    $result.pending = $rest.Count
                    $failed = $true
                    break
                }
                $result.sent += $chunk.Count
            }
            if ($failed) { break }
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        }

        # Report records lost to queue rotation (once the endpoint is reachable again)
        $droppedPath = Join-Path $dir 'state-dropped.txt'
        if (-not $failed -and (Test-Path $droppedPath)) {
            $n = 0; try { $n = [long]((Get-Content $droppedPath -Raw).Trim()) } catch { }
            if ($n -gt 0) {
                $attrs = @{ 'pc.error' = "telemetry queue full: $n records dropped"; 'pc.dropped' = [string]$n }
                if ($script:common) { foreach ($k in $script:common.Keys) { if (-not $attrs.ContainsKey($k)) { $attrs[$k] = $script:common[$k] } } }
                $rec = ConvertTo-OtlpRecordJson -Name 'pc.ai.hook_issue' -Attributes $attrs -TimeMs ([System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
                if ((Invoke-OtlpPost -Settings $Settings -Body (New-OtlpPayload $Settings @($rec)) -TimeoutSec 10).ok) {
                    Remove-Item $droppedPath -Force -ErrorAction SilentlyContinue
                    $result.sent++
                }
            } else { Remove-Item $droppedPath -Force -ErrorAction SilentlyContinue }
        }

        $now = (Get-Date).ToUniversalTime().ToString('o')
        $st = Read-StateFile $Settings 'state-flush.json'
        $state = [ordered]@{
            lastAttempt = $now
            lastSuccess = if ($result.sent -gt 0 -or $result.ok) { $now } elseif ($st) { $st.lastSuccess } else { '' }
            lastError   = if ($result.ok) { '' } else { $result.error }
            lastStatus  = $result.status
            lastSent    = $result.sent
        }
        Write-StateFile $Settings 'state-flush.json' ([pscustomobject]$state)
    } finally {
        Remove-Item (Join-Path $dir 'flush.lock') -Force -ErrorAction SilentlyContinue
    }
    return $result
}

function Start-OtelWorker {
    # Detached, hidden 'dispatch -Event <event>' process: the hook returns without waiting for the network.
    param($Settings, [string]$Event = 'flush', [string]$Agent = 'unknown')
    if ($script:OtelWorkerStarted) { return }
    $script:OtelWorkerStarted = $true
    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) { $exe = 'powershell' }
    $dispatch = Join-Path (Get-AiHooksRoot) 'dispatch.ps1'
    try {
        Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$dispatch`"", '-Event', $Event, '-Agent', $Agent) | Out-Null
    } catch { }
}

function Complete-OtelDispatch {
    # End of every hook run (background mode): start a flush worker when something was queued now,
    # or when an older queue is waiting and the last attempt is older than otel.retryMinutes.
    param($Settings, [string]$Agent)
    if (-not (Test-OtelBackground $Settings) -or $script:OtelWorkerStarted) { return }
    $want = $script:OtelQueued
    if (-not $want) {
        $dir = $Settings.log.dir
        $pending = (Test-Path (Get-QueuePath $Settings)) -or
                   [bool](Get-ChildItem $dir -File -Filter 'telemetry-queue.sending-*.jsonl' -ErrorAction SilentlyContinue)
        if ($pending) {
            $st = Read-StateFile $Settings 'state-flush.json'
            $last = $null
            if ($st -and $st.lastAttempt) { try { $last = ([DateTime]$st.lastAttempt).ToUniversalTime() } catch { } }
            $want = (-not $last) -or (((Get-Date).ToUniversalTime() - $last).TotalMinutes -ge [double]$Settings.otel.retryMinutes)
        }
    }
    if ($want) { Start-OtelWorker -Settings $Settings -Event 'flush' -Agent $Agent }
}
