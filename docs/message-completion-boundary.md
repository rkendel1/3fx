# Message/Completion/Tool Boundary Architecture

This document describes the semantic boundaries and ownership model for message/completion/tool handling in the agent orchestration layer.

## Architecture Layers

```
Neutral Execution Request
        ↓
  [credential injected]
        ↓
Provider Model Request → Provider → Provider Model Result
        ↓
  [Result union: completed | failed]
        ↓
Neutral Model Completion / Neutral Failure
        ↓
  [provider metadata added: billing, routing, control-plane]
        ↓
Model Completion / Failure (Provider-owned wrapper)
        ↓
  [Orchestration decision-making]
        ↓
Tool Call Normalization (compatibility layer)
Tool Materialization (via stream context)
Tool Execution (separate tooling module)
Tool Result Capture (execution_memory module)
        ↓
Message History Construction (session module)
Replay/Recovery (provider-specific state)
```

## Layer Ownership

### Layer 1: Neutral Execution (Request Boundary)

**File:** `src/core/agent/stream_provider.zig` (lines 220-264)

**Structure:** `NeutralModelRequest`

**Ownership:** Execution/workload

**Contains:**
- model, instructions, messages, tools, tool_choice
- vision_mode, max_output_tokens, response_format
- Coordination: trace_ctx, cancel_flag, events, admission

**Excludes:**
- credentials, account_id, API keys
- billing information
- provider identity
- authentication state

**Tests:** Lines 380-403 confirm no forbidden fields present

---

### Layer 2: Neutral Execution (Result Boundary)

**File:** `src/core/agent/stream_provider.zig` (lines 352-378)

**Structures:**
- `NeutralModelCompletion` (lines 352-371)
- `NeutralFailure` (lines 374-378)

**Ownership:** Execution

#### NeutralModelCompletion

**Contains (Execution Facts Only):**
- `content: ?[]const u8` — Model output text
- `tool_calls: []const ToolCall` — Tool invocations (name, id, arguments)
- `generation_id: ?[]const u8` — Model generation/session identifier
- `finish_reason: ?ProviderFinishReason` — Stop reason (stop/length/content_filter/tool_calls)
- `usage: types.Usage` — Token counts (input/output/cache/reasoning)
- `provider_failure_detail: ?[]const u8` — Vendor error message (troubleshooting)

**Contains (Opaque Protocol State):**
- `provider_state_json: ?[]const u8` — Provider-owned continuation state (never interpreted)
- `retry_after_seconds: ?u64` — HTTP retry hint

**Excludes (Never Crossing Boundary):**
- resolved_provider, billing, service_tier (control-plane)
- generation_metadata_invalid, delivery_ambiguous (billing authority)
- provider_failure_cause (diagnostics; belongs with provider result metadata)
- diagnostics objects (schema, request_shape)

**Tests:** Lines 417-441 confirm excluded fields are absent

#### NeutralFailure

**Contains:**
- `kind: FailureKind` — Error classification (rate_limited, server_error, etc.)
- `detail: ?[]u8` — Error message
- `retry_after_seconds: ?u64` — Retry guidance

**Excludes:**
- diagnostics (stored separately in provider Failure, not exposed to neutral layer)

**Tests:** Lines 444-465 confirm no forbidden fields

---

### Layer 3: Provider Compatibility (Result Wrapping)

**File:** `src/core/agent/stream_provider.zig` (lines 505-617)

**Structure:** `Result` union
- `.completed`: `Completed { completion: ModelCompletion, usage: UsageOutcome, ownership }`
- `.failed`: `Failure { kind, detail, diagnostics, retry_after_seconds, ownership }`

**Ownership:** Provider + Compatibility

**ModelCompletion adds (Control-Plane Fields):**
- `resolved_provider: ?[]const u8` — Gateway routing metadata (informational)
- `billing: ?ProviderBilling` — Exact cost and token accounting
- `service_tier: ?ProviderServiceTier` — QoS tier served
- `generation_metadata_invalid: bool` — Routing metadata conflict flag
- `delivery_ambiguous: bool` — Billing authority uncertainty marker
- `provider_result_identity_failure: ?ProviderResultIdentityFailure` — Routing validation detail
- `provider_failure_cause: ?ProviderFailureCause` — Vendor-specific failure classification

