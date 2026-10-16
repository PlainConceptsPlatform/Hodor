# tests/run.ps1 - dependency-free regression suite (PowerShell side).
# Runs the shared contract fixtures (tests/cases/*) against dispatch.ps1 in isolation
# (temp log dir + temp settings via AIHOOKS_SETTINGS), plus direct unit checks.
# Exit code 1 if any check fails.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'lib\logrotate.ps1')
. (Join-Path $Root 'lib\common.ps1')
$dispatch = Join-Path $Root 'dispatch.ps1'
$casesDir = Join-Path $PSScriptRoot 'cases'
$psExe = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('hodor-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$logDir = Join-Path $work 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$settingsFile = Join-Path $work 'settings.json'
$logDirFwd = ($logDir -replace '\\', '/')
$baseSettings = '{"otel":{"enabled":true,"endpoint":"","queueMaxSizeMB":2},"log":{"dir":"__LOGDIR__","maxSizeMB":5,"maxFiles":3},"identity":{"email":"test@local","salt":"TEST"},"skills":{"orgPluginPrefix":"pc-"}}'

# Fake ~/.claude and ~/.copilot (a pc-demo plugin, personal skills/commands) so tests never read the real homes.
$fixtures = Join-Path $work 'fixtures'
Copy-Item (Join-Path $PSScriptRoot 'fixtures') $fixtures -Recurse
$ip = Join-Path $fixtures 'claude-home/plugins/installed_plugins.json'
Set-Content -Path $ip -Value ((Get-Content $ip -Raw).Replace('__FIXTURES__', ($fixtures -replace '\\', '/'))) -Encoding UTF8
$env:AIHOOKS_CLAUDE_HOME = Join-Path $fixtures 'claude-home'
$env:AIHOOKS_COPILOT_HOME = Join-Path $fixtures 'copilot-home'

$script:pass = 0; $script:fail = 0
function Ok($n)   { Write-Host "  PASS  $n" -ForegroundColor Green; $script:pass++ }
function Bad($n, $d) { Write-Host "  FAIL  $n" -ForegroundColor Red; if ($d) { Write-Host "        $d" -ForegroundColor DarkYellow }; $script:fail++ }

function Read-Text($path) {
    if (Test-Path $path) { $c = Get-Content $path -Raw -Encoding UTF8; if ($null -ne $c) { return $c } }
    return ''
}

function Invoke-Dispatch($ev, $ag, $payloadFile, $outF, $errF) {
    $p = Start-Process -FilePath $psExe `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dispatch, '-Event', $ev, '-Agent', $ag) `
        -RedirectStandardInput $payloadFile -RedirectStandardOutput $outF -RedirectStandardError $errF `
        -PassThru -Wait -NoNewWindow
    return $p.ExitCode
}
function Count-In($text, $needle) { return ([regex]::Matches([string]$text, [regex]::Escape($needle))).Count }

Write-Host "`n== Contract fixtures =="
foreach ($case in (Get-ChildItem $casesDir -Directory | Sort-Object Name)) {
    $name = $case.Name
    # Effective settings: per-case override or base template, with the temp log dir injected.
    $tmplPath = Join-Path $case.FullName 'settings.json'
    $tmpl = if (Test-Path $tmplPath) { Get-Content $tmplPath -Raw -Encoding UTF8 } else { $baseSettings }
    Set-Content -Path $settingsFile -Value ($tmpl.Replace('__LOGDIR__', $logDirFwd)) -Encoding UTF8
    $env:AIHOOKS_SETTINGS = $settingsFile

    # Fresh log dir per case
    Get-ChildItem $logDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    $cmd = ((Get-Content (Join-Path $case.FullName 'cmd') | Select-Object -First 1).Trim() -split '\s+')
    $ev = $cmd[0]; $ag = if ($cmd.Count -gt 1) { $cmd[1] } else { 'test' }
    $payloadFile = Join-Path $case.FullName 'payload.json'
    $outF = Join-Path $work 'out.txt'; $errF = Join-Path $work 'err.txt'

    $exit = Invoke-Dispatch $ev $ag $payloadFile $outF $errF
    $ctx = @{
        stdout    = (Read-Text $outF)
        stderr    = (Read-Text $errF)
        seclog    = (Read-Text (Join-Path $logDir 'security.jsonl'))
        telemetry = (Read-Text (Join-Path $logDir 'telemetry-queue.jsonl'))
    }

    foreach ($line in (Get-Content (Join-Path $case.FullName 'expect'))) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $sp = $t -split '\s+', 2
        $dir = $sp[0]
        if ($dir -eq 'exit') {
            if ($exit -eq [int]$sp[1]) { Ok "$name : exit $($sp[1])" } else { Bad "$name : exit $($sp[1])" "got $exit" }
        }
        elseif ($dir -eq 'stdout_empty') {
            if ([string]::IsNullOrWhiteSpace($ctx.stdout)) { Ok "$name : stdout empty" } else { Bad "$name : stdout empty" $ctx.stdout }
        }
        else {
            $m = [regex]::Match($sp[1], '^(!?~)\s+(.*)$')
            $op = $m.Groups[1].Value; $operand = $m.Groups[2].Value
            $hay = [string]($ctx[$dir])
            $has = $hay.Contains($operand)
            $want = ($op -eq '~')
            if ($has -eq $want) { Ok "$name : $dir $op $operand" }
            else { Bad "$name : $dir $op $operand" ("present=$has") }
        }
    }
}

Write-Host "`n== Multi-run checks (dedupe, inventory throttle) =="
Set-Content -Path $settingsFile -Value ($baseSettings.Replace('__LOGDIR__', $logDirFwd)) -Encoding UTF8
$env:AIHOOKS_SETTINGS = $settingsFile
$queuePath = Join-Path $logDir 'telemetry-queue.jsonl'
$outF = Join-Path $work 'out.txt'; $errF = Join-Path $work 'err.txt'
function New-Payload($json) { $f = Join-Path $work ('p-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json'); [System.IO.File]::WriteAllText($f, $json); return $f }

Get-ChildItem $logDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
$pPrompt = New-Payload '{"prompt":"/pc-demo:deploy to staging","session_id":"dd-1"}'
$pTool = New-Payload '{"tool_name":"Skill","tool_input":{"skill":"pc-demo:deploy"},"session_id":"dd-1"}'
$pOther = New-Payload '{"tool_name":"Skill","tool_input":{"skill":"pc-demo:deploy"},"session_id":"dd-2"}'
Invoke-Dispatch 'UserPromptSubmit' 'claude-code' $pPrompt $outF $errF | Out-Null
Invoke-Dispatch 'PreToolUse' 'claude-code' $pTool $outF $errF | Out-Null
$n = Count-In (Read-Text $queuePath) 'pc.ai.skill_usage'
if ($n -eq 1) { Ok 'dedupe: /cmd prompt + Skill tool in same session = 1 use' } else { Bad 'dedupe: same session = 1 use' "got $n" }
Invoke-Dispatch 'PreToolUse' 'claude-code' $pOther $outF $errF | Out-Null
$n = Count-In (Read-Text $queuePath) 'pc.ai.skill_usage'
if ($n -eq 2) { Ok 'dedupe: another session counts again' } else { Bad 'dedupe: another session counts again' "got $n" }

Get-ChildItem $logDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
$repoDir = Join-Path $work 'my-folder'
New-Item -ItemType Directory -Force -Path $repoDir | Out-Null
& git -C $repoDir init -q 2>$null | Out-Null
& git -C $repoDir remote add origin 'https://github.com/owner/NombreRepo.git' 2>$null | Out-Null
$pRepo = New-Payload ('{"tool_name":"Skill","tool_input":{"skill":"pc-demo:deploy"},"session_id":"prj-1","cwd":"' + ($repoDir -replace '\\', '/') + '"}')
Invoke-Dispatch 'PreToolUse' 'claude-code' $pRepo $outF $errF | Out-Null
$q = Read-Text $queuePath
if ($q.Contains('owner/NombreRepo') -and $q.Contains('my-folder')) { Ok 'project: git origin -> pc.project, folder -> pc.folder' } else { Bad 'project from git origin' $q }

Get-ChildItem $logDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
$pStart = New-Payload '{"session_id":"inv-1"}'
Invoke-Dispatch 'SessionStart' 'claude-code' $pStart $outF $errF | Out-Null
$first = Count-In (Read-Text $queuePath) 'pc.ai.inventory'
Invoke-Dispatch 'SessionStart' 'claude-code' $pStart $outF $errF | Out-Null
$second = Count-In (Read-Text $queuePath) 'pc.ai.inventory'
if ($first -ge 3 -and $second -eq $first) { Ok "inventory: sent once ($first records), throttled on the next session" } else { Bad 'inventory throttle' "first=$first second=$second" }
New-Item -ItemType Directory -Force -Path (Join-Path $fixtures 'claude-home/skills/new-skill') | Out-Null
Set-Content (Join-Path $fixtures 'claude-home/skills/new-skill/SKILL.md') "---`nname: new-skill`n---" -Encoding UTF8
Invoke-Dispatch 'SessionStart' 'claude-code' $pStart $outF $errF | Out-Null
$third = Count-In (Read-Text $queuePath) 'pc.ai.inventory'
if ($third -gt $second) { Ok 'inventory: resent when what is installed changes' } else { Bad 'inventory: resent on change' "second=$second third=$third" }
Remove-Item (Join-Path $fixtures 'claude-home/skills/new-skill') -Recurse -Force
$env:AIHOOKS_SETTINGS = $null

Write-Host "`n== Sending (mock OTLP collector) =="
. (Join-Path $Root 'lib\otel.ps1')
. (Join-Path $PSScriptRoot 'mock-otlp.ps1')
$mock = Start-MockOtlp -Dir (Join-Path $work 'mock')
$empty = Join-Path $work 'empty.txt'; Set-Content $empty '' -NoNewline
function Set-SendSettings($endpoint, [string]$extra = '', [string]$dir = $logDirFwd) {
    $json = '{"otel":{"enabled":true,"endpoint":"' + $endpoint + '","queueMaxSizeMB":2' + $extra + '},' +
        '"log":{"dir":"' + $dir + '","maxSizeMB":5,"maxFiles":3},"identity":{"email":"test@local","salt":"TEST"},"skills":{"orgPluginPrefix":"pc-"}}'
    Set-Content -Path $settingsFile -Value $json -Encoding UTF8
    $env:AIHOOKS_SETTINGS = $settingsFile
    return ($json | ConvertFrom-Json)
}
function Write-QueueRecords($n, [string]$name = 'pc.ai.skill_usage') {
    $ms = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $lines = 1..$n | ForEach-Object { ConvertTo-OtlpRecordJson -Name $name -Attributes @{ 'pc.skill' = "s$_" } -TimeMs $ms }
    [System.IO.File]::WriteAllText($queuePath, (($lines -join "`n") + "`n"))
}
function Get-QueueFiles { return @(Get-ChildItem $logDir -File -Filter 'telemetry-queue*' -ErrorAction SilentlyContinue) }

# selftest: OK against the mock, headers sent, severity + resource attributes in the payload
Get-ChildItem $logDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
Reset-MockOtlp $mock
Set-SendSettings $mock.endpoint ',"background":false,"headers":{"Authorization":"Bearer t0k3n"}' | Out-Null
$code = Invoke-Dispatch 'selftest' 'test' $empty $outF $errF
$req = @(Get-MockRequests $mock)
$out = Read-Text $outF
if ($code -eq 0 -and $out.Contains('"ok":true') -and $out.Contains('Authorization') -and -not $out.Contains('t0k3n')) { Ok 'selftest: ok against the collector (header names only)' } else { Bad 'selftest: ok' "exit=$code $out" }
if ($req.Count -eq 1 -and $req[0].auth -eq 'Bearer t0k3n') { Ok 'selftest: Authorization header sent' } else { Bad 'selftest: header' ($req | ConvertTo-Json -Compress) }
$b = if ($req.Count) { $req[0].body } else { '' }
if ($b.Contains('pc.ai.selftest') -and $b.Contains('"severityNumber":9') -and $b.Contains('service.version') -and $b.Contains('host.name') -and $b.Contains('os.type')) { Ok 'payload: severity + resource attributes' } else { Bad 'payload: severity + resource' $b }

# selftest: endpoint down -> ok false, exit 1
Set-SendSettings 'http://localhost:1' ',"background":false' | Out-Null
$code = Invoke-Dispatch 'selftest' 'test' $empty $outF $errF
if ($code -eq 1 -and (Read-Text $outF).Contains('"ok":false')) { Ok 'selftest: endpoint down -> ok false, exit 1' } else { Bad 'selftest: endpoint down' "exit=$code $(Read-Text $outF)" }

# flush: 450 records, batches of 200 -> 3 requests, queue gone
Get-ChildItem $logDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
Reset-MockOtlp $mock
Set-SendSettings $mock.endpoint ',"background":false,"flushBatchSize":200' | Out-Null
Write-QueueRecords 450
$code = Invoke-Dispatch 'flush' 'test' $empty $outF $errF
$req = @(Get-MockRequests $mock)
if ($req.Count -eq 3 -and (Get-QueueFiles).Count -eq 0 -and (Read-Text $outF).Contains('"sent":450')) { Ok 'flush: 450 records in 3 batches, queue emptied' } else { Bad 'flush: batches' "requests=$($req.Count) files=$((Get-QueueFiles).Count) $(Read-Text $outF)" }

# flush: second batch fails -> first stays sent, the rest is kept and retried first next time
Get-ChildItem $logDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
Reset-MockOtlp $mock 'okleft 1'
Write-QueueRecords 450
Invoke-Dispatch 'flush' 'test' $empty $outF $errF | Out-Null
$pending = @(Get-ChildItem $logDir -File -Filter 'telemetry-queue.sending-*.jsonl')
$left = if ($pending.Count) { @(Get-Content $pending[0].FullName | Where-Object { $_ }).Count } else { 0 }
if ((Read-Text $outF).Contains('"sent":200') -and $left -eq 250) { Ok 'flush: failure keeps only the unsent records (250)' } else { Bad 'flush: partial failure' "left=$left $(Read-Text $outF)" }
Reset-MockOtlp $mock
Invoke-Dispatch 'flush' 'test' $empty $outF $errF | Out-Null
if ((Get-QueueFiles).Count -eq 0 -and @(Get-MockRequests $mock).Count -eq 2) { Ok 'flush: pending records retried and sent' } else { Bad 'flush: retry' "files=$((Get-QueueFiles).Count)" }

# legacy PowerShell queue lines {ts,name,attributes} are converted to OTLP records
Get-ChildItem $logDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
Reset-MockOtlp $mock
Set-Content $queuePath '{"ts":"2026-01-02T03:04:05.0000000Z","name":"pc.ai.skill_usage","attributes":{"pc.skill":"legacy-skill"}}' -Encoding UTF8
Invoke-Dispatch 'flush' 'test' $empty $outF $errF | Out-Null
$b = (@(Get-MockRequests $mock) | Select-Object -First 1).body
if ($b -and $b.Contains('legacy-skill') -and $b.Contains('"timeUnixNano":"1767323045000000000"')) { Ok 'flush: legacy queue line converted (original time kept)' } else { Bad 'flush: legacy line' $b }

# lock: a fresh lock skips the flush; a stale one (crashed worker) does not
Get-ChildItem $logDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
Reset-MockOtlp $mock
Write-QueueRecords 3
Set-Content (Join-Path $logDir 'flush.lock') '1 1'
Invoke-Dispatch 'flush' 'test' $empty $outF $errF | Out-Null
if ((Read-Text $outF).Contains('locked') -and @(Get-MockRequests $mock).Count -eq 0) { Ok 'flush: concurrent flush skipped (lock)' } else { Bad 'flush: lock' (Read-Text $outF) }
(Get-Item (Join-Path $logDir 'flush.lock')).LastWriteTime = (Get-Date).AddMinutes(-5)
Invoke-Dispatch 'flush' 'test' $empty $outF $errF | Out-Null
if ((Read-Text $outF).Contains('"sent":3')) { Ok 'flush: stale lock ignored' } else { Bad 'flush: stale lock' (Read-Text $outF) }

# records dropped by queue rotation are counted and reported on the next successful flush
Get-ChildItem $logDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
Reset-MockOtlp $mock
$tiny = Set-SendSettings '' ',"queueMaxSizeMB":0.0005'
$tiny.otel.queueMaxSizeMB = 0.0005
$tiny.log.dir = $logDir
1..12 | ForEach-Object { Add-OtelQueue -Settings $tiny -Lines @((ConvertTo-OtlpRecordJson -Name 'pc.ai.skill_usage' -Attributes @{ 'pc.skill' = "r$_" } -TimeMs 0)) }
$dropped = [int]((Read-Text (Join-Path $logDir 'state-dropped.txt')).Trim())
if ($dropped -gt 0) { Ok "queue rotation: $dropped dropped records counted" } else { Bad 'queue rotation: dropped count' 'state-dropped.txt missing' }
Set-SendSettings $mock.endpoint ',"background":false' | Out-Null
Invoke-Dispatch 'flush' 'test' $empty $outF $errF | Out-Null
$all = (@(Get-MockRequests $mock) | ForEach-Object { $_.body }) -join "`n"
if ($all.Contains('pc.dropped') -and $all.Contains("""stringValue"":""$dropped""") -and -not (Test-Path (Join-Path $logDir 'state-dropped.txt'))) { Ok 'queue rotation: pc.dropped reported, counter reset' } else { Bad 'queue rotation: report' $all }

# background: the hook only queues; a detached worker delivers it
Get-ChildItem $logDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
Reset-MockOtlp $mock
Set-SendSettings $mock.endpoint ',"background":true' | Out-Null
$pBg = New-Payload '{"prompt":"/pc-demo:deploy now","session_id":"bg-1"}'
Invoke-Dispatch 'UserPromptSubmit' 'claude-code' $pBg $outF $errF | Out-Null
$deadline = (Get-Date).AddSeconds(30)
do { Start-Sleep -Milliseconds 500; $bodies = (@(Get-MockRequests $mock) | ForEach-Object { $_.body }) -join "`n" } until ($bodies.Contains('pc.ai.skill_usage') -or (Get-Date) -gt $deadline)
Start-Sleep -Milliseconds 500
if ($bodies.Contains('pc.ai.skill_usage') -and (Get-QueueFiles).Count -eq 0) { Ok 'background: detached worker delivered the queue' } else { Bad 'background: worker delivery' "files=$((Get-QueueFiles).Count)" }

# background SessionStart: inventory built and sent by the worker
Get-ChildItem $logDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
Reset-MockOtlp $mock
Invoke-Dispatch 'SessionStart' 'claude-code' (New-Payload '{"session_id":"bg-inv"}') $outF $errF | Out-Null
$deadline = (Get-Date).AddSeconds(45)
do { Start-Sleep -Milliseconds 500; $bodies = (@(Get-MockRequests $mock) | ForEach-Object { $_.body }) -join "`n" } until ($bodies.Contains('pc.ai.inventory') -or (Get-Date) -gt $deadline)
if ($bodies.Contains('pc.ai.inventory') -and $bodies.Contains('bg-inv')) { Ok 'background: SessionStart inventory sent by the worker' } else { Bad 'background: inventory worker' '' }

# latency: endpoint unreachable -> the background hook does not wait for the network
$latDir = Join-Path $work 'lat'; New-Item -ItemType Directory $latDir -Force | Out-Null
$pLat = New-Payload '{"prompt":"hello","session_id":"lat"}'
function Measure-Hook { $sw = [System.Diagnostics.Stopwatch]::StartNew(); Get-Content $pLat -Raw | & $psExe -NoProfile -ExecutionPolicy Bypass -File $dispatch -Event UserPromptSubmit -Agent test | Out-Null; return $sw.ElapsedMilliseconds }
Set-SendSettings '' ',"background":true' ($latDir -replace '\\', '/') | Out-Null
$base = Measure-Hook
Set-SendSettings 'http://10.255.255.1:4318' ',"background":true' ($latDir -replace '\\', '/') | Out-Null
$bg = Measure-Hook
# 'hello' emits nothing: force a queued record so a worker is started
Set-Content (Join-Path $latDir 'telemetry-queue.jsonl') (ConvertTo-OtlpRecordJson -Name 'pc.ai.skill_usage' -Attributes @{} -TimeMs 0)
$bgq = Measure-Hook
if ($bg -lt ($base + 1500) -and $bgq -lt ($base + 1500)) { Ok "latency: unreachable endpoint does not slow the hook (base ${base} ms, background ${bgq} ms)" } else { Bad 'latency' "base=$base bg=$bg bgq=$bgq" }
$env:AIHOOKS_SETTINGS = $null
try { $null = $mock.ps.BeginStop($null, $null) } catch { }   # Stop() would block on GetContext()

Write-Host "`n== Installer (isolated USERPROFILE / LOCALAPPDATA) =="
# Runs install-local.ps1 for real with Windows PowerShell (where Set-Content -Encoding UTF8 adds a BOM),
# then checks every JSON it writes: no BOM (Copilot CLI rejects the whole hooks file otherwise), valid, wired to Dest.
$inst = Join-Path $work 'install'
$fakeProfile = Join-Path $inst 'profile'; $fakeLocal = Join-Path $inst 'local'; $instDest = Join-Path $inst 'dest'
New-Item -ItemType Directory -Force -Path (Join-Path $fakeProfile '.claude'), $fakeLocal | Out-Null
# Existing Claude settings with a foreign hook: the installer must keep it (refresh branch)
[System.IO.File]::WriteAllText((Join-Path $fakeProfile '.claude\settings.json'),
    '{"model":"x","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other-tool.exe"}]}]}}')
$savedProfile = $env:USERPROFILE; $savedLocal = $env:LOCALAPPDATA
$env:USERPROFILE = $fakeProfile; $env:LOCALAPPDATA = $fakeLocal
try {
    $ip = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'install-local.ps1'),
        '-Dest', $instDest, '-SkipTests', '-OtelEndpoint', 'http://localhost:4318', '-OtelToken', 'tok') `
        -RedirectStandardOutput (Join-Path $work 'inst-out.txt') -RedirectStandardError (Join-Path $work 'inst-err.txt') -PassThru -Wait -NoNewWindow
} finally { $env:USERPROFILE = $savedProfile; $env:LOCALAPPDATA = $savedLocal }
if ($ip.ExitCode -eq 0) { Ok 'installer: runs (Windows PowerShell)' } else { Bad 'installer: runs' (Read-Text (Join-Path $work 'inst-err.txt')) }

$written = @{
    'copilot hooks'   = (Join-Path $fakeProfile '.copilot\hooks\company-hooks.json')
    'claude settings' = (Join-Path $fakeProfile '.claude\settings.json')
    'hodor config'    = (Join-Path $instDest 'config\settings.json')
}
foreach ($k in $written.Keys) {
    $p = $written[$k]
    if (-not (Test-Path $p)) { Bad "installer: $k written" $p; continue }
    $bytes = [System.IO.File]::ReadAllBytes($p)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if (-not $bom) { Ok "installer: $k has no BOM" } else { Bad "installer: $k has no BOM" $p }
    # Strict parse with .NET (no BOM tolerance), like the Rust/Node parsers of the clients
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    try { $null = $text | ConvertFrom-Json; if ($text.TrimStart()[0] -ne '{') { throw 'does not start with {' }; Ok "installer: $k is valid JSON" }
    catch { Bad "installer: $k is valid JSON" $_.Exception.Message }
}
$cop = Read-Text $written['copilot hooks']
$destJson = ($instDest -replace '\\', '\\')
if ($cop.Contains($destJson) -and $cop.Contains('sessionStart') -and -not $cop.Contains('ProgramData')) { Ok 'installer: copilot hooks point to Dest' } else { Bad 'installer: copilot hooks point to Dest' $cop }
$cl = Read-Text $written['claude settings']
if ($cl.Contains('other-tool.exe') -and $cl.Contains('"model"') -and $cl.Contains($destJson) -and $cl.Contains('SessionStart')) { Ok 'installer: claude settings keep foreign hooks + add ours' } else { Bad 'installer: claude settings merge' $cl }
$marked = @(Get-ChildItem $instDest -Recurse -File -Filter '*.ps1' | Where-Object { Get-Item $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue })
if ($marked.Count -eq 0) { Ok 'installer: no Mark of the Web on installed scripts' } else { Bad 'installer: Mark of the Web removed' "$($marked.Count) file(s), e.g. $($marked[0].FullName)" }
# Copilot runs the 'powershell' command without -ExecutionPolicy Bypass: it must fail OPEN (exit 0) when the
# script cannot load (Copilot denies the tool on a preToolUse error), and keep exit 2 for real blocks.
$cmd = ((Read-Text $written['copilot hooks']) | ConvertFrom-Json).hooks.preToolUse[0].powershell
if ($cmd -match '^try \{ & .+ \} catch \{ \}; exit \$LASTEXITCODE$') { Ok 'installer: copilot command fails open' } else { Bad 'installer: copilot command fails open' $cmd }
$broken = Join-Path $inst 'broken.ps1'; Set-Content $broken "`$ErrorActionPreference='Stop'; . 'C:\does-not-exist\lib.ps1'; exit 0"
$probe = $cmd -replace "&\s+'[^']+dispatch\.ps1'", "& '$broken'"
$null = '{}' | & $psExe -NoProfile -ExecutionPolicy RemoteSigned -Command $probe 2>$null
if ($LASTEXITCODE -eq 0) { Ok 'installer: copilot command exits 0 when the hook cannot load' } else { Bad 'installer: copilot fail-open' "exit $LASTEXITCODE" }
$hc = (Read-Text $written['hodor config']) | ConvertFrom-Json
if ($hc.otel.endpoint -eq 'http://localhost:4318' -and $hc.otel.headers.Authorization -eq 'Bearer tok' -and $hc.otel.background -eq $true) { Ok 'installer: -OtelEndpoint / -OtelToken applied, new defaults merged' } else { Bad 'installer: config params' ($hc.otel | ConvertTo-Json -Compress) }

