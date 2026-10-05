# TurnExecutionInput Field Classification

This document details how each `CompatibilityExecutionJob` field was classified for the neutral turn execution input boundary.

## Source Type: CompatibilityExecutionJob

From `src/core/agent/worker_runtime.zig`, the `CompatibilityExecutionJob` contains the following fields:

## Field-by-Field Classification

### Category A: Moved to TurnExecutionInput (Neutral/Canonical)

| Field | Type | Reason | Usage in Turn Loop |
|-------|------|--------|-------------------|
| turn_id | u64 | Turn identity, never vendor-specific | Tracing, step tracking, coordinator identity |
| delivery | PromptDelivery | Routing classification (ordinary/continuation) | Message construction, context loading, steering |
| prompt | []u8 | User request text | User message construction, skill invocation, completion request |
| images | []ImageAttachment | Vision request attachments | Vision processing, model request body |
| authorized_image_catalog | []ImageAttachment | Additional image options for vision | Vision fallback processing |
| model | []u8 | Model selection (configuration) | Capability resolution, routing, recovery identity |
| provider | ProviderId | Provider routing (configuration) | Route selection, history replay, recovery identity |
| history | []HistoryTurn | Conversation context | Message construction, context loading, history projection |
| unversioned_history_count | usize | History consistency metadata | History range calculation, versioning |
| grants | []PermissionGrant | Neutral permission configuration | Permission grant tracking |
| root_user_intent_context | []u8 | User context for permission review | Permission auto-classification (not security) |
| context_snapshot | GatheredContextSnapshot | Workspace/project context | Context construction, file references |
| agent_settings | AgentTurnSettings | Runtime settings (effort, tool choice) | Request construction, model capability validation |
| skill_bindings | []SkillBinding | Skill definitions | Skill prompt construction |
| skill_display_spans | []SkillDisplaySpan | Skill display metadata | Skill rendering |
| snapshot_file_ownerships | []SnapshotFileOwnership | File ownership metadata | File mutation tracking |
| recovery_checkpoint | ?RecoveryCheckpoint | Resume/recovery state | Recovery state machine, checkpoint validation |
| recovery_source_already_presented | bool | UI state tracking | Output presentation logic |
| user_prompt_already_presented | bool | UI state tracking | Output presentation logic |
| steering_receipt | ?*SteeringReceipt | Priority/cancellation coordination | Step boundary checks |

### Category B: Excluded from TurnExecutionInput (Compatibility-Only)

These fields remain in `CompatibilityExecutionJob` and are accessed only through explicit `execution_compatibility` functions:

| Field | Type | Reason | Compatibility Operations |
|-------|------|--------|--------------------------|
| api_key | []u8 | **Authentication credential** — never crosses turn boundary | `initialSecret`, `credentialLease`, `modelRequestLease`, `refreshCredential`, `releaseSecret` |
| credential_source | ?CredentialSource | **Auth classification** — account/provider identity | `credentialLease`, `refreshCredential`, `replayDecision`, `validateRecovery`, `recoveryIdentity`, `publishHttpError` |
| account_id | ?[]u8 | **Account/billing identity** — vendor/subscription data | `credentialLease`, `refreshCredential`, `validateRecovery`, `recoveryIdentity`, `copyAuthorityForTurn`, `configureSideCall` |
| gateway_team | ?[]u8 | **Tenant/subscription state** — vendor control plane | `credentialLease`, `copyAuthorityForTurn`, `configureSideCall` |
| permission_mode | PermissionMode | **Policy state** — account-bound execution mode | Accessed via `permissionModeForAction` in orchestrator (compatibility wrapper, not turned into TurnExecutionInput field) |
| steering_receipt | ?*SteeringReceipt | Borrowed from job for coordination | Included in TurnExecutionInput (borrowed, no ownership change) |

## Why Model and Provider Are Included

`model` and `provider` appear to be vendor-specific, but they are **configuration data**, not **authorization data**:

- Used for capability checks: `deps.available_model_capabilities(deps.ctx, job.model)`
- Used for routing decisions: provider capabilities, vision fallback
- Used in recovery semantic identity: Checkpoint contains `provider` and `model`
- Never used for credential resolution, billing, or account classification

The turn loop must know which model/provider it's executing to handle capabilities, recovery, and routing. This is runtime configuration, not vendor authorization.

## Why permission_mode Is Excluded

`permission_mode` is policy state that:
- Depends on account/subscription level
- Can change between turns based on credentials
- Is accessed via wrapper functions (`permissionModeForAction`) in the orchestrator
- Is not a neutral field since its value has security implications

The turn loop receives permission mode decisions through compatibility operations, not as a direct field.

## Boundary Enforcement

The `TurnExecutionInput` type definition in `src/core/agent/turn_execution_input.zig` is the sole enforcement mechanism:
- Any field whose name contains "credential", "account", "team", "auth", or "secret" cannot be added to the type
- The test suite validates this at compile time
- No runtime checks needed; the type itself prevents crossing

## Compatibility Function Usage

All Category B operations continue to work exactly as before:
- No behavior changes
- No new logic
- No new allocation/ownership patterns
- Functions remain in `execution_compatibility.zig`
- Called from orchestrator with the full `CompatibilityExecutionJob`

Example compatibility function that reads multiple Category B fields:
```zig
pub fn credentialLease(secret_value: []const u8, job: CompatibilityExecutionJob) types.CredentialLease {
    if (job.credential_source == .host_managed) return .host_managed;
    return .{ .direct = .{
        .secret_bytes = secret_value,
        .source = job.credential_source,
        .account_id = job.account_id,
        .tenant_context = job.gateway_team,
    } };
}
```

This function reads three Category B fields (`credential_source`, `account_id`, `gateway_team`) and produces a typed lease for use in the turn loop. The lease construction is the boundary; the raw fields never cross.

## Testing Coverage

### Type-Level Tests (turn_execution_input.zig)
- Projection excludes all auth-related field names
- Borrowed slices maintain pointer identity
- Recovery and UI state flags are preserved
- Optional fields handle null correctly

### Integration Tests (turn_execution_input_tests.zig)
- Job-to-input projection is zero-allocation
- All Category A fields are preserved through projection
- No Category B fields appear in the type definition
- Input can be constructed independently of CompatibilityExecutionJob

### Existing Test Coverage
- Compatibility operation tests unchanged (execution_compatibility.zig)
- Orchestrator tests unchanged (tool_flow.zig)
- Integration tests unchanged (support.zig)

## What This Boundary Enables

1. **Clear data flow**: Turn loop receives work via `TurnExecutionInput`, auth via compatibility functions
2. **Type safety**: Impossible to accidentally pass credentials into turn logic
3. **Future neutralization**: Other vendor-specific data (provider transport, completion format) can follow the same pattern
4. **Testability**: Can test turn logic with mock `TurnExecutionInput` without credentials

## What This Boundary Does NOT Do

- Does not eliminate provider/model dependencies
- Does not introduce new authentication logic
- Does not change how credentials are refreshed or leased
- Does not abstract away the host/control-plane contract
- Does not claim "vendor neutral execution" — only that the turn loop receives a neutral *input* boundary

## Future Boundaries

As other data crosses the orchestrator boundary, follow this pattern:
1. Create a neutral type for the data
2. Add a projection function in `execution_compatibility`
3. Pass the projection to the turn orchestrator
4. Keep the full compatibility job available for compat operations
5. Document the field classification and rationale
