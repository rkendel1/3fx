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

## Credentials and authority

Two different credentials exist in an AuthBoundry-governed AppBoundry
deployment. fx only ever handles the first.

| Credential | Shape | Held by | Purpose |
| --- | --- | --- | --- |
| Caller session credential | `apt_<tenant>.<session>` | The person or process running fx | Authenticates the caller. AppBoundry resolves it with `GET /auth/session`. |
| AppBoundry check credential | `abc_...` | AppBoundry's server | AppBoundry uses it to submit per-permission authorization checks to AuthBoundry. |

`FX_APPBOUNDRY_TOKEN` must hold the caller's session credential. Never put the
`abc_` check credential there. fx treats the value as an opaque bearer token and
does not validate its prefix, so it cannot tell the two apart; that guard is the
operator's responsibility.

Credential behavior, as implemented:

- The variable name is stored in the generated server config
  (`bearer_token_env`); the value is read from the process environment on each
  request and is never written to configuration, sessions, logs, traces, tool
  results, or the model prompt. Stored OAuth credentials are not used for
  discovered servers.
- The same credential is sent to discovery and to every discovered application.
  Both go only to the configured origin: advertised paths must be absolute
  paths on that origin, and redirects are never followed by discovery or by the
  MCP transport, so a 3xx response ends the request without re-sending the
  credential.
- The model supplies only tool arguments. Arguments travel in the JSON-RPC body;
  they cannot set headers or replace the credential. Discovery fields such as
  `principal`, `scopes`, `authorization`, or `headers` are ignored: the
  generated config carries only a name, an endpoint, and the environment
  variable name.
- Credential lifetime belongs to AuthBoundry. fx has no refresh flow. When the
  session expires or is signed out, the host answers 401 and the call fails;
  restart fx with a fresh credential. fx does not retry without credentials,
  does not downgrade to another mode, and does not cache a decision.

### Non-interactive credential acquisition: not verified

A session credential is currently obtained through a human sign-in. This work
found no documented AuthBoundry machine-identity or token-exchange contract that
fx can call, and it adds none. A human session is not a durable machine
credential: it can expire or be revoked mid-task. Follow-up for the owning
AuthBoundry repository: define and document a non-interactive agent credential
flow (issuance, scope, lifetime, revocation, and audit identity). Until then fx
accepts whatever `apt_` credential the operator supplies.

## Discovery is metadata, not authority

- `GET /.well-known/appport` and `tools/list` describe what exists. A tool
  appearing in a list is never a grant, and fx never records one as such.
- Every `tools/call` is a new request that AppBoundry authorizes against the
  caller's current AuthBoundry state. fx keeps no allow-list, decision cache,
  or policy copy, so a tool list discovered earlier does not survive
  revocation: the next call is refused by the host.
- Discovery is read once per MCP load and refreshed on `/mcp` reload. Revocation
  does not require a reload and does not require restarting AppBoundry.
- Descriptions, schemas, tool output, error messages, and `_meta` are untrusted
  input. They reach the model as tool output.
- Applications are namespaced as `mcp_appboundry_<selector>_<tool>`. Two
  applications exposing the same tool name stay distinct tools and are checked
  against their own permission. Two selectors that normalize to the same server
  name (`a.b` and `a_b`) keep only the first; the other is counted as rejected
  in the `mcp` trace.

## Errors and revocation

fx does not translate host decisions. A refusal is an error result with the
host's own code:

| Code | Meaning | Execution evidence |
| --- | --- | --- |
| HTTP 401 / server `needs_auth` | The session credential is missing, expired, or signed out. | None |
| `FORBIDDEN` | The caller lacks the declared permission, including after revocation. | None |
| `AUTHORITY_UNAVAILABLE` | AuthBoundry timed out, was unreachable, or answered unreadably. AppBoundry fails closed. | None |
| `INVALID_INPUT` | Arguments did not satisfy the contract. | None |
| `appboundry.SYNAPSE_*` | The capability ran and failed or trapped. | Present, with a failure outcome |
| Unknown tool or malformed response | The host did not recognize the call, or the response was not valid MCP. | None |

Every failure is a failed tool call (`status: "error"` in `fx ask --json`); fx
does not report any of them as success and does not retry.

## Evidence

