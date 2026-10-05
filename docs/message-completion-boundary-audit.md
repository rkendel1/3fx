# Message/Completion/Tool/Replay Handling Audit

**Audit Date:** 2026-10-05  
**Branch:** `claude/trusting-allen-eh3evy`  
**Scope:** Trace NeutralModelCompletion consumption through message/history/tool/replay boundaries

## Executive Summary

The message/completion/tool boundary is **already well-separated at the semantic level**:

- **NeutralModelCompletion** (lines 352-371 in stream_provider.zig): Pure execution result
- **ModelCompletion** (types.zig 1633-1655): Provider compatibility wrapper
- **StreamResult** (gateway_step.zig line 18): Result union carrying both
- **ChatMessage** (types.zig 1450-1466): Message history representation

**Finding:** No new neutral type extraction is justified. The existing boundary between NeutralModelCompletion and ModelCompletion already cleanly separates execution facts from provider/billing/control-plane state. Tool calls, messages, and replay are already following the established pattern.

## Detailed Field Classification

### NeutralModelCompletion (stream_provider.zig 352-371)

| Field | Type | Classification | Owner | Crossing Point | Reason |
|-------|------|-----------------|-------|-----------------|--------|
| `content` | `?[]const u8` | **A** (Neutral execution fact) | Execution | Direct pass-through | Model output text |
| `tool_calls` | `[]const types.ToolCall` | **A** (Neutral execution fact) | Execution | Direct pass-through | Model tool invocations |
| `generation_id` | `?[]const u8` | **A** (Neutral execution fact) | Execution | Logging/replay identity | Provider's session/generation identifier |
| `finish_reason` | `?types.ProviderFinishReason` | **A** (Neutral execution fact) | Execution | Direct pass-through | Model completion stop reason |
| `provider_failure_detail` | `?[]const u8` | **A** (Neutral execution fact) | Execution | Troubleshooting only | Vendor error message for diagnostics |
| `usage` | `types.Usage` | **A** (Neutral execution fact) | Execution | Token tracking | Input/output/cache tokens (not billing) |
| `provider_state_json` | `?[]const u8` | **D** (Provider-specific) | Provider protocol | Opaque pass-through | Protocol state for continuation on retry |
| `retry_after_seconds` | `?u64` | **D** (Provider-specific) | Provider transport | Retry delay hint | HTTP header-sourced retry guidance |

**Key:** A = Neutral fact, B = Auth/credential, C = Account/billing, D = Provider protocol

### ToolCall (types.zig 862-876)

| Field | Type | Classification | Owner | Crossing Point |
|-------|------|-----------------|-------|-----------------|
| `id` | `[]const u8` | **A** (Execution fact) | Execution | Tool call identity |
| `name` | `[]const u8` | **A** (Execution fact) | Execution | Tool name invoked |
| `arguments_json` | `[]const u8` | **A** (Execution fact) | Execution | Arguments parsed/validated |
| `argument_integrity` | `ToolArgumentIntegrity` | **B** (Authority) | Permissions | Validation result (rejected/valid) |
| `argument_diagnostic` | `?ToolArgumentDiagnostic` | **D** (Provider protocol) | Compatibility | Malformed JSON detail |
| `provisional_id` | `?[]const u8` | **D** (Provider protocol) | Compatibility | Provisional tracking for streaming |
| `provider_result` | `?[]const u8` | **D** (Provider protocol) | Compatibility | Tool result from provider flow |
| `final_identity` | `FinalToolIdentity` | **D** (Provider protocol) | Compatibility | Replay identity validation |
| `provenance` | `ToolExecutionProvenance` | **A** (Execution fact) | Execution | Local vs provider origin |
| `resolved_skill` | `?*const PreparedSkill` | **B** (Authority) | Permissions | Skill binding (borrowed, compile-time) |

### ChatMessage (types.zig 1450-1466)

