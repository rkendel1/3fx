# Execution Credential Boundary

## Overview

This document proves the credential injection boundary in the existing execution path.

The fx agent runtime is already separated into credential-aware and credential-free layers. This boundary is architecturally sound and is identified here for formalization in Phase 3.

## Credential Injection Point

**Location:** `src/core/agent/runtime/orchestrator.zig:7266`

```zig
var model_request = agent_stream_provider.ModelRequest{
    .credential = execution_compatibility.modelRequestLease(active_api_key, job),
    .session_id = lifecycle.scope.session_id,
    .model = gateway_model,
    // ... rest of fields are neutral execution data
};
```

At this single location in the orchestrator:
1. The host-owned `active_api_key` and `job` (which contains account_id, gateway_team, etc.) are used
2. A credential is derived via `execution_compatibility.modelRequestLease()`
3. The credential is injected into `stream_provider.ModelRequest`
4. All other request fields are neutral execution data (messages, tools, deadlines, etc.)

## Credential-Free ModelProvider

**Location:** `src/core/agent/model_provider.zig`

The existing `ModelProvider` interface and `model_provider.Completion` result contain no credential or account state:

```zig
pub const ModelProvider = struct {
    id: []const u8,           // provider identifier only
    model: []const u8,        // model identifier only
    context: *anyopaque,
    chat_fn: *const fn(*anyopaque, Allocator, ChatRequest) anyerror!ChatStream,
    capabilities_fn: *const fn(*anyopaque) ProviderCapabilities,
};
```

The `ChatRequest` contains only neutral execution data:
- messages
- tools  
- deadlines
- cancellation signal

It does NOT contain credentials.

The `ChatStream` result contains only:
- content
- tool calls
- finish reason
- token usage

It does NOT contain billing, account, subscription, or credential state.

## Existing Neutral Projections

The codebase already demonstrates the minimal projection pattern:

**`src/core/app/execution_compatibility.zig:448`**
```zig
pub fn coordinator(job: worker.CompatibilityExecutionJob, turn: *TurnState, cancel: *AtomicBool, step_limit: usize) TurnCoordinator
```

Projects CompatibilityExecutionJob → neutral TurnCoordinator (execution identity only).

**`src/core/app/execution_compatibility.zig:478`**
```zig
pub fn loopControl(coordinator_state: *TurnCoordinator) LoopControl
```

Projects TurnCoordinator → neutral LoopControl (loop control only).

These show the architectural pattern: minimal, purpose-specific projections at boundaries.

## Proof of Separation

**Test:** `src/core/agent/execution_boundary.zig`

Three focused tests prove:

1. **Neutral data independence** — Execution data (model, messages, tools, deadlines) exists independent of credential state
2. **Result neutrality** — Completion results contain only execution outcomes, no credential/billing metadata
3. **Explicit injection** — Credentials are injected ONLY at the `stream_provider.ModelRequest` construction point

## Architecture

```
CompatibilityExecutionJob (host-owned, with credentials/account)
    ↓
orchestrator.processAgentPrompt()
    ↓
[execution logic operates on neutral data]
    ↓
orchestrator:7266 — CREDENTIAL INJECTION POINT
    .credential = execution_compatibility.modelRequestLease(active_api_key, job)
    ↓
stream_provider.ModelRequest (ready for transport, credential added)
    ↓
ModelProvider.chat() (credential-free interface)
    ↓
stream_provider.Result (neutral execution outcome)
```

## What Remains Unfinished

Phase 3 will formalize this boundary by:

1. Creating canonical `TurnExecutionInput` type (extracted from CompatibilityExecutionJob, no credentials)
2. Creating canonical `ProviderSelection` type (routing only)
3. Introducing optional neutral request/completion types for clarity
4. Adding dependency guard to prevent credentials leaking into neutral code paths
5. Creating standalone neutral-core verification

For now, this document proves the boundary is architecturally sound and requires only formalization, not redesign.
