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

- `PRIMARY_MODELS` are routed to the primary OpenAI-compatible upstream (`muskapi` by default), with optional backup fallback when backup is configured. Claude models are **not** listed here — see below.
- `CPA_MODELS` are routed directly to CPA/OAuth. They do **not** fall back to the primary or backup upstream after CPA capacity, quota, or account availability is exhausted; CPA will return an error instead.
- Claude models (`ANTHROPIC_MODEL_CEL = "model.startsWith('claude-')"`) are routed as a single wildcard rule to a second, native-Anthropic provider (`muskapi-anthropic`) instead of being enumerated in `PRIMARY_MODELS` — required for prompt caching to work at all; see "Claude prompt caching" below. `routing_targets.model` is left `NULL` for this rule, so any current or future Claude model name forwards through unchanged with no code change needed.

Use `CPA_MODELS` for models where downstream fallback is known to behave incorrectly, has unacceptable performance, or may cause unexpected billing. Users should review this tradeoff and configure their own routing and fallback policy for their provider/account mix.

You can run config alone:

```powershell
.\init-config.ps1
.\init-config.ps1 -DefaultEndpoint
```

## What each patch does

### CPA - Responses request (`codex_openai_responses_request.go`)

Copied wholesale into `internal/translator/codex/openai/responses/codex_openai-responses_request.go`.

