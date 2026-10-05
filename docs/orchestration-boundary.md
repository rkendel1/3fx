# Remaining orchestration ownership boundary

The mechanical ownership-consolidation pass ends at an intentional orchestration boundary. The remaining cross-step state is not misplaced finalization code. Moving it requires a deliberate lifecycle-ownership decision, not another file move.

```text
runtime/orchestrator.zig
  decides and coordinates the turn lifecycle
  owns CommonStopState across steps and attempts
    control → StopControl: stop-dispatch latch
    retained_candidate / latest_partial: response retention
    terminal_materializing: materialization-path bookkeeping
  invokes runtime/interruption.zig for cancellation persistence and cleanup
  invokes runtime/finalization.zig for selected terminal materialization
```

## StopControl

[`StopControl`](../src/core/agent/stop_control.zig) owns the `dispatched` latch, successful-dispatch bookkeeping, and idempotent dispatch state. `markDispatched` is called after Stop dispatch succeeds, never merely because dispatch was attempted. A cancelled dispatch leaves the latch available.

It does not own retained response text, recovery policy, terminal materialization, or cancellation policy. Orchestration decides when to dispatch and what to do with the hook outcome.

## CommonStopState

[`CommonStopState`](../src/core/agent/runtime/orchestrator.zig) remains orchestration-owned. Its existing fields are:

| Field | Responsibility |
| --- | --- |
| `control` | Holds the canonical StopControl latch. There is no separate `dispatched` field in CommonStopState. |
| `retained_candidate` | Retains an assistant response across execution paths and Stop continuations. Interruption, terminal presentation, failure materialization, and step-limit handling can consume it. |
| `latest_partial` | Retains accepted/interrupted stream text across buffer reuse and attempts while a candidate exists. |
| `terminal_materializing` | Records entry into a materialization path so outer terminal/error handling does not attempt duplicate fallback materialization. It is not proof that finalization succeeded. |

The aggregate is turn-local: `processQueuedPromptInner` constructs it on the stack and passes it to the loop. Its retained text is backed by the turn arena. Candidate text is copied into that arena and also referenced by the conversation suffix. Partial text is copied rather than borrowed from a reusable stream buffer. Replacing or clearing these references does not introduce per-field teardown; the arena releases their storage at turn teardown.

Its lifecycle spans model attempts, tool steps, steering, cancellation, recovery, Stop dispatch, and terminal fallback. It is neither runtime-global nor worker/queue state. It is not directly serialized as an aggregate into recovery checkpoints; existing materializers can copy selected text into durable terminal or interrupted payloads.

Orchestration sets or clears candidate and partial references, marks successful Stop dispatch through `control`, and coordinates terminal entry. Interruption and finalization helpers can update `terminal_materializing` through an explicit pointer. The outer loop error handler reads that flag together with `TurnFinalizationGuard.state` before choosing a fallback.

No one downstream module owns this complete retention and transition lifecycle. Finalization and interruption consume selected values; that consumption does not transfer ownership of the aggregate.

## Interruption ownership

[`runtime/interruption.zig`](../src/core/agent/runtime/interruption.zig) owns established cancellation/interruption persistence and cleanup operations, including `clearRecoveryCheckpointOnUserCancel`.

**Orchestrator decides when; interruption owns how cancellation cleanup is performed.** The cleanup operation receives explicit runtime dependencies, invokes the optional checkpoint-clear effect, and preserves its best-effort error logging. It does not select cancellation, retry, recovery, or continuation policy.

## Finalization ownership

[`runtime/finalization.zig`](../src/core/agent/runtime/finalization.zig) owns already-selected terminal materialization and finalization: terminal text construction, common assistant terminal completion, finalization guards, prompt-finish tracing, terminal payload release, and established finalization cleanup.

Finalization consumes selected orchestration state. It does not own the cross-step lifecycle that chooses, retains, replaces, or abandons response candidates. `TurnFinalizationGuard.state`, finish-trace emission, and CommonStopState's materialization-path flag have different responsibilities and must not be treated as interchangeable completion latches.

## Rule for future ownership work

Do not move an orchestrator operation merely because its final output looks like finalization. If it reads or mutates CommonStopState because it participates in cross-step lifecycle coordination, it remains orchestration-owned until a deliberate architectural decision changes that ownership.

Do not introduce a FinalizationContext, TerminalContext, or equivalent container merely to hide CommonStopState. Do not split the aggregate solely because different consumers read different fields.

### finishFailedTurnWithNotice

`finishFailedTurnWithNotice` was inspected as a potential finalization seam. Its notice and terminal-payload materialization fit finalization responsibilities, but it also reads the retained candidate and marks terminal materialization through CommonStopState. It therefore participates directly in the orchestration-owned lifecycle.

The function is not mechanically relocatable. Moving it unchanged would make finalization depend back on orchestration's state owner. Moving the aggregate or changing the function boundary first would be an architectural decision, not ownership consolidation. Leave the function and state unchanged until that decision is made explicitly.

## Scope

This document records existing ownership; it changes no runtime semantics or architecture-guard rules. It does not claim full agent neutrality or completion of the broader architectural work. The next phase must decide lifecycle ownership before changing these boundaries. Known app_render_runtime.zig:6152 and tool_host.zig:938 issues remain outside this work.
