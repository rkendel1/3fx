import { createServer } from "node:http";
import assert from "node:assert";

describe("FX Model API", () => {
  let mockServer: ReturnType<typeof createServer>;
  let mockPort: number;

  before(async function () {
    this.timeout(5000);
    await new Promise<void>((resolve, reject) => {
      mockServer = createServer((req, res) => {
        if (req.method !== "POST") {
          res.writeHead(405);
          res.end("Method not allowed");
          return;
        }

        if (req.url === "/v1/chat/completions") {
          // OpenAI-compatible endpoint
          let body = "";
          req.on("data", (chunk) => {
            body += chunk;
          });
          req.on("end", () => {
            try {
              const request = JSON.parse(body);
              assert(request.messages, "Missing messages");
              assert(request.model, "Missing model");

              // Return deterministic response
              const response = {
                id: "chatcmpl-test-123",
                object: "chat.completion",
                created: Math.floor(Date.now() / 1000),
                model: request.model,
                choices: [
                  {
                    index: 0,
                    message: {
                      role: "assistant",
                      content: "Test response from mock server",
                    },
                    finish_reason: "stop",
                  },
                ],
                usage: {
                  prompt_tokens: 10,
                  completion_tokens: 5,
                  total_tokens: 15,
                },
              };

              res.writeHead(200, { "Content-Type": "application/json" });
              res.end(JSON.stringify(response));
            } catch (err) {
              res.writeHead(400);
              res.end("Invalid request");
            }
          });
          return;
        }

        // Error endpoint for failure testing
        if (req.url === "/v1/error") {
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(
            JSON.stringify({
              error: {
                message: "Mock server error",
                type: "server_error",
              },
            })
          );
          return;
        }

        res.writeHead(404);
        res.end("Not found");
      });

      mockServer.listen(0, "127.0.0.1", () => {
        const addr = mockServer.address();
        if (addr && typeof addr !== "string") {
          mockPort = addr.port;
          resolve();
        } else {
          reject(new Error("Could not bind mock server"));
        }
      });
    });
  });

  after(async function () {
    return new Promise<void>((resolve) => {
      mockServer.close(() => resolve());
    });
  });

  it("should create model and execute chat request", async function () {
    this.timeout(5000);

    try {
      const { createFxModel } = await import("../../../sdk/node.js");

      const model = await createFxModel({
        baseUrl: `http://127.0.0.1:${mockPort}`,
        model: "test-model",
        id: "test-openai",
        apiKeyEnv: "FX_TEST_KEY",
      });

      assert(model, "Failed to create model");
      assert(typeof model.chat === "function", "Model missing chat method");

      process.env.FX_TEST_KEY = "test-api-key";

      const result = await model.chat({
        messages: [
          {
            role: "user",
            content: "Hello, test!",
          },
        ],
      });

      assert(result, "No result returned");
      assert(
        result.completed,
        `Expected completed result, got: ${JSON.stringify(result)}`
      );
      assert.strictEqual(
        result.completed.content,
        "Test response from mock server"
      );
      assert(result.completed.usage, "Missing usage info");
      assert.strictEqual(result.completed.usage.input_tokens, 10);
      assert.strictEqual(result.completed.usage.output_tokens, 5);
    } catch (err) {
      throw err;
    }
  });

  it("should handle provider errors correctly", async function () {
    this.timeout(5000);

    try {
      const { createFxModel } = await import("../../../sdk/node.js");

      process.env.FX_TEST_KEY_ERROR = "test-api-key";

      const model = await createFxModel({
        baseUrl: `http://127.0.0.1:${mockPort}/v1/error`,
        model: "test-model",
        apiKeyEnv: "FX_TEST_KEY_ERROR",
      });

      const result = await model.chat({
        messages: [
          {
            role: "user",
            content: "This should fail",
          },
        ],
      });

      // Should return a failed result, not throw
      assert(result.failed, `Expected failed result, got: ${JSON.stringify(result)}`);
      assert(result.failed.kind, "Missing failure kind");
    } catch (err) {
      throw err;
    }
  });

  it("should handle multiple messages", async function () {
    this.timeout(5000);

    try {
      const { createFxModel } = await import("../../../sdk/node.js");

      process.env.FX_TEST_KEY_MULTI = "test-api-key";

      const model = await createFxModel({
        baseUrl: `http://127.0.0.1:${mockPort}`,
        model: "test-model",
        apiKeyEnv: "FX_TEST_KEY_MULTI",
      });

      const result = await model.chat({
        messages: [
          {
            role: "system",
            content: "You are a helpful assistant",
          },
          {
            role: "user",
            content: "First message",
          },
          {
            role: "assistant",
            content: "First response",
          },
          {
            role: "user",
            content: "Second message",
          },
        ],
      });

      assert(result.completed, "Expected completed result");
      assert.strictEqual(
        result.completed.content,
        "Test response from mock server"
      );
    } catch (err) {
      throw err;
    }
  });
});
