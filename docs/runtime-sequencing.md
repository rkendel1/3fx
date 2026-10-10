# Runtime sequencing

What FX does, in what order, in representative scenarios, and what that costs. Everything here was observed by
running the real `./zig-out/bin/fx` against a mock OpenAI-compatible provider (`benchmarks/sequencing/`), plus the
source named in each section. The mock answers instantly, so **no real-model latency, token or cost claim is made
anywhere in this document**. Real Ollama (`qwen3-coder:latest`) was not available in the build container.

Reproduce: `zig build && cd tests/e2e && bun ../../benchmarks/sequencing/run.ts`.
The sequences are pinned by the `runtime sequencing` test in `tests/e2e/configured-providers.test.ts`.

## 1. Sequences

Decision owners: the model proposes; `orchestrator.zig` runs the loop and enforces limits; `shell.decode` and the
tool registry validate; `tool_admission` and `command_admission` authorize; `auto_classifier` reviews (a model
call) only in `--auto`; the executor runs; the tool result is the only authoritative evidence of an effect.

```
request
  -> model call (reason: initial)
       -> no tool calls ............................ final answer            [S1]
       -> tool call(s)
            -> validate arguments   (invalid: reject, never reaches review) [S5 S7b S13]
            -> authorize
                 default mode, action needs approval: stop, exit 1          [S15]
                 --auto: deterministic admission, else review (model call)  [S11 S12 S14]
            -> execute (once; identical repeat of a failure is stopped)     [S7]
            -> tool result appended (append-only; earlier messages unchanged)
            -> model call (reason: after tools | after failed tools)
                 -> more tool calls ... bounded by step limit               [S3 S8 S9]
                 -> final answer
```

| Scenario | Actual sequence | Terminal outcome | Evidence of the outcome |
| --- | --- | --- | --- |
| S1 answerable without tools | model, answer | exit 0 | assistant text only; nothing executed |
| S2 one read-only call | model, read_file, model, answer | exit 0 | tool result |
| S3 several calls | model, (call, model) x3, answer | exit 0 | three tool results |
| S4 state change | model, shell, model, answer | exit 0 | file exists on disk |
| S5 malformed call | model, rejected (0 executed, 0 reviews), model with problem list and `retry_with`, shell, model, answer | exit 0 | corrected call executed once |
| S6 execution failure | model, shell fails, model, shell ok, model, answer | exit 0 | failure result then success result |
| S7 repeated identical failure | model, shell fails, model, identical call stopped before execution | exit 1 | one failed execution, stop notice |
| S7b repeated invalid call | model, rejected, model, rejected, stop | exit 1 | zero executions |
| S8 repeated read-only call | model, read x4 (each executed), model, answer | exit 0 | four tool results, each executed |
| S9 step limit | model, tool, model, second call not executed | exit 1 | stop notice |
| S10 Ollama stop finish | model (`stop` + tool call, accepted by adapter opt-in), shell, model, answer | exit 0 | tool result |
| S11-S14 `--auto` | review is one extra model call per action that deterministic admission does not clear | exit 0 | review result, then tool result |
| S15 default mode, state change | model, permission required, stop | exit 1 | nothing executed |

## 2. Baseline versus candidate

Same scenarios, baseline binary (commit `27bd6c3`) versus candidate. Mock provider; "request bytes" are the
serialized bodies the server received; "model calls" exclude reviewer calls, which are counted separately from the
existing `auto_review_send` trace events.

| Scenario | Model calls | Review calls | Executed | Exit | Request bytes per call (candidate) | Baseline differs? |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | 1 | 0 | 0 | 0 | 26188 | no |
| S2 | 2 | 0 | 1 | 0 | 26188, 26992 | no |
| S3 | 4 | 0 | 3 | 0 | 26188, 26784, 27380, 27976 | no |
| S4 | 2 | 0 | 1 | 0 | 26237, 26882 | no (1 byte: temp path length) |
| S5 | 3 | 0 | 1 | 0 | 26237, 26570, 27203 | no (1 byte) |
| S6 | 3 | 0 | 2 | 0 | 26237, 26988, 27607 | no (1 byte) |
| S7 | 2 | 0 | 1 | 1 | 26237, 26980 | no (1 byte) |
| S7b | 2 | 0 | 0 | 1 | 26237, 26562 | no |
| S8 | 5 | 0 | 4 | 0 | 26188, 28834, 31480, 34126, 36772 | no |
| S9 | 2 | 0 | 1 | 1 | 26188, 26440 | no |
| S10 | 2 | 0 | 1 | 0 | 25376, 26056 | no |
| S11 | 2 | 1 | 1 | 0 | 26564, 27191 | no |
| S12 | 2 | 0 | 1 | 0 | 26564, 27212 | no |
| S13 | 2 | 0 | 0 | 0 | 26564, 26897 | no |
| S14 | 3 | 2 | 2 | 0 | 26564, 27192, 27821 | no |
| S15 | 1 | 0 | 0 | 1 | 26188 | no |

