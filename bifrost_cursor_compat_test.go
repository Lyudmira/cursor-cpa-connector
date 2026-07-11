package integrations

import (
    "testing"
    "github.com/maximhq/bifrost/core/providers/openai"
    "github.com/maximhq/bifrost/core/schemas"
)

func cursorConnectorTool(name string) schemas.ResponsesTool {
    return schemas.ResponsesTool{Type: schemas.ResponsesToolTypeFunction, Name: &name, ResponsesToolFunction: &schemas.ResponsesToolFunction{}}
}

func TestCursorConnectorClaudeToolCacheBreakpoint(t *testing.T) {
    req := &openai.OpenAIResponsesRequest{Model: "claude-sonnet-5"}
    req.Tools = []schemas.ResponsesTool{cursorConnectorTool("ReadFile"), cursorConnectorTool("Shell")}
    addCursorClaudeToolCacheBreakpoint(req)
    if req.Tools[0].CacheControl != nil || req.Tools[1].CacheControl == nil || req.Tools[1].CacheControl.Type != schemas.CacheControlTypeEphemeral { t.Fatalf("wrong breakpoint: %#v", req.Tools) }

    explicit := &openai.OpenAIResponsesRequest{Model: "claude-sonnet-5"}
    explicit.Tools = []schemas.ResponsesTool{cursorConnectorTool("ReadFile"), cursorConnectorTool("Shell")}
    explicit.Tools[0].CacheControl = &schemas.CacheControl{Type: schemas.CacheControlTypeEphemeral}
    addCursorClaudeToolCacheBreakpoint(explicit)
    if explicit.Tools[1].CacheControl != nil { t.Fatal("explicit cache_control was supplemented") }

    other := &openai.OpenAIResponsesRequest{Model: "gpt-5.6-sol"}
    other.Tools = []schemas.ResponsesTool{cursorConnectorTool("Shell")}
    addCursorClaudeToolCacheBreakpoint(other)
    if other.Tools[0].CacheControl != nil { t.Fatal("non-Claude request modified") }
}

func TestCursorConnectorNormalizesToolOutputs(t *testing.T) {
    itemType := schemas.ResponsesMessageTypeFunctionCallOutput
    for _, alias := range []schemas.ResponsesMessageContentBlockType{"text", schemas.ResponsesOutputMessageContentTypeText} {
        req := &openai.OpenAIResponsesRequest{}
        req.Input.OpenAIResponsesRequestInputArray = []schemas.ResponsesMessage{{Type: &itemType, ResponsesToolMessage: &schemas.ResponsesToolMessage{Output: &schemas.ResponsesToolMessageOutputStruct{ResponsesFunctionToolCallOutputBlocks: []schemas.ResponsesMessageContentBlock{{Type: alias}}}}}}
        normalizeCursorFunctionCallOutputs(req)
        if got := req.Input.OpenAIResponsesRequestInputArray[0].Output.ResponsesFunctionToolCallOutputBlocks[0].Type; got != schemas.ResponsesInputMessageContentBlockTypeText { t.Fatalf("alias %q became %q", alias, got) }
    }
}
