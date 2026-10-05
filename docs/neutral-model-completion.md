# Neutral Model Completion Boundary

## Overview

The model completion boundary is the response-side equivalent to the request-side `NeutralModelRequest` seam. It establishes that the turn orchestration loop receives provider results without credentials, account identity, billing state, or vendor control-plane objects.

## Three-Seam Architecture

### Seam 1: TurnExecutionInput (Neutral Turn Configuration)
**Location**: `src/core/agent/turn_execution_input.zig`

Workload input boundary. Extracted early from `CompatibilityExecutionJob`, contains only prompt, history, context, permissions.

### Seam 2: NeutralModelRequest (Neutral Model Execution Input)
**Location**: `src/core/agent/stream_provider.zig`

Request boundary at the gateway layer. Contains only execution workload (model, messages, tools, etc.).

### Seam 3: NeutralModelCompletion (Neutral Model Execution Result) ← NEW
**Location**: `src/core/agent/stream_provider.zig`

Result boundary at the gateway layer. Contains only execution result.

## Request/Response Symmetry

```
NeutralModelRequest → provider execution → NeutralModelCompletion

Input:                                      Output:
├── model                                   ├── content
├── messages                                ├── tool_calls
├── tools                                   ├── usage (execution facts)
├── provider_options                        ├── finish_reason
├── max_output_tokens                       ├── provider_state_json (opaque)
├── deadline                                ├── generation_id
├── cancel_flag                             └── provider_failure_detail
└── events (streaming sink)

EXCLUDED:                                   EXCLUDED:
├── credential ✗                            ├── resolved_provider ✗
├── retry_count ✗                           ├── billing ✗
└── (no account/billing input)              ├── service_tier ✗
                                            └── (no account/billing output)
```

## NeutralModelCompletion Type

```zig
pub const NeutralModelCompletion = struct {
    // Execution result content
    content: ?[]const u8,                      // Model output text
    tool_calls: []const ToolCall,              // Called tools with arguments
    
    // Execution metadata
    generation_id: ?[]const u8,                // Provider generation ID
    finish_reason: ?ProviderFinishReason,     // stop/length/content_filter/tool_calls
    provider_failure_detail: ?[]const u8,     // Error text for troubleshooting
    
    // Execution facts (not billing control)
    usage: Usage,                              // Token consumption
    
    // Recovery fidelity (provider-owned, opaque)
    provider_state_json: ?[]const u8,         // Passed through unchanged on retry
    
    // Retry guidance
    retry_after_seconds: ?u64,                 // From HTTP headers
};
```

## Field Classification Reference

See `model-completion-field-classification.md` for complete analysis. Summary:

| Category | Fields | Included in NeutralModelCompletion |
|----------|--------|-----------------------------------|
| A: Neutral execution result | content, tool_calls, generation_id, finish_reason, provider_failure_detail, usage, retry_after_seconds | ✓ YES |
| D: Provider compatibility (opaque) | provider_state_json | ✓ YES (fidelity) |
| C: Account/billing | resolved_provider, billing, service_tier, delivery_ambiguous | ✗ NO |
| D: Provider validation | diagnostics, provider_result_identity_failure | ✗ NO |
| D: Provider classification | provider_failure_cause, generation_metadata_invalid | ✗ NO |

**Total Neutral Fields**: 9 out of 14 ModelCompletion fields

## Projection and Boundary Enforcement

### From ModelCompletion to NeutralModelCompletion

```
provider result (ModelCompletion)
        ↓
Result union (completed/failed)
        ↓ result.neutralCompletion() [NEW]
        ↓ result.neutralFailure() [NEW]
NeutralModelCompletion / NeutralFailure
        ↓
turn orchestrator (receives only neutral result)
```

### Compiler Enforcement

The `NeutralModelCompletion` type has no fields for:
- Credentials (api_key, secret, credential, auth)
- Account identity (account_id, gateway_team, tenant, provider_id, resolved_provider)
- Billing (billing, service_tier, cost, created_at_ms)
- Diagnostics (schema, request_shape, validation results)

Attempting to add these fields will fail at compile time.

### Test Enforcement

```zig
test "neutral model completion contains no credential, account, or billing fields" {
    // Compile-time verification that no forbidden fields are present
}
```

## Projection Examples

### Successful Completion

