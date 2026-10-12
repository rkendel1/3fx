#!/usr/bin/env node
// createFxAgent({ model: createFxModel(...) }) runs the agent loop against the
// model's own provider. Everything here is deterministic and scripted: the
// model is a mock that implements the createFxModel() interface, so these
// tests prove the loop, not any real model. test-live-ollama-agent.mjs is the
// opt-in real-model check. When the native addon is present, the last section
// also drives a real createFxModel() against a local OpenAI-compatible server.
import { strict as assert } from "node:assert";
import { existsSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, createFxModel } from "../node.js";
import { createMcpAdapter } from "../mcp.js";

// The gateway path would use fetch; any use of it here is a failure.
globalThis.fetch = () => { throw new Error("unexpected network access: the direct agent must not use fetch"); };

function scriptedModel(steps) {
  const requests = [];
  return {
    requests,
    id: "scripted",
    model: "scripted-model",
    async chat() { throw new Error("the agent streams"); },
    stream(request, { signal } = {}) {
      requests.push(structuredClone(request));
      const step = steps[requests.length - 1];
      assert.ok(step, `unexpected model request #${requests.length}`);
      return (async function* () {
        if (signal?.aborted) throw Object.assign(new Error("aborted"), { name: "AbortError" });
        for (const piece of step.text ?? []) yield { type: "text_delta", text: piece };
        if (step.failure) { yield { type: "failure", failure: step.failure }; return; }
        yield {
          type: "completion",
          completion: {
            content: (step.text ?? []).join("") || null,
            tool_calls: step.calls ?? [],
            finish_reason: step.finish ?? (step.calls?.length ? "tool_calls" : "stop"),
            usage: { input_tokens: 10, output_tokens: 5, cache_read_tokens: null, cache_write_tokens: null, reasoning_tokens: null },
          },
        };
      })();
    },
  };
}

const call = (id, name, args) => ({ id, name, arguments_json: JSON.stringify(args) });

async function run(agent, prompt, options) {
  const turn = agent.prompt(prompt, options);
  const events = [];
  for await (const event of turn) events.push(event);
  return { events, result: await turn.result };
}

// Gateway credentials are not required, and gateway-only options are refused.
{
  const model = scriptedModel([{ text: ["hi"] }]);
  const agent = await createFxAgent({ model });
  assert.deepEqual(Object.keys(agent).sort(), ["checkpoint", "close", "prompt"]);
  const { events, result } = await run(agent, "hello");
  assert.deepEqual(events, [{ type: "text_delta", delta: "hi" }]);
  assert.equal(result.stopReason, "end_turn");
  assert.deepEqual(result.usage, { inputTokens: 10, outputTokens: 5 });
  await agent.close();
  for (const extra of [{ apiKey: "k" }, { gatewayChatUrl: "http://127.0.0.1:1/x" }, { effort: "low" }, { fast: true }, { fetch }]) {
    await assert.rejects(createFxAgent({ model: scriptedModel([]), ...extra }), TypeError, JSON.stringify(Object.keys(extra)));
  }
  await assert.rejects(createFxAgent({ model: scriptedModel([]), tools: [{ name: "x", providerExecuted: true }] }), /Vercel AI Gateway/);
}

// The gateway agent still requires apiKey and the error points at the alternative.
await assert.rejects(createFxAgent({ model: "some/model" }), /createFxModel/);