Write-Host "`n== Unit checks =="
# scan-prompt: rule + severity
$f = & (Join-Path $Root 'layers\policy\scan-prompt.ps1') -Prompt 'key AKIA1234567890ABCDEF here' -Root $Root
if ($f -and $f[0].rule -eq 'AWS_ACCESS_KEY' -and $f[0].severity -eq 'critical') { Ok 'scan: AWS critical' } else { Bad 'scan: AWS critical' ("$($f | ConvertTo-Json -Compress)") }
# placeholder filtered
$f = & (Join-Path $Root 'layers\policy\scan-prompt.ps1') -Prompt 'AKIAEXAMPLEKEY123456' -Root $Root
if (-not $f -or $f.Count -eq 0) { Ok 'scan: placeholder filtered' } else { Bad 'scan: placeholder filtered' "$($f.Count) findings" }
# Luhn valid vs invalid
$f = & (Join-Path $Root 'layers\policy\scan-prompt.ps1') -Prompt 'card 4111111111111111' -Root $Root
if ($f | Where-Object { $_.rule -eq 'CREDIT_CARD' }) { Ok 'scan: valid Luhn card detected' } else { Bad 'scan: valid Luhn card detected' }
$f = & (Join-Path $Root 'layers\policy\scan-prompt.ps1') -Prompt 'card 4111111111111112' -Root $Root
if (-not ($f | Where-Object { $_.rule -eq 'CREDIT_CARD' })) { Ok 'scan: invalid Luhn rejected' } else { Bad 'scan: invalid Luhn rejected' }

