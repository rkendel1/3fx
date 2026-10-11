# AppBoundry capability provider

fx can use the governed capabilities that an [AppBoundry](https://appboundry.com)
host publishes. The integration is optional. When it is not configured, fx
behaves exactly as before.

AppBoundry stays responsible for authentication, scope enforcement, contract
validation, verified WASM execution, and invocation evidence. fx stays
responsible for reasoning, choosing a capability, generating arguments,
orchestration, and deciding whether the task is complete. fx never downloads or
runs AppBoundry WASM and has no copy of the AppBoundry catalog.

## Configure

Set two environment variables before starting fx:

```sh
export FX_APPBOUNDRY_URL=https://appboundry.example   # the trusted host origin
export FX_APPBOUNDRY_TOKEN=...                        # bearer token for that host
fx
```

| Variable | Meaning |
| --- | --- |
| `FX_APPBOUNDRY_URL` | Host origin. A path, query, fragment, or credentials in the URL are rejected. Setting it enables the provider. |
| `FX_APPBOUNDRY_TOKEN` | Bearer token. Read from the environment on each request; never stored. |
| `FX_APPBOUNDRY_APPS` | Optional comma-separated allowlist matched against each application's `selector` or `id`. |
| `FX_APPBOUNDRY_TIMEOUT_MS` | Optional bound for discovery, each connection, and each call. Default 5000, maximum 60000. |
| `FX_APPBOUNDRY_ALLOW_LOCAL_HTTP` | Set to `1` to permit plain `http://` for a loopback host (`127.0.0.1`, `localhost`, `[::1]`) with an explicit port. Any other plain-HTTP host is refused. |
| `FX_APPBOUNDRY_DISABLE` | Set to `1` to disable the provider without unsetting the URL. |

Keep the token in your shell profile, a secret manager, or a credentials file
that you source. Do not put it in `.fx.json`; project configuration cannot set
these values, and fx ignores them there.

## How it works

1. When fx loads MCP servers (at startup and on `/mcp` reload), it requests
   `GET /.well-known/appport` from the configured origin.
2. For each application whose `status` is `running` and that advertises an `mcp`
   path, fx creates a Streamable HTTP MCP server named
   `appboundry_<selector>`. The advertised path must be an absolute path on the
   configured origin. Full URLs, `//host` paths, `..` segments, queries,
   fragments, and encoded separators are rejected, and redirects are never
   followed, so the token cannot leave the configured origin.
3. fx's existing MCP client connects, runs `tools/list`, and keeps the
   application's tools behind capability search. The model sees no AppBoundry
   schemas until it selects a tool with `mcp_select_tool`, at which point the
   host's actual input schema is loaded for the next step.
4. The model calls the tool. fx sends `tools/call` with the bearer token. Results
   and errors, including AppBoundry's structured `_meta` evidence, return to the
   agent loop as untrusted tool output. A successful call does not mean the task
   is complete; the model decides that.

Tool names keep their origin: `mcp_appboundry_<selector>_<tool>`. If a name
collides, fx's existing collision rules apply. A manually configured MCP server
with the same name as a discovered one takes precedence.

fx does not retry `tools/call`. Discovery is repeated when MCP configuration is
reloaded, which also picks up added, removed, or stopped applications and
changed endpoints. Cached discovery is never treated as proof of authorization.

## Try it against a local host

```sh
# in an AppBoundry checkout, with APPPORT_MCP_TOKEN and APPPORT_MCP_SCOPES set
appport app deploy --artifact sha256:... --alias change-context --port 4400

export FX_APPBOUNDRY_URL=http://127.0.0.1:4400
export FX_APPBOUNDRY_TOKEN="$APPPORT_MCP_TOKEN"
export FX_APPBOUNDRY_ALLOW_LOCAL_HTTP=1
fx mcp list --connect
```

`fx mcp list` without `--connect` reads only saved configuration and does not
show discovered AppBoundry servers.

## Diagnose problems

| Symptom | Likely cause |
| --- | --- |
| No `appboundry_*` server in `fx mcp list --connect` | The URL is unset or `FX_APPBOUNDRY_DISABLE=1`; the URL is plain HTTP without `FX_APPBOUNDRY_ALLOW_LOCAL_HTTP=1` on a loopback host; the host was unreachable or timed out; the application is stopped, has no `mcp` path, or is filtered out by `FX_APPBOUNDRY_APPS`; or its advertised endpoint left the origin. |
| Server `needs_auth` | The host rejected the token. Check `FX_APPBOUNDRY_TOKEN` and that the host has MCP enabled. |
| Server ready with `tools=0` or a missing tool | The token's scopes do not include the capability. AppBoundry lists only the tools its scopes allow. |
| Tool call returns `FORBIDDEN` | The scope was missing at call time. AppBoundry decided; fx does not override it. |
| Tool call returns `INVALID_INPUT` | The arguments did not satisfy the contract. Select the tool again and follow its schema. |
| Tool call returns `appboundry.SYNAPSE_*` | The capability failed or trapped inside AppBoundry. The host keeps the failure record. |

Set `FX_TRACE_LOG=/path/to/log FX_TRACE_SCOPES=mcp` for diagnostic traces. They
record counts and error names only, never the token, the URL, or response
bodies.

## Tests

- Unit tests: `zig build test` (the `core/mcp/appboundry.zig` and
  `builtins/appboundry.zig` tests).
- Deterministic integration: `cd tests/e2e && bun test appboundry.test.ts` runs the built
  binary against an AppBoundry-shaped host that enforces tokens and scopes.
- Live host: `appboundry-live.test.ts` is opt-in. Set `FX_APPBOUNDRY_E2E_URL`,
  `FX_APPBOUNDRY_E2E_TOKEN`, `FX_APPBOUNDRY_E2E_QUERY`, and
  `FX_APPBOUNDRY_E2E_ARGS` (plus `FX_APPBOUNDRY_E2E_ALLOW_HTTP=1` for loopback).
  fx's capability search ranks description words only when they distinguish
  between tools, so against a host that exposes a single tool, use a query
  that matches the tool name.

## Limits

- Discovery is synchronous and bounded by `FX_APPBOUNDRY_TIMEOUT_MS`, so an
  unreachable host can delay MCP startup by up to that long.
- One token applies to the whole host; per-application tokens are not supported.
- Only the `AppPort/host-discovery/1` document is understood.
