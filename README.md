# Cursor CPA Connector

Cursor's Codex-mode client sends Responses API history and tool payloads in a shape that is looser than what upstream Codex and Bifrost's schema layer expect. Failure modes we patch for:

1. **Input history** - Cursor attaches `role` to non-`message` items (`function_call`, `function_call_output`, ...) and uses `output[].type: "text"` where Codex expects `input_text`.
2. **Tool schemas through Bifrost** - nested `function.name` / `function.parameters` and flat `input_schema` get dropped; `strict: null` is emitted when Cursor omits `strict`.

This kit patches CPA and Bifrost at the source level, rebuilds them locally, and can interactively wire Bifrost primary/backup upstreams.

## Prerequisites

- Windows PowerShell, Git, Go (`go` on PATH), Docker Desktop (for Bifrost), Python 3 (`python` on PATH for config init)
- CPA already installed and **logged in** (OAuth). Init does not perform login.
- Cursor will need its API Base URL pointed at Bifrost (for example `http://127.0.0.1:8080`) after install

## Recommended: interactive install + config

```powershell
cd C:\CLIProxyAPI\patches\cursor-cpa-connector
.\install-cursor-cpa-bifrost-patches.ps1 -InitConfig -RestartCPA -RestartBifrost
```

`-InitConfig` opens a short terminal questionnaire (default). You do **not** need a `.env` file for this path.

The prompts explain why there are two upstreams:

1. **Primary** - normal GPT + Anthropic traffic (you must enter Base URL unless you also pass `-DefaultEndpoint`, which allows Enter to use `https://api.muskapi.cc/v1`)
2. **Backup** (optional) - models the primary does not offer, and failover if primary fails. **Press Enter on the backup Base URL to skip** if you do not have a backup.

Suggested backup URL if you want one: `https://ai.centos.hk/v1` (paste it; Enter alone still means skip).

### Routing model lists

`init_bifrost_config.py` has two intentionally different model lists:

- `PRIMARY_MODELS` are routed to the primary OpenAI-compatible upstream (`muskapi` by default), with optional backup fallback when backup is configured.
- `CPA_MODELS` are routed directly to CPA/OAuth. They do **not** fall back to the primary or backup upstream after CPA capacity, quota, or account availability is exhausted; CPA will return an error instead.

Use `CPA_MODELS` for models where downstream fallback is known to behave incorrectly, has unacceptable performance, or may cause unexpected billing. Users should review this tradeoff and configure their own routing and fallback policy for their provider/account mix.

You can run config alone:

```powershell
.\init-config.ps1
.\init-config.ps1 -DefaultEndpoint
```

## What each patch does

### CPA - Responses request (`codex_openai_responses_request.go`)

Copied wholesale into `internal/translator/codex/openai/responses/codex_openai-responses_request.go`.

- `sanitizeCodexResponsesInputItems` - `system` -> `developer` on messages; strip `role` from non-message items; `text`/`output_text` -> `input_text` on `function_call_output`.
- `removeUnsupportedCursorCustomToolsForCodexBYOK` - drop Cursor `ApplyPatch` custom tool on BYOK routes.
- `addCodexBYOKToolCompatibilityInstruction` - optional instruction when Shell is present without ApplyPatch.
- `normalizeCodexBuiltinTools` - e.g. `web_search_preview` -> `web_search`.
- `applyResponsesCompactionCompatibility` - Codex `/responses` compaction compatibility.

### CPA - Chat-completions response (`codex_openai_response.go`)

Dropped in wholesale from CLIProxyAPI PR #4079 into `internal/translator/codex/openai/chat-completions/codex_openai_response.go`. Adds `custom_tool_call` handling on the chat-completions translation path.

### Bifrost (`core/schemas/responses.go`)

Regex patch on `core/schemas/responses.go` (via the install script):

- `ResponsesToolTypeFunction`: fallback to `raw["function"]` and `raw["input_schema"]`.
- `Strict *bool` json tag gets `omitempty`.
- Cursor `function_call_output.output[]` content aliases `text` / `output_text` are normalized to `input_text` before provider forwarding.
- Claude Cursor requests with tools receive one `cache_control: {"type":"ephemeral"}` breakpoint on the final tool when the client did not provide an explicit cache policy. The Responses-to-Chat conversion preserves that marker for OpenAI-compatible Claude upstreams.

## Install mechanism

When `codex_openai_responses_request.go` exists next to the install script, it is **copied** into the CPA checkout and the legacy inline regex substitution for the request translator is skipped.

If that file is missing, the script falls back to the older inline regex patch (sanitize-only).

Bifrost is patched via regex against `main`, then built into `bifrost-patched:local`. With `-RestartBifrost`, install creates the data directory and runs the container.

Pinned refs: CPA `v7.2.50` (default), Bifrost `main`.

## Advanced: non-interactive `.env` (`-UseEnv`)

Only if you explicitly opt in. Copy `.env.example` to `.env`, then:

```powershell
.\init-config.ps1 -UseEnv
# or
.\install-cursor-cpa-bifrost-patches.ps1 -InitConfig -UseEnv -RestartCPA -RestartBifrost
```

Semantics:

- Missing `PRIMARY_BASE_URL` / `BACKUP_BASE_URL` fields -> built-in defaults (`muskapi` / `ai.centos.hk`)
- Empty or omitted `BACKUP_API_KEY` -> **skip backup**
- `PRIMARY_API_KEY` is required for `-UseEnv`

## Verifying the fix

```powershell
Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8317/v1/models" -Headers @{ Authorization = "Bearer sk-cpa-local" }
docker inspect bifrost --format "{{.State.Health.Status}}"
```

### Codex OAuth input sanitization (`gpt-5.5`)

