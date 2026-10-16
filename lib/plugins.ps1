# lib/plugins.ps1 - what is installed locally (Claude Code + Copilot plugins, personal skills/agents/commands).
# Used to (1) resolve a usage name to its kind/version/marketplace and (2) build the inventory snapshot.
# AIHOOKS_CLAUDE_HOME / AIHOOKS_COPILOT_HOME override the homes (test isolation; unset in production).

function Get-ClaudeHome {
    if ($env:AIHOOKS_CLAUDE_HOME) { return $env:AIHOOKS_CLAUDE_HOME }
    return (Join-Path $env:USERPROFILE '.claude')
}

function Get-CopilotHome {
    if ($env:AIHOOKS_COPILOT_HOME) { return $env:AIHOOKS_COPILOT_HOME }
    return (Join-Path $env:USERPROFILE '.copilot')
}

function Read-JsonFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-FrontmatterName {
    # 'name:' from the YAML frontmatter of a SKILL.md / agent .md ('' if absent)
    param([string]$Path)
    try {
        $lines = @(Get-Content -LiteralPath $Path -TotalCount 15 -Encoding UTF8)
        if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '---') { return '' }
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq '---') { break }
            if ($lines[$i] -match '^name:\s*["'']?([^"'']+?)["'']?\s*$') { return $matches[1] }
        }
    } catch { }
    return ''
}

function Get-PluginItems {
    # Skills, agents and commands under a plugin (or personal) root, by invocation name.
    param([string]$Dir)
    $skills = @(); $agents = @(); $commands = @()
    if ($Dir -and (Test-Path -LiteralPath $Dir)) {
        $sd = Join-Path $Dir 'skills'
        if (Test-Path -LiteralPath $sd) {
            foreach ($d in (Get-ChildItem -LiteralPath $sd -Directory -ErrorAction SilentlyContinue)) {
                $f = Join-Path $d.FullName 'SKILL.md'
                if (Test-Path -LiteralPath $f) {
                    $n = Get-FrontmatterName $f
                    $skills += $(if ($n) { $n } else { $d.Name })
                }
            }
        }
        $ad = Join-Path $Dir 'agents'
        if (Test-Path -LiteralPath $ad) {
            foreach ($f in (Get-ChildItem -LiteralPath $ad -File -Filter '*.md' -ErrorAction SilentlyContinue)) {
                $n = Get-FrontmatterName $f.FullName
                $agents += $(if ($n) { $n } else { $f.BaseName -replace '\.agent$', '' })
            }
        }
        $cd = Join-Path $Dir 'commands'
        if (Test-Path -LiteralPath $cd) {
            $base = (Resolve-Path -LiteralPath $cd).Path.TrimEnd('\', '/')
            foreach ($f in (Get-ChildItem -LiteralPath $cd -File -Filter '*.md' -Recurse -ErrorAction SilentlyContinue)) {
                $rel = $f.FullName.Substring($base.Length + 1) -replace '\.md$', ''
                $commands += ($rel -replace '[\\/]', ':')
            }
        }
    }
    return [pscustomobject]@{
        skills   = @($skills | Sort-Object -Unique)
        agents   = @($agents | Sort-Object -Unique)
        commands = @($commands | Sort-Object -Unique)
    }
}

function Get-ClaudePluginIndex {
    # installed_plugins.json (v1 object or v2 array per id) -> flat list of installs
    $j = Read-JsonFile (Join-Path (Get-ClaudeHome) 'plugins\installed_plugins.json')
    $out = @()
    if (-not $j -or -not $j.PSObject.Properties['plugins']) { return $out }
    foreach ($p in $j.plugins.PSObject.Properties) {
        $id = $p.Name
        $at = $id.LastIndexOf('@')
        $plugin = if ($at -gt 0) { $id.Substring(0, $at) } else { $id }
        $market = if ($at -gt 0) { $id.Substring($at + 1) } else { '' }
        foreach ($e in @($p.Value)) {
            $out += [pscustomobject]@{
                client      = 'claude-code'
                id          = $id
                plugin      = $plugin
                marketplace = $market
                version     = [string]$e.version
                scope       = $(if ($e.scope) { [string]$e.scope } else { 'user' })
                projectPath = [string]$e.projectPath
                installPath = [string]$e.installPath
            }
        }
    }
    return $out
}

function Get-CopilotPluginIndex {
    # ~/.copilot/installed-plugins/<plugin>/plugin.json or .../<marketplace>/<plugin>/plugin.json
    $root = Join-Path (Get-CopilotHome) 'installed-plugins'
    $out = @()
    if (-not (Test-Path -LiteralPath $root)) { return $out }
    foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $candidates = @()
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'plugin.json')) { $candidates += [pscustomobject]@{ dir = $d; market = '' } }
        else {
            foreach ($c in (Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath (Join-Path $c.FullName 'plugin.json')) {
                    $candidates += [pscustomobject]@{ dir = $c; market = $(if ($d.Name -eq '_direct') { 'direct' } else { $d.Name }) }
                }
            }
        }
        foreach ($c in $candidates) {
            $pj = Read-JsonFile (Join-Path $c.dir.FullName 'plugin.json')
            $out += [pscustomobject]@{
                client      = 'copilot'
                id          = $(if ($c.market) { "$($c.dir.Name)@$($c.market)" } else { $c.dir.Name })
                plugin      = $(if ($pj -and $pj.name) { [string]$pj.name } else { $c.dir.Name })
                marketplace = $c.market
                version     = $(if ($pj -and $pj.version) { [string]$pj.version } else { '' })
                scope       = 'user'
                projectPath = ''
                installPath = $c.dir.FullName
            }
        }
    }
    return $out
}

