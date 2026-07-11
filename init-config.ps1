param(
    [string]$EnvFile = "",
    [switch]$UseEnv,
    [switch]$DefaultEndpoint,
    [switch]$DryRun,
    [switch]$Force,
    [string]$CPAConfig = "C:\CLIProxyAPI\config.yaml",
    [string]$BifrostData = "C:\bifrost\data",
    [string]$CPABaseUrl = "http://host.docker.internal:8317/v1",
    [string]$CPAApiKey = "sk-cpa-local"
)

$ErrorActionPreference = "Stop"

$DefaultPrimaryUrl = "https://api.muskapi.cc/v1"
$DefaultBackupUrl = "https://ai.centos.hk/v1"
$ScriptDir = $PSScriptRoot
$PyHelper = Join-Path $ScriptDir "init_bifrost_config.py"

function Require-Python {
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        throw "python is required for Bifrost config.db updates. Install Python 3 and ensure 'python' is on PATH."
    }
}

function Read-DotEnv([string]$Path) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Env file not found: $Path (pass -EnvFile or create .env from .env.example)"
    }
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) { return }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { return }
        $k = $line.Substring(0, $idx).Trim()
        $v = $line.Substring($idx + 1).Trim()
        if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        $map[$k] = $v
    }
    return $map
}

