param(
    [string]$Root = "C:\CLIProxyAPI",
    [string]$BifrostData = "C:\bifrost\data",
    [string]$CurrentImage = "bifrost-patched:toolmerge-20260717-211419"
)
$ErrorActionPreference = "Stop"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $Root "backups\cursor-image-compression-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item -LiteralPath (Join-Path $Root "docker-compose.autostart.yml") -Destination $backup
if (Test-Path "C:\bifrost\edge-nginx.conf") { Copy-Item "C:\bifrost\edge-nginx.conf" $backup }
git -C (Join-Path $Root "patches\cursor-cpa-connector") status --porcelain=v1 | Set-Content (Join-Path $backup "patch-kit-status.txt")
docker inspect bifrost cpa edge-proxy 2>&1 | Set-Content (Join-Path $backup "containers.inspect.json")
docker image inspect $CurrentImage | Set-Content (Join-Path $backup "bifrost-image.inspect.json")
$configDb = Join-Path $BifrostData "config.db"
if (Test-Path $configDb) {
    @"
import sqlite3
src=sqlite3.connect(r'$configDb')
dst=sqlite3.connect(r'$(Join-Path $backup "config.db")')
src.backup(dst)
dst.close(); src.close()
"@ | python -
    Get-ChildItem "$configDb-wal", "$configDb-shm" -ErrorAction SilentlyContinue | Select-Object Name,Length,LastWriteTimeUtc | ConvertTo-Json | Set-Content (Join-Path $backup "sqlite-wal-state.json")
}
$archive = Join-Path $backup "bifrost-image.tar"
docker save -o $archive $CurrentImage
(Get-FileHash -Algorithm SHA256 $archive).Hash | Set-Content "$archive.sha256"
Write-Host $backup
