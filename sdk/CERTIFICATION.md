# Direct-model agent certification (0.1.2)

This report records what is verified about `createFxAgent({ model })` with a
`createFxModel()` handle, how, and what is not. It is evidence for evaluating
0.1.2, not a release approval.

## Verification levels

| Level | What it proves | What it cannot prove | Where |
| --- | --- | --- | --- |
| 1. Deterministic provider protocol | The agent talks only to the configured endpoint, sends the documented request shapes, dispatches structured tool calls to MCP tools, returns results to the model, terminates, and surfaces failures. The provider is scripted. | Anything about a real model: whether it picks the right tool, writes valid arguments, or reaches a good answer. | `tests/test-direct-agent.mjs`, `tests/test-direct-agent-provider.mjs`, run in CI |
| 2. Real-model quality | A real local model (Ollama) emits structured tool calls this loop can execute, and uses the result. Probabilistic, so it retries up to `FX_LIVE_ATTEMPTS`. | Behavior of other models, or of a live AppBoundry service. | `tests/test-live-ollama-agent.mjs`, opt-in, **not run in CI and not run for this report** |
| 3. Live AppBoundry | An AppBoundry MCP endpoint's real tools and auth work through the adapter. | Nothing here exercises it; no test contacts an external endpoint. | Not covered. Needs a reachable endpoint and credentials; run it with your MCP client in the same shape as the example below. |

A level 1 pass is not a level 2 or 3 pass. No result in this report is a
real-model or live-endpoint result.

## Phase 1 audit

What was certified before this work: the gateway agent (`tests/test-agent-*.mjs`,
`test-mcp-adapter.mjs`, `test-minimal-api.mjs`) against scripted Gateway
fixtures; `createFxModel()` against scripted OpenAI-compatible servers
(`test-native-model.mjs`) and manually against Ollama (`test-live-ollama.mjs`,
chat only, no agent loop); packaging and the packed tarball
(`test-packed-consumer.mjs`, chat only). None of it covered an agent using a
non-Gateway provider. That prior certification stands; nothing in it was changed.

Why `createFxAgent()` stayed Gateway-only: it always starts the fx core, which
is built `provider_set.gateway_only` (`src/wasm_core_main.zig`), speaks only the
Vercel language-model protocol, reads `AI_GATEWAY_API_KEY`, and the SDK made
`apiKey` mandatory. `gatewayChatUrl` accepts only the canonical Gateway URL or
a loopback URL speaking that same protocol, so an OpenAI-compatible server could
not be reached. `createFxModel()` was a separate surface with no agent loop.

Contract the direct agent must preserve (from the README and the Gateway
implementation in `fx-sdk.js`): `prompt`/`checkpoint`/`close` surface;
`text_delta`, `reasoning_delta`, `tool_start`, `tool_end`, `user_message`
events with the same field names; `turn.result` as `{ stopReason, usage }`;
one event consumer per turn; steering; cancellation by `signal`, `cancel()`,
and early loop exit; `close()` settling the turn; the same tool, instruction,
prompt, and checkpoint validators; MCP adapter tools unchanged; history that
never holds a tool call without its result.

## Findings fixed in this pass

Reviewing `direct-agent.js` against that contract found real gaps, fixed here:

1. `turn.cancel()` before the events were read, or `break`ing out of the event
   loop, left `turn.result` pending and the agent stuck on "a prompt is already
   in progress". Both now settle the turn as `cancelled`, abort the provider
   request, and remove the turn from history.
2. `close()` aborted a running turn but returned before it settled. It now waits.
3. `onEvent` was accepted and never called. It now receives `model.request` and
   `model.response`.
4. `checkpoint()` during a turn could capture a tool call without its result. It
   now rejects while a prompt runs.
5. `maxOutputTokens` is validated.

## Contract parity

| Behavior | Gateway agent | Direct agent | Test |
| --- | --- | --- | --- |
| Credentials | `apiKey` required | None from fx; `apiKeyEnv` on the model | `test-direct-agent*.mjs` |
| Gateway-only options (`apiKey`, `gatewayChatUrl`, `fetch`, `effort`, `fast`, `ultrafast`) | Accepted | Rejected with `TypeError` | `test-direct-agent.mjs` |
| Instructions | Core system prompt | First `system` message, MCP resource/prompt context included | provider test |
| Tool schema and arguments | Preserved | Preserved byte for byte as `function.parameters`; arguments passed as parsed JSON | provider test |
| Event order and fields | `tool_start`, `tool_end`, `text_delta` | Same names and fields | provider test |
| Multiple/parallel tool calls | Yes | Yes, sequential execution, one request after all results | provider test |
| Step limit | Core limit, continues past 64 | `maxSteps` (default 100) ends with `max_turn_requests` | both tests |
| Tool failures | Error result to model | Error result to model (throw, MCP `isError`, unknown tool) | both tests |
| Model failures | Turn rejects | Turn and `result` reject: `LIBFX_MODEL_FAILED` or the model's `LIBFX_MODEL_REQUEST_FAILED` | provider test |
| Cancellation | `signal`, `cancel()`, loop exit, `close()` | Same, each aborting the provider connection | provider test |
| Steering | Yes | Yes, enters before the next model request | both tests |
| Checkpoint | Core snapshot | JSON messages; restores only into a direct agent; rejects foreign data | both tests |
| `turn.result` | `{ stopReason, usage }` | Same shape; `usage` summed over rounds | both tests |
| Backward compatibility | n/a | String/object/omitted `model` still uses the Gateway | gateway regression runs below |

