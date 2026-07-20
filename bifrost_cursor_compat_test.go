package integrations

import (
	"fmt"
	"github.com/maximhq/bifrost/core/providers/openai"
	"github.com/maximhq/bifrost/core/schemas"
	"github.com/valyala/fasthttp"
	"os"
	"strings"
	"testing"
)

func cursorConnectorTool(name string) schemas.ResponsesTool {
	return schemas.ResponsesTool{Type: schemas.ResponsesToolTypeFunction, Name: &name, ResponsesToolFunction: &schemas.ResponsesToolFunction{}}
}

func cursorConnectorSystemMessage(text string) schemas.ResponsesMessage {
	role := schemas.ResponsesInputMessageRoleSystem
	return schemas.ResponsesMessage{
		Role: &role,
		Content: &schemas.ResponsesMessageContent{
			ContentBlocks: []schemas.ResponsesMessageContentBlock{
				{Type: schemas.ResponsesInputMessageContentBlockTypeText, Text: &text},
			},
		},
	}
}

func cursorConnectorMsg(r schemas.ResponsesMessageRoleType, text string) schemas.ResponsesMessage {
	t := text
	return schemas.ResponsesMessage{Role: &r, Content: &schemas.ResponsesMessageContent{ContentBlocks: []schemas.ResponsesMessageContentBlock{{Type: schemas.ResponsesInputMessageContentBlockTypeText, Text: &t}}}}
}

func cursorConnectorCacheControl(msg schemas.ResponsesMessage) *schemas.CacheControl {
	if msg.Content == nil || len(msg.Content.ContentBlocks) == 0 {
		return nil
	}
	return msg.Content.ContentBlocks[len(msg.Content.ContentBlocks)-1].CacheControl
}

// TestCursorConnectorClaudeToolCacheBreakpoint covers model gating and explicit-override
// suppression. It does NOT mark tools directly (confirmed empirically that a message-level
// breakpoint alone already covers the tools in Anthropic's fixed content ordering — see
// addCursorClaudeToolCacheBreakpoint's doc comment); it delegates all marking to
// addCursorClaudeSystemCacheBreakpoint, tested separately below.
func TestCursorConnectorClaudeToolCacheBreakpoint(t *testing.T) {
	req := &openai.OpenAIResponsesRequest{Model: "claude-sonnet-5"}
	req.Tools = []schemas.ResponsesTool{cursorConnectorTool("ReadFile"), cursorConnectorTool("Shell")}
	req.Input.OpenAIResponsesRequestInputArray = []schemas.ResponsesMessage{cursorConnectorMsg(schemas.ResponsesInputMessageRoleUser, "hi")}
	addCursorClaudeToolCacheBreakpoint(req)
	if req.Tools[0].CacheControl != nil || req.Tools[1].CacheControl != nil {
		t.Fatalf("tools should never be marked directly: %#v", req.Tools)
	}
	if cursorConnectorCacheControl(req.Input.OpenAIResponsesRequestInputArray[0]) == nil {
		t.Fatal("the message-level breakpoint should still be applied for a Claude request")
	}

	// An explicit client-supplied cache_control (tool or message) suppresses
	// auto-injection entirely.
	explicitTool := &openai.OpenAIResponsesRequest{Model: "claude-sonnet-5"}
	explicitTool.Tools = []schemas.ResponsesTool{cursorConnectorTool("Shell")}
	explicitTool.Tools[0].CacheControl = &schemas.CacheControl{Type: schemas.CacheControlTypeEphemeral}
	explicitTool.Input.OpenAIResponsesRequestInputArray = []schemas.ResponsesMessage{cursorConnectorMsg(schemas.ResponsesInputMessageRoleUser, "hi")}
	addCursorClaudeToolCacheBreakpoint(explicitTool)
	if cursorConnectorCacheControl(explicitTool.Input.OpenAIResponsesRequestInputArray[0]) != nil {
		t.Fatal("explicit tool cache_control should suppress message-level auto-injection too")
	}

	other := &openai.OpenAIResponsesRequest{Model: "gpt-5.6-sol"}
	other.Input.OpenAIResponsesRequestInputArray = []schemas.ResponsesMessage{cursorConnectorMsg(schemas.ResponsesInputMessageRoleUser, "hi")}
	addCursorClaudeToolCacheBreakpoint(other)
	if cursorConnectorCacheControl(other.Input.OpenAIResponsesRequestInputArray[0]) != nil {
		t.Fatal("non-Claude request modified")
	}

	// Bifrost addresses upstream models as "provider/model" (e.g. how this kit's own
	// init script registers Claude models: "muskapi/claude-sonnet-5"). Cursor's
	// configured custom model name is frequently this provider-prefixed form, not the
	// bare model name, and must still be recognized as Claude.
	prefixed := &openai.OpenAIResponsesRequest{Model: "muskapi/claude-sonnet-5"}
	prefixed.Input.OpenAIResponsesRequestInputArray = []schemas.ResponsesMessage{cursorConnectorMsg(schemas.ResponsesInputMessageRoleUser, "hi")}
	addCursorClaudeToolCacheBreakpoint(prefixed)
	if cursorConnectorCacheControl(prefixed.Input.OpenAIResponsesRequestInputArray[0]) == nil {
		t.Fatal("provider-prefixed Claude model (muskapi/claude-sonnet-5) was not recognized")
	}

	prefixedOther := &openai.OpenAIResponsesRequest{Model: "muskapi/gpt-5.6-sol"}
	prefixedOther.Input.OpenAIResponsesRequestInputArray = []schemas.ResponsesMessage{cursorConnectorMsg(schemas.ResponsesInputMessageRoleUser, "hi")}
	addCursorClaudeToolCacheBreakpoint(prefixedOther)
	if cursorConnectorCacheControl(prefixedOther.Input.OpenAIResponsesRequestInputArray[0]) != nil {
		t.Fatal("provider-prefixed non-Claude request modified")
	}
}

