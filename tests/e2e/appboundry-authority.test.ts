import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "bun:test";
import { runFx } from "../evals/eval-helpers";
import {
  CHECK_CREDENTIAL,
  DEFAULT_APP,
  startAuthorityHost,
  type AppSpec,
  type AuthorityHostOptions,
} from "./fixtures/appboundry-authority-host";
import {
  completion,
  createConfiguredProviderFixture as providerFixture,
  toolCompletion,
} from "./fixtures/chat-completions";

// Consumer-side proof that fx preserves caller identity, never manufactures
// authority, and reports authority outcomes faithfully. The host is a double of
// AppBoundry in AuthBoundry authority mode (fixtures/appboundry-authority-host.ts).
// These tests are "verified locally"; they are not verification against the real
// services. See docs/appboundry-provider.md.

let cleanups: Array<() => void> = [];
afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

function lastToolResult(body: any): string {
  const message = [...body.messages].reverse().find((entry: any) => entry.role === "tool");
  return typeof message?.content === "string" ? message.content : "";
}

type Call = {
  /** Substring of the discovered tool name to call. */
  match: string;
  args: Record<string, unknown>;
  /** Runs in the test process immediately before this call is issued. */
  before?: () => void;
};

type Outcome = { raw: string; result: any };

/**
 * Searches, selects every tool it finds, then performs `calls` in order within
 * one fx process. Tool names come from discovery. The list is fetched once, so
 * later calls reuse a tool list that was discovered earlier.
 */
function scriptedModel(calls: Call[], outcomes: Outcome[], names: string[], query = "image resizer resize doc tools write") {
  let step = 0;
  let selected = 0;
  let found: string[] = [];
  let issued = 0;
  return (body: any) => {
    step += 1;
    if (step === 1) return toolCompletion(body.model, "capability_search", { query });
    if (step === 2) {
      found = (JSON.parse(lastToolResult(body)).mcp_tools ?? []).map((tool: any) => tool.name);
      names.push(...found);
      if (found.length === 0) return completion(body.model, "no matching capability");
    }
    if (step >= 2 && selected < found.length) return toolCompletion(body.model, "mcp_select_tool", { name: found[selected++] });
    if (issued > 0) {
      const raw = lastToolResult(body);
      let result: any = null;
      try {
        result = JSON.parse(raw);
      } catch {}
      outcomes.push({ raw, result });
    }
    if (issued < calls.length) {
      const call = calls[issued++];
      call.before?.();
      const name = found.find((candidate) => candidate.includes(call.match));
      if (!name) return completion(body.model, `no tool matching ${call.match}`);
      return toolCompletion(body.model, name, call.args);
    }
    return completion(body.model, "calls finished; the overall goal is not established by them");
  };
}

async function run(
  hostOptions: AuthorityHostOptions,
  calls: (host: ReturnType<typeof startAuthorityHost>, session: string) => Call[],
  config: { fxJson?: object; principal?: string; grants?: Array<[string, string]>; token?: (session: string) => string } = {},
) {
  const host = startAuthorityHost(hostOptions);
  const principal = config.principal ?? "alice";
  const session = host.authority.addSession(principal);
  for (const [who, permission] of config.grants ?? [[principal, DEFAULT_APP.permission]]) host.authority.grant(who, permission);
  const outcomes: Outcome[] = [];
  const names: string[] = [];
  const provider = providerFixture(scriptedModel(calls(host, session), outcomes, names));
  cleanups.push(() => host.stop(), () => provider.close());
  if (config.fxJson) writeFileSync(join(provider.workspace, ".fx.json"), JSON.stringify(config.fxJson));
  const token = config.token ? config.token(session) : session;
  const result = await runFx(["ask", "--json", "--no-save", "Resize this raster"], {
    cwd: provider.workspace,
    env: {
      ...provider.env,
      FX_PERMISSION_MODE: "full-access",
      FX_APPBOUNDRY_URL: host.url,
      FX_APPBOUNDRY_TOKEN: token,
      FX_APPBOUNDRY_ALLOW_LOCAL_HTTP: "1",
    },
    timeoutMs: 30_000,
  });
  return { host, provider, session, token, outcomes, names, result };
}

const ARGS = { width: 4, height: 2 };
const callKinds = (result: { stdout: string }) =>
  JSON.parse(result.stdout).tool_calls.map((call: any) => call.status as string);
