package responses

import (
	"encoding/json"
	"fmt"
	"strings"

	log "github.com/sirupsen/logrus"
	"github.com/tidwall/gjson"
	"github.com/tidwall/sjson"
)

func ConvertOpenAIResponsesRequestToCodex(modelName string, inputRawJSON []byte, _ bool) []byte {
	rawJSON := inputRawJSON

	inputResult := gjson.GetBytes(rawJSON, "input")
	if inputResult.Type == gjson.String {
		input, _ := sjson.SetBytes([]byte(`[{"type":"message","role":"user","content":[{"type":"input_text","text":""}]}]`), "0.content.0.text", inputResult.String())
		rawJSON, _ = sjson.SetRawBytes(rawJSON, "input", input)
	}

	rawJSON, _ = sjson.SetBytes(rawJSON, "stream", true)
	rawJSON, _ = sjson.SetBytes(rawJSON, "store", false)
	rawJSON, _ = sjson.SetBytes(rawJSON, "parallel_tool_calls", true)
	rawJSON, _ = sjson.SetBytes(rawJSON, "include", []string{"reasoning.encrypted_content"})
	// Codex Responses rejects token limit fields, so strip them out before forwarding.
	rawJSON, _ = sjson.DeleteBytes(rawJSON, "max_output_tokens")
	rawJSON, _ = sjson.DeleteBytes(rawJSON, "max_completion_tokens")
	rawJSON, _ = sjson.DeleteBytes(rawJSON, "temperature")
	rawJSON, _ = sjson.DeleteBytes(rawJSON, "top_p")
	if v := gjson.GetBytes(rawJSON, "service_tier"); v.Exists() {
		if v.String() != "priority" {
			rawJSON, _ = sjson.DeleteBytes(rawJSON, "service_tier")
		}
	}

	rawJSON, _ = sjson.DeleteBytes(rawJSON, "truncation")
	rawJSON = applyResponsesCompactionCompatibility(rawJSON)

	// Delete the user field as it is not supported by the Codex upstream.
	rawJSON, _ = sjson.DeleteBytes(rawJSON, "user")

	// Normalize input items to the narrower schema accepted by Codex upstream.
	rawJSON = sanitizeCodexResponsesInputItems(modelName, rawJSON)
	rawJSON = removeUnsupportedCursorCustomToolsForCodexBYOK(rawJSON)
	rawJSON = addCodexBYOKToolCompatibilityInstruction(rawJSON)
	rawJSON = normalizeCodexBuiltinTools(rawJSON)

	return rawJSON
}

// applyResponsesCompactionCompatibility handles OpenAI Responses context_management.compaction
// for Codex upstream compatibility.
//
// Codex /responses currently rejects context_management with:
// {"detail":"Unsupported parameter: context_management"}.
//
// Compatibility strategy:
// 1) Remove context_management before forwarding to Codex upstream.
func applyResponsesCompactionCompatibility(rawJSON []byte) []byte {
	if !gjson.GetBytes(rawJSON, "context_management").Exists() {
		return rawJSON
	}

	rawJSON, _ = sjson.DeleteBytes(rawJSON, "context_management")
	return rawJSON
}

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

func removeUnsupportedCursorCustomToolsForCodexBYOK(rawJSON []byte) []byte {
	toolsResult := gjson.GetBytes(rawJSON, "tools")
	if !toolsResult.IsArray() {
		return rawJSON
	}

	changed := false
	kept := make([]json.RawMessage, 0, len(toolsResult.Array()))
	for _, tool := range toolsResult.Array() {
		if isCursorApplyPatchCustomTool(tool) {
			changed = true
			continue
		}
		kept = append(kept, json.RawMessage(tool.Raw))
	}
	if !changed {
		return rawJSON
	}

	if len(kept) == 0 {
		updated, errDelete := sjson.DeleteBytes(rawJSON, "tools")
		if errDelete != nil {
			return rawJSON
		}
		return updated
	}

	toolsRaw, errMarshal := json.Marshal(kept)
	if errMarshal != nil {
		return rawJSON
	}
	updated, errSet := sjson.SetRawBytes(rawJSON, "tools", toolsRaw)
	if errSet != nil {
		return rawJSON
	}
	return updated
}

func isCursorApplyPatchCustomTool(tool gjson.Result) bool {
	if strings.TrimSpace(tool.Get("type").String()) != "custom" {
		return false
	}
	return strings.EqualFold(strings.TrimSpace(tool.Get("name").String()), "ApplyPatch")
}

