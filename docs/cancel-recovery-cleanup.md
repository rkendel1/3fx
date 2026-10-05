# User cancellation recovery cleanup ownership

Base: refreshed main 0f1ff72. Move the existing `clearRecoveryCheckpointOnUserCancel` from orchestration to `runtime/interruption.zig`, the existing owner of cancellation/interruption persistence. Only publication changes in its implementation. All five orchestration calls now reference that owner directly. There is no old export, forwarding wrapper, new context, or recovery abstraction.

## Candidate inspection

| Current orchestrator operation | Inputs → output | Mutation / ownership | Callers, dependencies, natural owner |
| --- | --- | --- | --- |
| `clearRecoveryCheckpointOnUserCancel` | Explicit AgentRuntimeDeps → void | Optional synchronous host clear callback; catches/logs errors; no allocation or payload ownership | Five user-cancel branches; existing interruption owner. Selected cleanup effect; caller retains cancellation decision |
| Restored cause/tool evidence/strategy/attempt helpers | Explicit durable checkpoint or field → transient cause/evidence/strategy/count | No allocation; reads reservation/attempt/source fields | Loop resume initialization; session codec and recovery policy. Codec owns persistence, model_response_recovery owns policy; neither currently owns their bridge |
| `recoverySelectionChanged` | Checkpoint plus selected provider/model/modes → bool | No allocation | Resume initialization; authority and provider/model selection. Not selected; auth/provider areas remain out of scope |
| Checkpoint cause/action/tool-state mappings | Transient recovery values → stored status tags | No allocation | Persistence/status/diagnostic dispatch; joins recovery policy and durable/presentation representation. Moving a single mapping would strand its inverse/consumers |
| `persistRecoveryCheckpoint` | Explicit deps/finalization/job/messages/route/attempt/evidence → effect or error | Scratch arena, execution reconstruction, ordered append-piece then checkpoint set | Loop request boundaries; captured authority, session effects, compaction projection. No existing neighboring module owns this entire policy/effect bridge |
| `reset_recovery_after_immediate_steering` | Five mutable state pointers → reset fields | No allocation | Steering branches; ordering couples recovery reset to loop continuation. Leave transition coordination in orchestrator |
| Replay decision and recovery validation/identity | Captured compatibility job and facts/checkpoint → decision/identity/error | Host credential authority and refresh semantics | Already owned by app/execution_compatibility. No move required; auth implementation is out of scope |
| Recovery request construction | Strategy and mutable message list → instruction append | Borrowed static text plus caller list allocation | Loop request preparation; selects recovery/continuation instruction. Previously rejected prompt-policy seam |
| Paused/stalled recovery finishers | Deps, guard, stream state, arena, trace, cause/attempt/action/diagnostic → settlement/error | Provisional statuses, status publication, checkpoint clear, finalization/trace | Recovery terminal branches; spans stream/presentation/finalization policy. Not a single existing owner without moving helper group or redesign |

## Selected boundary and preservation

Interruption already owns persistence of cancelled turns and their presentations. Clearing the resume checkpoint when the user cancels is the complementary cancellation persistence operation. It remains host-specific: `AgentRuntimeDeps.recovery_checkpoint.clear` and `deps.ctx` are explicit. No CompatibilityExecutionJob is hidden or introduced.

Orchestration still chooses when cancellation triggers cleanup. The moved function does not inspect cancellation flags, select retries, interpret authority, choose recovery strategies, or finalize a turn. If no effect exists it returns immediately. If the effect exists it calls once; errors remain swallowed after the same debug message. All call ordering remains unchanged.

The operation allocates nothing and owns no payload. A targeted owner test covers absent effect, successful clear, and failed clear with preserved best-effort behavior. Existing gateway cancellation-during-recovery coverage checks one durable clear and interrupted outcome. No allocation-failure test is needed for this allocation-free operation; surrounding filtered coverage and exact validation results are reported in the PR.

This consolidates an existing cancellation cleanup responsibility, not neutral recovery policy. Known baseline failures, guard rules, queue, auth/provider adapters, storage implementation, and other excluded areas remain untouched.
