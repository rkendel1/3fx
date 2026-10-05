# Neutral Execution Boundary Architecture

**Document Status**: Complete architecture verification - all five seams established and verified

**Last Updated**: October 5, 2026

This document describes the complete neutral execution boundary that prevents credentials, accounts, billing state, and vendor control-plane objects from flowing through fx's core turn orchestration.

## Overview

The neutral execution boundary isolates three execution concerns:

1. **Workload** — neutral turn configuration and execution facts
2. **Routing** — model and provider selection (neutral)
3. **Credentials & Control-Plane** — authentication, account identity, billing (compatibility-only)

The boundary ensures that turn orchestration logic remains vendor-neutral and credential-free, while the compatibility layer maintains full control over authentication, billing, and account-specific decisions.

## Five Established Architectural Seams

### Seam 1: TurnExecutionInput (Neutral Turn Configuration)

**Location**: `src/core/agent/turn_execution_input.zig`

**Purpose**: Boundary between `CompatibilityExecutionJob` (host compatibility layer) and turn orchestration loop.

**Included** (Neutral Workload):
- turn_id, delivery (routing)
- prompt, images (user request)
- model, provider (configuration for routing, not auth)
- history (conversation context)
- grants, permissions (configuration)
- context_snapshot (workspace state)
- recovery_checkpoint (resume/recovery state)
- UI state flags (recovery_source_already_presented, user_prompt_already_presented)
- skill_bindings, settings, file_ownerships

**Excluded** (Compatibility-Only):
- api_key (authentication)
- credential_source (auth provenance)
- account_id (billing identity)
- gateway_team (tenant/control-plane)
- permission_mode (auth policy)

**Projection**: `execution_compatibility.turnExecutionInput(job)`
- No allocations
- Borrows all slices
- One-directional transformation

**Invariant**: TurnExecutionInput type definition forbids credential/auth/account/billing fields at compile time.

---

### Seam 2: ProviderSelection (Neutral Model Routing)

**Location**: `src/core/config/model_provider.zig`

**Type**:
```zig
pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
};
```

**Purpose**: Minimal routing information for capability queries, replay identity, recovery comparison.

**Contains**:
- provider (gateway, codex, grok, configured provider)
- model (model identifier)

**Does NOT Contain**:
- api_key, credential_source (authentication)
- account_id, gateway_team (billing/control-plane)
- permission_mode (policy)

**Projection**: `execution_compatibility.neutralModelRoute(job)`
- Borrows provider and model
- No allocations
- Used for capability resolution without credential coupling

**Usage**:
- Model capability queries
- Replay identity projection
- Recovery selection changes
- Routing decisions (gateway vs vendor)
- Telemetry labels

**Invariant**: ProviderSelection contains only routing identity, never credentials or account state.

---

### Seam 3: NeutralModelRequest (Neutral Model Execution Input)

**Location**: `src/core/agent/stream_provider.zig` (lines 220-264)

**Purpose**: Request boundary at the gateway layer. Consolidates model request construction around existing ModelProvider contract.

**Contains** (23 Workload Fields):
- model, instructions, messages (request content)
- tools, tool_choice (execution parameters)
- vision_mode, max_output_tokens (capabilities)
- provider_options (model execution config: temperature, reasoning_effort, etc.)
- response_format (structured output)
- trace_ctx (observability)
- deadline, cancel_flag (coordination)
- delivery, attempt_evidence (tracking)
- session_id, events (workload coordination)
- admission, cooperative_pulse (workload control)
- provider_attempt_owner (retry ownership)
- prepared_request_body, content_capture_limit (optimization)
- verified_images (workload payload)
- budget (execution deadline)

**Excluded**:
- credential (authentication)
- retry_count (injected at boundary)
- account_id, gateway_team, billing (control-plane)

**Projection Path**:
```
CompatibilityExecutionJob
    ↓
TurnExecutionInput + ProviderSelection
    ↓
NeutralModelRequest (constructed by orchestrator)
```

