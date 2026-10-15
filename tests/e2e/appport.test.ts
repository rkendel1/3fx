import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { createConfiguredProviderFixture as fixture } from "./fixtures/chat-completions";

const fixtures = resolve(import.meta.dir, "../appport-parity/fixtures");
const docs = join(fixtures, "docs.json");
const billing = join(fixtures, "billing.json");
const lintErrors = join(fixtures, "lint-errors.json");
const contextMarker = "AppPort contract context, prepared deterministically by fx";

function cliEnv(home: string) {
  // No PATH: inspection must not need Node.js, npm, or any other program.
  return { HOME: home, PATH: "/nonexistent", FX_AUTO_UPGRADE: "0", FX_SOUND: "0", NO_COLOR: "1" };
}

function systemMessages(body: any): string[] {
  return body.messages
    .filter((message: any) => message.role === "system")
    .map((message: any) => (typeof message.content === "string" ? message.content : JSON.stringify(message.content)));
}

describe("fx appport", () => {
  test("inspects contracts natively without Node.js or npm", async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-appport-"));
    try {
      const valid = await runFx(["appport", "inspect", docs, billing, "--json"], { cwd: home, env: cliEnv(home) });
      expect(valid.stderr).toBe("");
      expect(valid.code).toBe(0);
      const report = JSON.parse(valid.stdout);
      expect(report.kind).toBe("appport.inspect");
      expect(report.verdict).toBe("valid");
      expect(report.contracts.map((c: any) => c.application.id)).toEqual(["com.example.docs", "com.example.billing"]);
      expect(report.contracts[0].digest).toMatch(/^sha256:[0-9a-f]{64}$/);
      expect(report.not_checked.length).toBeGreaterThan(0);

      const inconsistent = await runFx(["appport", "inspect", lintErrors], { cwd: home, env: cliEnv(home) });
      expect(inconsistent.code).toBe(1);
      expect(inconsistent.stderr).toBe("");
      expect(inconsistent.stdout).toContain("verdict=inconsistent");
      expect(inconsistent.stdout).toContain("capabilities[bad.get@1].requires[9]: an unpinned target needs a versionConstraint");

      writeFileSync(join(home, "broken.json"), "{\"protocol\": \"appport/1\",");
      const malformed = await runFx(["appport", "inspect", "broken.json", "--json"], { cwd: home, env: cliEnv(home) });
      expect(malformed.code).toBe(1);
      expect(JSON.parse(malformed.stdout).contracts[0].verdict).toBe("malformed");

      const missing = await runFx(["appport", "graph", "absent.json", "--json"], { cwd: home, env: cliEnv(home) });
      expect(missing.code).toBe(1);
      expect(JSON.parse(missing.stdout)).toEqual({ kind: "appport.graph", error: "absent.json: contract file not found", code: "ContractNotFound" });

      const unsupported = await runFx(["appport", "assess", docs], { cwd: home, env: cliEnv(home) });
      expect(unsupported.code).toBe(1);
      expect(unsupported.stderr).toContain("assessReplacement is not implemented natively");

      const usage = await runFx(["appport", "inspect"], { cwd: home, env: cliEnv(home) });
      expect(usage.code).toBe(1);
      expect(usage.stderr).toContain("usage: fx appport");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("derives the graph and selects capabilities from published fields", async () => {
    const home = mkdtempSync(join(tmpdir(), "fx-appport-"));
    try {
      const graph = await runFx(["appport", "graph", docs, billing, "--json"], { cwd: home, env: cliEnv(home) });
      expect(graph.code).toBe(0);
      const body = JSON.parse(graph.stdout);
      expect(body.graph.edges.every((edge: any) => edge.provenance.join() === "declared")).toBe(true);
      expect(body.graph.risks.map((risk: any) => risk.kind).sort()).toEqual(["conflicting-ownership", "required-synchronous-cycle", "writes-foreign-resource"]);

      const find = await runFx(["appport", "find", docs, billing, "--changes", "urn:example:docs:document", "--json"], { cwd: home, env: cliEnv(home) });
      expect(find.code).toBe(0);
      expect(JSON.parse(find.stdout).matches.map((m: any) => `${m.application} ${m.capability}`)).toEqual([
        "com.example.billing billing.charge@1",
        "com.example.docs docs.save@2",
      ]);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
});

describe("AppPort model context", () => {
  test("ordinary runs carry no AppPort context, and opted-in runs carry only the focused contract knowledge", async () => {
    const f = fixture();
    try {
      const baseline = await runFx(["ask", "--json", "--no-save", "Say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (baseline.code !== 0) throw new Error(baseline.stdout + baseline.stderr);
      expect(f.requests).toHaveLength(1);
      const baselineSystem = systemMessages(f.requests[0].body);
      expect(baselineSystem.some(content => content.includes("AppPort"))).toBe(false);

      const aware = await runFx(["ask", "--json", "--no-save", "Say hello"], {
        cwd: f.workspace,
        env: { ...f.env, FX_APPPORT_MANIFEST: `${docs},${billing}`, FX_APPPORT_FOCUS: "docs.save" },
        timeoutMs: 20000,
      });
      if (aware.code !== 0) throw new Error(aware.stdout + aware.stderr);
      expect(f.requests).toHaveLength(2);
      const request = f.requests[1];
      // The opted-in request went to the configured provider, not a vendor default.
      expect(request.path).toBe("/v1/chat/completions");
      expect(request.authorization).toBeNull();
      const awareSystem = systemMessages(request.body);
      const appport = awareSystem.filter(content => content.includes(contextMarker));
      expect(appport).toHaveLength(1);
      const context = appport[0];
      expect(context).toContain("capability docs.save@2 request consequential");
      expect(context).toContain("capability docs.get@1 request observation");
      expect(context).toContain("verification (required to confirm the effect): state read-back readback via docs.get@1");
      expect(context).toContain("approval: required by urn:example:role:editor");
      expect(context).toContain("invokes com.example.billing billing.charge@1 required");
      expect(context).not.toContain("docs.watch");
      expect(context).not.toContain("billing.invoice.get");
      expect(context.length).toBeLessThan(16 * 1024 + 1024);

      // Everything else in the system prompt is what an ordinary run sends.
      expect(awareSystem.filter(content => !content.includes(contextMarker))).toEqual(baselineSystem);
    } finally {
      f.close();
    }
  }, 45000);

  test("an unreadable contract becomes a notice, not a failed turn", async () => {
    const f = fixture();
    try {
      const result = await runFx(["ask", "--json", "--no-save", "Say hello"], {
        cwd: f.workspace,
        env: { ...f.env, FX_APPPORT_MANIFEST: "missing-contract.json" },
        timeoutMs: 20000,
      });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      const notices = systemMessages(f.requests[0].body).filter(content => content.includes("AppPort contract missing-contract.json is unavailable"));
      expect(notices).toHaveLength(1);
    } finally {
      f.close();
    }
  }, 30000);
});