// TestCursorConnectorClaudeSystemCacheBreakpoint covers the 4-breakpoint scheme: stable
// anchor (system/developer message, or the first message when there is none), the
// absolute last two messages (covers a Cursor tool-calling loop growing WITHIN a single
// turn), and the second-to-last user-role message (covers realignment ACROSS a full turn
// boundary, which typically appends more than one message at once).
func TestCursorConnectorClaudeSystemCacheBreakpoint(t *testing.T) {
	req := &openai.OpenAIResponsesRequest{Model: "claude-opus-4-8"}
	req.Input.OpenAIResponsesRequestInputArray = []schemas.ResponsesMessage{
		cursorConnectorSystemMessage("You are a helpful assistant."),
	}
	addCursorClaudeToolCacheBreakpoint(req)

	sysBlocks := req.Input.OpenAIResponsesRequestInputArray[0].Content.ContentBlocks
	if len(sysBlocks) != 1 || sysBlocks[0].CacheControl == nil || sysBlocks[0].CacheControl.Type != schemas.CacheControlTypeEphemeral {
		t.Fatalf("expected ephemeral breakpoint on last system content block: %#v", sysBlocks)
	}

	// A client-supplied cache_control on a message content block must suppress
	// auto-injection.
	explicit := &openai.OpenAIResponsesRequest{Model: "claude-opus-4-8"}
	explicit.Input.OpenAIResponsesRequestInputArray = []schemas.ResponsesMessage{
		cursorConnectorSystemMessage("You are a helpful assistant."),
	}
	explicit.Input.OpenAIResponsesRequestInputArray[0].Content.ContentBlocks[0].CacheControl = &schemas.CacheControl{Type: schemas.CacheControlTypeEphemeral}
	before := explicit.Input.OpenAIResponsesRequestInputArray[0].Content.ContentBlocks[0].CacheControl
	addCursorClaudeToolCacheBreakpoint(explicit)
	if explicit.Input.OpenAIResponsesRequestInputArray[0].Content.ContentBlocks[0].CacheControl != before {
		t.Fatal("explicit content-block cache_control should not be replaced")
	}

	// No tools at all: the stable-anchor breakpoint must still be applied.
	noTools := &openai.OpenAIResponsesRequest{Model: "claude-sonnet-5"}
	noTools.Input.OpenAIResponsesRequestInputArray = []schemas.ResponsesMessage{
		cursorConnectorSystemMessage("System prompt only, no tools."),
	}
	addCursorClaudeToolCacheBreakpoint(noTools)
	if cb := noTools.Input.OpenAIResponsesRequestInputArray[0].Content.ContentBlocks[0].CacheControl; cb == nil {
		t.Fatal("stable-anchor breakpoint should be applied even when there are no tools")
	}

	// No system/developer message: Cursor's real production traffic doesn't send one at
	// all — all context (including what would normally be a system prompt) is folded into
	// the first message, which is role=user. Must not panic; the first message must get
	// the fallback stable-anchor breakpoint.
	noSystem := &openai.OpenAIResponsesRequest{Model: "claude-sonnet-5"}
	noSystem.Input.OpenAIResponsesRequestInputArray = []schemas.ResponsesMessage{
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleUser, "hello"),
	}
	addCursorClaudeToolCacheBreakpoint(noSystem)
	if cb := noSystem.Input.OpenAIResponsesRequestInputArray[0].Content.ContentBlocks[0].CacheControl; cb == nil || cb.Type != schemas.CacheControlTypeEphemeral {
		t.Fatal("first message should get a fallback breakpoint when there is no system/developer message")
	}

	// --- Turn boundary realignment (2 items appended per turn: assistant + user) ---
	//
	// Turn 2 shape: [user0, assistant1, user2].
	turn2 := &openai.OpenAIResponsesRequest{Model: "claude-sonnet-5"}
	turn2.Input.OpenAIResponsesRequestInputArray = []schemas.ResponsesMessage{
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleUser, "stable first message"),
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleAssistant, "assistant reply 1"),
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleUser, "user turn 2"),
	}
	addCursorClaudeSystemCacheBreakpoint(turn2)
	if cb := turn2.Input.OpenAIResponsesRequestInputArray[2].Content.ContentBlocks[0].CacheControl; cb == nil {
		t.Fatal("turn2's latest message (absolute last) must carry a breakpoint")
	}

	// Turn 3 shape: [user0, assistant1, user2, assistant3, user4] — 2 more messages
	// appended since turn 2, same as production Cursor traffic. Turn 2's own "absolute
	// last" breakpoint was on user2 (index 2); by turn 3 that position is neither the
	// absolute last (index 4) nor the absolute second-to-last (index 3) by raw index —
	// it must be found via the second-to-last-*user*-message breakpoint instead.
	turn3 := &openai.OpenAIResponsesRequest{Model: "claude-sonnet-5"}
	turn3.Input.OpenAIResponsesRequestInputArray = []schemas.ResponsesMessage{
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleUser, "stable first message"),
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleAssistant, "assistant reply 1"),
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleUser, "user turn 2"),
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleAssistant, "assistant reply 2"),
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleUser, "user turn 3"),
	}
	addCursorClaudeSystemCacheBreakpoint(turn3)
	if cb := turn3.Input.OpenAIResponsesRequestInputArray[2].Content.ContentBlocks[0].CacheControl; cb == nil {
		t.Fatal("turn3 must still mark user2 (turn2's absolute-last position) so the read from turn2's write hits")
	}
	if cb := turn3.Input.OpenAIResponsesRequestInputArray[4].Content.ContentBlocks[0].CacheControl; cb == nil {
		t.Fatal("turn3's own absolute-last message must also carry a breakpoint")
	}
	if cb := turn3.Input.OpenAIResponsesRequestInputArray[1].Content.ContentBlocks[0].CacheControl; cb != nil {
		t.Fatal("assistant message 1 should not get a breakpoint")
	}

	// --- Within-turn tool-loop growth (1 item appended per API call) ---
	//
	// Simulate the sequence of API calls a Cursor tool-calling loop actually produces:
	// each call in the loop appends exactly one new item versus the previous call. The
	// invariant that must hold for every consecutive pair is: call N's "absolute last"
	// breakpoint position must equal call N+1's "absolute second-to-last" position, so
	// call N+1 can read what call N wrote moments earlier.
	base := []schemas.ResponsesMessage{
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleUser, "stable first message"),
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleAssistant, "assistant reply 1"),
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleUser, "user turn 2 starts a tool loop"),
	}
	extra := []schemas.ResponsesMessage{
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleAssistant, "tool call 1"),
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleAssistant, "tool result 1"),
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleAssistant, "tool call 2"),
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleAssistant, "tool result 2"),
	}
	var prevLastIdx = -1
	for step := 0; step <= len(extra); step++ {
		call := &openai.OpenAIResponsesRequest{Model: "claude-sonnet-5"}
		call.Input.OpenAIResponsesRequestInputArray = append(append([]schemas.ResponsesMessage{}, base...), extra[:step]...)
		addCursorClaudeSystemCacheBreakpoint(call)
		n := len(call.Input.OpenAIResponsesRequestInputArray)
		lastIdx := n - 1
		if step > 0 {
			// The previous call's absolute-last position must be marked in THIS call —
			// either because it's now the absolute second-to-last (n-2), which is always
			// true here since exactly one item was appended, confirming the invariant.
			if lastIdx-1 != prevLastIdx {
				t.Fatalf("step %d: expected previous last index %d to be this call's second-to-last (%d)", step, prevLastIdx, lastIdx-1)
			}
			if cb := cursorConnectorCacheControl(call.Input.OpenAIResponsesRequestInputArray[prevLastIdx]); cb == nil {
				t.Fatalf("step %d: previous call's absolute-last message (index %d) must still be marked so its cache write is read", step, prevLastIdx)
			}
		}
		if cb := cursorConnectorCacheControl(call.Input.OpenAIResponsesRequestInputArray[lastIdx]); cb == nil {
			t.Fatalf("step %d: this call's absolute-last message (index %d) must be marked", step, lastIdx)
		}
		prevLastIdx = lastIdx
	}

	// function_call/function_call_output items carry cache_control on the message
	// itself, not on a content block — the sliding breakpoint must use the right slot
	// when the latest item in the conversation is a tool result.
	fcoType := schemas.ResponsesMessageTypeFunctionCallOutput
	toolResult := &openai.OpenAIResponsesRequest{Model: "claude-sonnet-5"}
	toolResult.Input.OpenAIResponsesRequestInputArray = []schemas.ResponsesMessage{
		cursorConnectorMsg(schemas.ResponsesInputMessageRoleUser, "stable first message"),
		{Type: &fcoType, ResponsesToolMessage: &schemas.ResponsesToolMessage{Output: &schemas.ResponsesToolMessageOutputStruct{ResponsesFunctionToolCallOutputBlocks: []schemas.ResponsesMessageContentBlock{{Type: schemas.ResponsesInputMessageContentBlockTypeText}}}}},
	}
	addCursorClaudeSystemCacheBreakpoint(toolResult)
	if cb := toolResult.Input.OpenAIResponsesRequestInputArray[1].CacheControl; cb == nil {
		t.Fatal("absolute-last breakpoint on a function_call_output item should be message-level, not content-block-level")
	}
	if cb := toolResult.Input.OpenAIResponsesRequestInputArray[0].Content.ContentBlocks[0].CacheControl; cb == nil {
		t.Fatal("the stable-anchor breakpoint on the first message should still be applied")
	}
}

