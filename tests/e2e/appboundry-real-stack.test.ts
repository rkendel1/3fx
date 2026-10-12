import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  completion,
  createConfiguredProviderFixture as providerFixture,
  toolCompletion,
} from "./fixtures/chat-completions";
import { RealStack, realStackConfigFromEnv, type StackState } from "./real-stack/client";

// Opt-in: fx against the REAL stack. A real `authboundry serve` (durable
// FeltDB) and a real AppBoundry host in authority mode are launched from
// operator-provided checkouts by real-stack/stack.launch.ts; this file then
// drives the built fx binary and the stack's control server.
//
//   FX_REAL_STACK=1
//   AUTHBOUNDRY_DIR              checkout with a binary that matches its own flow file
//                                (`cargo build --release --bin authboundry`)
//   APPBOUNDRY_DIR               checkout after `pnpm install` and `pnpm --filter appport build`
//   AUTHBOUNDRY_NODE_MODULES     directory containing @feltdb/core@0.11.7
//
// Without FX_REAL_STACK=1 this suite is skipped. A skipped suite means "not
// verified against the real services", never a pass. See
// docs/appboundry-provider.md.
const config = realStackConfigFromEnv();
const enabled = config !== null;
const real = new RealStack(config ?? { authboundryDir: "", appboundryDir: "" });

const SAMPLE_INPUT = {
  interpretedChange: { affectedConceptCandidates: ["billing", "warehouse"] },
  organizationalMappings: [
    { id: "ent-1", name: "billing service", businessSystem: "ERP", certainty: "declared", evidenceIds: ["doc-7"] },
  ],
};

/** Many resolved entities make the capability's own output large enough to exceed a small result cap. */
function largeInput(count: number) {
  const concepts = Array.from({ length: count }, (_, i) => `billing${i}`);
  return {
    interpretedChange: { affectedConceptCandidates: concepts },
    organizationalMappings: concepts.map((name, i) => ({ id: `ent-${i}`, name: `${name} service`, businessSystem: "ERP", certainty: "declared", evidenceIds: [`doc-${i}`] })),
  };
}

let stack: StackState;
const fxHome = () => real.fxHome;
const scratchDir = () => real.scratch;
const api = (path: string, body?: unknown) => real.api(path, body);

beforeAll(async () => {
  if (!enabled) return;
  await real.start();
  stack = real.state;
}, 180_000);

afterAll(async () => {
  if (enabled) await real.stop();
}, 60_000);

function lastToolResult(body: any): string {
  const message = [...body.messages].reverse().find((entry: any) => entry.role === "tool");
  return typeof message?.content === "string" ? message.content : "";
}

type Call = { server: string; args?: Record<string, unknown>; before?: () => Promise<void> | void };
type Outcome = { raw: string; result: any };

/** Searches, selects every AppBoundry tool it finds, then issues `calls` in order inside one fx process. */
function scriptedModel(calls: Call[], outcomes: Outcome[], names: string[]) {
  let step = 0;
  let selected = 0;
  let found: string[] = [];
  let issued = 0;
  const model = async (body: any) => {
    step += 1;
    if (step === 1) return toolCompletion(body.model, "capability_search", { query: "changeimpact context" });
    if (step === 2) {
      found = (JSON.parse(lastToolResult(body)).mcp_tools ?? []).map((tool: any) => tool.name);
      names.push(...found);
      if (found.length === 0) return completion(body.model, "no matching capability");
    }
    if (selected < found.length) return toolCompletion(body.model, "mcp_select_tool", { name: found[selected++] });
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
      const name = found.find((candidate) => candidate.includes(`appboundry_${call.server}_`));
      if (!name) return completion(body.model, `no tool for ${call.server}`);
      await call.before?.(); // e.g. revoke or sign out, strictly before this call is sent
      return toolCompletion(body.model, name, call.args ?? SAMPLE_INPUT);
    }
    return completion(body.model, "calls finished; the goal is not established by them");
  };
  return model;
}

