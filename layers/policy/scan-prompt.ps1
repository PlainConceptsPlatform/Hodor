# layers/policy/scan-prompt.ps1
# Scans the prompt against patterns.d. Returns findings: @{rule; severity; evidence}
param(
    [string]$Prompt,
    [Parameter(Mandatory = $true)][string]$Root
)

function Test-LuhnValid {
    param([string]$Value)
    $digits = ($Value -replace '[^0-9]', '')
    if ($digits.Length -lt 13 -or $digits.Length -gt 19) { return $false }
    $sum = 0; $alt = $false
    for ($i = $digits.Length - 1; $i -ge 0; $i--) {
        $d = [int][string]$digits[$i]
        if ($alt) { $d *= 2; if ($d -gt 9) { $d -= 9 } }
        $sum += $d; $alt = -not $alt
    }
    return ($sum % 10) -eq 0
}

if ([string]::IsNullOrWhiteSpace($Prompt)) { return @() }

# patterns.d is authored for grep -E (POSIX). Translate POSIX character classes so the
# same patterns also work in the .NET regex engine (which does not support [[:...:]]).
function ConvertTo-DotNetRegex {
    param([string]$Re)
    $map = @{
        '[:space:]'  = '\s'
        '[:digit:]'  = '0-9'
        '[:alnum:]'  = 'A-Za-z0-9'
        '[:alpha:]'  = 'A-Za-z'
        '[:upper:]'  = 'A-Z'
        '[:lower:]'  = 'a-z'
        '[:xdigit:]' = '0-9A-Fa-f'
    }
    foreach ($k in $map.Keys) { $Re = $Re.Replace($k, $map[$k]) }
    return $Re
}

$placeholderRe = '(?i)(example|placeholder|your_|xxxx|changeme|todo|fixme|dummy|fake|test_key|sample|lorem)'

$allow = @()
$allowPath = Join-Path $Root 'config\allowlist.txt'
if (Test-Path $allowPath) {
    $allow = Get-Content $allowPath -Encoding UTF8 |
        Where-Object { $_ -and -not $_.Trim().StartsWith('#') } |
        ForEach-Object { $_.Trim().ToLower() }
}

$findings = @()
$patternFiles = Get-ChildItem (Join-Path $Root 'layers\policy\patterns.d') -Filter '*.txt' | Sort-Object Name
foreach ($file in $patternFiles) {
    foreach ($line in (Get-Content $file.FullName -Encoding UTF8)) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $parts = $line.Split('|', 3)
        if ($parts.Count -lt 3) { continue }
        $name = $parts[0]; $sev = $parts[1]; $re = ConvertTo-DotNetRegex $parts[2]
        try {
            $found = [regex]::Matches($Prompt, $re, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        } catch { continue }
        foreach ($m in $found) {
            $val = $m.Value
            if ($val -match $placeholderRe) { continue }
            $skip = $false
            foreach ($a in $allow) {
                if ($a -and $val.ToLower().Contains($a)) { $skip = $true; break }
            }
            if ($skip) { continue }
            if ($name -eq 'CREDIT_CARD' -and -not (Test-LuhnValid $val)) { continue }
            $findings += [pscustomobject]@{ rule = $name; severity = $sev; evidence = $val }
        }
    }
}
return , $findings
