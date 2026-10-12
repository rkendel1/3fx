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

### Machine-agent identity: audited, and not available

Audit of AuthBoundry `44f6059` (read from source and documentation, then
exercised by the real-service tests below):

- Callers authenticate with a session credential, `apt_<tenant>.<session>`,
  accepted as `Authorization: Bearer`, the `authboundry_session` cookie, or the
  `x-authboundry-session` header. The tenant segment is re-checked against
  stored state on every request. A session lives for 3600 seconds and is revoked
  by sign-out or by an administrator.
- The only way this work found to obtain a session without a browser is
  `POST /_authboundry/browser/credentials`, a username and password sign-in for
  a human account. It is how the test harness signs in generated test accounts.
  It is not a machine credential, and fx does not call it.
- There is no OAuth client-credentials grant, token exchange, or API-key flow
  that mints an `apt_` session. Agents, delegations, and service principals
  exist as principals and policy subjects, not as credentials. AppBoundry's
  contract records the same gap (limitation L14).
- The `abc_<id>.<secret>` check credential is bound to one application, resolves
  to no principal, can only ask authorization questions, and is stored hashed.
  The audit found no expiry field. It belongs to AppBoundry's server.

Consequence: an unattended fx agent has no supported way to acquire or renew a
credential. Owner: AuthBoundry. Required: a documented non-interactive agent
credential flow covering issuance, scope, lifetime, revocation, and audit
identity. fx adds none and does not treat a human session as a durable machine
credential. fx refuses to start the provider when `FX_APPBOUNDRY_TOKEN` begins
with `abc_`, so a check credential is never sent to a host by mistake.

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

Truncation: the MCP result cap used to replace an oversized result with
truncated text, and `_meta` was lost with it. The cause was in fx's result
handling, not in the protocol, which keeps `_meta` separate from `content`. fx
now keeps a bounded copy of `_meta` (at most 8 KiB, sanitized like other result
text) in the truncated envelope. When `_meta` is larger than that, the envelope
says `"meta_omitted":true` instead of cutting it. Evidence is therefore never
silently dropped or partially kept; treat `meta_omitted` as "no evidence". The
text the cap shortens, and `structuredContent`, which a truncated envelope has
never carried, remain subject to the cap.

## Verification status

Three levels, kept apart. Nothing here is a production-readiness claim.

### Verified against the real services

Stack under test (2026-10-12, Linux x86_64, 4 CPUs, everything on loopback):

| Component | Version |
| --- | --- |
| AuthBoundry (`authboundry serve`, FeltDB-backed, built from source with rustc 1.97.0) | git `44f60599f55dca1886c0e04e559dd29f773e5d74`, package 1.15.3 |
| AppBoundry host (`appport` CLI, authority mode) | git `b3b4a8dc1ab715824c9850ea5541aed972d73a9b`, `appport` 1.1.20 |
| FeltDB client used by AuthBoundry's bridge | `@feltdb/core` 0.11.7 |
| fx | 0.0.13 built from this branch |
| Node / pnpm | 22.22.0 / 10.33.0 |

`appboundry-real-stack.test.ts` passes 10 of 10 against that stack. Identities,
passwords, tenants, and credentials are generated for each run in a temporary
directory; nothing is read from or written to a hosted service.

