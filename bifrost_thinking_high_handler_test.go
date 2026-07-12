package handlers

import (
	"testing"

	"github.com/maximhq/bifrost/core/schemas"
	"github.com/valyala/fasthttp"
)

func TestCursorConnectorPrepareResponsesThinkingHighClaude(t *testing.T) {
	var ctx fasthttp.RequestCtx
	ctx.Request.SetBodyString(`{"model":"muskapi/claude-sonnet-5-thinking-high","input":"hello","reasoning":{"effort":"low"}}`)

	req, bifrostReq, err := prepareResponsesRequest(&ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if req.Model != "claude-sonnet-5" || bifrostReq.Model != "claude-sonnet-5" {
		t.Fatalf("Claude high model was not restored: req=%q bifrost=%q", req.Model, bifrostReq.Model)
	}
	if bifrostReq.Provider != "" {
		t.Fatalf("Claude high must return to routing with no pinned provider, got %q", bifrostReq.Provider)
	}
	if bifrostReq.Params == nil || bifrostReq.Params.Reasoning == nil || bifrostReq.Params.Reasoning.Effort == nil || *bifrostReq.Params.Reasoning.Effort != "high" {
		t.Fatalf("Claude high did not force reasoning effort: %#v", bifrostReq.Params)
	}
}

func TestCursorConnectorPrepareResponsesOrdinaryClaudeUnchanged(t *testing.T) {
	var ctx fasthttp.RequestCtx
	ctx.Request.SetBodyString(`{"model":"muskapi/claude-sonnet-5","input":"hello","reasoning":{"effort":"medium"}}`)

	req, bifrostReq, err := prepareResponsesRequest(&ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if req.Model != "muskapi/claude-sonnet-5" {
		t.Fatalf("ordinary request model changed: %q", req.Model)
	}
	if bifrostReq.Provider != schemas.ModelProvider("") || bifrostReq.Model != "muskapi/claude-sonnet-5" {
		t.Fatalf("ordinary Claude route changed: provider=%q model=%q", bifrostReq.Provider, bifrostReq.Model)
	}
	if bifrostReq.Params == nil || bifrostReq.Params.Reasoning == nil || bifrostReq.Params.Reasoning.Effort == nil || *bifrostReq.Params.Reasoning.Effort != "medium" {
		t.Fatalf("ordinary Claude reasoning changed: %#v", bifrostReq.Params)
	}
}