// Multi-step tool calling with an MCP-discovered tool: results reach the model,
// and the loop stops on a plain answer. Awaiting only `result` still runs a turn.
{
  const executed = [];
  const client = {
    async listTools() {
      return { tools: [{ name: "get_capability", description: "Look up an AppBoundry capability", inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] } }] };
    },
    async callTool({ name, arguments: args }) {
      executed.push({ name, args });
      return { content: [{ type: "text", text: `capability ${args.id}: enabled` }] };
    },
  };
  const mcp = await createMcpAdapter(client, { prefix: "appboundry_" });
  const model = scriptedModel([
    { calls: [call("c1", "appboundry_get_capability", { id: "alpha" })] },
    { calls: [call("c2", "appboundry_get_capability", { id: "beta" })] },
    { text: ["alpha and beta ", "are enabled"] },
  ]);
  const agent = await createFxAgent({ model, tools: mcp.tools, instructions: ["Be brief."] });
  const { events, result } = await run(agent, "Check alpha and beta.");
  assert.deepEqual(executed, [{ name: "get_capability", args: { id: "alpha" } }, { name: "get_capability", args: { id: "beta" } }]);
  assert.deepEqual(events.map((event) => event.type), ["tool_start", "tool_end", "tool_start", "tool_end", "text_delta", "text_delta"]);
  assert.deepEqual(events[0], { type: "tool_start", id: "c1", name: "appboundry_get_capability", input: { id: "alpha" } });
  assert.deepEqual(events[1], { type: "tool_end", id: "c1", name: "appboundry_get_capability", content: "capability alpha: enabled", isError: false });
  assert.equal(result.stopReason, "end_turn");
  assert.deepEqual(result.usage, { inputTokens: 30, outputTokens: 15 });
  assert.equal(model.requests.length, 3);
  const [first, , third] = model.requests;
  assert.deepEqual(first.messages[0], { role: "system", content: "Be brief." });
  assert.equal(first.tools[0].name, "appboundry_get_capability");
  assert.equal(first.tools[0].input_schema.required[0], "id");
  // Structured call and its result are fed back to the model in order.
  const history = third.messages.slice(-4);
  assert.equal(history[0].role, "assistant");
  assert.equal(history[0].tool_calls[0].id, "c1");
  assert.deepEqual(history[1], { role: "tool", tool_call_id: "c1", content: "capability alpha: enabled" });
  assert.equal(history[3].tool_call_id, "c2");
  assert.equal(history[3].content, "capability beta: enabled");

  await agent.close();
  await mcp.close();
}
{
  const model = scriptedModel([{ text: ["ok"] }]);
  const agent = await createFxAgent({ model });
  assert.equal((await agent.prompt("go").result).stopReason, "end_turn");
  await agent.close();
}

// Tool errors and bad arguments go back to the model instead of ending the turn.
{
  const model = scriptedModel([
    { calls: [call("e1", "boom", {}), { id: "e2", name: "boom", arguments_json: "{not json" }, call("e3", "missing", {})] },
    { text: ["recovered"] },
  ]);
  const agent = await createFxAgent({ model, tools: [{ name: "boom", description: "fails", inputSchema: { type: "object" }, execute() { throw new Error("tool exploded"); } }] });
  const { events, result } = await run(agent, "x");
  const ends = events.filter((event) => event.type === "tool_end");
  assert.deepEqual(ends.map((event) => event.isError), [true, true, true]);
  assert.equal(ends[0].content, "tool exploded");
  assert.match(ends[1].content, /invalid arguments/);
  assert.match(ends[2].content, /unknown host tool/);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(model.requests[1].messages.filter((message) => message.role === "tool").length, 3);
  await agent.close();
}

// A model that never stops calling tools terminates at maxSteps.
{
  const model = scriptedModel(Array.from({ length: 3 }, (_, index) => ({ calls: [call(`l${index}`, "tick", {})] })));
  let ticks = 0;
  const agent = await createFxAgent({ model, maxSteps: 3, tools: [{ name: "tick", description: "t", inputSchema: { type: "object" }, execute() { ticks++; return "tick"; } }] });
  const { result } = await run(agent, "loop");
  assert.equal(result.stopReason, "max_turn_requests");
  assert.equal(ticks, 3);
  assert.equal(model.requests.length, 3);
  await agent.close();
}

