# Model Routing Field Classification

This document classifies every read of `provider` and `model` fields in the turn execution path to identify which are pure routing decisions versus those that embed vendor-specific or authentication concerns.

## Classification System

- **A (Pure Routing)**: Routing decision only; no credential/auth/control-plane coupling
- **B (Cred/Auth/Control-Plane)**: Embedded credential, auth, account, or billing concerns; remains at compatibility layer
- **C (Legacy Semantics)**: Legacy vendor-response/replay semantics; left unchanged for now
- **D (Mixed)**: Coupling of routing + auth/telemetry/legacy that cannot be cleanly split in this PR
- **Test**: Test-only code; not part of production execution

## Field Reads in Turn Execution Path

| Location | Line | Field | Use | Classification | Rationale | Included in ModelRoute? |
|----------|------|-------|-----|-----------------|-----------|------------------------|
| orchestrator.zig | 5368 | job.model | Trace logging for turn start | A | Pure routing information for debugging | Yes |
| orchestrator.zig | 5372 | job.model | Query available model capabilities | A | Pure routing—capabilities lookup has no auth coupling | Yes |
| orchestrator.zig | 5381 | job.model | Resolve model capabilities | A | Pure routing—capability resolution is neutral | Yes |
| orchestrator.zig | 5534 | job.provider, job.model | Create ProviderSelection for empty history replay | A | Pure routing—ProviderSelection is neutral identity | Yes |
| orchestrator.zig | 6073 | job.model | TEST: Set fixture model | Test | Test setup only | — |
| orchestrator.zig | 6191 | job.model | TEST: Set fixture model | Test | Test setup only | — |
| orchestrator.zig | 6553 | job.provider | Check if recovery selection changed | A | Pure routing—comparing routing identity, not auth | Yes |
| orchestrator.zig | 6554 | job.model | Check if recovery selection changed | A | Pure routing—comparing routing identity, not auth | Yes |
| orchestrator.zig | 6737 | job.model | Initialize gateway_model variable | A | Pure routing—local variable for model being used | Yes |
| orchestrator.zig | 6761 | job.model | Update gateway_model in recovery | A | Pure routing—select which model to route to | Yes |
| orchestrator.zig | 6873 | job.provider, job.model | Create ProviderSelection for replay | A | Pure routing—ProviderSelection is neutral identity | Yes |
| orchestrator.zig | 6923 | job.provider, job.model | Create ProviderSelection in tool call | A | Pure routing—ProviderSelection is neutral identity | Yes |
| orchestrator.zig | 6931 | job.provider, job.model | Create ProviderSelection for response | A | Pure routing—ProviderSelection is neutral identity | Yes |
| orchestrator.zig | 6986 | job.provider, job.model | Resolve ultrafast provider options | A | Pure routing—capability resolution for execution options | Yes |
| orchestrator.zig | 7115 | job.provider | Create ProviderSelection in retry | A | Pure routing—ProviderSelection is neutral identity | Yes |
| orchestrator.zig | 7176 | job.provider, job.model | Create ProviderSelection for retry replay | A | Pure routing—ProviderSelection is neutral identity | Yes |
| orchestrator.zig | 7234 | job.provider | Check if provider is gateway | A | Pure routing—determines capability or behavior path | Yes |
| orchestrator.zig | 7695 | job.provider, gateway_model | Push network record for telemetry | D | Mixed: routing + telemetry metric recording (kept at orchestrator level) | Yes (source only) |
| orchestrator.zig | 7728 | job.provider, gateway_model | Push network record for replay telemetry | D | Mixed: routing + telemetry metric recording (kept at orchestrator level) | Yes (source only) |
| orchestrator.zig | 7871 | job.provider, job.model | Create ProviderSelection in recovery | A | Pure routing—ProviderSelection is neutral identity | Yes |
| orchestrator.zig | 7879 | job.provider | Check if provider is gateway (retry decision) | A | Pure routing—determines retry strategy | Yes |
| orchestrator.zig | 7955 | job.model | Access model in update | A | Pure routing—reading routing identity | Yes |
| orchestrator.zig | 8200 | job.provider | Create ProviderSelection | A | Pure routing—ProviderSelection is neutral identity | Yes |
| orchestrator.zig | 8336 | job.model | Store model in recovery state | C | Legacy semantics—recovery checkpoint stores model for identity | Yes (for recovery authority) |
| orchestrator.zig | 8349 | job.model | Store model in interruption | C | Legacy semantics—interruption stores model for identity | Yes (for interruption authority) |
| orchestrator.zig | 8563 | job.model | Set selected_model in telemetry | D | Mixed: routing + telemetry (left at orchestrator) | Yes (source only) |
| orchestrator.zig | 8600 | job.provider, gateway_model | Create ProviderSelection for replay source | A | Pure routing—ProviderSelection is neutral identity | Yes |
| orchestrator.zig | 8670 | job.model | Access model in telemetry/logging | D | Mixed: routing + telemetry/logging (left at orchestrator) | Yes (source only) |
| orchestrator.zig | 9229 | job.provider | Check if provider != gateway (vision routing) | A | Pure routing—routing decision for vision fallback | Yes |
| gateway_step.zig | 72 | request.model | Record gateway call metric on error | D | Mixed: routing + telemetry (left at gateway layer) | Yes (source only) |
| gateway_step.zig | 82 | request.model | Record gateway result metric | D | Mixed: routing + telemetry (left at gateway layer) | Yes (source only) |

