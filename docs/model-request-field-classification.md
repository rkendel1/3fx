# ModelRequest Field Classification

## Classification Legend

- **A**: Neutral model-execution input (belongs in NeutralModelRequest)
- **B**: Authentication/Credential/Authorization (EXCLUDED from neutral request)
- **C**: Account/Billing/Usage/Control-plane (EXCLUDED from neutral request)
- **D**: Provider-specific compatibility (EXCLUDED from neutral request)

## Complete Field Analysis

### NeutralModelRequest Fields (A - Neutral)

| Field | Type | Purpose | Classification |
|-------|------|---------|-----------------|
| `model` | `[]const u8` | Model identifier for execution | A: Workload |
| `session_id` | `?[]const u8` | Workload identity (may be null) | A: Workload tracking |
| `instructions` | `[]const ChatMessage` | System instructions to model | A: Workload |
| `messages` | `[]const ChatMessage` | Conversation messages | A: Workload |
| `tools` | `ToolSelection` | Available tools (names, schemas) | A: Workload |
| `tool_choice` | `ToolChoice` | Tool execution option (auto/required/none) | A: Workload execution |
| `vision_mode` | `VisionMode` | Vision capability requirement | A: Capability routing |
| `provider_options` | `ResolvedProviderOptions` | Model execution config (temperature, max_tokens, reasoning_effort, ultrafast, etc.) | A: Workload execution |
| `max_output_tokens` | `?u32` | Maximum output token limit | A: Workload execution |
| `budget` | `?BuildBudget` | Deadline and cancellation control | A: Workload coordination |
| `verified_images` | `?[]const VerifiedSnapshot` | Image attachments/payloads | A: Workload |
| `response_format` | `?StructuredResponseFormat` | Structured output schema | A: Workload execution |
| `prepared_request_body` | `?[]const u8` | Pre-serialized request (optimization) | A: Optimization |
| `trace_ctx` | `TraceContext` | Turn/step/subagent IDs for observability | A: Observability |
| `content_capture_limit` | `?usize` | Truncation limit for content capture | A: Optimization |
| `deadline` | `?Timestamp` | Absolute execution deadline | A: Workload coordination |
| `cooperative_pulse` | `?CooperativePulse` | Host cooperation checkpoint | A: Workload coordination |
| `delivery` | `*DeliveryCertainty` | Delivery state tracking | A: Workload tracking |
| `attempt_evidence` | `*AttemptEvidence` | Network failure evidence | A: Workload recovery |
| `events` | `EventSink` | Streaming output sink | A: Workload output |
| `admission` | `Admission` | Pre-delivery admission gate | A: Workload control |
| `cancel_flag` | `*atomic bool` | Cancellation signal | A: Workload control |
| `provider_attempt_owner` | `ProviderAttemptOwner` | Retry owner (transport/agent) | A: Workload coordination |

**Total A fields**: 23

### ModelRequest-Only Fields (B - Authentication)

| Field | Type | Purpose | Classification | Reason for Exclusion |
|-------|------|---------|-----------------|---------------------|
| `credential` | `CredentialLease` | API key, account identity, auth headers | B: Authentication | Injected at compatibility boundary only |
| `retry_count` | `usize` | Retry limit for provider | A: Execution config | Set by compatibility layer, not turn orchestration |

**Total B fields**: 1 (credential)

## Projection Summary

| Aspect | Count |
|--------|-------|
| Total ModelRequest fields | 24 |
| Projected to NeutralModelRequest | 23 |
| Excluded (credential only) | 1 |
| Percent neutral | 95.8% |

## Boundary Injection Point

```zig
pub fn streamNeutralModelCompletion(
    provider: Provider,
    alloc: Allocator,
    neutral_request: NeutralModelRequest,    // 23 neutral fields
    credential: types.CredentialLease,       // B: Injected at boundary
    usage: ?*Usage,
    usage_allocator: Allocator,
) !StreamResult {
    // Create full ModelRequest with credential
    var model_request = ModelRequest{
        .credential = credential,  // Injected here
        .session_id = neutral_request.session_id,
        .model = neutral_request.model,
        // ... all other neutral fields copied
    };
    return streamModelCompletion(provider, alloc, model_request, usage, usage_allocator);
}
```

## Design Rationale

### Why credential is B (excluded)
- API keys are authentication, not workload
- Should never flow through neutral orchestration paths
- Account identity is authorization, not execution config
- Belongs at compatibility/auth boundary

### Why retry_count is not in NeutralModelRequest
- Set once at compatibility boundary based on job context
- Not part of neutral workload definition
- Injected via streamNeutralModelCompletion adapter

### Why all A fields are necessary
- Model, messages, tools define workload
- Execution options (temperature, tokens, reasoning) are workload config
- Delivery/attempt tracking is essential for recovery
- Deadlines and cancellation are workload coordination
- Events and admission are workload output control

## Test Coverage

```zig
// In stream_provider.zig
test "neutral model request contains no credential, account, or billing fields"
test "model request maintains backward compatibility with credential field"

// In gateway_step.zig
test "neutral model request adapter correctly injects credential at boundary"
```

## Future Evolution

This classification enables future work:
1. **Security analysis**: Static verification that credentials don't leak to neutral paths
2. **Optimization**: Analyze neutral requests without auth exposure
3. **Isolation**: Run neutral orchestration in different trust contexts
4. **Caching**: Cache based on neutral request structure
5. **Replay**: Replay neutral requests with different credentials