// Provider failures reject the turn and leave history unchanged; length maps to max_tokens.
{
  const model = scriptedModel([{ failure: { kind: "malformed_tool_call", detail: "<function=x>" } }, { text: ["partial"], finish: "length" }]);
  const agent = await createFxAgent({ model });
  const turn = agent.prompt("a");
  await assert.rejects((async () => { for await (const _ of turn) {} })(), { code: "LIBFX_MODEL_FAILED", kind: "malformed_tool_call" });
  await assert.rejects(turn.result, { kind: "malformed_tool_call" });
  assert.equal((await run(agent, "b")).result.stopReason, "max_tokens");
  assert.deepEqual(model.requests[1].messages, [{ role: "user", content: "b" }]);
  await agent.close();
}

// Cancellation: an aborted signal makes no request; cancelling mid-tool drops the turn from history.
{
  const model = scriptedModel([{ calls: [call("s1", "slow", {})] }, { text: ["after"] }]);
  let started;
  const toolStarted = new Promise((resolveStarted) => { started = resolveStarted; });
  const agent = await createFxAgent({ model, tools: [{ name: "slow", description: "s", inputSchema: { type: "object" }, execute(_input, { signal }) { started(); return new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(new Error("aborted")))); } }] });
  const pre = await run(agent, "never", { signal: AbortSignal.abort() });
  assert.equal(pre.result.stopReason, "cancelled");
  assert.equal(model.requests.length, 0);
  const turn = agent.prompt("work");
  const consumed = (async () => { for await (const _ of turn) {} })();
  await toolStarted;
  turn.cancel();
  await consumed;
  assert.equal((await turn.result).stopReason, "cancelled");
  const next = await run(agent, "again");
  assert.equal(next.result.stopReason, "end_turn");
  assert.deepEqual(model.requests[1].messages, [{ role: "user", content: "again" }]);
  await agent.close();
  assert.throws(() => agent.prompt("closed"), /closed/);
}

// Steering enters before the next model request; checkpoints restore history.
{
  const model = scriptedModel([{ calls: [call("t1", "wait", {})] }, { text: ["done"] }, { text: ["resumed"] }]);
  let turn;
  const agent = await createFxAgent({ model, tools: [{ name: "wait", description: "w", inputSchema: { type: "object" }, async execute() { await turn.steer("also check gamma"); return "ok"; } }] });
  turn = agent.prompt("start");
  const events = [];
  for await (const event of turn) events.push(event);
  assert.ok(events.some((event) => event.type === "user_message" && event.text === "also check gamma"));
  assert.deepEqual(model.requests[1].messages.at(-1), { role: "user", content: "also check gamma" });
  const checkpoint = await agent.checkpoint();
  await agent.close();
  const restored = await createFxAgent({ model, checkpoint });
  await run(restored, "continue");
  assert.equal(model.requests[2].messages[0].content, "start");
  assert.equal(model.requests[2].messages.at(-1).content, "continue");
  await restored.close();
  await assert.rejects(createFxAgent({ model, checkpoint: new TextEncoder().encode("{}") }), /direct-model agent/);
}

// Lifecycle parity without a native addon: cancel before consumption, early break,
// close() waiting for the turn, and checkpoint refusal mid-turn.
{
  const hang = (signals) => ({
    requests: [],
    id: "hang",
    model: "hang",
    async chat() { throw new Error("unused"); },
    stream(_request, { signal } = {}) {
      signals.push(signal);
      return (async function* () {
        yield { type: "text_delta", text: "partial" };
        await new Promise((resolveHang) => signal.addEventListener("abort", resolveHang, { once: true }));
        throw Object.assign(new Error("aborted"), { name: "AbortError" });
      })();
    },
  });
  const signals = [];
  const agent = await createFxAgent({ model: hang(signals) });
  const unread = agent.prompt("never read");
  unread.cancel();
  assert.equal((await unread.result).stopReason, "cancelled");
  assert.equal(signals.length, 0, "no provider call for an unconsumed cancelled turn");
  const broken = agent.prompt("break early");
  for await (const _ of broken) break;
  assert.equal((await broken.result).stopReason, "cancelled");
  assert.equal(signals.length, 1);
  assert.ok(signals[0].aborted, "break aborted the provider request");
  const closing = agent.prompt("close mid-turn");
  const seen = [];
  const reader = (async () => { for await (const event of closing) seen.push(event); })();
  while (seen.length === 0) await new Promise((r) => setTimeout(r, 1));
  await assert.rejects(agent.checkpoint(), /in progress/);
  assert.throws(() => agent.prompt("second"), /already in progress/);
  await agent.close();
  await reader;
  assert.equal((await closing.result).stopReason, "cancelled");
  assert.equal(signals.length, 2);
  assert.ok(signals[1].aborted, "close aborted the provider request");
  await assert.rejects(agent.checkpoint(), /closed/);
}

