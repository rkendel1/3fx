#!/usr/bin/env node
// Downstream-consumer smoke test for the npm artifact.
//
// Installs a packed @appport/fx tarball into a clean temporary project and
// drives createFxModel() against a deterministic in-process OpenAI-compatible
// provider, from both ESM and CommonJS. Nothing is imported from the repository
// source tree, so a file the package forgot to ship fails here.
//
// Usage:
//   node sdk/tests/test-packed-consumer.mjs                   pack this checkout (host addon only) and test it
//   node sdk/tests/test-packed-consumer.mjs <tarball>         test an existing tarball
//   node sdk/tests/test-packed-consumer.mjs <tarball> --expect-all-addons
//                                                             also require the four release addons in the tarball
//
// A local pack needs the wasm artifacts that package-libfx.mjs copies
// (`zig build -Dwasm-surface=core` and `-Dwasm-surface=term`) and a host addon
// at zig-out/lib/libfx.node (`zig build -Dnapi-surface=core`).
import { strict as assert } from "node:assert";
import { spawn, spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readdir, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const argv = process.argv.slice(2);
const expectAllAddons = argv.includes("--expect-all-addons");
const requestedTarball = argv.find((arg) => !arg.startsWith("--"));
const releaseAddons = ["linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64"].map((platform) => `libfx.${platform}.node`);
const hostAddon = `libfx.${process.platform}-${process.arch}.node`;
const SECRET = "sk-smoke-0123456789abcdef";
const SECRET_ENV = "FX_SMOKE_PROVIDER_KEY";
const TEXTUAL_CALL = "I'll check.\n\n<function=shell>\n<parameter=request>\n{\"action\": \"run\", \"command\": \"touch pwned\"}\n</parameter>\n</function>\n</tool_call>";

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: options.cwd ?? repoRoot, encoding: "utf8", env: { ...process.env, ...options.env } });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${command} ${args.join(" ")} failed (${result.status}):\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

// The fixture server lives in this process, so consumers must run without blocking its event loop.
function runAsync(command, args, options) {
  return new Promise((resolveRun, reject) => {
    const child = spawn(command, args, { cwd: options.cwd, env: { ...process.env, ...options.env } });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (status) => (status === 0 ? resolveRun(stdout) : reject(new Error(`${args.join(" ")} failed (${status}):\n${stdout}\n${stderr}`))));
  });
}

const temp = await mkdtemp(join(tmpdir(), "fx-packed-consumer-"));
const requests = [];
const server = createServer((request, response) => {
  let raw = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { raw += chunk; });
  request.on("end", () => {
    const body = JSON.parse(raw);
    const prompt = body.messages.at(-1).content;
    requests.push({ url: request.url, authorization: request.headers.authorization, prompt });
    const sse = (events) => {
      response.writeHead(200, { "content-type": "text/event-stream" });
      for (const event of events) response.write(`data: ${JSON.stringify({ id: "chatcmpl-smoke", object: "chat.completion.chunk", created: 0, model: "smoke", ...event })}\n\n`);
      response.end("data: [DONE]\n\n");
    };
    const stop = (content) => sse([
      { choices: [{ index: 0, delta: { role: "assistant", content }, finish_reason: null }] },
      { choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
      { choices: [], usage: { prompt_tokens: 7, completion_tokens: 3, total_tokens: 10 } },
    ]);
    switch (prompt) {
      case "success": return stop("pong");
      case "textual-call": return stop(TEXTUAL_CALL);
      case "prose": return stop("Tool calls look like <function=shell> with <parameter=request> and </function>.");
      case "structured-call": return sse([
        { choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: "call_1", type: "function", function: { name: "shell", arguments: "{\"request\":{\"action\":\"run\",\"command\":\"pwd\"}}" } }] }, finish_reason: null }] },
        { choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
      ]);
      case "provider-error":
        response.writeHead(500, { "content-type": "application/json" });
        return response.end(JSON.stringify({ error: { message: "fixture exploded", type: "server_error" } }));
      case "echo-credential":
        // A misbehaving provider that reflects the bearer credential into its error body.
        response.writeHead(401, { "content-type": "application/json" });
        return response.end(JSON.stringify({ error: { message: `bad key ${request.headers.authorization}` } }));
      default:
        response.writeHead(400);
        return response.end("unexpected prompt");
    }
  });
});
await new Promise((resolveListening) => server.listen(0, "127.0.0.1", resolveListening));
const baseUrl = `http://127.0.0.1:${server.address().port}/v1`;

