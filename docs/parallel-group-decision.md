# Payload-free parallel scheduling classification

Inspection found one precise neutral scheduling seam: `parallel_execution.leadingParallelGroup` classifies a leading batch as `none`, `read_only`, or `subagent`. These are existing scheduling meanings, not execute/wait/reject outcomes. Permission/admission decisions and execution results are separate and remain unchanged.

## Decision

`core/agent/parallel_group_decision.zig::ParallelGroupDecision` is a std-only enum with those three tags and no fields or payload. It replaces the original `parallel_execution.GroupKind` enum directly; no alias or duplicate enum remains.

`LeadingGroup.kind` uses the neutral enum; `LeadingGroup.len` remains scheduler-owned batch extent. `LeadingGroup.decision()` returns the classification without allocating, mutating, copying calls, or transferring ownership. The existing caller still owns the ToolCall slice, names, IDs and arguments. The scheduler continues inspecting active registry metadata and returns the same extent with the same read-only-before-subagent precedence.

The production orchestrator consumes this projection for the existing parallel permission-eligibility switch, subagent completion-observer selection and classification diagnostics. Permission checks, target freshness, minimum parallel size, call preparation and execution stay in their existing paths. `none` means no leading parallel group, not no tool work or permission denial; serial execution remains unchanged.

## Deliberately excluded

Tool invocation data, group length, registry/tool metadata, permissions/grants/live authority, prepared calls, execution callbacks, parallel worker threads, results/history/messages, cancellation, steering, lifecycle/finalization, provider/model/control-plane state and recovery remain outside the enum. No generic execution decision or result/payload bag is introduced.

Before: scheduler-owned LeadingGroup with locally defined kind enum → orchestrator classification branches.

After: existing scheduler-owned LeadingGroup → neutral ParallelGroupDecision plus unchanged extent/call payload → the same orchestrator branches.

No scheduling algorithm, precedence, ordering, ownership, argument handling, permission behavior, tool implementation, result fan-in, retry, continuation, steering, cancellation, streaming, recovery or finalization behavior changes.

## Tests and limits

Tests verify the exact enum tags, all group projections, unchanged group extent, actual scheduler registry classifications, read/subagent/mutation precedence, unchanged argument pointer/content, and caller-owned cleanup. Existing parallel execution and tool/orchestrator/Agent/worker tests cover ordering, cancellation, fan-in and passing allocation failures. The configured-provider suite repeats the real binary coding loop and stream/error regressions.

The whole-agent guard is unchanged. Existing registry/worker/orchestrator/provider/history/recovery/usage dependencies remain reachable; the new std-only enum is not a full scheduling subsystem abstraction. fx and PR3 remain incompletely neutral.

The known broader allocation sweep abort at unchanged tool_host.zig:938 remains out of scope. No full repository suite, broad allocation sweep or exact Linux/macOS CI success is claimed.

Observed validation: Debug build, 53 configured-provider tests, 599 focused parallel/tool/orchestrator/Agent/worker tests, independent neutral enum test, formatting/whitespace/public-surface/compactor checks passed. PTY smoke rendered a localhost response without Authorization; repeated smoke exited 0 after an earlier short poll observed shutdown still in progress. Guard remains 1,509 → 1,509 and is byte-for-byte unchanged. Exact CI remains unverified.