**Credential Injection**:
At `gateway_step.streamNeutralModelCompletion()`:
```
NeutralModelRequest + CredentialLease
    ↓
ModelRequest (credential injected)
    ↓
provider.stream()
```

**Invariant**: Credentials never enter the neutral request. Injection happens at explicit adapter boundary only.

---

### Seam 4: NeutralModelCompletion / NeutralFailure (Neutral Model Execution Result)

**Location**: `src/core/agent/stream_provider.zig` (lines 352-378)

**Purpose**: Response-side boundary. Prevents billing, routing, and control-plane metadata from flowing to turn orchestration.

#### NeutralModelCompletion

**Contains** (9 Execution/Opaque Fields):
- content: model output text
- tool_calls: invoked tools
- generation_id: provider ID for replay
- finish_reason: stop/length/content_filter/tool_calls
- usage: execution facts (input/output/cache/reasoning tokens)
- provider_failure_detail: vendor error message (troubleshooting)
- provider_state_json: **opaque provider-owned state** (never interpreted, passed through on retry)
- retry_after_seconds: HTTP retry hint

**Excludes**:
- resolved_provider, billing, service_tier (control-plane)
- generation_metadata_invalid, delivery_ambiguous (billing authority)
- provider_failure_cause (diagnostics)
- diagnostics (validation/schema state)

**Projection**:
```zig
pub fn neutralCompletion(self: Result) NeutralModelCompletion {
    // Borrows string references, no allocation
    // Returns neutral subset only
}
```

#### NeutralFailure

**Contains**:
- kind: FailureKind enum
- detail: error message
- retry_after_seconds: retry guidance

**Excludes**:
- diagnostics (schema, request_shape)

**Projection**:
```zig
pub fn neutralFailure(self: Result) NeutralFailure {
    // Borrows error info, excludes diagnostics
}
```

**Invariant**: Turn orchestrator never receives billing, routing, or diagnostics. provider_state_json is opaque blob for protocol continuation.

**Usage**:
- Recovery decisions use FailureKind (neutral), not provider_failure_cause
- Retry logic uses failure evidence (neutral), not diagnostics
- provider_state_json passed unchanged through recovery/retry

---

### Seam 5: Message/Completion/Tool/Replay Audit (Remaining Coupling)

**Location**: `docs/message-completion-boundary.md`

**Purpose**: Establishes where remaining coupling is correctly owned.

**Correct Ownership**:

1. **Streaming** — Already neutral (EventSink, Event enum)
   - No credentials in events
   - content_delta, reasoning_delta, tool_started, tool_input_delta
   - No billing/routing metadata

2. **Tool Calls** (mixed by necessity)
   - Execution facts: id, name, arguments_json, provenance
   - Protocol metadata: provisional_id, provider_result (needed for streaming/replay)
   - Authority: argument_integrity, resolved_skill
   - This is correct by necessity; not accidental

3. **Message History** (role-aware, mixed concerns)
   - User messages: content, images only
   - Assistant messages: content, tool_calls, provider_replay
   - Tool messages: tool_call_id, tool_name, tool_result_status, tool_result_memory
   - provider_replay is provider-owned protocol state; filtered by ProviderSelection

4. **Provider Replay**
   - Stored in ChatMessage.provider_replay
   - Provider-specific message wire format
   - Filtered when provider changes
   - Never interpreted by orchestrator

5. **Recovery Checkpoint**
   - Contains: assistant_source (partial content), tool_state (evidence), provider metadata
   - Does NOT contain: full model state (in history), billing, provider routing decisions

**Invariant**: Remaining coupling is owned by the correct layer (provider, permissions, streaming, persistence).

---

## Complete Request/Response Path

