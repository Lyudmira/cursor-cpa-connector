package schemas

import "testing"

func TestCursorConnectorThinkingHighAliases(t *testing.T) {
	tests := map[string]string{
		"gpt-5.4-thinking-high":                 "gpt-5.4",
		"gpt-5.4-mini-thinking-high":            "gpt-5.4-mini",
		"gpt-5.5-thinking-high":                 "gpt-5.5",
		"gpt-5.6-sol-thinking-high":             "gpt-5.6-sol",
		"gpt-5.6-terra-thinking-high":           "gpt-5.6-terra",
		"gpt-5.6-luna-thinking-high":            "gpt-5.6-luna",
		"gpt-5.3-codex-spark-thinking-high":     "gpt-5.3-codex-spark",
		"muskapi/claude-sonnet-5-thinking-high": "claude-sonnet-5",
		"muskapi/claude-fable-5-thinking-high":  "claude-fable-5",
		"muskapi/claude-opus-4-8-thinking-high": "claude-opus-4-8",
	}
	for alias, wantBase := range tests {
		low := "low"
		params := &ResponsesParameters{Reasoning: &ResponsesParametersReasoning{Effort: &low}}
		gotBase, ok := ApplyCursorThinkingHighAlias(alias, params)
		if !ok || gotBase != wantBase {
			t.Fatalf("alias %q resolved to %q, ok=%v; want %q", alias, gotBase, ok, wantBase)
		}
		if params.Reasoning == nil || params.Reasoning.Effort == nil || *params.Reasoning.Effort != "high" {
			t.Fatalf("alias %q did not force reasoning.effort=high: %#v", alias, params.Reasoning)
		}
	}
}

func TestCursorConnectorThinkingHighLeavesOtherModelsAlone(t *testing.T) {
	for _, model := range []string{
		"gpt-5.6-sol",
		"gpt-5.6-sol-thinking-low",
		"gpt-5.6-sol-thinking-medium",
		"gpt-5.6-sol-thinking-xhigh",
		"gpt-5.6-sol-thinking-max",
		"unknown-thinking-high",
		"muskapi/claude-sonnet-5",
	} {
		medium := "medium"
		params := &ResponsesParameters{Reasoning: &ResponsesParametersReasoning{Effort: &medium}}
		got, ok := ApplyCursorThinkingHighAlias(model, params)
		if ok || got != model {
			t.Fatalf("model %q unexpectedly resolved to %q, ok=%v", model, got, ok)
		}
		if params.Reasoning == nil || params.Reasoning.Effort == nil || *params.Reasoning.Effort != "medium" {
			t.Fatalf("model %q reasoning was modified: %#v", model, params.Reasoning)
		}
	}
}

func TestCursorConnectorThinkingHighModelList(t *testing.T) {
	resp := &BifrostListModelsResponse{Data: []Model{
		{ID: "cpa/gpt-5.6-sol"},
		{ID: "muskapi-anthropic/claude-sonnet-5"},
		{ID: "cpa/gpt-5.3-codex-spark"},
	}}
	AppendCursorThinkingHighModels(resp)

	ids := make([]string, 0, len(resp.Data))
	for _, model := range resp.Data {
		ids = append(ids, model.ID)
	}
	want := []string{
		"cpa/gpt-5.6-sol",
		"gpt-5.6-sol-thinking-high",
		"muskapi-anthropic/claude-sonnet-5",
		"muskapi/claude-sonnet-5-thinking-high",
		"cpa/gpt-5.3-codex-spark",
	}
	if len(ids) != len(want) {
		t.Fatalf("model ids = %v, want %v", ids, want)
	}
	for i := range want {
		if ids[i] != want[i] {
			t.Fatalf("model ids = %v, want %v", ids, want)
		}
	}

	// Idempotence: repeated conversion paths must not duplicate synthetic aliases.
	AppendCursorThinkingHighModels(resp)
	if len(resp.Data) != len(want) {
		t.Fatalf("second append duplicated aliases: %v", resp.Data)
	}
}

func TestCursorConnectorThinkingHighSparkRequiresBackupAnchor(t *testing.T) {
	withoutBackup := &BifrostListModelsResponse{Data: []Model{{ID: "cpa/gpt-5.3-codex-spark"}}}
	AppendCursorThinkingHighModels(withoutBackup)
	if len(withoutBackup.Data) != 1 {
		t.Fatalf("Spark high exposed without newapi anchor: %#v", withoutBackup.Data)
	}

	withBackup := &BifrostListModelsResponse{Data: []Model{{ID: "newapi/gpt-5.3-codex-spark"}}}
	AppendCursorThinkingHighModels(withBackup)
	if len(withBackup.Data) != 2 || withBackup.Data[1].ID != "gpt-5.3-codex-spark-thinking-high" {
		t.Fatalf("Spark high missing with newapi anchor: %#v", withBackup.Data)
	}
}