- `sanitizeCodexResponsesInputItems` - `system` -> `developer` on messages; preserve the legacy broad non-message `role` cleanup for known older Codex models; keep `additional_tools.role` for newer models such as `gpt-5.6-*`; normalize nested `additional_tools.tools` descriptors to Responses tool schema; normalize `text`/`output_text` -> `input_text` and `image_url` -> `input_image` on `function_call_output`.
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
- Claude Cursor requests receive up to 4 `cache_control: {"type":"ephemeral"}` breakpoints (Anthropic's per-request max), all message-level, when the client did not provide an explicit cache policy: a stable anchor (system/developer message, or the first message when Cursor sends none — see below), the absolute last message, the absolute second-to-last message, and the second-to-last *user*-role message. No tool-level breakpoint is set. See "Claude prompt caching" below and `docs/major_fix/` for the full investigation and why each of these is needed.

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

### Claude prompt caching

For a Claude model routed through Bifrost, send the same conversation prefix at least twice (same tools, same first message) and inspect `logs.db` / the response `usage`. A positive `cached_read_tokens` (or `prompt_tokens_details.cached_read_tokens` in muskapi's shape) on the second request confirms the upstream accepted and reused the cached prefix. The full end-to-end investigation — routing, breakpoint placement, and the multi-turn/tool-loop accumulation fix — lives in `docs/major_fix/`; summary of what had to be right, in the order it was found:

1. **Route Claude models through a `base_provider_type: anthropic` custom provider, not `openai`.** Bifrost's own OpenAI-format request marshaler (`core/providers/openai/types.go`, `OpenAIChatRequest.MarshalJSON`) strips `cache_control` from every tool and message unless the Bifrost provider is literally `openrouter`. If the Claude upstream is only reachable in OpenAI-Chat-Completions shape, `cache_control` never leaves Bifrost at all. If it also exposes a native `/v1/messages` endpoint (common for Claude-specific proxies — what `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` point at for Claude Code), register it as a **second** Bifrost provider with `base_provider_type: anthropic` and route Claude models to it. Cursor keeps talking to Bifrost's single OpenAI-compatible endpoint exactly as before; only Bifrost's internal routing changes. `init_bifrost_config.py` does this automatically (`muskapi-anthropic` provider, wildcard `model.startsWith('claude-')` route with `routing_targets.model = NULL` so it forwards any current or future Claude model name unchanged — no per-model enumeration needed).
2. **The breakpoint needs to be on a message content block, not only on a tool.** A `cache_control` that appears *only* on a tool produced **zero** cache activity on a production upstream (`api.muskapi.cc`) — not just zero reads, zero `cache_creation_input_tokens` too, i.e. no checkpoint was created at all. A message-level breakpoint alone (no tool breakpoint) cached correctly *and* covered the tools, because Anthropic's cache_control breakpoints cover everything earlier in the request's fixed content ordering (tools, then system, then messages). `addCursorClaudeToolCacheBreakpoint` therefore never marks a tool directly (despite the name); all breakpoints are message-level.
3. **Cursor doesn't send a dedicated system message.** Production Cursor traffic folds all context (including what would normally be a system prompt) into the first message, which is `role: "user"`. The stable-anchor breakpoint falls back to the first message when no `system`/`developer` message is present.
4. **A single trailing breakpoint doesn't let the cache grow with the conversation.** Anchoring the only breakpoint on the first message means every later turn only ever re-reads that same fixed prefix — everything appended after it (growing conversation history, and especially a Cursor tool-calling loop *within* one turn: assistant tool_call → tool_result → tool_call → ...) is recomputed at full price on every single request and never itself gets cached. Fixed-index "last N messages" doesn't fix this either, because Cursor appends a variable number of items per turn (assistant reply + new user query across a turn boundary; one tool_call or tool_result at a time within a tool loop) and a fixed window drifts out of alignment with wherever the previous request actually wrote its cache entry. The working scheme uses all 4 of Anthropic's allowed breakpoints: the stable anchor, the absolute last message, the absolute second-to-last message (the pair realigns turn-over-turn *within* a tool loop, where exactly one item is typically appended per request), and the second-to-last *user*-role message (realigns *across* a full turn boundary, where more than 1-2 items get appended at once). Confirmed against production traffic: `cached_read_tokens` on each turn exactly matches the previous turn's total, growing turn over turn instead of resetting.
5. **Ephemeral cache writes take time to become readable.** Requests sent faster than roughly 15-30s apart may miss a cache that was written moments earlier even with correct breakpoint placement — this is upstream propagation latency, not a placement bug. Real Cursor usage (human typing/reading pace) is comfortably slower than this in practice.

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

Do **not** mark the whole `config.toml` read-only, and do **not** run a poll/watch loop on the file. Both are worse than the problem: read-only blocks model changes; a resident watcher is unnecessary complexity.

**Simple fix:** put the provider pin in Codex's managed layer. On Windows that file is `~/.codex/managed_config.toml`. It merges **on top of** user `config.toml`, so the UI can keep rewriting model/effort in the user file while the HTTP-only provider survives:

```powershell
cd C:\CLIProxyAPI\patches\cursor-cpa-connector
.\pin-codex-lycorica-provider.ps1
# optional: also strip openai_base_url / duplicate provider bits from user config.toml
.\pin-codex-lycorica-provider.ps1 -AlsoCleanUserConfig
```

That writes (only) this managed trailer:

```toml
model_provider = "lycorica"

[model_providers.lycorica]
name = "lycorica"
base_url = "https://cursor.lycorica.com/cursor/v1"
wire_api = "responses"
supports_websockets = false
```

Restart Codex / reload the extension once after creating or changing `managed_config.toml`. Override `-ProviderId` / `-BaseUrl` if your edge name differs.

## Files

| Path | Role |
|------|------|
| `install-cursor-cpa-bifrost-patches.ps1` | Clone/patch/build CPA and Bifrost; optional `-InitConfig` |
| `init-config.ps1` | Interactive (default) or `-UseEnv` upstream wiring into `config.db` / CPA `api-keys` |
| `init_bifrost_config.py` | SQLite helper used by `init-config.ps1` |
| `pin-codex-lycorica-provider.ps1` | Write lycorica `supports_websockets = false` into `~/.codex/managed_config.toml` (survives UI rewrites of `config.toml`) |
| `.env.example` | Template for `-UseEnv` only |
| `codex_openai_responses_request.go` | Full Responses **request** translator patch |
| `codex_openai_response.go` | Chat-completions response patch (PR #4079) |
| `Dockerfile.bifrost-patched` | Patched Bifrost image build recipe |
| `Dockerfile.cpa-patched` | Patched CPA image build recipe (Linux binary, same patched source as the `.exe`) |
| `build-patched-cpa.ps1` | Windows/PowerShell: patch + test + build CPA `.exe` and native debug binary, then build `cpa-patched:local` and redeploy the `cpa` container (`--restart unless-stopped`) |
| `build-patched-cpa.sh` | bash equivalent of the above (git-bash or real Linux/macOS); paths overridable via `CPA_SRC` / `CPA_PROJECT_DIR` / etc. env vars |
| `config.docker.yaml.example` | Sanitized template for the CPA config the `cpa` container reads (`auth-dir` rewritten to the container path); copy to `config.docker.yaml` (gitignored) and fill in real `api-keys` / `remote-management.secret-key` |
| `next_steps_plan.md` | Notes on Cursor custom-model routing experiments (not applied by install) |

## Caveats

- Without a backup upstream, models that only exist on the backup (for example spark-preview via centos) will not be routed.
- If `config.db` has no schema yet, start Bifrost once, then re-run `init-config.ps1`.
- Bifrost `main` moves faster than CPA tags - regex failures mean the kit needs a manual refresh.
- Full-file CPA patches can diverge from upstream if CLIProxyAPI refactors the Responses translators; merge carefully on version bumps.
