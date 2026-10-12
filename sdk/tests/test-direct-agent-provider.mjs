#!/usr/bin/env node
// Deterministic certification of the direct-model agent path over the wire.
//
// A real createFxModel() (native addon) talks to a scripted local HTTP server
// that implements the OpenAI-compatible chat-completions protocol, and the
// agent dispatches tool calls to a real MCP server over stdio through
// createMcpAdapter(). The server records every request, so the assertions are
// on actual URLs, headers, bodies, and call order.
//
// This certifies provider-protocol and agent-loop behavior only. The provider
// is scripted: it says nothing about a real model's tool selection or argument
// quality (see test-live-ollama-agent.mjs) or about a live AppBoundry endpoint.
// It needs no Ollama, credential, or external network, and fails (not skips)
// when the native addon is missing so CI cannot pass vacuously.
//   node sdk/tests/test-direct-agent-provider.mjs [nativeAddon]
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { createFxAgent, createFxModel } from "../node.js";
import { createMcpAdapter } from "../mcp.js";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const nativeAddon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
if (!existsSync(nativeAddon)) {
  console.error(`FAILED: native addon not found at ${nativeAddon}; this suite cannot run without it`);
  process.exit(1);
}

// Sentinels: if the direct path ever read gateway configuration, they would surface on the wire.
const GATEWAY_KEY = "gw-sentinel-key-must-never-be-sent";
process.env.AI_GATEWAY_API_KEY = GATEWAY_KEY;
process.env.FX_GATEWAY_CHAT_URL = "http://127.0.0.1:1/gateway-sentinel";
const realFetch = globalThis.fetch;
const outboundFetches = [];
globalThis.fetch = (input, init) => { outboundFetches.push(String(input?.url ?? input)); return realFetch(input, init); };

// ---- scripted provider -----------------------------------------------------
const log = [];
let script = () => { throw new Error("no script installed"); };
const provider = createServer((request, response) => {
  let raw = "";
  request.setEncoding("utf8");
  request.on("data", (piece) => { raw += piece; });
  request.on("end", () => {
    const entry = { method: request.method, url: request.url, headers: request.headers, body: JSON.parse(raw), closed: false };
    response.on("close", () => { entry.closed = true; });
    entry.sequence = log.push(entry);
    script(entry, response, entry.sequence);
  });
});
await new Promise((resolveListening) => provider.listen(0, "127.0.0.1", resolveListening));
const providerPort = provider.address().port;
const baseUrl = `http://127.0.0.1:${providerPort}/v1`;

const sse = (response, ...deltas) => {
  response.writeHead(200, { "content-type": "text/event-stream" });
  deltas.forEach(([delta, finish], index) => response.write(`data: ${JSON.stringify({ id: "resp-1", object: "chat.completion.chunk", created: 0, model: "scripted", choices: [{ index: 0, delta, finish_reason: finish ?? null }] })}\n\n`));
};
const end = (response) => {
  response.write(`data: ${JSON.stringify({ id: "resp-1", object: "chat.completion.chunk", created: 0, model: "scripted", choices: [], usage: { prompt_tokens: 7, completion_tokens: 3, total_tokens: 10 } })}\n\n`);
  response.end("data: [DONE]\n\n");
};
const say = (response, text, finish = "stop") => { sse(response, [{ role: "assistant", content: text }], [{}, finish]); end(response); };
const callTools = (response, ...calls) => {
  sse(response, [{ role: "assistant", tool_calls: calls.map(([id, name, args], index) => ({ index, id, type: "function", function: { name, arguments: typeof args === "string" ? args : JSON.stringify(args) } })) }], [{}, "tool_calls"]);
  end(response);
};
const toolMessages = (entry) => entry.body.messages.filter((message) => message.role === "tool");
const reset = (next) => { log.length = 0; script = next; };

// ---- real MCP server over stdio -------------------------------------------
function startMcp() {
  const child = spawn(process.execPath, [resolve(scriptDir, "fixtures/mcp-stdio-server.mjs")], { stdio: ["pipe", "pipe", "inherit"] });
  const pending = new Map();
  let nextId = 1;
  const calls = [];
  createInterface({ input: child.stdout }).on("line", (line) => {
    const message = JSON.parse(line);
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    if (message.error) waiter.reject(new Error(message.error.message)); else waiter.resolve(message.result);
  });
  const request = (method, params = {}) => new Promise((resolveRequest, reject) => {
    const id = nextId++;
    pending.set(id, { resolve: resolveRequest, reject });
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  });
  return {
    calls,
    client: {
      listTools: (params) => request("tools/list", params),
      callTool: (params) => { calls.push(params); return request("tools/call", params); },
      readResource: (params) => request("resources/read", params),
      getPrompt: (params) => request("prompts/get", params),
      async close() { child.stdin.end(); await new Promise((resolveExit) => child.once("exit", resolveExit)); },
    },
    request,
  };
}

