# Neutral stop-dispatch control

This slice extracts only the once-per-turn dispatch latch from `CommonStopState`. It does not introduce a general loop outcome or make stop/finalization handling neutral.

## Inspection classification

Every `CommonStopState` field and its uses were inspected:

| Field | Classification | Reason |
| --- | --- | --- |
| `dispatched` | Neutral control | Two successful dispatch sites set it; four branch checks prevent redispatch and choose steering boundary timing |
| `retained_candidate` | History/result materialization | Retains assistant text for terminal fallback, continuation and interrupted persistence |
| `latest_partial` | Stream/content materialization | Stores the latest partial assistant content for retained-candidate failure output |
| `terminal_materializing` | Finalization/persistence | Prevents duplicate terminal materialization while persistence/finalization effects run |

Stop dispatch itself uses `lifecycle`, assistant text, provider disposition, allocator-owned outcomes and hook continuation messages. These remain transitional execution state. Model failure diagnostics and candidate materialization elsewhere in the loop also remain outside.

## Extracted type

`core/agent/stop_control.zig::StopControl` imports only std and owns one boolean, `dispatched`, initially false. `needsDispatch` reads the latch; `markDispatched` sets it idempotently.

The authoritative owner is `CommonStopState.control`, created alongside the existing per-turn materialization state in `processQueuedPromptInner`. This is the natural construction point because no host/job projection supplies this fresh latch. No compatibility constructor or duplicated latch is needed.

At both existing successful stop-checkpoint return points, the loop calls `markDispatched` in place of setting the old boolean. Cancellation/error branches still return or continue before marking. Branch checks use `needsDispatch` with the same polarity as before. The loop does not reset the latch after a continuation, preserving existing once-per-turn behavior.

Cancellation and turn identity remain in the existing LoopControl/TurnCoordinator. StopControl contains no copies or links to them, no hook result, no retained candidate, no provider state, no job/deps/config, no recovery/history/persistence, and no opaque context. It allocates nothing.

## Dependency and ownership

Before: CommonStopState directly owned dispatch latch alongside response-materialization fields.

After: CommonStopState owns a typed neutral StopControl plus unchanged materialization fields; the loop reads and updates that one control value. The new module compiles independently without importing the application or legacy execution types.

The existing loop-control, coordinator, compatibility job, deps/config, lifecycle/finalization, conversation/result/persistence, recovery, transport and other transitional environment remain explicit. This does not change loop order, retries, attempts/steps, steering, continuation, tools, streaming, cancellation timing, recovery, compaction or finalization behavior.

## Validation limits

Independent tests verify the exact single-boolean surface, initial dispatch eligibility, idempotence and the rule that cancelled dispatch does not mark the latch. Existing affected orchestrator finalization/interruption/gateway-flow and Agent/worker tests exercise actual stop dispatch, continuation, cancellation/steering and materialization behavior. The real-binary configured-provider suite retains the coding loop and streaming/error regressions.

The whole-agent guard is unchanged; observed before/after diagnostic is 1,509 → 1,509. New neutral control introduces no forbidden dependency; existing compatibility/provider/history/recovery/usage closures still remain reachable. The guard is not altered or optimized for its count.

The known broad allocation-sweep failure at unchanged tool_host.zig:938 remains out of scope. No broad allocation-sweep, full repository suite or exact Linux/macOS CI success is claimed. fx is not fully neutral and PR3 remains incomplete.