| Field | Type | Classification | Owner | Crossing Point |
|-------|------|-----------------|-------|-----------------|
| `role` | `ChatRole` | **A** (Execution fact) | Execution | Message type (user/assistant/tool) |
| `content` | `?[]const u8` | **A** (Execution fact) | Execution | Message text |
| `images` | `[]const ImageAttachment` | **A** (Execution fact) | Execution | Attached images |
| `tool_call_id` | `?[]const u8` | **D** (Provider protocol) | Compatibility | Tool result pairing ID |
| `tool_name` | `?[]const u8` | **A** (Execution fact) | Execution | Tool result attribution |
| `tool_calls` | `[]const ToolCall` | **A** + **D** (mixed) | Mixed | See ToolCall analysis |
| `provider_replay` | `?ProviderReplay` | **D** (Provider protocol) | Provider replay | Provider-specific replay state |
| `tool_result_status` | `?PersistedToolStatus` | **A** (Execution fact) | Execution | Tool result outcome |
| `tool_result_memory` | `?ToolResultMemory` | **A** (Execution fact) | Execution | Tool output captured |
| `permission_feedback` | `bool` | **B** (Authority) | Permissions | Permission decision record |
| `restored_steering` | `bool` | **A** (Execution fact) | Execution | Recovery checkpoint marker |
| `context_origin` | `enum` | **A** (Execution fact) | Execution | Message source classification |
| `standalone_response` | `bool` | **A** (Execution fact) | Execution | Finalization marker |

### ModelCompletion (types.zig 1633-1655)

| Field | Type | Classification | Owner | Notes |
|-------|------|-----------------|-------|-------|
| `content` | `?[]const u8` | **A** | Execution | From NeutralModelCompletion |
| `tool_calls` | `[]const ToolCall` | **A**+**D** | Mixed | From NeutralModelCompletion |
| `generation_id` | `?[]const u8` | **A** | Execution | From NeutralModelCompletion |
| `resolved_provider` | `?[]const u8` | **C** (Control-plane) | Gateway routing | NOT in NeutralModelCompletion |
| `billing` | `?ProviderBilling` | **C** (Billing) | Account/billing | NOT in NeutralModelCompletion |
| `service_tier` | `?ProviderServiceTier` | **C** (Control-plane) | Gateway service | NOT in NeutralModelCompletion |
| `generation_metadata_invalid` | `bool` | **C** (Control-plane) | Routing validation | NOT in NeutralModelCompletion |
| `delivery_ambiguous` | `bool` | **C** (Billing) | Billing authority | NOT in NeutralModelCompletion |
| `provider_result_identity_failure` | Option | **C** (Control-plane) | Routing | NOT in NeutralModelCompletion |
| `provider_failure_cause` | Option | **D** (Provider protocol) | Diagnostics | NOT in NeutralModelCompletion |
| `provider_failure_detail` | `?[]const u8` | **A** | Execution | From NeutralModelCompletion |
| `provider_state_json` | `?[]const u8` | **D** (Protocol) | Provider | From NeutralModelCompletion |
| `finish_reason` | Option | **A** | Execution | From NeutralModelCompletion |
| `usage` | `types.Usage` | **A** | Execution | From NeutralModelCompletion |

## Boundary Consumption Path

### 1. Stream Result Receipt (orchestrator.zig 7293)

```
streamNeutralModelCompletion()
  ↓
StreamResult { .completed or .failed }
  ↓
streamCompletion(result) → ModelCompletion
streamFailure(result) → ?Failure
```

The Neutral → Compatibility boundary is enforced here:
- NeutralModelRequest (line 220-264 in stream_provider.zig): No credentials
- credential injected at gateway_step.zig:50-86 (streamNeutralModelCompletion)
- Result projection: lines 589-603 (neutralCompletion, neutralFailure methods)

### 2. Completion Processing (orchestrator.zig 7745-7780)