async function drain(turn) {
  const events = [];
  for await (const event of turn) events.push(event);
  return events;
}
const types = (events) => events.map((event) => event.type);

const model = await createFxModel({ id: "cert-main", baseUrl, model: "local-model", nativeAddon });
const mcpServer = startMcp();
await mcpServer.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "cert", version: "1" } });
const mcp = await createMcpAdapter(mcpServer.client, { prefix: "appboundry_", resources: ["memory://fixture"], prompts: ["fixture"] });
assert.deepEqual(mcp.tools.map((tool) => tool.name), ["appboundry_echo"]);

// 1-6. Full interaction: no gateway credentials, only the configured endpoint, structured
// tool call, MCP dispatch, result returned to the model, final answer built from it.
{
  reset((entry, response, n) => {
    if (n === 1) return callTools(response, ["call_a", "appboundry_echo", { value: "alpha" }]);
    if (n === 2) return callTools(response, ["call_b", "appboundry_echo", { value: "beta" }]);
    // The final answer is derived from the tool messages the provider actually received.
    return say(response, `results: ${toolMessages(entry).map((message) => message.content).join(" | ")}`);
  });
  const agent = await createFxAgent({ model, tools: mcp.tools, instructions: mcp.instructions });
  const turn = agent.prompt("echo alpha then beta");
  const events = await drain(turn);
  const result = await turn.result;

  assert.equal(log.length, 3, "one provider request per model round");
  for (const entry of log) {
    assert.equal(entry.method, "POST");
    assert.equal(entry.url, "/v1/chat/completions");
    assert.equal(entry.headers.host, `127.0.0.1:${providerPort}`);
    assert.equal(entry.headers.authorization, undefined, "no credential is sent without apiKeyEnv");
    assert.match(entry.headers["content-type"], /application\/json/);
    assert.ok(!JSON.stringify(entry.headers).includes(GATEWAY_KEY) && !JSON.stringify(entry.body).includes(GATEWAY_KEY));
    assert.ok(!JSON.stringify([entry.headers, entry.body]).match(/ai-gateway|vercel|gateway-sentinel/i));
    assert.equal(entry.body.model, "local-model");
    assert.equal(entry.body.stream, true);
    assert.equal(entry.body.tool_choice, undefined, 'toolChoiceMode "omit" sends no tool_choice');
    // Tool schema and description are preserved exactly as the MCP server advertised them.
    assert.deepEqual(entry.body.tools, [{ type: "function", function: { name: "appboundry_echo", description: "Echo a value", parameters: { type: "object", properties: { value: { type: "string" } }, required: ["value"] } } }]);
  }
  // Instructions (including MCP resource and prompt context) travel as the system message.
  assert.equal(log[0].body.messages[0].role, "system");
  assert.ok(log[0].body.messages[0].content.includes("resource context") && log[0].body.messages[0].content.includes("prompt context"));
  assert.deepEqual(log[0].body.messages.slice(1), [{ role: "user", content: "echo alpha then beta" }]);
  // The structured call and its MCP result are replayed to the provider in order.
  const second = log[1].body.messages.slice(-2);
  assert.equal(second[0].role, "assistant");
  assert.equal(second[0].tool_calls[0].id, "call_a");
  assert.equal(second[0].tool_calls[0].function.name, "appboundry_echo");
  assert.deepEqual(JSON.parse(second[0].tool_calls[0].function.arguments), { value: "alpha" });
  assert.deepEqual(second[1], { role: "tool", tool_call_id: "call_a", content: "mcp:alpha" });
  assert.deepEqual(toolMessages(log[2]).map((message) => [message.tool_call_id, message.content]), [["call_a", "mcp:alpha"], ["call_b", "mcp:beta"]]);
  // MCP server executed the calls with the model's exact arguments, in order.
  assert.deepEqual(mcpServer.calls, [{ name: "echo", arguments: { value: "alpha" } }, { name: "echo", arguments: { value: "beta" } }]);
  // Event order and the final response incorporating tool results.
  assert.deepEqual(types(events), ["tool_start", "tool_end", "tool_start", "tool_end", "text_delta"]);
  assert.deepEqual(events[0], { type: "tool_start", id: "call_a", name: "appboundry_echo", input: { value: "alpha" } });
  assert.deepEqual(events[1], { type: "tool_end", id: "call_a", name: "appboundry_echo", content: "mcp:alpha", isError: false });
  assert.equal(events.at(-1).delta, "results: mcp:alpha | mcp:beta");
  assert.equal(result.stopReason, "end_turn");
  assert.deepEqual(result.usage, { inputTokens: 21, outputTokens: 9 });
  assert.deepEqual(outboundFetches, [], "the SDK never called fetch");
  await agent.close();
  mcpServer.calls.length = 0;
}

