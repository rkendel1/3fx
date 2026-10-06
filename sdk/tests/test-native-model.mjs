#!/usr/bin/env node
// Public model API: drives createFxModel() through the native addon against
// a deterministic in-process OpenAI-compatible server. Streaming, concurrency,
// and cancellation use server-side gates, so a buffering, serialized, or
// event-loop-blocking implementation deadlocks and fails instead of passing.
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Worker } from "node:worker_threads";
import { createFxModel } from "../node.js";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const nativeAddon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));

let handler = null;
const requests = [];
const server = createServer((request, response) => {
  let raw = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { raw += chunk; });
  request.on("end", () => {
    const entry = {
      url: request.url,
      authorization: request.headers.authorization,
      body: JSON.parse(raw),
      closed: new Promise((resolveClosed) => response.on("close", resolveClosed)),
    };
    requests.push(entry);
    handler(entry, response);
  });
});
await new Promise((resolveListening) => server.listen(0, "127.0.0.1", resolveListening));
const baseUrl = `http://127.0.0.1:${server.address().port}/v1`;

function chunk(response, choice, extra = {}) {
  response.write(`data: ${JSON.stringify({ id: "chatcmpl-1", object: "chat.completion.chunk", created: 0, model: "fixture", choices: choice ? [{ index: 0, finish_reason: null, ...choice }] : [], ...extra })}\n\n`);
}

function finish(response, reason, usage = { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }) {
  chunk(response, { delta: {}, finish_reason: reason });
  chunk(response, null, { usage });
  response.end("data: [DONE]\n\n");
}

function text(response, ...parts) {
  response.writeHead(200, { "content-type": "text/event-stream" });
  for (const part of parts) chunk(response, { delta: { content: part } });
  finish(response, "stop");
}

function gate() {
  let open;
  const opened = new Promise((resolveGate) => { open = resolveGate; });
  return { open, opened };
}

function within(promise, label, ms = 10_000) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`timed out: ${label}`)), ms); }),
  ]).finally(() => clearTimeout(timer));
}

async function collect(stream) {
  const events = [];
  for await (const event of stream) events.push(event);
  return events;
}

const model = await createFxModel({ baseUrl, model: "fixture", nativeAddon });
let passed = 0;
async function test(name, run) {
  requests.length = 0;
  await within(run(), name, 20_000);
  passed++;
  console.log(`ok - ${name}`);
}

await test("completion preserves content, usage, finish reason, and request identity", async () => {
  handler = (_, response) => text(response, "Hel", "lo");
  const result = await model.chat({ messages: [{ role: "system", content: "Be brief." }, { role: "user", content: "Hi" }] });
  assert.deepEqual(result, {
    completed: {
      content: "Hello",
      tool_calls: [],
      finish_reason: "stop",
      response_id: "chatcmpl-1",
      usage: { input_tokens: 10, output_tokens: 5, cache_read_tokens: null, cache_write_tokens: null, reasoning_tokens: null },
    },
  });
  const [request] = requests;
  assert.equal(request.url, "/v1/chat/completions");
  assert.equal(request.authorization, undefined, "omitted apiKeyEnv sends no credential");
  assert.equal(request.body.model, "fixture");
  assert.equal(request.body.stream, true);
  assert.deepEqual(request.body.messages, [{ role: "system", content: "Be brief." }, { role: "user", content: "Hi" }]);
});

await test("assistant tool calls and tool results survive request conversion", async () => {
  handler = (_, response) => text(response, "done");
  await model.chat({
    messages: [
      { role: "system", content: "Use tools." },
      { role: "user", content: "Weather?" },
      { role: "assistant", content: null, tool_calls: [{ id: "call_7", name: "weather", arguments_json: "{\"city\":\"Oslo\"}" }] },
      { role: "tool", tool_call_id: "call_7", content: "{\"temp\":3}" },
      { role: "user", content: "Thanks" },
    ],
  });
  const messages = requests[0].body.messages;
  assert.deepEqual(messages.map((message) => message.role), ["system", "user", "assistant", "tool", "user"]);
  assert.equal(messages[2].tool_calls[0].id, "call_7");
  assert.equal(messages[2].tool_calls[0].function.name, "weather");
  assert.equal(messages[2].tool_calls[0].function.arguments, "{\"city\":\"Oslo\"}");
  assert.equal(messages[3].tool_call_id, "call_7");
  assert.equal(messages[3].content, "{\"temp\":3}");
});