| # | Property | Result |
| --- | --- | --- |
| 1 | Unauthenticated request rejected | Verified. No credential and a forged `apt_` session both get 401 and list no tools. |
| 2 | Authenticated but unauthorized request rejected | Verified through the protocol: `FORBIDDEN`, a deny decision with a `decisionId`, no execution evidence. fx itself is never shown a tool for an ungranted principal. |
| 3 | Only permitted capabilities discovered | Verified. A principal granted one application sees one tool in it and none elsewhere. `/.well-known/appport` itself is public by contract and lists every application. |
| 4 | Permitted capability executes | Verified through fx, with output and evidence. |
| 5 | Revocation or sign-out applies to the next call in the same fx process | Verified for both. The tool list fx discovered earlier did not help. |
| 6 | Denied invocation never executes | Verified with a module that traps if it runs: no completed record and no failure usage record after denial. |
| 7 | Correlation | Verified: result `decisionId` equals AuthBoundry's durable decision, whose recorded execution unit equals the result's `executionUnitId`, AppBoundry's invocation record, and its usage record. A refusal and an execution failure stay distinguishable. |
| 8 | Cross-tenant access rejected | Verified for another tenant's session and for a session with its tenant segment swapped. Not verified: identical principal names in two tenants, cross-tenant policy writes. |
| 9 | Restart | Verified for an unclean (SIGKILL) restart of AuthBoundry: a revoked grant stays revoked, a signed-out session stays signed out, earlier decisions remain, the issued check credential still works, and an outage fails closed with no execution. Not verified: restarting the AppBoundry host, remote FeltDB. |
| 10 | Evidence survives result truncation | Verified. See Evidence above. |

AppBoundry's own `authority-boundary.test.ts` also passes 19 of 19 against the
same AuthBoundry build (12 against its in-process double, 7 against the real
service).

Credential handling, verified in those runs: the session credential and the
`abc_` prefix are absent from fx's stdout and stderr and from every request fx
made to the model provider; every request to the host carried the caller's
session credential and nothing else.

### Verified locally with a double

`appboundry-authority.test.ts` (19 tests) runs the built binary against
`fixtures/appboundry-authority-host.ts`, a double of AppBoundry in authority
mode with AuthBoundry-shaped state. It covers failure modes the real service
cannot be asked to produce (authority unavailable, malformed, timeout),
redirects and other-origin endpoints (the credential reaches no other origin
and no redirect target), forged arguments and discovery claims, same-named
tools in two applications, a check credential in the token variable, and
truncation. It also runs in ordinary CI. Its wire shapes (`decisions[].decision`,
`outcome: success|failure`, `appboundry.SYNAPSE_TRAP`) match the real service
as observed, but the double is not evidence about the real service.

### Not verified

- A hosted AuthBoundry or AppBoundry tenant, hosted tenant isolation, and
  anything over a network rather than loopback.
- Non-interactive credential acquisition (it does not exist yet).
- Revocation of an execution that is already running (AppBoundry documents that
  it is not interrupted).
- PAX observation of these records.
- Any other fx platform than the one above. Full CI results for the pushed
  commit are reported on the pull request, not here.

## Latency

`benchmarks/appboundry_authority.ts`, 30 iterations after 3 warmups, against the
real stack above (milliseconds, wall clock):

| Measurement | median | p95 | mean | min |
| --- | --- | --- | --- | --- |
| protocol: no credential (rejected before any authority call) | 0.3 | 0.7 | 0.3 | 0.2 |
| protocol: denied (session lookup, one durable decision, no module) | 18.5 | 23.6 | 18.9 | 16.1 |
| protocol: allowed (decision, module, records, evidence) | 25.0 | 38.3 | 26.9 | 20.5 |
| discovery: `GET /.well-known/appport` | 4.9 | 6.7 | 5.1 | 4.5 |
| discovery: `fx mcp list --connect` (3 applications) | 81.4 | 98.1 | 82.4 | 68.3 |
| `fx ask`, search only (baseline) | 106.8 | 123.7 | 108.3 | 90.3 |
| `fx ask`, one allowed call | 195.7 | 225.1 | 197.9 | 177.2 |

Reading them: one authorization decision, including the session lookup, costs
about 18 ms on loopback; running the module and recording evidence adds about 7
ms; the allowed call adds about 89 ms to an fx run, which also covers the extra
select-tool and call turns, not only the call. A denied call is timed at the
protocol layer only, because a new fx process after revocation is no longer
shown the tool. These numbers have no baseline from an earlier version and set
no budget. They bound software cost on one machine; they say nothing about a
hosted AuthBoundry over a real network.

## Tests

