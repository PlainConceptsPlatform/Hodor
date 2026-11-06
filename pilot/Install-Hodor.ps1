# Install-Hodor.ps1 - Instalacion del piloto de Hodor (hooks de IA) en un solo paso.
#
# Uso (PowerShell, sin permisos de administrador):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Hodor.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Hodor.ps1 -Token <TOKEN>
#
# Que hace:
#   1. Comprueba requisitos (Git)
#   2. Clona (o actualiza) el repo en %USERPROFILE%\Hodor
#   3. Obtiene tu UPN corporativo (whoami /upn) como identidad
#   4. Ejecuta install-local.ps1 con el endpoint de Atlas y el token
#   5. Activa chat.useHooks en VS Code (si esta instalado)
#   6. Lanza el selftest para comprobar que la telemetria llega
param(
    [string]$Token,
    [string]$Email,
    [string]$RepoDir = (Join-Path $env:USERPROFILE 'Hodor')
)

# --- Configuracion del piloto ---------------------------------------------------
$RepoUrl      = 'https://github.com/PlainConceptsPlatform/Hodor.git'
$OtelEndpoint = 'https://atlas-api.plainconcepts.com/api/v1/ai-hooks'
$DefaultToken = ''   # opcional: rellenar antes de repartir el script para no pedir el token
$InstallDir   = Join-Path $env:LOCALAPPDATA 'PlainConcepts\ai-hooks'
# -------------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
function Step($n, $msg) { Write-Host ""; Write-Host "[$n/6] $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [!]  $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "  [X]  $msg" -ForegroundColor Red; exit 1 }

Write-Host "== Instalacion del piloto de Hodor ==" -ForegroundColor White

# 1. Requisitos -----------------------------------------------------------------
Step 1 "Comprobando requisitos"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail "Git no esta instalado o no esta en el PATH. Instalalo (https://git-scm.com/download/win) y vuelve a ejecutar."
}
Ok "Git encontrado"

if (-not $Token) { $Token = $DefaultToken }
if (-not $Token -and $env:HODOR_TOKEN) { $Token = $env:HODOR_TOKEN }
if (-not $Token) { $Token = Read-Host "  Pega el token de Atlas (sin 'Bearer')" }
$Token = ($Token -replace '^\s*Bearer\s+', '').Trim()
if (-not $Token) { Fail "No se ha indicado el token." }
Ok "Token recibido"

# 2. Repo -----------------------------------------------------------------------
Step 2 "Descargando Hodor en $RepoDir"
if (Test-Path (Join-Path $RepoDir '.git')) {
    & git -C $RepoDir pull --ff-only
    if ($LASTEXITCODE -ne 0) { Fail "No se pudo actualizar $RepoDir (git pull). Borra la carpeta y vuelve a ejecutar." }
    Ok "Repo actualizado"
} elseif (Test-Path $RepoDir) {
    Fail "$RepoDir ya existe y no es un repo git. Borrala o usa -RepoDir <otra carpeta>."
} else {
    & git clone $RepoUrl $RepoDir
    if ($LASTEXITCODE -ne 0) { Fail "No se pudo clonar $RepoUrl" }
    Ok "Repo clonado"
}

# 3. Identidad (UPN) -------------------------------------------------------------
Step 3 "Obteniendo tu identidad corporativa"
if (-not $Email) {
    # Ruta completa: con Git for Windows en el PATH, 'whoami' puede ser el de Git y no acepta /upn
    $whoami = Join-Path $env:WINDIR 'System32\whoami.exe'
    try { $Email = ("" + (& $whoami /upn 2>$null)).Trim() } catch { $Email = '' }
}
if ($Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    Warn "No se pudo obtener el UPN automaticamente."
    $Email = (Read-Host "  Escribe tu email corporativo (@plainconcepts.com)").Trim()
}
if ($Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { Fail "Email no valido: '$Email'" }
if ($Email -notmatch '@plainconcepts\.com$') { Warn "La identidad '$Email' no es @plainconcepts.com. Revisa que sea tu cuenta corporativa." }
Ok "Identidad: $Email"

# 4. Instalacion -----------------------------------------------------------------
Step 4 "Instalando hooks en $InstallDir"
$installer = Join-Path $RepoDir 'install-local.ps1'
if (-not (Test-Path $installer)) { Fail "No se encuentra $installer" }
& powershell -NoProfile -ExecutionPolicy Bypass -File $installer `
    -Dest $InstallDir `
    -OtelEndpoint $OtelEndpoint `
    -OtelToken $Token `
    -IdentityEmail $Email
if ($LASTEXITCODE -ne 0) { Fail "El instalador ha fallado (exit $LASTEXITCODE). Revisa la salida de arriba." }
Ok "Hooks instalados para Claude Code y Copilot"

# 5. VS Code: chat.useHooks ------------------------------------------------------
Step 5 "Activando chat.useHooks en VS Code"
$vsDir = Join-Path $env:APPDATA 'Code\User'
$vsSettings = Join-Path $vsDir 'settings.json'
if (-not (Test-Path $vsDir)) {
    Warn "VS Code no parece instalado para este usuario. Se omite."
} else {
    $done = $false
    try {
        if (Test-Path $vsSettings) {
            $raw = Get-Content $vsSettings -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '{}' }
            $obj = $raw | ConvertFrom-Json   # falla si el fichero tiene comentarios o comas finales (JSONC)
        } else {
            $obj = [pscustomobject]@{}
        }
        if ($obj.PSObject.Properties['chat.useHooks'] -and $obj.'chat.useHooks' -eq $true) {
            Ok "Ya estaba activado"
        } else {
            if (Test-Path $vsSettings) { Copy-Item $vsSettings "$vsSettings.hodor.bak" -Force }
            $obj | Add-Member -NotePropertyName 'chat.useHooks' -NotePropertyValue $true -Force
            [System.IO.File]::WriteAllText($vsSettings, ($obj | ConvertTo-Json -Depth 32), (New-Object System.Text.UTF8Encoding($false)))
            Ok "Activado (copia de seguridad: settings.json.hodor.bak)"
        }
        $done = $true
    } catch { }
    if (-not $done) {
        Warn "Tu settings.json de VS Code tiene comentarios o formato no estandar; no lo toco."
        Warn "Activalo a mano: Settings > busca 'chat.useHooks' > marcalo."
    }
}

# 6. Selftest --------------------------------------------------------------------
Step 6 "Comprobando el envio de telemetria (selftest)"
$dispatch = Join-Path $InstallDir 'dispatch.ps1'
$out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $dispatch -Event selftest 2>&1 | Out-String).Trim()
$selftestOk = ($LASTEXITCODE -eq 0) -and ($out -match '"ok"\s*:\s*true')
if ($selftestOk) {
    Ok "La telemetria llega a Atlas"
} else {
    Warn "El selftest ha fallado. Mandale esta salida a quien te paso el script:"
    Write-Host $out
}

# Resumen ------------------------------------------------------------------------
Write-Host ""
Write-Host "== Listo ==" -ForegroundColor Green
Write-Host "Siguientes pasos:"
Write-Host "  1. Cierra y vuelve a abrir Claude Code."
Write-Host "  2. En VS Code: Ctrl+Shift+P > 'Developer: Reload Window'."
Write-Host "  3. Pasa la bateria de pruebas:"
Write-Host "     https://github.com/PlainConceptsPlatform/Hodor/blob/main/docs/manual-test-battery.md"
Write-Host ""
Write-Host "Diagnostico si algo falla:"
Write-Host ('  powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $InstallDir 'tools\hodor-version.ps1') + '"')
if (-not $selftestOk) { exit 2 }