// Selection is by interface: model option objects and strings keep the Gateway path.
await assert.rejects(createFxAgent({ model: { id: "vendor/model", effort: "low" } }), /apiKey is required/);
await assert.rejects(createFxAgent({ model: { chat() {} } }), /unsupported model option|apiKey/);
await assert.rejects(createFxAgent({ model: scriptedModel([]), maxSteps: 0 }), /maxSteps/);
await assert.rejects(createFxAgent({ model: scriptedModel([]), maxOutputTokens: 0 }), /maxOutputTokens/);

// A real createFxModel() against a local OpenAI-compatible server: the provider
// is called directly with no gateway URL, no credential, and no fx core.
const scriptDir = dirname(fileURLToPath(import.meta.url));
const nativeAddon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
if (existsSync(nativeAddon)) {
  const seen = [];
  const server = createServer((request, response) => {
    let raw = "";
    request.setEncoding("utf8");
    request.on("data", (piece) => { raw += piece; });
    request.on("end", () => {
      const body = JSON.parse(raw);
      seen.push({ url: request.url, host: request.headers.host, authorization: request.headers.authorization, body });
      const sendChunk = (delta, finish) => response.write(`data: ${JSON.stringify({ id: "x", object: "chat.completion.chunk", created: 0, model: "fixture", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`);
      response.writeHead(200, { "content-type": "text/event-stream" });
      if (body.messages.some((message) => message.role === "tool")) {
        sendChunk({ content: "serial is SN-42" }, null);
        sendChunk({}, "stop");
      } else {
        sendChunk({ tool_calls: [{ index: 0, id: "call_9", type: "function", function: { name: "read_serial", arguments: "{}" } }] }, null);
        sendChunk({}, "tool_calls");
      }
      response.end("data: [DONE]\n\n");
    });
  });
  await new Promise((resolveListening) => server.listen(0, "127.0.0.1", resolveListening));
  try {
    const model = await createFxModel({ baseUrl: `http://127.0.0.1:${server.address().port}/v1`, model: "local", nativeAddon });
    const agent = await createFxAgent({ model, tools: [{ name: "read_serial", description: "serial", inputSchema: { type: "object" }, execute: () => "SN-42" }] });
    const { events, result } = await run(agent, "serial?");
    assert.equal(result.stopReason, "end_turn");
    assert.equal(events.filter((event) => event.type === "tool_end").length, 1);
    assert.equal(events.filter((event) => event.type === "text_delta").map((event) => event.delta).join(""), "serial is SN-42");
    assert.equal(seen.length, 2);
    assert.ok(seen.every((entry) => entry.url === "/v1/chat/completions" && entry.host.startsWith("127.0.0.1:") && entry.authorization === undefined));
    assert.ok(seen.every((entry) => !JSON.stringify(entry).includes("ai-gateway")));
    await agent.close();
    console.log("direct agent drove a real createFxModel() against a local server");
  } finally {
    server.close();
  }
} else {
  console.log(`skipped createFxModel() section: no native addon at ${nativeAddon}`);
}
console.log("direct agent tests passed");
