# lib/logrotate.ps1 - circular log rotation
# security.jsonl -> security.jsonl.1 -> security.jsonl.2 -> (deleted)

function Invoke-LogRotation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxSizeMB = 5,
        [int]$MaxFiles = 3
    )
    if (-not (Test-Path $Path)) { return }
    $maxBytes = $MaxSizeMB * 1MB
    if ((Get-Item $Path).Length -lt $maxBytes) { return }

    $oldest = "$Path.$($MaxFiles - 1)"
    if (Test-Path $oldest) { Remove-Item $oldest -Force -ErrorAction SilentlyContinue }
    for ($i = $MaxFiles - 2; $i -ge 1; $i--) {
        if (Test-Path "$Path.$i") {
            Move-Item "$Path.$i" "$Path.$($i + 1)" -Force -ErrorAction SilentlyContinue
        }
    }
    Move-Item $Path "$Path.1" -Force -ErrorAction SilentlyContinue
}
