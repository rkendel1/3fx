// Tests for the benchmark runner: provider readiness, the smoke profile, run
// accounting, and the result contract. Model-driven trials use scripted
// providers through the real trial code path; they validate the runner and are
// never evidence about any model.

import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { completion, createConfiguredProviderFixture as fixture } from "../e2e/fixtures/chat-completions";
import { DEFAULT_LIMITS } from "./harness";
import { displayEndpoint, renderPreflight, runPreflight, scrubSecrets } from "./preflight";
import { renderMarkdown, summarize, type Results } from "./report";
import { SMOKE_TASKS, describePlan, exitCode, parseArgs, resolvePlan, runBenchmark, writeResults } from "./run";
import { scriptedProvider } from "./scripted";
import { modelTasks, taskDigest } from "./tasks";

const LIMITS = { ...DEFAULT_LIMITS, timeout_ms: 60_000 };
const FAKE_KEY = "sk-test-FAKESECRET-0123456789abcdef";
/** An environment with no provider: an empty HOME and no credentials. */
function emptyEnv() {
  const home = mkdtempSync(join(tmpdir(), "fx-appport-runner-"));
  return { home, env: { HOME: home, AI_GATEWAY_API_KEY: undefined, VERCEL_OIDC_TOKEN: undefined, FX_PROVIDER: undefined, FX_MODEL: undefined, FX_GATEWAY_BASE_URL: undefined, FX_GATEWAY_CHAT_URL: undefined } as Record<string, string | undefined> };
}
const smoke = (provider: any) => runBenchmark({ runType: "smoke", repetitions: 0, detRepetitions: 0, configs: ["A", "B", "C"], limits: LIMITS, seed: 1, provider });

