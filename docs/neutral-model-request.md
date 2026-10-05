# Neutral Model Request Boundary

## Overview

The model request boundary is the third seam in fx's execution architecture. It consolidates request construction around the existing `ModelProvider` contract, ensuring that the turn orchestration loop passes only neutral model-execution data to the provider layer, while credentials and account/billing information remain behind the compatibility boundary.

## Three-Seam Architecture

### Seam 1: TurnExecutionInput (Neutral Turn Configuration)
**Location**: `src/core/agent/turn_execution_input.zig`

Extracted early from `CompatibilityExecutionJob`. Contains only workload and configuration data:
- Prompt, images, model, provider (routing only)
- Conversation history, permissions, context snapshot
- Excludes: credentials, account_id, api_key, gateway_team, billing

### Seam 2: ProviderSelection (Neutral Model Routing)
**Location**: `src/core/config/model_provider.zig`

Simple routing information: `{ provider: ProviderId, model: []const u8 }`

Allows capability routing and recovery identity projection without exposing credentials or billing.

### Seam 3: NeutralModelRequest (Neutral Model Execution Input)
**Location**: `src/core/agent/stream_provider.zig`

The model request boundary at the gateway layer. Contains only execution workload:

#### Included (Neutral Model-Execution Fields)
- `model`: model identifier (workload)
- `messages`, `instructions`: conversation workload
- `tools`: available tools (workload)
- `tool_choice`: execution option
- `vision_mode`: capability routing
- `provider_options`: model execution configuration (temperature, max_tokens, reasoning_effort, etc.)
- `max_output_tokens`: execution parameter
- `budget`: deadline and cancellation (workload coordination)
- `verified_images`: image payloads (workload)
- `response_format`: execution parameter (structured output)
- `prepared_request_body`: serialization optimization
- `trace_ctx`: observability
- `events`: streaming output sink
- `cancel_flag`: workload cancellation control
- `deadline`: execution deadline
- `delivery`: delivery certainty state (workload tracking)
- `attempt_evidence`: network evidence for recovery (workload tracking)
- `session_id`: workload identity
- `cooperative_pulse`: host cooperation mechanism
- `provider_attempt_owner`: retry ownership (workload coordination)
- `admission`: pre-delivery gate for workload control
- `content_capture_limit`: optimization parameter

#### Explicitly Excluded (Compatibility Layer)
- `credential`: API key, account identity, authentication headers
- `retry_count`: retry policy (injected at compatibility boundary)
- Account/billing: account_id, gateway_team, billing metadata
- Vendor-specific: vendor login state, control-plane objects
- Authorization: policy objects, subscription tier

**Total**: 23 neutral fields, 0 credential fields

## Request Projection Flow

```
CompatibilityExecutionJob
├── (contains all state: creds, auth, account, billing)
│
├── turnExecutionInput() → TurnExecutionInput
│   └── (neutral workload only, no auth)
│
└── (for model execution)
    ├── ProviderSelection (model + provider routing)
    │
    ├── NeutralModelRequest (workload execution)
    │   ├── Constructed by orchestrator from TurnExecutionInput + routing
    │   └── Contains no credential/auth/account fields
    │
    └── Compatibility Adapter: streamNeutralModelCompletion()
        ├── Input: NeutralModelRequest + credential_lease
        ├── Creates full ModelRequest (injects credential)
        └── Calls provider.stream(ModelRequest)
```

## Implementation Details

### Orchestrator Responsibility
**File**: `src/core/agent/runtime/orchestrator.zig`

1. Extracts `TurnExecutionInput` early (line 5172)
2. Constructs only `NeutralModelRequest` for model calls
3. Obtains credential lease from compatibility layer
4. Calls `streamNeutralModelCompletion()` with separated credential

