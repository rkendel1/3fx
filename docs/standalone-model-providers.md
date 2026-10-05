# Standalone model providers

fx can invoke a configured OpenAI Chat Completions endpoint without a vendor account. The existing terminal, filesystem, editing, search, MCP, skills, sessions, streaming, and TUI implementations are unchanged.

## Use Ollama

Start the server in one terminal:

```bash
ollama serve
```

In another terminal, download the model and run fx from your project:

```bash
ollama pull qwen3-coder
fx --provider ollama --model qwen3-coder
```

The preset uses `http://localhost:11434/v1` and omits the Authorization header. Its default model is `qwen3-coder`. An explicit connection named `ollama` overrides the preset, so you can use a different local port or model.

To run plain `fx`, save `{ "provider": "ollama" }` in `~/.fx/settings.json`. The preset does not probe for a running server or download models.

## Configure another endpoint

Save one provider in `~/.fx/settings.json`:

```json
{
  "provider": {
    "type": "openai-compatible",
    "baseURL": "http://localhost:1234/v1",
    "model": "your-local-model"
  }
}
```

`baseURL` is the API prefix. fx appends `/chat/completions`. Localhost HTTP is supported; non-loopback endpoints require HTTPS. The single-provider form uses the internal connection ID `custom` and enables function-tool use for the selected model. Choose a model that actually supports tools.

Authentication is optional. For an endpoint that requires a bearer token, add an environment-variable name instead of storing the token in the profile:

```json
{
  "provider": {
    "type": "openai-compatible",
    "baseURL": "https://openrouter.ai/api/v1",
    "model": "your-remote-model",
    "apiKeyEnv": "MODEL_API_KEY"
  }
}
```

Set `MODEL_API_KEY` through your normal secret-management mechanism. Without `apiKeyEnv`, no bearer token is sent. An unrelated Gateway credential is not used as a fallback. A required but unset environment variable produces a provider-credential error, not a vendor login flow.

The existing named `providers` registry remains supported. Don't combine it with the single-provider object. Use the registry when you need several endpoints, explicit capability metadata, or a permission-review model.

## Inspect configuration

```bash
fx providers
```

This reports the available protocol/preset choices and the selected provider, model, and endpoint. It does not test endpoint availability, enumerate vendor accounts, or verify credentials. `openrouter` in the informational list is an endpoint example, not a preconfigured account or automatic model selection.

With no explicit provider, a fresh `fx` launch prints:

```text
No model provider configured.
Configure a local or remote OpenAI-compatible provider in ~/.fx/settings.json.
Or run fx --provider ollama --model qwen3-coder.
```

Generic-provider launches skip vendor credential inventory and onboarding. Automatic upgrades default to disabled for these launches. A local endpoint needs no external model service, but user-requested shell commands, configured MCP servers, and an explicit `auto_upgrade: true` can still access the network.

## Build and verify this fork

The main application is Zig, not a Node application. Install Zig 0.16.0 and Bun for the integration tests. There is no root `package.json`; `npm install` and `npm test` are not this repository's build gate.

From the repository root:

```bash
zig build
zig build test
bun test tests/e2e/configured-providers.test.ts
```

Run the binary from this checkout:

```bash
./zig-out/bin/fx providers
./zig-out/bin/fx --provider ollama --model qwen3-coder
```

The deterministic integration test starts a fake localhost Chat Completions server and drives the real binary through reading a file, editing it, running a failing check, fixing the file, running a passing check, and receiving a fragmented SSE final response. It verifies omitted authorization and tool-result replay. A fake server proves runtime orchestration, not a real model's coding quality.

## Boundary status

The current Zig boundary uses `stream_provider.Provider` for typed chat requests and streamed events, `model_catalog.Provider` for model information, and `provider_set.Bundle` for composition. `gateway/chat_completions.zig` translates the OpenAI-compatible protocol. The agent owns tool execution and turns.

This change builds on those contracts rather than introducing a second TypeScript agent loop. It is not yet the complete proposed `ModelProvider` extraction: credential leases, vendor identities, and deferred billing references remain in shared agent contracts. Legacy auth commands and composition paths also remain. Those dependencies must be moved out of the agent boundary before declaring the full vendor-agnostic architecture acceptance gate satisfied.

Real Ollama interaction and the required Linux/macOS CI jobs remain separate validation gates. The Compute/PAX filesystem and terminal adapter work is not part of this change.