function toolCallResponse(_, response) {
  response.writeHead(200, { "content-type": "text/event-stream" });
  chunk(response, { delta: { role: "assistant", tool_calls: [{ index: 0, id: "call_1", type: "function", function: { name: "weather", arguments: "" } }] } });
  chunk(response, { delta: { tool_calls: [{ index: 0, function: { arguments: "{\"city\":" } }] } });
  chunk(response, { delta: { tool_calls: [{ index: 0, function: { arguments: "\"Oslo\"}" } }] } });
  finish(response, "tool_calls");
}

await test("tool definitions, tool choice, and output limit reach the provider", async () => {
  handler = toolCallResponse;
  const schema = { type: "object", properties: { city: { type: "string" } }, required: ["city"] };
  const sending = await createFxModel({ baseUrl, model: "fixture", toolChoiceMode: "send", nativeAddon });
  await sending.chat({
    messages: [{ role: "user", content: "Weather?" }],
    tools: [{ name: "weather", description: "Look up weather", input_schema: schema }],
    tool_choice: "required",
    max_output_tokens: 64,
  });
  const body = requests[0].body;
  assert.equal(body.tools.length, 1);
  assert.equal(body.tools[0].function.name, "weather");
  assert.equal(body.tools[0].function.description, "Look up weather");
  assert.deepEqual(body.tools[0].function.parameters, schema);
  assert.equal(body.tool_choice, "required");
  assert.ok(body.max_tokens === 64 || body.max_completion_tokens === 64, `output limit missing: ${JSON.stringify(body)}`);

  // The default omits tool_choice on the wire, matching configured providers, but still enforces it.
  requests.length = 0;
  handler = (_, response) => text(response, "no tool");
  await assert.rejects(
    model.chat({ messages: [{ role: "user", content: "Weather?" }], tools: [{ name: "weather" }], tool_choice: "required" }),
    { code: "LIBFX_MODEL_REQUEST_FAILED", message: "RequiredToolMissing" },
  );
  assert.equal(requests[0].body.tool_choice, undefined);
});

await test("generated tool calls return with id, name, arguments, and finish reason", async () => {
  handler = toolCallResponse;
  const tools = [{ name: "weather", input_schema: { type: "object", properties: { city: { type: "string" } } } }];
  const { completed } = await model.chat({ messages: [{ role: "user", content: "Weather?" }], tools });
  assert.deepEqual(completed.tool_calls, [{ id: "call_1", name: "weather", arguments_json: "{\"city\":\"Oslo\"}" }]);
  assert.equal(completed.finish_reason, "tool_calls");

  const events = await collect(model.stream({ messages: [{ role: "user", content: "Weather?" }], tools }));
  assert.equal(events.at(-1).type, "completion");
  assert.deepEqual(events.at(-1).completion.tool_calls, completed.tool_calls);
  assert.equal(events.at(-1).completion.finish_reason, "tool_calls");
});

await test("stream delivers each provider delta before the provider sends the next", async () => {
  const gates = [gate(), gate()];
  handler = async (_, response) => {
    response.writeHead(200, { "content-type": "text/event-stream" });
    chunk(response, { delta: { role: "assistant", content: "one " } });
    await gates[0].opened;
    chunk(response, { delta: { content: "two " } });
    await gates[1].opened;
    chunk(response, { delta: { content: "three" } });
    finish(response, "stop");
  };
  const seen = [];
  for await (const event of model.stream({ messages: [{ role: "user", content: "Count" }] })) {
    seen.push(event);
    // The provider is still holding the next chunk; reaching here proves this delta was not buffered.
    if (event.type === "text_delta" && event.text === "one ") gates[0].open();
    if (event.type === "text_delta" && event.text === "two ") gates[1].open();
  }
  assert.deepEqual(seen.filter((event) => event.type === "text_delta").map((event) => event.text), ["one ", "two ", "three"]);
  assert.equal(seen.length, 4);
  assert.equal(seen[3].type, "completion");
  assert.equal(seen[3].completion.content, "one two three");
  assert.equal(seen[3].completion.finish_reason, "stop");
  assert.equal(seen[3].completion.usage.output_tokens, 5);
});

await test("provider failures keep kind, detail, and retry-after", async () => {
  handler = (_, response) => {
    response.writeHead(429, { "content-type": "application/json", "retry-after": "7" });
    response.end(JSON.stringify({ error: { message: "slow down", type: "rate_limit" } }));
  };
  const result = await model.chat({ messages: [{ role: "user", content: "Hi" }] });
  assert.equal(result.completed, undefined);
  assert.equal(result.failed.kind, "rate_limited");
  assert.match(result.failed.detail, /slow down/);
  assert.equal(result.failed.retry_after_seconds, 7);

  const events = await collect(model.stream({ messages: [{ role: "user", content: "Hi" }] }));
  assert.deepEqual(events.map((event) => event.type), ["failure"]);
  assert.deepEqual(events[0].failure, result.failed);

  handler = (_, response) => response.writeHead(500).end("boom");
  const server_error = await model.chat({ messages: [{ role: "user", content: "Hi" }] });
  assert.deepEqual(server_error.failed, { kind: "server_error", detail: "boom", retry_after_seconds: null });
});