```zig
// ModelCompletion from provider
const completion = ModelCompletion{
    .content = "Here's the file content...",
    .tool_calls = &.{},
    .generation_id = "gen_...",
    .finish_reason = .stop,
    .usage = Usage{ .input_tokens = 50, .output_tokens = 150 },
    .resolved_provider = "claude-3-opus",      // EXCLUDED
    .billing = ProviderBilling{ ... },         // EXCLUDED
    .service_tier = .ultrafast,                // EXCLUDED
    .provider_state_json = "{...}",            // RETAINED
};

// Project to neutral
const neutral = result.neutralCompletion();
// → content, tool_calls, generation_id, finish_reason, usage, provider_state_json
// → resolved_provider, billing, service_tier are gone
```

### Tool Call Completion

```zig
const completion = ModelCompletion{
    .content = null,
    .tool_calls = &.{
        ToolCall{ .id = "call_1", .name = "read_file", .arguments_json = "{...}" },
    },
    .finish_reason = .tool_calls,
    .provider_state_json = "{...}",            // For protocol continuation
    .billing = ProviderBilling{ ... },         // EXCLUDED (not used for tools)
};

// Neutral projection includes tool_calls and provider_state_json unchanged
```

### Failure Result

```zig
// Failure from provider
const failure = Failure{
    .kind = .rate_limited,
    .detail = "too many requests",
    .retry_after_seconds = 60,
    .diagnostics = FailureDiagnostics{        // EXCLUDED
        .schema = "...",
        .request_shape = "...",
    },
};

// Project to neutral
const neutral = result.neutralFailure();
// → kind, detail, retry_after_seconds
// → diagnostics field is gone
```

## Implementation

### Projection Functions

In `src/core/agent/stream_provider.zig`:

```zig
pub fn neutralCompletion(self: Result) NeutralModelCompletion {
    return switch (self) {
        .completed => |completed| .{
            .content = completed.completion.content,
            .tool_calls = completed.completion.tool_calls,
            .generation_id = completed.completion.generation_id,
            .finish_reason = completed.completion.finish_reason,
            .provider_failure_detail = completed.completion.provider_failure_detail,
            .usage = completed.completion.usage,
            .provider_state_json = completed.completion.provider_state_json,
            .retry_after_seconds = null,
        },
        .failed => .{},
    };
}

pub fn neutralFailure(self: Result) NeutralFailure {
    return switch (self) {
        .failed => |failure| .{
            .kind = failure.kind,
            .detail = failure.detail,
            .retry_after_seconds = failure.retry_after_seconds,
        },
        .completed => unreachable,
    };
}
```

These are **borrowing projections**: they return new values with borrowed string references. No allocation, no ownership change.

### Streaming Already Neutral

Streaming events already use the neutral boundary via `EventSink`:

```zig
pub const Event = union(enum) {
    content_delta: []const u8,
    reasoning_delta: []const u8,
    tool_started: struct { id, name, label, arguments_json },
    tool_input_delta: []const u8,
};
```

No credentials, billing, or control-plane state flows through events.

## Integration Points

### Turn Orchestration

The orchestrator already processes results safely:

```zig
// After model invocation
const stream_result = try runtime_gateway_step.streamNeutralModelCompletion(...);

// Accessing result
if (stream_result == .completed) {
    const completion = stream_result.completed.completion; // ModelCompletion
    // Orchestrator can safely read: content, tool_calls, usage, generation_id
    // Orchestrator does NOT receive: billing, service_tier, resolved_provider
}
```

With this boundary clarified, we can optionally project to neutral in the future:

```zig
// Future: explicit neutral result flow
const neutral = stream_result.neutralCompletion();
// Orchestrator receives only neutral fields
```

### Billing and Gateway Metadata

These remain at the compatibility boundary:

```zig
// At CompatibilityExecutionJob layer
const billing = stream_result.completed.completion.billing;        // Accessible here
const resolved_provider = stream_result.completed.completion.resolved_provider;

// Turn orchestrator never sees these fields directly
```

### Provider State Continuation

For protocol replay/recovery, `provider_state_json` is retained as opaque:

```zig
const neutral = result.neutralCompletion();
// provider_state_json is included (passed through unchanged)
// Orchestrator never interprets it, only forwards on retry
```

## Streaming Behavior Preserved

- Partial text delivery: unchanged (content_delta events)
- Tool streaming: unchanged (tool_started, tool_input_delta)
- Cancellation: unchanged (cancel_flag monitoring)
- Timeout: unchanged (deadline enforcement)
- Retry: unchanged (attempt tracking)
- Allocation: unchanged (arena scratch released after every attempt)