const meta = (outcome: Outcome) => outcome.result?.result?._meta ?? {};
const toolCalls = (host: { requests: Array<{ body: any }> }) => host.requests.filter((request) => request.body?.method === "tools/call");

function expectNoSecrets(r: Awaited<ReturnType<typeof run>>) {
  const everything = r.result.stdout + r.result.stderr + JSON.stringify(r.provider.requests.map((request) => request.body));
  expect(everything).not.toContain(r.token);
  expect(everything).not.toContain(CHECK_CREDENTIAL);
  for (const request of r.host.requests) expect(request.text + JSON.stringify(request.headers)).not.toContain(CHECK_CREDENTIAL);
}

describe("AppBoundry authority: authorized path", () => {
  test("discovers and invokes with the caller's session; the host decides and the evidence is preserved verbatim", async () => {
    const r = await run({}, () => [{ match: "image_resize", args: ARGS }]);
    expect(r.result.code).toBe(0);
    expect(callKinds(r.result).slice(-1)).toEqual(["success"]);
    expect(r.host.executions).toBe(1);

    // Every request, discovery included, carries exactly the caller's session credential.
    for (const request of r.host.requests) expect(request.headers["authorization"]).toBe(`Bearer ${r.session}`);

    // Authorization and execution evidence reach the model as the host wrote them.
    const [outcome] = r.outcomes;
    const authorization = meta(outcome)["appboundry/authorization"];
    const evidence = meta(outcome)["appboundry/evidence"];
    expect(authorization).toEqual({
      authority: "authboundry",
      principal: "alice",
      decisions: [{ permission: "image.resize", capability: "image.resize@1", decision: "allow", decisionId: r.host.decisions[0].decisionId, reason: null }],
    });
    expect(evidence.executionUnitId).toBe("unit-1");
    expect(evidence.outcome).toBe("success");
    expect(evidence.artifactHash).toMatch(/^sha256:/);
    expect(evidence.contractFingerprint).toMatch(/^sha256:/);
    expect(outcome.result.result.structuredContent).toEqual({ width: 4, height: 2, ranBy: "image-resizer" });
    expectNoSecrets(r);
  }, 45_000);

  test("an invalid or unknown session is rejected and nothing executes", async () => {
    const r = await run({}, () => [{ match: "image_resize", args: ARGS }], { token: () => "apt_acme.forged-session" });
    expect(r.result.code).toBe(0);
    expect(r.host.executions).toBe(0);
    expect(r.host.decisions).toHaveLength(0);
    expect(JSON.stringify(r.outcomes)).not.toContain("allow");
    // fx never retried without credentials or with a different one.
    for (const request of r.host.requests) {
      expect(request.headers["authorization"]).toBe("Bearer apt_acme.forged-session");
    }
  }, 45_000);

  test("a principal without the grant is denied before the module runs", async () => {
    const r = await run({}, () => [{ match: "image_resize", args: ARGS }], { grants: [] });
    expect(r.result.code).toBe(0);
    expect(r.host.executions).toBe(0);
    const [outcome] = r.outcomes;
    expect(outcome.raw).toContain("FORBIDDEN");
    expect(meta(outcome)["appboundry/authorization"].decisions[0].decision).toBe("deny");
    // A refusal has authorization evidence and no execution evidence.
    expect(meta(outcome)["appboundry/evidence"]).toBeUndefined();
    expect(r.host.invocations).toHaveLength(0);
    expect(callKinds(r.result).slice(-1)).toEqual(["error"]);
  }, 45_000);
});

