package integrations

import (
	"testing"

	"github.com/maximhq/bifrost/core/providers/openai"
	"github.com/maximhq/bifrost/core/schemas"
)

func TestCursorAnthropicCustomToolRoundTrip(t *testing.T) {
	name := "ApplyPatch"
	definition := "start: /.+/"
	syntax := "lark"
	req := &openai.OpenAIResponsesRequest{Model: "muskapi-pro/gpt-5-5-pro"}
	req.Tools = []schemas.ResponsesTool{{
		Type: schemas.ResponsesToolTypeCustom,
		Name: &name,
		ResponsesToolCustom: &schemas.ResponsesToolCustom{Format: &schemas.ResponsesToolCustomFormat{
			Type: "grammar", Definition: &definition, Syntax: &syntax,
		}},
	}}
	ctx := schemas.NewBifrostContext(nil, schemas.NoDeadline)
	prepareCursorAnthropicCustomTools(ctx, req)

	tool := req.Tools[0]
	if tool.Type != schemas.ResponsesToolTypeFunction || tool.ResponsesToolFunction == nil || tool.ResponsesToolFunction.Parameters == nil {
		t.Fatalf("custom tool was not converted to a function schema: %#v", tool)
	}
	if _, ok := tool.ResponsesToolFunction.Parameters.Properties.Get("input"); !ok {
		t.Fatal("converted schema is missing the input string property")
	}

	callID := "call_patch"
	arguments := `{"input":"*** Begin Patch\n*** Add File: ok.txt\n+ok\n*** End Patch"}`
	resp := &schemas.BifrostResponsesResponse{Output: []schemas.ResponsesMessage{{
		Type:                 schemas.Ptr(schemas.ResponsesMessageTypeFunctionCall),
		ResponsesToolMessage: &schemas.ResponsesToolMessage{CallID: &callID, Name: &name, Arguments: &arguments},
	}}}
	restoreCursorAnthropicCustomResponse(ctx, resp)
	item := resp.Output[0]
	if item.Type == nil || *item.Type != schemas.ResponsesMessageTypeCustomToolCall || item.ResponsesCustomToolCall == nil {
		t.Fatalf("function response was not restored to custom_tool_call: %#v", item)
	}
	if item.ResponsesCustomToolCall.Input != "*** Begin Patch\n*** Add File: ok.txt\n+ok\n*** End Patch" {
		t.Fatalf("restored input = %q", item.ResponsesCustomToolCall.Input)
	}
	if item.Arguments != nil {
		t.Fatalf("restored custom call retained arguments: %q", *item.Arguments)
	}
}

func TestCursorAnthropicCustomToolStreamRoundTrip(t *testing.T) {
	name := "ApplyPatch"
	req := &openai.OpenAIResponsesRequest{Model: "muskapi-pro/gpt-5-5-pro"}
	req.Tools = []schemas.ResponsesTool{{Type: schemas.ResponsesToolTypeCustom, Name: &name, ResponsesToolCustom: &schemas.ResponsesToolCustom{}}}
	ctx := schemas.NewBifrostContext(nil, schemas.NoDeadline)
	prepareCursorAnthropicCustomTools(ctx, req)

	index := 0
	callID := "call_patch"
	added := &schemas.BifrostResponsesStreamResponse{
		Type: schemas.ResponsesStreamResponseTypeOutputItemAdded, OutputIndex: &index,
		Item: &schemas.ResponsesMessage{Type: schemas.Ptr(schemas.ResponsesMessageTypeFunctionCall), ResponsesToolMessage: &schemas.ResponsesToolMessage{CallID: &callID, Name: &name}},
	}
	if _, _, handled := restoreCursorAnthropicCustomStream(ctx, added); handled {
		t.Fatal("output_item.added should continue through the normal wire converter")
	}
	if added.Item.Type == nil || *added.Item.Type != schemas.ResponsesMessageTypeCustomToolCall {
		t.Fatalf("added item type = %#v", added.Item.Type)
	}

	deltaText := `{"input":"*** Begin Patch\n*** End Patch"}`
	delta := &schemas.BifrostResponsesStreamResponse{Type: schemas.ResponsesStreamResponseTypeFunctionCallArgumentsDelta, OutputIndex: &index, Delta: &deltaText}
	if _, payload, handled := restoreCursorAnthropicCustomStream(ctx, delta); !handled || payload != nil {
		t.Fatalf("function argument delta was not buffered: handled=%v payload=%#v", handled, payload)
	}

	done := &schemas.BifrostResponsesStreamResponse{Type: schemas.ResponsesStreamResponseTypeFunctionCallArgumentsDone, OutputIndex: &index, Arguments: &deltaText}
	event, payload, handled := restoreCursorAnthropicCustomStream(ctx, done)
	if !handled || event != string(schemas.ResponsesStreamResponseTypeCustomToolCallInputDone) {
		t.Fatalf("done event = %q handled=%v", event, handled)
	}
	wire := payload.(map[string]interface{})
	if wire["input"] != "*** Begin Patch\n*** End Patch" {
		t.Fatalf("stream input = %#v", wire["input"])
	}
}

func TestCursorAnthropicCustomToolModelGate(t *testing.T) {
	name := "ApplyPatch"
	req := &openai.OpenAIResponsesRequest{Model: "cpa/gpt-5.6-sol"}
	req.Tools = []schemas.ResponsesTool{{Type: schemas.ResponsesToolTypeCustom, Name: &name}}
	ctx := schemas.NewBifrostContext(nil, schemas.NoDeadline)
	prepareCursorAnthropicCustomTools(ctx, req)
	if req.Tools[0].Type != schemas.ResponsesToolTypeCustom {
		t.Fatal("non-target model was modified")
	}
}
