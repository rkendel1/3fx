# Neutral turn execution input boundary

This boundary sits between `CompatibilityExecutionJob` (host compatibility layer) and the turn orchestration loop. It contains only workload and configuration data; all authentication, authorization, account/billing, and provider-control-plane state remain in the compatibility layer.

## Purpose

The turn execution loop requires:
- Turn identification and delivery routing
- User request text and attachments
- Conversation history for context
- Model and provider routing (configuration, not authorization)
- Permission configuration and context
- Workspace context and settings
- Recovery/resume state
- UI state for already-presented content

The turn execution loop does NOT need:
- API credentials (api_key)
- Credential source or identity (credential_source, account_id)
- Tenant/subscription state (gateway_team)
- Billing or usage tracking
- Provider-specific control-plane objects

## Type definition

`TurnExecutionInput` is defined in `src/core/agent/turn_execution_input.zig`.

### Included fields (Category A - neutral/canonical)

- **turn_id**: u64 — Turn identity for tracing and coordination
- **delivery**: PromptDelivery — Routing (ordinary, active_turn, continuation)
- **prompt**: []u8 — User request text
- **images**: []ImageAttachment — Request attachments
- **authorized_image_catalog**: []ImageAttachment — Additional image options
- **model**: []u8 — Model selection (runtime configuration, not auth)
- **provider**: ProviderId — Provider routing (configuration, not auth)
- **history**: []HistoryTurn — Conversation context
- **unversioned_history_count**: usize — History consistency marker
- **grants**: []PermissionGrant — Permission configuration
- **root_user_intent_context**: []u8 — Context for auto-classification (trusted only for permission review scoping, never for security decisions)
- **context_snapshot**: GatheredContextSnapshot — Workspace/project context
- **agent_settings**: AgentTurnSettings — Runtime settings (effort, tool choice, etc.)
- **skill_bindings**: []SkillBinding — Skill integrations
- **skill_display_spans**: []SkillDisplaySpan — Skill display metadata
- **snapshot_file_ownerships**: []SnapshotFileOwnership — File ownership tracking
- **recovery_checkpoint**: ?RecoveryCheckpoint — Resume/recovery state (optional)
- **recovery_source_already_presented**: bool — UI state
- **user_prompt_already_presented**: bool — UI state
- **steering_receipt**: ?*SteeringReceipt — Priority/cancellation coordination (borrowed)

### Excluded fields (Category B - compatibility-only)

These fields remain in `CompatibilityExecutionJob` and are accessed only through explicit `execution_compatibility` functions:

- **api_key**: []u8 — Authentication credential (never crossed to TurnExecutionInput)
- **credential_source**: ?CredentialSource — Auth classification
- **account_id**: ?[]u8 — Account/billing identity
- **gateway_team**: ?[]u8 — Tenant/subscription state
- **permission_mode**: PermissionMode — Policy state (accessed through compatibility operations)

### Why model and provider are included

`model` and `provider` are configuration, not authorization. They are:
- Used for capability resolution and request routing
- Not credentials or account identifiers
- Necessary for the turn loop to understand its own execution environment
- Used in recovery authority projection for resume semantic identity, not billing

`permission_mode` remains in the compatibility layer because it represents policy decisions that may change between turns and involve account/credential state.

## Boundary operations

The projection is created by `execution_compatibility.turnExecutionInput(job)`:
- No allocations; all slices are borrowed
- One-directional transformation
- No mutation of source or projection
- Type-safe: the new type's definition itself enforces what is absent

Compatibility-only operations continue to receive the full `CompatibilityExecutionJob`:
- `initialSecret`, `credentialLease`, `modelRequestLease`
- `refreshCredential`, `replayDecision`
- `validateRecovery`, `recoveryAuthority`, `recoveryIdentity`
- `copyAuthorityForTurn`, `configureSideCall`, `publishHttpError`
- `buildReviewTurnContext`, `releaseSecret`

These operations remain unchanged in behavior, implementation, or call patterns.

## Turn orchestration flow

1. Host worker enqueues `CompatibilityExecutionJob`
2. Compatibility boundary projects `TurnExecutionInput` via `execution_compatibility.turnExecutionInput(job)`
3. Turn orchestrator receives both:
   - `TurnExecutionInput` — neutral workload and configuration
   - `CompatibilityExecutionJob` — for auth/account compatibility operations
4. Turn loop uses neutral input for execution logic
5. Turn loop calls compatibility functions for auth/recovery/billing operations
6. Neither TurnExecutionInput nor its projection contains credential/account state

## Migration status

This PR establishes the first neutral subset of execution state. Complete vendor neutralization would require:
- Full provider identity/routing abstraction
- Conversation/recovery message type abstraction
- Completion/tool-result contract neutralization
- Provider transport envelope abstraction
- Usage/billing/control-plane contract redesign

This boundary does not attempt those larger refactorings. It demonstrates the pattern for extracting neutral data at architectural seams without dragging provider/control-plane coupling across them.

## Diagnostics and validation

The `TurnExecutionInput` type definition is self-documenting: any field whose name contains "credential", "account", "auth", "billing", "team", or "secret" is rejected at compile time by the test suite.

The compatibility operations remain unchanged and continue to handle all authorization workflows. No new auth logic was introduced; the boundary only clarifies what the turn loop actually needs to know.
