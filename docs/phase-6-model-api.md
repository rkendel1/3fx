# Phase 6: public model API

`createFxModel()` exposes the existing `ModelProvider` contract to Node.js
hosts without the agent loop. Phase 6D recovery made it compile, run, stream,
and cancel; earlier Phase 6 reports described behavior that did not exist on
`main`.

The public usage reference is the "Direct model calls" section of
[`sdk/README.md`](../sdk/README.md). The native lifecycle is described in
[`sdk/NAPI.md`](../sdk/NAPI.md).

## Call path

```text
createFxModel() / model.chat() / model.stream()      sdk/node.js
        |  validated, normalized request
        v
createModel / modelChat / modelStream                src/napi_core_main.zig
        |  request copied into a per-call arena
        v
ModelHandle.run on a dedicated native thread         src/napi_model_provider.zig
        |  ChatRequest { messages, tools, tool_choice, max_output_tokens,
        |                events, cancel_flag }
        v
ModelProvider.chat                                   src/core/agent/model_provider.zig
        v
OpenAICompatibleModelProvider (SSE over HTTP)        src/gateway/openai_compatible_model_provider.zig
```

Events and the terminal result return through a Node-API thread-safe function
in provider order.

## Implemented

- Model creation from `baseUrl`, `model`, optional `apiKeyEnv`, optional
  `toolChoiceMode`, and optional `id`. The handle owns copies of every string
  and is reference counted, so a collected JavaScript handle stays valid for
  its in-flight calls.
- Request conversion from JavaScript objects into `model_provider.Message` and
  `model_provider.Tool`, with no intermediate message type. Roles, content,
  assistant `tool_calls`, `tool_call_id`, tools with JSON Schema, `tool_choice`,
  and `max_output_tokens` reach the provider request.
- Completion results with content, tool calls (`id`, `name`,
  `arguments_json`), `finish_reason`, `response_id`, and all five token usage
  fields. Unreported values are `null`.
- Provider failures as `{ failed: { kind, detail, retry_after_seconds } }`,
  mirroring `ChatStream.failed`. Errors with no provider response reject with
  a coded Error: `LIBFX_MODEL_CANCELLED`, `LIBFX_MODEL_TIMEOUT`,
  `LIBFX_MODEL_CREDENTIAL_MISSING`, `LIBFX_MODEL_CREDENTIAL_INVALID`, or
  `LIBFX_MODEL_REQUEST_FAILED`.
- Streaming through the provider's `EventSink`. Each `text_delta` and
  `reasoning_delta` reaches JavaScript as the provider emits it, followed by
  one `completion` or `failure` event.
- Cancellation from an `AbortSignal`, or by leaving a stream loop, through
  `cancelModelCall` to the call's `cancel_flag`. The provider closes the active
  connection.
- Concurrent, non-blocking execution on dedicated native threads, capped at
  256 calls per process. Model calls do not occupy the libuv thread pool, and
  terminating a worker cancels its calls.
- ESM and CommonJS consumers of the packaged `libfx` load the API through the
  default platform addon.

## Not implemented

- Incremental tool-call events. The chat-completions stream reducer emits only
  content and reasoning deltas, so tool calls arrive complete in the
  `completion` event. Adding them requires the reducer to emit tool deltas and
  the neutral `model_provider.Event` to carry them.
- A per-call deadline. `ChatRequest.deadline` is not exposed; the provider's
  own connect and response-header phase limits still apply, and an
  `AbortSignal` can bound a call.
- Providers other than OpenAI-compatible chat completions.
- A browser or Wasm model API. `createFxModel()` requires the native addon.
- An AI SDK `LanguageModel` adapter. The API carries what such an adapter needs
  for `doGenerate()` and `doStream()`, but fx has no AI SDK dependency.
- Publishing.

## Verification

| Check | Command |
| --- | --- |
| Native addon build | `zig build -Dnapi-surface=core` |
| Model runtime unit tests | `zig build test` (includes `src/napi_model_provider.zig`) |
| Public API against a local server | `node --expose-gc sdk/tests/test-native-model.mjs` |
| Phase 6C async checks | `node tests/phase6c-verify.mjs` |
| Full native SDK lane | `npm run --prefix sdk test:node-napi` |
| Neutral contract boundary | `python3 scripts/check-model-provider-boundary.py` |

`sdk/tests/test-native-model.mjs` uses gates in its local server. A stream that
buffers deltas, a runtime that serializes calls, and a call that blocks the
event loop each deadlock and fail on a timeout.

`scripts/check-model-provider-boundary.py --whole-agent` reports 1,512 findings
both before and after this work. The model API adds none; 1,509 predate
Phase 6, and 3 come from the Phase 4 `AgentTurnRequest` projection in
`src/core/agent/execution_boundary.zig`.
