package integrations

import (
	"bytes"
	"encoding/json"
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

func compressCursorClaudeRequest(req *openai.OpenAIResponsesRequest) {
	mode := cursorClaudeCompressionMode()
	if mode == "off" || req == nil || !isClaudeCursorModel(req.Model) {
		return
	}

	requestJSON, err := sonic.Marshal(req)
	if err != nil {
		return
	}
	var payload map[string]interface{}
	if err := sonic.Unmarshal(requestJSON, &payload); err != nil {
		return
	}
	payload["options"] = map[string]bool{
		"static":       cursorClaudeCompressionBucket("CURSOR_CLAUDE_IMAGE_COMPRESSION_STATIC"),
		"tool_results": cursorClaudeCompressionBucket("CURSOR_CLAUDE_IMAGE_COMPRESSION_TOOL_RESULTS"),
		"history":      cursorClaudeCompressionBucket("CURSOR_CLAUDE_IMAGE_COMPRESSION_HISTORY"),
	}
	body, err := sonic.Marshal(payload)
	if err != nil {
		return
	}

	endpoint := strings.TrimSpace(os.Getenv("CURSOR_CLAUDE_IMAGE_COMPRESSOR_URL"))
	if endpoint == "" {
		endpoint = "http://cursor-image-compressor:47822/compress"
	}
	httpReq, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return
	}
	httpReq.Header.Set("Content-Type", "application/json")
	resp, err := cursorClaudeCompressionHTTPClient.Do(httpReq)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return
	}

	var result cursorClaudeCompressionResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return
	}
	for _, metric := range result.Diagnostics {
		slog.Info("cursor Claude image compression", "mode", mode, "bucket", metric.Bucket, "applied", metric.Applied, "text_tokens", metric.TextTokens, "image_tokens", metric.ImageTokens, "png_hashes", metric.PNGHashes)
	}
	if mode != "on" || !result.Changed || len(result.Request) == 0 {
		return
	}
	candidate := &openai.OpenAIResponsesRequest{}
	if err := sonic.Unmarshal(result.Request, candidate); err != nil {
		return
	}
	*req = *candidate
}