The candidate changes no runtime behavior; it adds the call-reason breakdown to the `context` trace event
(`calls_initial`, `calls_after_tools`, `calls_after_failed_tools`). The baseline column reads "n/a" for those.

Time split from a four-call trace (mock provider): process start to first trace line about 5 ms; runtime work per
step before the provider is admitted about 2 to 3 ms; tool execution about 1 ms; the remainder (about 21 to 23 ms
per call) is the mock server round trip and stream parsing, not runtime ordering; last trace line to exit about
2 ms. Real model time is not measured.

## 3. Hypotheses

| Hypothesis | Current sequence | Result | Test that could disprove it |
| --- | --- | --- | --- |
| A deterministic decision can avoid a model call | Every call is initial, a continuation after tool results, or a correction; repeated failures stop without a further call | **Rejected as a runtime change.** The only model calls that look avoidable are corrections of invalid calls, and applying `retry_with` itself would be hidden repair that the shell contract forbids | S5, S7b: a deterministic repair would show fewer calls but execute a call the model did not make |
| Validation should precede review | Already true | **Confirmed**, pinned by S13 (invalid call, zero reviews) | S13 expects 0 reviews |
| Interpretation should precede observation | A request is answered or a tool is chosen by the model in one call; there is no local interpretation step to move | **Not applicable** | n/a |
| Tools run before enough is known | Authorization precedes execution in every scenario; default mode stops before running (S15) | **Rejected**; no premature execution found | S15, S13 expect 0 executions |
| Repeated or irrelevant context is sent | Each call resends about 18 KB of tool schemas and 8 KB of base instructions (about 26 KB; the tool schemas alone are 69 percent of the first request). Tools and earlier messages are byte-identical from call to call; only new messages are appended | **Partly confirmed**: the per-call constant dominates, and repeated reads add about 2.6 KB per copy (S8). No safe reduction found (see 4) | `prefix stable` column |
| Prior evidence can avoid another tool execution | Re-reading costs about 1 ms; a repeated read costs context, not time | **Rejected**: no latency to save, and no reuse contract or state token exists | S8 timing; `context-discipline.md` prerequisites |
| Correction calls repeat a known failure | A correction carries the problem list; a second identical failure is stopped (S7, S7b) | **Rejected**: bounded to two calls, second is the stop | S7, S7b |
| An engine would beat ordinary logic | Runtime overhead is 2 to 3 ms per step against tens of milliseconds to minutes of model time | **Rejected**: no runtime bottleneck for an engine to remove | A profile showing runtime time comparable to model time |

## 4. Implemented

Only measurement. Each model call now records why it happened, derived from the end of the request it sends:
`initial`, `after_tools`, or `after_failed_tools` (`observation_discipline.callReason`, committed by `ContextMeter`
only for requests that the provider admitted). Tests: unit tests for the reason and the commit rule, and the
`runtime sequencing` e2e test, which pins every scenario above.

No optimization is implemented because no hypothesis survived the evidence as a safe change. In particular:

* Rewriting earlier messages to deduplicate reads would break the byte-identical prefix that the table shows FX
  preserves, which a local runtime's prompt cache depends on. It stays disabled (`context-discipline.md`).
* Skipping or merging review calls changes who authorizes an action; see the backlog.

## 5. Remaining bottlenecks and evidence gaps

Ranked by measured cost, not by guess:

1. **Fixed request size.** About 26 KB per call, of which the 14 tool schemas are 18 KB (largest: `shell` 2.9 KB,
   `grep_files` 2.2 KB, `read_tool_result` 2.0 KB, `mcp_features` 1.7 KB). Saved sessions send one more tool and
   about 5 KB more. Trimming means changing what the model can do per request; it needs a real-model task
   success comparison before anyone attempts it.
2. **Review calls in `--auto`.** A default-profile shell command costs one reviewer call (about 5.1 KB) plus its
   round trip, even for `ls .`; the same command with `profile: "clean"` costs none (S11 versus S12). An identical
   repeat is reviewed again (S14). Both follow the documented rule that a clear review covers only the exact
   action. Changing either is a permission-policy decision for the security owners, not a sequencing fix. A
   disproving test would replay S14 with a changed intervening result and show the second review is still needed.
3. **Hallucinated tool names.** An unknown tool name ends the run at once with exit 1 after one model call and
   zero executions (the stream reducer rejects it). This is truthful and safe, but gives the model no chance to
   correct, unlike invalid arguments. A bounded correction for this case is a protocol change and needs evidence
   from a real local model that it occurs often enough to matter.
4. **Real-model behavior is unmeasured.** All counts above are mock-provider counts. Whether Ollama with
   `qwen3-coder` takes the same sequences, how long calls take, and what tokens they cost remain open (BLOCKED:
   Ollama and its model registry were unreachable from the container).
5. **Review and execution time are not in the meter.** Reviewer calls are visible only through the existing
   `auto_review_send` trace events; `ContextMeter.model_calls` counts the main agent loop only. Per-tool execution
   time is available from trace timestamps but is not aggregated.
6. **Gateway-fixture e2e tests** cannot start under the decoupled build ("No model provider configured"), so the
   sequencing of the gateway path is untested here.
