# Neutral submission and host capture

## Admission contract

`core/agent/submission.zig::Submission` is the neutral ingress request. It imports only the neutral turn-state module and contains:

- `turn_id`, defaulting to zero until admission assigns an identity.
- Owned or borrowed `prompt` text, according to the caller's existing lifetime contract.
- Existing `PromptDelivery`, defaulting to ordinary delivery.

`WorkerRuntime.enqueuePrompt`, `admitInteractivePrompt`, and `admitActiveSteering` accept this request and a separate typed `ExecutionSnapshot`. They no longer accept `CompatibilityExecutionJob`.

Host capture helpers may return `CapturedSubmission`, with two explicit fields: `work: Submission` and `snapshot: ExecutionSnapshot`. This is a host ownership carrier, not a neutral agent type, a queued item, or an execution job. Callers pass its fields separately at admission.

Model, provider configuration, credentials, account/team identity, permissions, history/recovery, image catalog, skills/context, and routing settings stay in the host snapshot. Admission reads the same captured values and applies the same explicitly synchronized queue settings as before. Dequeue never rereads current host state.

## Production paths

- Application prompt and recovery entry points capture work and snapshot separately; ordinary and interactive admission submit the neutral request.
- Managed-owner feedback uses neutral work plus its typed captured receipt and resources.
- CLI ask, ACP prompt, and subagent adapter previously constructed the execution job and invoked the legacy orchestrator synchronously, bypassing the worker FIFO. They now call `admitSynchronousSubmission` with neutral work and a typed snapshot.
- App-process, command, worker, and provider-flow fixtures use capture representations for admission. Legacy-execution fixtures remain explicitly test-only.

## Synchronous admission

Synchronous callers retain their existing resource owners: CLI context, ACP prompt/session lifetime, or child-turn arena. `admitSynchronousSubmission` uses a one-shot worker runtime, the same admission API, and the same dequeue method to establish the boundary. It introduces no background thread and does not publish its temporary queue presentation events to the UI.

It copies no model, credential, or prompt buffers. Only temporary queue/map storage is allocated and released after handoff. Begin-prompt presentation events are disabled for this one-shot runtime, avoiding prompt/image copies. Captured input slices remain borrowed from the caller. If admission or dequeue allocation fails, the helper relinquishes those borrowed captures before teardown rather than freeing them. Exhaustive allocation-failure tests cover this contract. The fresh runtime has no stopped worker, active turn, held transition, or finalization fault; only allocation failure can prevent this one-shot admission.

This path adds bounded admission/event allocations to previously direct calls. It does not change the legacy orchestrator algorithm, model invocation, recovery policy, compaction policy, or provider adapter.

## One execution construction boundary

Only `core/app/execution_compatibility.zig::resolve` constructs `CompatibilityExecutionJob` in production. Its only production caller is `WorkerRuntime.takeNextPromptLocked`, after removing neutral work and consuming its captured snapshot. This is also true for synchronous submissions.

Remaining references to `CompatibilityExecutionJob` are its real declaration, legacy consumption/callback types, returned execution values, cleanup, and test fixtures that specifically exercise legacy execution. Test-only constructors include `app_agent_runtime.makeQueuedPrompt` and `runtime/tests/support.PromptFixture.job`; neither is an ingress API in production.

Discard paths still release the neutral queued turn and captured snapshot without constructing a compatibility job. Retries use the already-resolved execution job. Queue FIFO, steering, continuation, cancellation, removal, clearing, teardown, explicit synchronization, and existing shared-history behavior are unchanged.

## Verification and remaining boundary

The production tests exercise neutral submission, admission, typed snapshot insertion, dequeue, exact captured pointers, configuration A versus current configuration B, and cleanup. Worker/Agent tests retain queue allocation-failure, steering, continuation, retry, cancellation, synchronization, and history coverage. Configured-provider tests exercise the real binary's coding loop and stream/error regressions.

The unchanged strict whole-agent guard remains at 1,509 violations before and after this change. The neutral request and queue closure are submission/queued_turn → turn_state → model_provider → std. Host capture still legitimately references auth/provider/history/recovery types; the execution snapshot and legacy orchestrator remain coupled. Those broader control-plane dependencies are not removed or claimed confined to a single module by this ingress extraction.

Remaining mutually exclusive categories: credential/auth concepts 698; legacy/auth imports 232; team concepts 176; subscription concepts 150; upgrade concepts 119; account concepts 102; billing concepts 31; vendor concepts 1. PR3 is not complete.

## Validation limitation

A broader allocation-failure sweep aborted in the unchanged `core/subagent/tool_host.zig` test `subagent yielded identity is owned and allocation failures do not leak`. The failure occurred in `removeYielded` while freeing `result.body`. Running that exact test on unchanged main (`cd66abc`) reproduced the same protection exception and abort. This is outside the ingress slice and was not modified or excluded from the guard.

The focused worker/queue/Agent and CLI/ACP/managed-owner ingress suites, including their allocation-failure coverage, pass. The Debug build and configured-provider integration suite also pass. No successful full allocation-failure sweep or full repository suite is claimed; required CI remains a separate gate.
