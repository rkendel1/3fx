# Payload-free steering decision

`core/agent/steering_decision.zig::SteeringDecision` is an enum containing exactly the existing worker classifications: `none`, `continue_turn`, `handoff`, and `interrupt`. `none` is retained because no pending guidance is a distinct existing result. No new outcome or meaning is introduced.

The module imports only std. It contains no payload fields, queue references, callbacks, job/context, model/provider/auth/account/permissions, history/results, recovery, finalization or control-plane data.

## Projection and ownership

The existing `worker_runtime.SteeringBoundaryResult` union is unchanged in shape. Only `continue_turn` contains guidance (`[][]u8`). Its new `decision()` method projects the tag into the neutral enum without allocation, mutation, copying guidance or transferring ownership.

Worker admission/steering classification and dequeue/removal remain unchanged. `takeSteeringBoundaryInto` still allocates the guidance with the supplied result allocator; existing callers retain their existing arena/free obligations. Handoff leaves the queued work in place. Decision values may be copied independently, but do not extend guidance lifetime.

The three orchestrator helper consumers (`observe_steering_boundary`, `append_pending_steering_after_assistant`, `append_immediate_steering_after_cancel`) now switch on `boundary.decision()`. Only a `continue_turn` decision reads the existing result's guidance. The same guidance is delivered to the same existing append/materialization functions, with identical branch mappings and ordering.

Before: worker result tag and payload → consumer union switch.

After: worker result → payload-free decision + unchanged owned payload → consumer decision switch and guarded payload access.

No second queue/result hierarchy or generic payload context is introduced. The neutral decision does not own cancellation or delivery; those remain in LoopControl/TurnCoordinator and the existing worker machinery. The richer local SteeringBoundaryAction remains an execution helper mapping: continued, handoff or no action. It is not moved or reinterpreted.

## Preserved semantics

Worker precedence, FIFO, guidance allocation, cancellation reset, steering handoff, continuation, retry, tool scheduling, streaming, recovery and finalization algorithms are unchanged. The production worker result remains the owner/carrier of guidance; only classification consumption crosses the neutral enum boundary.

Tests verify all four enum values, exact field surface, projection of every worker tag, and preservation of guidance pointer/content/ownership. Existing worker/orchestrator interruption/finalization/gateway-flow/Agent tests exercise real steering and queue behavior; the configured-provider suite exercises the real binary coding loop and stream/error regressions.

The whole-agent guard is unmodified. Its count remains diagnostic: the neutral enum introduces no forbidden dependency, while the worker/orchestrator execution environment still reaches legacy provider, shared conversation/recovery, lifecycle and usage types. This slice does not make steering payloads, the orchestrator or fx fully neutral.

The known broad allocation-sweep failure at unchanged tool_host.zig:938 remains out of scope. No full repository suite, broad allocation sweep or exact Linux/macOS CI result is claimed.

Observed guard count: 1,509 before and 1,509 after, with byte-for-byte unchanged guard. Validation: Debug build, 53 configured-provider tests, 511 focused steering/interruption/finalization/gateway-flow/Agent/worker tests, independent module test, formatting/whitespace/public-surface/compactor checks and real-binary PTY smoke all passed. Required CI remains unverified.