func TestCursorConnectorNormalizesToolOutputs(t *testing.T) {
	itemType := schemas.ResponsesMessageTypeFunctionCallOutput
	for _, alias := range []schemas.ResponsesMessageContentBlockType{"text", schemas.ResponsesOutputMessageContentTypeText} {
		req := &openai.OpenAIResponsesRequest{}
		req.Input.OpenAIResponsesRequestInputArray = []schemas.ResponsesMessage{{Type: &itemType, ResponsesToolMessage: &schemas.ResponsesToolMessage{Output: &schemas.ResponsesToolMessageOutputStruct{ResponsesFunctionToolCallOutputBlocks: []schemas.ResponsesMessageContentBlock{{Type: alias}}}}}}
		normalizeCursorFunctionCallOutputs(req)
		if got := req.Input.OpenAIResponsesRequestInputArray[0].Output.ResponsesFunctionToolCallOutputBlocks[0].Type; got != schemas.ResponsesInputMessageContentBlockTypeText {
			t.Fatalf("alias %q became %q", alias, got)
		}
	}
}

func parseCursorConnectorRequest(t *testing.T, raw string) *openai.OpenAIResponsesRequest {
	t.Helper()
	ctx := &fasthttp.RequestCtx{}
	ctx.Request.SetBodyString(raw)
	req := &openai.OpenAIResponsesRequest{}
	if err := cursorRequestParser(ctx, req); err != nil {
		t.Fatalf("cursorRequestParser: %v", err)
	}
	return req
}