```powershell
$body = @{
  model = "gpt-5.5"
  stream = $false
  input = @(
    @{ type = "message"; role = "system"; content = @(@{ type = "input_text"; text = "You are concise." }) },
    @{ id = "fc_test_role"; type = "function_call"; status = "completed"; role = "assistant"; call_id = "call_test_role"; name = "Shell"; arguments = '{"command":"pwd"}' },
    @{ type = "function_call_output"; role = "tool"; call_id = "call_test_role"; output = @(@{ type = "text"; text = "C:\CLIProxyAPI" }) },
    @{ type = "message"; role = "user"; content = @(@{ type = "input_text"; text = "reply ok" }) }
  )
} | ConvertTo-Json -Depth 10

Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8317/v1/responses" -Method Post `
  -Headers @{ Authorization = "Bearer sk-cpa-local"; "Content-Type" = "application/json" } -Body $body
```

Expect HTTP 200. Before the patch, Codex rejects `input[n].role` or `output[].type: "text"`.

### Claude tool-prefix caching

For a Claude model routed through Bifrost, send the same stable tool list at least twice and inspect `logs.db`. The forwarded request parameters should contain exactly one cache breakpoint on the final tool. A positive `cached_read_tokens` value confirms that the upstream accepted and reused the cached prefix. Some OpenAI-compatible providers may preserve the marker but still report zero cache reads; that indicates an upstream cache implementation or accounting limitation rather than marker loss inside Bifrost.

## Troubleshooting: Codex WebSocket to `/v1/responses`

This kit's CPA Responses patch fixes **HTTP** request-body compatibility (roles, `input_text`, tools, compaction). It does **not** implement Codex's WebSocket Responses transport.

If Codex (or a Codex-shaped client) errors while opening a WebSocket against your Bifrost/CPA endpoint, for example:

```text
failed to connect to websocket:
HTTP error: 400 Bad Request
wss://.../v1/responses
```

the client is trying to use WebSockets. Point it at HTTP Responses instead by disabling WebSockets on that provider in Codex config (`~/.codex/config.toml` or equivalent). Prefer a **custom** `[model_providers.xxx]` entry with `model_provider = "xxx"`; do not rely on `openai_base_url` alone, because that keeps the built-in `openai` provider (WebSocket-capable) and cannot pin `supports_websockets = false`:

```toml
model_provider = "xxx"

[model_providers.xxx]
name = "xxx"
base_url = "https://xxx/v1"
wire_api = "responses"
supports_websockets = false
```

Replace `xxx` / `base_url` with your Bifrost (or edge) URL. With `supports_websockets = false`, Codex uses ordinary HTTP `POST /v1/responses`, which is what this kit patches for.

### Codex UI can rewrite `~/.codex/config.toml`

The Codex / ChatGPT VS Code extension may rewrite the whole user `config.toml` when it persists the composer default model (internal path: `set-default-model-config-for-host`, logged as `Setting default model and reasoning effort`). That writeback often keeps only fields the UI manages (`model`, `model_reasoning_effort`, `openai_base_url`, project trust, …) and **drops** hand-written `[model_providers.*]` blocks, including `supports_websockets = false`. Afterward you may see WebSocket `400` again, and older threads that still reference the removed provider id fail with `Model provider \`xxx\` not found`.

Do **not** mark the whole `config.toml` read-only (`attrib +R`). That blocks the UI from changing the default model and is too coarse.

Instead, pin only the provider trailer (leave `model` / effort editable). One-shot:

```powershell
cd C:\CLIProxyAPI\patches\cursor-cpa-connector
.\pin-codex-lycorica-provider.ps1
```

Keep it pinned across UI writebacks (recommended while using Codex). `-Watch` uses `FileSystemWatcher` (blocks on OS file events; idle CPU near zero — not a poll loop):

```powershell
.\pin-codex-lycorica-provider.ps1 -Watch
```

The script strips a dropped/rewritten `openai_base_url` and re-appends a fixed trailer at the end of the file:

```toml
model_provider = "lycorica"

[model_providers.lycorica]
name = "lycorica"
base_url = "https://cursor.lycorica.com/cursor/v1"
wire_api = "responses"
supports_websockets = false
```

UI-owned keys above that trailer stay free to change. Override provider id / URL with `-ProviderId` / `-BaseUrl` if your edge name differs.

## Files

| Path | Role |
|------|------|
| `install-cursor-cpa-bifrost-patches.ps1` | Clone/patch/build CPA and Bifrost; optional `-InitConfig` |
| `init-config.ps1` | Interactive (default) or `-UseEnv` upstream wiring into `config.db` / CPA `api-keys` |
| `init_bifrost_config.py` | SQLite helper used by `init-config.ps1` |
| `pin-codex-lycorica-provider.ps1` | Re-pin lycorica `supports_websockets = false` trailer after Codex UI config rewrite; optional event-driven `-Watch` |
| `.env.example` | Template for `-UseEnv` only |
| `codex_openai_responses_request.go` | Full Responses **request** translator patch |
| `codex_openai_response.go` | Chat-completions response patch (PR #4079) |
| `Dockerfile.bifrost-patched` | Patched Bifrost image build recipe |
| `next_steps_plan.md` | Notes on Cursor custom-model routing experiments (not applied by install) |

## Caveats

- Without a backup upstream, models that only exist on the backup (for example spark-preview via centos) will not be routed.
- If `config.db` has no schema yet, start Bifrost once, then re-run `init-config.ps1`.
- Bifrost `main` moves faster than CPA tags - regex failures mean the kit needs a manual refresh.
- Full-file CPA patches can diverge from upstream if CLIProxyAPI refactors the Responses translators; merge carefully on version bumps.
