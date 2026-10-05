# Neutral Model Routing

## Overview

Model routing—determining "which endpoint/capability should execute this work"—is a neutral concern separate from authentication, authorization, billing, and vendor-specific control-plane decisions.

This boundary isolates routing from provider-specific execution state at the `CompatibilityExecutionJob` → `TurnExecutionInput` seam.

## What Is Model Routing?

Model routing answers these questions:
- Which model by identifier (e.g., "claude-opus-5-5", "gpt-4o", "ollama:mistral")
- Which provider by name (e.g., "gateway", "codex", "configured:local-ollama")
- What capability constraints apply (vision support, context window, reasoning effort)
- What recovery identity for replay (which model and provider served the original attempt)

Model routing does NOT answer:
- "What API key do I use?" (authentication)
- "Am I authorized to call this?" (authorization)
- "Whose account is this?" (billing/identity)
- "Which team/tenant is this for?" (control-plane)

## The Neutral Type: ProviderSelection

`ProviderSelection` is the minimal structure for neutral routing:

```zig
pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
};
```

**Fields:**
- `provider`: ProviderId enum (gateway | codex | grok | configured)
- `model`: Model identifier string

**No fields for:**
- `api_key` (authentication)
- `credential_source` (auth provenance)
- `account_id` (billing/authorization)
- `gateway_team` (tenant)
- `permission_mode` (policy)

## Projection Point: execution_compatibility.zig

```zig
pub fn neutralModelRoute(job: CompatibilityExecutionJob) model_provider.ProviderSelection
```

This function:
- Borrows `provider` and `model` from the job
- Performs no allocations
- Retains no ownership
- Returns the routing identity

**Example:**

```zig
const job: CompatibilityExecutionJob = .{
    .model = "gpt-4o",
    .provider = .gateway,
    .api_key = "secret-key",           // NOT projected
    .account_id = "acct_123",           // NOT projected
    .gateway_team = "team_abc",         // NOT projected
    // ...
};

const route = neutralModelRoute(job);
// route.model == "gpt-4o"
// route.provider == .gateway
// route carries no credential/auth/account state
```

## Where Model Routing Is Used

### 1. Model Capability Queries (Pure Routing)

```zig
// "What capabilities does this model have?"
var request_capabilities = deps.available_model_capabilities(deps.ctx, job.model);
```

The model identifier alone is sufficient; no credential is needed.

### 2. ProviderSelection for Replay Identity (Pure Routing)

```zig
// "Which model and provider to use as replay source?"
try projectEmptyHistoryReplay(
    arena,
    deps.agent_stream_provider,
    .{ .provider = job.provider, .model = job.model },
    history_messages.items,
);
```

Replay identity needs only routing; no auth coupling.

### 3. Recovery Selection Comparison (Pure Routing)

```zig
// "Did the routing decision change (model or provider)?"
const selection_changed = recoverySelectionChanged(
    checkpoint,
    job.provider,    // routing
    job.model,       // routing
    // fast/ultrafast modes are also routing
);
```

Comparing old vs new routing requires only provider/model.

### 4. Provider Routing Decisions (Pure Routing)

```zig
// "Is this provider the gateway (determines capability or behavior)?"
if (job.provider == .gateway) {
    // gateway-specific behavior
}
```

The provider identity alone determines routing.

### 5. Telemetry/Metrics Labels (Source Only)

```zig
// Telemetry records model and provider names for tracing
recordGatewayCallMetric(request.model, started_at_ms, ...);
```

Model/provider are used as labels only; no auth coupling.

## What This Boundary Protects

| Concern | Remains At | Why |
|---------|-----------|-----|
| Authentication (api_key) | CompatibilityExecutionJob | Credential must not cross boundary |
| Authorization (permission_mode) | CompatibilityExecutionJob | Policy decisions stay at host |
| Billing (account_id) | CompatibilityExecutionJob | Identity sensitive; audit trail needed |
| Control-plane (gateway_team) | CompatibilityExecutionJob | Tenant isolation critical |
| Routing (provider, model) | Both (projected) | Neutral; needed for execution |

## Fields in ProviderSelection vs CompatibilityExecutionJob

### In ProviderSelection (Projected)
- `provider: ProviderId` — routing identity
- `model: []const u8` — model identifier

### In CompatibilityExecutionJob Only (NOT Projected)
- `api_key: []u8` — authentication secret
- `credential_source: ?CredentialSource` — auth provenance
- `account_id: ?[]u8` — billing/authorization identity
- `gateway_team: ?[]u8` — tenant context
- `permission_mode: PermissionMode` — authorization policy
- `steering_receipt: ?*SteeringReceipt` — control/cancellation

## Integration Points (Unchanged)

These components already receive neutral routing and require no changes:

### Model Capabilities (config/model_capabilities.zig)
- Receives model identifier
- Returns capability info
- No credential involved

### ModelProvider / AgentStreamProvider (gateway/)
- Receives ProviderSelection or model identifier
- Routes to appropriate endpoint
- Credential passed separately (via CredentialLease)

### Recovery Authority (session/session_codec.zig)
- Checkpoint stores provider + model for identity
- No credential stored in checkpoint
- Authorization checked separately when resuming

### Replay Projection
- Uses ProviderSelection to tag replay identity
- No credential stored in replay metadata
- Delivery uses current credential

## Testing Strategy

### Unit Tests (execution_compatibility_tests.zig)
1. Projection borrows fields without copying
2. Projection excludes all auth/account/billing fields
3. Configured providers work correctly
4. Gateway/codex/grok providers work correctly

### E2E Tests (turn execution)
1. Model routing unchanged (same models resolve same capabilities)
2. Provider routing unchanged (same providers handle requests identically)
3. Replay identity preserved (checkpoints use correct provider/model)
4. Recovery selection change detection works
5. Telemetry labels correct

### No Breaking Changes
- ModelProvider invocation signature unchanged
- Replay/history semantics unchanged
- Capability resolution unchanged
- Recovery/checkpoint authority unchanged

## Why This Is NOT Complete Provider Neutralization

This boundary isolates routing from authentication, but does not:
- Eliminate all provider-specific code
- Create a provider-agnostic request format
- Redesign the gateway adapter interface
- Consolidate vendor-specific replay semantics

Those are separate, larger efforts. This PR creates the narrow seam needed to make routing decisions without embedding auth/account/policy concerns.

## Related Concepts

### ProviderSelection vs Model Routing
- `ProviderSelection` is the concrete type (provider + model string)
- "Model routing" is the conceptual boundary (routing decisions vs auth)
- They are the same thing operationally; routing uses ProviderSelection

### TurnExecutionInput Includes Routing
- `TurnExecutionInput.provider` and `.model` are routing fields
- Part of the neutral workload configuration
- Unlike auth fields (api_key, credential_source, account_id), which are not in TurnExecutionInput

### Orchestrator's Gateway Model Variable
```zig
var gateway_model: []const u8 = job.model;
```
- Local variable for the current model being routed to
- Updated during recovery if selection changes
- Still pure routing; no auth coupling
