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

## Reusable Agent-Turn Boundary

The existing runtime already exposes a callable seam suitable for external control planes:

**Location:** `src/core/agent/runtime/orchestrator.zig:5137`

```zig
pub fn processAgentPrompt(
    agent: *runtime_agent.Agent,
    deps: *const AgentRuntimeDeps,
    semantic_presentation: ?runtime_assistant_stream.SemanticPresentationSink,
    lifecycle: LifecycleContext,
    config: Config,
    job: CompatibilityExecutionJob,
) !void
```

### Phase 3: Callable Seam Discovered

Phase 3 documented that `processAgentPrompt` is already the canonical agent-turn boundary.

Current callers: App layer, CLI, ACP, subagents, external tests.

### Phase 4: Caller-Facing Request Boundary

Phase 4 introduces a minimal caller-facing request type to decouple external callers from `CompatibilityExecutionJob`:

**New Type:** `src/core/agent/execution_boundary.zig`

```zig
pub const AgentTurnRequest = struct {
    prompt: []const u8,
    model: []const u8,
    history: []types.HistoryTurn,
    images: []types.ImageAttachment,
    grants: []types.PermissionGrant,
    permission_mode: types.PermissionMode,
    agent_settings: worker_runtime.AgentTurnSettings = .{},
};

pub fn projectAgentTurnRequest(
    alloc: Allocator,
    request: AgentTurnRequest,
    api_key: []const u8,
    credential_source: types.CredentialSource,
) !worker_runtime.CompatibilityExecutionJob
```

### External Caller Path (Phase 4)

An external control plane now:
1. Constructs `AgentTurnRequest` with only execution inputs (no credentials)
2. Calls `projectAgentTurnRequest()` with host-owned credentials
3. Receives `CompatibilityExecutionJob` ready for `processAgentPrompt()`
4. Implements the `AgentRuntimeDeps` callbacks as before

Flow:
```
External control plane
        ↓
AgentTurnRequest (execution inputs only, no credentials)
        ↓
projectAgentTurnRequest()
        ↓
CompatibilityExecutionJob (with host credentials injected)
        ↓
processAgentPrompt()
        ↓
existing fx runtime
```

### Credential Boundary (Preserved)

- Caller request contains NO credentials or account state
- Host projection injects credentials at boundary via `projectAgentTurnRequest()`
- Credentials flow into `CompatibilityExecutionJob`
- Single injection point in orchestrator remains unchanged
- Results contain only execution outcomes (no credentials returned)

### Phase 5: First Real Caller

Phase 5 demonstrates a real caller using `AgentTurnRequest` end-to-end:

**Example: Test harness in `src/core/agent/runtime/tests/support.zig`**

```zig
pub fn turnRequest(self: *PromptFixture) AgentTurnRequest {
    return .{
        .prompt = "user prompt",
        .model = "anthropic/claude-opus-4.6",
        .images = self.images[0..],
        .history = self.history[0..],
        .grants = self.grants[0..],
        .permission_mode = .ask,
    };
}
```

**Integration test path:**
```zig
// External caller constructs AgentTurnRequest
const request = fixture.turnRequest();

// Host projects request + credentials
const job = try projectAgentTurnRequest(
    alloc,
    request,
    "test-api-key",
    .ai_gateway_api_key,
);

// Execute through real processAgentPrompt
try runFakePrompt(&gateway, &hooks, fixture.config(), job);
```

Real execution proves:
- `AgentTurnRequest` → `projectAgentTurnRequest()` → `processAgentPrompt()`
- Credentials injected at boundary
- Existing provider/streaming/tool execution unchanged
- Complete integration working end-to-end

### Phase 3/4/5 Summary

1. Phase 3: Discovered existing `processAgentPrompt()` as callable boundary
2. Phase 4: Introduced `AgentTurnRequest` to decouple external callers from `CompatibilityExecutionJob`
3. Phase 5: First real caller (`test harness`) uses the new boundary successfully
4. Tests proving end-to-end execution
5. Proof that credentials remain host-owned throughout
6. No new runtime, frameworks, or abstractions
7. Existing `processAgentPrompt()` unchanged