AppBoundry attaches structured evidence in `_meta`, and fx forwards the result
to the model unchanged apart from fx's normal text sanitization:

- `appboundry/authorization`: authority, principal, and per-permission
  decisions with a `decisionId`. Present for allowed and refused calls.
- `appboundry/evidence`: capability, package identity, artifact hash, contract
  fingerprint, outcome, and `executionUnitId`. Present only when execution was
  attempted.

A refusal therefore has authorization evidence and no execution evidence; an
execution failure has execution evidence with a failure outcome. fx neither
creates, upgrades, nor verifies these records: they are claims made by the
host, and a result without them, or with malformed ones, carries no proof.
They are not proof that the user's goal was achieved.

Correlation is done outside fx. `executionUnitId` joins the execution evidence
to AppBoundry's invocation and usage records, and `decisionId` joins the
authorization evidence to AuthBoundry's durable decision and its recorded
execution context.

Known limit: when a result exceeds `max_tool_result_bytes`, the existing MCP
result cap replaces it with truncated text and `"truncated":true`, and the
structured `_meta` is not carried. Treat a truncated result as having no
evidence, and raise the cap or have the capability return less output. This is
existing MCP behavior and was left unchanged.

## Verification status

**Verified locally (ordinary CI, no external services).** `appboundry-authority.test.ts`
runs the built binary against a double of AppBoundry in authority mode
(`tests/e2e/fixtures/appboundry-authority-host.ts`) and proves: an authorized
call; invalid-session rejection; denial without a grant and without running the
module; a previously discovered tool list that does not bypass a later denial; revocation and sign-out taking effect on the next call in the same
process; forged arguments and discovery claims having no effect; fail-closed
behavior for `AUTHORITY_UNAVAILABLE` (unavailable, malformed, timeout);
execution failures; credentials never reaching another origin or a redirect
target; per-application separation; evidence preserved verbatim, correlated
across decision, invocation, and execution unit, and not invented when absent.
The double encodes the contract described above; it is not AuthBoundry or
AppBoundry, so these results do not show that the real services behave this way.

**Verified against the real service: not yet.** No AuthBoundry or AppBoundry
binary was available when this was written, so `appboundry-authority-live.test.ts`
has not been run. A skipped run means "not verified", never "verified".

**Not verified in a hosted tenant.** Hosted AuthBoundry API behavior, tenant
isolation, non-interactive credential acquisition, and production readiness are
all unproven.

## Tests

- Unit tests: `zig build test` (the `core/mcp/appboundry.zig` and
  `builtins/appboundry.zig` tests).
- Deterministic integration: `cd tests/e2e && bun test appboundry.test.ts` runs the built
  binary against an AppBoundry-shaped host that enforces tokens and scopes.
- Authority and revocation: `cd tests/e2e && bun test appboundry-authority.test.ts`
  (needs `zig build` first; uses the double described above).
- Real stack (opt-in): `appboundry-authority-live.test.ts` drives one fx process
  through an authorized call, a revocation, and a second call, against services
  you run yourself. It starts nothing and assumes no AuthBoundry endpoints.
  Prerequisites: a running AuthBoundry (serve, backed by FeltDB) and an
  AppBoundry host in authority mode with a packaged capability that declares a
  permission; an existing `apt_` session for a principal granted that
  permission; and a command that revokes the grant or signs the session out.

  ```sh
  cd tests/e2e
  FX_AUTHORITY_E2E_URL=http://127.0.0.1:4400 \
  FX_AUTHORITY_E2E_ALLOW_HTTP=1 \
  FX_AUTHORITY_E2E_SESSION='apt_<tenant>.<session>' \
  FX_AUTHORITY_E2E_QUERY='words from the capability description or tool name' \
  FX_AUTHORITY_E2E_ARGS='{"...":"..."}' \
  FX_AUTHORITY_E2E_REVOKE_CMD='<command that revokes the grant or signs out the session>' \
  FX_AUTHORITY_E2E_CORRELATE_CMD='<optional; reads FX_DECISION_ID and FX_EXECUTION_UNIT_ID, exits 0 if the AuthBoundry decision and AppBoundry record agree>' \
  bun test appboundry-authority-live.test.ts
  ```

  Without `FX_AUTHORITY_E2E_CORRELATE_CMD`, correlation against the durable
  records is reported as not verified.
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
