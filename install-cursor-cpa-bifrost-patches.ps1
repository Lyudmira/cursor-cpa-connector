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
    [switch]$SkipBifrostBuild,
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

function Resolve-RealCommandPath([string]$Name) {
    $command = Get-Command $Name -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $path = $command.Source
    if ($path -like "*\scoop\shims\*" -and (Get-Command scoop -ErrorAction SilentlyContinue)) {
        $candidate = (& scoop which $Name | Select-Object -First 1)
        if ($candidate) {
            $path = (Resolve-Path -LiteralPath $candidate.Trim()).Path
        }
    }
    return $path
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
    $requestTestPatchFile = Join-Path $PSScriptRoot "codex_openai_responses_request_image_test.go"
    $requestTestTarget = Join-Path $SourceRoot "internal\translator\codex\openai\responses\codex_openai-responses_request_image_test.go"

    if (Test-Path $requestPatchFile) {
        Write-Host "Applying full CPA Responses request patch: $requestPatchFile"
        Copy-Item -Force $requestPatchFile $responsesRequest
        if (Test-Path $requestTestPatchFile) {
            Copy-Item -Force $requestTestPatchFile $requestTestTarget
        }
    } else {
    $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $responsesRequest
    if ($content -notmatch '"strings"') {
        $content = $content -replace '("fmt"\r?\n)', "`$1`t`"strings`"`r`n"
    }
    $content = $content -replace "rawJSON = convertSystemRoleToDeveloper\(rawJSON\)", "rawJSON = sanitizeCodexResponsesInputItems(modelName, rawJSON)"
    $content = $content -replace "rawJSON = sanitizeCodexResponsesInputItems\(rawJSON\)", "rawJSON = sanitizeCodexResponsesInputItems(modelName, rawJSON)"

    $oldFuncPattern = '(?s)// convertSystemRoleToDeveloper traverses the input array.*?func convertSystemRoleToDeveloper\(rawJSON \[\]byte\) \[\]byte \{.*?return updated\s*\}'
    $sanitizeFuncPattern = '(?s)// sanitizeCodexResponsesInputItems traverses the input array.*?func normalizeFunctionCallOutputContentTypes\(itemRaw \[\]byte\) \(\[\]byte, bool, error\) \{.*?return updated, changed, nil\s*\}'
    $newFunc = @'
// sanitizeCodexResponsesInputItems traverses the input array and normalizes item
// fields to the narrower schema accepted by Codex upstream.
//
// Message items keep their role, except "system" becomes "developer".
//
// Known legacy Codex models rejected role on non-message history items such as
// function_call/function_call_output, so preserve that broad cleanup for them.
// Newer models may send additional_tools as a developer-scoped input item;
// stripping that role causes "Missing required parameter: input[0].role".
func sanitizeCodexResponsesInputItems(modelName string, rawJSON []byte) []byte {
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
			} else if shouldStripCodexInputRole(modelName, itemType) && item.Get("role").Exists() {
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
			if itemType == "additional_tools" {
				updatedItem, itemChanged, errNormalizeTools := normalizeAdditionalToolsInputItem(itemRaw)
				if errNormalizeTools != nil {
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

func shouldStripCodexInputRole(modelName string, itemType string) bool {
	if itemType == "message" {
		return false
	}
	if isLegacyCodexInputRoleModel(modelName) {
		return true
	}
	return itemType != "additional_tools"
}

func isLegacyCodexInputRoleModel(modelName string) bool {
	model := strings.ToLower(strings.TrimSpace(modelName))
	if slash := strings.LastIndex(model, "/"); slash >= 0 {
		model = strings.TrimSpace(model[slash+1:])
	}
	switch model {
	case "gpt-5.2",
		"gpt-5.3",
		"gpt-5.3-codex",
		"gpt-5.3-codex-spark",
		"gpt-5.3-codex-spark-preview",
		"gpt-5.4",
		"gpt-5.4-mini",
		"gpt-5.4-openai-compact",
		"gpt-5.5",
		"gpt-5.5-openai-compact":
		return true
	default:
		return false
	}
}

func normalizeAdditionalToolsInputItem(itemRaw []byte) ([]byte, bool, error) {
	toolsResult := gjson.GetBytes(itemRaw, "tools")
	if !toolsResult.IsArray() {
		return itemRaw, false, nil
	}

	changed := false
	rebuiltTools := make([]json.RawMessage, 0, len(toolsResult.Array()))
	for _, tool := range toolsResult.Array() {
		toolRaw := []byte(tool.Raw)
		if tool.IsObject() {
			inputSchema := tool.Get("input_schema")
			if !tool.Get("type").Exists() {
				toolType := "function"
				if inputSchema.Exists() && inputSchema.Type == gjson.Null {
					toolType = "custom"
				}
				updatedTool, errSetType := sjson.SetBytes(toolRaw, "type", toolType)
				if errSetType != nil {
					return itemRaw, false, errSetType
				}
				toolRaw = updatedTool
				changed = true
			}

			tool = gjson.ParseBytes(toolRaw)
			inputSchema = tool.Get("input_schema")
			if inputSchema.Exists() {
				if inputSchema.Type != gjson.Null && tool.Get("type").String() == "function" && !tool.Get("parameters").Exists() {
					var errSetParameters error
					toolRaw, errSetParameters = sjson.SetRawBytes(toolRaw, "parameters", []byte(inputSchema.Raw))
					if errSetParameters != nil {
						return itemRaw, false, errSetParameters
					}
					changed = true
				}

				updatedTool, errDeleteInputSchema := sjson.DeleteBytes(toolRaw, "input_schema")
				if errDeleteInputSchema != nil {
					return itemRaw, false, errDeleteInputSchema
				}
				toolRaw = updatedTool
				changed = true
			}
		}
		rebuiltTools = append(rebuiltTools, json.RawMessage(toolRaw))
	}
	if !changed {
		return itemRaw, false, nil
	}

	toolsRaw, errMarshalTools := json.Marshal(rebuiltTools)
	if errMarshalTools != nil {
		return itemRaw, false, errMarshalTools
	}
	updated, errSetTools := sjson.SetRawBytes(itemRaw, "tools", toolsRaw)
	if errSetTools != nil {
		return itemRaw, false, errSetTools
	}
	return updated, true, nil
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
		normalizedType := ""
		switch outputType {
		case "text", "output_text":
			normalizedType = "input_text"
		case "image_url":
			imageURL := outputItem.Get("image_url")
			if imageURL.IsObject() {
				url := imageURL.Get("url")
				if url.Type != gjson.String {
					continue
				}

				var err error
				updated, err = sjson.SetBytes(updated, fmt.Sprintf("output.%d.image_url", i), url.String())
				if err != nil {
					return itemRaw, false, err
				}
				if detail := imageURL.Get("detail"); detail.Type == gjson.String {
					updated, err = sjson.SetBytes(updated, fmt.Sprintf("output.%d.detail", i), detail.String())
					if err != nil {
						return itemRaw, false, err
					}
				}
			} else if imageURL.Type != gjson.String {
				continue
			}
			normalizedType = "input_image"
		default:
			continue
		}

		var err error
		updated, err = sjson.SetBytes(updated, fmt.Sprintf("output.%d.type", i), normalizedType)
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
        $chatRequestContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $chatRequest
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
        & $script:GofmtExe -w $responsesRequest
        if (Test-Path $chatRequest) { & $script:GofmtExe -w $chatRequest }
        & $script:GoExe test ./internal/translator/codex/openai/responses/...
        if ($LASTEXITCODE -ne 0) { throw "CPA Responses tests failed" }
        & $script:GoExe test ./internal/translator/codex/openai/chat-completions/...
        if ($LASTEXITCODE -ne 0) { throw "CPA Chat Completions tests failed" }

        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
        $outExe = Join-Path $OutputDir "cli-proxy-api-patched.exe"
        & $script:GoExe build -o $outExe ./cmd/server
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

    $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $responsesGo
    $content = $content -replace 'Strict\s+\*bool\s+`json:"strict"`', 'Strict     *bool                   `json:"strict,omitempty"`'
    # Bifrost main briefly retained a write to the removed rawToolSearch field after
    # replacing it with rawPreserved. Remove only that stale assignment when the field
    # declaration is absent so current main remains buildable without affecting older refs.
    if ($content -notmatch 'rawToolSearch\s+\[\]byte' -and $content -match 'm\.rawToolSearch = append\(\[\]byte\(nil\), data\.\.\.\)') {
        $content = $content -replace '(?m)^\s*m\.rawToolSearch = append\(\[\]byte\(nil\), data\.\.\.\)\r?\n', ''
    }

    $muxGo = Join-Path $SourceRoot "core\schemas\mux.go"
    if (-not (Test-Path $muxGo)) {
        throw "Bifrost mux.go not found: $muxGo"
    }
    $muxContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $muxGo
    if ($muxContent -notmatch 'rt.CacheControl = ct.CacheControl') {
        $muxContent = $muxContent.Replace("`trt := &ResponsesTool{`r`n`t`tType: ResponsesToolType(ct.Type),`r`n`t}", "`trt := &ResponsesTool{`r`n`t`tType:         ResponsesToolType(ct.Type),`r`n`t`tCacheControl: ct.CacheControl,`r`n`t}")
    }
    if ($muxContent -notmatch 'ct.CacheControl = rt.CacheControl') {
        $muxContent = $muxContent.Replace("`tct := &ChatTool{`r`n`t`tType: ChatToolType(rt.Type),`r`n`t}", "`tct := &ChatTool{`r`n`t`tType:         ChatToolType(rt.Type),`r`n`t`tCacheControl: rt.CacheControl,`r`n`t}")
    }
    if ($muxContent -notmatch 'CacheControl: ct.CacheControl' -or $muxContent -notmatch 'CacheControl: rt.CacheControl') {
        throw "Could not patch Responses/Chat tool cache_control conversion in $muxGo"
    }
    Save-Utf8NoBom $muxGo $muxContent

    $unmarshalStart = $content.IndexOf('func (t *ResponsesTool) UnmarshalJSON(data []byte) error {')
    if ($unmarshalStart -lt 0) {
        throw "Could not locate ResponsesTool.UnmarshalJSON in $responsesGo"
    }
    $unmarshalContent = $content.Substring($unmarshalStart)
    $casePattern = '(?s)case ResponsesToolTypeFunction:\s*var funcTool ResponsesToolFunction\s*if err := Unmarshal\(data, &funcTool\); err != nil \{\s*return err\s*\}\s*t\.ResponsesToolFunction = &funcTool\s*case ResponsesToolTypeFileSearch:'
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
    if ($unmarshalContent -notmatch 'Cursor flat format uses input_schema') {
        if ($unmarshalContent -notmatch $casePattern) {
            throw "Could not locate unpatched ResponsesToolTypeFunction case in ResponsesTool.UnmarshalJSON: $responsesGo"
        }
        $patchedUnmarshal = [regex]::Replace($unmarshalContent, $casePattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $caseReplacement }, 1)
        $content = $content.Substring(0, $unmarshalStart) + $patchedUnmarshal
    }

    $marshalStart = $content.IndexOf('func (t ResponsesTool) MarshalJSON() ([]byte, error) {')
    $unmarshalStart = $content.IndexOf('func (t *ResponsesTool) UnmarshalJSON(data []byte) error {')
    if ($marshalStart -lt 0 -or $unmarshalStart -le $marshalStart) {
        throw "Unexpected ResponsesTool marshal/unmarshal structure in $responsesGo"
    }
    $marshalContent = $content.Substring($marshalStart, $unmarshalStart - $marshalStart)
    if ($marshalContent -match 'fnRaw|Cursor flat format uses input_schema') {
        throw "Cursor compatibility code leaked into ResponsesTool.MarshalJSON: $responsesGo"
    }
    $unmarshalContent = $content.Substring($unmarshalStart)
    if ([regex]::Matches($unmarshalContent, 'Cursor flat format uses input_schema').Count -ne 1) {
        throw "Expected exactly one Cursor function-tool compatibility block in ResponsesTool.UnmarshalJSON: $responsesGo"
    }
    Save-Utf8NoBom $responsesGo $content

    $cursorGo = Join-Path $SourceRoot "transports\bifrost-http\integrations\cursor.go"
    if (-not (Test-Path $cursorGo)) {
        throw "Bifrost Cursor integration not found: $cursorGo"
    }

    $cursorToolResultsGo = Join-Path $SourceRoot "transports\bifrost-http\integrations\cursortoolresults.go"
    $cursorCompressionGo = Join-Path $SourceRoot "transports\bifrost-http\integrations\cursorcompression.go"
    $cursorAnthropicCustomToolsGo = Join-Path $SourceRoot "transports\bifrost-http\integrations\cursoranthropiccustomtools.go"
    Copy-Item -Force (Join-Path $PSScriptRoot "bifrost_cursortoolresults.go") $cursorToolResultsGo
    Copy-Item -Force (Join-Path $PSScriptRoot "bifrost_cursorcompression.go") $cursorCompressionGo
    Copy-Item -Force (Join-Path $PSScriptRoot "bifrost_anthropiccustomtools.go") $cursorAnthropicCustomToolsGo

    $cursorContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $cursorGo
    if ($cursorContent -notmatch "normalizeCursorFunctionCallOutputs") {
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
    }

    $mergeThenNormalizePattern = 'cursorMergeToolResultsFromMessages\(data, cursorReq\)\r?\n(\s*)normalizeInputContentBlocks\(cursorReq\)'
    $cursorContent = [regex]::Replace($cursorContent, $mergeThenNormalizePattern, [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        "cursorMergeToolResultsFromMessages(data, cursorReq)`r`n$($m.Groups[1].Value)normalizeCursorFunctionCallOutputs(cursorReq)`r`n$($m.Groups[1].Value)normalizeInputContentBlocks(cursorReq)"
    })

    $mergeFunctionPattern = '(?s)func cursorMergeToolResultsFromMessages\(data \[\]byte, cursorReq \*openai\.OpenAIResponsesRequest\) \{.*?\r?\n\}\r?\n\s*(?=// cursorConvertMessagesToInput)'
    if ($cursorContent -notmatch $mergeFunctionPattern) {
        throw "Could not locate Cursor tool-result merge function in $cursorGo"
    }
    $mergeDelegate = @'
func cursorMergeToolResultsFromMessages(data []byte, cursorReq *openai.OpenAIResponsesRequest) {
	reconcileCursorToolResultsFromMessages(data, cursorReq)
}

'@
    $cursorContent = [regex]::Replace($cursorContent, $mergeFunctionPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $mergeDelegate }, 1)
    Save-Utf8NoBom $cursorGo $cursorContent

    $cursorContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $cursorGo
    if ([regex]::Matches($cursorContent, 'normalizeCursorFunctionCallOutputs\(cursorReq\)').Count -ne 2) {
        throw "Expected Cursor tool-output normalization in both parser paths: $cursorGo"
    }
    if ([regex]::Matches($cursorContent, 'reconcileCursorToolResultsFromMessages\(data, cursorReq\)').Count -ne 1) {
        throw "Expected exactly one Cursor tool-result reconciliation delegate: $cursorGo"
    }

    $cursorContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $cursorGo
    if ($cursorContent -notmatch "addCursorClaudeToolCacheBreakpoint") {
        $happyPathPattern = 'normalizeInputContentBlocks\(cursorReq\)\r?\n\s*return nil'
        if ($cursorContent -notmatch $happyPathPattern) {
            throw "Could not locate Cursor parser happy-path return in $cursorGo"
        }
        $cursorContent = [regex]::Replace($cursorContent, $happyPathPattern, "normalizeInputContentBlocks(cursorReq)`r`n`t`taddCursorClaudeToolCacheBreakpoint(cursorReq)`r`n`t`treturn nil", 1)

        $fallbackReturnPattern = '(?s)(for i := range toolsWrapper\.Tools \{.*?\r?\n\s*\})\r?\n\s*return nil\r?\n\}'
        if ($cursorContent -notmatch $fallbackReturnPattern) {
            throw "Could not locate Cursor flat-tool parser return in $cursorGo"
        }
        $cursorContent = [regex]::Replace($cursorContent, $fallbackReturnPattern, "`$1`r`n`r`n`taddCursorClaudeToolCacheBreakpoint(cursorReq)`r`n`treturn nil`r`n}", 1)
        $cacheMarker = '// normalizeInputContentBlocks ensures all input messages have ContentBlocks instead of'
        $cacheFunction = @"
// addCursorClaudeToolCacheBreakpoint adds one Anthropic-compatible cache breakpoint
// to Cursor's stable tool prefix when the client did not provide one. Limiting the
// change to Claude requests avoids leaking provider-specific behavior to other models.
func addCursorClaudeToolCacheBreakpoint(req *openai.OpenAIResponsesRequest) {
	if req == nil || !strings.HasPrefix(strings.ToLower(req.Model), "claude-") || len(req.Tools) == 0 {
		return
	}
	for i := range req.Tools {
		if req.Tools[i].CacheControl != nil {
			return
		}
	}
	req.Tools[len(req.Tools)-1].CacheControl = &schemas.CacheControl{
		Type: schemas.CacheControlTypeEphemeral,
	}
}

"@
        if (-not $cursorContent.Contains($cacheMarker)) {
            throw "Could not locate Cursor input normalization marker in $cursorGo"
        }
        $cursorContent = $cursorContent.Replace($cacheMarker, $cacheFunction + $cacheMarker)
        Save-Utf8NoBom $cursorGo $cursorContent
    }

    $cursorContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $cursorGo
    if ([regex]::Matches($cursorContent, 'addCursorClaudeToolCacheBreakpoint\(cursorReq\)').Count -ne 2) {
        throw "Expected Claude cache helper calls in both Cursor parser paths: $cursorGo"
    }
    if ([regex]::Matches($cursorContent, 'func addCursorClaudeToolCacheBreakpoint').Count -ne 1) {
        throw "Expected exactly one Claude cache helper definition: $cursorGo"
    }

    $compressionCallPattern = 'normalizeInputContentBlocks\(cursorReq\)\r?\n(\s*)addCursorClaudeToolCacheBreakpoint\(cursorReq\)'
    $cursorContent = [regex]::Replace($cursorContent, $compressionCallPattern, [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        "normalizeInputContentBlocks(cursorReq)`r`n$($m.Groups[1].Value)if err := compressCursorClaudeRequest(cursorReq); err != nil {`r`n$($m.Groups[1].Value)`treturn err`r`n$($m.Groups[1].Value)}`r`n$($m.Groups[1].Value)addCursorClaudeToolCacheBreakpoint(cursorReq)"
    })
    Save-Utf8NoBom $cursorGo $cursorContent
    if ([regex]::Matches($cursorContent, 'compressCursorClaudeRequest\(cursorReq\)').Count -lt 1) {
        throw "Expected Claude compression before cache marking in the standard Cursor parser path: $cursorGo"
    }

    # Upgrade to the final, fully-verified breakpoint scheme (idempotent: matches and
    # replaces ANY earlier generation of this function family — the original tool-only
    # breakpoint, or the tool+system-message intermediate version — so upgrading an
    # existing install skips straight to the version below regardless of which generation
    # it currently has installed).
    #
    # This version was arrived at after extensive live debugging against a production
    # Cursor + muskapi (Anthropic-compatible) setup; see
    # log/major_fix/<commit>_cache_control_incremental_fix.md in this repo for the full
    # investigation. Summary of what changed vs. the tool+system-message version above:
    #
    #   - No tool-level breakpoint at all. Confirmed empirically: a breakpoint on a
    #     message content block alone (no tool breakpoint) still correctly caches the
    #     tools array, because Anthropic's cache_control breakpoints cover everything
    #     earlier in the request's fixed content ordering (tools, then system, then
    #     messages). Spending one of Anthropic's 4 allowed breakpoints on the tools array
    #     specifically was wasted budget.
    #   - Model matching tolerates a Bifrost "provider/model" address prefix (e.g.
    #     "muskapi/claude-sonnet-5"), which is what Cursor's configured custom model name
    #     actually looks like once routed through a named provider — a bare "claude-"
    #     prefix check silently no-ops for these.
    #   - Cursor's real traffic does not send a dedicated system/developer message at all;
    #     everything is folded into the first message (role=user). The stable-anchor
    #     breakpoint falls back to the first message in that case.
    #   - Four breakpoints total (Anthropic's per-request max), all message-level:
    #     stable anchor (first/system message), absolute last message, absolute
    #     second-to-last message (the pair lets a Cursor tool-calling loop within a single
    #     turn accumulate cache turn-over-turn), and the second-to-last *user*-role
    #     message (realigns across a full turn boundary, which typically appends more
    #     than the 1-2 items the absolute-position pair assumes).
    $cursorContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $cursorGo
    if ($cursorContent -notmatch "isClaudeCursorModel") {
        $finalUpgradePattern = '(?s)// addCursorClaudeToolCacheBreakpoint adds.*?(?=// normalizeInputContentBlocks ensures)'
        if ($cursorContent -notmatch $finalUpgradePattern) {
            throw "Could not locate addCursorClaudeToolCacheBreakpoint function family to upgrade to the final version in $cursorGo"
        }
        $finalBlock = @'
// isClaudeCursorModel reports whether model refers to a Claude model, tolerating a
// Bifrost "provider/model" address prefix (e.g. "muskapi/claude-sonnet-5") in addition
// to a bare model name (e.g. "claude-sonnet-5"). Cursor's configured custom model name
// is whatever the routing setup uses to address the upstream, which is frequently
// provider-prefixed; matching only a bare "claude-" prefix silently no-ops for those
// requests.
func isClaudeCursorModel(model string) bool {
	m := strings.ToLower(model)
	if idx := strings.LastIndex(m, "/"); idx >= 0 {
		m = m[idx+1:]
	}
	return strings.HasPrefix(m, "claude-")
}

// addCursorClaudeToolCacheBreakpoint adds Anthropic-compatible cache breakpoints to
// Cursor's request when the client did not provide one. Limiting the change to Claude
// requests avoids leaking provider-specific behavior to other models.
//
// This does NOT mark a tool directly (despite the name, kept for compatibility with
// existing callers/tests). Confirmed empirically against a production Anthropic-compatible
// upstream: a breakpoint on the last tool with nothing else marked creates NO cache entry
// at all -- neither cache_creation_input_tokens nor cache_read_input_tokens. But a
// breakpoint on a message content block alone (no tool breakpoint) correctly caches
// everything before it, tools included -- Anthropic's cache_control breakpoints cover all
// content earlier in the request's fixed ordering (tools, then system, then messages), so
// a message-level breakpoint already subsumes the tools. Spending one of Anthropic's 4
// allowed breakpoints on the tools array specifically is therefore wasted budget; all 4
// are used for message-level breakpoints instead (see addCursorClaudeSystemCacheBreakpoint).
func addCursorClaudeToolCacheBreakpoint(req *openai.OpenAIResponsesRequest) {
	if req == nil || !isClaudeCursorModel(req.Model) {
		return
	}
	if cursorRequestHasExplicitCacheControl(req) {
		return
	}
	addCursorClaudeSystemCacheBreakpoint(req)
}

// cursorRequestHasExplicitCacheControl reports whether the client already supplied a
// cache_control anywhere in the request (any tool, or any input message / content
// block), in which case Bifrost defers entirely to the client's own cache policy
// instead of layering an additional breakpoint on top of it.
func cursorRequestHasExplicitCacheControl(req *openai.OpenAIResponsesRequest) bool {
	for i := range req.Tools {
		if req.Tools[i].CacheControl != nil {
			return true
		}
	}
	for i := range req.Input.OpenAIResponsesRequestInputArray {
		msg := &req.Input.OpenAIResponsesRequestInputArray[i]
		if msg.CacheControl != nil {
			return true
		}
		if msg.Content == nil {
			continue
		}
		for j := range msg.Content.ContentBlocks {
			if msg.Content.ContentBlocks[j].CacheControl != nil {
				return true
			}
		}
	}
	return false
}

// setCursorMessageCacheBreakpoint marks msg as a cache checkpoint. Regular content
// messages carry cache_control on their last content block; function_call and
// function_call_output items carry it on the message itself (see ResponsesMessage.
// CacheControl). Returns false if msg has nothing markable.
func setCursorMessageCacheBreakpoint(msg *schemas.ResponsesMessage) bool {
	if msg == nil {
		return false
	}
	if msg.Type != nil && (*msg.Type == schemas.ResponsesMessageTypeFunctionCall || *msg.Type == schemas.ResponsesMessageTypeFunctionCallOutput) {
		msg.CacheControl = &schemas.CacheControl{Type: schemas.CacheControlTypeEphemeral}
		return true
	}
	if msg.Content == nil || len(msg.Content.ContentBlocks) == 0 {
		return false
	}
	last := &msg.Content.ContentBlocks[len(msg.Content.ContentBlocks)-1]
	last.CacheControl = &schemas.CacheControl{Type: schemas.CacheControlTypeEphemeral}
	return true
}

// addCursorClaudeSystemCacheBreakpoint marks the stable prefix boundary, plus a sliding
// window covering both the growing tail WITHIN a turn (a Cursor tool-calling loop:
// assistant tool_call, tool_result, assistant tool_call, tool_result, ...) and realignment
// ACROSS turns (when the next real user message arrives).
//
// The stable-prefix breakpoint alone is not enough for multi-turn caching to actually
// accumulate: Cursor's first message (or an explicit system/developer message, when
// present) never changes, but every later turn appends new messages after it. Anchoring
// the only breakpoint there means each turn only ever re-reads that same fixed prefix --
// the growing tail in between is recomputed at full price every single turn and never
// itself becomes part of the cache.
//
// Uses all 4 of Anthropic's allowed breakpoints per request, all message-level (see
// addCursorClaudeToolCacheBreakpoint for why a tool-level breakpoint is unnecessary once
// a message-level one is present):
//
//  1. Stable anchor -- the last system/developer message, or (Cursor's actual shape: no
//     dedicated system message at all) the first message in the array, which stays
//     byte-identical across the whole conversation.
//  2. Absolute last message, whatever its role. This is what lets a tool-calling loop
//     WITHIN a single turn accumulate cache too: each tool_call/tool_result round appends
//     to the end of the array, and marking the true last item every time -- not just the
//     last *user* message -- means each round's request can read what the previous round
//     (moments earlier, same turn) wrote and extend it, instead of leaving everything
//     between the turn's original user query and the current tool round permanently
//     uncached until the turn finally ends.
//  3. Absolute second-to-last message. Pairs with #2 for the common case where a turn
//     produces exactly one new item since the last request in the same loop (their
//     positions must both be present for the read to hit turn-over-turn).
//  4. Second-to-last *user*-role message. Handles realignment across a full turn boundary,
//     where Cursor appends more than the 1-2 items #2/#3 assume (the previous turn's
//     trailing tool calls, its final assistant reply, AND the new user query). Cursor's
//     history is a strict append -- earlier messages are never mutated -- so whatever user
//     message was "the latest" when the previous turn built its own breakpoints is always
//     exactly "the second-to-last user message" by the time this turn looks at the same
//     history, regardless of how much non-user content sits between them. Confirmed
//     against production Cursor traffic across 4 consecutive turns with adequate spacing
//     between requests for the upstream's cache writes to propagate: read tokens matched
//     the previous turn's write exactly, every turn, only the small per-turn delta was
//     freshly written each time.
func addCursorClaudeSystemCacheBreakpoint(req *openai.OpenAIResponsesRequest) {
	n := len(req.Input.OpenAIResponsesRequestInputArray)
	if n == 0 {
		return
	}

	markedStableAnchor := false
	for i := n - 1; i >= 0; i-- {
		msg := &req.Input.OpenAIResponsesRequestInputArray[i]
		if msg.Role == nil {
			continue
		}
		if *msg.Role != schemas.ResponsesInputMessageRoleSystem && *msg.Role != schemas.ResponsesInputMessageRoleDeveloper {
			continue
		}
		markedStableAnchor = setCursorMessageCacheBreakpoint(msg)
		break
	}
	if !markedStableAnchor {
		// No system/developer message: Cursor's production traffic folds all static
		// context (including what would normally be a system prompt) into the first
		// message, which is always role=user and verified to stay byte-identical across
		// a conversation while later turns are appended after it.
		setCursorMessageCacheBreakpoint(&req.Input.OpenAIResponsesRequestInputArray[0])
	}

	// #2 and #3: absolute last two messages, covering within-turn tool-loop growth.
	setCursorMessageCacheBreakpoint(&req.Input.OpenAIResponsesRequestInputArray[n-1])
	if n >= 2 {
		setCursorMessageCacheBreakpoint(&req.Input.OpenAIResponsesRequestInputArray[n-2])
	}

	// #4: second-to-last user-role message, covering realignment across a full turn
	// boundary. See the function comment for why role-indexing (not raw position) is
	// required here.
	marked := 0
	for i := n - 1; i >= 0 && marked < 2; i-- {
		msg := &req.Input.OpenAIResponsesRequestInputArray[i]
		if msg.Role == nil || *msg.Role != schemas.ResponsesInputMessageRoleUser {
			continue
		}
		if marked == 1 {
			setCursorMessageCacheBreakpoint(msg)
		}
		marked++
	}
}

'@
        $cursorContent = [regex]::Replace($cursorContent, $finalUpgradePattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $finalBlock }, 1)
        Save-Utf8NoBom $cursorGo $cursorContent
    }

    $cursorContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $cursorGo
    if ([regex]::Matches($cursorContent, 'func addCursorClaudeSystemCacheBreakpoint').Count -ne 1) {
        throw "Expected exactly one Claude system cache breakpoint helper definition: $cursorGo"
    }
    if ([regex]::Matches($cursorContent, 'func isClaudeCursorModel').Count -ne 1) {
        throw "Expected exactly one isClaudeCursorModel helper definition: $cursorGo"
    }

    # Install the fixed, Responses-only thinking-high alias table in core/schemas.
    # Request parsing and model-list presentation both consume this shared table so
    # their supported aliases cannot drift apart.
    $thinkingHighGo = Join-Path $SourceRoot "core\schemas\cursor_thinking_high_alias.go"
    $thinkingHighTest = Join-Path $SourceRoot "core\schemas\cursor_thinking_high_alias_test.go"
    Copy-Item -Force (Join-Path $PSScriptRoot "bifrost_thinking_high_alias.go") $thinkingHighGo
    Copy-Item -Force (Join-Path $PSScriptRoot "bifrost_thinking_high_alias_test.go") $thinkingHighTest

    $inferenceGo = Join-Path $SourceRoot "transports\bifrost-http\handlers\inference.go"
    if (-not (Test-Path $inferenceGo)) {
        throw "Bifrost inference handler not found: $inferenceGo"
    }
    $inferenceContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $inferenceGo
    if ($inferenceContent -notmatch 'ApplyCursorThinkingHighAlias') {
        $thinkingHighBlock = @'
	if req.ResponsesParameters == nil {
		req.ResponsesParameters = &schemas.ResponsesParameters{}
	}
	// Only the connector's explicit, fixed thinking-high aliases take this path.
	// Clear any provider parsed from an alias such as muskapi/claude-... so the
	// restored base model goes through the existing routing rules.
	if baseModel, ok := schemas.ApplyCursorThinkingHighAlias(req.Model, req.ResponsesParameters); ok {
		req.Model = baseModel
		base.Provider = ""
		base.ModelName = baseModel
	}
'@
        $responsesParamsPattern = '(?m)^\tif req\.ResponsesParameters == nil \{\r?\n\t\treq\.ResponsesParameters = &schemas\.ResponsesParameters\{\}\r?\n\t\}'
        if ($inferenceContent -notmatch $responsesParamsPattern) {
            throw "Could not locate Responses parameter initialization in $inferenceGo"
        }
        $inferenceContent = [regex]::Replace($inferenceContent, $responsesParamsPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $thinkingHighBlock.TrimEnd() }, 1)

        $enrichCall = @(
            "`tenrichAndFilterListModelsResponse(resp, h.config.ModelCatalog)",
            "`tenrichListModelsResponse(resp, h.config.ModelCatalog)"
        ) | Where-Object { $inferenceContent.Contains($_) } | Select-Object -First 1
        if (-not $enrichCall) {
            throw "Could not locate /v1/models enrichment in $inferenceGo"
        }
        $enrichWithAliases = "$enrichCall`r`n`tschemas.AppendCursorThinkingHighModels(resp)"
        $inferenceContent = $inferenceContent.Replace($enrichCall, $enrichWithAliases)
        Save-Utf8NoBom $inferenceGo $inferenceContent
    }

    $openAIIntegrationGo = Join-Path $SourceRoot "transports\bifrost-http\integrations\openai.go"
    if (-not (Test-Path $openAIIntegrationGo)) {
        throw "Bifrost OpenAI integration not found: $openAIIntegrationGo"
    }
    $openAIIntegrationContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $openAIIntegrationGo
    if ($openAIIntegrationContent -notmatch 'restoreCursorAnthropicCustomResponse') {
        $requestPattern = '(?s)(RequestConverter: func\(ctx \*schemas\.BifrostContext, req interface\{\}\) \(\*schemas\.BifrostRequest, error\) \{\r?\n\s*if openaiReq, ok := req\.\(\*openai\.OpenAIResponsesRequest\); ok \{\r?\n)(\s*)(return &schemas\.BifrostRequest\{\r?\n\s*ResponsesRequest:)'
        if ([regex]::Matches($openAIIntegrationContent, $requestPattern).Count -ne 1) {
            throw "Could not locate OpenAI Responses request converter in $openAIIntegrationGo"
        }
        $openAIIntegrationContent = [regex]::Replace($openAIIntegrationContent, $requestPattern, [System.Text.RegularExpressions.MatchEvaluator]{
            param($m)
            "$($m.Groups[1].Value)$($m.Groups[2].Value)prepareCursorAnthropicCustomTools(ctx, openaiReq)`r`n$($m.Groups[2].Value)$($m.Groups[3].Value)"
        }, 1)

        $responsePattern = 'ResponsesResponseConverter: openAIResponsesWireConverter,'
        $responseReplacement = @'
ResponsesResponseConverter: func(ctx *schemas.BifrostContext, resp *schemas.BifrostResponsesResponse) (interface{}, error) {
                restoreCursorAnthropicCustomResponse(ctx, resp)
                return openAIResponsesWireConverter(ctx, resp)
            },
'@
        if ([regex]::Matches($openAIIntegrationContent, $responsePattern).Count -lt 1) {
            throw "Could not locate OpenAI Responses response converter in $openAIIntegrationGo"
        }
        $responseRegex = [regex]::new($responsePattern)
        $openAIIntegrationContent = $responseRegex.Replace($openAIIntegrationContent, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $responseReplacement.TrimEnd() }, 1)

        $streamPattern = '(?s)(ResponsesStreamResponseConverter: func\(ctx \*schemas\.BifrostContext, resp \*schemas\.BifrostResponsesStreamResponse\) \(string, interface\{\}, error\) \{\r?\n)(\s*)(if resp\.ExtraFields\.Provider == schemas\.OpenAI)'
        $openAIIntegrationContent = [regex]::Replace($openAIIntegrationContent, $streamPattern, [System.Text.RegularExpressions.MatchEvaluator]{
            param($m)
            "$($m.Groups[1].Value)$($m.Groups[2].Value)if event, payload, handled := restoreCursorAnthropicCustomStream(ctx, resp); handled {`r`n$($m.Groups[2].Value)`treturn event, payload, nil`r`n$($m.Groups[2].Value)}`r`n$($m.Groups[2].Value)$($m.Groups[3].Value)"
        })
        Save-Utf8NoBom $openAIIntegrationGo $openAIIntegrationContent
    }
    if ([regex]::Matches($openAIIntegrationContent, 'restoreCursorAnthropicCustomStream\(ctx, resp\)').Count -ne 2) {
        throw "Expected Anthropic custom-tool stream restoration in both OpenAI Responses route variants: $openAIIntegrationGo"
    }

    $openAIIntegrationContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $openAIIntegrationGo
    if ($openAIIntegrationContent -notmatch 'AppendCursorThinkingHighModels') {
        $cursorListModelsConverter = @'
			ListModelsResponseConverter: func(ctx *schemas.BifrostContext, resp *schemas.BifrostListModelsResponse) (interface{}, error) {
				if pathPrefix == "/cursor" {
					schemas.AppendCursorThinkingHighModels(resp)
				}
				return openai.ToOpenAIListModelsResponse(resp), nil
			},
'@
        $listModelsConverterPattern = '(?m)^\t\t\tListModelsResponseConverter: func\(ctx \*schemas\.BifrostContext, resp \*schemas\.BifrostListModelsResponse\) \(interface\{\}, error\) \{\r?\n\t\t\t\treturn openai\.ToOpenAIListModelsResponse\(resp\), nil\r?\n\t\t\t\},'
        if ($openAIIntegrationContent -notmatch $listModelsConverterPattern) {
            throw "Could not locate OpenAI list-model converter in $openAIIntegrationGo"
        }
        $openAIIntegrationContent = [regex]::Replace($openAIIntegrationContent, $listModelsConverterPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $cursorListModelsConverter.TrimEnd() }, 1)
        Save-Utf8NoBom $openAIIntegrationGo $openAIIntegrationContent
    }

    $schemaCompatTest = Join-Path $SourceRoot "core\schemas\cursor_connector_compat_test.go"
    $cursorCompatTest = Join-Path $SourceRoot "transports\bifrost-http\integrations\cursor_connector_compat_test.go"
    $cursorAnthropicCustomToolsTest = Join-Path $SourceRoot "transports\bifrost-http\integrations\cursor_anthropic_custom_tools_test.go"
    $thinkingHighHandlerTest = Join-Path $SourceRoot "transports\bifrost-http\handlers\cursor_thinking_high_test.go"
    Copy-Item -Force (Join-Path $PSScriptRoot "bifrost_responses_compat_test.go") $schemaCompatTest
    Copy-Item -Force (Join-Path $PSScriptRoot "bifrost_cursor_compat_test.go") $cursorCompatTest
    Copy-Item -Force (Join-Path $PSScriptRoot "bifrost_anthropiccustomtools_test.go") $cursorAnthropicCustomToolsTest
    Copy-Item -Force (Join-Path $PSScriptRoot "bifrost_thinking_high_handler_test.go") $thinkingHighHandlerTest

    Push-Location $SourceRoot
    try {
        & $script:GofmtExe -w $responsesGo $muxGo $cursorGo $cursorToolResultsGo $cursorCompressionGo $cursorAnthropicCustomToolsGo $thinkingHighGo $thinkingHighTest $inferenceGo $openAIIntegrationGo $schemaCompatTest $cursorCompatTest $cursorAnthropicCustomToolsTest $thinkingHighHandlerTest

        Push-Location (Join-Path $SourceRoot "core")
        try {
            & $script:GoExe test ./schemas -run CursorConnector -count=1
            if ($LASTEXITCODE -ne 0) { throw "Bifrost schema compatibility tests failed" }
        } finally {
            Pop-Location
        }

        $goWork = Join-Path $SourceRoot "go.work"
        $createdGoWork = -not (Test-Path $goWork)
        if ($createdGoWork) {
            & $script:GoExe work init
            & $script:GoExe work use ./core ./framework ./plugins/compat ./plugins/governance ./plugins/jsonparser ./plugins/logging ./plugins/maxim ./plugins/mocker ./plugins/otel ./plugins/prompts ./plugins/semanticcache ./plugins/telemetry ./transports
            if ($LASTEXITCODE -ne 0) { throw "Bifrost go.work setup failed" }
        }
        Push-Location (Join-Path $SourceRoot "transports")
        try {
            & $script:GoExe test ./bifrost-http/integrations -run CursorConnector -count=1
            if ($LASTEXITCODE -ne 0) { throw "Bifrost Cursor compatibility tests failed" }
            & $script:GoExe test ./bifrost-http/handlers -run CursorConnector -count=1
            if ($LASTEXITCODE -ne 0) { throw "Bifrost thinking-high handler tests failed" }
        } finally {
            Pop-Location
            if ($createdGoWork) {
                Remove-Item -LiteralPath $goWork -Force
                $goWorkSum = Join-Path $SourceRoot "go.work.sum"
                if (Test-Path $goWorkSum) { Remove-Item -LiteralPath $goWorkSum -Force }
            }
        }

        if (-not $SkipBifrostBuild) {
            $dockerfile = Join-Path $PSScriptRoot "Dockerfile.bifrost-patched"
            docker build -f $dockerfile -t $BifrostImage --build-arg VERSION=local-patch .
            if ($LASTEXITCODE -ne 0) { throw "Bifrost docker build failed" }
            Write-Host "Built Bifrost image: $BifrostImage" -ForegroundColor Green
        }
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
$script:GoExe = Resolve-RealCommandPath "go"
$script:GofmtExe = Resolve-RealCommandPath "gofmt"
if (-not $SkipBifrost -and -not $SkipBifrostBuild) {
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
