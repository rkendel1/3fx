# Legacy execution operations at the compatibility boundary

This slice keeps the legacy execution algorithm and `CompatibilityExecutionJob` entry point intact. It isolates the auth and account operations that previously prevented a truthful neutral-input projection. It does not complete PR3 or introduce a neutral orchestrator input yet.

## Operations and captured fields

All operations are explicit typed functions in `core/app/execution_compatibility.zig`, not an opaque context, identity bag, or new provider contract.

| Operation | Captured fields read inside compatibility | Effect or result |
| --- | --- | --- |
| `initialSecret` | `api_key` | Borrow the captured key for the existing request loop |
| `credentialLease` | `credential_source`, `account_id`, `gateway_team` | Existing review/tool lease, preserving null source or host-managed authorization |
| `modelRequestLease` | Same fields | Existing primary model lease, including its API-key-source default when source is absent |
| `refreshCredential` | `credential_source`, `account_id` | Invoke the existing refresh callback; replace/zero the owned rotated key; preserve reconciliation and trace effects |
| `replayDecision` | `credential_source` | Existing replay policy from explicit rejection/delivery-safety/already-replayed facts |
| `replaceLeaseSecret` | No job fields | Update the existing direct request lease after successful refresh |
| `validateRecovery` / `rejectRecovery` | `credential_source`, `account_id` | Existing potentially-sent account/source authority check and exact rejection error |
| `recoveryAuthority` / `recoveryIdentity` | `provider`, `credential_source`, `account_id` | Existing checkpoint authority projection |
| `copyAuthorityForTurn` | `account_id`, `gateway_team` | Preserve the previous arena-owned copies while borrowing the other existing job fields |
| `configureSideCall` | `credential_source`, `account_id`, `gateway_team` | Populate only authorization fields in the existing side-call caller |
| `publishHttpError` | `credential_source` | Preserve selected-source error presentation |
| `buildReviewTurnContext` | No job fields | Preserve the existing typed review context construction using a compatibility-produced lease |
| `releaseSecret` | No job fields | Existing zero-and-free cleanup |

`refreshCredential` was moved without changing callback precedence, swallowed versus propagated errors, refresh modes, reconciliation behavior, or old/new key lifetime. Replay control flow remains in the orchestrator; it receives a typed decision, calls refresh, and performs the same single replay under the same conditions. It does not decide which captured source is refreshable or modify lease internals itself.

The original recovery-authority test moved alongside its unchanged implementation. Recovery policy, checkpoint schema, identity derivation, and retry budgets are not redesigned.

## Orchestrator changes

The orchestrator no longer imports `auth_transition`, `credentials`, `credential_authority`, or `secret`. It does not directly read `api_key`, `credential_source`, `account_id`, or `gateway_team` from the job. Lease construction, refreshability, refresh effects, identity derivation, source-bound error presentation, and authority comparisons cross the named compatibility functions.

The provider request and permission/tool execution APIs still receive their existing legacy lease values. Those values are now produced by compatibility operations, not constructed by destructuring the job in the orchestrator. No hidden pointer or generic context carries a replacement execution job.

The account/team copies still happen in the turn arena. The projection has explicit partial-allocation cleanup so its ownership is testable independently of that arena. All other job resources remain borrowed exactly as before.

## What remains before a neutral input

Already isolated:

- Captured-key acquisition and model/review/tool lease construction.
- Refresh callback selection, key transfer/cleanup, refresh reconciliation, and replay eligibility/lease replacement.
- Account-bound recovery authority and checkpoint-authority projection.
- Authorization projection for existing side calls and error presentation.

Still directly legacy:

- `processAgentPrompt` and internal helpers still accept `worker_runtime.CompatibilityExecutionJob`.
- `job.provider` is read for provider-specific capability/options, replay source identity, network records, gateway-only branches, and route recovery.
- `job.model`, `job.agent_settings`, and `config` still include legacy model routing/tier controls.
- `job.history`, images/catalog, grants, context, skills, recovery checkpoint, and associated shared message/completion/continuation types still have legacy dependency closures.
- `deps.agent_stream_provider`, `ModelRequest`, `streamModelCompletion`, and result/completion types remain transitional provider contracts.
- `deps.usage` / `usage_allocator`, completion billing/service-tier metadata, invocation observation, and deferred usage remain control-plane dependencies.
- Vision/compaction and recovery/finalization interfaces still use existing contracts. This slice only changes where their authorization fields are projected, not their implementation or policy.

Already neutral concepts, though some are currently represented in shared legacy modules:

- Prompt text, turn ID, `PromptDelivery`, cancellation flags, tool call/result scheduling, semantic attempt and step counters, steering order, finalization control flow, and the canonical `TurnState` token measurements.

Therefore the next neutral-input migration is smaller but still requires provider identity/replay, shared conversation/recovery types, and downstream invocation/result contracts to cross typed boundaries. This slice does not claim that only an entry-point signature change remains.

## Guard and validation

The strict whole-agent guard is unchanged: 1,509 before and 1,509 after. The orchestrator's four direct auth imports and direct account/key/source/team field operations are removed, but the same implementations are now reachable through `execution_compatibility`, and other host/control-plane dependencies remain reachable through `runtime/deps`, worker jobs, shared types, and session/subagent imports. No guard roots, patterns, categories, or exclusions changed.

Focused tests cover lease defaults, host-managed behavior, captured model/account/team authority, refresh source/account/mode, owned key rotation, non-refreshable sources, safe versus unsafe replay, and partial-allocation cleanup. Existing orchestrator tests retain pre-request refresh, 401 replay, account-change rejection, recovery authority, cancellation, retry, tool flow, and finalization coverage. The configured-provider suite repeats the real-binary coding loop and streaming/error regressions.

The known broader allocation sweep failure in unchanged `tool_host.zig:938` remains out of scope. No successful full repository suite or broad allocation-failure sweep is claimed.
