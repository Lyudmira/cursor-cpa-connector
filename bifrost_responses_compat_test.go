package schemas

import (
    "bytes"
    "testing"
)

func TestCursorConnectorFunctionToolCompatibility(t *testing.T) {
    nested := []byte(`{"type":"function","function":{"name":"Shell","description":"run commands","parameters":{"type":"object"},"cache_control":{"type":"ephemeral"}}}`)
    var nestedTool ResponsesTool
    if err := Unmarshal(nested, &nestedTool); err != nil { t.Fatalf("nested unmarshal failed: %v", err) }
    if nestedTool.Name == nil || *nestedTool.Name != "Shell" || nestedTool.ResponsesToolFunction == nil || nestedTool.ResponsesToolFunction.Parameters == nil { t.Fatalf("nested metadata lost: %#v", nestedTool) }
    if nestedTool.CacheControl == nil || nestedTool.CacheControl.Type != CacheControlTypeEphemeral { t.Fatalf("cache_control lost: %#v", nestedTool.CacheControl) }

    chatTool := nestedTool.ToChatTool()
    if chatTool.CacheControl == nil || chatTool.CacheControl.Type != CacheControlTypeEphemeral { t.Fatalf("Responses to Chat conversion lost cache_control: %#v", chatTool.CacheControl) }
    roundTrip := chatTool.ToResponsesTool()
    if roundTrip.CacheControl == nil || roundTrip.CacheControl.Type != CacheControlTypeEphemeral { t.Fatalf("Chat to Responses conversion lost cache_control: %#v", roundTrip.CacheControl) }

    flat := []byte(`{"type":"function","name":"Shell","input_schema":{"type":"object"}}`)
    var flatTool ResponsesTool
    if err := Unmarshal(flat, &flatTool); err != nil { t.Fatalf("flat unmarshal failed: %v", err) }
    if flatTool.ResponsesToolFunction == nil || flatTool.ResponsesToolFunction.Parameters == nil { t.Fatalf("input_schema lost: %#v", flatTool) }
    encoded, err := MarshalSorted(flatTool)
    if err != nil { t.Fatal(err) }
    if bytes.Contains(encoded, []byte(`"strict":null`)) { t.Fatalf("strict:null emitted: %s", encoded) }
    if !bytes.HasPrefix(encoded, []byte(`{"type":"function","name":"Shell"`)) { t.Fatalf("unstable field order: %s", encoded) }
}