describe("AppBoundry authority: revocation in one fx process", () => {
  test("revoking the policy denies the next call on the already-discovered tool list", async () => {
    const r = await run({}, (host) => [
      { match: "image_resize", args: ARGS },
      { match: "image_resize", args: ARGS, before: () => host.authority.revoke("alice", "image.resize") },
    ]);
    expect(r.result.code).toBe(0);
    expect(r.outcomes).toHaveLength(2);

    // One discovery and one tools/list for the whole process: the second call reused them.
    expect(r.host.requests.filter((request) => request.path === "/.well-known/appport")).toHaveLength(1);
    expect(r.host.requests.filter((request) => request.body?.method === "tools/list")).toHaveLength(1);
    expect(toolCalls(r.host)).toHaveLength(2);

    expect(meta(r.outcomes[0])["appboundry/evidence"].outcome).toBe("success");
    expect(r.outcomes[1].raw).toContain("FORBIDDEN");
    expect(meta(r.outcomes[1])["appboundry/evidence"]).toBeUndefined();
    expect(r.host.executions).toBe(1);
    expect(r.host.invocations).toHaveLength(1);
  }, 45_000);

  test("signing out the session denies the next call and fx does not fall back to anything weaker", async () => {
    const r = await run({}, (host, session) => [
      { match: "image_resize", args: ARGS },
      { match: "image_resize", args: ARGS, before: () => host.authority.signOut(session) },
    ]);
    expect(r.result.code).toBe(0);
    expect(r.host.executions).toBe(1);
    expect(callKinds(r.result).slice(-1)).toEqual(["error"]);
    expect(r.outcomes.length).toBeGreaterThanOrEqual(1);
    const second = toolCalls(r.host).at(-1)!;
    expect(second.headers["authorization"]).toBe(`Bearer ${r.session}`);
    expect(JSON.stringify(r.outcomes.at(-1))).not.toContain('"decision":"allow"');
    expect(JSON.stringify(r.outcomes.at(-1))).not.toContain("unit-2");
    // Every request used the same credential; none went out anonymously.
    for (const request of r.host.requests) expect(request.headers["authorization"]).toBe(`Bearer ${r.session}`);
  }, 45_000);

  test("the full sequence correlates the decision, the invocation record, and the execution evidence", async () => {
    const r = await run({}, (host) => [
      { match: "image_resize", args: ARGS },
      { match: "image_resize", args: ARGS, before: () => host.authority.revoke("alice", "image.resize") },
    ]);
    const evidence = meta(r.outcomes[0])["appboundry/evidence"];
    const authorization = meta(r.outcomes[0])["appboundry/authorization"];
    const decisionId = authorization.decisions[0].decisionId;

    // execution unit -> AppBoundry invocation record -> AuthBoundry decision (and back).
    const invocation = r.host.invocations.find((record) => record.executionUnitId === evidence.executionUnitId)!;
    expect(invocation.decisionId).toBe(decisionId);
    const decision = r.host.decisions.find((record) => record.decisionId === decisionId)!;
    expect(decision.effect).toBe("allow");
    expect(decision.principal).toBe("alice");
    expect(decision.executionContext?.executionUnitId).toBe(evidence.executionUnitId);

    // The later denial has its own decision and no execution unit.
    const denied = r.host.decisions.find((record) => record.effect === "deny")!;
    expect(denied.decisionId).not.toBe(decisionId);
    expect(denied.executionContext).toBeUndefined();
    expect(r.host.invocations.map((record) => record.decisionId)).not.toContain(denied.decisionId);
  }, 45_000);
});

describe("AppBoundry authority: credential kinds", () => {
  test("a server-side check credential is never sent to the host", async () => {
    const r = await run({}, () => [{ match: "image_resize", args: ARGS }], { token: () => CHECK_CREDENTIAL });
    expect(r.result.code).toBe(0);
    expect(r.host.requests).toHaveLength(0);
    expect(r.result.stdout + r.result.stderr).not.toContain(CHECK_CREDENTIAL);
  }, 45_000);
});

describe("AppBoundry authority: forged claims cannot elevate", () => {
  test("identity and scope smuggled in tool arguments do not change the principal or the decision", async () => {
    const forged = { ...ARGS, principal: "admin", scopes: ["*"], permission: "admin.all", authorization: "Bearer apt_acme.admin", "x-appboundry-principal": "admin" };
    const r = await run({ apps: [{ ...DEFAULT_APP, lenientSchema: true }] }, () => [{ match: "image_resize", args: forged }], { grants: [] });
    expect(r.result.code).toBe(0);
    expect(r.host.executions).toBe(0);
    const call = toolCalls(r.host)[0];
    expect(call.headers["authorization"]).toBe(`Bearer ${r.session}`);
    expect(r.host.decisions[0].principal).toBe("alice");
    expect(r.host.decisions[0].permission).toBe("image.resize");
    expect(r.host.decisions[0].effect).toBe("deny");
  }, 45_000);

  test("discovery metadata claiming authority is treated as metadata, not a grant", async () => {
    const r = await run({ forgeDiscoveryClaims: true }, () => [{ match: "image_resize", args: ARGS }], { grants: [] });
    expect(r.result.code).toBe(0);
    expect(r.host.executions).toBe(0);
    expect(r.outcomes[0].raw).toContain("FORBIDDEN");
    for (const request of r.host.requests) expect(request.headers["authorization"]).toBe(`Bearer ${r.session}`);
  }, 45_000);
});

