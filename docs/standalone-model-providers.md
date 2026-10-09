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

For a named provider that needs a shell-schema compatibility projection, set `tool_schema_mode` to `flatten_unions` in that provider's registry entry:

```json
{
  "providers": {
    "ollama": {
      "protocol": "openai-chat-completions",
      "base_url": "http://localhost:11434/v1",
      "auth": { "type": "none" },
      "tool_schema_mode": "flatten_unions"
    }
  }
}
```

The default `canonical` mode is unchanged. `flatten_unions` omits `oneOf` only from the recognized built-in `shell` schema; it advertises `run`, `interact`, and `stop` through one broader request object. FX still validates every shell request against the canonical action-specific contract before execution. This setting is an opt-in compatibility measure for a provider/model combination that does not return structured tool calls for the canonical schema; it does not imply that all Ollama models or compatible endpoints need it.

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

## Agent contract

`src/core/agent/model_provider.zig` defines `ModelProvider`, `ChatRequest`, `ChatStream`, and `ProviderCapabilities`. The contract imports only Zig's standard library. Its request and completion types do not carry vendor identities, credential leases, account metadata, or billing references.

`ModelProvider.chat` follows the existing synchronous streaming convention: it emits borrowed deltas through `EventSink`, then returns an allocator-owned terminal result. The caller releases that result with `ChatStream.deinit`. Cancellation is checked before invocation and during transport. `capabilities` describes protocol behavior, not an account entitlement.

`runtime/model_step.zig` is an independently compilable neutral invocation step. Agent runtime configuration now uses neutral `ModelFeatures`; legacy bundles project their feature flags at the host composition edge.

## Reference adapter

`gateway/openai_compatible_model_provider.zig` implements `OpenAICompatibleModelProvider` with a configuration ID, API prefix, model, and optional environment-variable name. An absent environment slot omits Authorization. A configured slot is resolved by the adapter for each invocation. No vendor login or credential lease is accepted by this adapter.

The direct neutral API currently advertises text chat, streaming, and function tools. It does not advertise vision or structured output. The transitional host bridge continues to use the established serializer for existing multimodal, reasoning-replay, and tool-projection behavior.

## Compatibility contracts

`stream_provider.Provider`, `model_catalog.Provider`, and `provider_set.Bundle` are transitional compatibility contracts, not the canonical model interface. `gateway/legacy_model_provider.zig` translates established requests and results at the transport edge. The configured-provider path invokes the neutral model step and reference adapter through this bridge. The hardened Chat Completions reducer is reused in the adapter.

This is not yet a fully extracted core agent loop. `runtime/orchestrator.zig`, `runtime/deps.zig`, `runtime/gateway_step.zig`, and shared job/message/recovery types still require legacy identities, credential refresh, and usage reconciliation. Existing vendor auth commands remain in place. The bridge preserves behavior while those control-plane responsibilities are moved; its existence does not make the whole agent vendor-neutral.

## Architectural verification

From the repository root:

```bash
zig build -Doptimize=Debug -j1
bun test tests/e2e/configured-providers.test.ts
python3 -B -m unittest scripts.tests.test_model_provider_boundary
python3 scripts/check-model-provider-boundary.py
```

The last command checks the transitive closure of the canonical contract and neutral invocation step. The regression tests deliberately introduce direct and transitive forbidden imports and an account field to verify that this check rejects them.

The full migration gate is stricter:

```bash
python3 scripts/check-model-provider-boundary.py --whole-agent
```

**This full-agent gate currently fails.** It traces runtime imports while excluding test fixtures and reports legacy dependencies and control-plane concepts that remain reachable from `agent_runtime.zig`. Do not substitute the narrower contract check for this acceptance gate.

To finish the extraction without replacing the tool loop:

1. Move model selection, authorization refresh, and billing reconciliation from the orchestrator into compatibility-owned invocation hooks.
2. Give the core loop neutral prompt, completion, replay, and recovery-authority types, with session conversion at the host boundary.
3. Route all model side calls, including compaction and vision handling, through `ModelProvider` without requiring legacy contracts in the loop.
4. Make the full-agent guard pass and verify the real binary's coding loop again.

Real Ollama inference, Compute/PAX integration, MCP architecture, tools, skills, session storage, TUI, and distribution changes are outside this extraction.
