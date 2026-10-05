# Neutral loop-control boundary

This slice introduces `core/agent/loop_control.zig::LoopControl` without making the complete loop, its execution input, or `processAgentPrompt` neutral.

## Verified fields

The type contains exactly:

- `coordinator: *TurnCoordinator`, borrowing the existing authoritative neutral state.
- `current_step_index: usize`, owning the loop's last-entered one-based step index, initially zero.

The current index is distinct from the coordinator's zero-based loop counter: the loop retains it when reporting or finalizing outcomes, including when the counter advances at the loop increment. Its assignments occur in the same locations as the previous local variable.

The type imports only std and the existing neutral coordinator. No coordinator fields are copied. Turn identity, cancellation, delivery, attempts, steps and limits still have one owner in `TurnCoordinator`. Its `TurnState` link still points to the existing Agent owner.

## Signature audit

`processQueuedPromptLoop` has one production caller, `processQueuedPromptInner`. The signature audit classified:

- Verified neutral control: the coordinator pointer and the local current-step index. These are the only values extracted here.
- Host/model environment: compatibility execution job, runtime deps/config, request capabilities and model/provider invocation state. These remain outside.
- Transitional execution and presentation: semantic presentation, lifecycle, finalization, prepared skills and tool-advertisement flags, arena, stable/history/suffix message projections, overlay arena, grants, completed tool names, summary accumulator, finish trace, interrupted-persistence flag, current user message, stop state and Agent. These remain separate parameters.

Stop state retains model-failure diagnostics, partial assistant data, tool terminals and candidate materialization. Lifecycle/finalization references shared outcome and persistence/presentation types. The interrupted-persistence flag represents whether history publication occurred, not a standalone neutral cancellation state. Their current closures do not justify placing them in a neutral control type.

## Production ownership

`execution_compatibility.loopControl` receives the already-projected neutral coordinator. It reads no compatibility job or host configuration, allocates nothing and returns the borrowed pointer plus a zero current-step index.

`processQueuedPromptInner` owns this loop-control value and passes its pointer to the loop. The loop signature replaces its separate coordinator parameter with `control: *LoopControl`. The old `current_step_index` local is removed. All coordinator and index accesses now use that single explicit control boundary.

Before:

```text
compatibility projection → coordinator → loop
loop-local current_step_index
legacy environment alongside
```

After:

```text
compatibility projection → LoopControl → coordinator
                                     → owned current_step_index
                          → loop
legacy environment alongside
```

No loop ordering, attempt/step mutation, cancellation check, retry, steering, continuation, scheduling, stream, finalization, recovery or compaction policy is changed. No generic execution context, optional-field bag, opaque pointer or copied legacy job is introduced.

## Remaining dependencies and validation limits

The loop still explicitly accepts the compatibility job, deps/config, capabilities, skills, lifecycle/finalization, allocator, legacy conversation projections, grants, tool names, presentation/trace/interruption/stop state and Agent. Provider/auth/control-plane effects remain reachable through those dependencies. A fully neutral input still requires typed boundaries for history/replay/recovery, transport/results, permissions/context, model options, usage, vision/compaction and finalization effects.

The unmodified whole-agent guard reports 1,509 before and after. The new neutral module adds no forbidden dependency; the existing host/model/transitional closure remains reachable. No guard exclusions or pattern changes were made.

Independent type tests verify the exact field types, authoritative coordinator link, identity, cancellation, attempts, steps, continuation and current-step index. Projection tests verify pointer identity and zero initialization. Existing orchestrator/Agent/worker tests retain retry/steering/scheduling/finalization and relevant passing allocation-failure coverage. No allocation is introduced by this type or projection.

The known broad allocation-sweep abort at unchanged `tool_host.zig:938` remains out of scope. No full repository suite, broad allocation-sweep or required Linux/macOS CI success is claimed. PR3 remains incomplete.