// apiKeyEnv: the credential goes to the configured provider only, as the model handle documents.
{
  process.env.FX_CERT_PROVIDER_KEY = "provider-key-123";
  reset((_entry, response) => say(response, "ok"));
  const keyed = await createFxModel({ id: "cert-keyed", baseUrl, model: "local-model", apiKeyEnv: "FX_CERT_PROVIDER_KEY", nativeAddon });
  const agent = await createFxAgent({ model: keyed });
  await drain(agent.prompt("hi"));
  assert.equal(log[0].headers.authorization, "Bearer provider-key-123");
  assert.ok(!JSON.stringify(log[0]).includes(GATEWAY_KEY));
  await agent.close();
}

// 7. Multi-round termination within the limit, and exactly maxSteps requests at the limit.
{
  reset((_entry, response, n) => callTools(response, [`loop_${n}`, "appboundry_echo", { value: String(n) }]));
  const agent = await createFxAgent({ model, tools: mcp.tools, maxSteps: 4 });
  const turn = agent.prompt("never stop");
  const events = await drain(turn);
  assert.equal((await turn.result).stopReason, "max_turn_requests");
  assert.equal(log.length, 4);
  assert.equal(events.filter((event) => event.type === "tool_end").length, 4);
  assert.equal(mcpServer.calls.length, 4);
  // History stays well formed: the agent still answers the next prompt.
  reset((_entry, response) => say(response, "fine"));
  assert.equal((await agent.prompt("again").result).stopReason, "end_turn");
  await agent.close();
  mcpServer.calls.length = 0;
}

// Parallel tool calls in one round all run and all return before the next request.
{
  reset((entry, response, n) => n === 1
    ? callTools(response, ["p1", "appboundry_echo", { value: "x" }], ["p2", "appboundry_echo", { value: "y" }])
    : say(response, toolMessages(entry).map((message) => message.content).join(",")));
  const agent = await createFxAgent({ model, tools: mcp.tools });
  const events = await drain(agent.prompt("two at once"));
  assert.deepEqual(types(events), ["tool_start", "tool_end", "tool_start", "tool_end", "text_delta"]);
  assert.equal(events.at(-1).delta, "mcp:x,mcp:y");
  await agent.close();
  mcpServer.calls.length = 0;
}