```
if streamCompletionPtr(&stream_result) |completion| {
    // completion is *ModelCompletion (includes billing, resolved_provider)
    
    // Extract provider routing metadata (C - control-plane)
    if completion.resolved_provider |provider| {
        deps.push_event(.provider_resolved = owned)  // Informational only
    }
    
    // Normalize tool calls (A+D mixed: execution fact + provider protocol)
    completion.tool_calls = normalize_terminal_request_tool_calls(...)
    completion.tool_calls = normalize_subagent_request_tool_calls(...)
}
```

**Key observation:** tool_calls are extracted directly from ModelCompletion. They flow from:
- NeutralModelCompletion.tool_calls (execution fact)
→ ModelCompletion.tool_calls (unwrapped, no addition)
→ Normalized for terminal/subagent protocol compatibility

### 3. Tool Call Normalization (in-place compatibility)

Tool calls undergo **terminal request normalization** and **subagent request normalization**:
- Transforms: Legacy "tool_use" → normalized "tool_call" format
- Ownership: Provider-specific protocol mapping (lines 7768-7779)
- This is compatibility layer, not semantic extraction

### 4. Tool Execution and Materialization

Tool call execution path (orchestrator.zig 7866-7878):
```
if streamSucceeded(stream_result) and
   (settled_disposition == .interrupted or .provider_failure)
{
    materializeConfirmedProviderTools(
        deps, &stream_ctx, arena, config, control.coordinator.turn_id,
        response_completion,  // ModelCompletion
        .{ .provider = job.provider, .model = gateway_model },
        ...
    );
}
```

Tool calls are materialized into the transcript via stream context, not through a separate extraction step.

### 5. Message History Integration

Messages are composed from multiple sources (orchestrator.zig 5519-5533):
- Stable prefix: System context, project files
- History messages: Prior turns
- Current user message: New user input  
- Within-turn suffix: Tool results, steering, recovery context

Assistant messages are **NOT** created as a discrete step from completion content. Instead:
- Content streams via `stream_ctx` (runtime_assistant_stream.zig)
- Tool calls tracked in `stream_ctx` 
- Messages materialized when turn persists to history

### 6. Replay Semantics

Provider replay is stored at ChatMessage.provider_replay (types.zig 1457):
```
pub const ProviderReplay = struct {
    source: ProviderSelection,   // Which provider, which model
    parts_json: []const u8,      // Provider-specific message parts
};
```

**Ownership:** Provider-specific, NOT neutral. Replay depends on:
- provider_state_json (opaque continuation state)
- provider model identity
- Provider-specific message serialization

Replay projection (types.zig 1469-1483):
- Filters provider_replay by ProviderSelection match
- Preserves execution facts, removes incompatible replay
- This is compatibility check, not extraction

## What Remains Tightly Coupled (By Design)

### 1. Tool Call Representation

Tool calls **cannot be separated** from provider protocol details because:
- `provisional_id`: Used during streaming to track incomplete tool calls
- `provider_result`: Provider-native result before fx processing
- `final_identity`: Replay validation marker
- `argument_diagnostic`: Vendor-specific parse failure detail

These are **not accidental mixing**. They are the **neutral execution fact** (name, id, arguments) plus **immediate protocol metadata** needed for:
- Streaming tool call tracking
- Replay correctness
- Vendor error diagnostics

**Extraction not justified:** Would require either:
a) Splitting ToolCall into NeutralToolInvocation + ProviderToolMetadata (premature; semantics not yet separated)
b) Deferring metadata storage separately (would duplicate retrieval logic)

### 2. Provider Replay

Replay cannot be neutral because:
- Each provider has different message wire format
- Replay must work with the provider's internal state
- The orchestrator **does not interpret** provider_state_json; it's purely opaque pass-through
- Replay is provider-specific semantic operation, not execution fact

**Where replay is interpreted:** Only in provider adapters (gateway/, not in core orchestration)

### 3. Message History Construction

