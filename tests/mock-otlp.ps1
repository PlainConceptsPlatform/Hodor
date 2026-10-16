# tests/mock-otlp.ps1 - in-process OTLP/HTTP mock for tests/run.ps1 (dependency-free: HttpListener in a runspace).
# Every request is appended to <dir>/requests.jsonl as {code, auth, body}.
# Response code from <dir>/mode.txt: '200' / '500' / ... (default 200), or 'okleft N' = N more 200s, then 500.

function Start-MockOtlp {
    param([string]$Dir)
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $tcp = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $tcp.Start(); $port = $tcp.LocalEndpoint.Port; $tcp.Stop()
    $state = [hashtable]::Synchronized(@{})
    $ps = [powershell]::Create()
    $null = $ps.AddScript({
        param($Prefix, $Dir, $State)
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add($Prefix)
        $l.Start()
        $State.listener = $l
        $modePath = Join-Path $Dir 'mode.txt'
        while ($l.IsListening) {
            try { $ctx = $l.GetContext() } catch { break }   # Stop-MockOtlp closes the listener
            $body = (New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)).ReadToEnd()
            $mode = if (Test-Path $modePath) { (Get-Content $modePath -Raw).Trim() } else { '200' }
            $code = 200
            if ($mode -match '^okleft (\d+)$') {
                $left = [int]$Matches[1]
                if ($left -gt 0) { Set-Content $modePath "okleft $($left - 1)" } else { $code = 500 }
            } elseif ($mode -match '^(\d{3})$') { $code = [int]$Matches[1] }
            $rec = @{ code = $code; auth = [string]$ctx.Request.Headers['Authorization']; body = $body } | ConvertTo-Json -Compress -Depth 3
            [System.IO.File]::AppendAllText((Join-Path $Dir 'requests.jsonl'), $rec + "`n")
            $ctx.Response.StatusCode = $code
            $b = [System.Text.Encoding]::UTF8.GetBytes('{}')
            $ctx.Response.OutputStream.Write($b, 0, $b.Length)
            $ctx.Response.Close()
        }
    }).AddArgument("http://localhost:$port/").AddArgument($Dir).AddArgument($state)
    $handle = $ps.BeginInvoke()
    Start-Sleep -Milliseconds 300
    return @{ ps = $ps; handle = $handle; state = $state; port = $port; dir = $Dir; endpoint = "http://localhost:$port" }
}

function Stop-MockOtlp {
    # The listener thread blocks in GetContext() and keeps pwsh alive after 'exit': close it explicitly.
    param($Mock)
    if (-not $Mock) { return }
    try { if ($Mock.state.listener) { $Mock.state.listener.Close() } } catch { }
    try { $null = $Mock.handle.AsyncWaitHandle.WaitOne(5000) } catch { }
    try { $Mock.ps.Dispose() } catch { }
}

function Reset-MockOtlp {
    param($Mock, [string]$Mode = '200')
    Remove-Item (Join-Path $Mock.dir 'requests.jsonl') -Force -ErrorAction SilentlyContinue
    Set-Content (Join-Path $Mock.dir 'mode.txt') $Mode
}

function Get-MockRequests {
    param($Mock)
    $p = Join-Path $Mock.dir 'requests.jsonl'
    if (-not (Test-Path $p)) { return @() }
    return @(Get-Content $p | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}
