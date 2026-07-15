#!/usr/bin/env bash
# Build patched CLIProxyAPI (cpa) from bash — companion to build-patched-cpa.ps1.
# Same source tree, same patches, same docker deploy tail; for anyone who'd
# rather not touch PowerShell, or wants to build/deploy from a real Linux box.
#
# Produces two artifacts from one patched source tree:
#   1. a native binary for the current OS (local debugging only)
#   2. the cpa-patched:local Linux docker image, redeployed as the `cpa`
#      container — this is what actually serves 127.0.0.1:8317 in prod.
#
# All paths are overridable via env vars so this also runs on a plain Linux
# host, not just this Windows box via git-bash. Defaults match this project's
# current layout.
set -euo pipefail

SRC="${CPA_SRC:-$HOME/AppData/Local/Temp/CLIProxyAPI-src}"
if [ ! -d "$SRC" ]; then
    # not on this Windows/git-bash box (or exe build never ran here) -- try a
    # plain-Linux-friendly default instead
    SRC="${CPA_SRC:-$HOME/.cache/CLIProxyAPI-src}"
fi

PROJECT_DIR="${CPA_PROJECT_DIR:-/c/CLIProxyAPI}"
PATCHES_DIR="${CPA_PATCHES_DIR:-$PROJECT_DIR/patches}"
DOCKERFILE="${CPA_DOCKERFILE:-$PROJECT_DIR/Dockerfile.cpa-patched}"
CONFIG_DOCKER="${CPA_CONFIG_DOCKER:-$PROJECT_DIR/config.docker.yaml}"
AUTHS_DIR="${CPA_AUTHS_DIR:-$PROJECT_DIR/auths}"
LOGS_DIR="${CPA_LOGS_DIR:-$PROJECT_DIR/logs}"
IMAGE="cpa-patched:local"
CONTAINER="cpa"

if [ ! -d "$SRC" ]; then
    echo "Source not found: $SRC" >&2
    echo "Clone v7.2.50 first: git clone --depth 1 --branch v7.2.50 https://github.com/router-for-me/CLIProxyAPI.git \"$SRC\"" >&2
    exit 1
fi

echo "==> Applying patches to $SRC"
chat_response_target="$SRC/internal/translator/codex/openai/chat-completions/codex_openai_response.go"
responses_request_target="$SRC/internal/translator/codex/openai/responses/codex_openai-responses_request.go"
chat_request_target="$SRC/internal/translator/codex/openai/chat-completions/codex_openai_request.go"

cp -f "$PATCHES_DIR/codex_openai_response.go" "$chat_response_target"
cp -f "$PATCHES_DIR/codex_openai_responses_request.go" "$responses_request_target"

# case "text": -> case "text", "output_text":  (same regex as the .ps1 version)
perl -0777 -pi -e \
    's/case "text":(\s*part := \[\]byte\(`\{\}`\)\s*part, _ = sjson\.SetBytes\(part, "type", "input_text"\))/case "text", "output_text":$1/' \
    "$chat_request_target"

pushd "$SRC" >/dev/null
gofmt -w "$chat_request_target"
go test ./internal/translator/codex/openai/chat-completions/...
go test ./internal/translator/codex/openai/responses/...

echo "==> Building native binary (local debug only, not what runs in prod)"
goos="$(go env GOOS)"
ext=""
[ "$goos" = "windows" ] && ext=".exe"
native_out="$PROJECT_DIR/cli-proxy-api-patched-native$ext"
go build -o "$native_out" ./cmd/server
echo "Built: $native_out"
popd >/dev/null

if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found; skipping image build/redeploy. Native binary only."
    exit 0
fi

echo "==> Building $IMAGE from $SRC"
# Build with a relative "." context from inside $SRC rather than passing $SRC
# as an absolute unix-style path -- git-bash's docker CLI wrapper only
# resolves the "/c/..." convention for single bind-mount paths, not for the
# build context positional arg, and fails with "path not found" otherwise.
# A plain absolute path context (real Linux/macOS) works fine either way.
pushd "$SRC" >/dev/null
docker build -f "$DOCKERFILE" -t "$IMAGE" --build-arg VERSION=v7.2.50-patched .
popd >/dev/null

echo "==> Redeploying $CONTAINER container"
docker stop "$CONTAINER" >/dev/null 2>&1 || true
docker rm "$CONTAINER" >/dev/null 2>&1 || true

MSYS2_ARG_CONV_EXCL="*" docker run -d \
    --name "$CONTAINER" \
    --restart unless-stopped \
    -p 127.0.0.1:8317:8317 \
    -v "$CONFIG_DOCKER:/CLIProxyAPI/config.yaml:ro" \
    -v "$AUTHS_DIR:/CLIProxyAPI/auths" \
    -v "$LOGS_DIR:/CLIProxyAPI/logs" \
    "$IMAGE"

echo "==> Waiting for cpa to come up..."
for _ in $(seq 1 15); do
    sleep 2
    if curl -fsS -o /dev/null -m 3 http://127.0.0.1:8317/; then
        echo "cpa is up."
        exit 0
    fi
done

echo "cpa container started but did not answer within 30s; check: docker logs cpa"
exit 0