function Ensure-CPAApiKey([string]$ConfigPath, [string]$ApiKey, [switch]$DryRunSwitch) {
    $dir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $template = @"
host: "0.0.0.0"
port: 8317
auth-dir: "C:\\CLIProxyAPI\\auths"
api-keys:
  - "$ApiKey"
remote-management:
  allow-remote: true
  disable-control-panel: false
debug: false
logging-to-file: true
request-retry: 3
routing:
  strategy: "fill-first"
  session-affinity: false
"@
        Write-Host "CPA config missing; will write minimal template: $ConfigPath"
        Write-Host "Complete CPA login (OAuth) before using Codex models."
        if (-not $DryRunSwitch) {
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($ConfigPath, $template, $utf8NoBom)
        }
        return
    }

    $raw = Get-Content -LiteralPath $ConfigPath -Raw
    if ($raw -match [regex]::Escape($ApiKey)) {
        Write-Host "CPA config already contains api-key."
        return
    }

    if ($raw -match '(?m)^api-keys:\s*$') {
        $updated = [regex]::Replace($raw, '(?m)^api-keys:\s*$', "api-keys:`r`n  - `"$ApiKey`"", 1)
    } elseif ($raw -match '(?m)^api-keys:') {
        $updated = [regex]::Replace($raw, '(?m)^(api-keys:\s*(?:\r?\n(?:[ \t]+-[^\r\n]*\r?\n?)*))', "`$1  - `"$ApiKey`"`r`n", 1)
    } else {
        $updated = $raw.TrimEnd() + "`r`napi-keys:`r`n  - `"$ApiKey`"`r`n"
    }

    Write-Host "Will ensure CPA api-keys contains the local Bifrost->CPA key."
    if (-not $DryRunSwitch) {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($ConfigPath, $updated, $utf8NoBom)
    }
}

function Get-InteractiveConfig([switch]$UseDefaultEndpoint) {
    Write-Host ""
    Write-Host "CPA is assumed already logged in (OAuth). Configure OpenAI-compatible upstreams in Bifrost."
    Write-Host ""
    Write-Host "Why two endpoints (backup is optional):"
    Write-Host "  - Primary: normal GPT + Anthropic traffic"
    Write-Host "  - Backup: models primary does not offer, and failover if primary fails"
    Write-Host "  - No backup? Press Enter on the backup prompts to skip."
    Write-Host ""

    Write-Host "[1/2] Primary endpoint (GPT + Anthropic first hop)"
    if ($UseDefaultEndpoint) {
        $primaryUrl = Read-Host "      Base URL [$DefaultPrimaryUrl]"
        if ([string]::IsNullOrWhiteSpace($primaryUrl)) { $primaryUrl = $DefaultPrimaryUrl }
    } else {
        do {
            $primaryUrl = Read-Host "      Base URL (required)"
            if ([string]::IsNullOrWhiteSpace($primaryUrl)) {
                Write-Host "      Primary Base URL is required unless you pass -DefaultEndpoint." -ForegroundColor Yellow
            }
        } while ([string]::IsNullOrWhiteSpace($primaryUrl))
    }

    do {
        $primaryKey = Read-Host "      API key"
        if ([string]::IsNullOrWhiteSpace($primaryKey)) {
            Write-Host "      Primary API key is required." -ForegroundColor Yellow
        }
    } while ([string]::IsNullOrWhiteSpace($primaryKey))

    Write-Host ""
    Write-Host "[2/2] Backup endpoint (optional — press Enter to skip if you do not have one)"
    Write-Host "      Suggested default if you want a backup: $DefaultBackupUrl"
    $backupUrl = Read-Host "      Base URL (Enter=skip)"
    $backupKey = $null
    if (-not [string]::IsNullOrWhiteSpace($backupUrl)) {
        do {
            $backupKey = Read-Host "      API key"
            if ([string]::IsNullOrWhiteSpace($backupKey)) {
                Write-Host "      Backup API key is required after providing a backup URL (or Enter Base URL empty to skip)." -ForegroundColor Yellow
            }
        } while ([string]::IsNullOrWhiteSpace($backupKey))
    } else {
        Write-Host "      Skipping backup upstream."
    }

    return [pscustomobject]@{
        PrimaryUrl = $primaryUrl.Trim()
        PrimaryKey = $primaryKey.Trim()
        BackupUrl  = if ($backupUrl) { $backupUrl.Trim() } else { $null }
        BackupKey  = if ($backupKey) { $backupKey.Trim() } else { $null }
    }
}

function Get-EnvConfig([string]$Path) {
    $map = Read-DotEnv $Path

    if ($map.ContainsKey("CPA_CONFIG") -and $map["CPA_CONFIG"]) { $script:CPAConfig = $map["CPA_CONFIG"] }
    if ($map.ContainsKey("BIFROST_DATA") -and $map["BIFROST_DATA"]) { $script:BifrostData = $map["BIFROST_DATA"] }
    if ($map.ContainsKey("CPA_BASE_URL") -and $map["CPA_BASE_URL"]) { $script:CPABaseUrl = $map["CPA_BASE_URL"] }
    if ($map.ContainsKey("CPA_API_KEY") -and $map["CPA_API_KEY"]) { $script:CPAApiKey = $map["CPA_API_KEY"] }

    $primaryUrl = if ($map.ContainsKey("PRIMARY_BASE_URL") -and $map["PRIMARY_BASE_URL"]) { $map["PRIMARY_BASE_URL"] } else { $DefaultPrimaryUrl }
    $primaryKey = if ($map.ContainsKey("PRIMARY_API_KEY")) { $map["PRIMARY_API_KEY"] } else { "" }
    if ([string]::IsNullOrWhiteSpace($primaryKey)) {
        throw "PRIMARY_API_KEY is required in $Path for -UseEnv"
    }

    $backupKey = if ($map.ContainsKey("BACKUP_API_KEY")) { $map["BACKUP_API_KEY"] } else { "" }
    $backupUrl = $null
    if (-not [string]::IsNullOrWhiteSpace($backupKey)) {
        $backupUrl = if ($map.ContainsKey("BACKUP_BASE_URL") -and $map["BACKUP_BASE_URL"]) { $map["BACKUP_BASE_URL"] } else { $DefaultBackupUrl }
    }

    return [pscustomobject]@{
        PrimaryUrl = $primaryUrl.Trim()
        PrimaryKey = $primaryKey.Trim()
        BackupUrl  = if ($backupUrl) { $backupUrl.Trim() } else { $null }
        BackupKey  = if ($backupKey) { $backupKey.Trim() } else { $null }
    }
}

Require-Python
if (-not (Test-Path -LiteralPath $PyHelper)) {
    throw "Missing helper script: $PyHelper"
}

Write-Host "==> init-config" -ForegroundColor Cyan
if ($Force) {
    Write-Host "Note: -Force accepted (upserts always overwrite matching providers/keys/routes)."
}

if ($UseEnv) {
    if (-not $EnvFile) { $EnvFile = Join-Path $ScriptDir ".env" }
    Write-Host "Using env file: $EnvFile"
    $cfg = Get-EnvConfig $EnvFile
} else {
    if ($EnvFile) {
        Write-Host "Ignoring -EnvFile because -UseEnv was not set (interactive is default)." -ForegroundColor Yellow
    }
    $cfg = Get-InteractiveConfig -UseDefaultEndpoint:$DefaultEndpoint
}

Write-Host ""
Write-Host "Summary:"
Write-Host "  Primary: $($cfg.PrimaryUrl)"
if ($cfg.BackupUrl) {
    Write-Host "  Backup:  $($cfg.BackupUrl)"
} else {
    Write-Host "  Backup:  (skipped)"
}
Write-Host "  CPA:     $CPABaseUrl  (config: $CPAConfig)"
Write-Host "  Bifrost: $(Join-Path $BifrostData 'config.db')"

Ensure-CPAApiKey -ConfigPath $CPAConfig -ApiKey $CPAApiKey -DryRunSwitch:$DryRun

$dbPath = Join-Path $BifrostData "config.db"
$pyArgs = @(
    $PyHelper,
    "--db", $dbPath,
    "--primary-url", $cfg.PrimaryUrl,
    "--primary-key", $cfg.PrimaryKey,
    "--cpa-url", $CPABaseUrl,
    "--cpa-key", $CPAApiKey
)
if ($cfg.BackupUrl -and $cfg.BackupKey) {
    $pyArgs += @("--backup-url", $cfg.BackupUrl, "--backup-key", $cfg.BackupKey)
}
if ($DryRun) { $pyArgs += "--dry-run" }

& python @pyArgs
if ($LASTEXITCODE -ne 0) { throw "init_bifrost_config.py failed with exit $LASTEXITCODE" }

Write-Host ""
Write-Host "Done." -ForegroundColor Green
if (-not $DryRun) {
    Write-Host "If Bifrost is running, restart it to reload config.db:"
    Write-Host "  docker restart bifrost"
}
