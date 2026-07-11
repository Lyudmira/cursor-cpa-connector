#Requires -Version 5.1
<#
.SYNOPSIS
  Keep the lycorica HTTP-only provider block in ~/.codex/config.toml without
  locking the whole file (so the Codex UI can still change model / effort).

.DESCRIPTION
  Codex UI writeback often drops [model_providers.*]. This script surgically
  re-applies only a pinned trailer at the end of the file:

    model_provider = "lycorica"
    [model_providers.lycorica] ... supports_websockets = false

  UI-managed keys (model, model_reasoning_effort, projects, ...) are left alone.
  openai_base_url is removed when present because it forces the built-in openai
  provider (WebSocket-capable) and fights the custom provider pin.

.PARAMETER Watch
  Stay resident and re-pin on config.toml changes via FileSystemWatcher
  (event-driven; idle CPU near zero — not a poll loop).

.PARAMETER ConfigPath
  Override path to config.toml (default: $env:USERPROFILE\.codex\config.toml).

.PARAMETER DebounceMs
  Wait this long after a filesystem event before reading/writing, so Codex can
  finish its rewrite. Default 400ms.
#>
[CmdletBinding()]
param(
    [switch]$Watch,
    [string]$ConfigPath = $(Join-Path $env:USERPROFILE ".codex\config.toml"),
    [string]$ProviderId = "lycorica",
    [string]$BaseUrl = "https://cursor.lycorica.com/cursor/v1",
    [int]$DebounceMs = 400
)

$ErrorActionPreference = "Stop"

function Get-PinnedTrailer {
    param([string]$Id, [string]$Url)
    @(
        "model_provider = `"$Id`"",
        "",
        "[model_providers.$Id]",
        "name = `"$Id`"",
        "base_url = `"$Url`"",
        "wire_api = `"responses`"",
        "supports_websockets = false",
        ""
    ) -join "`n"
}

function Get-BodyWithoutPinnedBits {
    param([string]$Text, [string]$Id)

    $lines = $Text -split "`r?`n", -1
    $out = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $lines.Count) {
        $trim = $lines[$i].Trim()

        if ($trim -match '^(#\s*)?model_provider\s*=') {
            $i++
            continue
        }
        if ($trim -match '^(#\s*)?openai_base_url\s*=') {
            $i++
            continue
        }
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

    return (($out -join "`n").TrimEnd("`r", "`n", " "))
}

function Invoke-PinCodexProvider {
    param([string]$Path, [string]$Id, [string]$Url)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Config not found: $Path"
        return $false
    }

    # Skip while the file is marked read-only; caller should clear attrib +R.
    $item = Get-Item -LiteralPath $Path
    if ($item.IsReadOnly) {
        Write-Warning "Config is read-only; clear with: attrib -R `"$Path`""
        return $false
    }

    $original = [System.IO.File]::ReadAllText($Path)
    $body = Get-BodyWithoutPinnedBits -Text $original -Id $Id
    $trailer = Get-PinnedTrailer -Id $Id -Url $Url
    if ([string]::IsNullOrWhiteSpace($body)) {
        $next = $trailer
    } else {
        $next = $body + "`n`n" + $trailer
    }

    $normOriginal = ($original -replace "`r`n", "`n").TrimEnd() + "`n"
    $normNext = ($next -replace "`r`n", "`n").TrimEnd() + "`n"
    if ($normOriginal -eq $normNext) {
        return $false
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $normNext, $utf8NoBom)
    Write-Host ("[{0}] Pinned provider trailer in {1}" -f (Get-Date -Format "HH:mm:ss"), $Path)
    return $true
}

$changed = Invoke-PinCodexProvider -Path $ConfigPath -Id $ProviderId -Url $BaseUrl
if (-not $Watch) {
    if (-not $changed) {
        Write-Host "Already pinned; no write needed."
    }
    exit 0
}

$dir = Split-Path -Parent $ConfigPath
$name = Split-Path -Leaf $ConfigPath
if (-not (Test-Path -LiteralPath $dir)) {
    throw "Config directory not found: $dir"
}

$watcher = New-Object System.IO.FileSystemWatcher $dir, $name
$watcher.NotifyFilter = [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size -bor [IO.NotifyFilters]::FileName
$watcher.IncludeSubdirectories = $false
$watcher.EnableRaisingEvents = $false

$changeTypes =
    [IO.WatcherChangeTypes]::Changed -bor
    [IO.WatcherChangeTypes]::Created -bor
    [IO.WatcherChangeTypes]::Renamed

Write-Host "Watching $ConfigPath via FileSystemWatcher (Ctrl+C to stop)..."
try {
    while ($true) {
        # Blocks until the OS reports a change — no polling.
        $null = $watcher.WaitForChanged($changeTypes)
        Start-Sleep -Milliseconds $DebounceMs
        # Drain bursty multi-event writes from the same save.
        while ($true) {
            $extra = $watcher.WaitForChanged($changeTypes, 150)
            if ($extra.TimedOut) { break }
        }
        try {
            [void](Invoke-PinCodexProvider -Path $ConfigPath -Id $ProviderId -Url $BaseUrl)
        } catch {
            Write-Warning $_.Exception.Message
        }
    }
} finally {
    $watcher.Dispose()
    Write-Host "Watcher stopped."
}