func cursorConnectorOutputByCallID(t *testing.T, req *openai.OpenAIResponsesRequest, callID string) *schemas.ResponsesMessage {
	t.Helper()
	for i := range req.Input.OpenAIResponsesRequestInputArray {
		msg := &req.Input.OpenAIResponsesRequestInputArray[i]
		if got, ok := cursorFunctionCallOutputID(msg); ok && got == callID {
			return msg
		}
	}
	t.Fatalf("function_call_output %q not found", callID)
	return nil
}

func cursorConnectorOutputText(msg *schemas.ResponsesMessage) string {
	if msg == nil || msg.ResponsesToolMessage == nil || msg.Output == nil {
		return ""
	}
	if msg.Output.ResponsesToolCallOutputStr != nil {
		return *msg.Output.ResponsesToolCallOutputStr
	}
	for _, block := range msg.Output.ResponsesFunctionToolCallOutputBlocks {
		if block.Text != nil {
			return *block.Text
		}
	}
	return ""
}

func TestCursorConnectorReconcilesEmptyInputToolResults(t *testing.T) {
	for _, toolName := range []string{"Read", "SearchFiles", "Shell"} {
		t.Run(toolName, func(t *testing.T) {
			callID := "call_" + toolName
			raw := fmt.Sprintf(`{
				"model":"claude-sonnet-5",
				"input":[
					{"type":"message","role":"user","content":[{"type":"input_text","text":"use the tool"}]},
					{"type":"function_call","role":"assistant","call_id":%q,"name":%q,"arguments":"{}"},
					{"type":"function_call_output","call_id":%q,"output":""}
				],
				"messages":[
					{"role":"user","content":"use the tool"},
					{"role":"assistant","content":[{"type":"tool_use","id":%q,"name":%q,"input":{}}]},
					{"role":"user","content":[{"type":"tool_result","tool_use_id":%q,"content":[{"type":"text","text":"MARKER_%s"}]}]}
				],
				"tools":[{"name":%q,"description":"tool","input_schema":{"type":"object","properties":{}}}]
			}`, callID, toolName, callID, callID, toolName, callID, toolName, toolName)
			req := parseCursorConnectorRequest(t, raw)
			got := cursorConnectorOutputText(cursorConnectorOutputByCallID(t, req, callID))
			if want := "MARKER_" + toolName; got != want {
				t.Fatalf("output = %q, want %q", got, want)
			}
		})
	}
}