/** Runs fx as `user`. `before` hooks run between model steps (they must finish before the call is sent). */
async function runAs(user: string | { credential: string }, calls: Call[], extra: { fxJson?: object; args?: string[]; /* global launch args, placed before `ask` */ env?: Record<string, string | undefined> } = {}) {
  const credential = typeof user === "string" ? stack.sessions[user].credential : user.credential;
  const outcomes: Outcome[] = [];
  const names: string[] = [];
  const script = scriptedModel(calls, outcomes, names);
  const provider = providerFixture(script);
  try {
    if (extra.fxJson) writeFileSync(join(provider.workspace, ".fx.json"), JSON.stringify(extra.fxJson));
    const result = await runFx([...(extra.args ?? []), "ask", "--json", "--no-save", "Resolve the change context"], {
      cwd: provider.workspace,
      env: {
        ...provider.env,
        FX_PERMISSION_MODE: "full-access",
        FX_APPBOUNDRY_URL: stack.host,
        FX_APPBOUNDRY_TOKEN: credential,
        FX_APPBOUNDRY_ALLOW_LOCAL_HTTP: "1",
        ...extra.env,
      },
      timeoutMs: 90_000,
    });
    return { result, outcomes, names, credential, prompts: provider.requests.map((request) => request.body) };
  } finally {
    provider.close();
  }
}

const meta = (outcome: Outcome) => outcome.result?.result?._meta ?? {};
const statuses = (result: { stdout: string }) => JSON.parse(result.stdout).tool_calls.map((call: any) => call.status as string);

async function listTools(token: string | undefined) {
  const result = await runFx(["mcp", "list", "--connect"], {
    cwd: scratchDir(),
    env: {
      HOME: fxHome(),
      FX_PERMISSION_MODE: "full-access",
      FX_APPBOUNDRY_URL: stack.host,
      FX_APPBOUNDRY_ALLOW_LOCAL_HTTP: "1",
      FX_APPBOUNDRY_TOKEN: token,
    },
    timeoutMs: 90_000,
  });
  return result.stdout + result.stderr;
}

const rawCall = (alias: string, credential: string | undefined) => real.rawCall(alias, credential, SAMPLE_INPUT);

const executions = () => real.executions();

