#!/usr/bin/env node
// Opt-in live check for createFxAgent() with a local Ollama-compatible model
// and an MCP-style tool. Not part of CI: it needs a running Ollama.
//   ollama pull qwen3-coder:latest
//   node sdk/tests/test-live-ollama-agent.mjs [nativeAddon]
//
// Environment: FX_LIVE_BASE_URL, FX_LIVE_MODEL, FX_LIVE_ATTEMPTS as in
// test-live-ollama.mjs. No Vercel AI Gateway credential is read or needed.
//
// The agent loop calls a real model here. It passes only when the model returns
// a structured tool call, the MCP tool executes, and the final answer contains a
// random value that exists only in that tool's output.
// Exit codes: 0 passed, 1 failed, 2 Ollama or the model is unavailable.
import { strict as assert } from "node:assert";
import { randomBytes } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, createFxModel } from "../node.js";
import { createMcpAdapter } from "../mcp.js";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const nativeAddon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const baseUrl = process.env.FX_LIVE_BASE_URL ?? "http://localhost:11434/v1";
const modelId = process.env.FX_LIVE_MODEL ?? "qwen3-coder:latest";
const attempts = Number(process.env.FX_LIVE_ATTEMPTS ?? 5);

try {
  const tags = await fetch(new URL("../api/tags", `${baseUrl}/`), { signal: AbortSignal.timeout(5000) });
  const names = (await tags.json()).models?.map((entry) => entry.name) ?? [];
  if (!names.includes(modelId)) {
    console.error(`unavailable: ${modelId} is not installed (found: ${names.join(", ") || "none"})`);
    process.exit(2);
  }
} catch (error) {
  console.error(`unavailable: cannot reach Ollama at ${baseUrl}: ${error.message}`);
  process.exit(2);
}

// From here on, any fetch would be a gateway or catalog call the direct agent must not make.
const realFetch = globalThis.fetch;
globalThis.fetch = (...args) => { throw new Error(`unexpected fetch ${String(args[0])}`); };
void realFetch;

const model = await createFxModel({ baseUrl, model: modelId, nativeAddon });

async function attempt() {
  const serial = `SN-${randomBytes(6).toString("hex")}`;
  const executed = [];
  const mcp = await createMcpAdapter({
    async listTools() {
      return { tools: [{ name: "read_serial", description: "Returns the device serial number. Always call this tool to learn the serial; it cannot be guessed.", inputSchema: { type: "object", properties: {}, additionalProperties: false } }] };
    },
    async callTool({ name }) {
      executed.push(name);
      return { content: [{ type: "text", text: JSON.stringify({ serial }) }] };
    },
  }, { prefix: "appboundry_" });
  const agent = await createFxAgent({
    model,
    tools: mcp.tools,
    instructions: "You have a tool for the device serial number. Use it, then state the serial number it returned.",
    maxSteps: 6,
  });
  try {
    const turn = agent.prompt("What is the device serial number?");
    let text = "";
    let toolEnds = 0;
    for await (const event of turn) {
      if (event.type === "text_delta") text += event.delta;
      if (event.type === "tool_end" && !event.isError) toolEnds++;
    }
    const result = await turn.result;
    if (result.stopReason !== "end_turn") return { ok: false, reason: `stopped with ${result.stopReason}` };
    if (executed.length === 0 || toolEnds === 0) return { ok: false, reason: "tool was never executed" };
    if (!text.includes(serial)) return { ok: false, reason: `answer omitted the tool output ${serial}` };
    return { ok: true };
  } catch (error) {
    return { ok: false, reason: `turn failed: ${error.message}` };
  } finally {
    await agent.close();
    await mcp.close();
  }
}

let outcome;
const reasons = [];
for (let index = 1; index <= attempts && !outcome?.ok; index++) {
  outcome = await attempt();
  if (!outcome.ok) reasons.push(`attempt ${index}: ${outcome.reason}`);
}
console.log(`model ${modelId} at ${baseUrl}`);
for (const reason of reasons) console.log(reason);
assert.ok(outcome, "no attempts ran");
if (!outcome.ok) {
  console.error(`FAILED: no attempt completed a tool-calling interaction in ${attempts} tries`);
  process.exit(1);
}
console.log("live Ollama agent test passed: structured tool call, MCP tool executed, final answer used its output");