describe("provider readiness", () => {
  test("missing authentication", async () => {
    const { home, env } = emptyEnv();
    try {
      const p = await runPreflight({ env });
      expect(p.state).toBe("missing_auth");
      expect(p.model_ready).toBe(false);
      expect(p.deterministic_ready).toBe(true);
      expect(p.checks.find(c => c.name === "auth")?.status).toBe("fail");
    } finally { rmSync(home, { recursive: true, force: true }); }
  });

  test("missing provider", async () => {
    const { home, env } = emptyEnv();
    try {
      const p = await runPreflight({ env: { ...env, FX_PROVIDER: "not-configured" } });
      expect(p.state).toBe("missing_provider");
      expect(p.model_ready).toBe(false);
    } finally { rmSync(home, { recursive: true, force: true }); }
  });

  test("unreachable Gateway endpoint, without exposing the key", async () => {
    const { home, env } = emptyEnv();
    try {
      const p = await runPreflight({ env: { ...env, AI_GATEWAY_API_KEY: FAKE_KEY, FX_GATEWAY_BASE_URL: "http://127.0.0.1:9" } });
      expect(p.state).toBe("endpoint_unreachable");
      expect(p.provider.auth).toBe("AI_GATEWAY_API_KEY");
      expect(p.endpoint_check.status).toBe("unreachable");
      const everything = JSON.stringify(p) + renderPreflight(p);
      expect(everything).not.toContain(FAKE_KEY);
      expect(everything).not.toContain("FAKESECRET");
    } finally { rmSync(home, { recursive: true, force: true }); }
  }, 60_000);

  test("unreachable configured endpoint", async () => {
    const f = fixture(b => completion(b.model, "unused"));
    try {
      f.settings.providers.local.base_url = "http://127.0.0.1:9/v1";
      f.save();
      const p = await runPreflight({ env: f.env, probeTimeoutMs: 3_000 });
      expect(p.state).toBe("endpoint_unreachable");
      expect(p.endpoint_check.method).toContain("unauthenticated");
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 60_000);

  test("unsupported model", async () => {
    const s = await scriptedProvider();
    try {
      const p = await runPreflight({ env: s.provider.env, model: "no-such-model" });
      expect(p.state).toBe("unsupported_model");
      expect(p.provider.requested_model).toBe("no-such-model");
      expect(p.model_check.status).toBe("not_listed");
    } finally { s.close(); }
  }, 60_000);

  test("ready, with no inference request", async () => {
    const s = await scriptedProvider();
    try {
      const p = await runPreflight({ env: s.provider.env });
      expect(p.state).toBe("ready");
      expect(p.model_ready).toBe(true);
      expect(p.provider.model).toBe("local-model");
      expect(p.fx.build_mode).toMatch(/^(Debug|ReleaseSafe|ReleaseFast|ReleaseSmall)$/);
      expect(p.fx.sha256).toMatch(/^[0-9a-f]{64}$/);
      expect(p.endpoint_check).toMatchObject({ status: "reachable" });
      // Only the credential-free endpoint probe reached the provider; no chat completion was requested.
      expect(s.requests.every(r => r.body === null && !r.path.endsWith("/chat/completions"))).toBe(true);
      expect(s.requests.every(r => r.authorization === null)).toBe(true);
      expect(p.note).toMatch(/not proof/);
    } finally { s.close(); }
  }, 60_000);

  test("secret scrubbing", () => {
    const env = { MY_API_KEY: "abcdefghijklmnopqrstuvwxyz", FX_AUTH_MODE: "gateway" };
    const text = "key abcdefghijklmnopqrstuvwxyz; Authorization: Bearer abc.def.ghijklmnop; https://user:pw@host.example/v1?api_key=zzz123&x=1 sk-live_1234567890abcd gateway";
    const out = scrubSecrets(text, env);
    for (const secret of ["abcdefghijklmnopqrstuvwxyz", "abc.def.ghijklmnop", "user:pw", "zzz123", "sk-live_1234567890abcd"]) expect(out).not.toContain(secret);
    expect(out).toContain("gateway");
    expect(displayEndpoint("https://u:p@api.example.com/v1/?key=1#x")).toBe("https://api.example.com/v1");
  });
});

describe("smoke profile", () => {
  test("plan and arguments", () => {
    const cli = parseArgs(["--smoke", "--model", "m1"]);
    expect(cli.options.runType).toBe("smoke");
    expect(resolvePlan(cli.options)).toMatchObject({ tasks: SMOKE_TASKS, configs: ["A", "B", "C"], repetitions: 1 });
    expect(describePlan(resolvePlan(cli.options), cli.options.limits)).toMatch(/at most 9 model trials/);
    expect(describePlan(resolvePlan(cli.options), cli.options.limits)).toMatch(/not provider requests/);
    expect(() => parseArgs(["--smoke", "--repetitions", "3"])).toThrow();
    expect(() => parseArgs(["--smoke", "--preflight"])).toThrow();
    expect(() => parseArgs(["--tasks", "Z9"])).toThrow();
    // The smoke subset is existing tasks with their existing oracles.
    for (const id of SMOKE_TASKS) expect(modelTasks.some(t => t.id === id)).toBe(true);
  });

  test("a successful smoke run invokes the provider in every configuration and makes no statistical claim", async () => {
    const s = await scriptedProvider();
    try {
      const r = await smoke(s.provider);
      expect(r.run.type).toBe("smoke");
      expect(r.run.status).toBe("completed");
      expect(r.run.smoke?.verdict).toBe("passed");
      expect(r.trials).toHaveLength(9);
      expect(r.run.planned.max_trials).toBe(9);
      for (const c of ["A", "B", "C"]) expect(r.run.provider_invocations[c].trials_with_provider_calls).toBe(3);
      // Every configuration ran the same task definitions.
      for (const id of SMOKE_TASKS) {
        const digests = new Set(r.trials.filter(t => t.task_id === id).map(t => t.task_digest));
        expect([...digests]).toEqual([taskDigest(modelTasks.find(t => t.id === id)!)]);
        expect(r.trials.filter(t => t.task_id === id).map(t => t.config).sort()).toEqual(["A", "B", "C"]);
      }
      expect(r.trials.every(t => t.outcome === "pass" && t.independently_verified)).toBe(true);
      expect(r.run.statistical_comparison.suitable).toBe(false);
      const summary = summarize(r);
      expect(summary.comparisons).toEqual([]);
      expect(summary.interpretation).toEqual([]);
      const md = renderMarkdown(r, summary);
      expect(md).toContain("**Run type:** Smoke test");
      expect(md).toContain("not an effectiveness comparison");
      expect(md).not.toMatch(/McNemar|sign test|p=0\./);
      expect(exitCode(r, false)).toBe(0);
    } finally { s.close(); }
  }, 120_000);

  test("independent oracles fail confident wrong answers in a smoke run", async () => {
    const s = await scriptedProvider(() => "wrong");
    try {
      const r = await smoke(s.provider);
      expect(r.run.smoke?.verdict).toBe("passed");
      expect(r.trials.every(t => t.outcome !== "pass")).toBe(true);
      expect(r.run.oracle.pass).toBe(0);
      expect(r.run.oracle.failure_categories).toMatchObject({ "invented-capability": 3, "false-compatibility-claim": 3 });
    } finally { s.close(); }
  }, 120_000);

  test("a provider failure on the first request is recorded, not hidden", async () => {
    const s = await scriptedProvider(() => "request-error");
    try {
      const r = await smoke(s.provider);
      expect(r.run.status).toBe("provider_failed");
      expect(r.run.smoke?.verdict).toBe("failed");
      expect(r.trials).toHaveLength(9);
      expect(r.run.connectivity_failures.count).toBe(9);
      expect(r.run.connectivity_failures.by_category).toEqual({ "fx-error": 9 });
      expect(summarize(r).configurations.A).toMatchObject({ trials: 3, fail: 3, verified_completion_rate: 0 });
      expect(exitCode(r, false)).toBe(2);
    } finally { s.close(); }
  }, 120_000);

  test("timeouts stay in the denominator", async () => {
    const s = await scriptedProvider(() => "provider-unavailable");
    try {
      const r = await runBenchmark({ runType: "smoke", repetitions: 0, detRepetitions: 0, configs: ["A", "B", "C"], limits: { ...LIMITS, timeout_ms: 3_000 }, seed: 1, provider: s.provider });
      expect(r.trials).toHaveLength(9);
      expect(r.trials.every(t => t.failure === "timeout")).toBe(true);
      expect(r.run.status).toBe("provider_failed");
      expect((summarize(r).configurations as any).B.trials).toBe(3);
    } finally { s.close(); }
  }, 120_000);
});

describe("result contract", () => {
  test("no-model runs say the effectiveness comparison did not run", async () => {
    const r = await runBenchmark({ repetitions: 2, detRepetitions: 1, configs: ["A", "B", "C"], limits: LIMITS, seed: 1, noModel: true });
    expect(r.run).toMatchObject({ type: "comparison", status: "deterministic_only", completed_trials: 0 });
    expect(r.run.statistical_comparison.suitable).toBe(false);
    expect(r.run.skipped_configurations.map(s => s.config)).toEqual(["A", "B", "C"]);
    const md = renderMarkdown(r, summarize(r));
    expect(md).toContain("The effectiveness comparison did not run");
    expect(md).not.toMatch(/Improved verified completion: yes/);
  }, 60_000);

  test("a blocked run records why and does not claim success", async () => {
    const { home, env } = emptyEnv();
    const saved = { ...process.env };
    try {
      Object.assign(process.env, { HOME: home });
      for (const k of Object.keys(env)) if (env[k] === undefined) delete process.env[k];
      const r = await runBenchmark({ runType: "smoke", repetitions: 0, detRepetitions: 0, configs: ["A", "B", "C"], limits: LIMITS, seed: 1 });
      expect(r.run.status).toBe("blocked");
      expect(r.run.status_detail).toContain("missing_auth");
      expect(r.preflight?.state).toBe("missing_auth");
      expect(r.run.smoke?.verdict).toBe("failed");
      expect(exitCode(r, false)).toBe(2);
    } finally {
      for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k];
      Object.assign(process.env, saved);
      rmSync(home, { recursive: true, force: true });
    }
  }, 60_000);

  test("artifacts come from the same trial records and identify the commit and run type", async () => {
    const s = await scriptedProvider();
    const dir = mkdtempSync(join(tmpdir(), "fx-appport-artifacts-"));
    try {
      const r = await smoke(s.provider);
      writeResults(r, dir);
      const trials = JSON.parse(readFileSync(join(dir, "trials.json"), "utf8")) as Results;
      const summary = JSON.parse(readFileSync(join(dir, "summary.json"), "utf8"));
      const md = readFileSync(join(dir, "report.md"), "utf8");
      expect(JSON.parse(JSON.stringify(summarize(trials)))).toEqual(summary);
      expect(renderMarkdown(trials, summarize(trials))).toBe(md);
      expect(trials.run.type).toBe("smoke");
      expect(summary.run.type).toBe("smoke");
      expect(trials.run.git_commit).toMatch(/^[0-9a-f]{40}$|^unknown$/);
      expect(summary.run.git_commit).toBe(trials.run.git_commit);
      expect(md).toContain(trials.run.git_commit);
      expect(trials.run.fx_binary_sha256).toMatch(/^[0-9a-f]{64}$/);
      expect(trials.run.fx_build_mode).toMatch(/^(Debug|ReleaseSafe|ReleaseFast|ReleaseSmall)$/);
    } finally { s.close(); rmSync(dir, { recursive: true, force: true }); }
  }, 120_000);

  test("secrets never appear in artifacts, even when the provider or model echoes them", async () => {
    for (const echo of ["error", "answer"] as const) {
      // A provider that reflects the credential in an error body, or a model that repeats it in its answer.
      const f = fixture(b => echo === "error"
        ? new Response(JSON.stringify({ error: { message: `invalid key ${FAKE_KEY}` } }), { status: 400, headers: { "content-type": "application/json" } })
        : completion(b.model, `I used ${FAKE_KEY}.\n\`\`\`json\n{"capability": "${FAKE_KEY}"}\n\`\`\``));
      const dir = mkdtempSync(join(tmpdir(), "fx-appport-secret-"));
      try {
        const env = { ...f.env, AI_GATEWAY_API_KEY: FAKE_KEY, FX_TEST_PROVIDER_TOKEN: FAKE_KEY } as Record<string, string | undefined>;
        const pre = await runPreflight({ env });
        const provider = { kind: "scripted" as const, env, identity: { model: pre.provider.model, model_source: pre.provider.model_source, provider_endpoint: pre.provider.endpoint, auth: pre.provider.auth, build_revision: pre.fx.build_revision } };
        const r = await smoke(provider);
        if (echo === "answer") {
          expect(r.trials[0].answer_tail).toContain("<redacted>");
          expect(r.trials.every(t => t.outcome !== "pass")).toBe(true);
        }
        writeResults(r, dir);
        for (const file of ["trials.json", "summary.json", "report.md"]) {
          const text = readFileSync(join(dir, file), "utf8");
          expect([echo, file, text.includes(FAKE_KEY), text.includes("FAKESECRET")]).toEqual([echo, file, false, false]);
        }
      } finally { f.close(); rmSync(dir, { recursive: true, force: true }); }
    }
  }, 180_000);

  test("an interrupted run is labeled incomplete", async () => {
    const s = await scriptedProvider();
    try {
      const checkpoints: Results[] = [];
      await runBenchmark({ runType: "smoke", repetitions: 0, detRepetitions: 0, configs: ["A", "B", "C"], limits: LIMITS, seed: 1, provider: s.provider, checkpoint: r => checkpoints.push(r) });
      expect(checkpoints).toHaveLength(9);
      expect(checkpoints[3].run).toMatchObject({ status: "incomplete", completed_trials: 4, scheduled_trials: 9 });
      expect(checkpoints[3].run.statistical_comparison.suitable).toBe(false);
    } finally { s.close(); }
  }, 120_000);
});

describe("backward compatibility", () => {
  test("the documented comparison invocation is unchanged", () => {
    const cli = parseArgs(["--repetitions", "5"]);
    expect(cli.options).toMatchObject({ runType: "comparison", repetitions: 5, detRepetitions: 5, configs: ["A", "B", "C"], seed: 1, limits: DEFAULT_LIMITS });
    expect(resolvePlan(cli.options).tasks).toEqual(modelTasks.map(t => t.id));
    expect(cli.requireModel).toBe(false);
    expect(parseArgs([]).options.repetitions).toBe(3);
  });

  test("a completed comparison keeps the paired statistics", async () => {
    const s = await scriptedProvider();
    try {
      const r = await runBenchmark({ repetitions: 1, detRepetitions: 0, tasks: ["D1", "D9"], configs: ["A", "B", "C"], limits: LIMITS, seed: 2, provider: s.provider });
      expect(r.run).toMatchObject({ type: "comparison", status: "completed" });
      expect(r.run.statistical_comparison.suitable).toBe(true);
      const summary = summarize(r);
      expect(summary.comparisons.map(c => c.compare)).toEqual(["B vs A", "C vs A", "C vs B"]);
      expect(renderMarkdown(r, summary)).toContain("Improved verified completion: inconclusive");
    } finally { s.close(); }
  }, 120_000);

  test("results written before the run section existed still render", () => {
    const legacy: any = {
      format: "fx.appport-effectiveness-results/1", benchmark_version: "appport-effectiveness/1", started_at: "", finished_at: "",
      environment: {}, model_tier: { ran: false, skipped_reason: "no provider" }, trials: [], deterministic: [], solvers: [], extensions: [], tasks: [],
    };
    const md = renderMarkdown(legacy, summarize(legacy));
    expect(md).toContain("no provider");
  });
});
