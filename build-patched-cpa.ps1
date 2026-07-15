# Build CLIProxyAPI v7.2.50 with PR #4079 custom_tool_call fix
$ErrorActionPreference = 'Stop'

$src = 'C:\Users\SurfacePro8\AppData\Local\Temp\CLIProxyAPI-src'
$chatResponsePatch = 'C:\cliproxyapi\patches\codex_openai_response.go'
$chatResponseTarget = Join-Path $src 'internal\translator\codex\openai\chat-completions\codex_openai_response.go'
$responsesRequestPatch = 'C:\cliproxyapi\patches\codex_openai_responses_request.go'
$responsesRequestTarget = Join-Path $src 'internal\translator\codex\openai\responses\codex_openai-responses_request.go'
$chatRequestTarget = Join-Path $src 'internal\translator\codex\openai\chat-completions\codex_openai_request.go'
$outDir = 'C:\cliproxyapi'
$outExe = Join-Path $outDir 'cli-proxy-api-patched.exe'

if (-not (Test-Path $src)) {
    throw "Source not found: $src`nClone v7.2.50 first: git clone --depth 1 --branch v7.2.50 https://github.com/router-for-me/CLIProxyAPI.git $src"
}

Copy-Item -Force $chatResponsePatch $chatResponseTarget
Copy-Item -Force $responsesRequestPatch $responsesRequestTarget
$chatRequestContent = Get-Content -Raw -LiteralPath $chatRequestTarget
$chatRequestContent = $chatRequestContent -replace 'case "text":(\s*part := \[\]byte\(`\{\}`\)\s*part, _ = sjson\.SetBytes\(part, "type", "input_text"\))', 'case "text", "output_text":$1'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($chatRequestTarget, $chatRequestContent, $utf8NoBom)

Push-Location $src
try {
    gofmt -w $chatRequestTarget
    go test ./internal/translator/codex/openai/chat-completions/...
    go test ./internal/translator/codex/openai/responses/...
    go build -o $outExe ./cmd/server
} finally {
    Pop-Location
}

Write-Host "Built: $outExe"

# --- Deploy tail: build the Linux image from the SAME patched source tree and
# redeploy the `cpa` container. This is what actually serves 127.0.0.1:8317 in
# prod now (see Dockerfile.cpa-patched); the .exe above is kept only for local
# Windows-side testing/debugging, it is not what runs day to day anymore. ---
$dockerfile = 'C:\CLIProxyAPI\Dockerfile.cpa-patched'
$configDocker = 'C:\CLIProxyAPI\config.docker.yaml'
$authsDir = 'C:\CLIProxyAPI\auths'
$logsDir = 'C:\CLIProxyAPI\logs'
$image = 'cpa-patched:local'
$container = 'cpa'

$dockerAvailable = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerAvailable) {
    Write-Warning "docker CLI not found; skipping image build/redeploy. Exe built at $outExe only."
    exit 0
}

Write-Host "Building $image from $src ..."
docker build -f $dockerfile -t $image --build-arg VERSION=v7.2.50-patched "$src"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Stopping old $container container..."
docker stop $container 2>$null
docker rm $container 2>$null

Write-Host "Starting patched $container container..."
docker run -d `
    --name $container `
    --restart unless-stopped `
    -p 127.0.0.1:8317:8317 `
    -v "${configDocker}:/CLIProxyAPI/config.yaml:ro" `
    -v "${authsDir}:/CLIProxyAPI/auths" `
    -v "${logsDir}:/CLIProxyAPI/logs" `
    $image
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Waiting for cpa to come up..."
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 2
    try {
        $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:8317/' -UseBasicParsing -TimeoutSec 3
        if ($resp.StatusCode -eq 200) {
            Write-Host "cpa is up (200 on /)."
            exit 0
        }
    } catch {
        # not up yet, keep polling
    }
}
Write-Host "cpa container started but did not answer 200 within 30s; check: docker logs cpa"
exit 0
