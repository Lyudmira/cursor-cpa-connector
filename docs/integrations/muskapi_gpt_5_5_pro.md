# MuskAPI GPT-5.5 Pro Integration Through Bifrost

## Purpose

This document describes how the deployment exposes a Cursor-safe logical model name, routes it through a dedicated Anthropic-compatible Bifrost provider, and forwards the upstream wire identifier `gpt-5.5-pro` to MuskAPI's Messages API.

The configured Cursor model name is:

```text
muskapi-pro/gpt-5-5-pro
```

The hyphenated logical leaf `gpt-5-5-pro` is intentional. Cursor applies built-in GPT-5.5 handling to custom names containing the literal `gpt-5.5` substring. Using a distinct logical identifier prevents Cursor from normalizing the selection to its built-in `gpt-5.5` catalog entry before the request reaches Bifrost.

## Original routing problem

Cursor's built-in GPT-5.5 variants use one base API model ID:

```text
gpt-5.5
```

UI options such as High or Extra High modify reasoning/context parameters; they do not select the independent `gpt-5.5-pro` SKU. Earlier requests reached Bifrost as `gpt-5.5`, were eligible for the existing CPA/model-catalog routes, and could fall back to providers that also served standard GPT-5.5.

Adding `gpt-5.5-pro` to an OpenAI-style provider allowlist would not solve this. The successful LobeHub experiment established a different protocol requirement:

```text
POST https://api.muskapi.cc/v1/messages
model = gpt-5.5-pro
```

MuskAPI accepts that identifier through its Anthropic-compatible Messages endpoint even though model discovery behavior may differ from invocation behavior.

## Architecture

```text
Cursor custom model
  muskapi-pro/gpt-5-5-pro
        |
        v
edge nginx
  /cursor/v1/responses -> Bifrost /v1/responses
  /cursor/chat/completions -> Bifrost Cursor integration
        |
        v
Bifrost provider selection
  explicit provider = muskapi-pro
  logical model = gpt-5-5-pro
        |
        v
key-level alias resolution
  gpt-5-5-pro -> gpt-5.5-pro
        |
        v
Anthropic provider adapter
  OpenAI Responses/Chat -> Anthropic Messages
        |
        v
MuskAPI
  POST https://api.muskapi.cc/v1/messages
  model = gpt-5.5-pro
```

The explicit `provider/model` prefix prevents model-catalog ambiguity. No governance fallback rule is attached to this logical model.

## Provider configuration

A dedicated custom provider named `muskapi-pro` was created in Bifrost with these relevant properties:

```json
{
  "name": "muskapi-pro",
  "network_config": {
    "base_url": "https://api.muskapi.cc",
    "default_request_timeout_in_seconds": 60,
    "max_retries": 1
  },
  "custom_provider_config": {
    "base_provider_type": "anthropic",
    "allowed_requests": {
      "list_models": true,
      "chat_completion": true,
      "chat_completion_stream": true,
      "responses": true,
      "responses_stream": true
    }
  }
}
```

`base_provider_type: anthropic` is the critical setting. Bifrost reuses its standard Anthropic provider implementation, which:

- builds the upstream `/v1/messages` URL;
- sends `x-api-key` and `anthropic-version: 2023-06-01`;
- converts OpenAI Chat/Responses messages, tools, system instructions, and streaming events into Anthropic Messages format;
- converts the Anthropic response stream back to the protocol expected by Cursor.

No new Go protocol adapter or custom container image was required.

## Dedicated key and alias

The provider has one enabled key restricted to the logical model:

```json
{
  "name": "muskapi-pro-key-1",
  "models": ["gpt-5-5-pro"],
  "aliases": {
    "gpt-5-5-pro": {
      "model_id": "gpt-5.5-pro",
      "model_name": "gpt-5.5-pro",
      "model_family": "anthropic",
      "description": "MuskAPI GPT-5.5 Pro over Anthropic Messages API"
    }
  },
  "enabled": true,
  "weight": 1
}
```

The fields have separate roles:

| Field | Meaning |
| --- | --- |
| Alias key `gpt-5-5-pro` | Model identifier sent by Cursor after Bifrost removes the provider prefix |
| `model_id: gpt-5.5-pro` | Wire identifier forwarded to MuskAPI |
| `model_name: gpt-5.5-pro` | Canonical model name used in routing metadata and pricing lookup |
| `model_family: anthropic` | Forces Anthropic-family request/response handling for the alias |

The allowlist contains only `gpt-5-5-pro`; the dedicated key cannot serve ordinary `gpt-5.5` through this provider.

## Fallback policy

The Pro route is fail-closed at the provider-selection level:

- no routing rule rewrites `gpt-5-5-pro`;
- no fallback points to CPA, the OpenAI-compatible `muskapi` provider, `newapi`, or standard `gpt-5.5`;
- an upstream failure is returned to the caller instead of silently changing the billed model class.

Bifrost's provider network configuration still permits one retry against the same provider/key. That retry does not change provider or model.

## Implementation and deployment method

The production configuration was changed in the Bifrost SQLite configuration store. Before production application, the same change was tested in an isolated Bifrost instance on `127.0.0.1:8083` using a copied configuration database. Port `8082` was left untouched.

