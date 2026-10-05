# ModelCompletion Field Classification

## Classification Legend

- **A**: Neutral model-execution result (belongs in NeutralModelCompletion)
- **B**: Authentication/Credential/Authorization (EXCLUDED from neutral result)
- **C**: Account/Billing/Usage/Control-plane (EXCLUDED from neutral result)
- **D**: Provider-specific compatibility/replay (EXCLUDED from neutral result, owned by provider)

## Complete Field Analysis

### ModelCompletion Fields (types.ModelCompletion)

| Field | Type | Purpose | Classification | Rationale |
|-------|------|---------|-----------------|-----------|
| `content` | `?[]const u8` | Model output text | A: Neutral | Execution result, workload output |
| `tool_calls` | `[]const ToolCall` | Called tools with args | A: Neutral | Execution result, workload output |
| `generation_id` | `?[]const u8` | Provider generation ID | A: Neutral | Execution metadata (can be used for replay/logging) |
| `resolved_provider` | `?[]const u8` | Gateway routing resolution | C: Control-plane | Gateway-applied routing metadata, not provider-neutral |
| `billing` | `?ProviderBilling` | Billing information | C: Billing | Account/billing/cost data (control-plane) |
| `service_tier` | `?ProviderServiceTier` | Gateway service tier | C: Control-plane | Gateway feature/SLA metadata, not execution fact |
| `generation_metadata_invalid` | `bool` | Metadata validation flag | D: Compatibility | Provider protocol state, not execution result |
| `delivery_ambiguous` | `bool` | Billing delivery flag | C: Billing | Billing reconciliation state |
| `provider_result_identity_failure` | `?ProviderResultIdentityFailure` | Identity validation | D: Compatibility | Provider protocol validation |
| `provider_failure_cause` | `?ProviderFailureCause` | Failure classification | D: Compatibility | Provider-specific error classification |
| `provider_failure_detail` | `?[]const u8` | Provider error text | A: Neutral | Error information for user/troubleshooting |
| `provider_state_json` | `?[]const u8` | Opaque provider state | D: Compatibility | Provider-owned state for protocol continuation |
| `finish_reason` | `?ProviderFinishReason` | Completion stop reason | A: Neutral | Execution metadata (stop/length/content_filter/tool_calls) |
| `usage` | `Usage` | Token counting | A/C: Mixed | Execution metadata + billing (see below) |

**Total A fields**: 4 (content, tool_calls, generation_id, finish_reason)
**Total C fields**: 4 (resolved_provider, billing, service_tier, delivery_ambiguous)
**Total D fields**: 4 (generation_metadata_invalid, provider_result_identity_failure, provider_failure_cause, provider_state_json)
**Total Mixed (A/C)**: 1 (usage)

### Usage Field Analysis (types.Usage)

This field is currently mixed and requires careful handling:

```zig
pub const Usage = struct {
    input_tokens: ?u64 = null,      // A: Execution fact
    output_tokens: ?u64 = null,     // A: Execution fact
    cache_read_tokens: ?u64 = null, // A: Execution fact (cache hit efficiency)
    cache_write_tokens: ?u64 = null,// A: Execution fact (cache population)
    reasoning_tokens: ?u64 = null,  // A: Execution fact (extended thinking)
};
```

**Classification**: **A** (Neutral)

**Rationale**: 
- Token counts are *execution facts*, not billing control
- They measure provider-neutral resource consumption
- They enable efficiency tracking (cache hits, reasoning usage)
- They are read-only execution metadata
- Billing/cost is separate (see ProviderBilling)

**Note**: Usage/token counts are factual outcomes of model execution, like output latency or content length. They cross the neutral boundary as execution facts. Control-plane usage tracking (deferred reconciliation, rate limits, allocation) stays in `stream_provider.UsageOutcome.deferred` and doesn't cross into the neutral result.

### Failure Fields (agent_stream_provider.Failure)

| Field | Type | Purpose | Classification | Rationale |
|-------|------|---------|-----------------|-----------|
| `kind` | `FailureKind` | Error category | A: Neutral | Execution failure (invalid_request, rate_limited, etc.) |
| `detail` | `?[]u8` | Error description | A: Neutral | Provider error message for troubleshooting |
| `diagnostics` | `FailureDiagnostics` | Debug info | D: Compatibility | Provider protocol diagnostics (schema validation) |
| `retry_after_seconds` | `?u64` | Retry hint | A: Neutral | Provider directive (from HTTP headers) |
| `ownership` | `ResultOwnership` | Allocation owner | (metadata) | Not user-facing |

**Total A fields in Failure**: 3 (kind, detail, retry_after_seconds)
**Total D fields**: 1 (diagnostics)

## NeutralModelCompletion Design

The neutral result type projects only A-classified fields:

```zig
pub const NeutralModelCompletion = struct {
    // Execution result content
    content: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    
    // Execution metadata
    generation_id: ?[]const u8 = null,
    finish_reason: ?ProviderFinishReason = null,
    provider_failure_detail: ?[]const u8 = null,
    
    // Execution facts (not billing control)
    usage: Usage = .{},
    
    // Recovery coordination
    provider_state_json: ?[]const u8 = null,
    
    // Retry guidance
    retry_after_seconds: ?u64 = null,
};
```

**Included from ModelCompletion**:
- `content`: A (text output)
- `tool_calls`: A (execution output)
- `generation_id`: A (execution metadata)
- `finish_reason`: A (completion reason)
- `provider_failure_detail`: A (error info)
- `usage`: A (execution facts)
- `provider_state_json`: D (retained for replay fidelity)
- `retry_after_seconds`: A (retry hint)

