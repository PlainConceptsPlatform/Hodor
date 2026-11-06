# Uninstall-Hodor.ps1 - Desinstala el piloto de Hodor (hooks de IA).
#
# Uso (PowerShell, sin permisos de administrador). Cierra antes Claude Code y VS Code:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-Hodor.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-Hodor.ps1 -KeepRepo -KeepLogs
#
# Que hace:
#   1. Detiene los procesos de Hodor en segundo plano (envio de telemetria)
#   2. Quita los hooks de Hodor de ~/.claude/settings.json (respeta el resto de hooks y ajustes)
#   3. Quita el hook de Copilot (~/.copilot/hooks/company-hooks.json)
#   4. Borra la instalacion (%LOCALAPPDATA%\PlainConcepts\ai-hooks) y, por defecto, la copia del repo
#   5. Restaura chat.useHooks en VS Code si lo activo Install-Hodor.ps1
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'PlainConcepts\ai-hooks'),
    [string]$RepoDir    = (Join-Path $env:USERPROFILE 'Hodor'),
    [switch]$KeepRepo,   # no borrar %USERPROFILE%\Hodor
    [switch]$KeepLogs    # guardar los logs en el Escritorio antes de borrar
)

$ErrorActionPreference = 'Stop'
$script:problems = 0
function Step($n, $msg) { Write-Host ""; Write-Host "[$n/5] $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Info($msg) { Write-Host "  [-]  $msg" -ForegroundColor DarkGray }
function Warn($msg) { Write-Host "  [!]  $msg" -ForegroundColor Yellow; $script:problems++ }
function Save-Json($path, $obj) {
    [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
}
# Coincide con cualquier instalacion de Hodor (LOCALAPPDATA o ProgramData)
$HodorPattern = 'PlainConcepts\\ai-hooks\\dispatch\.ps1'

Write-Host "== Desinstalacion de Hodor ==" -ForegroundColor White
Write-Host "Recomendado: cierra Claude Code y VS Code antes de continuar." -ForegroundColor DarkGray

# 1. Procesos en segundo plano ----------------------------------------------------
Step 1 "Deteniendo procesos de Hodor en segundo plano"
$procs = @()
try {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $HodorPattern -and $_.ProcessId -ne $PID })
} catch { }
foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { } }
if ($procs.Count) { Ok "$($procs.Count) proceso(s) detenido(s)" } else { Info "No habia procesos en ejecucion" }