ChatMessage **cannot be split** into NeutralMessage + CompatibilityMessage because:
- Role, content, tool_calls, images are execution facts (A)
- tool_call_id, tool_name, tool_result_status are result pairing (A)
- provider_replay is protocol requirement (D)
- context_origin, restored_steering, standalone_response are persistence markers (A)

No single field is universally "neutral" independent of message role and context.

## Ownership Seams Already Established

### 1. **NeutralModelRequest ↔ ModelRequest** (stream_provider.zig)

```
NeutralModelRequest (workload only)
    ↓ [credential injected at boundary]
ModelRequest (+ credential)
    ↓ [provider.stream()]
StreamResult { .completed | .failed }
```

**Status:** Clean separation. Credential never enters neutral execution.

### 2. **NeutralModelCompletion ↔ ModelCompletion** (stream_provider.zig)

```
NeutralModelCompletion (execution facts)
    ↓ [projection neutralCompletion()]
Result.neutralCompletion() → NeutralModelCompletion (read-only)
    
ModelCompletion (includes billing, routing, protocol)
    ↓ [embedded in Result.completed]
Full result available to orchestrator
```

**Status:** Clean separation. Neutral result already extracted and tested (lines 746-793 in stream_provider.zig).

### 3. **StreamResult ↔ Orchestration** (orchestrator.zig)

```
StreamResult {
    .completed { completion: ModelCompletion, usage, ... }
    .failed { kind, detail, diagnostics, ... }
}
    ↓ [streamCompletion(), streamFailure() accessors]
response_completion: ModelCompletion (with billing, routing)
response_failure: ?Failure
```

**Status:** Clean seam. Orchestrator receives full model result, including control-plane fields, and correctly:
- Publishes resolved_provider as informational only
- Uses billing only for token tracking (lines 7753, 7746-7751)
- Passes provider_state_json opaque through recovery/retry

### 4. **Tool Calls ↔ Normalization** (orchestrator.zig)

```
response_completion.tool_calls ([]ToolCall)
    ↓ [normalize_terminal_request_tool_calls()]
    ↓ [normalize_subagent_request_tool_calls()]
Normalized tool calls remain in place (compatibility layer, not extraction)
    ↓ [materializeConfirmedProviderTools() if needed]
Tool tracked in stream_ctx, not moved to separate structure
```

**Status:** Compatibility layer (terminal/subagent protocol adaptation) is intentionally in-place, not separated.

### 5. **Tool Results ↔ Messages** (runtime_execution_memory.zig, session.zig)

Tool result messages are built separately from tool execution:
- Tool result execution: `tools/` directory
- Result capture: `runtime_execution_memory.zig`
- Message construction: `session.zig appendExecutionMemoryChatMessages()`

**Status:** Already separated by module. Tool result handling doesn't mix with completion handling.

## Provider State JSON Interpretation (Critical)

**Finding:** provider_state_json is **never interpreted** by neutral orchestration.

Usage trace:
1. **Received:** stream_provider.zig lines 352-371 (NeutralModelCompletion)
2. **Passed through:** gateway_step.zig line 589-603 (projected into ModelCompletion)
3. **Stored:** ChatMessage.provider_replay (types.zig 1457)
4. **Replayed:** Only by provider adapters, never by orchestrator
5. **Deinit:** Result.deinit() handles cleanup (stream_provider.zig 558-584)

**No semantic interpretation occurs** at orchestration level. Provider state is:
- Opaque string
- Borrowed from provider response
- Owned/freed via Result lifecycle
- Passed unchanged to provider on next request

This is correct and requires no change.

## Failure Handling

NeutralFailure (stream_provider.zig 374-378):
```
pub const NeutralFailure = struct {
    kind: FailureKind,
    detail: ?[]u8 = null,
    retry_after_seconds: ?u64 = null,
};
```

**Excludes:** diagnostics (schema, request_shape)

**Usage:**
- Extracted via streamFailure() (orchestrator.zig 4163)
- Failure kind determines recovery strategy (model_response_recovery.zig)
- Detail shown to user if available
- Diagnostics (NOT in neutral) logged for troubleshooting only