describe("AppBoundry authority: fail closed", () => {
  for (const mode of ["unavailable", "malformed", "timeout"] as const) {
    test(`authority ${mode} is a failure, never a downgrade to allow`, async () => {
      const r = await run({}, (host) => [{ match: "image_resize", args: ARGS, before: () => host.authority.setFailure(mode) }]);
      expect(r.result.code).toBe(0);
      expect(r.host.executions).toBe(0);
      const [outcome] = r.outcomes;
      expect(outcome.raw).toContain("AUTHORITY_UNAVAILABLE");
      expect(meta(outcome)["appboundry/evidence"]).toBeUndefined();
      expect(meta(outcome)["appboundry/authorization"].decisions[0].decision).toBe("deny");
      expect(toolCalls(r.host)).toHaveLength(1);
      expect(callKinds(r.result).slice(-1)).toEqual(["error"]);
    }, 45_000);
  }

  test("a malformed or non-JSON host response is not reported as success", async () => {
    // Pointing fx at a host that answers every MCP call with garbage after discovery.
    const bad = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      fetch(request) {
        const url = new URL(request.url);
        if (url.pathname === "/.well-known/appport") {
          return Response.json({ protocol: "AppPort/host-discovery/1", applications: [{ selector: "broken", status: "running", mcp: "/apps/broken/mcp" }] });
        }
        return new Response("<html>not json</html>", { status: 200, headers: { "content-type": "text/html" } });
      },
    });
    cleanups.push(() => bad.stop(true));
    const provider = providerFixture((body: any) => completion(body.model, "done"));
    cleanups.push(() => provider.close());
    const result = await runFx(["mcp", "list", "--connect"], {
      cwd: provider.workspace,
      env: { ...provider.env, FX_PERMISSION_MODE: "full-access", FX_APPBOUNDRY_URL: `http://127.0.0.1:${bad.port}`, FX_APPBOUNDRY_TOKEN: "apt_acme.s1", FX_APPBOUNDRY_ALLOW_LOCAL_HTTP: "1" },
      timeoutMs: 30_000,
    });
    expect(result.stdout).not.toMatch(/state=ready/);
  }, 45_000);

  test("an execution failure keeps its failure evidence and is not reported as success", async () => {
    const r = await run({ apps: [{ ...DEFAULT_APP, trap: true }] }, () => [{ match: "image_resize", args: ARGS }]);
    expect(r.result.code).toBe(0);
    const [outcome] = r.outcomes;
    expect(outcome.raw).toContain("SYNAPSE_TRAP");
    expect(meta(outcome)["appboundry/authorization"].decisions[0].decision).toBe("allow");
    expect(meta(outcome)["appboundry/evidence"].outcome).toBe("failure");
    expect(r.host.invocations[0].outcome).toBe("failure");
    expect(callKinds(r.result).slice(-1)).toEqual(["error"]);
  }, 45_000);

  test("a success result without evidence is passed through without fx adding any", async () => {
    // A host that omits (or mangles) _meta must not gain verified-looking evidence from fx.
    const plain = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      async fetch(request) {
        const url = new URL(request.url);
        if (url.pathname === "/.well-known/appport") {
          return Response.json({ protocol: "AppPort/host-discovery/1", applications: [{ selector: "plain", status: "running", mcp: "/apps/plain/mcp" }] });
        }
        const body: any = await request.json().catch(() => null);
        const rpc = (result: unknown) => Response.json({ jsonrpc: "2.0", id: body.id, result });
        if (body?.method === "initialize") return rpc({ protocolVersion: "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: "x", version: "1" } });
        if (body?.method === "notifications/initialized") return new Response(null, { status: 202 });
        if (body?.method === "tools/list") return rpc({ tools: [{ name: "do_it", description: "plain do_it", inputSchema: { type: "object", properties: {} } }] });
        return rpc({ content: [{ type: "text", text: "ok" }], _meta: { "appboundry/evidence": "trust me" } });
      },
    });
    cleanups.push(() => plain.stop(true));
    const outcomes: Outcome[] = [];
    const provider = providerFixture(scriptedModel([{ match: "do_it", args: {} }], outcomes, [], "do_it"));
    cleanups.push(() => provider.close());
    const result = await runFx(["ask", "--json", "--no-save", "do it"], {
      cwd: provider.workspace,
      env: { ...provider.env, FX_PERMISSION_MODE: "full-access", FX_APPBOUNDRY_URL: `http://127.0.0.1:${plain.port}`, FX_APPBOUNDRY_TOKEN: "apt_acme.s1", FX_APPBOUNDRY_ALLOW_LOCAL_HTTP: "1" },
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    expect(outcomes).toHaveLength(1);
    const raw = outcomes[0].raw;
    // Passed through as the host sent it: a bare string, not upgraded to a record.
    expect(outcomes[0].result.result._meta["appboundry/evidence"]).toBe("trust me");
    expect(raw).not.toMatch(/verified|executionUnitId/);
    expect(outcomes[0].result.result._meta["appboundry/authorization"]).toBeUndefined();
  }, 45_000);
});