await test("unreachable providers reject with a coded error", async () => {
  const closed = createServer();
  await new Promise((resolveListening) => closed.listen(0, "127.0.0.1", resolveListening));
  const port = closed.address().port;
  await new Promise((resolveClosed) => closed.close(resolveClosed));
  const unreachable = await createFxModel({ baseUrl: `http://127.0.0.1:${port}/v1`, model: "fixture", nativeAddon });
  await assert.rejects(unreachable.chat({ messages: [{ role: "user", content: "Hi" }] }), (error) => {
    assert.equal(error.code, "LIBFX_MODEL_REQUEST_FAILED");
    assert.match(error.message, /Connection|Refused/i);
    return true;
  });
  await assert.rejects(collect(unreachable.stream({ messages: [{ role: "user", content: "Hi" }] })), { code: "LIBFX_MODEL_REQUEST_FAILED" });
});

await test("aborting chat cancels the active provider request", async () => {
  const arrived = gate();
  handler = (entry) => arrived.open(entry); // never responds
  const controller = new AbortController();
  const pending = model.chat({ messages: [{ role: "user", content: "Hang" }] }, { signal: controller.signal });
  const entry = await arrived.opened;
  controller.abort();
  await assert.rejects(pending, (error) => {
    assert.equal(error.code, "LIBFX_MODEL_CANCELLED");
    assert.equal(error.name, "AbortError");
    return true;
  });
  await within(entry.closed, "provider connection closed after cancellation");
  await assert.rejects(model.chat({ messages: [{ role: "user", content: "x" }] }, { signal: controller.signal }), { name: "AbortError" });
});

await test("aborting a stream mid-response cancels the provider", async () => {
  handler = (_, response) => {
    response.writeHead(200, { "content-type": "text/event-stream" });
    chunk(response, { delta: { role: "assistant", content: "partial" } }); // then holds the stream open
  };
  const controller = new AbortController();
  const seen = [];
  await assert.rejects((async () => {
    for await (const event of model.stream({ messages: [{ role: "user", content: "Hang" }] }, { signal: controller.signal })) {
      seen.push(event);
      controller.abort();
    }
  })(), { code: "LIBFX_MODEL_CANCELLED", name: "AbortError" });
  assert.deepEqual(seen, [{ type: "text_delta", text: "partial" }]);
  await within(requests[0].closed, "provider connection closed after stream abort");
});

await test("leaving a stream early cancels the provider", async () => {
  handler = (_, response) => {
    response.writeHead(200, { "content-type": "text/event-stream" });
    chunk(response, { delta: { role: "assistant", content: "first" } });
  };
  for await (const event of model.stream({ messages: [{ role: "user", content: "Hang" }] })) {
    assert.equal(event.text, "first");
    break;
  }
  await within(requests[0].closed, "provider connection closed after early return");
});

await test("concurrent calls run in parallel without blocking the event loop", async () => {
  const bothArrived = gate();
  const held = [];
  handler = (_, response) => {
    held.push(response);
    if (held.length === 2) bothArrived.open();
  };
  let ticks = 0;
  const ticker = setInterval(() => { ticks++; }, 5);
  const first = model.chat({ messages: [{ role: "user", content: "a" }] });
  const second = createFxModel({ baseUrl, model: "fixture", nativeAddon })
    .then((other) => other.chat({ messages: [{ role: "user", content: "b" }] }));
  // Both requests must be in flight at once: a serialized runtime never sends the second.
  await bothArrived.opened;
  await new Promise((resolveWait) => setTimeout(resolveWait, 50));
  const ticksWhileHeld = ticks;
  for (const response of held) text(response, "done");
  const results = await Promise.all([first, second]);
  clearInterval(ticker);
  assert.ok(ticksWhileHeld >= 3, `event loop stalled while calls were in flight (${ticksWhileHeld} ticks)`);
  assert.deepEqual(results.map((result) => result.completed.content), ["done", "done"]);
});