**Key Change**: Model request construction no longer directly accesses credential:
```zig
// Before: ModelRequest with embedded credential
var model_request = agent_stream_provider.ModelRequest{
    .credential = execution_compatibility.modelRequestLease(...),
    ...
};

// After: NeutralModelRequest + separate credential
var neutral_request = agent_stream_provider.NeutralModelRequest{ ... };
const credential_lease = execution_compatibility.modelRequestLease(...);
try runtime_gateway_step.streamNeutralModelCompletion(..., neutral_request, credential_lease, ...);
```

### Gateway Boundary Responsibility
**File**: `src/core/agent/runtime/gateway_step.zig`

The `streamNeutralModelCompletion()` function:
1. Accepts `NeutralModelRequest` (workload only)
2. Accepts `CredentialLease` (authentication only)
3. Constructs full `ModelRequest` by injecting credential into neutral request
4. Delegates to existing `streamModelCompletion()` for actual execution

This adapter sits at the compatibility boundary and prevents credential information from flowing through the neutral turn loop.

### Provider Interface
**File**: `src/core/agent/stream_provider.zig`

No changes to existing `ModelProvider` or `Provider` contracts:
- Providers still receive `ModelRequest` with credential field
- Providers still extract credential for HTTP headers/authentication
- Provider behavior is unchanged
- Only the turn orchestration loop's internal flow is reorganized

## Replay and Recovery

Both replay (for auth failures) and recovery (for network failures) use the same neutral boundary:

```zig
// Auth replay with credential refresh
const replay_credential_lease = execution_compatibility.modelRequestLease(refreshed_api_key, job);
var replay_neutral_request = neutral_request;
replay_neutral_request.delivery = &replay_delivery;
replay_neutral_request.attempt_evidence = &replay_evidence;
try runtime_gateway_step.streamNeutralModelCompletion(
    provider, arena, replay_neutral_request, replay_credential_lease, usage, usage_allocator
);
```

Credential injection happens at the same adapter point, regardless of retry or recovery.

## Side-Model Requests

Compaction requests (`text_completion.zig`) and vision/image requests (`image_provider.zig`) construct full `ModelRequest` directly because they:
1. Are not part of main turn orchestration
2. Need different retry and resource policies
3. Have specific credential and usage tracking requirements

These remain outside the neutral boundary by design. Only primary turn orchestration (orchestrator.zig → gateway_step.zig) uses the neutral seam.

## Tests

### Core Boundary Tests
- `stream_provider.zig`: NeutralModelRequest contains no credential/auth/account fields
- `stream_provider.zig`: ModelRequest maintains backward compatibility with credential field
- `gateway_step.zig`: Neutral request adapter correctly injects credential at boundary

### Behavioral Tests
- Existing `streamModelCompletion()` tests remain green
- Replay/recovery flows use same neutral boundary
- Streaming, cancellation, and timeout behavior unchanged
- Allocation patterns preserved (arena scratch released after every attempt)

### Integration
- End-to-end tests verify behavior unchanged from user perspective
- Model routing and capability checks work with neutral requests
- Permission review sees only neutral request data
- Usage tracking works with injected credential

## What Stayed the Same

1. **ModelProvider contract** (`src/core/agent/model_provider.zig`)
   - No changes
   - Remains provider-neutral
   - Continues to reject control-plane fields

2. **Provider implementations** (gateway adapters)
   - No changes to request handling
   - Still extract credential from ModelRequest.credential
   - HTTP behavior identical

3. **Streaming, cancellation, retries**
   - All retry logic unchanged
   - Delivery certainty tracking unchanged
   - Cancellation semantics preserved
   - Attempt evidence collection unchanged

4. **Replay and recovery**
   - Both use neutral boundary adapter
   - Credential refresh still works
   - Recovery policy decisions unchanged

## Why This Matters

This seam ensures that:
1. The neutral turn loop (orchestrator) never handles credentials
2. Credentials stay behind the explicit compatibility boundary
3. Turn orchestration logic remains decoupled from auth/billing concerns
4. Provider interface is simplified (no account/billing context needed)
5. Security boundary is clear: credentials flow at adapter point only
6. Future optimizations can safely analyze neutral requests without auth exposure
