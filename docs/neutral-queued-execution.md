# Neutral queued work and execution snapshots

## Queue contract

`core/agent/queued_turn.zig::QueuedTurn` is the sole item stored in `WorkerRuntime.queued_prompts`. It contains four fields:

- `turn_id`: the existing turn identity.
- `prompt`: owned prompt text.
- `delivery`: the existing neutral `PromptDelivery` union.
- `execution_snapshot_id`: a typed `ExecutionSnapshotId`, containing a process-local numeric reference.

This module imports only the neutral turn-state module. It does not contain credentials, model selection, account identity, provider identity, history, recovery objects, or a generic metadata container. The worker calls it `NeutralQueuedTurn`; that alias points to the actual neutral type, not a legacy object.

## Host-owned execution snapshot

The worker runtime owns `execution_snapshots`, a typed map from `ExecutionSnapshotId` to `ExecutionSnapshot`. It is local to that runtime, protected by the existing worker mutex, and released at runtime teardown. It is not a global cache, a persistence layer, or part of the model-provider contract.

`ExecutionSnapshot` explicitly stores all remaining compatibility-job fields:

- `steering_receipt`.
- `images`, `authorized_image_catalog`.
- `model`, `provider`, `api_key`, `credential_source`, `gateway_team`, `account_id`.
- `permission_mode`, `grants`.
- `history`, `unversioned_history_count`.
- `root_user_intent_context`.
- `skill_bindings`, `skill_display_spans`.
- `context_snapshot`, `agent_settings`.
- `snapshot_file_ownerships`.
- `recovery_checkpoint`, `recovery_source_already_presented`, `user_prompt_already_presented`.

`CompatibilityExecutionJob` (formerly `QueuedPrompt`) is now exclusively a resolved execution shape, not ingress or a queue item. Existing producers capture neutral `Submission` and a typed `ExecutionSnapshot` separately; admission stores those without copying or rereading current configuration. See [Neutral submission](neutral-submission.md).

The history policy is unchanged: the worker's existing shared `queued_history` holds canonical queued history, while stored snapshots have an empty history slice. Dequeue supplies the existing updated history snapshot to the compatibility job.

## Snapshot semantics

Model, auth, account, permission, recovery, context, image, and skill data originate from the submitted job. Dequeue does not reconstruct them from the host's current state.

The existing explicit queued-model, permission, grants, settings, routing, and history synchronization APIs remain effective. They now update the typed execution snapshot instead of a queue item. Consequently these snapshots are not immutable: explicit queue synchronization still has exactly its prior behavior. Merely changing current host configuration without calling a synchronization API does not replace captured configuration.

## Lifetime and conversion boundary

1. Enqueue reserves queue and snapshot-store capacity before transferring ownership. Allocation failure leaves the caller owning the original job.
2. The worker assigns a monotonically increasing snapshot ID and inserts the typed snapshot alongside the neutral FIFO entry.
3. At `takeNextPromptLocked`, after preparing the existing begin-prompt event, `consumeExecutionSnapshot` removes the stored snapshot, and `core/app/execution_compatibility.zig::resolve` assembles the legacy execution job. The returned job owns the slices and references until the existing `freeQueuedPrompt` cleanup.
4. Steering consumption, removal, retraction, clearing, and teardown also consume the corresponding snapshot and free its captured resources directly, without assembling an execution job. No snapshot is left behind after its queue item is removed.
5. Active execution and retries use the already-resolved job, not the snapshot store or current host configuration.

The legacy turn orchestrator still receives `QueuedPrompt`. Moving that consumer to neutral model types is a later extraction. This queue change does not alter provider adapters, authentication, billing, recovery, compaction, vision, tools, MCP, TUI, or session-storage behavior.

## Verification

Focused production-worker tests cover typed queue shape, captured configuration A versus changed current host model/settings B, FIFO, continuation, cancel reset, snapshot resolution, removal, clearing, and existing steering/queue allocation-failure behavior. The configured-provider integration suite continues to exercise the real binary's coding loop and streaming/error regressions.

The whole-agent guard is unchanged: before 1,506 violations; after 1,509 violations. The neutral queue module introduces no forbidden dependency. The execution snapshot and existing downstream orchestrator still legitimately reach legacy auth, identity, history/recovery, and control-plane types, so removing data from the FIFO does not by itself remove those modules from the whole-agent dependency closure.

The remaining mutually exclusive categories are credential/auth concepts (698), legacy/auth imports (232), team concepts (176), subscription concepts (150), upgrade concepts (119), account concepts (102), billing concepts (31), and vendor concepts (1). The queue's stored type carries none of them; its owning host worker and compatibility execution path still do. This does not complete PR3.


## Explicit compatibility boundary

`worker_runtime.CompatibilityExecutionJob` is a real renamed struct, not an alias hiding `QueuedPrompt`. All consumers and cleanup calls use its explicit name. The legacy orchestrator's algorithm is unchanged.

`takeNextPromptLocked` is the only production call to `execution_compatibility.resolve`. It passes the neutral item and the consumed typed snapshot by value. This mapping allocates nothing, rereads no current state, and retains the captured slices and references for existing execution/retry cleanup.

Discard paths use `releaseQueuedTurn` and resource cleanup directly, so no compatibility execution job is reconstructed for queue removal, retraction, steering consumption, clearing, or teardown.

The guard reports three additional per-file concepts because the explicit conversion module references the existing account, credential-source, and team fields. It does not introduce new identity state. Neither the guard nor the neutral queue dependency closure changed.

Legacy host submission APIs now accept neutral work plus a separate typed snapshot. `CapturedSubmission` is a host capture result, not an alias or replacement execution job. Synchronous CLI, ACP, and child-agent entry points also pass through admission/dequeue before the compatibility resolver. See [Neutral submission](neutral-submission.md) for ownership and the remaining whole-agent boundary.
