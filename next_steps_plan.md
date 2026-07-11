# Cursor Custom Model Routing Notes

## Goal

Investigate whether Cursor custom models can inherit native model parameter behavior such as reasoning effort, thinking, fast mode, and context presets, and determine practical ways to route native-looking selections to a custom provider.

## Environment

- Host OS: macOS
- Cursor user state path: `/Users/a/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
- Main state key examined:
  - `ItemTable -> src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser`

## Custom Models Involved

The following user-added models were identified in Cursor local state:

- `gpt-5.3-codex-spark`
- `muskapi/claude-sonnet-5`
- `muskapi/claude-fable-5`
- `muskapi/claude-opus-4-8`

These entries were found in Cursor's application-level reactive storage JSON and each had `isUserAdded: true`.

## Initial Findings

### 1. Where custom model names are stored

Custom model names are not stored in the normal user `settings.json`.

They are stored inside the SQLite database:

- `/Users/a/Library/Application Support/Cursor/User/globalStorage/state.vscdb`

Specifically inside:

- `ItemTable`
- key: `src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser`

### 2. Shape of the custom model entries before modification

Initially, the custom models were very thin entries. They looked roughly like this:

- `parameterDefinitions: []`
- `variants: []`
- `legacySlugs: []`
- `idAliases: []`
- `cloudAgentEffortModes: []`
- `isUserAdded: true`

This means Cursor recognized them as user-added named models, but not as native parameterized models.

### 3. Native models contain much richer metadata

Native models such as:

- `gpt-5.3-codex`
- `claude-sonnet-5`
- `claude-fable-5`
- `claude-opus-4-8`

contain much richer structures, including:

- `parameterDefinitions`
- `variants`
- `legacySlugs`
- `tooltipData`
- `tooltipDataForMaxMode`
- `clientDisplayName`
- `vendor` / `vendorName`
- feature flags such as `supportsThinking`, `supportsMaxMode`, `supportsPlanMode`, etc.

## Modifications Performed

### 1. Full database safety backup created

A manual SQLite backup was created before more invasive experiments.

Backup set:

- `state.vscdb.backup.before-custom-model-field-clone-1783715940`
- `state.vscdb.backup.before-custom-model-field-clone-1783715940-wal`
- `state.vscdb.backup.before-custom-model-field-clone-1783715940-shm`

This includes the WAL and SHM files because the database is using WAL mode.

### 2. Experiment: clone native model metadata into custom entries

The following native-to-custom field cloning was performed:

- `gpt-5.3-codex` -> `gpt-5.3-codex-spark`
- `claude-sonnet-5` -> `muskapi/claude-sonnet-5`
- `claude-fable-5` -> `muskapi/claude-fable-5`
- `claude-opus-4-8` -> `muskapi/claude-opus-4-8`

The unique custom names were intentionally preserved:

- `name`
- `serverModelName`
- `inputboxShortModelName`

Core native parameter metadata was copied over, including variants and parameter definitions.

### 3. Observation after cloning metadata

Although the JSON in `applicationUser` clearly reflected the copied native structures, Cursor UI behavior did not visibly start treating the custom models as fully native in the expected way.

This suggested that:

- UI registration metadata alone is not sufficient
- or Cursor uses additional internal mappings and runtime logic when resolving model identities and providers

### 4. Experiment: hijack native Sonnet 5 route by changing serverModelName

A smaller experiment was then performed on the native model entry itself:

- native `claude-sonnet-5`
- only `serverModelName` was changed to `muskapi/claude-sonnet-5`

Everything else about the native model entry was left untouched:

- native `name`
- native parameter definitions
- native variants
- native effort/thinking/context behavior metadata

The hypothesis was:

- the UI would still expose native Sonnet 5
- but the actual runtime route would point to the custom model line

## Runtime Result of Native Sonnet Hijack

Testing produced a provider error:

```json
{
  "is_bifrost_error": false,
  "error": {
    "message": "could not auto resolve a provider for the request, please specify a provider explicitly"
  },
  "extra_fields": {
    "routing_info": {},
    "original_model_requested": "claude-sonnet-5-thinking-high",
    "resolved_model_used": "claude-sonnet-5-thinking-high",
    "request_type": "responses_stream"
  }
}
```

The same kind of failure also occurred for other effort levels such as low.

## Important Discoveries from the Error

### 1. Cursor does not route only by top-level serverModelName

The runtime request showed that Cursor internally resolved the selected native Sonnet variant into a flattened internal slug:

- `claude-sonnet-5-thinking-high`

rather than using the top-level custom name directly.

This implies that changing the top-level `serverModelName` alone is not sufficient.

### 2. Cursor has a deeper model resolution path

There appears to be a multi-step process:

1. Native model registration metadata
2. Variant or parameter resolution
3. Flattening into an internal runtime model identifier
4. Provider resolution/routing

The failing runtime model ID was still the native internal style ID, not the custom provider model name.

### 3. The effective runtime identifier is likely derived from variant data

Based on the observed runtime slug and the native metadata format, the effective model may be derived from one or more of the following:

- `legacySlug`
- `variantStringRepresentation`
- internal parameterized model resolution logic
- internal model/provider catalog mappings not yet modified

### 4. Native-looking custom names are likely fighting Cursor alias logic

There is now strong evidence that names like:

- `claude-*`
- `gpt-*`

trigger Cursor's internal catalog/alias/provider resolution paths.

This matches community reports that custom BYOK model names colliding with Cursor's native catalog often get remapped or rejected in unexpected ways.

## Practical Interpretation

At this point, the project split into two possible strategies.

### Strategy A: continue deeper local-state hijacking inside Cursor

This would mean discovering and overriding all fields and internal mappings involved in converting a selected native model variant into the final runtime slug and provider route.

This path is possible in theory, but increasingly risky and brittle because:

- multiple resolution layers are involved
- internal runtime IDs do not seem to come solely from the edited top-level JSON entry
- future Cursor updates may easily break the hack

### Strategy B: accept Cursor's internal runtime slugs and translate them externally

This is currently the most promising direction.

Instead of forcing Cursor to emit the custom provider's preferred model names, the external forwarding/proxy layer can accept Cursor's internal model IDs such as:

- `claude-sonnet-5-thinking-low`
- `claude-sonnet-5-thinking-medium`
- `claude-sonnet-5-thinking-high`
- `claude-sonnet-5-thinking-xhigh`
- `claude-sonnet-5-thinking-max`
- plus non-thinking variants

and map them into whatever the external API provider expects.

## Current Proposal

### Core idea

Do not keep fighting Cursor's internal model resolution.

Instead:

1. Let Cursor emit its own native internal model slugs
2. In the external forwarding layer, parse those slugs into structured semantics
3. Translate them into the custom provider's accepted language

### Example semantic parse

Input from Cursor:

- `claude-sonnet-5-thinking-high`

Parse into:

```json
{
  "base_model": "claude-sonnet-5",
  "thinking": true,
  "effort": "high"
}
```

Then translate into provider-specific output, for example:

- model: `muskapi/claude-sonnet-5`
- plus optional provider-specific effort / reasoning fields if supported

### Why this is preferable

- Avoids deeper corruption of Cursor local state
- Preserves native picker UX inside Cursor
- Keeps logic in a controllable external layer
- Makes the system easier to maintain across Cursor updates
- Matches known community workaround patterns where neutral or translated names are handled by a proxy

## Expected mapping scope

For `claude-sonnet-5`, ignoring context for the moment, the core mapping space is likely 10 combinations:

- low
- medium
- high
- xhigh
- max

crossed with:

- thinking=false
- thinking=true

For Opus, if `fast` is included, the mapping space becomes larger.

The current recommendation is to start with Sonnet only because it is the cheapest and simplest validation target.

## Recommended Next Step

Do not continue editing Cursor local state until the external translator design is settled.

Instead, design the external router to:

- recognize Cursor internal model slugs
- parse model family + effort + thinking + fast
- rewrite them into provider-compatible requests

Only after that should more implementation work resume.

## Files/State Touched So Far

- Read and modified:
  - `/Users/a/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
- Read for confirmation:
  - `/Users/a/Library/Application Support/Cursor/User/globalStorage/storage.json`
  - `/Users/a/Library/Application Support/Cursor/User/settings.json`
  - `/Users/a/Library/Application Support/Cursor/User/workspaceStorage/*/workspace.json`
- Backup created:
  - `state.vscdb.backup.before-custom-model-field-clone-1783715940`
  - `state.vscdb.backup.before-custom-model-field-clone-1783715940-wal`
  - `state.vscdb.backup.before-custom-model-field-clone-1783715940-shm`

## Status

Current status: investigation complete for this phase.

Main conclusion:

- Cursor internal runtime model resolution is stronger than local top-level metadata edits
- external translation is the most practical next proposal