function Test-PluginItem {
    # 'command' | 'skill' | 'agent' | '' : what <name> is inside a plugin/personal root
    param([string]$Dir, [string]$Name)
    if (-not $Dir -or -not $Name -or -not (Test-Path -LiteralPath $Dir)) { return '' }
    $rel = $Name -replace ':', '\'
    if (Test-Path -LiteralPath (Join-Path $Dir "commands\$rel.md")) { return 'command' }
    if (Test-Path -LiteralPath (Join-Path $Dir "skills\$rel\SKILL.md")) { return 'skill' }
    if ((Test-Path -LiteralPath (Join-Path $Dir "agents\$rel.md")) -or (Test-Path -LiteralPath (Join-Path $Dir "agents\$rel.agent.md"))) { return 'agent' }
    # Agents are invoked by their frontmatter name (e.g. pc.presales.discovery for agents\discovery.agent.md)
    $ad = Join-Path $Dir 'agents'
    if (Test-Path -LiteralPath $ad) {
        foreach ($f in (Get-ChildItem -LiteralPath $ad -File -Filter '*.md' -ErrorAction SilentlyContinue)) {
            if ((Get-FrontmatterName $f.FullName) -eq $Name) { return 'agent' }
        }
    }
    return ''
}

function Get-AgentCanonicalName {
    # Claude Code invokes an agent by its frontmatter name (pc.presales.risks-analyzer), Copilot by its file name
    # (risks-analyzer for agents\risks-analyzer.agent.md): report both clients under the frontmatter name.
    param([string]$Dir, [string]$Name)
    $rel = $Name -replace ':', '\'
    foreach ($f in @((Join-Path $Dir "agents\$rel.agent.md"), (Join-Path $Dir "agents\$rel.md"))) {
        if (Test-Path -LiteralPath $f) { $fm = Get-FrontmatterName $f; if ($fm) { return $fm } }
    }
    return $Name
}

function Resolve-UsageItem {
    # Enriches a usage with what is installed: kind (skill vs command), plugin version and marketplace.
    # Plugin ''  -> personal (~/.claude, <cwd>/.claude) first, then any installed plugin exposing that bare name.
    # found=$false when nothing local matches (the caller decides whether to keep it).
    param([string]$Plugin, [string]$Name, [string]$Kind, [string]$Cwd, [string]$Client)
    $r = [pscustomobject]@{ plugin = $Plugin; kind = $Kind; version = ''; marketplace = ''; found = $false; name = $Name }
    # The calling client's own installs first (the same plugin can be installed in Claude Code and Copilot at different versions)
    if ($Client -match 'copilot') { $installs = @(Get-CopilotPluginIndex) + @(Get-ClaudePluginIndex) }
    else { $installs = @(Get-ClaudePluginIndex) + @(Get-CopilotPluginIndex) }

    if (-not $Plugin) {
        $roots = @()
        if ($Cwd) { $roots += (Join-Path $Cwd '.claude') }
        $roots += (Get-ClaudeHome)
        $roots += (Get-CopilotHome)
        foreach ($root in $roots) {
            $k = Test-PluginItem $root $Name
            if ($k) {
                $r.found = $true; if ($Kind -ne 'agent') { $r.kind = $k }
                if ($r.kind -eq 'agent') { $r.name = Get-AgentCanonicalName $root $Name }
                return $r
            }
        }
    }

    $first = $null   # first install of the named plugin, used when no install contains the item itself
    foreach ($i in $installs) {
        if ($Plugin -and $i.plugin -ne $Plugin) { continue }
        $k = Test-PluginItem $i.installPath $Name
        if ($k) {
            $r.plugin = $i.plugin; $r.version = $i.version; $r.marketplace = $i.marketplace; $r.found = $true
            if ($Kind -ne 'agent') { $r.kind = $k }
            if ($r.kind -eq 'agent') { $r.name = Get-AgentCanonicalName $i.installPath $Name }
            return $r
        }
        if ($Plugin -and -not $first) { $first = $i }
    }
    if ($first) { $r.version = $first.version; $r.marketplace = $first.marketplace }
    if ($Plugin) { $r.found = $true }
    return $r
}
