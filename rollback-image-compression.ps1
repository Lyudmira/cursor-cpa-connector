param(
    [Parameter(Mandatory=$true)][string]$Backup,
    [string]$Root = "C:\CLIProxyAPI",
    [string]$BifrostData = "C:\bifrost\data",
    [string]$OldImage = "bifrost-patched:toolmerge-20260717-211419"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType File -Force -Path (Join-Path $BifrostData "disable-image-compression") | Out-Null
docker stop cursor-image-compressor 2>$null | Out-Null
Copy-Item -Force (Join-Path $Backup "docker-compose.autostart.yml") (Join-Path $Root "docker-compose.autostart.yml")
if (Test-Path (Join-Path $Backup "edge-nginx.conf")) { Copy-Item -Force (Join-Path $Backup "edge-nginx.conf") "C:\bifrost\edge-nginx.conf" }
if (-not (docker image inspect $OldImage 2>$null)) {
    docker load -i (Join-Path $Backup "bifrost-image.tar")
}
docker compose -f (Join-Path $Root "docker-compose.autostart.yml") up -d --no-build cpa bifrost edge-proxy
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8081/health | Out-Null
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8080/cursor/v1/models | Out-Null
Write-Host "Rollback completed; kill switch remains enabled."