**Status:** Clean separation. Neutral failure contains recovery information only. Diagnostics remain with provider compatibility layer (Failure struct, line 497-503 in stream_provider.zig).

## Replay/Recovery Ownership

Recovery checkpoint (types.HistoryTurn.recovery):
```
recovery_checkpoint: ?RecoveryCheckpoint = null,
```

RecoveryCheckpoint contains:
- assistant_source: Partial streamed content
- tool_state: Tool execution evidence
- max_provider_attempts: Retry limit
- fast_mode: Performance mode flag
- cause: Failure classification

**Semantics:** Recovery checkpoint is **session lifecycle**, not message semantic.

**provider_state_json** is carried within recovery for replay, but:
- NOT interpreted by recovery logic
- NOT used for recovery decision-making
- Only passed to provider on retry
- Owned by Result lifecycle, not checkpoint

**Status:** provider_state_json remains opaque and provider-owned. Checkpoint structure is correct.

## Summary of Findings

### Neutral Execution Boundary: CLEAN ✓
- NeutralModelRequest excludes all credentials/account/billing
- NeutralModelCompletion contains only execution facts
- NeutralFailure contains only recovery-relevant info
- Tests confirm (lines 380-465 in stream_provider.zig)

### Message/Tool/Replay Boundary: SEMANTICALLY MIXED (BY DESIGN) ✓
- ToolCall mixes execution fact (name/id/arguments) with protocol metadata (provisional_id/provider_result)
- This is correct because: streaming requires provisional tracking, replay requires provider context
- No extraction justified because semantics cannot be cleanly separated at message level

### Completion Consumption: CLEAN ✓
- ModelCompletion (provider-owned) clearly separate from NeutralModelCompletion
- Orchestrator correctly:
  - Doesn't interpret provider_state_json
  - Passes billing/routing fields through without decision-making
  - Normalizes tool calls at compatibility boundary only
  - Tracks tool execution via stream context, not separate structure

### Replay: PROVIDER-OWNED ✓
- provider_replay is provider-specific protocol state
- Correctly stored in ChatMessage (immutable history)
- Correctly filtered by ProviderSelection (types.zig 1476-1481)
- Never interpreted outside provider adapters

## Conclusion

**No new neutral type extraction is justified.**

The architecture already cleanly separates:
1. **Neutral execution facts** (NeutralModelCompletion) from
2. **Provider compatibility** (ModelCompletion, ProviderReplay, provider_state_json) from
3. **Message history** (ChatMessage, with role, content, tool_calls, images, metadata)
4. **Tool results** (execution-specific, separate module)
5. **Permissions/Authority** (ToolArgumentIntegrity, permission_feedback, resolved_skill)

The message/completion boundary **is already well-owned**:
- Semantic layer: Message history representation (ChatMessage) with clear role semantics
- Protocol layer: Provider replay, provider_state_json, tool call metadata (provisional_id, provider_result, final_identity)
- Execution facts: content, tool_calls (name/id/arguments), finish_reason, usage, tool results, images

Attempting to extract "NeutralMessage" or "NeutralToolExecution" would be premature generalization. The tightly coupled fields exist because their semantics genuinely require it:
- Tool streaming requires provisional_id tracking
- Replay requires provider context awareness
- Recovery requires provider_state_json pass-through
- Permissions require argument_integrity validation

These are not accidental mixings; they are **required couplings for correctness**.

---

## Recommendations

1. **Document the existing boundary** (add docs/message-completion-boundary.md)
2. **No extraction needed** - the existing seams are sufficient
3. **Consider future work if needed:** Only if use cases emerge where execution facts must be separated from protocol metadata. Currently, all consumers need the full context.
4. **Maintain guard patterns** in stream_provider.zig tests (lines 380-465) to prevent credential/account/billing leakage into neutral layer
