#!/usr/bin/env node
// Live integration test for createFxModel() against a local Ollama server.
//
// Not part of ordinary CI: it needs a running Ollama with the model pulled.
//   ollama pull qwen3-coder:latest
//   node sdk/tests/test-live-ollama.mjs [nativeAddon]
//
// Environment:
//   FX_LIVE_BASE_URL  OpenAI-compatible prefix (default http://localhost:11434/v1)
//   FX_LIVE_MODEL     model id (default qwen3-coder:latest)
//   FX_LIVE_ATTEMPTS  attempts allowed per scenario (default 5)
//
// The test passes only on real execution. The model must return a structured
// tool call; this script runs the tool itself and the model's final answer must
// contain a random value that exists nowhere except in that tool's output. Text
// that merely looks like a tool call never passes, and is counted separately.
// Exit codes: 0 passed, 1 failed, 2 Ollama or the model is unavailable.
import { strict as assert } from "node:assert";
import { randomBytes } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxModel } from "../node.js";

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

const model = await createFxModel({ baseUrl, model: modelId, nativeAddon });
const tools = [{
  name: "read_serial",
  description: "Returns the device serial number. Always call this tool to learn the serial; it cannot be guessed.",
  input_schema: { type: "object", properties: {}, additionalProperties: false },
}];
const tally = { structured: 0, malformed: 0, other: 0, executed: 0, answered: 0 };

async function attempt() {
  const serial = `SN-${randomBytes(6).toString("hex")}`;
  const messages = [
    { role: "system", content: "You have a tool named read_serial. Use it, then state the serial number it returned." },
    { role: "user", content: "What is the device serial number?" },
  ];
  const first = await model.chat({ messages, tools, max_output_tokens: 512 });
  if (first.failed) {
    if (first.failed.kind === "malformed_tool_call") tally.malformed++;
    else tally.other++;
    return { ok: false, reason: `first turn failed: ${first.failed.kind}` };
  }
  const calls = first.completed.tool_calls;
  if (calls.length === 0) {
    tally.other++;
    return { ok: false, reason: "no structured tool call" };
  }
  tally.structured++;
  assert.equal(calls[0].name, "read_serial");
  assert.doesNotThrow(() => JSON.parse(calls[0].arguments_json));
  // Real execution: this process runs the tool and returns its output.
  tally.executed++;
  const followUp = [
    ...messages,
    { role: "assistant", content: first.completed.content, tool_calls: calls },
    { role: "tool", tool_call_id: calls[0].id, content: JSON.stringify({ serial }) },
  ];
  const second = await model.chat({ messages: followUp, tools, max_output_tokens: 512 });
  if (second.failed) return { ok: false, reason: `second turn failed: ${second.failed.kind}` };
  if (!second.completed.content?.includes(serial)) return { ok: false, reason: `answer omitted the tool output ${serial}` };
  tally.answered++;
  return { ok: true };
}

let outcome;
const reasons = [];
for (let index = 1; index <= attempts && !outcome?.ok; index++) {
  outcome = await attempt();
  if (!outcome.ok) reasons.push(`attempt ${index}: ${outcome.reason}`);
}
console.log(`model ${modelId} at ${baseUrl}`);
console.log(`tally: ${JSON.stringify(tally)}`);
for (const reason of reasons) console.log(reason);
if (!outcome.ok) {
  console.error(`FAILED: no attempt executed the tool and returned its output in ${attempts} tries`);
  process.exit(1);
}
console.log("live Ollama test passed: structured tool call, real execution, tool output returned in the final answer");
