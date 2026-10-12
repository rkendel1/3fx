// Launches the REAL authority stack for fx's opt-in integration tests:
//   real `authboundry serve` (durable FeltDB) + real AppBoundry host (authority mode)
//   hosting packaged WASM capabilities, one of which traps if it ever runs.
//
// This file is not a test of anything itself. It runs under AppBoundry's own
// toolchain (see run-stack.md) because AppBoundry's host and its packaging
// helpers live in that repository; fx's tests then drive the stack through a
// small localhost control server. Nothing here is a production credential: every
// identity, password, and credential is generated for one run in a temp dir.
//
// Only documented AuthBoundry surfaces are used, the same sequence as
// authboundry/scripts/docker-bootstrap.mjs and appboundry's authority-fixture.ts.

import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, writeFileSync } from "node:fs";
import { cp, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { createServer as createNetServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const env = (name: string): string => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
};
const AUTHBOUNDRY_DIR = env("AUTHBOUNDRY_DIR");
const APPBOUNDRY_DIR = env("APPBOUNDRY_DIR");
const STATE_FILE = env("FX_STACK_STATE");
const NODE_MODULES = process.env["AUTHBOUNDRY_NODE_MODULES"] ?? join(AUTHBOUNDRY_DIR, "node_modules");
const ab = (path: string) => import(pathToFileURL(join(APPBOUNDRY_DIR, path)).href);

const TENANT = "reference";
const OTHER_TENANT = "other";
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const freePort = (): Promise<number> =>
  new Promise((resolve, reject) => {
    const probe = createNetServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address() as { port: number };
      probe.close(() => resolve(port));
    });
  });

const OWNER_GRANTS = [
  "identity.read", "identity.write", "principal.read", "principal.write", "agent.read", "agent.write", "delegation.read",
  "delegation.create", "delegation.revoke", "policy.read", "policy.write", "audit.read", "evidence.read", "authorization.read",
  "authorization.explain", "approval.read", "approval.write", "reconcile", "apply", "revert", "session.admin",
];

function authorityBinary(): string {
  const candidates = [
    process.env["AUTHBOUNDRY_BIN"],
    join(AUTHBOUNDRY_DIR, "target", "release", "authboundry"),
    join(AUTHBOUNDRY_DIR, "native", `${process.platform}-${process.arch}`, "authboundry"),
  ].filter(Boolean) as string[];
  const found = candidates.find((candidate) => existsSync(candidate));
  if (!found) throw new Error("no authboundry binary: build one with `cargo build --release --bin authboundry`");
  return found;
}

class Authority {
  child: ChildProcess | null = null;
  root = "";
  port = 0;
  url = "";
  passwords: Record<string, string> = {};
  ownerSession = "";
  applicationId = "appboundry-host";
  checkCredential = "";

  async start(users: Array<{ name: string; tenant: string }>) {
    this.root = await mkdtemp(join(tmpdir(), "fx-real-stack-"));
    await cp(join(AUTHBOUNDRY_DIR, "bridge"), join(this.root, "bridge"), { recursive: true });
    await symlink(NODE_MODULES, join(this.root, "node_modules"));
    const flow = await readFile(join(AUTHBOUNDRY_DIR, "authboundry.flow"), "utf8");
    await writeFile(
      join(this.root, "authority.flow"),
      `${flow.slice(0, flow.indexOf("use control_plane"))}use control_plane {\n  authoritative_state = [organization, deployment, provisioning, subscription_reference, billing_account_reference]\n  storage = "feltdb"\n}\n`,
    );
    this.port = await freePort();
    this.url = `http://127.0.0.1:${this.port}`;
    const { randomBytes } = await import("node:crypto");
    const accounts = [{ name: "owner", tenant: TENANT }, ...users].flatMap(({ name, tenant }) => {
      this.passwords[name] = `${randomBytes(12).toString("hex")}-Aa1`;
      return ["--account", `${name}:${this.passwords[name]}:role=${name === "owner" ? "owner" : "user"}@${tenant}`];
    });
    this.accounts = accounts;
    await this.spawn();
  }
  accounts: string[] = [];