await test("apiKeyEnv is read at call time and sent as a bearer credential", async () => {
  handler = (_, response) => text(response, "ok");
  const keyed = await createFxModel({ baseUrl, model: "fixture", apiKeyEnv: "LIBFX_MODEL_TEST_KEY", nativeAddon });
  delete process.env.LIBFX_MODEL_TEST_KEY;
  await assert.rejects(keyed.chat({ messages: [{ role: "user", content: "Hi" }] }), { code: "LIBFX_MODEL_CREDENTIAL_MISSING" });
  assert.equal(requests.length, 0, "missing credential must not contact the provider");
  process.env.LIBFX_MODEL_TEST_KEY = "fixture-secret";
  await keyed.chat({ messages: [{ role: "user", content: "Hi" }] });
  assert.equal(requests[0].authorization, "Bearer fixture-secret");
  delete process.env.LIBFX_MODEL_TEST_KEY;
});

await test("invalid configuration and requests are rejected before any call", async () => {
  await assert.rejects(createFxModel({ baseUrl: "http://example.com/v1", model: "fixture", nativeAddon }), { code: "LIBFX_INVALID_MODEL_CONFIG" });
  await assert.rejects(createFxModel({ baseUrl, nativeAddon }), TypeError);
  await assert.rejects(createFxModel({ baseUrl, model: "fixture", toolChoiceMode: "auto", nativeAddon }), TypeError);
  await assert.rejects(model.chat({ messages: [] }), TypeError);
  await assert.rejects(model.chat({ messages: [{ role: "developer", content: "x" }] }), TypeError);
  await assert.rejects(model.chat({ messages: [{ role: "user", content: "x" }], tool_choice: "any" }), TypeError);
  assert.throws(() => model.stream({ messages: [{ role: "user", content: [] }] }), TypeError);
  assert.equal(requests.length, 0);
});

await test("in-flight calls leave the libuv thread pool free", async () => {
  const held = [];
  handler = (_, response) => held.push(response);
  const controller = new AbortController();
  // More calls than the default pool size of 4: pool-backed calls would stall fs work.
  const calls = Array.from({ length: 6 }, () =>
    model.chat({ messages: [{ role: "user", content: "hold" }] }, { signal: controller.signal }).catch((error) => error));
  await within((async () => { while (held.length < 6) await new Promise((resolveTick) => setTimeout(resolveTick, 5)); })(), "six calls in flight");
  await within(readFile(fileURLToPath(import.meta.url)), "fs.readFile while model calls are in flight", 2_000);
  controller.abort();
  for (const error of await Promise.all(calls)) assert.equal(error.code, "LIBFX_MODEL_CANCELLED");
});

await test("terminating a worker cancels its in-flight calls", async () => {
  const arrived = gate();
  handler = (entry, response) => {
    if (entry.body.messages[0].content === "stream") response.writeHead(200, { "content-type": "text/event-stream" });
    if (requests.length === 2) arrived.open();
  };
  const worker = new Worker(`
    const { parentPort, workerData } = require("node:worker_threads");
    import(workerData.sdk).then(async ({ createFxModel }) => {
      const model = await createFxModel({ baseUrl: workerData.baseUrl, model: "fixture", nativeAddon: workerData.nativeAddon });
      model.chat({ messages: [{ role: "user", content: "chat" }] }).catch(() => {});
      (async () => { for await (const _ of model.stream({ messages: [{ role: "user", content: "stream" }] })) {} })().catch(() => {});
    });
  `, { eval: true, workerData: { sdk: new URL("../node.js", import.meta.url).href, baseUrl, nativeAddon } });
  await arrived.opened;
  const exited = new Promise((resolveExit) => worker.once("exit", resolveExit));
  await worker.terminate();
  await within(exited, "worker exit with in-flight model calls", 3_000);
  await within(Promise.all(requests.map((entry) => entry.closed)), "provider connections closed by worker teardown", 3_000);
});

if (typeof globalThis.gc === "function") {
  await test("a collected model handle stays valid for its in-flight call", async () => {
    const arrived = gate();
    let release;
    handler = (_, response) => {
      release = () => text(response, "still here");
      arrived.open();
    };
    let transient = await createFxModel({ baseUrl, model: "fixture", nativeAddon });
    const pending = transient.chat({ messages: [{ role: "user", content: "Hi" }] });
    transient = null;
    await arrived.opened;
    for (let round = 0; round < 5; round++) {
      globalThis.gc();
      await new Promise((resolveTick) => setImmediate(resolveTick));
    }
    release();
    assert.equal((await pending).completed.content, "still here");
  });
} else {
  console.log("# skipped handle collection check; run with --expose-gc");
}

server.close();
console.log(`${passed} model API checks passed`);
