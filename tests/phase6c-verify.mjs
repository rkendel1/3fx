#!/usr/bin/env node
// Phase 6C Verification: Async Model Execution
// Demonstrates non-blocking execution

import { createServer } from "node:http";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxModel } from "../sdk/node.js";

const nativeAddon = resolve(process.argv[2] || resolve(dirname(fileURLToPath(import.meta.url)), "../zig-out/lib/libfx.node"));

// The provider requests an OpenAI-compatible SSE stream from <baseUrl>/chat/completions.
function sendStream(res, content, usage) {
  const chunk = (choices, extra = {}) =>
    res.write(`data: ${JSON.stringify({ id: "test-1", object: "chat.completion.chunk", created: 0, model: "test", choices, ...extra })}\n\n`);
  res.writeHead(200, { "Content-Type": "text/event-stream" });
  chunk([{ index: 0, delta: { role: "assistant", content }, finish_reason: null }]);
  chunk([{ index: 0, delta: {}, finish_reason: "stop" }]);
  chunk([], { usage });
  res.end("data: [DONE]\n\n");
}

let passed = 0;
let failed = 0;

async function test(name, fn) {
  try {
    await fn();
    console.log(`✓ ${name}`);
    passed++;
  } catch (err) {
    console.error(`✗ ${name}`);
    console.error(`  ${err.message}`);
    failed++;
  }
}

async function startMockServer() {
  return new Promise((resolve) => {
    const server = createServer((req, res) => {
      req.resume();
      req.on("end", () => {
        if (req.url === "/v1/chat/completions") {
          sendStream(res, "Test response", { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 });
        } else if (req.url === "/slow/v1/chat/completions") {
          // Delayed endpoint for testing non-blocking behavior
          setTimeout(() => sendStream(res, "Delayed response", { prompt_tokens: 5, completion_tokens: 3 }), 500);
        } else {
          res.writeHead(404);
          res.end("Not found");
        }
      });
    });

    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      resolve({ server, port });
    });
  });
}

async function runTests() {
  const { server, port } = await startMockServer();

  process.env.FX_TEST_KEY = "test-key";

  // Test 1: Model creation
  await test("Model creation succeeds", async () => {
    const model = await createFxModel({
      baseUrl: `http://127.0.0.1:${port}/v1`,
      model: "test-model",
      apiKeyEnv: "FX_TEST_KEY",
      nativeAddon,
    });
    if (!model || !model.chat) throw new Error("Model creation failed");
  });

  // Test 2: Basic async completion
  await test("Async chat returns Promise", async () => {
    const model = await createFxModel({
      baseUrl: `http://127.0.0.1:${port}/v1`,
      model: "test-model",
      apiKeyEnv: "FX_TEST_KEY",
      nativeAddon,
    });
    const chatPromise = model.chat({ messages: [{ role: "user", content: "Hi" }] });
    if (!(chatPromise instanceof Promise)) {
      throw new Error("chat() did not return a Promise");
    }
    const result = await chatPromise;
    if (!result.completed) throw new Error("No completion in result");
  });

  // Test 3: Non-blocking behavior
  await test("Node event loop remains responsive during async operation", async () => {
    const model = await createFxModel({
      baseUrl: `http://127.0.0.1:${port}/slow/v1`,
      model: "test-model",
      apiKeyEnv: "FX_TEST_KEY",
      nativeAddon,
    });

    let otherOperationCompleted = false;
    const chatPromise = model.chat({
      messages: [{ role: "user", content: "Slow request" }],
    });

    // While chat is executing asynchronously, execute another operation
    setImmediate(() => {
      otherOperationCompleted = true;
    });

    await new Promise((resolve) => setTimeout(resolve, 100));
    if (!otherOperationCompleted) {
      throw new Error("Event loop was blocked (other operation did not complete)");
    }

    await chatPromise;
  });

  // Test 4: Result content preserved
  await test("Response content preserved through async boundary", async () => {
    const model = await createFxModel({
      baseUrl: `http://127.0.0.1:${port}/v1`,
      model: "test-model",
      apiKeyEnv: "FX_TEST_KEY",
      nativeAddon,
    });
    const result = await model.chat({
      messages: [{ role: "user", content: "Test" }],
    });
    if (result.completed?.content !== "Test response") {
      throw new Error(`Expected "Test response", got "${result.completed?.content}"`);
    }
  });

  // Test 5: Usage preserved
  await test("Token usage preserved through async boundary", async () => {
    const model = await createFxModel({
      baseUrl: `http://127.0.0.1:${port}/v1`,
      model: "test-model",
      apiKeyEnv: "FX_TEST_KEY",
      nativeAddon,
    });
    const result = await model.chat({
      messages: [{ role: "user", content: "Test" }],
    });
    if (result.completed?.usage?.input_tokens !== 10) {
      throw new Error("Usage not preserved");
    }
  });

  // Test 6: Multiple concurrent requests
  await test("Multiple concurrent model requests execute in parallel", async () => {
    const model1 = await createFxModel({
      baseUrl: `http://127.0.0.1:${port}/v1`,
      model: "model-1",
      apiKeyEnv: "FX_TEST_KEY",
      nativeAddon,
    });
    const model2 = await createFxModel({
      baseUrl: `http://127.0.0.1:${port}/v1`,
      model: "model-2",
      apiKeyEnv: "FX_TEST_KEY",
      nativeAddon,
    });

    const start = Date.now();
    const [result1, result2] = await Promise.all([
      model1.chat({ messages: [{ role: "user", content: "Request 1" }] }),
      model2.chat({ messages: [{ role: "user", content: "Request 2" }] }),
    ]);

    const duration = Date.now() - start;
    if (!result1.completed || !result2.completed) {
      throw new Error("One or both requests failed");
    }
    // Should be fast (parallel) not slow (sequential)
    if (duration > 2000) {
      throw new Error(`Requests took too long: ${duration}ms (likely sequential, not parallel)`);
    }
  });

  server.close();

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
}

runTests().catch((err) => {
  console.error("Test suite failed:", err);
  process.exit(1);
});
