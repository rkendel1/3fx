# Rust Chip runtime audit and FX parity

Reference: `rkendel1/chip-rs`, branch `main`, commit `3d7e4fadb66c4a86f1a79f16e0833b337e4ea5e1` (read-only
clone, clean working tree). Target: this repository, branch `claude/zen-edison-jprsp2`.

Evidence rules: a mechanism is **Proven** only when production code exists and a test or executed
result verifies it. Names, READMEs and design documents are not evidence. Chip's own documents are
unusually candid about this; where they say "design, not implemented" the source agrees (no
`blockage` symbol exists in any `.rs` file).

## 1. How the Chip tests were run

The workspace depends on a private git repository (`rkendel1/flow_db`, used only by the experiment crate
`chip-session-memory`), which the container cannot fetch. The clone was left untouched; a scratch copy
without that one member was tested:

```
cargo test -p chip-core -p chip-compute -p chip-cli --no-fail-fast
```

PAX was obtained from `rkendel1/pax` at tag `v0.4.1` (commit `674f3b3143874d1a692aca103b33f89da31a82ac`, the
version Chip's CI pins), built with `cargo build --release` (`pax 0.4.1`) and placed on `PATH`.

Result with PAX: 758 passed, 1 failed. The one failure is `chip-cli --test inventory`, which fails only because
the scratch copy removed a workspace member. Before PAX was installed the same command gave 751 passed and 8
failed; seven of those failures were `PAX unavailable` and disappeared. No real model was available, so the
opt-in real-model tests did not run.

## 2. Audit: what Chip actually implements

| Mechanism | Class | Evidence (source, then tests) |
| --- | --- | --- |
| Runtime-owned bounded loop: turns, executions, terminal states `Completed`, `Escalated`, `Blocked`, `LimitReached`, `Failed` | Proven | `chip-core/src/work.rs` `Agent::drive`, `WorkLimits`; `tests/work_loop.rs` `each_terminal_state_is_reachable_and_explicit`, `limits_hold_for_every_combination_and_every_run_ends_terminal` |
| Local decision before any model call; exactly one model call per escalation, no retry | Proven | `drive` (policy `propose`, `escalate`); `an_escalation_makes_exactly_one_model_call_and_measures_what_it_sent`, `a_provider_failure_is_a_failure_after_exactly_one_call` |
| Model proposes, runtime validates; a request is not an execution; model words are never evidence | Proven | `perform`, `validate_capability_request`; `model_output_cannot_manufacture_execution_or_evidence`, `a_capability_request_is_not_an_execution`, `invalid_model_output_never_becomes_execution_observation_or_evidence` (`model_decision.rs`) |
| Runtime assigns the execution id; the model never names one | Proven | `assign_execution_id`; `the_model_never_names_an_execution` |
| Goal evaluated by the runtime from observations only; a model completion claim is refused until observations support it (terminal `Blocked`) | Proven | `evaluate_goal`, `completion_refused`, `answer_refused`; `a_proposed_answer_is_evaluated_by_the_runtime_and_audited`; CLI kinds `change`, `verify`, `inspect` in `chip-cli/src/software_work.rs` |
| Observation classification: new, repeated identical, changed reality, new from same capability | Proven | `classify_observations`; `observations_are_classified_new_repeated_changed_or_from_the_same_capability` |
| Context dedup: an earlier identical observation is omitted and named only when the capability's contract allows reuse and a later identical result is in the request; never summarised | Proven | `omissions`, `DeduplicatedEscalationContext`; `an_identical_reusable_observation_is_left_out_and_named_never_summarised`, `a_non_reusable_observation_is_always_resent_even_when_identical`, `read_write_read_establishes_the_new_reality_and_the_old_one_is_not_current` |
| Fail-closed context budget: an over-budget request is not sent, trimmed or retried (`LimitReached(Context)`) | Proven | `escalate`; `an_over_budget_request_is_not_trimmed_retried_or_sent_elsewhere` |
| Evidence reuse validated against state; stale evidence is not reused; cancelled executions never become evidence | Proven | `lookup`, `reuse`; `stale_evidence_is_not_reused_it_goes_to_local_reasoning`, `a_cancelled_execution_is_observed_but_never_becomes_evidence`. The shipped `chip work` marks every project capability non-reusable, so this is exercised mainly by tests |
| Failure notes naming the exact invocation ("ruled out" list in the next context); another input is not ruled out | Proven (narrow) | `Run::ruled_out`, `invocation_label`; covered through `context_discipline` and `chip-cli/tests/work_cli.rs` |
| Independent safety audit and trajectory verifier that read recorded events, not loop counters | Proven | `audit_safety`, `verify_trajectory`; `the_audit_catches_an_omission_or_a_send_nothing_justifies` |
| Identical inputs give identical trajectories | Proven | `identical_workloads_produce_identical_trajectories`, `the_same_inputs_build_the_same_context_every_time` |
| Measurement derived from events (model calls, executions, tokens, bytes, repeated bytes) | Proven | `WorkMeasurement::derive`, `context_report`; `every_model_call_is_measured_by_chip_and_the_providers_usage_is_kept_apart` |
| Provider-neutral model boundary; `chip-core` names no provider | Proven | `chip_core_names_no_provider_and_reads_no_environment`, `provider_isolation.rs` |
| Cancellation | Implemented, incompletely verified | Advisory only: stops the next model call, never interrupts a call in flight (README, debt D-16). No whole-work wall-clock deadline |
| Real-model effectiveness | Absent | Debt D-24: no recorded real-model run. Coding-agent evaluation uses scripted judgment |
| Deterministic failure classification (Blockage Classifier), Work Contract, Evidence Ledger, Micro-step Proposal Gate | Planned/documented | Design documents marked "not implemented"; no source symbols |
| Repair budget, tiers, resumable escalation | Absent | Debt D-13: "No retries, no hidden repair" |
| Shadow micro-model classifier | Experimental | Observation only, no authority (`micro-model-shadow.md`) |
| Local ML, Wasm decision, graph, session-memory crates | Experimental | `docs/product/crates.md` classifies them as experiments |

Important negative finding: Chip does not detect repeated identical *actions* and stop the loop. It bounds
loops with turn and execution limits, and measures repetition. Chip's "loop prevention" is therefore the
limits plus the ruled-out notes, not a detector.

## 3. Parity matrix

"FX today" was established by reading the FX source and running the real binary against a mock
OpenAI-compatible server.

| Chip behavior | FX today | Gap | Belongs in FX | Action |
| --- | --- | --- | --- | --- |
| Bounded loop, explicit terminal state | Step limit and per-guard stops exist (`orchestrator.zig`) | Repeated shell validation failures ended the turn as `completed`, and `fx ask --json` reported `exit_code: 0` with empty output | Yes | **Implemented** (section 4) |
| Strict validation before execution; rejected requests never execute | Present (`shell.decode`, `request_correction`) | None found; rejected calls executed zero times in every case tested | Yes | Regression tests added |
| Model repair only where the contract allows (Chip tolerates one code fence) | Shell correction returns `retry_with` but never executes it; flat `{"command":...}` was left to fail | Unambiguous flat run form not normalized | Yes, shell tool only | **Implemented** |
| Provider-neutral boundary; adapter owns wire quirks | Adapter per protocol | Ollama reports `finish_reason: "stop"` on tool-call turns and FX failed the whole turn with `InconsistentFinishReason` | Adapter, opt-in | **Implemented** |
| Request reaches the wire exactly as designed | `flatten_unions` existed but never applied to the shell schema `fx ask` sends (process-only variant) | Schema projection did not reach the wire | Adapter and schema | **Implemented** |
| Identical-failure detection | Present: `IdenticalFailureEscalationState`, malformed-argument batch limit of 3 | None | Already in FX | None |
| Dedup of identical earlier observations in model context | Not present as a request-time projection; compaction exists | Possible context saving | Yes, with care | Deferred (section 6) |
| Fail-closed context budget | FX compacts rather than refusing | Different design, not a defect | No | Not ported |
| Observation repetition metrics | Not in `fx ask --json` | Observability | Yes | Deferred |
| Goal predicates, completion refusal, kinds `change`, `verify`, `inspect` | Not applicable: FX is a general coding agent with no machine-checkable goal | Large | No (product orchestration; depends on PAX and goals) | Not ported |
| Evidence reuse with state tokens | FX tracks file evidence staleness | Not applicable | No | Not ported |
| Durable work governance, queue service, environment providers | Out of scope | | No | Not ported |

## 4. Implemented in FX

| File | Change and rationale |
| --- | --- |
| `src/core/agent/runtime/orchestrator.zig` | (a) `flat_shell_run_arguments`: the flat form `{"command":"..."}` becomes `{"action":"run","command":"..."}` only for the tool named `shell`, only with an explicit allowlist (`command`, `cwd`, `profile`, `shell`, `tty`, `yield_time_ms`, `timeout_ms`, `reload`), and never when `action`, `request`, unknown fields, an empty or non-string command, or a `profile`+`shell` conflict is present. Canonical decode still validates the result. (b) Repeated shell validation failures now finish through `finishFailedTurnWithNotice` like the two sibling guards, so exhausted recovery is a failed turn |
| `src/gateway/chat_completions_protocol.zig` | `Limits.accept_stop_with_tool_calls`: when set, a `stop` finish reason on a turn with fully received, validated tool calls is reported as `tool_calls`. Default stays strict. The reverse mismatch (`tool_calls` with no calls) stays an error |
| `src/core/config/configured_provider.zig`, `src/gateway/openai_compatible_model_provider.zig`, `src/gateway/legacy_model_provider.zig` | `finish_reason_mode` (`strict` or `accept_stop_with_tool_calls`) plumbed like `tool_schema_mode`; the built-in Ollama preset enables it. User-defined providers stay strict unless they opt in |
| `src/core/tooling/model_tool_schema.zig` | The flatten projection now also matches the three-variant process-only shell schema, which is what `fx ask` advertises |
| `src/core/cli/cli_surface.zig` | The ACP identity test now passes `--provider ollama`, so it no longer reads the machine's `~/.fx/settings.json` |
| `tests/e2e/configured-providers.test.ts` | New `local shell tool calling` tests against the real binary: serialized request body with `flatten_unions` and canonical; flat, nested and stop-finish calls execute exactly once and the real output reaches the model; stop-finish rejected without the opt-in; six malformed or ambiguous calls never execute, terminate, and exit 1 |
| `tests/e2e/gateway-stream-lifecycle.test.ts` | The pinned expectation for the repeated-validation stop changed from exit 0 to exit 1. This test uses the Vercel gateway fixture, which the decoupled build rejects (`No model provider configured`), so it could not be run here (section 5) |

Provider neutrality: nothing Ollama or Qwen specific is in general runtime logic. The only Ollama-specific
element is the preset line that enables an opt-in adapter mode.

## 5. Verification

| Check | Result |
| --- | --- |
| `zig fmt --check src/` | pass |
| `zig build` | pass |
| New e2e group `local shell tool calling` (4 tests, 71 assertions) | pass |
| Full `zig build test --summary all`, baseline (parent commit, clean worktree) | 9868 of 9917 passed, 31 skipped, 14 failed, 4 crashed |
| Full `zig build test --summary all`, final tree | 9870 of 9919 passed, 31 skipped, 14 failed, 4 crashed |
| Failures fixed relative to baseline | `ACP runner errors preserve their identity` |
| Failures that differ from baseline | `McpRuntime cancels blocked stdio discovery` (timing test, failed in every run of the changed tree, passed in the baseline) and `closing owned terminals for exit` (leak in `native_session.zig` PTY start, failed once in three runs, outside the changed code). Both are process and timing sensitive in this container; neither was proven unrelated by an isolated rerun, because `build.zig` has no test filter |
| Regression caught and fixed during the work | `processQueuedPrompt stops repeated distinct terminal corrections...` pinned the old `completed` status and system notice; it now asserts a failed turn announced as operational text |

Pre-existing failures, investigated:

* `ACP runner errors preserve their identity`: cause found and fixed. It read the machine's real profile
  settings, and the decoupled build exits with "No model provider configured" when none is set. The test now uses
  host-managed auth, which skips that local check.
* `timeout terminates foreground process group descendants`, MCP timeout and cancellation tests: environmental.
  PID 1 in this container (`process_api`) never reaps orphans, so a killed child stays a zombie and
  `kill(pid, 0)` keeps succeeding; reproduced directly with a `sleep` killed with SIGKILL. Not fixed because the
  expected behavior is correct.
* Read-only directory and permission tests (`session_store`, `change_tracker`, `storage`, `api_tests`): the
  container runs as root, which bypasses permission checks.
* Four tests abort with `switch on corrupt value` in `expectEqualDeep` (`model_catalog`, `chat_completions`
  capability lookup, `agent_adapter`, `tool_host`). They fail identically at the parent commit and were not
  investigated further.
* Gateway-fixture e2e tests (`gateway-stream-lifecycle.test.ts` and similar) cannot start under the decoupled
  build: they report `No model provider configured`. This is a harness/fixture gap, not a product defect.

## 6. Performance and reliability evidence

No latency or token-cost improvement is claimed; none was measured. Measured, same scenario, baseline versus
changed binary, mock server that always returns an invalid shell call:

| Metric | Before | After |
| --- | --- | --- |
| `exit_code` for a stalled invalid-call loop | 0 | 1 |
| Model requests before the guard stops the loop | 2 | 2 |
| Shell executions of invalid calls | 0 | 0 |
| `oneOf` in the shell schema sent with `flatten_unions` through `fx ask` | present | absent |
| Turn with `finish_reason: "stop"` plus a valid tool call (Ollama preset) | fails, 0 executions | executes once, result returned, final answer produced |

## 7. Deferred work, ranked

1. **Real-model acceptance (BLOCKED).** Ollama could not be installed or run: `ollama.com` and
   `registry.ollama.ai` are denied by the egress proxy (HTTP 403 on CONNECT), `huggingface.co` is unreachable, and
   no Ollama binary or server exists in the container. `qwen3-coder:latest` was therefore never present and never
   tested. Layers C and D are BLOCKED. All tool-calling evidence above is from a scripted mock server that
   reproduces known Ollama wire behavior; it does not prove the real model emits these shapes.
2. Decide whether the Ollama preset should also default `tool_schema_mode` to `flatten_unions`. The direct
   Ollama experiments reported in the task support it, but they could not be reproduced here, so it was not
   changed.
3. Request-time dedup of earlier identical read-only tool results (Chip `dedup-v1`). It rewrites earlier
   messages, which invalidates provider prompt caches; it needs a measured comparison before adoption.
4. Add repetition metrics (new, repeated identical, changed) to `fx ask --json`, as Chip's `ContextReport` does.
5. Report a stop reason in `fx ask --json` for runtime-initiated stops; today only the exit code and a stderr
   notice carry it. This extends a public contract, so it needs a decision.
6. Re-point the gateway-fixture e2e tests at a configured provider so they run in the decoupled build.

## 8. Release assessment

Not safe to release on this evidence. Real-model acceptance is BLOCKED, the changed expectation in
`gateway-stream-lifecycle.test.ts` is unverified here, the full suite still has pre-existing failures (listed
above) that Full CI on all four native runners must confirm are absent there, and AGENTS.md requires that
CI and the ship gate pass on the exact commit. Nothing was tagged or published, and no pull request was opened.