describe("AppBoundry authority: result size", () => {
  test("an oversized result is marked truncated and keeps its authorization and execution evidence", async () => {
    const r = await run({ apps: [{ ...DEFAULT_APP, padding: 20_000 }] }, () => [{ match: "image_resize", args: ARGS }], { fxJson: { max_tool_result_bytes: 2000 } });
    expect(r.result.code).toBe(0);
    expect(r.host.executions).toBe(1);
    const result = r.outcomes[0].result.result;
    expect(result.truncated).toBe(true);
    expect(result.meta_omitted).toBeUndefined();
    expect(result._meta["appboundry/evidence"].executionUnitId).toBe("unit-1");
    expect(result._meta["appboundry/authorization"].decisions[0].decisionId).toBe(r.host.decisions[0].decisionId);
  }, 45_000);
});

describe("AppBoundry authority: origins and namespacing", () => {
  test("a redirect from the MCP endpoint is never followed and the credential never leaves the origin", async () => {
    const stranger = startAuthorityHost();
    cleanups.push(() => stranger.stop());
    const r = await run({ apps: [{ ...DEFAULT_APP, redirectTo: `${stranger.url}/apps/image-resizer/mcp` }] }, () => [{ match: "image_resize", args: ARGS }]);
    expect(r.result.code).toBe(0);
    expect(stranger.requests).toHaveLength(0);
    expect(r.host.executions).toBe(0);
    expect(r.result.stdout + r.result.stderr).not.toContain(r.session);
  }, 45_000);

  test("an advertised endpoint on another origin is never contacted", async () => {
    const stranger = startAuthorityHost();
    cleanups.push(() => stranger.stop());
    const r = await run({ advertisedMcp: `${stranger.url}/apps/image-resizer/mcp` }, () => [{ match: "image_resize", args: ARGS }]);
    expect(r.result.code).toBe(0);
    expect(stranger.requests).toHaveLength(0);
    expect(r.host.requests.every((request) => request.path === "/.well-known/appport")).toBe(true);
  }, 45_000);

  test("two applications with the same tool name stay separate and are checked against their own permission", async () => {
    const other: AppSpec = { selector: "doc-tools", permission: "doc.write", tool: "image_resize", capability: "doc.write@1" };
    const r = await run({ apps: [DEFAULT_APP, other] }, () => [
      { match: "image-resizer_image_resize", args: ARGS },
      { match: "doc-tools_image_resize", args: ARGS },
    ]);
    expect(r.result.code).toBe(0);
    expect(r.names.sort()).toEqual(["mcp_appboundry_doc-tools_image_resize", "mcp_appboundry_image-resizer_image_resize"]);
    const byApp = Object.fromEntries(r.host.decisions.map((decision) => [decision.application, decision]));
    expect(byApp["image-resizer"].permission).toBe("image.resize");
    expect(byApp["image-resizer"].effect).toBe("allow");
    expect(byApp["doc-tools"].permission).toBe("doc.write");
    expect(byApp["doc-tools"].effect).toBe("deny");
    expect(r.host.invocations.map((record) => record.application)).toEqual(["image-resizer"]);
  }, 45_000);
});