# usage classification
$su = & (Join-Path $Root 'layers\usage\usage.ps1') -SkillName 'pc-ai:debugger' -Kind skill -Root $Root
if ($su[0].source -eq 'plainconcepts' -and $su[0].plugin -eq 'pc-ai' -and $su[0].kind -eq 'skill') { Ok 'skill: pc- => plainconcepts' } else { Bad 'skill: pc- => plainconcepts' "$($su | ConvertTo-Json -Compress)" }
$su = & (Join-Path $Root 'layers\usage\usage.ps1') -SkillName 'anthropic-skills:docx' -Kind skill -Root $Root
if ($su[0].source -eq 'plugin') { Ok 'skill: other plugin => plugin' } else { Bad 'skill: other plugin => plugin' "$($su | ConvertTo-Json -Compress)" }
$su = & (Join-Path $Root 'layers\usage\usage.ps1') -SkillName 'my-local-skill' -Kind skill -Root $Root
if ($su[0].source -eq 'personal') { Ok 'skill: bare => personal' } else { Bad 'skill: bare => personal' "$($su | ConvertTo-Json -Compress)" }
$su = & (Join-Path $Root 'layers\usage\usage.ps1') -Prompt 'please /build now' -Root $Root
if (-not $su -or $su.Count -eq 0) { Ok 'skill: bare /word ignored' } else { Bad 'skill: bare /word ignored' "$($su.Count)" }

# version format + -Event version does not block on stdin
$v = Get-HooksVersion
if ($v -match '^\d+\.\d+\.\d+\+g') { Ok "version format ($v)" } else { Bad 'version format' $v }
$empty = Join-Path $work 'empty.txt'; Set-Content $empty '' -NoNewline
$vo = Join-Path $work 'v.txt'
$vp = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dispatch, '-Event', 'version') -RedirectStandardInput $empty -RedirectStandardOutput $vo -RedirectStandardError (Join-Path $work 've.txt') -PassThru -Wait -NoNewWindow
if ($vp.ExitCode -eq 0 -and (Read-Text $vo) -match '"version"') { Ok 'dispatch -Event version -> json, exit 0' } else { Bad 'dispatch -Event version' "exit $($vp.ExitCode)" }

$env:AIHOOKS_CLAUDE_HOME = $null; $env:AIHOOKS_COPILOT_HOME = $null
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`nResult: $($script:pass) passed, $($script:fail) failed`n"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