Intentionally unsupported on the direct path, each rejected or documented:
image prompts, provider-executed tools, `effort`/`fast`/`ultrafast`, Gateway
transport events, checkpoints during a running prompt, and sharing checkpoints
with Gateway agents. Parallel tool calls run one after another, not
concurrently.

Behavior of the native model client the direct agent inherits (observed, and
asserted in the provider test): argument JSON that is invalid or not an object,
a tool name the request did not advertise, a `length` finish, and a
`content_filter` finish all reject with `LIBFX_MODEL_REQUEST_FAILED`
(`InvalidToolArguments`, `InvalidToolName`, `OutputTruncated`, `ContentFiltered`)
rather than reaching the loop. A hand-written model object can still report
those finishes as `max_tokens`/`refused` stop reasons.

## Phase 4 results

Environment: Linux x64, Node 22.22.0, Bun present, tmux present, **no Zig**.
Native and Wasm artifacts could not be built here, so every check that needs
them ran against the **published `@appport/fx@0.1.1` binaries as stand-ins**.
Those predate this source, so these runs show the JavaScript layer behaves, not
that a fresh core build passes. CI builds the real artifacts.

Commands run from the repository root. Stand-ins were copied to `zig-out/`
(`zig-out/lib/libfx.node`, `zig-out/bin/fx-core.wasm`, `zig-out/bin/fx-term.wasm`)
and removed afterwards.

| Command | Result |
| --- | --- |
| `node sdk/tests/test-direct-agent.mjs` (no addon) | Pass; addon section reports skipped |
| `node sdk/tests/test-direct-agent.mjs` (stand-in addon) | Pass, including real `createFxModel()` |
| `node sdk/tests/test-direct-agent-provider.mjs` (stand-in addon) | Pass, 0.7 s |
| `node sdk/tests/test-node-napi.mjs` lane, each script run separately | 34 of 35 pass. `test-agent-provider-tools.mjs` fails identically on unmodified `origin/main` with the same stand-ins, so it is a stand-in mismatch (the 0.1.1 binary predates that source), not a regression. Needs a fresh build to verify. |
| Gateway regressions: `test-minimal-api`, `test-agent-step-limit`, `test-agent-steering`, `test-instruction-limits`, `test-agent-reserved-tool-names`, `test-mcp-adapter` (stdio and http) | Pass |
| `node sdk/tests/test-packed-consumer.mjs` (packs, installs into a clean project, runs ESM and CJS including the direct agent) | Pass |
| `node sdk/tests/test-term-demo-package.mjs` | Pass |
| `node sdk/tests/test-node-package.mjs` | Pass |
| `node sdk/scripts/build-node-cjs.mjs` (Bun) | Pass; CJS bundle exposes the direct path |
| `node sdk/tests/test-node-wasm.mjs` | **Blocked**: Node 22.22 lacks `WebAssembly.Suspending` (JSPI); needs a newer Node. |
| `zig build ...` native addon and Wasm builds | **Blocked**: no Zig toolchain. |
| `node sdk/tests/test-vercel-package.mjs` | **Not run**: needs a published version or tarball argument and a Vercel build. |
| SDK type checks | **Not applicable**: the SDK is plain JavaScript with no `.d.ts` or `tsconfig`. |
| `tests/test-live-ollama-agent.mjs` | **Not run**: no Ollama. Level 2 is unverified. |

CI (`.github/workflows/sdk-ci.yml`) builds the real addon and Wasm and runs
`test-direct-agent.mjs`, `test-direct-agent-provider.mjs`, and the packed
tarball test on Ubuntu and macOS. Treat the CI result on the exact commit as the
authoritative native and packaging result.

## Reproduce

```sh
zig build -Dnapi-surface=core -Doptimize=ReleaseSafe && zig build -Dwasm-surface=core && zig build -Dwasm-surface=term
node sdk/tests/test-direct-agent.mjs
node sdk/tests/test-direct-agent-provider.mjs
node sdk/tests/test-packed-consumer.mjs
# Opt-in, real model (level 2):
ollama pull qwen3-coder:latest && node sdk/tests/test-live-ollama-agent.mjs
```

## Example

```js
import { createFxAgent, createFxModel } from "@appport/fx";
import { createMcpAdapter } from "@appport/fx/mcp";

const model = await createFxModel({ baseUrl: "http://localhost:11434/v1", model: "qwen3-coder" });
const mcp = await createMcpAdapter(mcpClient, { prefix: "appboundry_" });
const agent = await createFxAgent({ model, tools: mcp.tools, instructions: mcp.instructions, maxSteps: 20 });
const turn = agent.prompt("Which capabilities are enabled?");
for await (const event of turn) if (event.type === "text_delta") process.stdout.write(event.delta);
console.log(await turn.result);
await agent.close();
await mcp.close();
```

`mcpClient` is any object with `listTools()` and `callTool()`, such as an MCP SDK
client connected to AppBoundry. The provider-protocol test drives this exact
composition with a real stdio MCP server and a scripted provider.