// 8. Failures are surfaced, classified, and leave the agent usable.
{
  const agent = await createFxAgent({ model, tools: mcp.tools });
  const expectFailure = async (label, install, check) => {
    reset(install);
    const turn = agent.prompt(label);
    await assert.rejects(drain(turn), (error) => { check(error); return true; }, label);
    await assert.rejects(turn.result, undefined, `${label} result`);
  };
  await expectFailure("http 500", (_e, r) => { r.writeHead(500, { "content-type": "application/json" }); r.end(JSON.stringify({ error: { message: "boom" } })); },
    (error) => { assert.equal(error.code, "LIBFX_MODEL_FAILED"); assert.equal(error.kind, "server_error"); assert.match(error.message, /boom/); });
  await expectFailure("http 429", (_e, r) => { r.writeHead(429, { "retry-after": "7" }); r.end("slow down"); },
    (error) => { assert.equal(error.kind, "rate_limited"); });
  await expectFailure("http 401", (_e, r) => { r.writeHead(401); r.end("nope"); },
    (error) => { assert.equal(error.kind, "unauthorized"); });
  await expectFailure("text tool call", (_e, r) => say(r, "<function=appboundry_echo>\n<parameter=value>\nhi\n</parameter>\n</function>"),
    (error) => { assert.equal(error.kind, "malformed_tool_call"); assert.equal(mcpServer.calls.length, 0, "text that looks like a tool call is never executed"); });
  // Malformed argument JSON is rejected by the provider client before any tool runs.
  reset((_e, r) => callTools(r, ["m1", "appboundry_echo", "{not json"]));
  await assert.rejects(drain(agent.prompt("bad args")), { code: "LIBFX_MODEL_REQUEST_FAILED", message: /InvalidToolArguments/ });
  assert.equal(mcpServer.calls.length, 0);
  // A tool the request never advertised is rejected by the provider client, not executed.
  reset((_e, r) => callTools(r, ["u1", "never_advertised", {}]));
  const unadvertised = agent.prompt("bad tool name");
  await assert.rejects(drain(unadvertised), { code: "LIBFX_MODEL_REQUEST_FAILED", message: /InvalidToolName/ });
  assert.equal(mcpServer.calls.length, 0);
  // Failed prompts are not kept in history.
  reset((_e, r) => say(r, "recovered"));
  assert.equal((await agent.prompt("after failures").result).stopReason, "end_turn");
  assert.deepEqual(log[0].body.messages, [{ role: "user", content: "after failures" }]);
  await agent.close();

  // Transport failure: nothing is listening, so the call rejects without a provider response.
  const dead = await createFxModel({ id: "cert-dead", baseUrl: "http://127.0.0.1:1/v1", model: "local-model", nativeAddon });
  const deadAgent = await createFxAgent({ model: dead });
  const deadTurn = deadAgent.prompt("hello");
  await assert.rejects(drain(deadTurn), { code: "LIBFX_MODEL_REQUEST_FAILED" });
  await assert.rejects(deadTurn.result, { code: "LIBFX_MODEL_REQUEST_FAILED" });
  await deadAgent.close();
}

// A tool that fails (MCP-side error result or a thrown error) goes back to the model as an error
// result; the turn continues and ends with the model's final answer.
{
  const client = {
    async listTools() { return { tools: [{ name: "broken", description: "always errors", inputSchema: { type: "object" } }] }; },
    async callTool() { return { isError: true, content: [{ type: "text", text: "upstream said no" }] }; },
  };
  const broken = await createMcpAdapter(client, { prefix: "appboundry_" });
  const thrown = [{ name: "flaky", description: "always throws", inputSchema: { type: "object" }, execute() { throw new Error("tool exploded"); } }];
  reset((entry, response, n) => n === 1
    ? callTools(response, ["f1", "appboundry_broken", {}], ["f2", "flaky", {}], ["f3", "appboundry_echo", { value: "ok" }])
    : say(response, `saw ${toolMessages(entry).map((m) => m.content).join(" / ")}`));
  const agent = await createFxAgent({ model, tools: [...broken.tools, ...thrown, ...mcp.tools] });
  const events = await drain(agent.prompt("break things"));
  const ends = events.filter((event) => event.type === "tool_end");
  assert.deepEqual(ends.map((event) => event.isError), [true, true, false]);
  assert.equal(events.at(-1).delta, "saw upstream said no / tool exploded / mcp:ok");
  assert.equal(mcpServer.calls.length, 1, "only the healthy call reached the MCP server");
  await agent.close();
  mcpServer.calls.length = 0;
}

// Finish reasons the native client treats as failures reject the turn with its cause.
{
  const agent = await createFxAgent({ model });
  reset((_e, r) => say(r, "cut off", "length"));
  await assert.rejects(agent.prompt("a").result, { code: "LIBFX_MODEL_REQUEST_FAILED", message: /OutputTruncated/ });
  reset((_e, r) => say(r, "", "content_filter"));
  await assert.rejects(agent.prompt("b").result, { code: "LIBFX_MODEL_REQUEST_FAILED", message: /ContentFiltered/ });
  await agent.close();
}

