package integrations

import (
	"encoding/json"
	"strings"
	"sync"

	"github.com/maximhq/bifrost/core/providers/openai"
	"github.com/maximhq/bifrost/core/schemas"
)

type cursorAnthropicCustomToolState struct {
	mu      sync.Mutex
	names   map[string]struct{}
	buffers map[int]string
}

type cursorAnthropicCustomToolStateKeyType struct{}

var cursorAnthropicCustomToolStateKey cursorAnthropicCustomToolStateKeyType

func isCursorAnthropicCustomToolModel(model string) bool {
	model = strings.ToLower(strings.TrimSpace(model))
	return model == "muskapi-pro/gpt-5-5-pro" || model == "gpt-5-5-pro"
}

func prepareCursorAnthropicCustomTools(ctx *schemas.BifrostContext, req *openai.OpenAIResponsesRequest) {
	if ctx == nil || req == nil || !isCursorAnthropicCustomToolModel(req.Model) {
		return
	}

	state := &cursorAnthropicCustomToolState{
		names:   make(map[string]struct{}),
		buffers: make(map[int]string),
	}
	for i := range req.Tools {
		tool := &req.Tools[i]
		if tool.Type != schemas.ResponsesToolTypeCustom || tool.Name == nil || strings.TrimSpace(*tool.Name) == "" {
			continue
		}
		state.names[*tool.Name] = struct{}{}
		tool.Type = schemas.ResponsesToolTypeFunction
		tool.ResponsesToolCustom = nil
		tool.ResponsesToolFunction = &schemas.ResponsesToolFunction{
			Parameters: &schemas.ToolFunctionParameters{
				Type: "object",
				Properties: schemas.NewOrderedMapFromPairs(
					schemas.KV("input", map[string]interface{}{"type": "string"}),
				),
				Required: []string{"input"},
			},
		}
	}
	if len(state.names) == 0 {
		return
	}

	for i := range req.Input.OpenAIResponsesRequestInputArray {
		item := &req.Input.OpenAIResponsesRequestInputArray[i]
		if item.Type == nil {
			continue
		}
		switch *item.Type {
		case schemas.ResponsesMessageTypeCustomToolCall:
			if item.Name == nil || !state.isCustomName(*item.Name) || item.ResponsesCustomToolCall == nil {
				continue
			}
			arguments, err := json.Marshal(map[string]string{"input": item.ResponsesCustomToolCall.Input})
			if err != nil {
				continue
			}
			item.Type = schemas.Ptr(schemas.ResponsesMessageTypeFunctionCall)
			item.Arguments = schemas.Ptr(string(arguments))
			item.ResponsesCustomToolCall = nil
		case schemas.ResponsesMessageTypeCustomToolCallOutput:
			item.Type = schemas.Ptr(schemas.ResponsesMessageTypeFunctionCallOutput)
		}
	}
	ctx.SetValue(cursorAnthropicCustomToolStateKey, state)
}

func (s *cursorAnthropicCustomToolState) isCustomName(name string) bool {
	if s == nil {
		return false
	}
	_, ok := s.names[name]
	return ok
}

func cursorAnthropicCustomToolStateFromContext(ctx *schemas.BifrostContext) *cursorAnthropicCustomToolState {
	if ctx == nil {
		return nil
	}
	state, _ := ctx.Value(cursorAnthropicCustomToolStateKey).(*cursorAnthropicCustomToolState)
	return state
}

func cursorCustomInputFromArguments(arguments string) string {
	var payload struct {
		Input string `json:"input"`
	}
	if json.Unmarshal([]byte(arguments), &payload) == nil {
		return payload.Input
	}
	return arguments
}

func restoreCursorAnthropicCustomItem(state *cursorAnthropicCustomToolState, item *schemas.ResponsesMessage) bool {
	if state == nil || item == nil || item.Type == nil || *item.Type != schemas.ResponsesMessageTypeFunctionCall || item.Name == nil || !state.isCustomName(*item.Name) {
		return false
	}
	input := ""
	if item.Arguments != nil {
		input = cursorCustomInputFromArguments(*item.Arguments)
	}
	item.Type = schemas.Ptr(schemas.ResponsesMessageTypeCustomToolCall)
	item.ResponsesCustomToolCall = &schemas.ResponsesCustomToolCall{Input: input}
	item.Arguments = nil
	return true
}

func restoreCursorAnthropicCustomResponse(ctx *schemas.BifrostContext, resp *schemas.BifrostResponsesResponse) {
	state := cursorAnthropicCustomToolStateFromContext(ctx)
	if state == nil || resp == nil {
		return
	}
	for i := range resp.Output {
		restoreCursorAnthropicCustomItem(state, &resp.Output[i])
	}
}

func restoreCursorAnthropicCustomStream(ctx *schemas.BifrostContext, resp *schemas.BifrostResponsesStreamResponse) (string, interface{}, bool) {
	state := cursorAnthropicCustomToolStateFromContext(ctx)
	if state == nil || resp == nil {
		return "", nil, false
	}

	index := 0
	if resp.OutputIndex != nil {
		index = *resp.OutputIndex
	}

	state.mu.Lock()
	defer state.mu.Unlock()

	switch resp.Type {
	case schemas.ResponsesStreamResponseTypeOutputItemAdded:
		if restoreCursorAnthropicCustomItem(state, resp.Item) {
			state.buffers[index] = ""
		}
	case schemas.ResponsesStreamResponseTypeFunctionCallArgumentsDelta:
		if _, tracked := state.buffers[index]; tracked {
			if resp.Delta != nil {
				state.buffers[index] += *resp.Delta
			}
			return "", nil, true
		}
	case schemas.ResponsesStreamResponseTypeFunctionCallArgumentsDone:
		if buffered, tracked := state.buffers[index]; tracked {
			if resp.Arguments != nil && *resp.Arguments != "" {
				buffered = *resp.Arguments
			}
			return string(schemas.ResponsesStreamResponseTypeCustomToolCallInputDone), map[string]interface{}{
				"type":            schemas.ResponsesStreamResponseTypeCustomToolCallInputDone,
				"sequence_number": resp.SequenceNumber,
				"output_index":    resp.OutputIndex,
				"item_id":         resp.ItemID,
				"input":           cursorCustomInputFromArguments(buffered),
			}, true
		}
	case schemas.ResponsesStreamResponseTypeOutputItemDone:
		if restoreCursorAnthropicCustomItem(state, resp.Item) {
			delete(state.buffers, index)
		}
	case schemas.ResponsesStreamResponseTypeCompleted:
		if resp.Response != nil {
			for i := range resp.Response.Output {
				restoreCursorAnthropicCustomItem(state, &resp.Response.Output[i])
			}
		}
	}
	return "", nil, false
}
