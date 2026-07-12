package schemas

// CursorThinkingHighAlias maps the small, explicit set of client-visible
// thinking-high model IDs to the existing base models used by Bifrost routing.
// No suffix-based fallback is intentional: unknown and non-high models must keep
// their existing behavior.
var CursorThinkingHighAlias = map[string]string{
	"gpt-5.4-thinking-high":                    "gpt-5.4",
	"gpt-5.4-mini-thinking-high":               "gpt-5.4-mini",
	"gpt-5.5-thinking-high":                    "gpt-5.5",
	"gpt-5.6-sol-thinking-high":                "gpt-5.6-sol",
	"gpt-5.6-terra-thinking-high":              "gpt-5.6-terra",
	"gpt-5.6-luna-thinking-high":               "gpt-5.6-luna",
	"gpt-5.3-codex-spark-thinking-high":        "gpt-5.3-codex-spark",
	"muskapi/claude-sonnet-5-thinking-high":    "claude-sonnet-5",
	"muskapi/claude-fable-5-thinking-high":     "claude-fable-5",
	"muskapi/claude-opus-4-8-thinking-high":    "claude-opus-4-8",
}

type cursorThinkingHighListAlias struct {
	Alias    string
	AnchorID string
}

var cursorThinkingHighListAliases = []cursorThinkingHighListAlias{
	{Alias: "gpt-5.4-thinking-high", AnchorID: "cpa/gpt-5.4"},
	{Alias: "gpt-5.4-mini-thinking-high", AnchorID: "cpa/gpt-5.4-mini"},
	{Alias: "gpt-5.5-thinking-high", AnchorID: "cpa/gpt-5.5"},
	{Alias: "gpt-5.6-sol-thinking-high", AnchorID: "cpa/gpt-5.6-sol"},
	{Alias: "gpt-5.6-terra-thinking-high", AnchorID: "cpa/gpt-5.6-terra"},
	{Alias: "gpt-5.6-luna-thinking-high", AnchorID: "cpa/gpt-5.6-luna"},
	// Requiring the newapi anchor keeps Spark hidden when no backup route exists.
	{Alias: "gpt-5.3-codex-spark-thinking-high", AnchorID: "newapi/gpt-5.3-codex-spark"},
	{Alias: "muskapi/claude-sonnet-5-thinking-high", AnchorID: "muskapi-anthropic/claude-sonnet-5"},
	{Alias: "muskapi/claude-fable-5-thinking-high", AnchorID: "muskapi-anthropic/claude-fable-5"},
	{Alias: "muskapi/claude-opus-4-8-thinking-high", AnchorID: "muskapi-anthropic/claude-opus-4-8"},
}

// ApplyCursorThinkingHighAlias resolves an explicitly supported high alias and
// forces reasoning effort to high. It returns false without modifying params for
// ordinary models, other effort suffixes, and unknown high-like names.
func ApplyCursorThinkingHighAlias(model string, params *ResponsesParameters) (string, bool) {
	baseModel, ok := CursorThinkingHighAlias[model]
	if !ok {
		return model, false
	}
	if params != nil {
		if params.Reasoning == nil {
			params.Reasoning = &ResponsesParametersReasoning{}
		}
		high := "high"
		params.Reasoning.Effort = &high
	}
	return baseModel, true
}

// AppendCursorThinkingHighModels adds each high alias immediately after its
// routable base-model anchor. Existing entries are never reordered or changed,
// aliases are not duplicated, and Spark is only added when its newapi anchor is
// present (which means backup routing is configured).
func AppendCursorThinkingHighModels(resp *BifrostListModelsResponse) {
	if resp == nil || len(resp.Data) == 0 {
		return
	}

	existing := make(map[string]struct{}, len(resp.Data))
	byAnchor := make(map[string]string, len(cursorThinkingHighListAliases))
	for _, model := range resp.Data {
		existing[model.ID] = struct{}{}
	}
	for _, spec := range cursorThinkingHighListAliases {
		if _, found := existing[spec.Alias]; found {
			continue
		}
		byAnchor[spec.AnchorID] = spec.Alias
	}

	withAliases := make([]Model, 0, len(resp.Data)+len(byAnchor))
	for _, model := range resp.Data {
		withAliases = append(withAliases, model)
		alias, ok := byAnchor[model.ID]
		if !ok {
			continue
		}
		aliasModel := model
		aliasModel.ID = alias
		aliasModel.Alias = nil
		aliasModel.Name = Ptr(alias)
		withAliases = append(withAliases, aliasModel)
	}
	resp.Data = withAliases
}
