#Requires -Version 5.1
<#
.SYNOPSIS
  Pin the lycorica HTTP-only provider in Codex managed config (no watcher).

.DESCRIPTION
  Codex UI often rewrites ~/.codex/config.toml and drops [model_providers.*].
  On Windows, ~/.codex/managed_config.toml is a higher-precedence config layer
  that merges on top of the user file. Put the provider pin there once; leave
  model / effort editable in config.toml. No polling or FileSystemWatcher.

.PARAMETER ConfigPath
  Override managed config path (default: $env:USERPROFILE\.codex\managed_config.toml).

.PARAMETER AlsoCleanUserConfig
  Also strip openai_base_url / duplicate lycorica provider bits from the user
  config.toml so the active route is unambiguous.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = $(Join-Path $env:USERPROFILE ".codex\managed_config.toml"),
    [string]$UserConfigPath = $(Join-Path $env:USERPROFILE ".codex\config.toml"),
    [string]$ProviderId = "lycorica",
    [string]$BaseUrl = "https://cursor.lycorica.com/cursor/v1",
    [switch]$AlsoCleanUserConfig
)

$ErrorActionPreference = "Stop"

$managed = @"
# Pinned by pin-codex-lycorica-provider.ps1. Codex UI rewrites config.toml
# (model / effort) but this managed layer merges on top and keeps the
# HTTP-only provider. No file watcher required.
model_provider = "$ProviderId"

[model_providers.$ProviderId]
name = "$ProviderId"
base_url = "$BaseUrl"
wire_api = "responses"
supports_websockets = false
"@

$dir = Split-Path -Parent $ConfigPath
if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir | Out-Null
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$desired = ($managed -replace "`r`n", "`n").TrimEnd() + "`n"
$current = ""
if (Test-Path -LiteralPath $ConfigPath) {
    $current = ([System.IO.File]::ReadAllText($ConfigPath) -replace "`r`n", "`n").TrimEnd() + "`n"
}
if ($current -ne $desired) {
    [System.IO.File]::WriteAllText($ConfigPath, $desired, $utf8NoBom)
    Write-Host "Wrote managed provider pin: $ConfigPath"
} else {
    Write-Host "Managed provider pin already present: $ConfigPath"
}

if (-not $AlsoCleanUserConfig) { exit 0 }
if (-not (Test-Path -LiteralPath $UserConfigPath)) { exit 0 }

function Get-BodyWithoutPinnedBits {
    param([string]$Text, [string]$Id)
    $lines = $Text -split "`r?`n", -1
    $out = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $lines.Count) {
        $trim = $lines[$i].Trim()
        if ($trim -match '^(#\s*)?model_provider\s*=') { $i++; continue }
        if ($trim -match '^(#\s*)?openai_base_url\s*=') { $i++; continue }
        if ($trim -eq "[model_providers.$Id]") {
            $i++
            while ($i -lt $lines.Count) {
                $next = $lines[$i].Trim()
                if ($next -match '^\[.+\]$' -and $next -ne "[model_providers.$Id]") { break }
                $i++
            }
            continue
        }
        [void]$out.Add($lines[$i])
        $i++
    }
    return (($out -join "`n").TrimEnd("`r", "`n", " ") + "`n")
}

$userItem = Get-Item -LiteralPath $UserConfigPath
if ($userItem.IsReadOnly) {
    Write-Warning "User config is read-only; skip clean: $UserConfigPath"
    exit 0
}

$original = [System.IO.File]::ReadAllText($UserConfigPath)
$cleaned = Get-BodyWithoutPinnedBits -Text $original -Id $ProviderId
$normOriginal = ($original -replace "`r`n", "`n").TrimEnd() + "`n"
$normCleaned = ($cleaned -replace "`r`n", "`n").TrimEnd() + "`n"
if ($normOriginal -ne $normCleaned) {
    [System.IO.File]::WriteAllText($UserConfigPath, $normCleaned, $utf8NoBom)
    Write-Host "Cleaned duplicate provider / openai_base_url from user config.toml"
} else {
    Write-Host "User config.toml already clean of duplicate provider bits"
}