## Summary

### Pure Routing (A) — Candidates for Neutral ModelRoute
- Model capability queries and resolution (lines 5372, 5381)
- ProviderSelection creation for replay and tool execution (lines 5534, 6873, 6923, 6931, 6986, 7115, 7176, 7871, 8200, 8600)
- Recovery selection comparison (lines 6553-6554)
- Provider routing decisions (lines 7234, 7879, 9229)
- Local gateway_model variable management (lines 6737, 6761)
- Trace logging (line 5368)

**Action**: All A classification uses can operate on a neutral ModelRoute type.

### Mixed (D) — Keep at Orchestrator Level
- Telemetry/metrics recording: pushNetworkRecord, recordGatewayCallMetric, recordProviderResultMetric (lines 7695, 7728, 72, 82)
- Telemetry accumulation: selected_model tracking (line 8563)
- Debug logging: model output tracking (line 8670)

**Action**: Telemetry/metrics layer owns these; they use ModelRoute as data source without enforcement.

### Legacy Semantics (C) — Keep in Execution Authority
- Recovery checkpoint stores provider/model for identity (lines 8336, 8349)
- Used to reconstruct turn authority after interruption or recovery

**Action**: Recovery authority layer owns these; they use ModelRoute as source for checkpoint/interruption state.

## Neutral ModelRoute Design

The minimal type needed:

```zig
pub const ModelRoute = struct {
    /// Model identifier (e.g., "claude-opus-5-5", "gpt-4o", "ollama:mistral")
    model: []const u8,
    
    /// Provider identifier for routing (e.g., "gateway", "codex", "local-ollama")
    /// Only includes neutral routing names, not auth/control-plane identity
    provider: model_provider.ProviderId,
};
```

**Exclusions** (explicitly NOT included):
- `api_key` — authentication; remains at compatibility layer
- `credential_source` — auth provenance; remains at compatibility layer
- `account_id` — billing/authorization; remains at compatibility layer
- `gateway_team` — tenant/control-plane; remains at compatibility layer
- `permission_mode` — authorization policy; remains at compatibility layer

**Rationale**: ProviderSelection (provider + model string) already exists and serves this role.
ModelRoute adds no new type; it is simply ProviderSelection borrowed from TurnExecutionInput or passed separately.

## Projection Point

Projection occurs in `execution_compatibility.zig`:

```zig
pub fn neutralModelRoute(job: CompatibilityExecutionJob) ModelRoute {
    return .{
        .provider = job.provider,
        .model = job.model,
    };
}
```

- No allocations
- Borrows both fields
- Compatibility job retains all auth/credential/account/team state
- No copy or transformation

## Integration Points

1. **TurnExecutionInput** already carries provider and model (neutral fields)
2. **ProviderSelection** in orchestrator uses model_provider.ProviderId + model string
3. **Stream provider** already receives provider/model routing
4. **Recovery authority** reads from stored provider/model in checkpoint
5. **Telemetry** reads provider/model for metrics labels

## No Breaking Changes

All existing type and behavior remain:
- ModelProvider invocation unchanged
- Provider adapter dispatch unchanged
- Replay/history handling unchanged
- Recovery/checkpoint authority unchanged
- Telemetry/metrics unchanged
- Model capability lookups unchanged
