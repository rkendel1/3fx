# Assistant terminal finalization ownership

Base: refreshed main 14cfa10. This slice relocates the existing `finishCommonAssistantTerminal` operation from orchestration to `runtime/finalization.zig`. No new context, result type, callback layer, or neutral facade is introduced.

## Inspected operations

All candidates below currently originate in orchestration. Dependencies are visible in signatures or direct calls; none becomes hidden in a new owner object.

| Operation | Responsibility, inputs and output | Mutable state / allocation | Callers and dependencies | Selection |
| --- | --- | --- | --- | --- |
| `finishCommonAssistantTerminal` | Explicit deps/guard/job/messages/summary/terminal text/outcome/disposition/trace/response → terminal publication or error | Builds execution memory and optional unchanged replay in supplied arena; downstream finish owns durable copies and updates guard/summary/trace | Loop terminal paths, retained-candidate failure path, finalization-flow tests; existing finalization owner and execution-memory helper | Selected: natural existing finalization owner |
| `copyLatestStopPartial` | Allocator, stop state, bytes → retained copy or null | Arena copy and latest_partial mutation | Stream/cancellation paths; CommonStopState is still loop-local orchestration state | Moving alone splits ownership of the same state |
| Steering observation/append/handoff | Explicit deps, turn/origin, message lists and stop/finalization state → guidance/action or finalized interruption | Allocated steering messages, callbacks, persisted/terminal flags | Multiple inner/loop boundaries; worker boundary and cancellation/continuation decisions | Not selected: the current dispatch group joins worker observation to loop decisions |
| Pending parallel/prepared cancellation finishers | Explicit calls/results/status flags, config, allocators/deps → settled tool statuses/results | Copies retained tool memory/images and updates presentation/lifecycle | Cancellation branches; parallel execution plus tool result/presentation owners | Not selected: crosses several owners and loop policy |
| Preparation callbacks | Explicit classifier context/call → terminal/preparation result | Caller allocator output, captured deps | Loop preparation; registry, skill/availability/admission checks | Not selected: dispatch adapter still owns policy-bearing deps |
| Provider-result incorporation | Calls/messages/config/deps → execution results and appended history/results | Borrowed provider result, usage reporting, result-memory allocation | Loop and confirmed-provider materialization; presentation/usage/execution owners | Not selected: operation group spans these owners |
| Retry/recovery bookkeeping | Explicit diagnostic/strategy/cause/pacing/evidence or attempt limits → state reset/limit | Mutates existing loop recovery fields; usually no allocation | Immediate steering and provider retry branches; recovery ordering/policy | Not selected: small helpers encode loop transitions rather than independent ownership |
| Compatibility operations | Captured job/authority → credentials, review/recovery configuration, coordinator/control | Captured ownership and secret cleanup | Inner loop; existing app execution_compatibility owner | Already host-owned; do not relocate authority into core |

## Selected operation

The finalization module already owns `TerminalText`, `TurnFinalizationGuard`, `PromptFinishTrace`, `finishAssistantTerminalWithExecution`, and related terminal failure operations. The moved operation builds execution memory, compares presentation/history text, preserves replay only through the existing unchanged-replay helper, then invokes that owner's existing execution-backed finish operation.

Its signature remains unchanged except local module qualification. One local execution-memory value is renamed to avoid shadowing the destination module import. `CompatibilityExecutionJob` remains explicit, including its legacy captured authority; there is no claim of neutrality. No provider, auth, queue, lifecycle implementation, or history-storage implementation is changed.

The sole-use orchestrator `finishCommonAssistantTerminalWithExecution` helper was already a pure forwarding call to `finalization.finishAssistantTerminalWithExecution`. Remove it and invoke that existing function directly from the relocated operation, with the same arguments and try/error behavior. No forwarding alias remains at the old location.

The caller still selects stop outcome, retry, cancellation, steering, and terminal disposition. Orchestration's calls now reference the finalization owner directly. Existing finalization-flow tests update their owner reference; assertions and fixtures remain unchanged.

## Ownership and errors

Execution-memory and replay construction use the supplied allocator, normally the turn arena. Message payload/replay copying behavior is unchanged. The downstream finalization operation retains its own projection arena, C-allocator durable payload duplication, history propagation, guard completion, trace emission, and delayed propagation-error return. The move does not add cleanup, change allocation order, or redesign existing lifetime assumptions.

Existing coverage includes compaction-retained execution followed by a subsequent request, payload allocation failure leaving the guard open for exactly one fallback, propagation/finalization errors, cancellation/steering, and terminal flows. Exact validation results are recorded in the PR description. No broader neutrality, full repository suite, broad allocation sweep, platform CI, or ship-gate success is claimed.
