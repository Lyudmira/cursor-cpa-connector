param(
    [string]$WorkDir = "$env:LOCALAPPDATA\Temp\cursor-cpa-connector",
    [string]$OutputDir = "C:\CLIProxyAPI",
    [string]$CPAVersion = "v7.2.50",
    [string]$CPASource = "",
    [string]$BifrostSource = "",
    [string]$BifrostRef = "main",
    [string]$BifrostImage = "bifrost-patched:local",
    [string]$BifrostData = "C:\bifrost\data",
    [string]$BifrostPort = "127.0.0.1:8080:8080",
    [switch]$SkipCPA,
    [switch]$SkipBifrost,
    [switch]$RestartCPA,
    [switch]$RestartBifrost,
    [string]$CPAConfig = "C:\CLIProxyAPI\config.yaml",
    [switch]$InitConfig,
    [switch]$UseEnv,
    [string]$EnvFile = "",
    [switch]$DefaultEndpoint
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Require-Command([string]$Name, [string]$Hint) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing command '$Name'. $Hint"
    }
}

function Reset-Directory([string]$Path) {
    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Clone-Or-Use([string]$ExistingPath, [string]$Repo, [string]$Ref, [string]$Destination) {
    if ($ExistingPath) {
        $resolved = (Resolve-Path -LiteralPath $ExistingPath).Path
        Write-Host "Using source: $resolved"
        return $resolved
    }

    if (Test-Path $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    Write-Host "Cloning $Repo ($Ref) -> $Destination"
    git clone --depth 1 --branch $Ref $Repo $Destination
    if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Repo $Ref" }
    return $Destination
}

function Save-Utf8NoBom([string]$Path, [string]$Content) {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Apply-CPA-Patch([string]$SourceRoot) {
    Write-Step "Patching CPA source"

    $responsesRequest = Join-Path $SourceRoot "internal\translator\codex\openai\responses\codex_openai-responses_request.go"
    if (-not (Test-Path $responsesRequest)) {
        throw "CPA Responses request translator not found: $responsesRequest"
    }

    $requestPatchFile = Join-Path $PSScriptRoot "codex_openai_responses_request.go"

    if (Test-Path $requestPatchFile) {
        Write-Host "Applying full CPA Responses request patch: $requestPatchFile"
        Copy-Item -Force $requestPatchFile $responsesRequest
    } else {
    $content = Get-Content -Raw -LiteralPath $responsesRequest
    $content = $content -replace "rawJSON = convertSystemRoleToDeveloper\(rawJSON\)", "rawJSON = sanitizeCodexResponsesInputItems(rawJSON)"

    $oldFuncPattern = '(?s)// convertSystemRoleToDeveloper traverses the input array.*?func convertSystemRoleToDeveloper\(rawJSON \[\]byte\) \[\]byte \{.*?return updated\s*\}'
    $sanitizeFuncPattern = '(?s)// sanitizeCodexResponsesInputItems traverses the input array.*?func normalizeFunctionCallOutputContentTypes\(itemRaw \[\]byte\) \(\[\]byte, bool, error\) \{.*?return updated, changed, nil\s*\}'
    $newFunc = @'
// sanitizeCodexResponsesInputItems traverses the input array and normalizes item
// fields to the narrower schema accepted by Codex upstream.
//
// Message items keep their role, except "system" becomes "developer". Non-message
// items such as function_call and function_call_output do not accept role.
func sanitizeCodexResponsesInputItems(rawJSON []byte) []byte {
	inputResult := gjson.GetBytes(rawJSON, "input")
	if !inputResult.IsArray() {
		return rawJSON
	}

	inputItems := inputResult.Array()
	if len(inputItems) == 0 {
		return rawJSON
	}

	changed := false
	rebuiltInput := make([]json.RawMessage, 0, len(inputItems))
	for _, item := range inputItems {
		itemRaw := []byte(item.Raw)
		if item.IsObject() {
			itemType := item.Get("type").String()
			if itemType == "message" {
				if item.Get("role").String() == "system" {
					updatedItem, errSetItem := sjson.SetBytes(itemRaw, "role", "developer")
					if errSetItem != nil {
						return rawJSON
					}
					itemRaw = updatedItem
					changed = true
				}
			} else if item.Get("role").Exists() {
				updatedItem, errDeleteItem := sjson.DeleteBytes(itemRaw, "role")
				if errDeleteItem != nil {
					return rawJSON
				}
				itemRaw = updatedItem
				changed = true
			}
			if itemType == "function_call_output" {
				updatedItem, itemChanged, errNormalizeOutput := normalizeFunctionCallOutputContentTypes(itemRaw)
				if errNormalizeOutput != nil {
					return rawJSON
				}
				itemRaw = updatedItem
				changed = changed || itemChanged
			}
		}
		rebuiltInput = append(rebuiltInput, json.RawMessage(itemRaw))
	}
	if !changed {
		return rawJSON
	}

	inputRaw, errMarshalInput := json.Marshal(rebuiltInput)
	if errMarshalInput != nil {
		return rawJSON
	}
	updated, errSetInput := sjson.SetRawBytes(rawJSON, "input", inputRaw)
	if errSetInput != nil {
		return rawJSON
	}
	return updated
}

func normalizeFunctionCallOutputContentTypes(itemRaw []byte) ([]byte, bool, error) {
	outputResult := gjson.GetBytes(itemRaw, "output")
	if !outputResult.IsArray() {
		return itemRaw, false, nil
	}

	changed := false
	updated := itemRaw
	outputItems := outputResult.Array()
	for i, outputItem := range outputItems {
		if !outputItem.IsObject() {
			continue
		}
		outputType := outputItem.Get("type").String()
		if outputType != "text" && outputType != "output_text" {
			continue
		}

		var err error
		updated, err = sjson.SetBytes(updated, fmt.Sprintf("output.%d.type", i), "input_text")
		if err != nil {
			return itemRaw, false, err
		}
		changed = true
	}

	return updated, changed, nil
}
'@
    if ($content -notmatch "output_text") {
        if ($content -match "sanitizeCodexResponsesInputItems") {
            if ($content -notmatch $sanitizeFuncPattern) {
                throw "Could not locate sanitizeCodexResponsesInputItems in $responsesRequest"
            }
            $content = [regex]::Replace($content, $sanitizeFuncPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newFunc }, 1)
        } else {
            if ($content -notmatch $oldFuncPattern) {
                throw "Could not locate convertSystemRoleToDeveloper in $responsesRequest"
            }
            $content = [regex]::Replace($content, $oldFuncPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newFunc }, 1)
        }
    }
    Save-Utf8NoBom $responsesRequest $content
    }

    $chatRequest = Join-Path $SourceRoot "internal\translator\codex\openai\chat-completions\codex_openai_request.go"
    if (Test-Path $chatRequest) {
        $chatRequestContent = Get-Content -Raw -LiteralPath $chatRequest
        $chatRequestContent = $chatRequestContent -replace 'case "text":(\s*part := \[\]byte\(`\{\}`\)\s*part, _ = sjson\.SetBytes\(part, "type", "input_text"\))', 'case "text", "output_text":$1'
        Save-Utf8NoBom $chatRequest $chatRequestContent
    } else {
        Write-Warning "CPA chat-completions request translator not found: $chatRequest; skipping output_text tool-result patch."
    }

    $chatResponsePatch = Join-Path $PSScriptRoot "codex_openai_response.go"
    $chatResponseTarget = Join-Path $SourceRoot "internal\translator\codex\openai\chat-completions\codex_openai_response.go"
    if (Test-Path $chatResponsePatch) {
        Copy-Item -Force $chatResponsePatch $chatResponseTarget
    } else {
        Write-Warning "codex_openai_response.go patch file not found next to this script; skipping chat-completions response patch."
    }

    Push-Location $SourceRoot
    try {
        gofmt -w $responsesRequest
        if (Test-Path $chatRequest) { gofmt -w $chatRequest }
        go test ./internal/translator/codex/openai/responses/...
        go test ./internal/translator/codex/openai/chat-completions/...
        if ($LASTEXITCODE -ne 0) { throw "go test failed" }

        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
        $outExe = Join-Path $OutputDir "cli-proxy-api-patched.exe"
        go build -o $outExe ./cmd/server
        if ($LASTEXITCODE -ne 0) { throw "CPA go build failed" }
        Write-Host "Built CPA: $outExe" -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

function Apply-Bifrost-Patch([string]$SourceRoot) {
    Write-Step "Patching Bifrost source"

    $responsesGo = Join-Path $SourceRoot "core\schemas\responses.go"
    if (-not (Test-Path $responsesGo)) {
        throw "Bifrost responses.go not found: $responsesGo"
    }

    $content = Get-Content -Raw -LiteralPath $responsesGo
    $content = $content -replace 'Strict\s+\*bool\s+`json:"strict"`', 'Strict     *bool                   `json:"strict,omitempty"`'

    $casePattern = '(?s)case ResponsesToolTypeFunction:\s*.*?\s*case ResponsesToolTypeFileSearch:'
    $caseReplacement = @'
case ResponsesToolTypeFunction:
		// Chat Completions nests function metadata under "function"; Responses API
		// uses top-level name/description/parameters. Cursor sends both shapes.
		if fnRaw, ok := raw["function"].(map[string]interface{}); ok {
			if t.Name == nil {
				if name, ok := fnRaw["name"].(string); ok && name != "" {
					t.Name = &name
				}
			}
			if t.Description == nil {
				if desc, ok := fnRaw["description"].(string); ok {
					t.Description = &desc
				}
			}
			if t.CacheControl == nil {
				if cacheControl, ok := fnRaw["cache_control"]; ok && cacheControl != nil {
					cacheControlBytes, err := MarshalSorted(cacheControl)
					if err != nil {
						return err
					}
					var parsedCacheControl CacheControl
					if err := Unmarshal(cacheControlBytes, &parsedCacheControl); err != nil {
						return err
					}
					t.CacheControl = &parsedCacheControl
				}
			}
		}

		funcPayload := data
		if fnRaw, ok := raw["function"]; ok && fnRaw != nil {
			fnBytes, err := MarshalSorted(fnRaw)
			if err != nil {
				return err
			}
			funcPayload = fnBytes
		}

		var funcTool ResponsesToolFunction
		if err := Unmarshal(funcPayload, &funcTool); err != nil {
			return err
		}

		// Cursor flat format uses input_schema instead of parameters.
		if funcTool.Parameters == nil {
			if inputSchema, ok := raw["input_schema"]; ok {
				schemaBytes, err := MarshalSorted(inputSchema)
				if err != nil {
					return err
				}
				var params ToolFunctionParameters
				if err := Unmarshal(schemaBytes, &params); err != nil {
					return err
				}
				funcTool.Parameters = &params
			}
		}

		t.ResponsesToolFunction = &funcTool

	case ResponsesToolTypeFileSearch:
'@
    if ($content -notmatch "parsedCacheControl") {
        if ($content -notmatch $casePattern) {
            throw "Could not locate ResponsesToolTypeFunction switch block in $responsesGo"
        }
        $content = [regex]::Replace($content, $casePattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $caseReplacement }, 1)
    }
    Save-Utf8NoBom $responsesGo $content

    $cursorGo = Join-Path $SourceRoot "transports\bifrost-http\integrations\cursor.go"
    if (-not (Test-Path $cursorGo)) {
        throw "Bifrost Cursor integration not found: $cursorGo"
    }

    $cursorContent = Get-Content -Raw -LiteralPath $cursorGo
    if ($cursorContent -notmatch "normalizeCursorFunctionCallOutputs") {
        $cursorContent = $cursorContent -replace 'cursorMergeToolResultsFromMessages\(data, cursorReq\)\r?\n\s*normalizeInputContentBlocks\(cursorReq\)', "cursorMergeToolResultsFromMessages(data, cursorReq)`r`n`t`tnormalizeCursorFunctionCallOutputs(cursorReq)`r`n`t`tnormalizeInputContentBlocks(cursorReq)"

        $normalizeMarker = '// normalizeInputContentBlocks ensures all input messages have ContentBlocks instead of'
        $normalizeFunction = @"
// normalizeCursorFunctionCallOutputs rewrites Cursor's non-standard text aliases
// to the input_text content type required for Responses API tool-result history.
func normalizeCursorFunctionCallOutputs(req *openai.OpenAIResponsesRequest) {
	for i := range req.Input.OpenAIResponsesRequestInputArray {
		msg := &req.Input.OpenAIResponsesRequestInputArray[i]
		if msg.Type == nil || *msg.Type != schemas.ResponsesMessageTypeFunctionCallOutput || msg.ResponsesToolMessage == nil || msg.Output == nil {
			continue
		}
		for j := range msg.Output.ResponsesFunctionToolCallOutputBlocks {
			block := &msg.Output.ResponsesFunctionToolCallOutputBlocks[j]
			if block.Type == "text" || block.Type == schemas.ResponsesOutputMessageContentTypeText {
				block.Type = schemas.ResponsesInputMessageContentBlockTypeText
			}
		}
	}
}

"@
        if (-not $cursorContent.Contains($normalizeMarker)) {
            throw "Could not locate Cursor input normalization marker in $cursorGo"
        }
        $cursorContent = $cursorContent.Replace($normalizeMarker, $normalizeFunction + $normalizeMarker)
        Save-Utf8NoBom $cursorGo $cursorContent
    }

    Push-Location $SourceRoot
    try {
        gofmt -w $responsesGo $cursorGo
        go test ./core/schemas/...
        if ($LASTEXITCODE -ne 0) { throw "Bifrost schema tests failed" }

        $dockerfile = Join-Path $PSScriptRoot "Dockerfile.bifrost-patched"
        docker build -f $dockerfile -t $BifrostImage --build-arg VERSION=local-patch .
        if ($LASTEXITCODE -ne 0) { throw "Bifrost docker build failed" }
        Write-Host "Built Bifrost image: $BifrostImage" -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

function Restart-CPA-Service {
    Write-Step "Restarting CPA"
    $exe = Join-Path $OutputDir "cli-proxy-api-patched.exe"
    if (-not (Test-Path $exe)) { throw "Patched CPA exe not found: $exe" }

    Get-CimInstance Win32_Process |
        Where-Object { $_.CommandLine -like "*cli-proxy-api*.exe*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

    Start-Sleep -Seconds 2
    Start-Process -FilePath $exe -ArgumentList "-config", $CPAConfig -WorkingDirectory $OutputDir -WindowStyle Hidden
    Write-Host "Started CPA: $exe -config $CPAConfig" -ForegroundColor Green
}

function Restart-Bifrost-Container {
    Write-Step "Restarting Bifrost container"
    New-Item -ItemType Directory -Force -Path $BifrostData | Out-Null
    docker stop bifrost 2>$null | Out-Null
    docker rm bifrost 2>$null | Out-Null
    docker run -d --name bifrost --restart unless-stopped -p $BifrostPort -v "${BifrostData}:/app/data" $BifrostImage
    if ($LASTEXITCODE -ne 0) { throw "docker run failed for Bifrost" }
    Write-Host "Started Bifrost container from $BifrostImage" -ForegroundColor Green
}

Require-Command git "Install Git for Windows."
Require-Command go "Install Go."
if (-not $SkipBifrost) {
    Require-Command docker "Install Docker Desktop and start it."
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

if ($InitConfig) {
    Write-Step "Initializing CPA/Bifrost upstream config"
    $initScript = Join-Path $PSScriptRoot "init-config.ps1"
    if (-not (Test-Path -LiteralPath $initScript)) {
        throw "Missing init-config.ps1 next to install script: $initScript"
    }
    $initArgs = @{
        CPAConfig   = $CPAConfig
        BifrostData = $BifrostData
    }
    if ($UseEnv) { $initArgs.UseEnv = $true }
    if ($EnvFile) { $initArgs.EnvFile = $EnvFile }
    if ($DefaultEndpoint) { $initArgs.DefaultEndpoint = $true }
    & $initScript @initArgs
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        throw "init-config.ps1 failed with exit $LASTEXITCODE"
    }
}

if (-not $SkipCPA) {
    $cpaSrc = Clone-Or-Use $CPASource "https://github.com/router-for-me/CLIProxyAPI.git" $CPAVersion (Join-Path $WorkDir "CLIProxyAPI-src")
    Apply-CPA-Patch $cpaSrc
}

if (-not $SkipBifrost) {
    $bifrostSrc = Clone-Or-Use $BifrostSource "https://github.com/maximhq/bifrost.git" $BifrostRef (Join-Path $WorkDir "bifrost-src")
    Apply-Bifrost-Patch $bifrostSrc
}

if ($RestartCPA) {
    Restart-CPA-Service
}

if ($RestartBifrost) {
    Restart-Bifrost-Container
}

Write-Step "Done"
Write-Host "CPA exe:      $(Join-Path $OutputDir 'cli-proxy-api-patched.exe')"
Write-Host "Bifrost img:  $BifrostImage"
Write-Host "Restart CPA manually:     & '$(Join-Path $OutputDir 'cli-proxy-api-patched.exe')' -config '$CPAConfig'"
Write-Host "Restart Bifrost manually: docker run -d --name bifrost --restart unless-stopped -p $BifrostPort -v `"${BifrostData}:/app/data`" $BifrostImage"
