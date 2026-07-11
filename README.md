# Cursor CPA Connector

Cursor's Codex-mode client sends Responses API history and tool payloads in a shape that is looser than what upstream Codex and Bifrost's schema layer expect. Failure modes we patch for:

1. **Input history** — Cursor attaches `role` to non-`message` items (`function_call`, `function_call_output`, …) and uses `output[].type: "text"` where Codex expects `input_text`.
2. **Tool schemas through Bifrost** — nested `function.name` / `function.parameters` and flat `input_schema` get dropped; `strict: null` is emitted when Cursor omits `strict`.

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

1. **Primary** — normal GPT + Anthropic traffic (you must enter Base URL unless you also pass `-DefaultEndpoint`, which allows Enter to use `https://api.muskapi.cc/v1`)
2. **Backup** (optional) — models the primary does not offer, and failover if primary fails. **Press Enter on the backup Base URL to skip** if you do not have a backup.

Suggested backup URL if you want one: `https://ai.centos.hk/v1` (paste it; Enter alone still means skip).

You can run config alone:

```powershell
.\init-config.ps1
.\init-config.ps1 -DefaultEndpoint
```

## What each patch does

### CPA — Responses request (`codex_openai_responses_request.go`)

Copied wholesale into `internal/translator/codex/openai/responses/codex_openai-responses_request.go`.

- `sanitizeCodexResponsesInputItems` — `system` → `developer` on messages; strip `role` from non-message items; `text`/`output_text` → `input_text` on `function_call_output`.
- `removeUnsupportedCursorCustomToolsForCodexBYOK` — drop Cursor `ApplyPatch` custom tool on BYOK routes.
- `addCodexBYOKToolCompatibilityInstruction` — optional instruction when Shell is present without ApplyPatch.
- `normalizeCodexBuiltinTools` — e.g. `web_search_preview` → `web_search`.
- `applyResponsesCompactionCompatibility` — Codex `/responses` compaction compatibility.

### CPA — Chat-completions response (`codex_openai_response.go`)

Dropped in wholesale from CLIProxyAPI PR #4079 into `internal/translator/codex/openai/chat-completions/codex_openai_response.go`. Adds `custom_tool_call` handling on the chat-completions translation path.

### Bifrost (`core/schemas/responses.go`)

Regex patch on `core/schemas/responses.go` (via the install script):

- `ResponsesToolTypeFunction`: fallback to `raw["function"]` and `raw["input_schema"]`.
- `Strict *bool` json tag gets `omitempty`.

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

- Missing `PRIMARY_BASE_URL` / `BACKUP_BASE_URL` fields → built-in defaults (`muskapi` / `ai.centos.hk`)
- Empty or omitted `BACKUP_API_KEY` → **skip backup**
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

## Troubleshooting: Codex WebSocket to `/v1/responses`

This kit’s CPA Responses patch fixes **HTTP** request-body compatibility (roles, `input_text`, tools, compaction). It does **not** implement Codex’s WebSocket Responses transport.

If Codex (or a Codex-shaped client) errors while opening a WebSocket against your Bifrost/CPA endpoint, for example:

```text
failed to connect to websocket:
HTTP error: 400 Bad Request
wss://…/v1/responses
```

the client is trying to use WebSockets. Point it at HTTP Responses instead by disabling WebSockets on that provider in Codex config (`~/.codex/config.toml` or equivalent):

```toml
[model_providers.xxx]
name = "xxx"
base_url = "https://xxx/v1"
wire_api = "responses"
supports_websockets = false
```

Replace `xxx` / `base_url` with your Bifrost (or edge) URL. With `supports_websockets = false`, Codex uses ordinary HTTP `POST /v1/responses`, which is what this kit patches for.

## Files

| Path | Role |
|------|------|
| `install-cursor-cpa-bifrost-patches.ps1` | Clone/patch/build CPA and Bifrost; optional `-InitConfig` |
| `init-config.ps1` | Interactive (default) or `-UseEnv` upstream wiring into `config.db` / CPA `api-keys` |
| `init_bifrost_config.py` | SQLite helper used by `init-config.ps1` |
| `.env.example` | Template for `-UseEnv` only |
| `codex_openai_responses_request.go` | Full Responses **request** translator patch |
| `codex_openai_response.go` | Chat-completions response patch (PR #4079) |
| `Dockerfile.bifrost-patched` | Patched Bifrost image build recipe |
| `next_steps_plan.md` | Notes on Cursor custom-model routing experiments (not applied by install) |

## Caveats

- Without a backup upstream, models that only exist on the backup (for example spark-preview via centos) will not be routed.
- If `config.db` has no schema yet, start Bifrost once, then re-run `init-config.ps1`.
- Bifrost `main` moves faster than CPA tags — regex failures mean the kit needs a manual refresh.
- Full-file CPA patches can diverge from upstream if CLIProxyAPI refactors the Responses translators; merge carefully on version bumps.