// Cancellation and cleanup reach the provider connection.
{
  const waitClosed = async (entry) => { for (let i = 0; i < 200 && !entry.closed; i++) await new Promise((r) => setTimeout(r, 10)); return entry.closed; };
  // cancel() mid-stream
  reset((_e, r) => { sse(r, [{ role: "assistant", content: "partial" }]); });
  const agent = await createFxAgent({ model });
  const turn = agent.prompt("hang");
  const seen = [];
  const consumer = (async () => { for await (const event of turn) seen.push(event); })();
  while (seen.length === 0) await new Promise((r) => setTimeout(r, 5));
  turn.cancel();
  await consumer;
  assert.equal((await turn.result).stopReason, "cancelled");
  assert.ok(await waitClosed(log[0]), "cancel closed the provider connection");
  // breaking out of the event loop cancels the request and settles the turn
  reset((_e, r) => { sse(r, [{ role: "assistant", content: "partial" }]); });
  const broken = agent.prompt("break");
  for await (const _ of broken) break;
  assert.equal((await broken.result).stopReason, "cancelled");
  assert.ok(await waitClosed(log[0]), "break closed the provider connection");
  // cancelling a turn nobody has consumed settles it and frees the agent
  reset((_e, r) => say(r, "x"));
  const idle = agent.prompt("unread");
  idle.cancel();
  assert.equal((await idle.result).stopReason, "cancelled");
  assert.equal(log.length, 0, "an unconsumed cancelled turn makes no request");
  // an abort signal passed to prompt()
  const controller = new AbortController();
  reset((_e, r) => { sse(r, [{ role: "assistant", content: "partial" }]); });
  const signalled = agent.prompt("signal", { signal: controller.signal });
  const signalledEvents = [];
  const reader = (async () => { for await (const event of signalled) signalledEvents.push(event); })();
  while (signalledEvents.length === 0) await new Promise((r) => setTimeout(r, 5));
  controller.abort();
  await reader;
  assert.equal((await signalled.result).stopReason, "cancelled");
  // close() mid-turn aborts the provider request and waits for the turn
  reset((_e, r) => { sse(r, [{ role: "assistant", content: "partial" }]); });
  const closing = agent.prompt("close me");
  const closingEvents = [];
  const closeReader = (async () => { for await (const event of closing) closingEvents.push(event); })();
  while (closingEvents.length === 0) await new Promise((r) => setTimeout(r, 5));
  await agent.close();
  await closeReader;
  assert.equal((await closing.result).stopReason, "cancelled");
  assert.ok(await waitClosed(log[0]), "close closed the provider connection");
  assert.throws(() => agent.prompt("late"), /closed/);
  await agent.close(); // idempotent
}

// Steering during a tool call reaches the provider before the next request.
{
  let turn;
  const steering = [{ name: "steer_me", description: "steers", inputSchema: { type: "object" }, async execute() { await turn.steer("also do the other thing"); return "done"; } }];
  reset((entry, response, n) => n === 1 ? callTools(response, ["s1", "steer_me", {}]) : say(response, `last user message: ${entry.body.messages.filter((m) => m.role === "user").at(-1).content}`));
  const agent = await createFxAgent({ model, tools: steering });
  turn = agent.prompt("start");
  const events = await drain(turn);
  assert.ok(events.some((event) => event.type === "user_message" && event.text === "also do the other thing"));
  assert.equal(events.at(-1).delta, "last user message: also do the other thing");
  await agent.close();
}

// Checkpoints resume with the model-visible history, and reject foreign data.
{
  reset((_e, r) => say(r, "first answer"));
  const agent = await createFxAgent({ model, instructions: "be brief" });
  await drain(agent.prompt("question one"));
  const checkpoint = await agent.checkpoint();
  await agent.close();
  reset((_e, r) => say(r, "second answer"));
  const resumed = await createFxAgent({ model, instructions: "be brief", checkpoint });
  await drain(resumed.prompt("question two"));
  assert.deepEqual(log[0].body.messages, [
    { role: "system", content: "be brief" },
    { role: "user", content: "question one" },
    { role: "assistant", content: "first answer" },
    { role: "user", content: "question two" },
  ]);
  await resumed.close();
  await assert.rejects(createFxAgent({ model, checkpoint: new Uint8Array([1, 2, 3]) }), /direct-model agent/);
}

// Diagnostics reach onEvent, and a throwing handler cannot break the turn.
{
  const diagnostics = [];
  reset((_e, r) => say(r, "ok"));
  const agent = await createFxAgent({ model, onEvent(event) { diagnostics.push(event.type); throw new Error("handler bug"); } });
  assert.equal((await agent.prompt("hi").result).stopReason, "end_turn");
  assert.deepEqual(diagnostics, ["model.request", "model.response"]);
  await agent.close();
}

// Throughout, nothing contacted anything but the scripted provider, and the SDK used no fetch.
assert.deepEqual(outboundFetches, []);
await mcp.close();
provider.closeAllConnections();
await new Promise((resolveClose) => provider.close(resolveClose));
console.log("direct agent provider certification passed (scripted provider; not a real-model result)");
