# Neutral turn coordination state

This preparatory slice names and owns a small set of neutral execution state. It does not change `processAgentPrompt` into a neutral entry point, replace the legacy execution environment, or complete PR3.

## State classification

Inspection of `processQueuedPromptInner` and `processQueuedPromptLoop` identified:

- Neutral coordination: effective turn identity, delivery/continuation classification, cancellation flag, Agent turn state, semantic attempt count/budget, step count, and step limit.
- Host/model state: provider/model selection, routing and fast/service-tier options, captured authorization, account/team identity, reconciliation, and recovery authority.
- Transitional execution state: history/messages, images/catalog, grants/context/skills, recovery checkpoint, completion/result/replay types, request capabilities, provider transport, compaction, vision, and finalization presentation structures.

Only the first small set moves into the coordinator. Tool scheduling caches and richer recovery/steering state retain their current types and locations because their dependency closures are transitional. No parallel tool or message structures are introduced.

## Neutral type

`core/agent/turn_coordinator.zig::TurnCoordinator` contains exactly:

- `turn_id: u64`.
- `delivery: PromptDelivery`.
- `turn_state: *TurnState`.
- `cancel_flag: *std.atomic.Value(bool)`.
- `attempt: usize`.
- `attempt_limit: usize`.
- `step: usize`.
- `step_limit: usize`.

It imports only the standard library and `turn_state.zig`, whose model reference is the canonical neutral contract. No job, host callback, provider identity, auth, account, billing, history, checkpoint, or generic metadata is stored.

`turn_state` and `cancel_flag` borrow their existing authoritative owners; the coordinator does not copy or reinitialize them. The coordinator owns attempt/step counters and limits. There are no duplicate local semantic-attempt, semantic-limit, or step variables beside it.

## Production ownership

`execution_compatibility.coordinator` projects identity and delivery from the effective captured job and borrows existing Agent turn state and cancellation. `processQueuedPromptInner` constructs this value once, uses its delivery for continuation classification, and passes its pointer to `processQueuedPromptLoop` in place of the old turn-ID argument.

The inner loop uses that same coordinator for turn identity, cancellation checks, step limits, semantic budget/counter, and step counter. Existing checkpoint-derived budget/count decisions assign the coordinator fields where the previous locals were initialized. Retry branches mutate the same attempt field. The loop increment mutates the same step field in the same place as before.

Algorithm order, attempts, callback timing, queue/submission representation, ownership of captured resources, streaming, tools, retry, recovery, compaction, cancellation, and finalization policy are unchanged. No new generic execution context is introduced.

## Remaining environment

The loop still explicitly accepts the captured `CompatibilityExecutionJob`, runtime deps/config, capabilities, prepared skills, lifecycle/finalization, arena, message/history/suffix projections, local grants, completed tool names, summary/trace state, interrupted-history status, stop state, and Agent. Its surrounding functions still use shared legacy types.

Provider identity and options, recovery checkpoint interpretation, messages/history/replay/images, permissions/context/skills, transport requests/results, usage reconciliation, vision/compaction, and finalization effects remain blockers to a fully neutral execution input. This slice does not hide them in the coordinator or claim a neutral loop.

## Validation scope

Independent coordinator compilation tests the neutral dependency boundary, borrowed cancellation/state links, continuation, and counter ownership. Compatibility projection tests preserve identity, delivery, state/cancel pointers, limits, and initial counters. Existing focused orchestrator/Agent/worker tests cover semantic retries, step budgets, steering, tools, recovery/finalization, captured configuration and passing allocation-failure cases. The configured-provider integration suite exercises the real binary coding loop and stream/error regressions.

The whole-agent guard is unchanged: 1,509 before and 1,509 after. Existing legacy job/deps/shared-type and compatibility dependency closures remain reachable. No exclusions or pattern/category changes were made.

The known broad allocation-sweep abort at unchanged `tool_host.zig:938` remains out of scope. No full-suite or required Linux/macOS CI success is claimed.
