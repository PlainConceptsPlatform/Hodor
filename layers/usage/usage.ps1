# layers/usage/usage.ps1
# Detects skill/agent/command usage and classifies it by plugin namespace.
# Returns events: @{skill; raw; plugin; source; kind; via; version; marketplace}
#   - skill:  canonical name (agents: frontmatter name, the same for Claude Code and Copilot); raw = name as invoked
#   - source: plainconcepts (plugin starts with org prefix) | plugin (other namespaced) | personal (no namespace)
#   - kind:   skill | agent | command (command = a commands/*.md file of the plugin or personal folder)
#   - via:    tool (Skill/Agent tool call) | prompt (/name typed by the user) | file_read (the .md was read directly)
# Params:
#   - SkillName: direct name from a PreToolUse tool_input (e.g. "pc-ai:debugger", "docx"); Kind = skill|agent
#   - Prompt:    /plugin:name tokens anywhere, plus a bare /name at the very start only when it is installed
#                (built-ins like /clear and paths like /usr/bin never match a local skill/command)
#   - FileText:  a Read path or Bash command; matches .../skills/<x>/SKILL.md, .../agents/<x>.md, .../commands/<x>.md
param(
    [string]$Prompt,
    [string]$SkillName,
    [ValidateSet('skill', 'agent', 'command')][string]$Kind = 'skill',
    [string]$FileText,
    [string]$Cwd,
    [string]$Client,
    [Parameter(Mandatory = $true)][string]$Root
)

$prefix = 'pc-'
try {
    . (Join-Path $Root 'lib\common.ps1') 2>$null
    $s = Get-AiHooksSettings
    if ($s -and $s.skills -and $s.skills.orgPluginPrefix) { $prefix = [string]$s.skills.orgPluginPrefix }
} catch { }
. (Join-Path $Root 'lib\plugins.ps1')

function Split-UsageName {
    param([string]$Name)
    $n = $Name.Trim()
    $idx = $n.IndexOf(':')
    if ($idx -gt 0) { return @($n.Substring(0, $idx), $n.Substring($idx + 1)) }
    return @('', $n)
}

function New-SkillEvent {
    param([string]$Plugin, [string]$Bare, [string]$EventKind, [string]$Via, [bool]$RequireFound)
    if (-not $Bare) { return $null }
    $raw = if ($Plugin) { "${Plugin}:$Bare" } else { $Bare }   # before $plugin (= $Plugin: PS names are case-insensitive) is reassigned
    $res = Resolve-UsageItem -Plugin $Plugin -Name $Bare -Kind $EventKind -Cwd $Cwd -Client $Client
    if ($RequireFound -and -not $res.found) { return $null }
    $plugin = $res.plugin
    if ($plugin -and $plugin.ToLower().StartsWith($prefix.ToLower())) {
        $source = 'plainconcepts'
    } elseif ($plugin) {
        $source = 'plugin'
    } else {
        $source = 'personal'
    }
    return [pscustomobject]@{
        skill = $(if ($res.name) { $res.name } else { $Bare }); raw = $raw; plugin = $plugin; source = $source; kind = $res.kind
        via = $Via; version = $res.version; marketplace = $res.marketplace
    }
}

$candidates = @()  # @{ plugin; bare; kind; via; requireFound }
if (-not [string]::IsNullOrWhiteSpace($SkillName)) {
    $sp = Split-UsageName $SkillName
    $candidates += [pscustomobject]@{ plugin = $sp[0]; bare = $sp[1]; kind = $Kind; via = 'tool'; requireFound = $false }
}
# Copilot CLI expands "/plugin:skill args" before the hook runs: the prompt becomes a fixed preamble followed by
# the whole SKILL.md. Count only the named skill; the embedded skill text may mention other /plugin:name tokens.
$cm = [regex]::Match([string]$Prompt, '^\s*The user explicitly invoked the "/([A-Za-z0-9][A-Za-z0-9._:-]{0,127})" skill\.')
if ($cm.Success) {
    $sp = Split-UsageName $cm.Groups[1].Value
    $candidates += [pscustomobject]@{ plugin = $sp[0]; bare = $sp[1]; kind = 'skill'; via = 'prompt'; requireFound = $false }
    $Prompt = ''
}
if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
    # Namespaced tokens (/plugin:name, /plugin:group:name) are reliable invocations without a catalog.
    foreach ($m in [regex]::Matches($Prompt, '(^|\s)/([A-Za-z0-9][A-Za-z0-9._-]{0,63}(?::[A-Za-z0-9][A-Za-z0-9._-]{0,63})+)')) {
        $sp = Split-UsageName $m.Groups[2].Value
        $candidates += [pscustomobject]@{ plugin = $sp[0]; bare = $sp[1]; kind = 'skill'; via = 'prompt'; requireFound = $false }
    }
    # A bare /name counts only at the start of the prompt AND when it is installed locally.
    $bm = [regex]::Match($Prompt, '^\s*/([A-Za-z0-9][A-Za-z0-9._-]{0,63})(\s|$)')
    if ($bm.Success) {
        $candidates += [pscustomobject]@{ plugin = ''; bare = $bm.Groups[1].Value; kind = 'command'; via = 'prompt'; requireFound = $true }
    }
}
if (-not [string]::IsNullOrWhiteSpace($FileText)) {
    $text = $FileText -replace '\\', '/'
    $rx = '(?i)(/?(?:[^/\s"''<>|]+/)*)(?:skills/([^/\s"''<>|]+)/SKILL\.md|agents/([^/\s"''<>|]+?)\.md|commands/([^\s"''<>|]+?)\.md)'
    foreach ($m in [regex]::Matches($text, $rx)) {
        $segments = @($m.Groups[1].Value.TrimEnd('/') -split '/' | Where-Object { $_ })
        # Plugin = the folder holding skills/agents/commands, skipping a version folder (plugin cache: <plugin>/<version>/skills/...)
        $plugin = ''
        for ($i = $segments.Count - 1; $i -ge 0; $i--) {
            $seg = $segments[$i]
            if ($seg -match '^(v?\d+(\.\d+)*([-+].*)?|[0-9a-f]{7,40}|unknown)$') { continue }
            $plugin = $seg; break
        }
        if ($plugin -match '^\.(claude|copilot|github)$') { $plugin = '' }
        $fullPath = $m.Value
        if ($m.Groups[2].Success) { $bare = $m.Groups[2].Value; $k = 'skill' }
        elseif ($m.Groups[3].Success) { $bare = $m.Groups[3].Value -replace '\.agent$', ''; $k = 'agent' }
        else { $bare = $m.Groups[4].Value -replace '/', ':'; $k = 'command' }
        if ($k -ne 'command' -and (Test-Path -LiteralPath $fullPath)) {
            $fm = Get-FrontmatterName $fullPath
            if ($fm) { $bare = $fm }
        }
        $candidates += [pscustomobject]@{ plugin = $plugin; bare = $bare; kind = $k; via = 'file_read'; requireFound = $false }
    }
}

$events = @()
$seen = @{}
foreach ($c in $candidates) {
    $key = ("$($c.plugin):$($c.bare)").ToLower()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $ev = New-SkillEvent -Plugin $c.plugin -Bare $c.bare -EventKind $c.kind -Via $c.via -RequireFound $c.requireFound
    if ($ev) { $events += $ev }
}
return , $events