func TestCursorConnectorReconcilesParallelResultsWithoutOverwritingValidInput(t *testing.T) {
	raw := `{
		"model":"claude-sonnet-5",
		"input":[
			{"type":"message","role":"user","content":[{"type":"input_text","text":"parallel"}]},
			{"type":"function_call","call_id":"call_read","name":"Read","arguments":"{}"},
			{"type":"function_call","call_id":"call_search","name":"SearchFiles","arguments":"{}"},
			{"type":"function_call_output","call_id":"call_read","output":"INPUT_WINS"},
			{"type":"function_call_output","call_id":"call_search","output":[]}
		],
		"messages":[
			{"role":"user","content":"parallel"},
			{"role":"assistant","content":[
				{"type":"tool_use","id":"call_read","name":"Read","input":{}},
				{"type":"tool_use","id":"call_search","name":"SearchFiles","input":{}}
			]},
			{"role":"user","content":[
				{"type":"tool_result","tool_use_id":"call_read","content":"MESSAGES_MUST_NOT_WIN"},
				{"type":"tool_result","tool_use_id":"call_search","content":"SEARCH_FILLED"}
			]}
		],
		"tools":[{"name":"Read","input_schema":{"type":"object"}},{"name":"SearchFiles","input_schema":{"type":"object"}}]
	}`
	req := parseCursorConnectorRequest(t, raw)
	if got := cursorConnectorOutputText(cursorConnectorOutputByCallID(t, req, "call_read")); got != "INPUT_WINS" {
		t.Fatalf("valid input output was overwritten: %q", got)
	}
	if got := cursorConnectorOutputText(cursorConnectorOutputByCallID(t, req, "call_search")); got != "SEARCH_FILLED" {
		t.Fatalf("empty parallel output was not filled: %q", got)
	}
}

