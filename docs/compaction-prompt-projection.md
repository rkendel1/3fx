# Compaction prompt projection ownership

## Inspected execution path

On refreshed main 66d6cc6, CLI, application, and subagent adapters call `processAgentPrompt`. It establishes effective turn/subagent identities and the finalization guard, then calls `processQueuedPromptInner`. The inner function owns a turn arena, copies captured authority through `execution_compatibility.copyAuthorityForTurn`, establishes coordinator/control, verifies recovery images, projects history, prepares skills and context, and passes existing lists and state pointers to `processQueuedPromptLoop`.

The loop owns mutable request capabilities, grants, retry states, compaction handoff/tail/offset, context delivery, refreshed credentials, summaries, and interruption state. `CompatibilityExecutionJob` still carries captured provider/model/auth, permission, history, recovery, context, and worker delivery data. No new context or neutral job hides that boundary.

## Candidate seams

| Existing owner / operation | Inputs and outputs | State and allocation | Dependencies / callers | Mechanical suitability |
| --- | --- | --- | --- | --- |
| orchestrator: `buildProviderPromptForCompactionWindow` | Explicit message slices, current user message, optional handoff, retained tail, suffix offset → existing `ProviderPrompt` | Temporary history list; owns output list storage only; borrows all message payloads | Existing prompt_context builder; response-language prompt projection calls it from the loop | Selected: relocate to existing prompt_context owner |
| orchestrator: `buildToolExecutionRootUserContext` | Root context and two message slices → allocated review context | Temporary feedback list and owned output | Trusted permission feedback and auto-classifier authority semantics; tool review callers | Small, but belongs to permission interpretation; not selected |
| orchestrator: `reconstructProjectContext` | deps/config/job → optional owned gathered snapshot | Temporary targets, owned snapshot, cancellation checks and pushed notices | Registry, history/recovery target projection, access scope, image applicability; inner preparation caller | Moving unchanged retains the legacy job/deps closure; reducing it requires redesign |
| orchestrator: `appendStablePromptContext` | deps/config/catalog/project bytes and mutable list → appended messages | Caller-owned list storage and borrowed payloads | Host instructions, model overlay, static-context callback and context registry; inner preparation caller | Cohesive assembly, but broad config/deps retain host coupling |
| orchestrator: `commitContextCompaction` | deps, summary, optional prefix/cut → effect or error | Mutates durable state through callback; owns no new payload | Host commit callback or history propagation fallback; compaction callers | Already an explicit effect boundary; relocating does not remove authority |
| app: execution_compatibility operations | Captured job/authority and turn state → copied authority, control, credentials/review/recovery data | Captured snapshot ownership, arena copies, secret cleanup | Worker delivery, auth refresh, recovery and permission review; inner/loop callers | Already host-owned; moving into core would move policy or conceal it |

## Selected move

Relocate the existing `buildProviderPromptForCompactionWindow` to `runtime/prompt_context.zig`, beside its existing `ProviderPrompt` output and `buildProviderPrompt` dependency. Remove the orchestrator definition and call the canonical function directly. The only production changes to the moved definition are publication and removal of now-local module qualification. Its body and API semantics are preserved.

Without a handoff, the existing builder receives the original history and full suffix. With a handoff, a temporary list contains the handoff as a user message followed by the retained tail; the suffix begins at the existing bounded offset. Temporary list storage is released, while output lists retain shallow borrowed message values. Existing output ownership/deinit, allocator error propagation, order, and offsets are unchanged.

The caller still decides whether to compact, which history to retain, and how offsets advance. Response-language policy, retries, cancellation, steering, finalization, and credential handling stay in orchestration. No new type, facade, compatibility alias, provider/session change, or hidden policy is introduced.

This consolidates a real projection under its existing owner. It does not make prompt_context wholly neutral, remove the CompatibilityExecutionJob dependency, or reduce the whole-agent dependency closure. The guard remains diagnostic and unchanged.

## Validation

New focused tests cover null handoff, retained tail, offsets 0/1/end/beyond-end, instruction ordering, borrowed payload pointer identity, and every failed list allocation on those paths. Existing compacted-request and response-language consumer coverage remains in orchestration. Exact validation results and limitations are recorded in the PR description.