func addCodexBYOKToolCompatibilityInstruction(rawJSON []byte) []byte {
	hasShell := false
	hasApplyPatch := false
	if toolsResult := gjson.GetBytes(rawJSON, "tools"); toolsResult.IsArray() {
		for _, tool := range toolsResult.Array() {
			name := strings.TrimSpace(tool.Get("name").String())
			if name == "" {
				name = strings.TrimSpace(tool.Get("function.name").String())
			}
			if strings.EqualFold(name, "Shell") {
				hasShell = true
			}
			if isCursorApplyPatchCustomTool(tool) {
				hasApplyPatch = true
			}
		}
	}
	if !hasShell || hasApplyPatch {
		return rawJSON
	}

	instruction := "Compatibility note: the Cursor BYOK Responses client does not execute custom ApplyPatch tool calls on this route. For file creation and edits, use the Shell tool instead of ApplyPatch."
	instructionsResult := gjson.GetBytes(rawJSON, "instructions")
	if !instructionsResult.Exists() || strings.TrimSpace(instructionsResult.String()) == "" {
		updated, errSet := sjson.SetBytes(rawJSON, "instructions", instruction)
		if errSet != nil {
			return rawJSON
		}
		return updated
	}

	current := instructionsResult.String()
	if strings.Contains(current, "Cursor BYOK Responses client does not execute custom ApplyPatch") {
		return rawJSON
	}
	updated, errSet := sjson.SetBytes(rawJSON, "instructions", current+"\n\n"+instruction)
	if errSet != nil {
		return rawJSON
	}
	return updated
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
			if !tool.Get("type").Exists() {
				updatedTool, errSetType := sjson.SetBytes(toolRaw, "type", "function")
				if errSetType != nil {
					return itemRaw, false, errSetType
				}
				toolRaw = updatedTool
				changed = true
			}

			tool = gjson.ParseBytes(toolRaw)
			inputSchema := tool.Get("input_schema")
			if inputSchema.Exists() {
				if !tool.Get("parameters").Exists() {
					var errSetParameters error
					if inputSchema.Type == gjson.Null {
						toolRaw, errSetParameters = sjson.SetRawBytes(toolRaw, "parameters", []byte(`{"type":"object","properties":{}}`))
					} else {
						toolRaw, errSetParameters = sjson.SetRawBytes(toolRaw, "parameters", []byte(inputSchema.Raw))
					}
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

// normalizeCodexBuiltinTools rewrites legacy/preview built-in tool variants to the
// stable names expected by the current Codex upstream.
func normalizeCodexBuiltinTools(rawJSON []byte) []byte {
	result := rawJSON

	tools := gjson.GetBytes(result, "tools")
	if tools.IsArray() {
		toolArray := tools.Array()
		for i := 0; i < len(toolArray); i++ {
			typePath := fmt.Sprintf("tools.%d.type", i)
			result = normalizeCodexBuiltinToolAtPath(result, typePath)
		}
	}

	result = normalizeCodexBuiltinToolAtPath(result, "tool_choice.type")

	toolChoiceTools := gjson.GetBytes(result, "tool_choice.tools")
	if toolChoiceTools.IsArray() {
		toolArray := toolChoiceTools.Array()
		for i := 0; i < len(toolArray); i++ {
			typePath := fmt.Sprintf("tool_choice.tools.%d.type", i)
			result = normalizeCodexBuiltinToolAtPath(result, typePath)
		}
	}

	return result
}

func normalizeCodexBuiltinToolAtPath(rawJSON []byte, path string) []byte {
	currentType := gjson.GetBytes(rawJSON, path).String()
	normalizedType := normalizeCodexBuiltinToolType(currentType)
	if normalizedType == "" {
		return rawJSON
	}

	updated, err := sjson.SetBytes(rawJSON, path, normalizedType)
	if err != nil {
		return rawJSON
	}

	log.Debugf("codex responses: normalized builtin tool type at %s from %q to %q", path, currentType, normalizedType)
	return updated
}

// normalizeCodexBuiltinToolType centralizes the current known Codex Responses
// built-in tool alias compatibility. If Codex introduces more legacy aliases,
// extend this helper instead of adding path-specific rewrite logic elsewhere.
func normalizeCodexBuiltinToolType(toolType string) string {
	switch toolType {
	case "web_search_preview", "web_search_preview_2025_03_11":
		return "web_search"
	default:
		return ""
	}
}