  async spawn() {
    const grants = OWNER_GRANTS.flatMap((grant) => ["--grant", `authority.${grant}=role:owner`]);
    this.child = spawn(
      authorityBinary(),
      ["serve", join(this.root, "authority.flow"), "--addr", `127.0.0.1:${this.port}`, "--tenant", TENANT, "--tenant", OTHER_TENANT, ...this.accounts, ...grants],
      {
        stdio: "ignore",
        env: {
          ...process.env,
          AUTHBOUNDRY_FELTDB_BRIDGE: join(this.root, "bridge", "feltdb-store.cjs"),
          AUTHBOUNDRY_FELTDB_PATH: join(this.root, "data"),
          AUTHBOUNDRY_PORTAL_ORIGIN: "http://localhost:3001",
          AUTHBOUNDRY_NODE: process.execPath,
        },
      },
    );
    for (let attempt = 0; ; attempt += 1) {
      if (attempt > 200) throw new Error("AuthBoundry did not start");
      try {
        if ((await fetch(`${this.url}/health`)).ok) return;
      } catch {
        /* not yet */
      }
      await sleep(100);
    }
  }

  async kill() {
    const child = this.child;
    this.child = null;
    if (!child) return;
    await new Promise<void>((resolve) => {
      child.once("exit", () => resolve());
      child.kill("SIGKILL"); // an unclean stop: durability must not depend on a graceful shutdown
    });
  }
  async restart() {
    await this.kill();
    await this.spawn();
  }
  async stop() {
    await this.kill();
    await rm(this.root, { recursive: true, force: true });
  }

  async request(path: string, init: { method?: string; credential?: string; body?: unknown } = {}) {
    const target = new URL(path, this.url);
    if (path.startsWith("/_") && !target.searchParams.has("tenant")) target.searchParams.set("tenant", TENANT);
    const response = await fetch(target, {
      method: init.method ?? "GET",
      headers: {
        accept: "application/json",
        ...(init.body === undefined ? {} : { "content-type": "application/json" }),
        ...(init.credential ? { "x-authboundry-session": init.credential } : {}),
      },
      ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
    });
    const text = await response.text();
    let value: any;
    try {
      value = text ? JSON.parse(text) : {};
    } catch {
      value = { message: text };
    }
    return { status: response.status, value };
  }
  async must(promise: Promise<{ status: number; value: any }>, what: string, allowed: number[] = []) {
    const result = await promise;
    if (result.status >= 300 && !allowed.includes(result.status)) throw new Error(`${what} failed (${result.status})`);
    return result;
  }
  async login(name: string, tenant: string): Promise<string> {
    const { value } = await this.request("/_authboundry/browser/credentials", {
      method: "POST",
      body: { application: "portal", connector: "local", tenant, return_to: "/overview", username: name, password: this.passwords[name] },
    });
    if (typeof value.credential !== "string") throw new Error(`sign-in failed for ${name}`);
    return value.credential;
  }
  async bootstrap() {
    this.ownerSession = await this.login("owner", TENANT);
    await this.must(
      this.request("/_authboundry/control-plane/organizations", { method: "POST", credential: this.ownerSession, body: { id: "appboundry", name: "AppBoundry", authority_tenant_id: TENANT } }),
      "organization",
      [409],
    );
    await this.must(
      this.request("/_authboundry/control-plane/applications", {
        method: "POST",
        credential: this.ownerSession,
        body: { id: this.applicationId, project_id: "appboundry", name: "AppBoundry host", production_url: "http://127.0.0.1:4400", environment: "production" },
      }),
      "application",
      [409],
    );
    const issued = await this.must(
      this.request(`/_authboundry/control-plane/applications/${this.applicationId}/check-credentials`, { method: "POST", credential: this.ownerSession, body: { label: "fx real-stack" } }),
      "check credential",
    );
    this.checkCredential = issued.value.secret as string;
  }
  async declare(capabilities: string[]) {
    await this.must(
      this.request(`/_authboundry/control-plane/applications/${this.applicationId}/contracts`, {
        method: "POST",
        credential: this.ownerSession,
        body: { authority_source: "external", version: "1.0.0", capabilities },
      }),
      "contract",
    );
  }
  async principalOf(credential: string): Promise<string> {
    const response = await fetch(new URL("/auth/session", this.url), { headers: { authorization: `Bearer ${credential}` } });
    return ((await response.json()) as { principal: { id: string } }).principal.id;
  }
  async grant(principalId: string, capabilities: string[]) {
    await this.must(
      this.request("/_authboundry/policies", { method: "POST", credential: this.ownerSession, body: { application: this.applicationId, principal_id: principalId, capabilities } }),
      "policy",
    );
  }
  async revoke(principalId: string) {
    await this.must(
      this.request(`/_authboundry/control-plane/applications/${this.applicationId}/policies/${encodeURIComponent(principalId)}`, { method: "DELETE", credential: this.ownerSession }),
      "revoke",
      [404],
    );
  }
  async signOut(credential: string) {
    await fetch(new URL("/auth/sign-out", this.url), { method: "POST", headers: { authorization: `Bearer ${credential}` } });
  }
  async decisions() {
    const { value } = await this.must(
      this.request(`/_authboundry/control-plane/applications/${this.applicationId}/evidence`, { credential: this.ownerSession }),
      "evidence",
    );
    return (value.evidence as any[]).map((record) => ({
      decisionId: record.id,
      principalId: record.principal_id,
      capability: record.capability,
      decision: record.decision,
      mode: record.context?.mode,
      executionUnit: record.context?.["context.appboundry_execution_unit"],
    }));
  }
}