func TestCursorConnectorInsertsMissingResultOnceAndIgnoresOrphan(t *testing.T) {
	raw := `{
		"model":"claude-sonnet-5",
		"input":[
			{"type":"message","role":"user","content":[{"type":"input_text","text":"missing"}]},
			{"type":"function_call","call_id":"call_read","name":"Read","arguments":"{}"},
			{"type":"message","role":"assistant","content":[{"type":"output_text","text":"after"}]}
		],
		"messages":[
			{"role":"user","content":"missing"},
			{"role":"assistant","content":[{"type":"tool_use","id":"call_read","name":"Read","input":{}}]},
			{"role":"user","content":[
				{"type":"tool_result","tool_use_id":"call_read","content":"INSERTED"},
				{"type":"tool_result","tool_use_id":"call_orphan","content":"ORPHAN"}
			]}
		],
		"tools":[{"name":"Read","input_schema":{"type":"object"}}]
	}`
	req := parseCursorConnectorRequest(t, raw)
	count := 0
	for i := range req.Input.OpenAIResponsesRequestInputArray {
		if callID, ok := cursorFunctionCallOutputID(&req.Input.OpenAIResponsesRequestInputArray[i]); ok {
			if callID == "call_orphan" {
				t.Fatal("orphan tool result was injected")
			}
			if callID == "call_read" {
				count++
			}
		}
	}
	if count != 1 {
		t.Fatalf("inserted result count = %d, want 1", count)
	}
	if got := cursorConnectorOutputText(cursorConnectorOutputByCallID(t, req, "call_read")); got != "INSERTED" {
		t.Fatalf("inserted output = %q", got)
	}
}

func TestCursorConnectorPreservesLegitimateEmptyAndErrorResults(t *testing.T) {
	emptyType := schemas.ResponsesMessageTypeFunctionCallOutput
	empty := ""
	errText := "permission denied"
	req := &openai.OpenAIResponsesRequest{Input: openai.OpenAIResponsesRequestInput{
		OpenAIResponsesRequestInputArray: []schemas.ResponsesMessage{
			{Type: &emptyType, ResponsesToolMessage: &schemas.ResponsesToolMessage{CallID: schemas.Ptr("call_empty"), Output: &schemas.ResponsesToolMessageOutputStruct{ResponsesToolCallOutputStr: &empty}}},
			{Type: &emptyType, ResponsesToolMessage: &schemas.ResponsesToolMessage{CallID: schemas.Ptr("call_error"), Error: &errText}},
		},
	}}
	if cursorFunctionCallOutputHasPayload(&req.Input.OpenAIResponsesRequestInputArray[0]) {
		t.Fatal("empty result was treated as non-empty")
	}
	if !cursorFunctionCallOutputHasPayload(&req.Input.OpenAIResponsesRequestInputArray[1]) {
		t.Fatal("error result was treated as empty")
	}
}