The neutral boundary does not affect streaming semantics. It only clarifies which *result fields* cross into orchestration.

## What Stayed the Same

1. **Provider implementations**
   - No changes to ModelProvider adapters
   - Still return ModelCompletion/Failure unchanged
   - No new provider requirements

2. **Streaming and events**
   - EventSink already neutral
   - No changes to Event type
   - Streaming delivery unchanged

3. **Usage tracking**
   - Usage/token counts are execution facts (neutral, cross boundary)
   - Billing reconciliation stays at compatibility layer
   - No change to deferred usage tracking

4. **Retry and recovery**
   - Provider replay uses ModelRequest (unchanged)
   - Recovery uses neutral request/completion (established)
   - Allocation patterns unchanged

5. **Completion prose handling**
   - Existing discardCompletionProse logic unchanged
   - Works with ModelCompletion directly

## Tests

### Core Boundary Tests
- `stream_provider.zig`: NeutralModelCompletion contains no credential/account/billing fields
- `stream_provider.zig`: NeutralFailure contains no diagnostic/validation fields
- `stream_provider.zig`: Neutral projection preserves execution result correctly

### Behavioral Tests
- Existing `streamModelCompletion()` tests remain green
- Streaming, cancellation, timeout behavior unchanged
- Allocation patterns verified

### Field Coverage
- All 9 neutral fields tested for presence
- All 5 excluded field categories verified absent (compile-time)

## Why This Matters

This boundary ensures:

1. **Clear separation of concerns**: Orchestration logic doesn't entangle with billing/routing metadata
2. **Security boundary**: Billing data never flows through neutral paths
3. **Audit trail**: We can verify orchestrator doesn't access account/subscription state
4. **Isolation**: Future optimizations can safely analyze neutral completions
5. **Testability**: Neutral behavior is verifiable without involving gateway/billing
6. **Replay fidelity**: provider_state_json is retained for protocol correctness
7. **Streaming integrity**: Events remain purely workload output

## Design Notes

### Why provider_state_json is included (D, but neutral)

Provider state is opaque protocol data for continuation. It:
- Is never interpreted by orchestrator
- Is passed through unchanged on retry
- Maintains protocol fidelity
- Is provider-owned (not orchestration state)

Including it as a neutral "blob" is correct because:
1. Orchestrator doesn't examine it
2. It enables transparent protocol replay
3. Excluding it would force awkward refactoring

### Why usage is neutral (A, not C)

Token counts are *execution facts*, not billing control:
- Input tokens consumed: execution metric
- Output tokens generated: execution metric
- Cache hits/writes: efficiency metric
- Reasoning tokens: extended thinking metric

These are like response latency or content length—observable outcomes, not billing jurisdiction.

### Why resolved_provider is excluded (C, not A)

Provider routing is a gateway control-plane decision:
- Only the gateway decides which backend to use
- Orchestrator is agnostic to the choice
- It's available in the event stream (provider_resolved event) when needed
- Belongs at compatibility/gateway layer

## Future Evolution

This boundary enables:

1. **Neutral result type usage**: Turn orchestrator explicitly receives `NeutralModelCompletion`
2. **Static analysis**: Verify orchestrator code never accesses ModelCompletion fields directly
3. **Billing isolation**: Separate accounting from model execution cleanly
4. **Replay optimization**: Cache based on neutral request/completion structure
5. **Cross-provider testing**: Test orchestration with neutral results only
6. **Protocol versioning**: NeutralModelCompletion can evolve independently of gateway metadata

## Summary

| Aspect | Request Side (NeutralModelRequest) | Response Side (NeutralModelCompletion) |
|--------|-----------------------------------|--------------------------------------|
| **Purpose** | Prevent credentials entering orchestration | Prevent billing/routing exiting orchestration |
| **Location** | stream_provider.zig | stream_provider.zig |
| **Included fields** | 23 workload fields | 9 result fields + opaque state |
| **Excluded fields** | credential only | resolved_provider, billing, service_tier, diagnostics |
| **Streaming** | EventSink (already neutral) | Event enum (already neutral) |
| **Usage tracking** | Not applicable | Usage/tokens are neutral facts |
| **Enforcement** | Compile-time + tests | Compile-time + tests |
| **Backward compat** | Projections are borrowing | Projections are borrowing |

The request and response boundaries together ensure the neutral turn loop executes workload-only logic, with credentials and account metadata injected/removed only at the explicit compatibility seam.