```
┌─ Host Layer ─────────────────────────────────┐
│ CompatibilityExecutionJob                    │
│ ├─ api_key (authentication)                  │
│ ├─ credential_source, account_id             │
│ ├─ gateway_team (control-plane)              │
│ ├─ permission_mode (policy)                  │
│ └─ neutral workload (everything else)        │
└──────────────────────────────────────────────┘
                     ↓
        execution_compatibility boundary
                     ↓
┌─ Neutral Turn Layer ──────────────────────────┐
│ TurnExecutionInput                            │
│ ├─ Workload: prompt, history, context        │
│ ├─ Configuration: model, provider, settings  │
│ └─ NO credentials, account, billing          │
└───────────────────────────────────────────────┘
                     ↓
        ProviderSelection (routing only)
                     ↓
┌─ Neutral Request Layer ────────────────────────┐
│ NeutralModelRequest                           │
│ ├─ model, messages, tools, options            │
│ ├─ trace, deadline, events, delivery         │
│ └─ NO credential                              │
└────────────────────────────────────────────────┘
                     ↓
    gateway_step.streamNeutralModelCompletion()
    (credential injection adapter)
                     ↓
┌─ Provider Request Layer ────────────────────────┐
│ ModelRequest                                  │
│ ├─ NeutralModelRequest fields                 │
│ └─ + credential (injected)                    │
└────────────────────────────────────────────────┘
                     ↓
        provider.stream()
                     ↓
┌─ Provider Result ───────────────────────────────┐
│ Result (completed | failed)                   │
│ ├─ ModelCompletion/Failure (full state)       │
│ ├─ billing, resolved_provider, service_tier  │
│ └─ provider_state_json (opaque)               │
└────────────────────────────────────────────────┘
                     ↓
       result.neutralCompletion()
       result.neutralFailure()
                     ↓
┌─ Neutral Result Layer ──────────────────────────┐
│ NeutralModelCompletion / NeutralFailure        │
│ ├─ content, tool_calls, usage, finish_reason  │
│ ├─ provider_state_json (opaque blob)          │
│ └─ NO billing, resolved_provider, diagnostics │
└────────────────────────────────────────────────┘
                     ↓
        Turn Orchestration
        (recovery, retry, history)
                     ↓
┌─ Message History ───────────────────────────────┐
│ ChatMessage (role-aware)                      │
│ ├─ content, tool_calls, images                │
│ ├─ provider_replay (filtered, opaque)         │
│ └─ tool_result_status, tool_result_memory     │
└────────────────────────────────────────────────┘
```

## Boundary Verification

### Type-Level Verification (Compile-Time)

Each neutral type's definition enforces what is absent:

```zig
// TurnExecutionInput cannot have api_key, credential, account_id, etc.
pub const TurnExecutionInput = struct { ... };

// ProviderSelection is minimal: only provider + model
pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
};

// NeutralModelRequest has no credential field
pub const NeutralModelRequest = struct { ... };

// NeutralModelCompletion has no billing/routing fields
pub const NeutralModelCompletion = struct { ... };
```

**Test Coverage**: `test "X contains no credential/account/billing fields"` verifies no forbidden field names appear.

### Runtime Verification

**Boundary Tests**:

1. **Credential Containment**
   - Test with sentinel value (e.g., "TEST_CRED_MARKER_")
   - Verify exists in CompatibilityExecutionJob
   - Verify NOT in TurnExecutionInput projection
   - Verify available through compatibility function
   - Verify injected at adapter boundary
   - Verify NOT in NeutralModelRequest

2. **Projection Fidelity**
   - Test workload fields preserved through all projections
   - Test model, provider routing preserved
   - Test history, context preserved
   - Test no unexpected allocations
   - Test borrowing (no copies)

3. **provider_state_json Opacity**
   - Test arbitrary JSON survives unchanged
   - Test byte-identical (same pointer)
   - Test passed through without interpretation

4. **Streaming Events**
   - Test content_delta, reasoning_delta
   - Test tool_started, tool_input_delta
   - Test no credentials in event content
   - Test no account/billing metadata

5. **Replay Ownership**
   - Test provider_replay is provider-owned
   - Test replay filtered by ProviderSelection
   - Test orchestrator never interprets replay

### Diagnostic Tool

```bash
scripts/check-model-provider-boundary.py
```

Reports:
- Current violation count (types/functions with coupling)
- Prior count (baseline)
- Delta
- Remaining categories
- Violations inside/outside neutral boundary

