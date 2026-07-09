# layers/usage/usage.ps1
# Detects skill/agent usage and classifies it by plugin namespace.
# Returns events: @{skill; plugin; source; kind}
#   - source: plainconcepts (plugin starts with org prefix) | plugin (other namespaced) | personal (no namespace)
# Params:
#   - SkillName: direct name from a PreToolUse tool_input (e.g. "pc-ai:debugger", "docx"); Kind = skill|agent
#   - Prompt:    scanned ONLY for namespaced /plugin:skill invocations (bare /word tokens are ignored)
param(
    [string]$Prompt,
    [string]$SkillName,
    [ValidateSet('skill', 'agent')][string]$Kind = 'skill',
    [Parameter(Mandatory = $true)][string]$Root
)

$prefix = 'pc-'
try {
    . (Join-Path $Root 'lib\common.ps1') 2>$null
    $s = Get-AiHooksSettings
    if ($s -and $s.skills -and $s.skills.orgPluginPrefix) { $prefix = [string]$s.skills.orgPluginPrefix }
} catch { }

function New-SkillEvent {
    param([string]$Name, [string]$EventKind)
    $n = $Name.Trim()
    if (-not $n) { return $null }
    $plugin = ''
    $bare = $n
    $idx = $n.IndexOf(':')
    if ($idx -gt 0) {
        $plugin = $n.Substring(0, $idx)
        $bare = $n.Substring($idx + 1)
    }
    if ($plugin -and $plugin.ToLower().StartsWith($prefix.ToLower())) {
        $source = 'plainconcepts'
    } elseif ($plugin) {
        $source = 'plugin'
    } else {
        $source = 'personal'
    }
    return [pscustomobject]@{ skill = $bare; plugin = $plugin; source = $source; kind = $EventKind }
}

$candidates = @()  # @{ name; kind }
if (-not [string]::IsNullOrWhiteSpace($SkillName)) {
    $candidates += [pscustomobject]@{ name = $SkillName; kind = $Kind }
}
if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
    # Only namespaced tokens (/plugin:skill) are reliable skill invocations without a catalog.
    foreach ($m in [regex]::Matches($Prompt, '(^|\s)/([A-Za-z0-9][A-Za-z0-9._-]{0,63}:[A-Za-z0-9][A-Za-z0-9._-]{0,63})')) {
        $candidates += [pscustomobject]@{ name = $m.Groups[2].Value; kind = 'skill' }
    }
}

$events = @()
$seen = @{}
foreach ($c in $candidates) {
    $key = $c.name.ToLower()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $ev = New-SkillEvent -Name $c.name -EventKind $c.kind
    if ($ev) { $events += $ev }
}
return , $events