function listen(handler: (path: string, method: string, body: any) => Promise<unknown>): Promise<{ server: Server; port: number }> {
  return new Promise((resolve) => {
    const server = createServer((request, response) => {
      const chunks: Buffer[] = [];
      request.on("data", (chunk) => chunks.push(chunk));
      request.on("end", async () => {
        let body: any = {};
        try {
          body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {};
        } catch {
          body = {};
        }
        try {
          const result = await handler(request.url ?? "/", request.method ?? "GET", body);
          response.setHeader("content-type", "application/json");
          response.end(JSON.stringify(result ?? {}));
        } catch (error) {
          response.statusCode = 500;
          response.end(JSON.stringify({ error: String((error as Error).message) }));
        }
      });
    });
    server.listen(0, "127.0.0.1", () => resolve({ server, port: (server.address() as { port: number }).port }));
  });
}

const harnessModule = await ab("packages/cli/test/synapse-host-harness.ts");
const resolver = await ab("packages/cli/test/synapse-change-context-resolver.ts");
const packager = await ab("packages/cli/test/synapse-capability-package.ts");
const authorityModule = await ab("packages/cli/src/authority.ts");

const specs: Record<string, any> = {
  ctx: resolver.CHANGE_CONTEXT_RESOLVER_SPEC,
  trap: { ...resolver.CHANGE_CONTEXT_RESOLVER_SPEC, applicationId: "synapse.trap-context", applicationName: "Trap Context", authorization: ["trap.context.read"] },
  other: { ...resolver.CHANGE_CONTEXT_RESOLVER_SPEC, applicationId: "synapse.second-context", applicationName: "Second Context", authorization: ["second.context.read"] },
};
const capabilityOf = (spec: any): string => authorityModule.authorityCapability(spec.applicationId, spec.authorization[0]);
const harness = harnessModule.useHostHarness();

