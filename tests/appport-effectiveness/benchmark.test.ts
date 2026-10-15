// Self-tests for the AppPort effectiveness benchmark. They check the harness,
// the configurations, and the oracles; they make no performance claims and
// contain no timing thresholds. Model-driven trials here use a scripted
// provider, so they run without a real model.

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import * as protocol from "@appport/protocol";
import * as integration from "@appport/integration";
import { runFx } from "../evals/eval-helpers";
import { CONFIGS, DEFAULT_LIMITS, configEnv, detectProvider, runModelTrial, type ConfigId, type ModelTrial } from "./harness";
import { binomialTwoSided, distribution, renderMarkdown, summarize } from "./report";
import { plan, runBenchmark } from "./run";
import { REFERENCE_SOLUTIONS, WRONG_BUT_CONFIDENT, scriptedProvider, taskForBody } from "./scripted";
import {
  CONTRACTS, GRAPH_EDGES, MANIFEST_ENV, deterministicTasks, extractAnswer, fixtureDir, modelTasks, parityFixtureDir,
  runHiddenTest, sha256, taskDigest, workspaceFiles,
} from "./tasks";

const LIMITS = { ...DEFAULT_LIMITS, timeout_ms: 60_000 };
const MARKER = "AppPort contract context, prepared deterministically by fx";
const load = (path: string) => JSON.parse(readFileSync(path, "utf8"));
const memos = load(CONTRACTS["contracts/memos.manifest.json"]);
const vikunja = load(CONTRACTS["contracts/vikunja.manifest.json"]);
const task = (id: string) => modelTasks.find(t => t.id === id)!;
const ctx = (sequence = 0) => ({ repetition: 0, sequence, order_in_block: 0, cold: sequence === 0 });

function systemText(body: any): string {
  return body.messages.filter((m: any) => m.role === "system").map((m: any) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content))).join("\n");
}