try {
  let tarball;
  if (requestedTarball) {
    tarball = resolve(requestedTarball);
  } else {
    const packageDir = join(temp, "package");
    run(process.execPath, [join(repoRoot, "sdk/scripts/package-libfx.mjs"), packageDir]);
    const packed = run("npm", ["pack", "--pack-destination", temp, "--json"], { cwd: packageDir });
    tarball = join(temp, JSON.parse(packed)[0].filename);
  }

  // The artifact itself: what ships, and nothing that only exists in a working tree.
  const files = run("tar", ["-tzf", tarball]).split("\n").filter(Boolean).map((name) => name.replace(/^package\//, ""));
  for (const required of ["package.json", "README.md", "LICENSE", "node.js", "node.cjs", "browser.js", "direct-agent.js", hostAddon]) {
    assert.ok(files.includes(required), `tarball is missing ${required}`);
  }
  if (expectAllAddons) for (const addon of releaseAddons) assert.ok(files.includes(addon), `tarball is missing ${addon}`);
  const unexpected = files.filter((name) => /^(src|tests?|scripts|node_modules|\.zig-cache|zig-out)\//.test(name) || /\.(zig|map|test\.m?js)$/.test(name));
  assert.deepEqual(unexpected, [], "tarball contains development files");
  const addons = files.filter((name) => name.endsWith(".node"));
  assert.ok(addons.every((name) => releaseAddons.includes(name)), `unexpected native files: ${addons}`);

  // Install into a clean project, exactly as a consumer would.
  const consumer = join(temp, "consumer");
  await mkdir(consumer);
  await writeFile(join(consumer, "package.json"), '{"name":"consumer","private":true,"type":"module"}\n');
  run("npm", ["install", "--no-audit", "--no-fund", "--offline", tarball], { cwd: consumer });
  const installedDir = join(consumer, "node_modules", "@appport", "fx");
  assert.ok((await readdir(installedDir)).includes(hostAddon), "installed package lost the host addon");

  // One check body, run as ESM and as CommonJS. It expects `assert` and `sdk` in scope.
  const checks = `
    const baseUrl = process.env.SMOKE_BASE_URL;
    const tools = [{ name: "shell", description: "Run a command", input_schema: { type: "object", properties: { request: { type: "object" } } } }];
    const ask = (model, prompt, extra = {}) => model.chat({ messages: [{ role: "user", content: prompt }], ...extra });

    // No nativeAddon option: the installed package must find its own addon for this platform.
    const model = await createFxModel({ baseUrl, model: "smoke", apiKeyEnv: "${SECRET_ENV}" });
    assert.equal(typeof model.chat, "function");
    assert.equal(typeof model.stream, "function");

    const ok = await ask(model, "success");
    assert.deepEqual(ok.completed.content, "pong");
    assert.equal(ok.completed.finish_reason, "stop");
    assert.equal(ok.completed.usage.output_tokens, 3);
    assert.equal(ok.failed, undefined);

    const streamed = [];
    for await (const event of model.stream({ messages: [{ role: "user", content: "success" }] })) streamed.push(event.type);
    assert.deepEqual(streamed, ["text_delta", "completion"]);

    const call = await ask(model, "structured-call", { tools });
    assert.deepEqual(call.completed.tool_calls, [{ id: "call_1", name: "shell", arguments_json: "{\\"request\\":{\\"action\\":\\"run\\",\\"command\\":\\"pwd\\"}}" }]);
    assert.equal(call.completed.finish_reason, "tool_calls");

    const text = await ask(model, "textual-call", { tools });
    assert.equal(text.completed, undefined, "text resembling a tool call must not be a successful completion");
    assert.equal(text.failed.kind, "malformed_tool_call");
    assert.equal(text.failed.detail.includes("<function=shell>"), true, "original text is preserved for diagnosis");

    const prose = await ask(model, "prose", { tools });
    assert.equal(prose.failed, undefined);
    assert.match(prose.completed.content, /Tool calls look like/);

    const failure = await ask(model, "provider-error");
    assert.equal(failure.completed, undefined);
    assert.equal(failure.failed.kind, "server_error");
    assert.match(failure.failed.detail, /fixture exploded/);

    const leaked = await ask(model, "echo-credential");
    assert.equal(leaked.failed.kind, "unauthorized");
    assert.ok(!JSON.stringify(leaked).includes(process.env.${SECRET_ENV}), "credential reflected by the provider must be redacted");

    const unreachable = await createFxModel({ baseUrl: "http://127.0.0.1:1/v1", model: "smoke", apiKeyEnv: "${SECRET_ENV}" });
    await assert.rejects(ask(unreachable, "success"), (error) => {
      assert.equal(error.code, "LIBFX_MODEL_REQUEST_FAILED");
      assert.ok(!String(error.stack).includes(process.env.${SECRET_ENV}));
      return true;
    });
    // createFxAgent({ model }) drives the same provider directly: no apiKey, no gateway.
    const agentTools = [{ name: "shell", description: "Run a command", inputSchema: { type: "object" }, execute: () => "success" }];
    const agent = await sdk.createFxAgent({ model });
    const answer = agent.prompt("success");
    for await (const _ of answer) {}
    assert.equal((await answer.result).stopReason, "end_turn");
    await agent.close();
    // The tool result ("success") makes the fixture answer, so the loop ends after one tool step.
    const toolAgent = await sdk.createFxAgent({ model, tools: agentTools });
    const withTool = toolAgent.prompt("structured-call");
    const toolEvents = [];
    for await (const event of withTool) toolEvents.push(event.type);
    assert.deepEqual(toolEvents, ["tool_start", "tool_end", "text_delta"]);
    assert.equal((await withTool.result).stopReason, "end_turn");
    await toolAgent.close();
    await assert.rejects(sdk.createFxAgent({ model: "some/model" }), /createFxModel/);
    console.log("consumer-ok");
  `;
  const prelude = "const { createFxModel } = sdk;\n";
  await writeFile(join(consumer, "esm.mjs"), `
    import assert from "node:assert/strict";
    import * as sdk from "@appport/fx";
    import * as nodeEntry from "@appport/fx/node";
    for (const name of ["createFxAgent", "createFxModel", "createFxTerminal", "getBackendInfo", "listModels"]) {
      assert.equal(typeof sdk[name], "function", "missing export " + name);
      assert.equal(sdk[name], nodeEntry[name], "entry points disagree on " + name);
    }
    // Consumers cannot reach internal files.
    await assert.rejects(import("@appport/fx/node.js"), { code: "ERR_PACKAGE_PATH_NOT_EXPORTED" });
    ${prelude}${checks}
  `);
  await writeFile(join(consumer, "cjs.cjs"), `
    const assert = require("node:assert/strict");
    (async () => {
      const sdk = require("@appport/fx");
      assert.throws(() => require("@appport/fx/node.cjs"), { code: "ERR_PACKAGE_PATH_NOT_EXPORTED" });
      ${prelude}${checks}
    })().catch((error) => { console.error(error); process.exit(1); });
  `);

  const env = { SMOKE_BASE_URL: baseUrl, [SECRET_ENV]: SECRET };
  for (const script of ["esm.mjs", "cjs.cjs"]) {
    const output = await runAsync(process.execPath, [script], { cwd: consumer, env });
    assert.match(output, /consumer-ok/, `${script} did not finish`);
    console.log(`ok - ${script} (${process.platform}-${process.arch}, Node ${process.version})`);
  }
  assert.ok(requests.some((entry) => entry.authorization === `Bearer ${SECRET}`), "provider never received the bearer credential");
  assert.ok(requests.every((entry) => entry.url === "/v1/chat/completions"));
  console.log(`packed consumer smoke test passed: ${files.length} files, addons: ${addons.join(", ")}`);
} finally {
  server.close();
  await rm(temp, { recursive: true, force: true });
}