---

## Explicit Exclusions

These remain at the compatibility layer by design:

- **Authentication**: api_key, credential_source, auth state
- **Authorization**: permission_mode, policy decisions
- **Account Identity**: account_id, billing authority
- **Tenant/Control-Plane**: gateway_team, service tier decisions
- **Validation Metadata**: schema, request_shape diagnostics
- **Provider Routing Decisions**: resolved_provider, capability overrides

---

## Intentional Remaining Coupling

These seams are correctly owned outside the neutral boundary:

1. **Provider Replay** (provider-owned)
   - Message wire format for same-provider continuation
   - Stored in ChatMessage.provider_replay
   - Filtered by ProviderSelection
   - Never interpreted by orchestration

2. **Tool Streaming Metadata** (provider + protocol)
   - provisional_id (needed during streaming)
   - provider_result (for provider-native path)
   - final_identity (for replay validation)
   - These are necessary; not accidental

3. **Permission/Authority** (orthogonal concern)
   - argument_integrity, permission_feedback
   - resolved_skill binding
   - Separate validation layer

4. **Usage Tracking** (execution facts + deferred billing)
   - Usage fields are execution facts (neutral)
   - DeferredUsageReference kept in compatibility layer
   - Billing reconciliation at host

5. **Protocol Metadata** (provider-specific)
   - generation_id (for replay identity, neutral)
   - provider_state_json (opaque, neutral)
   - finish_reason (execution fact, neutral)

---

## Related Documents

1. **neutral-turn-execution-input.md** — TurnExecutionInput boundary detail
2. **neutral-model-routing.md** — ProviderSelection boundary detail
3. **neutral-model-request.md** — NeutralModelRequest boundary detail
4. **neutral-model-completion.md** — NeutralModelCompletion boundary detail
5. **message-completion-boundary.md** — Message/completion/tool ownership detail

---

## Migration Path (Future)

Current state establishes the pattern. Future work could extend to:

1. **Conversation Type Abstraction** — Message type as provider-neutral interface
2. **Completion/Tool-Result Contract Neutralization** — Separate neutral tool execution
3. **Provider Transport Envelope Abstraction** — Neutral transport metadata
4. **Usage/Billing Contract Redesign** — Full deferred accounting isolation

These are separate, larger efforts. This boundary demonstrates the pattern: extracting neutral data at architectural seams without dragging provider/control-plane coupling across them.

---

## Success Criteria

✓ TurnExecutionInput excludes all auth/account/billing fields (compile-time + tests)
✓ ProviderSelection contains only routing identity
✓ NeutralModelRequest excludes credential field (compile-time + tests)
✓ NeutralModelCompletion excludes billing/routing (compile-time + tests)
✓ Credential injection at explicit adapter boundary only
✓ provider_state_json preserved opaque through recovery
✓ Streaming events workload-only (no credentials)
✓ Replay remains provider-owned
✓ Projection fidelity preserved (workload fields unchanged)
✓ No unexpected allocations across boundary
✓ Boundary diagnostic identifies all violations inside/outside

---

## Summary

The neutral execution boundary consists of five established seams:

| Seam | Input | Output | Purpose |
|------|-------|--------|---------|
| 1. TurnExecutionInput | CompatibilityExecutionJob | TurnExecutionInput | Separate workload from credentials |
| 2. ProviderSelection | CompatibilityExecutionJob | ProviderSelection | Separate routing from auth |
| 3. NeutralModelRequest | TurnExecutionInput + ProviderSelection | NeutralModelRequest | Workload-only request |
| 4. Credential Injection | NeutralModelRequest + CredentialLease | ModelRequest | Add credential at boundary |
| 5. NeutralModelCompletion | Result | NeutralModelCompletion | Execution facts without billing |

Together these ensure:
- Credentials never enter neutral paths
- Billing/control-plane metadata never exits orchestration via neutral
- Provider protocol (replay, state) owned by provider layer
- Remaining coupling is correct by necessity

This is the production architecture. No further refactoring is required; violations outside the boundary are acceptable.