describe("fixtures and oracles agree with the published contracts and reference packages", () => {
  test("fixture files match their recorded provenance", () => {
    const provenance = load(join(fixtureDir, "PROVENANCE.json"));
    for (const [file, entry] of Object.entries<any>(provenance.files)) {
      expect(`${file} ${sha256(readFileSync(join(fixtureDir, file)))}`).toBe(`${file} ${entry.sha256}`);
    }
  });

  test("discovery expectations follow from the contracts themselves", () => {
    const def = (m: any, name: string) => m.capabilities.find((c: any) => c.name === name).definitions[0];
    const integ = (m: any, key: string) => m.attributes["appport.integration/1"].capabilities[key];
    const setdone = def(vikunja, "vikunja.tasks.setdone");
    // D1: the only capability that changes the tasks resource with an update.
    expect((task("D1").expected as any).capability).toBe("vikunja.tasks.setdone@1");
    expect(integ(vikunja, "vikunja.tasks.setdone@1").access).toEqual([{ resource: "urn:appport:vikunja:tasks", mode: "changes", operations: ["update"] }]);
    // D2: search takes a tag; get does not.
    expect(def(memos, "memos.search").inputSchema.properties.tag).toBeDefined();
    expect(def(memos, "memos.get").inputSchema.properties.tag).toBeUndefined();
    // D3: required inputs and outputs, as published.
    const get = def(vikunja, "vikunja.tasks.get");
    expect([...get.inputSchema.required].sort()).toEqual((task("D3").expected as any).required_inputs);
    expect([...get.outputSchema.required].sort()).toEqual((task("D3").expected as any).required_outputs);
    // D4: declared verification, access, and no declared requires.
    const setdoneInteg = integ(vikunja, "vikunja.tasks.setdone@1");
    expect(`${setdoneInteg.verify[0].via.capability}@${setdoneInteg.verify[0].via.version}`).toBe("vikunja.tasks.get@1");
    expect(setdoneInteg.requires).toBeUndefined();
    // D6: no published capability creates tasks.
    for (const m of [memos, vikunja]) for (const [, entry] of Object.entries<any>(m.attributes["appport.integration/1"].capabilities)) {
      for (const a of entry.access ?? []) expect(a.operations ?? []).not.toContain("create");
    }
    // D7: setdone does not declare idempotency.
    expect(setdone.idempotency).toBe("unsupported");
    // D8: declared INTERNAL_ERROR behaviour.
    expect(setdoneInteg.failures.find((f: any) => f.code === "INTERNAL_ERROR")).toMatchObject({ retry: "after-verification", effect: "unknown" });
    // D9: authorization.
    expect(setdone.authorization).toEqual(["vikunja.tasks.write"]);
  });

  test("the replacement golden matches compareManifests", () => {
    const candidate = load(join(fixtureDir, "replacement/vikunja-candidate.manifest.json"));
    const report = protocol.compareManifests(vikunja, candidate);
    expect(report.compatible).toBe(false);
    const affected = [...new Set(report.breaking.map(b => b.target.split(" ")[0].replace(/@\d+$/, "")))].sort();
    expect(affected).toEqual((task("I3").expected as any).breaking_capabilities);
    expect(report.breaking.some(b => b.target.includes("projectId"))).toBe(true);
  });

  test("deterministic goldens match @appport/protocol and @appport/integration", () => {
    const lintErrors = load(join(parityFixtureDir, "lint-errors.json"));
    const issues = protocol.lintDependencyModel(lintErrors);
    expect([issues.length, issues.filter(i => i.level === "error").length]).toEqual([46, 43]);
    const graph = integration.deriveGraph({ manifests: [memos, vikunja] });
    expect(graph.edges.map(e => e.id).sort()).toEqual(GRAPH_EDGES);
    expect(graph.risks).toEqual([]);
    const update = integration.findCapabilities([memos, vikunja], { changes: "urn:appport:vikunja:tasks", operation: "update" });
    expect(update.matches.map(m => `${m.application} ${m.capability}`)).toEqual(["io.vikunja vikunja.tasks.setdone@1"]);
    const create = integration.findCapabilities([memos, vikunja], { changes: "urn:appport:vikunja:tasks", operation: "create" });
    expect(create.matches).toEqual([]);
    const del = integration.findCapabilities([memos, vikunja], { changes: "urn:appport:memos:memos", operation: "delete" });
    expect([del.matches, del.undeclared]).toEqual([[], []]);
  });

  test.each(modelTasks.map(t => t.id))("oracle for %s accepts the reference solution and rejects a confident wrong one", id => {
    const t = task(id);
    const solution = REFERENCE_SOLUTIONS[id];
    const files = workspaceFiles(t);
    const ws = (overrides: Record<string, string> = {}) => {
      const dir = require("node:fs").mkdtempSync(join(require("node:os").tmpdir(), "fx-appport-oracle-ws-"));
      for (const [rel, content] of Object.entries({ ...files, ...overrides })) {
        require("node:fs").mkdirSync(join(dir, rel, ".."), { recursive: true });
        require("node:fs").writeFileSync(join(dir, rel), content);
      }
      return dir;
    };
    const answerText = (a: unknown) => a === undefined ? "Done. All tests pass." : `Verified. SUCCESS.\n\`\`\`json\n${JSON.stringify(a)}\n\`\`\``;
    const good = ws(solution.files);
    expect(t.grade(answerText(solution.answer), good)).toMatchObject({ outcome: "pass" });
    const bad = ws();
    const g = t.grade(answerText(WRONG_BUT_CONFIDENT[id]), bad);
    expect(g.outcome).not.toBe("pass");
    expect(g.failure).not.toBeNull();
  });

  test("an unmodified legacy rewrite is not a pass", () => {
    const g = runHiddenTest(join(fixtureDir, "workspaces/legacy-references"), "src/references.mjs", `test("legacy", () => { assert.deepEqual(mod.extractTaskRefs("vikunja-task:007 ~vikunja-task:3"), [7]); });`);
    expect(g.outcome).toBe("pass");
    const t = task("I4");
    const files = workspaceFiles(t);
    const dir = require("node:fs").mkdtempSync(join(require("node:os").tmpdir(), "fx-appport-legacy-"));
    for (const [rel, content] of Object.entries(files)) { require("node:fs").mkdirSync(join(dir, rel, ".."), { recursive: true }); require("node:fs").writeFileSync(join(dir, rel), content); }
    expect(t.grade("", dir)).toMatchObject({ outcome: "partial", failure: "constraint-violation" });
  });

  test("answer extraction takes the last fenced JSON block", () => {
    expect(extractAnswer("```json\n{\"a\":1}\n```\ntext\n```json\n{\"a\":2}\n```")).toEqual({ a: 2 });
    expect(extractAnswer("no block {\"a\":1}")).toBeNull();
    expect(extractAnswer("```json\nnot json\n```")).toBeNull();
  });
});