func TestCursorConnectorNormalizesToolOutputsInBothParserPaths(t *testing.T) {
	toolShapes := []string{
		`{"type":"function","name":"Read","parameters":{"type":"object"}}`,
		`{"name":"Read","input_schema":{"type":"object"}}`,
	}
	for i, tool := range toolShapes {
		t.Run(fmt.Sprintf("path_%d", i), func(t *testing.T) {
			raw := fmt.Sprintf(`{"model":"claude-sonnet-5","input":[{"type":"function_call_output","call_id":"call_read","output":[{"type":"text","text":"ok"}]}],"tools":[%s]}`, tool)
			req := parseCursorConnectorRequest(t, raw)
			msg := cursorConnectorOutputByCallID(t, req, "call_read")
			if msg.Output == nil || len(msg.Output.ResponsesFunctionToolCallOutputBlocks) != 1 {
				t.Fatalf("unexpected output: %#v", msg.Output)
			}
			if got := msg.Output.ResponsesFunctionToolCallOutputBlocks[0].Type; got != schemas.ResponsesInputMessageContentBlockTypeText {
				t.Fatalf("output type = %q, want input_text", got)
			}
		})
	}
}

func TestCursorConnectorCompressionOffPreservesParsedRequest(t *testing.T) {
	t.Setenv("CURSOR_CLAUDE_IMAGE_COMPRESSION", "off")
	raw := `{"model":"claude-sonnet-5","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"unchanged"}]}]}`
	req := parseCursorConnectorRequest(t, raw)
	if got := cursorConnectorOutputText(&req.Input.OpenAIResponsesRequestInputArray[0]); got != "" {
		t.Fatalf("unexpected tool output helper result: %q", got)
	}
	blocks := req.Input.OpenAIResponsesRequestInputArray[0].Content.ContentBlocks
	if len(blocks) != 1 || blocks[0].Text == nil || *blocks[0].Text != "unchanged" {
		t.Fatalf("off mode changed request content: %#v", blocks)
	}
}

func TestCursorConnectorCompressionRunsBeforeCacheBreakpoints(t *testing.T) {
	source, err := os.ReadFile("cursor.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	compress := strings.Index(text, "compressCursorClaudeRequest(cursorReq)")
	cache := strings.Index(text, "addCursorClaudeToolCacheBreakpoint(cursorReq)")
	if compress < 0 || cache < 0 || compress > cache {
		t.Fatalf("compression must run before cache marking: compress=%d cache=%d", compress, cache)
	}
}

func TestCursorConnectorCompressionOnFailsClosedAndClearsFallbacks(t *testing.T) {
	t.Setenv("CURSOR_CLAUDE_IMAGE_COMPRESSION", "on")
	t.Setenv("CURSOR_CLAUDE_IMAGE_COMPRESSOR_URL", "http://127.0.0.1:1/compress")
	req := &openai.OpenAIResponsesRequest{Model: "claude-sonnet-5", Fallbacks: []string{"claude-haiku-4-5"}}
	err := compressCursorClaudeRequest(req)
	if err == nil || !strings.Contains(err.Error(), "compressor request") {
		t.Fatalf("expected explicit compressor request error, got %v", err)
	}
	if len(req.Fallbacks) != 0 {
		t.Fatalf("strict compression must clear model fallbacks, got %v", req.Fallbacks)
	}
}

func TestCursorConnectorCompressionShadowKeepsFallbacksOnCompressorFailure(t *testing.T) {
	t.Setenv("CURSOR_CLAUDE_IMAGE_COMPRESSION", "shadow")
	t.Setenv("CURSOR_CLAUDE_IMAGE_COMPRESSOR_URL", "http://127.0.0.1:1/compress")
	req := &openai.OpenAIResponsesRequest{Model: "claude-sonnet-5", Fallbacks: []string{"claude-haiku-4-5"}}
	if err := compressCursorClaudeRequest(req); err != nil {
		t.Fatalf("shadow mode must remain diagnostic-only: %v", err)
	}
	if len(req.Fallbacks) != 1 {
		t.Fatalf("shadow mode unexpectedly changed fallbacks: %v", req.Fallbacks)
	}
}
