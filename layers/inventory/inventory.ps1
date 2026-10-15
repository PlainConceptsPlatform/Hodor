# layers/inventory/inventory.ps1
# Snapshot of what this user has installed: one record per plugin install (Claude Code + Copilot),
# plus one per client for personal skills/agents/commands (~/.claude, ~/.copilot).
# Returns a list of attribute hashtables (without the common who/where attributes).
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)]$Settings
)
. (Join-Path $Root 'lib\plugins.ps1')

$prefix = [string]$Settings.skills.orgPluginPrefix
$maxList = 4000   # cap for the comma-separated item lists (OTel attribute size)

function Get-SourceOf([string]$Plugin) {
    if (-not $Plugin) { return 'personal' }
    if ($prefix -and $Plugin.ToLower().StartsWith($prefix.ToLower())) { return 'plainconcepts' }
    return 'plugin'
}

function Join-Capped([string[]]$Items) {
    $s = (@($Items) -join ',')
    if ($s.Length -gt $maxList) { $s = $s.Substring(0, $maxList) + ',...' }
    return $s
}

function Get-EnabledMap([string]$SettingsPath) {
    $m = @{}
    $j = Read-JsonFile $SettingsPath
    if ($j -and $j.PSObject.Properties['enabledPlugins'] -and $j.enabledPlugins) {
        foreach ($p in $j.enabledPlugins.PSObject.Properties) { $m[$p.Name] = [bool]$p.Value }
    }
    return $m
}

function New-InventoryRecord($Client, $Plugin, $Marketplace, $MarketRepo, $Version, $Scope, $Project, $Enabled, $Items, $InstallOk = $true) {
    return @{
        'pc.client'           = $Client
        'pc.plugin'           = $Plugin
        'pc.marketplace'      = $Marketplace
        'pc.marketplace_repo' = $MarketRepo
        'pc.plugin_version'   = $Version
        'pc.scope'            = $Scope
        'pc.scope_project'    = $Project
        'pc.enabled'          = $Enabled
        'pc.install_ok'       = $(if ($InstallOk) { 'true' } else { 'false' })
        'pc.source'           = (Get-SourceOf $Plugin)
        'pc.skills_count'     = [string]@($Items.skills).Count
        'pc.agents_count'     = [string]@($Items.agents).Count
        'pc.commands_count'   = [string]@($Items.commands).Count
        'pc.skills'           = (Join-Capped $Items.skills)
        'pc.agents'           = (Join-Capped $Items.agents)
        'pc.commands'         = (Join-Capped $Items.commands)
    }
}

$records = @()
$claudeHome = Get-ClaudeHome

# ---- Claude Code plugins ----
$markets = Read-JsonFile (Join-Path $claudeHome 'plugins\known_marketplaces.json')
$userEnabled = Get-EnabledMap (Join-Path $claudeHome 'settings.json')
foreach ($i in (Get-ClaudePluginIndex)) {
    $repo = ''
    if ($markets -and $i.marketplace -and $markets.PSObject.Properties[$i.marketplace]) {
        $src = $markets.($i.marketplace).source
        if ($src) {
            foreach ($f in @('repo', 'url', 'path')) { if ($src.PSObject.Properties[$f] -and $src.$f) { $repo = [string]$src.$f; break } }
            if ($src.PSObject.Properties['source'] -and $src.source -in @('directory', 'file')) { $repo = 'local:' + (Split-Path -Leaf $repo) }
        }
    }
    $project = ''
    $enabled = 'unknown'
    if ($i.scope -eq 'user') {
        if ($userEnabled.ContainsKey($i.id)) { $enabled = ([string]$userEnabled[$i.id]).ToLower() }
    } elseif ($i.projectPath) {
        # Folder name only (no git call: this runs on every session start, before the throttle check)
        $project = Split-Path -Leaf ($i.projectPath.TrimEnd('\', '/'))
        if ("$($Settings.telemetry.projectMode)" -eq 'hash') { $project = Get-ShortHash ($project.ToLower() + $Settings.identity.salt) }
        foreach ($f in @('settings.local.json', 'settings.json')) {
            $pm = Get-EnabledMap (Join-Path $i.projectPath ".claude\$f")
            if ($pm.ContainsKey($i.id)) { $enabled = ([string]$pm[$i.id]).ToLower(); break }
        }
    }
    $items = Get-PluginItems $i.installPath
    # install_ok = false: the install folder is gone (stale entry in installed_plugins.json), so nothing can load from it
    $ok = [bool]($i.installPath -and (Test-Path -LiteralPath $i.installPath))
    $records += New-InventoryRecord 'claude-code' $i.plugin $i.marketplace $repo $i.version $i.scope $project $enabled $items $ok
}

# ---- Copilot plugins ----
foreach ($i in (Get-CopilotPluginIndex)) {
    $items = Get-PluginItems $i.installPath
    $records += New-InventoryRecord 'copilot' $i.plugin $i.marketplace '' $i.version 'user' '' 'unknown' $items
}

# ---- Personal (no plugin) ----
foreach ($p in @(@{ client = 'claude-code'; dir = $claudeHome }, @{ client = 'copilot'; dir = (Get-CopilotHome) })) {
    $items = Get-PluginItems $p.dir
    if ((@($items.skills).Count + @($items.agents).Count + @($items.commands).Count) -gt 0) {
        $records += New-InventoryRecord $p.client '' '' '' '' 'user' '' 'true' $items
    }
}

return , $records