describe("statistics", () => {
  test("exact binomial test", () => {
    expect(binomialTwoSided(0, 0)).toBe(1);
    expect(binomialTwoSided(0, 5)).toBeCloseTo(0.0625, 6);
    expect(binomialTwoSided(1, 6)).toBeCloseTo(0.21875, 6);
    expect(binomialTwoSided(3, 6)).toBe(1);
  });
  test("distribution", () => {
    expect(distribution([4, 1, 3, 2])).toMatchObject({ n: 4, min: 1, median: 2.5, max: 4, p25: 1.75, p75: 3.25 });
    expect(distribution([])).toMatchObject({ n: 0, median: null });
  });
  test("the plan pairs every task across configurations and rotates their order", () => {
    const steps = plan(["D1", "D2", "D3"], ["A", "B", "C"], 3, 7);
    expect(steps).toHaveLength(27);
    for (const id of ["D1", "D2", "D3"]) for (let r = 0; r < 3; r++) {
      expect(steps.filter(s => s.task === id && s.repetition === r).map(s => s.config).sort()).toEqual(["A", "B", "C"]);
    }
    const firsts = new Set(steps.filter(s => s.order_in_block === 0).map(s => s.config));
    expect([...firsts].sort()).toEqual(["A", "B", "C"]);
    expect(plan(["D1", "D2", "D3"], ["A", "B", "C"], 3, 7)).toEqual(steps);
  });
});