**Excluded from ModelCompletion**:
- `resolved_provider`: C (gateway routing)
- `billing`: C (billing/cost)
- `service_tier`: C (gateway SLA)
- `generation_metadata_invalid`: D (validation state)
- `delivery_ambiguous`: C (billing)
- `provider_result_identity_failure`: D (validation)
- `provider_failure_cause`: D (provider classification)

**Not included from Failure diagnostics**:
- `diagnostics.schema`, `diagnostics.request_shape`: D (protocol validation)

## Boundary Projection Flow

```
ModelProvider.stream() or gateway provider
        ↓
agent_stream_provider.Completed / Failure
        ├── ModelCompletion (mixed: A/C/D)
        ├── UsageOutcome (usage tracking, separate)
        └── Failure (mixed: A/D)
        
        ↓ (compatibility adapter projects neutral fields)
        
NeutralModelCompletion
        ├── content, tool_calls (A)
        ├── generation_id, finish_reason (A)
        ├── usage (A: execution facts)
        ├── provider_failure_detail (A)
        ├── provider_state_json (D: retained)
        └── retry_after_seconds (A)
        
        ↓ (turn orchestration receives neutral result)
        
Turn orchestrator
        └── No access to: resolved_provider, billing, service_tier, or validation state
```

## Streaming Behavior

Streaming events already use the neutral boundary via `EventSink`:

```zig
pub const Event = union(enum) {
    content_delta: []const u8,          // A
    reasoning_delta: []const u8,        // A
    tool_started: struct {              // A
        id: []const u8,
        name: []const u8,
        label: ?[]const u8,
        arguments_json: ?[]const u8,
    },
    tool_input_delta: []const u8,       // A
};
```

- No streaming event carries credentials, billing, or control-plane data
- Streaming deltas flow through the neutral boundary unchanged
- Final result object (Completion) does the field projection

## Design Rationale

### Why usage is A (not C)

Token counts are *execution facts*, like:
- Response latency (observable outcome)
- Content length (observable outcome)
- Cache efficiency (observable outcome)

They are not:
- Billing tier/allocation (control-plane)
- Rate limit accounting (control-plane)
- Cost calculation (billing)

The turn orchestrator needs token counts for:
- Terminal context compaction decisions
- Agent step tracking
- User feedback

### Why provider_state_json is retained (D, but included)

`provider_state_json` is opaque provider-owned state for protocol continuation. It is:
- Owned entirely by the provider
- Included in NeutralModelCompletion for replay fidelity
- Never interpreted by the neutral turn loop
- Treated as a binary blob (passed through unchanged)

This is a **compatibility/fidelity decision**, not a security boundary. The turn orchestration passes it through verbatim on retry without examining it.

### Why resolved_provider is excluded (C)

`resolved_provider` is a gateway routing decision:
- Only the gateway sets it (from finalProvider/resolvedProvider)
- The turn orchestrator has no business knowing which backend served the request
- It's gateway control-plane metadata, not execution result
- It's exposed to the user via events (provider_resolved) at compatibility layer, not through neutral result

### Why billing is excluded (C)

`ProviderBilling` contains:
- created_at_ms, model, total_cost
- Billing token counts (input, output, cache, reasoning)
- billable_web_search_calls

This is account/subscription control-plane data:
- Not needed for workload execution
- Not needed for retry/recovery decisions
- Billing ledger reconciliation happens at compatibility layer
- Credentials required to interpret it

### Why validation fields are excluded (D)

- `generation_metadata_invalid`: Protocol validation result
- `provider_result_identity_failure`: Provider ID validation
- `provider_failure_cause`: Provider-specific classification
- `diagnostics`: Schema/request_shape validation

These are provider adapter internal state, not execution results. They remain in the adapter's result projection.

### Why service_tier is excluded (C)

`ProviderServiceTier` (standard, flex, ultrafast):
- Gateway-applied feature metadata
- Not provider output
- Not execution result
- Service tier is used only for billing and feature availability decisions
- Belongs at gateway compatibility layer

## Test Coverage

```zig
// In stream_provider.zig or model_completion.zig
test "neutral model completion contains only A-classified fields" {
    // Verify NeutralModelCompletion has no credential/auth/account/billing fields
}

test "neutral model completion projection preserves provider_state_json for replay" {
    // Ensure provider opaque state is retained
}

test "streaming events carry only neutral content" {
    // Verify Event union has no control-plane fields
}

test "usage is treated as neutral execution fact" {
    // Token counts are execution outcome, not billing control
}
```

## Migration Path

This classification enables future work:

1. **Security analysis**: Static verification that credentials/billing don't leak to neutral paths
2. **Neutral result adapter**: Project `Completed` → `NeutralModelCompletion` at compatibility boundary
3. **Audit trail**: Turn orchestration never sees billing/account data
4. **Optimization**: Analyze neutral completions without auth exposure
5. **Isolation**: Run neutral orchestration in different trust contexts
6. **Caching**: Cache based on neutral completion structure
7. **Replay**: Replay neutral completions with different credentials

## Fields Summary Table

| Category | Count | Examples |
|----------|-------|----------|
| A: Neutral execution result | 9 | content, tool_calls, usage, finish_reason, provider_failure_detail, generation_id, retry_after_seconds, reason enum |
| C: Account/billing/control-plane | 4 | resolved_provider, billing, service_tier, delivery_ambiguous |
| D: Provider-specific/validation | 5 | generation_metadata_invalid, provider_state_json (retention), provider_result_identity_failure, provider_failure_cause, diagnostics |

**Note**: provider_state_json is D but included in NeutralModelCompletion for protocol fidelity (not interpreted by neutral layer).