# 2. Claude Code -------------------------------------------------------------------
Step 2 "Quitando los hooks de Claude Code"
$claudeSettings = Join-Path $env:USERPROFILE '.claude\settings.json'
if (-not (Test-Path $claudeSettings)) {
    Info "No existe $claudeSettings"
} else {
    try {
        $settings = Get-Content $claudeSettings -Raw -Encoding UTF8 | ConvertFrom-Json
        $removed = 0
        if ($settings.PSObject.Properties['hooks'] -and $settings.hooks) {
            foreach ($ev in @($settings.hooks.PSObject.Properties.Name)) {
                $groups = @()
                foreach ($grp in @($settings.hooks.$ev)) {
                    if ($null -eq $grp) { continue }
                    if ($grp.PSObject.Properties['hooks']) {
                        $keep = @(@($grp.hooks) | Where-Object { -not ($_.command -and $_.command -match $HodorPattern) })
                        $removed += @($grp.hooks).Count - $keep.Count
                        if ($keep.Count -eq 0) { continue }   # grupo que solo tenia hooks de Hodor
                        $grp | Add-Member -NotePropertyName hooks -NotePropertyValue ([object[]]$keep) -Force
                    }
                    $groups += $grp
                }
                if ($groups.Count -eq 0) { $settings.hooks.PSObject.Properties.Remove($ev) }
                else { $settings.hooks | Add-Member -NotePropertyName $ev -NotePropertyValue ([object[]]$groups) -Force }
            }
            if (@($settings.hooks.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }
        }
        if ($removed -gt 0) {
            Copy-Item $claudeSettings "$claudeSettings.hodor-uninstall.bak" -Force
            Save-Json $claudeSettings $settings
            Ok "$removed hook(s) eliminados (copia: settings.json.hodor-uninstall.bak)"
        } else {
            Info "No habia hooks de Hodor"
        }
    } catch {
        Warn "No se pudo procesar ${claudeSettings}: $($_.Exception.Message)"
        Warn "Quita a mano las entradas de 'hooks' que contengan PlainConcepts\ai-hooks\dispatch.ps1"
    }
}

# 3. Copilot (VS Code + Copilot CLI) -------------------------------------------------
Step 3 "Quitando el hook de Copilot"
$copilotHook = Join-Path $env:USERPROFILE '.copilot\hooks\company-hooks.json'
if (-not (Test-Path $copilotHook)) {
    Info "No existe $copilotHook"
} elseif ((Get-Content $copilotHook -Raw -Encoding UTF8) -match 'ai-hooks') {
    try { Remove-Item $copilotHook -Force; Ok "Eliminado $copilotHook" }
    catch { Warn "No se pudo borrar ${copilotHook}: $($_.Exception.Message)" }
} else {
    Info "$copilotHook no es de Hodor; no se toca"
}

# 4. Ficheros -----------------------------------------------------------------------
Step 4 "Borrando ficheros"
if ($KeepLogs) {
    $logs = Join-Path $InstallDir 'logs'
    if (Test-Path $logs) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $zip = Join-Path $desktop ("hodor-logs-{0:yyyyMMdd-HHmmss}.zip" -f (Get-Date))
        try { Compress-Archive -Path (Join-Path $logs '*') -DestinationPath $zip -Force; Ok "Logs guardados en $zip" }
        catch { Warn "No se pudieron guardar los logs: $($_.Exception.Message)" }
    }
}
function Remove-Dir($path, $label) {
    if (-not (Test-Path $path)) { Info "No existe $path"; return }
    for ($i = 0; $i -lt 3; $i++) {
        try { Remove-Item $path -Recurse -Force -ErrorAction Stop; Ok "$label eliminado: $path"; return }
        catch { Start-Sleep -Milliseconds 700 }
    }
    Warn "No se pudo borrar $path (algun fichero en uso). Cierra Claude Code / VS Code y vuelve a ejecutar."
}
Remove-Dir $InstallDir 'Instalacion'
# Carpeta padre vacia
$parent = Split-Path $InstallDir -Parent
if ((Test-Path $parent) -and -not (Get-ChildItem $parent -Force)) { Remove-Item $parent -Force -ErrorAction SilentlyContinue }
if ($KeepRepo) { Info "Se conserva el repo en $RepoDir (-KeepRepo)" }
elseif (Test-Path (Join-Path $RepoDir 'install-local.ps1')) { Remove-Dir $RepoDir 'Repo' }
elseif (Test-Path $RepoDir) { Info "$RepoDir no parece el repo de Hodor; no se toca" }
else { Info "No existe $RepoDir" }

$progData = 'C:\ProgramData\PlainConcepts\ai-hooks'
if (Test-Path $progData) { Info "Existe otra instalacion en $progData (requiere administrador para borrarla)" }

# 5. VS Code --------------------------------------------------------------------------
Step 5 "Revisando chat.useHooks en VS Code"
$vsSettings = Join-Path $env:APPDATA 'Code\User\settings.json'
$vsBackup   = "$vsSettings.hodor.bak"
if (-not (Test-Path $vsBackup)) {
    Info "Install-Hodor.ps1 no modifico VS Code; no se toca"
} else {
    try {
        $before = Get-Content $vsBackup -Raw -Encoding UTF8 | ConvertFrom-Json
        $wasOn  = $before.PSObject.Properties['chat.useHooks'] -and $before.'chat.useHooks' -eq $true
        if (-not $wasOn -and (Test-Path $vsSettings)) {
            $now = Get-Content $vsSettings -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($now.PSObject.Properties['chat.useHooks']) {
                $now.PSObject.Properties.Remove('chat.useHooks')
                Save-Json $vsSettings $now
                Ok "chat.useHooks desactivado (estaba apagado antes de instalar Hodor)"
            }
        } else {
            Info "chat.useHooks ya estaba activado antes de Hodor; se deja como estaba"
        }
        Remove-Item $vsBackup -Force -ErrorAction SilentlyContinue
    } catch {
        Warn "No se pudo revisar VS Code: $($_.Exception.Message). Si quieres, desactiva 'chat.useHooks' a mano."
    }
}

# Resumen -------------------------------------------------------------------------------
Write-Host ""
if ($script:problems -eq 0) {
    Write-Host "== Hodor desinstalado ==" -ForegroundColor Green
} else {
    Write-Host "== Desinstalacion con $($script:problems) aviso(s): revisa los mensajes [!] de arriba ==" -ForegroundColor Yellow
}
Write-Host "Reinicia Claude Code y recarga VS Code para que dejen de cargar los hooks."
if ($script:problems -gt 0) { exit 1 }