describe.skipIf(!enabled)("AppBoundry + AuthBoundry real stack", () => {
  test("1. unauthenticated and forged-session requests are rejected and nothing executes", async () => {
    const before = await executions();
    // Discovery is public by contract; the protected MCP surface is not.
    for (const token of [undefined, "apt_reference.forged-session-0000"]) {
      const listing = await listTools(token);
      expect(listing).not.toMatch(/tools=[1-9]/);
      expect((await rawCall("ctx", token)).status).toBe(401);
    }
    expect(await executions()).toEqual(before);
  }, 180_000);

  test("2. an authenticated but ungranted principal is refused, sees no tools, and the module never runs", async () => {
    const bob = stack.sessions.bob.credential;
    expect(await listTools(bob)).not.toMatch(/tools=[1-9]/);
    const denied = await rawCall("trap", bob);
    const result = denied.json.result;
    expect(result.isError).toBe(true);
    expect(result._meta["appboundry/error"].code).toBe("FORBIDDEN");
    expect(result._meta["appboundry/evidence"]).toBeUndefined();
    expect(result._meta["appboundry/authorization"].decisions[0].decision).toBe("deny");
    expect(typeof result._meta["appboundry/authorization"].decisions[0].decisionId).toBe("string");
    // The trapping module would leave a failure usage record if it had run.
    expect((await executions()).trap).toEqual({ completed: 0, usage: 0, usageFailures: 0 });
  }, 120_000);

  test("3. a principal discovers only the capabilities it is permitted to use", async () => {
    await api("/grant", { user: "bob", capabilities: [stack.apps.second.capability] });
    const listing = await listTools(stack.sessions.bob.credential);
    const section = (name: string) => listing.split(/\n(?=\s*appboundry_)/).find((block) => block.trim().startsWith(name)) ?? "";
    expect(section("appboundry_second")).toMatch(/tools=1/);
    expect(section("appboundry_ctx")).toMatch(/tools=0/);
    expect(section("appboundry_trap")).toMatch(/tools=0/);
    await api("/revoke", { user: "bob" });
  }, 120_000);

  test("4. a permitted capability executes through fx with correlated evidence", async () => {
    const run = await runAs("alice", [{ server: "ctx" }]);
    expect(run.result.code).toBe(0);
    expect(statuses(run.result).slice(-1)).toEqual(["success"]);
    const [outcome] = run.outcomes;
    expect(outcome.result.result.isError).not.toBe(true);
    const authorization = meta(outcome)["appboundry/authorization"];
    const evidence = meta(outcome)["appboundry/evidence"];
    expect(authorization).toMatchObject({ authority: "authboundry", principal: stack.sessions.alice.principalId });
    expect(evidence.outcome).toBe("success");
    expect(typeof evidence.executionUnitId).toBe("string");
    const decisionId = authorization.decisions[0].decisionId;

    // AuthBoundry's durable decision names the same execution unit.
    const recorded = (await api("/decisions")).find((entry: any) => entry.decisionId === decisionId);
    expect(recorded).toMatchObject({ principalId: stack.sessions.alice.principalId, decision: "allow", mode: "enforce", executionUnit: evidence.executionUnitId });
    // AppBoundry's invocation and usage records name the same unit and decision.
    const records = (await api("/records")).ctx;
    expect(records.records.find((record: any) => record.executionUnitId === evidence.executionUnitId)).toMatchObject({ status: "completed", authority: { principal: stack.sessions.alice.principalId } });
    expect(records.usage.find((entry: any) => entry.executionId === evidence.executionUnitId)).toMatchObject({ status: "success" });

    // Credentials never reached the model or fx output.
    const everything = run.result.stdout + run.result.stderr + JSON.stringify(run.prompts);
    expect(everything).not.toContain(run.credential);
    expect(everything).not.toContain("abc_");
  }, 180_000);

  test("5. an execution failure carries failure evidence and stays distinct from a refusal", async () => {
    const run = await runAs("alice", [{ server: "trap" }]);
    const [outcome] = run.outcomes;
    expect(outcome.raw).toContain("SYNAPSE_TRAP");
    expect(statuses(run.result).slice(-1)).toEqual(["error"]);
    expect(meta(outcome)["appboundry/authorization"].decisions[0].decision).toBe("allow");
    const evidence = meta(outcome)["appboundry/evidence"];
    expect(evidence.outcome).toBe("failure");
    const decisionId = meta(outcome)["appboundry/authorization"].decisions[0].decisionId;
    const recorded = (await api("/decisions")).find((entry: any) => entry.decisionId === decisionId);
    expect(recorded.executionUnit).toBe(evidence.executionUnitId);
  }, 180_000);

  test("6. revoking the policy denies the next call in the same fx process; the denied module never runs", async () => {
    const before = await executions();
    const run = await runAs("alice", [
      { server: "ctx" },
      { server: "ctx", before: () => api("/revoke", { user: "alice" }) },
      { server: "trap" },
    ]);
    expect(run.outcomes).toHaveLength(3);
    expect(meta(run.outcomes[0])["appboundry/evidence"].outcome).toBe("success");
    for (const denied of run.outcomes.slice(1)) {
      expect(denied.raw).toContain("FORBIDDEN");
      expect(meta(denied)["appboundry/evidence"]).toBeUndefined();
      expect(meta(denied)["appboundry/authorization"].decisions[0].decision).toBe("deny");
    }
    const after = await executions();
    expect(after.ctx.completed).toBe(before.ctx.completed + 1);
    expect(after.trap).toEqual(before.trap); // a trap would have added a failure usage record
    await api("/grant", { user: "alice" });
  }, 240_000);

  test("7. signing out the session fails the next call in the same fx process with no further execution", async () => {
    await api("/grant", { user: "bob", capabilities: [stack.apps.ctx.capability] });
    const before = await executions();
    const run = await runAs("bob", [{ server: "ctx" }, { server: "ctx", before: () => api("/signout", { user: "bob" }) }]);
    expect(meta(run.outcomes[0])["appboundry/evidence"].outcome).toBe("success");
    expect(statuses(run.result).slice(-1)).toEqual(["error"]);
    expect(JSON.stringify(run.outcomes.at(-1))).not.toContain('"outcome":"success"');
    const after = await executions();
    expect(after.ctx.completed).toBe(before.ctx.completed + 1);
    expect((await rawCall("ctx", stack.sessions.bob.credential)).status).toBe(401);
  }, 240_000);

  test("8. another tenant's session, or a session with its tenant swapped, cannot reach the capability", async () => {
    const before = await executions();
    const mallory = stack.sessions.mallory;
    expect(await listTools(mallory.credential)).not.toMatch(/tools=[1-9]/);
    const crossTenant = await rawCall("ctx", mallory.credential);
    expect(crossTenant.status === 401 || crossTenant.json?.result?.isError === true).toBe(true);
    const swapped = `apt_reference.${mallory.credential.split(".").slice(1).join(".")}`;
    expect((await rawCall("ctx", swapped)).status).toBe(401);
    expect(await executions()).toEqual(before);
  }, 180_000);

  test("9. an authority outage fails closed, and restart neither restores revoked authority nor loses durable decisions", async () => {
    const decisionsBefore = (await api("/decisions")).map((entry: any) => entry.decisionId);
    expect(decisionsBefore.length).toBeGreaterThan(0);

    // alice is granted again after test 6; revoke, then SIGKILL and restart the authority.
    await api("/revoke", { user: "alice" });
    await api("/kill-authority", {});
    const before = await executions();
    const down = await runAs("alice", [{ server: "ctx" }]);
    expect(down.outcomes.length === 0 || statuses(down.result).slice(-1)[0] === "error").toBe(true);
    expect(JSON.stringify(down.outcomes)).not.toContain('"outcome":"success"');
    expect(await executions()).toEqual(before);

    await api("/start-authority", {});
    const afterRestart = await runAs("alice", [{ server: "ctx" }]);
    expect(afterRestart.outcomes.length === 0 || afterRestart.outcomes[0].raw.includes("FORBIDDEN")).toBe(true);
    expect(JSON.stringify(afterRestart.outcomes)).not.toContain('"outcome":"success"');
    expect(await executions()).toEqual(before);
    // The signed-out session is still signed out.
    expect((await rawCall("ctx", stack.sessions.bob.credential)).status).toBe(401);
    // Earlier decisions were not lost.
    const decisionsAfter = new Set((await api("/decisions")).map((entry: any) => entry.decisionId));
    for (const id of decisionsBefore) expect(decisionsAfter.has(id)).toBe(true);

    // The restarted authority is still functional, including the previously issued check credential.
    await api("/grant", { user: "alice" });
    const again = await runAs("alice", [{ server: "ctx" }]);
    expect(meta(again.outcomes[0])["appboundry/evidence"]?.outcome).toBe("success");
  }, 300_000);

  test("10. an oversized result keeps its evidence after fx truncation", async () => {
    const run = await runAs("alice", [{ server: "ctx", args: largeInput(40) }], { fxJson: { max_tool_result_bytes: 4000 }, env: { FX_APPBOUNDRY_APPS: "synapse.change-context-resolver" } });
    
    const [outcome] = run.outcomes;
    expect(outcome.result.result.truncated).toBe(true);
    expect(meta(outcome)["appboundry/evidence"].outcome).toBe("success");
    expect(typeof meta(outcome)["appboundry/evidence"].executionUnitId).toBe("string");
    expect(meta(outcome)["appboundry/authorization"].decisions[0].decision).toBe("allow");
  }, 180_000);
});

if (!enabled) {
  describe("AppBoundry + AuthBoundry real stack (NOT RUN)", () => {
    test.skip("real-service verification skipped: set FX_REAL_STACK=1 with AUTHBOUNDRY_DIR and APPBOUNDRY_DIR", () => {});
  });
}