- Unit tests: `zig build test` (the `core/mcp/appboundry.zig`,
  `builtins/appboundry.zig`, and `core/mcp/tool_result.zig` tests).
- Deterministic integration: `cd tests/e2e && bun test appboundry.test.ts` runs the built
  binary against an AppBoundry-shaped host that enforces tokens and scopes.
- Authority and revocation with a double, in ordinary CI:
  `cd tests/e2e && bun test appboundry-authority.test.ts` (needs `zig build` first).
- Real stack, opt-in. Prerequisites:
  - An AuthBoundry checkout whose binary matches its own flow file. Build it:
    `cargo build --release --bin authboundry`. The `native/linux-x64/authboundry`
    binary committed at `44f6059` does not start against that checkout's
    `authboundry.flow` (`unknown AppPort service configuration`).
  - An AppBoundry checkout with `pnpm install` and `pnpm --filter appport build`
    done (the root `pnpm build` fails at `b3b4a8d` in `packages/appboundry`).
  - `@feltdb/core@0.11.7` installed in a directory of your choice.
  - Node 22, pnpm, and a `zig build` of fx.

  ```sh
  cd tests/e2e
  FX_REAL_STACK=1 \
  AUTHBOUNDRY_DIR=/path/to/authboundry \
  APPBOUNDRY_DIR=/path/to/appboundry \
  AUTHBOUNDRY_NODE_MODULES=/path/to/node_modules \
  bun test appboundry-real-stack.test.ts

  # latency
  cd ../.. && FX_REAL_STACK=1 AUTHBOUNDRY_DIR=... APPBOUNDRY_DIR=... AUTHBOUNDRY_NODE_MODULES=... \
    bun benchmarks/appboundry_authority.ts --iterations 30
  ```

  The test starts both services itself through `tests/e2e/real-stack/`, which
  uses only AuthBoundry's documented HTTP surface (the same sequence as its
  `scripts/docker-bootstrap.mjs`) and AppBoundry's own packaging helpers. Without
  `FX_REAL_STACK=1` the suite is reported as skipped, which means not verified.
- Operator-supplied stack, opt-in: `appboundry-authority-live.test.ts` drives one
  fx process through a call, a revocation you perform with your own command, and a
  second call, against a stack you run (see its header for the variables).
- Live host with a token: `appboundry-live.test.ts`, as before.

## Known gaps, owners, and release blockers

Release blockers: no production-readiness claim is made while any of these
stands.

| # | Gap | Owner |
| --- | --- | --- |
| B1 | No non-interactive agent credential flow (issuance, scope, lifetime, revocation, audit identity). An unattended agent cannot acquire or renew an `apt_` session. | AuthBoundry |
| B2 | No verification against a hosted AuthBoundry or AppBoundry tenant, including hosted tenant isolation (AppBoundry limitation L16). | AuthBoundry, AppBoundry |
| B3 | Check credentials show no expiry or rotation in the audit; whether a leaked one can be bounded is unverified. | AuthBoundry |

Other gaps:

| Gap | Owner |
| --- | --- |
| The committed `native/linux-x64/authboundry` binary does not match the checkout's flow file. | AuthBoundry |
| Root `pnpm build` fails in `packages/appboundry` at `b3b4a8d`; only `appport` builds. | AppBoundry |
| Discovery is public and lists every application regardless of the caller (documented, deliberate, out of scope here). | AppBoundry |
| AppBoundry host restart and remote FeltDB were not tested. | AppBoundry, AuthBoundry |
| fx recognizes a check credential only by its `abc_` prefix and cannot validate a session credential. | fx |
| A truncated result still loses `structuredContent`. | fx |

## Limits

- Discovery is synchronous and bounded by `FX_APPBOUNDRY_TIMEOUT_MS`, so an
  unreachable host can delay MCP startup by up to that long.
- One token applies to the whole host; per-application tokens are not supported.
- Only the `AppPort/host-discovery/1` document is understood.
