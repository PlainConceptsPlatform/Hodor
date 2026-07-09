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
$baseSettings = '{"otel":{"enabled":true,"endpoint":"","queueMaxSizeMB":2},"log":{"dir":"__LOGDIR__","maxSizeMB":5,"maxFiles":3},"identity":{"email":"test@local","salt":"TEST"},"policy":{"blockSeverity":"critical"},"skills":{"orgPluginPrefix":"pc-"}}'

$script:pass = 0; $script:fail = 0
function Ok($n)   { Write-Host "  PASS  $n" -ForegroundColor Green; $script:pass++ }
function Bad($n, $d) { Write-Host "  FAIL  $n" -ForegroundColor Red; if ($d) { Write-Host "        $d" -ForegroundColor DarkYellow }; $script:fail++ }

function Read-Text($path) {
    if (Test-Path $path) { $c = Get-Content $path -Raw -Encoding UTF8; if ($null -ne $c) { return $c } }
    return ''
}

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

    $p = Start-Process -FilePath $psExe `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dispatch, '-Event', $ev, '-Agent', $ag) `
        -RedirectStandardInput $payloadFile -RedirectStandardOutput $outF -RedirectStandardError $errF `
        -PassThru -Wait -NoNewWindow
    $exit = $p.ExitCode
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
$env:AIHOOKS_SETTINGS = $null

Write-Host "`n== Unit checks =="
# scan-prompt: rule + severity
$f = & (Join-Path $Root 'layers\10-policy\scan-prompt.ps1') -Prompt 'key AKIA1234567890ABCDEF here' -Root $Root
if ($f -and $f[0].rule -eq 'AWS_ACCESS_KEY' -and $f[0].severity -eq 'critical') { Ok 'scan: AWS critical' } else { Bad 'scan: AWS critical' ("$($f | ConvertTo-Json -Compress)") }
# placeholder filtered
$f = & (Join-Path $Root 'layers\10-policy\scan-prompt.ps1') -Prompt 'AKIAEXAMPLEKEY123456' -Root $Root
if (-not $f -or $f.Count -eq 0) { Ok 'scan: placeholder filtered' } else { Bad 'scan: placeholder filtered' "$($f.Count) findings" }
# Luhn valid vs invalid
$f = & (Join-Path $Root 'layers\10-policy\scan-prompt.ps1') -Prompt 'card 4111111111111111' -Root $Root
if ($f | Where-Object { $_.rule -eq 'CREDIT_CARD' }) { Ok 'scan: valid Luhn card detected' } else { Bad 'scan: valid Luhn card detected' }
$f = & (Join-Path $Root 'layers\10-policy\scan-prompt.ps1') -Prompt 'card 4111111111111112' -Root $Root
if (-not ($f | Where-Object { $_.rule -eq 'CREDIT_CARD' })) { Ok 'scan: invalid Luhn rejected' } else { Bad 'scan: invalid Luhn rejected' }

# skill-usage classification
$su = & (Join-Path $Root 'layers\30-skills\skill-usage.ps1') -SkillName 'pc-ai:debugger' -Kind skill -Root $Root
if ($su[0].source -eq 'plainconcepts' -and $su[0].plugin -eq 'pc-ai' -and $su[0].kind -eq 'skill') { Ok 'skill: pc- => plainconcepts' } else { Bad 'skill: pc- => plainconcepts' "$($su | ConvertTo-Json -Compress)" }
$su = & (Join-Path $Root 'layers\30-skills\skill-usage.ps1') -SkillName 'anthropic-skills:docx' -Kind skill -Root $Root
if ($su[0].source -eq 'plugin') { Ok 'skill: other plugin => plugin' } else { Bad 'skill: other plugin => plugin' "$($su | ConvertTo-Json -Compress)" }
$su = & (Join-Path $Root 'layers\30-skills\skill-usage.ps1') -SkillName 'my-local-skill' -Kind skill -Root $Root
if ($su[0].source -eq 'personal') { Ok 'skill: bare => personal' } else { Bad 'skill: bare => personal' "$($su | ConvertTo-Json -Compress)" }
$su = & (Join-Path $Root 'layers\30-skills\skill-usage.ps1') -Prompt 'please /build now' -Root $Root
if (-not $su -or $su.Count -eq 0) { Ok 'skill: bare /word ignored' } else { Bad 'skill: bare /word ignored' "$($su.Count)" }

# version format + -Event version does not block on stdin
$v = Get-HooksVersion
if ($v -match '^\d+\.\d+\.\d+\+g') { Ok "version format ($v)" } else { Bad 'version format' $v }
$empty = Join-Path $work 'empty.txt'; Set-Content $empty '' -NoNewline
$vo = Join-Path $work 'v.txt'
$vp = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dispatch, '-Event', 'version') -RedirectStandardInput $empty -RedirectStandardOutput $vo -RedirectStandardError (Join-Path $work 've.txt') -PassThru -Wait -NoNewWindow
if ($vp.ExitCode -eq 0 -and (Read-Text $vo) -match '"version"') { Ok 'dispatch -Event version -> json, exit 0' } else { Bad 'dispatch -Event version' "exit $($vp.ExitCode)" }

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`nResult: $($script:pass) passed, $($script:fail) failed`n"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
