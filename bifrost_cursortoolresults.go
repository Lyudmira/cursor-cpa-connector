package integrations

import (
	"encoding/json"

	"github.com/bytedance/sonic"
	"github.com/maximhq/bifrost/core/providers/openai"
	"github.com/maximhq/bifrost/core/schemas"
)

// reconcileCursorToolResultsFromMessages fills incomplete Responses tool-result
// history from Cursor's parallel messages representation without replacing rich
// input messages. Existing non-empty input results always remain authoritative.
func reconcileCursorToolResultsFromMessages(data []byte, cursorReq *openai.OpenAIResponsesRequest) {
	if cursorReq == nil || len(data) == 0 {
		return
	}

	var envelope struct {
		Messages json.RawMessage `json:"messages"`
	}
	if err := sonic.Unmarshal(data, &envelope); err != nil || len(envelope.Messages) == 0 {
		return
	}
	messagesData, err := sonic.Marshal(&envelope)
	if err != nil {
		return
	}

	messagesReq := &openai.OpenAIResponsesRequest{}
	cursorConvertMessagesToInput(messagesData, messagesReq)
	if len(messagesReq.Input.OpenAIResponsesRequestInputArray) == 0 {
		return
	}
	cursorConvertAnthropicToolBlocks(messagesData, messagesReq)
	normalizeCursorFunctionCallOutputs(messagesReq)

	candidates := make(map[string]schemas.ResponsesMessage)
	for _, msg := range messagesReq.Input.OpenAIResponsesRequestInputArray {
		callID, ok := cursorFunctionCallOutputID(&msg)
		if !ok {
			continue
		}
		candidate := schemas.DeepCopyResponsesMessage(msg)
		current, exists := candidates[callID]
		if !exists || (!cursorFunctionCallOutputHasPayload(&current) && cursorFunctionCallOutputHasPayload(&candidate)) {
			candidates[callID] = candidate
		}
	}
	if len(candidates) == 0 {
		return
	}

	input := cursorReq.Input.OpenAIResponsesRequestInputArray
	existingOutputs := make(map[string]bool)
	for i := range input {
		callID, ok := cursorFunctionCallOutputID(&input[i])
		if !ok {
			continue
		}
		existingOutputs[callID] = true
		candidate, exists := candidates[callID]
		if exists && !cursorFunctionCallOutputHasPayload(&input[i]) && cursorFunctionCallOutputHasPayload(&candidate) {
			input[i] = schemas.DeepCopyResponsesMessage(candidate)
		}
	}

	merged := make([]schemas.ResponsesMessage, 0, len(input)+len(candidates))
	for i := 0; i < len(input); {
		if !cursorIsFunctionCall(&input[i]) {
			merged = append(merged, input[i])
			i++
			continue
		}

		callOrder := make([]string, 0, 1)
		for i < len(input) && cursorIsFunctionCall(&input[i]) {
			if callID, ok := cursorFunctionCallID(&input[i]); ok {
				callOrder = append(callOrder, callID)
			}
			merged = append(merged, input[i])
			i++
		}

		for i < len(input) {
			if _, ok := cursorFunctionCallOutputID(&input[i]); !ok {
				break
			}
			merged = append(merged, input[i])
			i++
		}

		for _, callID := range callOrder {
			if existingOutputs[callID] {
				continue
			}
			candidate, ok := candidates[callID]
			if !ok {
				continue
			}
			merged = append(merged, schemas.DeepCopyResponsesMessage(candidate))
			existingOutputs[callID] = true
		}
	}

	cursorReq.Input.OpenAIResponsesRequestInputArray = merged
}

func cursorIsFunctionCall(msg *schemas.ResponsesMessage) bool {
	return msg != nil && msg.Type != nil && *msg.Type == schemas.ResponsesMessageTypeFunctionCall
}

func cursorFunctionCallID(msg *schemas.ResponsesMessage) (string, bool) {
	if !cursorIsFunctionCall(msg) || msg.ResponsesToolMessage == nil || msg.CallID == nil || *msg.CallID == "" {
		return "", false
	}
	return *msg.CallID, true
}

func cursorFunctionCallOutputID(msg *schemas.ResponsesMessage) (string, bool) {
	if msg == nil || msg.Type == nil || *msg.Type != schemas.ResponsesMessageTypeFunctionCallOutput ||
		msg.ResponsesToolMessage == nil || msg.CallID == nil || *msg.CallID == "" {
		return "", false
	}
	return *msg.CallID, true
}

func cursorFunctionCallOutputHasPayload(msg *schemas.ResponsesMessage) bool {
	if msg == nil || msg.ResponsesToolMessage == nil {
		return false
	}
	if msg.Error != nil && *msg.Error != "" {
		return true
	}
	output := msg.Output
	if output == nil {
		return false
	}
	if output.ResponsesToolCallOutputStr != nil {
		return *output.ResponsesToolCallOutputStr != ""
	}
	if output.ResponsesComputerToolCallOutput != nil {
		return true
	}
	for i := range output.ResponsesFunctionToolCallOutputBlocks {
		if cursorToolOutputBlockHasPayload(&output.ResponsesFunctionToolCallOutputBlocks[i]) {
			return true
		}
	}
	return false
}

func cursorToolOutputBlockHasPayload(block *schemas.ResponsesMessageContentBlock) bool {
	if block == nil {
		return false
	}
	if block.Text != nil && *block.Text != "" {
		return true
	}
	return block.FileID != nil ||
		block.ResponsesInputMessageContentBlockImage != nil ||
		block.ResponsesInputMessageContentBlockFile != nil ||
		block.Audio != nil ||
		block.ResponsesOutputMessageContentText != nil ||
		block.ResponsesOutputMessageContentRefusal != nil ||
		block.ResponsesOutputMessageContentRenderedContent != nil ||
		block.ResponsesOutputMessageContentCompaction != nil
}
