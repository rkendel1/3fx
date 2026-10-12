# Changelog

Release notes for the `@appport/fx` npm package. The fx command line has its own
changelog at the repository root.

## 0.1.2

### New Features

- **Gateway-free agents:** `createFxAgent({ model })` accepts a `createFxModel()` handle and runs the agent loop against that provider directly. Ollama and other OpenAI-compatible endpoints work with streaming, structured tool calls, MCP tools, steering, cancellation, and checkpoints, and need no Vercel AI Gateway account, API key, or URL.

### Improvements

- **Clearer missing key error:** `createFxAgent()` without `apiKey` now explains that the key is for the Vercel AI Gateway and points to `createFxModel()` for other providers.

### Migration

Existing code is unaffected: a string or object `model`, or no `model`, still uses the Vercel AI Gateway and still requires `apiKey`. To leave the Gateway, replace `apiKey` and the model string with a model handle, and remove `apiKey`, `gatewayChatUrl`, `fetch`, `effort`, `fast`, and `ultrafast`, which a model handle rejects. Checkpoints do not move between the two kinds of agent.

## 0.1.1

### Bug Fixes

- **Tool calls written as text:** `createFxModel()` no longer reports a model reply as a successful completion when the model wrote a tool call as plain text, such as `<function=shell>` with `<parameter=...>` and `</function>`, instead of returning a structured tool call. Local servers such as Ollama with qwen3-coder do this intermittently. `chat()` now resolves `{ failed: { kind: "malformed_tool_call", detail } }`, and `stream()` ends with a `failure` event. `detail` is the original text, and fx never parses or runs it. Prose and fenced code examples that only mention the syntax, and replies with structured tool calls, are unchanged.

### Improvements

- **Tarball install check:** the release now installs the exact packed tarball into a clean project and exercises it from both ESM and CommonJS before publishing.
- **Smaller manifest:** the published `package.json` no longer lists repository-only test scripts, and the tarball includes this changelog.

## 0.1.0

Initial release of `@appport/fx` with `createFxAgent()`, `createFxTerminal()`, `createFxModel()`, and the browser and Node entry points.