describe("validity controls", () => {
  let scripted: Awaited<ReturnType<typeof scriptedProvider>>;
  const runs = new Map<string, { trial: ModelTrial; bodies: any[] }>();
  async function trial(id: string, config: ConfigId, sequence = 0) {
    const before = scripted.requests.length;
    const t = await runModelTrial(task(id), config, scripted.provider, LIMITS, ctx(sequence));
    const bodies = scripted.requests.slice(before).map(r => r.body).filter(b => taskForBody(b));
    runs.set(`${id}${config}`, { trial: t, bodies });
    return { trial: t, bodies };
  }
  beforeAll(async () => { scripted = await scriptedProvider(); });
  afterAll(() => scripted?.close());

  test("1. with both variables unset, the request matches an ordinary fx run", async () => {
    const saved = { m: process.env.FX_APPPORT_MANIFEST, f: process.env.FX_APPPORT_FOCUS };
    // An inherited value must not leak into the baseline.
    process.env.FX_APPPORT_MANIFEST = MANIFEST_ENV;
    process.env.FX_APPPORT_FOCUS = "vikunja.tasks.setdone";
    try {
      const { bodies } = await trial("D1", "A");
      expect(bodies.length).toBeGreaterThan(0);
      expect(systemText(bodies[0])).not.toContain("AppPort");
      const before = scripted.requests.length;
      const plain = await runFx(["ask", "--json", "--no-save", LIMITS.permission, task("D1").prompt], {
        cwd: require("node:fs").mkdtempSync(join(require("node:os").tmpdir(), "fx-appport-plain-")),
        env: { ...scripted.provider.env, FX_APPPORT_MANIFEST: undefined, FX_APPPORT_FOCUS: undefined, FX_MAX_AGENT_STEPS: String(LIMITS.max_agent_steps) }, timeoutMs: 60_000,
      });
      expect(plain.code).toBe(0);
      const plainBody = scripted.requests[before].body;
      const strip = (s: string) => s.replace(/\/tmp\/[^\s"']+/g, "<tmp>");
      expect(strip(systemText(bodies[0]))).toBe(strip(systemText(plainBody)));
    } finally {
      if (saved.m === undefined) delete process.env.FX_APPPORT_MANIFEST; else process.env.FX_APPPORT_MANIFEST = saved.m;
      if (saved.f === undefined) delete process.env.FX_APPPORT_FOCUS; else process.env.FX_APPPORT_FOCUS = saved.f;
    }
  }, 120_000);

  test("2. AppPort context appears only in the configured runs", async () => {
    const b = await trial("D1", "B", 1);
    const c = await trial("D1", "C", 2);
    expect(systemText(runs.get("D1A")!.bodies[0])).not.toContain(MARKER);
    expect(systemText(b.bodies[0])).toContain(MARKER);
    expect(systemText(c.bodies[0])).toContain(MARKER);
    expect(runs.get("D1A")!.trial.appport_context_bytes).toBe(0);
    expect(b.trial.appport_context_bytes).toBeGreaterThan(c.trial.appport_context_bytes);
    expect(c.trial.appport_context_bytes).toBeGreaterThan(0);
  }, 120_000);

  test("3. focused context holds the intended capabilities and dependencies only", async () => {
    const c = systemText(runs.get("D1C")!.bodies[0]);
    expect(c).toContain("capability vikunja.tasks.setdone@1");
    expect(c).toContain("capability vikunja.tasks.get@1");
    expect(c).not.toContain("capability memos.search@1");
    expect(c).not.toContain("capability vikunja.projects.list@1");
    const b = systemText(runs.get("D1B")!.bodies[0]);
    expect(b).toContain("capability memos.search@1");
    // The context fx sends has the size the harness records.
    expect(c.slice(c.indexOf(MARKER)).length).toBeGreaterThanOrEqual(runs.get("D1C")!.trial.appport_context_bytes - 64);
  });

  test("4. all configurations use the same task and verification definitions", () => {
    const trials = ["D1A", "D1B", "D1C"].map(k => runs.get(k)!.trial);
    expect(new Set(trials.map(t => t.task_digest)).size).toBe(1);
    expect(trials[0].task_digest).toBe(taskDigest(task("D1")));
    expect(new Set(trials.map(t => JSON.stringify(t.limits))).size).toBe(1);
    // The configurations differ only in the AppPort variables.
    for (const c of Object.keys(CONFIGS) as ConfigId[]) expect(Object.keys(configEnv(c, task("D1"))).sort()).toEqual(["FX_APPPORT_FOCUS", "FX_APPPORT_MANIFEST"]);
    expect(trials.map(t => t.config_env)).toEqual([
      { FX_APPPORT_MANIFEST: null, FX_APPPORT_FOCUS: null },
      { FX_APPPORT_MANIFEST: MANIFEST_ENV, FX_APPPORT_FOCUS: null },
      { FX_APPPORT_MANIFEST: MANIFEST_ENV, FX_APPPORT_FOCUS: "vikunja.tasks.setdone" },
    ]);
  });

  test("5. each trial starts from the same clean fixture state", async () => {
    const first = await trial("I1", "A", 3);
    expect(first.trial.outcome).toBe("pass");
    const second = await trial("I1", "B", 4);
    expect(second.trial.clean_start).toBe(true);
    expect(second.trial.workspace_digest_before).toBe(first.trial.workspace_digest_before);
    expect(second.trial.workspace_digest_before).toBe(second.trial.workspace_digest_expected);
    expect(second.trial.outcome).toBe("pass");
  }, 120_000);

  test("6. incorrect results fail even when the model claims success", async () => {
    const liar = await scriptedProvider(() => "wrong");
    try {
      for (const id of ["D1", "D6", "D7", "I1", "I3"]) {
        const t = await runModelTrial(task(id), "B", liar.provider, LIMITS, ctx());
        expect(t.answer_tail).toMatch(/SUCCESS/);
        expect([id, t.outcome]).not.toEqual([id, "pass"]);
        expect(t.failure).not.toBeNull();
      }
    } finally { liar.close(); }
  }, 180_000);

  test("7. missing provider metrics are recorded as unavailable", async () => {
    const quiet = await scriptedProvider(() => "no-usage");
    try {
      const t = await runModelTrial(task("D2"), "A", quiet.provider, LIMITS, ctx());
      expect(t.outcome).toBe("pass");
      expect(t.input_tokens).toMatchObject({ value: null, available: false });
      expect(t.output_tokens).toMatchObject({ value: null, available: false });
      expect(t.cost).toMatchObject({ value: null, available: false });
      expect(t.model_calls.available).toBe(true);
      const summary = summarize({ ...emptyResults(), trials: [t] });
      expect((summary.configurations as any).A.metrics.input_tokens).toMatchObject({ n: 0, available_in: 0, of: 1 });
    } finally { quiet.close(); }
  }, 60_000);

  test("8. failed trials stay in the results and the denominators", async () => {
    const broken = await scriptedProvider(() => "request-error");
    try {
      const results = await runBenchmark({
        repetitions: 1, detRepetitions: 1, tasks: ["D9"], configs: ["A", "B", "C"], limits: LIMITS, seed: 3, provider: broken.provider,
      });
      expect(results.trials).toHaveLength(3);
      expect(results.trials.every(t => t.outcome === "fail" && t.failure === "fx-error")).toBe(true);
      const summary = summarize(results);
      for (const c of ["A", "B", "C"]) expect((summary.configurations as any)[c]).toMatchObject({ trials: 1, fail: 1, verified_completion_rate: 0 });
      expect(renderMarkdown(results, summary)).toContain("fx-error 1");
    } finally { broken.close(); }
    const down = await scriptedProvider(() => "provider-unavailable");
    try {
      const t = await runModelTrial(task("D9"), "A", down.provider, { ...LIMITS, timeout_ms: 4_000 }, ctx());
      expect(t).toMatchObject({ outcome: "fail", failure: "timeout", fx_timed_out: true });
    } finally { down.close(); }
  }, 120_000);

  test("9. results record configuration and fixture versions", async () => {
    const results = await runBenchmark({ repetitions: 1, detRepetitions: 1, tasks: ["D2"], configs: ["A", "C"], limits: LIMITS, seed: 9, provider: scripted.provider });
    const env = results.environment as any;
    expect(env.fx_version).toMatch(/\d+\.\d+\.\d+/);
    expect(env.git_commit).toMatch(/^[0-9a-f]{40}$|^unknown$/);
    expect(env.fixtures_digest).toMatch(/^[0-9a-f]{64}$/);
    expect(env.provider_kind).toBe("scripted");
    expect(env.provider.model).toBe("local-model");
    expect(env.limits).toEqual(LIMITS);
    expect(results.tasks.find(t => t.id === "D2")!.digest).toBe(taskDigest(task("D2")));
    expect(results.trials.map(t => t.config).sort()).toEqual(["A", "C"]);
    const summary = summarize(results);
    const md = renderMarkdown(results, summary);
    expect(md).toContain("Harness self-test");
    expect(md).toContain("inconclusive");
    expect(md).not.toMatch(/yes: /);
  }, 120_000);

  test("10. the benchmark does not change the contract authority or the provider boundary", () => {
    const provenance = load(join(fixtureDir, "PROVENANCE.json"));
    for (const [file, entry] of Object.entries<any>(provenance.files)) expect(sha256(readFileSync(join(fixtureDir, file)))).toBe(entry.sha256);
    // The parity pins the native layer follows are unchanged.
    const parity = load(join(parityFixtureDir, "../package.json")).devDependencies;
    expect(parity).toMatchObject({ "@appport/protocol": "1.1.0", "@appport/integration": "1.1.0", "@appport/sdk": "1.2.4", "@appport/core": "1.2.0", "@appport/server": "1.1.2", "@appport/client": "1.1.2", "@appport/transport-http": "1.1.2" });
    const own = load(join(fixtureDir, "../package.json")).devDependencies;
    expect(own).toEqual({ "@appport/integration": parity["@appport/integration"], "@appport/protocol": parity["@appport/protocol"] });
    // Nothing in the benchmark injects context another way.
    for (const file of ["harness.ts", "run.ts", "tasks.ts"]) {
      const source = readFileSync(join(fixtureDir, "..", file), "utf8");
      expect(source).not.toMatch(/role:\s*"system"/);
    }
  });
});

describe("deterministic tier", () => {
  test("every deterministic task matches its golden without a provider", async () => {
    const results = await runBenchmark({ repetitions: 0, detRepetitions: 1, configs: ["A"], limits: LIMITS, seed: 1, noModel: true });
    expect(results.model_tier).toEqual({ ran: false, skipped_reason: "the model tier was disabled with --no-model" });
    expect(results.deterministic.filter(d => d.outcome !== "pass").map(d => `${d.task_id}: ${d.detail}`)).toEqual([]);
    expect(results.deterministic).toHaveLength(deterministicTasks.length);
    expect(results.solvers.map(s => [s.task_id, s.outcome])).toEqual([["D1", "pass"], ["D4", "pass"], ["D6", "pass"]]);
  }, 60_000);

  test("deterministic operations send nothing to a provider", async () => {
    const watcher = await scriptedProvider();
    try {
      const before = watcher.requests.length;
      for (const t of deterministicTasks) {
        await runFx(["appport", ...t.args, "--json"], { cwd: fixtureDir, env: { ...watcher.provider.env }, timeoutMs: 30_000 });
      }
      expect(watcher.requests.length).toBe(before);
    } finally { watcher.close(); }
  }, 60_000);

  test("without a configured provider the model tier is skipped with a reason", async () => {
    const home = require("node:fs").mkdtempSync(join(require("node:os").tmpdir(), "fx-appport-noprov-"));
    const probe = await detectProvider({ HOME: home, AI_GATEWAY_API_KEY: undefined, VERCEL_OIDC_TOKEN: undefined, FX_PROVIDER: undefined, FX_MODEL: undefined });
    expect(probe.available).toBe(false);
    expect(probe.reason).toContain("no model provider is configured");
  });
});

function emptyResults() {
  return {
    format: "fx.appport-effectiveness-results/1" as const, benchmark_version: "test", started_at: "", finished_at: "", environment: {},
    model_tier: { ran: true, skipped_reason: null }, trials: [], deterministic: [], solvers: [], extensions: [], tasks: [],
  };
}