**Failure adds:**
- `diagnostics: FailureDiagnostics` — Detailed validation/schema information

**Projection Methods:**
- `result.neutralCompletion()` — Extract execution facts only (line 589)
- `result.neutralFailure()` — Extract neutral failure (line 607)

**Deinit:** `result.deinit(alloc)` manages ownership cleanup (line 558)

---

### Layer 4: Orchestration (Consumption)

**File:** `src/core/agent/runtime/orchestrator.zig`

**Call Site:** Line 7293

```zig
stream_result = runtime_gateway_step.streamNeutralModelCompletion(
    deps.agent_stream_provider,
    arena,
    neutral_request,
    credential_lease,  // Injected at boundary
    deps.usage,
    deps.usage_allocator,
) catch |err| {
    // Error handling (network, provider, etc.)
};
```

**Result Handling:**
```zig
const response_completion = streamCompletion(stream_result);
const response_failure = streamFailure(stream_result);
```

**Correct Semantics:**
- `response_completion` is `ModelCompletion` (includes billing, routing, control-plane)
- Orchestrator correctly:
  - Does NOT interpret `provider_state_json` (passed through opaque)
  - Does NOT make billing decisions (that's account/control-plane responsibility)
  - Does NOT interpret provider failure cause (diagnostics only; recovery uses neutral `FailureKind`)
  - Uses `resolved_provider` for telemetry only (published as event, line 7759-7766)
  - Uses `service_tier` for ultrafast mode verification only (line 7746-7751)
  - Normalizes tool calls via compatibility layer (terminal/subagent request projection)

---

### Layer 5: Tool Call Representation

**File:** `src/core/shared/types.zig` (lines 862-876)

**Structure:** `ToolCall`

**Mixed Ownership (By Design):**

| Field | Classification | Owner | Reason |
|-------|-----------------|-------|--------|
| `id` | Execution fact | Execution | Tool call identity |
| `name` | Execution fact | Execution | Tool name invoked |
| `arguments_json` | Execution fact | Execution | Tool arguments (validated) |
| `argument_integrity` | Authority | Permissions | Validation result |
| `argument_diagnostic` | Protocol metadata | Provider | Vendor JSON parse detail |
| `provisional_id` | Protocol metadata | Provider | Streaming tracking ID |
| `provider_result` | Protocol metadata | Provider | Vendor-native result (if from provider) |
| `final_identity` | Protocol metadata | Provider | Replay validation marker |
| `provenance` | Execution fact | Execution | Local vs provider origin |
| `resolved_skill` | Authority | Permissions | Skill binding (borrowed) |

**Why Mixed?**
- Streaming requires `provisional_id` during tool call streaming before full result
- Replay requires provider context (`final_identity`, `provider_result`)
- Permissions require `resolved_skill` and `argument_integrity` binding
- This is not accidental; it's correct by necessity

**Normalization (Compatibility Layer):**
Tool calls undergo legacy protocol adaptation (orchestrator.zig 7768-7779):
- `normalize_terminal_request_tool_calls()` — Adapt terminal tool protocol
- `normalize_subagent_request_tool_calls()` — Adapt subagent tool protocol

This is in-place normalization at compatibility boundary, not extraction.

---

### Layer 6: Message History

**File:** `src/core/shared/types.zig` (lines 1450-1466)

**Structure:** `ChatMessage`

**Ownership:** Execution + Compatibility + Persistence

**Fields by Category:**

**Execution Facts:**
- `role: ChatRole` — Message type (user/assistant/tool)
- `content: ?[]const u8` — Text content
- `images: []const ImageAttachment` — Attached images
- `tool_name: ?[]const u8` — Tool result attribution
- `tool_calls: []const ToolCall` — Assistant-called tools (mixed: see ToolCall)
- `tool_result_status: ?PersistedToolStatus` — Tool outcome (success/failure)
- `tool_result_memory: ?ToolResultMemory` — Tool output captured

**Persistence Metadata:**
- `context_origin` — Source classification (ordinary/user_turn/handoff)
- `restored_steering` — Recovery checkpoint flag
- `standalone_response` — Finalization marker

**Protocol/Replay:**
- `tool_call_id: ?[]const u8` — Pairs tool result to invocation (provider protocol)
- `provider_replay: ?ProviderReplay` — Provider-specific message state

**Authority:**
- `permission_feedback: bool` — Permission decision recorded

**Why Not Split?**
Each role has different semantic requirements:
- User message: content, images only
- Assistant message: content, tool_calls, provider_replay
- Tool message: tool_call_id, tool_name, tool_result_status, tool_result_memory

No single "neutral" structure fits all roles independently.

---

### Layer 7: Provider Replay

**File:** `src/core/shared/types.zig` (defined implicitly in projectProviderReplay)

**Structure:** `ProviderReplay`
```zig
source: ProviderSelection,  // {provider, model}
parts_json: []const u8,     // Vendor-specific message parts
```

**Ownership:** Provider-specific protocol

**Semantics:**
- Stores provider's native message wire format
- Used to reconstruct exact message on replay to same provider
- Filtered by ProviderSelection (types.zig 1476-1481): Only used if provider+model match
- Never interpreted by orchestrator

**Lifecycle:**
1. Created by provider adapter (maps native response to our ChatMessage)
2. Stored in ChatMessage.provider_replay (immutable history)
3. Projected when provider changes (removes incompatible replay)
4. Replayed by provider adapter on next request to same provider

**provider_state_json vs provider_replay:**
- `provider_state_json` (NeutralModelCompletion): Opaque continuation state (passed to next request)
- `provider_replay` (ChatMessage): Message wire format (used when replaying turn to same provider)

Different purposes, different ownership.

---

## Owned Boundaries

### Boundary 1: Credential Injection

```
NeutralModelRequest (no credential)
    ↓ [gateway_step.zig:50-86]
    ↓ credential_lease injected
ModelRequest (+ credential)
    ↓ [provider.stream()]
Result
```

**Invariant:** Credential never enters neutral request.

**Enforcement:** Tests lines 380-403 in stream_provider.zig.

### Boundary 2: Neutral Result Extraction

```
ModelCompletion + control-plane state
    ↓ [result.neutralCompletion()]
NeutralModelCompletion (execution facts only)
```

**Invariant:** NeutralModelCompletion never contains billing, routing, or control-plane fields.

**Enforcement:** Tests lines 746-793 in stream_provider.zig.

### Boundary 3: Orchestration Semantics

```
NeutralModelCompletion
    ↓ [orchestrator decision logic]
Recovery decision, retry decision, history integration
```

**Invariant:** Orchestrator decisions (recovery, retry) use only neutral facts and execution semantics.

**Current:** Correctly implemented.
- Recovery uses `FailureKind`, not `provider_failure_cause`
- Retry uses failure evidence, not provider diagnostics
- provider_state_json passed opaque through recovery

### Boundary 4: Tool Normalization

```
Tool calls from completion
    ↓ [compatibility layer]
Normalized for terminal/subagent protocol
```

**Invariant:** Tool call normalization is in-place compatibility transformation, not extraction to separate structure.

**Current:** Correctly implemented (orchestrator.zig 7768-7779).

### Boundary 5: Replay Ownership

```
Provider-native message state
    ↓ [provider adapter]
ProviderReplay (provider-specific wire format)
    ↓ [stored in ChatMessage]
    ↓ [provider selection changes]
    ↓ [projection: remove if provider mismatches]
    ↓ [provider adapter on replay]
Restored to native format for next request to same provider
```

**Invariant:** Replay is provider-specific; orchestrator doesn't interpret it.

**Current:** Correctly implemented.

---

## What Should NOT Be Extracted

### 1. NeutralMessage

Would require splitting ChatMessage by role, which breaks history semantics:
- User messages don't have tool_calls or provider_replay
- Assistant messages need provider_replay for correctness
- Tool messages need tool_call_id and tool_result_memory
- No common "neutral message" exists across roles

### 2. NeutralToolExecution

Would require separating ToolCall into NeutralToolInvocation + ProviderToolMetadata:
- `provisional_id` is needed during streaming to track incomplete calls
- `provider_result` is needed for provider-native result path
- `final_identity` is needed for replay correctness
- These are **not accidental**; they're required for correct streaming and replay

### 3. NeutralCompletion (separate from ModelCompletion)

Already exists as `result.neutralCompletion()` method:
- Provides read-only neutral projection
- Used for testing (line 746-793)
- Doesn't require structural extraction
- Method projection is sufficient

### 4. ProviderCompletionContext

Would duplicate Result semantics and add confusion:
- Result already cleanly separates neutral facts from provider state
- Orchestrator correctly uses ModelCompletion as "full state including compatibility"
- No consumer needs a "compatibility-only" structure

---

## Replay and Recovery Ownership

### provider_state_json

**Source:** NeutralModelCompletion (opaque)

**Usage Path:**
1. Received from provider
2. Passed through StreamResult
3. Stored in Result.completed.completion.provider_state_json
4. Projected to neutral (never interpreted)
5. Passed through recovery checkpoint unchanged
6. Sent to provider on next request (for continuation)

**Semantics:** Opaque provider protocol state, never interpreted by orchestrator.

**Correct:** No changes needed.

### provider_replay

**Source:** Provider adapter creates ProviderReplay from native response

**Usage Path:**
1. Created by provider adapter
2. Stored in ChatMessage.provider_replay (immutable history)
3. Projected when provider changes (filtered by ProviderSelection)
4. Replayed by provider adapter (if provider matches)

**Semantics:** Provider-specific message wire format for replay.

**Correct:** No changes needed.

### Recovery Checkpoint

Contains:
- assistant_source: Partial streamed content (for resume/retry)
- tool_state: Tool execution evidence (for recovery decision)
- provider metadata: Model, attempts, mode, cause, strategy

**Does NOT contain:**
- Full model state (that's in message history)
- Billing information
- Provider routing decisions

**Correct:** Checkpoint is session lifecycle, not semantic storage.

---

## Recommended Practice

### For New Tool/Message Features

1. **Execution facts** live in NeutralModelCompletion (if from provider)
2. **Provider-specific protocol** state stays in Result/ModelCompletion
3. **Message history** lives in ChatMessage with role-appropriate fields
4. **Authority/permission** decisions stored with message (permission_feedback, argument_integrity)
5. **Replay/recovery** state stays provider-owned (provider_replay, provider_state_json)

### For Code Reading

- Start at orchestrator.zig:7293 (stream call)
- Follow streamCompletion/streamFailure projection
- Understand what stays opaque (provider_state_json, provider_replay)
- Understand what's extracted for decisions (FailureKind, content, tool_calls)
- Understand what's logged for telemetry (resolved_provider, service_tier)

### For Refactoring

Before proposing extraction:
1. Verify the concept exists at semantic boundary
2. Confirm consumers need neutral view vs full context
3. Check if projection method (like neutralCompletion) is sufficient
4. Ensure extraction doesn't duplicate existing seams

---

## Summary

The message/completion/tool boundary is already well-architected:

- **Neutral execution** (facts, no credentials): NeutralModelRequest → NeutralModelCompletion
- **Provider compatibility** (includes billing, routing, protocol): ModelCompletion, ProviderReplay
- **Message history** (role-aware, mixed concerns by necessity): ChatMessage
- **Tool execution** (separate module): types.ToolCall + tooling/ directory
- **Permissions/authority** (separate concern): argument_integrity, permission_feedback, resolved_skill

This is correct by design. No extraction is needed. Focus on maintaining these boundaries in future work.
