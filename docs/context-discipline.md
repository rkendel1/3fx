# Evidence-aware context discipline

Behavior ported from Rust Chip (`rkendel1/chip-rs`, commit `3d7e4fadb66c4a86f1a79f16e0833b337e4ea5e1`):
`classify_observations`, `omissions` and `DeduplicatedEscalationContext` in `chip-core/src/work.rs`, with their
tests in `chip-core/tests/context_discipline.rs`. Chip itself was not modified.

## What runs in production today

Every model request is classified and measured. No request is changed: reuse is disabled because FX lacks the
contracts it needs (see "Missing prerequisites"). `observation_discipline.project` is called with no contracts and
`reuse_enabled = false`, so the messages that reach the provider are the same slice as before.

## Classification

An observation is one tool result paired with the assistant tool call that produced it.

* Invocation: tool name plus the exact bytes of the call's `arguments_json`. No normalization; reordered or
  re-spaced arguments are a different invocation, which fails toward "not repeated".
* Reality: result status plus content bytes. Identical text under a different invocation is never "repeated".
* Each observation is compared with the most recent earlier observation of the same invocation:

| Class | Meaning |
| --- | --- |
| `new` | The first observation of its tool |
| `repeated` | Same invocation as an earlier one, same reality |
| `changed` | Same invocation as an earlier one, different reality |
| `same_capability` | The tool was observed before, with a different invocation |

This is Chip's `New`, `RepeatedIdentical`, `ChangedReality` and `NewFromSameCapability`.

## Safe omission (disabled in production)

`project(..., contracts, reuse_enabled)` replaces the content of an earlier tool message with
`[fx: omitted; identical to the result of tool call <later id>]` only when all of these hold:

1. The caller-supplied contract for the tool says `permits_reuse`.
2. The earlier and later results both succeeded (cancelled and failed results are failures in FX, so they are never
   reusable) and the earlier one carries no stored images.
3. A later result of the same invocation has the same reality.
4. No state-changing result, unknown tool, or new user turn lies between the earlier result and the end of the
   request. A tool with no contract counts as state-changing.

Message order, roles, tool call ids and tool-call/result pairing are unchanged. Stored history, evidence and logs are
never touched: the function returns a new message slice and leaves its input alone. Condition 4 is stricter than
Chip, which only requires a later identical result; FX has no state token, so it demands that nothing could have
changed.

## Missing prerequisites (why reuse stays off)

* No tool declares a reuse contract. `ToolSpec` has `activity_kind` and `reads_only_fn`, but a read-only tool is not
  permission to drop its result: `shell`, MCP tools and files edited outside FX can change what the same call returns.
* No state-validity token exists. FX tracks file evidence staleness for its own file tools, but nothing covers
  commands or external edits.
* `PersistedToolStatus` has only `success` and `failure`; cancellation is recorded as failure, which this module
  treats as never reusable.

Enabling reuse for a tool needs an explicit per-tool contract plus a state token the runtime can trust. Neither was
invented here.

## Measurement

`ContextMeter` (`src/core/agent/runtime/context_meter.zig`) is advanced only by runtime events and is emitted through
the existing trace mechanism (`FX_TRACE_LOG`, scope `context`, event `measurement`). No public CLI schema changed.

| Field | Source |
| --- | --- |
| `model_calls` | Calls the provider admitted |
| `tool_executions` | Executions that started; rejected calls never count |
| `provider_input_tokens`, `provider_output_tokens` | Provider-reported usage only; `null` until reported, never estimated |
| `serialized_request_bytes`, `requests_with_known_bytes` | Body length reported by the chat-completions adapter; other adapters leave it unknown |
| `repeated_observations` | Repeated observations in the most recent request's history |
| `omitted_observations`, `omissions_denied` | Totals over requests actually sent; a denial is an identical later result that could not safely be omitted |

Known limits: an authentication replay is counted once; only the chat-completions adapter reports serialized bytes.

## Experiment

Deterministic fixture in `src/gateway/chat_completions.zig` (six identical `read_file` results of about 4.3 KB
each, serialized with the real chat-completions request builder):

| | Reuse disabled | Reuse enabled (test contract) |
| --- | --- | --- |
| Messages | 13 | 13 |
| Serialized request bytes | 33777 | 12067 |
| Omitted observations | 0 | 5 |
| Newest copy of the evidence | present | present |
| Tool-call/result pairing | unchanged | unchanged |

With a state change after the reads the projection omits nothing and the request is byte-identical to the baseline.
The fixture measures request size only. It makes no claim about latency, token cost, prompt caching (rewriting
earlier messages changes a cached prefix) or model behavior, and it does not run a model, so it does not show that a
model answers correctly from references. Those need separate measurements before reuse is enabled anywhere.