describe("fx real authority stack", () => {
  it("serves until told to stop", async () => {
    const authority = new Authority();
    await authority.start([
      { name: "alice", tenant: TENANT },
      { name: "bob", tenant: TENANT },
      { name: "mallory", tenant: OTHER_TENANT },
    ]);
    let stopRequested: () => void = () => undefined;
    const stopped = new Promise<void>((resolve) => (stopRequested = resolve));
    try {
      await authority.bootstrap();
      await authority.declare(Object.values(specs).map(capabilityOf));
      const sessions: Record<string, { credential: string; principalId: string; tenant: string }> = {};
      for (const [name, tenant] of [["alice", TENANT], ["bob", TENANT], ["mallory", OTHER_TENANT]] as const) {
        const credential = await authority.login(name, tenant);
        sessions[name] = { credential, principalId: await authority.principalOf(credential), tenant };
      }
      const grantable = Object.values(specs).map(capabilityOf);
      await authority.grant(sessions["alice"].principalId, grantable);

      // The in-process AppBoundry host reads these on every request.
      process.env["APPPORT_AUTHBOUNDRY_URL"] = authority.url;
      process.env["APPPORT_AUTHBOUNDRY_APPLICATION"] = authority.applicationId;
      process.env["APPPORT_AUTHBOUNDRY_CHECK_CREDENTIAL"] = authority.checkCredential;
      process.env["APPPORT_AUTHBOUNDRY_TIMEOUT_MS"] = "3000";

      const apps: Record<string, { alias: string; applicationId: string; host: string }> = {};
      for (const [alias, key, wasm] of [["ctx", "ctx", undefined], ["trap", "trap", resolver.synapseWasm({ trap: true })], ["second", "other", undefined]] as const) {
        const built = await packager.buildSynapseCapabilityPackage(specs[key], wasm ? { wasm } : {});
        const deployed = await harness.deploy(built, alias);
        apps[alias] = { alias, applicationId: specs[key].applicationId, host: deployed.host };
      }
      const runtime = JSON.parse(await readFile(join(harness.runtimeDirectory(), "host", "runtime.json"), "utf8"));
      const host = `http://127.0.0.1:${runtime.port}`;

      const executions = async () => {
        const out: Record<string, { completed: number; usage: number; usageFailures: number }> = {};
        for (const app of Object.values(apps)) {
          const { records, usage } = await harness.stateRecords(app.applicationId);
          out[app.alias] = {
            completed: records.filter((record: any) => record.status === "completed").length,
            usage: usage.length,
            usageFailures: usage.filter((entry: any) => entry.status === "failure").length,
          };
        }
        return out;
      };

      const { server, port } = await listen(async (path, method, body) => {
        const route = `${method} ${path.split("?")[0]}`;
        const who = (name: string) => sessions[name] ?? (() => { throw new Error(`unknown user ${name}`); })();
        switch (route) {
          case "GET /state":
            return {
              host,
              authority: authority.url,
              apps: Object.fromEntries(Object.entries(apps).map(([alias, app]) => [alias, { applicationId: app.applicationId, capability: capabilityOf(specs[alias === "second" ? "other" : alias]) }])),
              sessions,
              versions: { authboundry: process.env["FX_STACK_AUTHBOUNDRY_VERSION"] ?? null, appboundry: process.env["FX_STACK_APPBOUNDRY_VERSION"] ?? null },
            };
          case "POST /grant":
            await authority.grant(who(body.user).principalId, body.capabilities ?? grantable);
            return { ok: true };
          case "POST /revoke":
            await authority.revoke(who(body.user).principalId);
            return { ok: true };
          case "POST /signout":
            await authority.signOut(who(body.user).credential);
            return { ok: true };
          case "POST /restart-authority":
            await authority.restart();
            return { ok: true };
          case "POST /kill-authority":
            await authority.kill();
            return { ok: true };
          case "POST /start-authority":
            await authority.spawn();
            return { ok: true };
          case "GET /decisions":
            return await authority.decisions();
          case "GET /executions":
            return await executions();
          case "GET /records": {
            const out: Record<string, unknown> = {};
            for (const app of Object.values(apps)) out[app.alias] = await harness.stateRecords(app.applicationId);
            return out;
          }
          case "POST /stop":
            stopRequested();
            return { ok: true };
          default:
            throw new Error(`no route ${route}`);
        }
      });
      writeFileSync(STATE_FILE, JSON.stringify({ control: `http://127.0.0.1:${port}` }));
      await stopped;
      server.close();
    } finally {
      for (const name of ["APPPORT_AUTHBOUNDRY_URL", "APPPORT_AUTHBOUNDRY_APPLICATION", "APPPORT_AUTHBOUNDRY_CHECK_CREDENTIAL", "APPPORT_AUTHBOUNDRY_TIMEOUT_MS"]) delete process.env[name];
      await authority.stop();
    }
  }, 3_600_000);
});
