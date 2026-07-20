package responses

import (
	"testing"

	"github.com/tidwall/gjson"
)

func TestConvertOpenAIResponsesRequestToCodexNormalizesFunctionOutputImages(t *testing.T) {
	inputJSON := []byte(`{
		"model": "gpt-5.6-sol",
		"input": [{
			"type": "function_call_output",
			"call_id": "call_image",
			"output": [
				{"type": "text", "text": "Read image file"},
				{"type": "image_url", "image_url": "data:image/png;base64,AAAA"},
				{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,BBBB", "detail": "high"}},
				{"type": "input_image", "image_url": "data:image/webp;base64,CCCC"},
				{"type": "computer_screenshot", "image_url": "data:image/png;base64,DDDD"}
			]
		}]
	}`)

	output := ConvertOpenAIResponsesRequestToCodex("gpt-5.6-sol", inputJSON, false)

	wants := map[string]string{
		"input.0.output.0.type":      "input_text",
		"input.0.output.1.type":      "input_image",
		"input.0.output.1.image_url": "data:image/png;base64,AAAA",
		"input.0.output.2.type":      "input_image",
		"input.0.output.2.image_url": "data:image/jpeg;base64,BBBB",
		"input.0.output.2.detail":    "high",
		"input.0.output.3.type":      "input_image",
		"input.0.output.3.image_url": "data:image/webp;base64,CCCC",
		"input.0.output.4.type":      "computer_screenshot",
	}
	for path, want := range wants {
		if got := gjson.GetBytes(output, path).String(); got != want {
			t.Errorf("%s = %q, want %q: %s", path, got, want, output)
		}
	}
	if gjson.GetBytes(output, "input.0.output.2.image_url.url").Exists() {
		t.Fatalf("nested image_url.url should be flattened: %s", output)
	}
}

func TestConvertOpenAIResponsesRequestToCodexLeavesMalformedImageOutputUnchanged(t *testing.T) {
	inputJSON := []byte(`{
		"model": "gpt-5.6-sol",
		"input": [{
			"type": "function_call_output",
			"call_id": "call_image",
			"output": [{"type": "image_url", "image_url": {"detail": "low"}}]
		}]
	}`)

	output := ConvertOpenAIResponsesRequestToCodex("gpt-5.6-sol", inputJSON, false)
	if got := gjson.GetBytes(output, "input.0.output.0.type").String(); got != "image_url" {
		t.Fatalf("malformed image output type = %q, want image_url: %s", got, output)
	}
}
