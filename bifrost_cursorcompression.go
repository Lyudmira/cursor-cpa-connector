package integrations

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/bytedance/sonic"
	"github.com/maximhq/bifrost/core/providers/openai"
)

const cursorClaudeCompressionKillSwitch = "/app/data/disable-image-compression"

type cursorClaudeCompressionResponse struct {
	Request     json.RawMessage                 `json:"request"`
	Changed     bool                            `json:"changed"`
	Diagnostics []cursorClaudeCompressionMetric `json:"diagnostics"`
}

type cursorClaudeCompressionMetric struct {
	Bucket      string   `json:"bucket"`
	Applied     bool     `json:"applied"`
	TextTokens  int      `json:"text_tokens"`
	ImageTokens int      `json:"image_tokens"`
	PNGHashes   []string `json:"png_hashes"`
}

var cursorClaudeCompressionHTTPClient = &http.Client{Timeout: 5 * time.Second}

func cursorClaudeCompressionMode() string {
	mode := strings.ToLower(strings.TrimSpace(os.Getenv("CURSOR_CLAUDE_IMAGE_COMPRESSION")))
	if mode != "shadow" && mode != "on" {
		return "off"
	}
	if _, err := os.Stat(cursorClaudeCompressionKillSwitch); err == nil {
		return "off"
	}
	return mode
}

func cursorClaudeCompressionBucket(name string) bool {
	value := strings.ToLower(strings.TrimSpace(os.Getenv(name)))
	return value == "1" || value == "on" || value == "true" || value == "yes"
}

func compressCursorClaudeRequest(req *openai.OpenAIResponsesRequest) error {
	mode := cursorClaudeCompressionMode()
	if mode == "off" || req == nil || !isClaudeCursorModel(req.Model) {
		return nil
	}

	strict := mode == "on"
	fail := func(stage string, err error) error {
		if !strict {
			slog.Warn("cursor Claude image compression skipped", "mode", mode, "stage", stage, "error", err)
			return nil
		}
		return fmt.Errorf("cursor Claude image compression failed at %s: %w", stage, err)
	}
	if strict {
		// An enabled image-compression request must never escape through a client-provided
		// model fallback, which could silently resend the original text-heavy context.
		req.Fallbacks = nil
	}

	requestJSON, err := sonic.Marshal(req)
	if err != nil {
		return fail("request marshal", err)
	}
	var payload map[string]interface{}
	if err := sonic.Unmarshal(requestJSON, &payload); err != nil {
		return fail("payload decode", err)
	}
	payload["options"] = map[string]bool{
		"static":       cursorClaudeCompressionBucket("CURSOR_CLAUDE_IMAGE_COMPRESSION_STATIC"),
		"tool_results": cursorClaudeCompressionBucket("CURSOR_CLAUDE_IMAGE_COMPRESSION_TOOL_RESULTS"),
		"history":      cursorClaudeCompressionBucket("CURSOR_CLAUDE_IMAGE_COMPRESSION_HISTORY"),
	}
	body, err := sonic.Marshal(payload)
	if err != nil {
		return fail("compressor payload marshal", err)
	}

	endpoint := strings.TrimSpace(os.Getenv("CURSOR_CLAUDE_IMAGE_COMPRESSOR_URL"))
	if endpoint == "" {
		endpoint = "http://cursor-image-compressor:47822/compress"
	}
	httpReq, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return fail("compressor request creation", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	resp, err := cursorClaudeCompressionHTTPClient.Do(httpReq)
	if err != nil {
		return fail("compressor request", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fail("compressor response", fmt.Errorf("unexpected HTTP status %s", resp.Status))
	}

	var result cursorClaudeCompressionResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fail("compressor response decode", err)
	}
	for _, metric := range result.Diagnostics {
		slog.Info("cursor Claude image compression", "mode", mode, "bucket", metric.Bucket, "applied", metric.Applied, "text_tokens", metric.TextTokens, "image_tokens", metric.ImageTokens, "png_hashes", metric.PNGHashes)
	}
	if mode != "on" || !result.Changed {
		return nil
	}
	if len(result.Request) == 0 {
		return fail("compressor result validation", errors.New("changed response omitted transformed request"))
	}
	candidate := &openai.OpenAIResponsesRequest{}
	if err := sonic.Unmarshal(result.Request, candidate); err != nil {
		return fail("transformed request decode", err)
	}
	if candidate.Model == "" || (len(candidate.Input.OpenAIResponsesRequestInputArray) == 0 && candidate.Input.OpenAIResponsesRequestInputStr == nil) {
		return fail("transformed request validation", errors.New("transformed request is missing model or input"))
	}
	candidate.Fallbacks = nil
	*req = *candidate
	return nil
}