A reusable configuration utility was created at:

```text
/home/lycorica/workspace/tmp/configure_bifrost_gpt55_pro.py
```

The utility:

1. clones the protocol/network settings of the existing Anthropic-compatible MuskAPI provider;
2. creates `muskapi-pro` if absent;
3. copies the existing credential value inside SQLite without printing the plaintext secret;
4. creates the strict logical-model allowlist and rich alias;
5. refuses to proceed if a conflicting routing rule already references `gpt-5-5-pro`;
6. is idempotent for the provider and key records.

Production `bifrost` was stopped only for the database update and restarted through a guarded exit path. The endpoint returned healthy after restart.

## Protocol validation

### OpenAI Responses path

An isolated streaming request was sent to:

```text
POST http://localhost:8083/v1/responses
model = muskapi-pro/gpt-5-5-pro
```

It returned HTTP 200 and `OK`. Bifrost's response metadata reported:

```text
provider:                 muskapi-pro
model:                    gpt-5-5-pro
resolved_key_alias.id:    gpt-5.5-pro
resolved_key_alias.name:  gpt-5.5-pro
resolved_key_alias.family: anthropic
original_model_requested: gpt-5-5-pro
resolved_model_used:      gpt-5.5-pro
```

The persisted request record showed:

```text
provider:             muskapi-pro
model:                gpt-5.5-pro
alias:                gpt-5-5-pro
canonical_model_name: gpt-5.5-pro
alias_model_family:   anthropic
fallback_index:       0
number_of_retries:    0
status:               success
selected_key_name:    muskapi-pro-key-1
child fallback rows:  0
```

### Cursor Chat-compatible path

The exact Cursor route shape was also tested:

```text
POST /cursor/chat/completions
model = muskapi-pro/gpt-5-5-pro
```

Bifrost returned a valid Chat Completions SSE stream:

```text
model: gpt-5.5-pro
content delta: OK
finish_reason: stop
```

This confirms that both Cursor protocol entry points reach the dedicated provider and that the key alias is resolved before the Anthropic upstream call.

## Production verification

The production management API currently reports:

```text
provider: muskapi-pro
base provider type: anthropic
base URL: https://api.muskapi.cc
key: muskapi-pro-key-1
allowed models: [gpt-5-5-pro]
alias: gpt-5-5-pro -> gpt-5.5-pro
key status: success
```

The `muskapi-pro` records survived the subsequent SQLite database repair unchanged.

## What this proves

Local evidence proves all of the following:

1. Cursor can address the route using `muskapi-pro/gpt-5-5-pro` without triggering the built-in `gpt-5.5` name path.
2. Bifrost deterministically selects `muskapi-pro`.
3. Bifrost converts Cursor's OpenAI-compatible request to Anthropic Messages.
4. The wire model sent by Bifrost is `gpt-5.5-pro`.
5. MuskAPI accepts the request and returns a successful response whose model field is `gpt-5.5-pro`.
6. Bifrost does not create a standard-model fallback for the request.

## Billing and model-identity limitation

The integration cannot independently prove which physical MuskAPI backend or billing SKU serves the accepted alias. A gateway can accept and echo `gpt-5.5-pro` while internally mapping it to another channel. Model self-identification in generated text is also unreliable because Cursor supplies model/persona instructions in the system prompt.

Therefore:

- Bifrost routing metadata proves the identifier sent to MuskAPI.
- MuskAPI's account-side request record and billing line prove the SKU actually charged.
- LobeHub's locally calculated `$180/M` output cost is a model-bank estimate, not evidence of MuskAPI billing.

When auditing a charge, correlate the Bifrost request time or upstream `X-Request-Id` with MuskAPI's billing record. If MuskAPI labels that request as standard `gpt-5.5`, the provider is internally mapping the Pro wire identifier and a different upstream channel/model ID is required; changing the Bifrost alias alone cannot override such a provider-side mapping.

## Usage

Configure the Cursor custom model exactly as:

```text
muskapi-pro/gpt-5-5-pro
```

Do not use these alternatives:

```text
gpt-5.5-pro                 # may trigger Cursor's built-in GPT-5.5 handling
gpt-5-5-pro                 # leaves provider selection to the catalog
muskapi-pro/gpt-5.5-pro     # retains the risky literal gpt-5.5 substring
```

For verification, inspect Bifrost structured logs for:

```text
provider = muskapi-pro
alias = gpt-5-5-pro
model = gpt-5.5-pro
fallback_index = 0
status = success
```

Then correlate the request with MuskAPI's account-side billing record before asserting that the physical Pro SKU was used.

## Rollback

To disable the integration without changing existing providers:

1. disable or delete `muskapi-pro-key-1`;
2. remove the `muskapi-pro` custom provider after confirming no active requests reference it;
3. remove the custom model from Cursor;
4. leave the existing `muskapi-anthropic`, `muskapi`, CPA, and NewAPI providers unchanged.

The pre-change production configuration backup is stored under:

```text
C:\bifrost\backups\before-gpt55-pro-20260721-230135
```
