// Aggregates trial records into the benchmark report. The JSON summary and the
// Markdown report are both built from the same records by this file.
//
// Deterministic operations and model-driven tasks are reported separately and
// never combined into one score. Every interpretation is derived from the
// paired data with exact tests; with too few pairs the answer is
// "inconclusive", never an improvement.

import type { ConfigId, DeterministicTrial, ModelTrial, SolverTrial } from "./harness";
import { CONFIGS } from "./harness";
import type { Preflight } from "./preflight";

export type RunType = "preflight" | "smoke" | "comparison";
/**
 * - preflight_only: readiness was checked; no trials were requested.
 * - deterministic_only: the model tier was disabled with --no-model.
 * - blocked: the model tier did not start, for the recorded reason.
 * - provider_failed: model trials ran, but none got past provider or harness failures.
 * - incomplete: the run stopped before every scheduled trial finished.
 * - completed: every scheduled model trial finished and was graded.
 */
export type RunStatus = "preflight_only" | "deterministic_only" | "blocked" | "provider_failed" | "incomplete" | "completed";

export interface RunSection {
  type: RunType;
  status: RunStatus;
  status_detail: string;
  git_commit: string;
  git_dirty: boolean;
  benchmark_version: string;
  fixtures_digest: string;
  fx_binary_sha256: string;
  fx_build_mode: string | null;
  provider: unknown;
  preflight_state: string | null;
  planned: { tasks: string[]; configurations: ConfigId[]; repetitions: number; max_trials: number; note: string };
  scheduled_trials: number;
  completed_trials: number;
  provider_invocations: Record<string, { trials: number; trials_with_provider_calls: number; model_calls: number; review_calls: number; trials_without_call_data: number }>;
  skipped_configurations: { config: ConfigId; reason: string }[];
  connectivity_failures: { count: number; by_category: Record<string, number>; first: string | null };
  oracle: { pass: number; partial: number; fail: number; unsupported: number; failure_categories: Record<string, number> };
  tokens: { input_available_in: number; output_available_in: number; of: number };
  cost: { available: boolean; reason: string };
  smoke?: { tasks: string[]; verdict: "passed" | "failed"; detail: string };
  statistical_comparison: { suitable: boolean; reason: string };
}

const CONNECTIVITY = new Set(["fx-error", "timeout", "harness-error"]);

/** Derives the run section from the trial records. */
export function runSection(results: Results, meta: {
  type: RunType; planned_tasks: string[]; planned_configs: ConfigId[]; repetitions: number; planned_trials: number;
  scheduled_trials: number; finished: boolean; no_model: boolean;
}): RunSection {
  const env = results.environment as any;
  const trials = results.trials;
  const invocations: RunSection["provider_invocations"] = {};
  for (const c of meta.planned_configs) {
    const xs = trials.filter(t => t.config === c);
    invocations[c] = {
      trials: xs.length,
      trials_with_provider_calls: xs.filter(t => (t.model_calls.value ?? 0) > 0).length,
      model_calls: xs.reduce((a, t) => a + (t.model_calls.value ?? 0), 0),
      review_calls: xs.reduce((a, t) => a + (t.review_calls.value ?? 0), 0),
      trials_without_call_data: xs.filter(t => !t.model_calls.available).length,
    };
  }
  const byCategory: Record<string, number> = {};
  const failures: Record<string, number> = {};
  for (const t of trials) {
    if (t.failure) failures[t.failure] = (failures[t.failure] ?? 0) + 1;
    if (t.failure && CONNECTIVITY.has(t.failure)) byCategory[t.failure] = (byCategory[t.failure] ?? 0) + 1;
  }
  const connectivityCount = Object.values(byCategory).reduce((a, b) => a + b, 0);
  const firstConnectivity = trials.find(t => t.failure && CONNECTIVITY.has(t.failure));

  let status: RunStatus;
  let detail: string;
  if (meta.type === "preflight") { status = "preflight_only"; detail = `preflight state ${results.preflight?.state ?? "unknown"}; no trials requested`; }
  else if (meta.scheduled_trials === 0) {
    status = meta.no_model ? "deterministic_only" : "blocked";
    detail = results.model_tier.skipped_reason ?? "no model trials were scheduled";
  } else if (!meta.finished || trials.length < meta.scheduled_trials) { status = "incomplete"; detail = `${trials.length} of ${meta.scheduled_trials} scheduled trials finished`; }
  else if (trials.every(t => t.failure && CONNECTIVITY.has(t.failure))) { status = "provider_failed"; detail = `all ${trials.length} trials failed before producing a gradable result (${Object.entries(byCategory).map(([k, v]) => `${k} ${v}`).join(", ")})`; }
  else { status = "completed"; detail = `${trials.length} of ${meta.scheduled_trials} scheduled trials finished and were graded`; }

  const skipped: RunSection["skipped_configurations"] = [];
  for (const c of ["A", "B", "C"] as ConfigId[]) {
    if (!meta.planned_configs.includes(c)) { if (meta.type !== "preflight") skipped.push({ config: c, reason: "not requested (--configs)" }); continue; }
    if (meta.scheduled_trials === 0) skipped.push({ config: c, reason: results.model_tier.skipped_reason ?? "model tier did not run" });
    else if (invocations[c].trials > 0 && invocations[c].trials_with_provider_calls === 0) {
      skipped.push({ config: c, reason: `no trial reached the provider${invocations[c].trials_without_call_data ? " (no call data recorded)" : ""}` });
    }
  }

  let smoke: RunSection["smoke"];
  if (meta.type === "smoke") {
    const missing = meta.planned_configs.filter(c => !invocations[c] || invocations[c].trials_with_provider_calls === 0);
    const ok = status === "completed" && missing.length === 0 && connectivityCount === 0;
    smoke = {
      tasks: meta.planned_tasks,
      verdict: ok ? "passed" : "failed",
      detail: ok
        ? "every configuration invoked the provider and every trial was graded by its oracle; oracle outcomes are below"
        : status !== "completed" ? `run ${status}: ${detail}` : missing.length ? `configurations that never reached the provider: ${missing.join(", ")}` : `${connectivityCount} trials hit provider or harness failures`,
    };
  }

  let statistical: RunSection["statistical_comparison"];
  if (meta.type === "preflight") statistical = { suitable: false, reason: "preflight only: no trials" };
  else if (meta.type === "smoke") statistical = { suitable: false, reason: "smoke test: a connectivity and pipeline check, not an effectiveness comparison" };
  else if (status !== "completed") statistical = { suitable: false, reason: `the effectiveness comparison did not complete (${status})` };
  else if (meta.planned_configs.length < 2) statistical = { suitable: false, reason: "fewer than two configurations" };
  else if (skipped.some(s => meta.planned_configs.includes(s.config))) statistical = { suitable: false, reason: `configurations without provider calls: ${skipped.filter(s => meta.planned_configs.includes(s.config)).map(s => s.config).join(", ")}` };
  else statistical = { suitable: true, reason: `${meta.repetitions} repetitions of ${meta.planned_tasks.length} tasks, paired across ${meta.planned_configs.join(", ")}; small samples still yield "inconclusive" verdicts` };

  const count = (o: string) => trials.filter(t => t.outcome === o).length;
  return {
    type: meta.type, status, status_detail: detail,
    git_commit: env.git_commit, git_dirty: env.git_dirty, benchmark_version: results.benchmark_version, fixtures_digest: env.fixtures_digest,
    fx_binary_sha256: env.fx_binary_sha256, fx_build_mode: env.fx_build_mode ?? null,
    provider: env.provider ?? null, preflight_state: results.preflight?.state ?? null,
    planned: {
      tasks: meta.planned_tasks, configurations: meta.planned_configs, repetitions: meta.repetitions, max_trials: meta.planned_trials,
      note: "A trial is one fx ask run and can make several model and safety-review requests.",
    },
    scheduled_trials: meta.scheduled_trials, completed_trials: trials.length,
    provider_invocations: invocations, skipped_configurations: skipped,
    connectivity_failures: { count: connectivityCount, by_category: byCategory, first: firstConnectivity ? `${firstConnectivity.task_id} ${firstConnectivity.config}: ${firstConnectivity.detail}` : null },
    oracle: { pass: count("pass"), partial: count("partial"), fail: count("fail"), unsupported: count("unsupported"), failure_categories: failures },
    tokens: { input_available_in: trials.filter(t => t.input_tokens.available).length, output_available_in: trials.filter(t => t.output_tokens.available).length, of: trials.length },
    cost: { available: trials.length > 0 && trials.every(t => t.cost.available), reason: "fx does not report provider cost; no estimate is made" },
    smoke, statistical_comparison: statistical,
  };
}

export interface Results {
  format: "fx.appport-effectiveness-results/1";
  benchmark_version: string;
  started_at: string;
  finished_at: string;
  environment: Record<string, unknown>;
  model_tier: { ran: boolean; skipped_reason: string | null };
  /** Run type, status, plan, invocation counts, and statistical suitability, derived from the trials. */
  run: RunSection;
  /** Provider readiness, checked before any model trial. Null in results written before preflights existed. */
  preflight: Preflight | null;
  trials: ModelTrial[];
  deterministic: DeterministicTrial[];
  solvers: SolverTrial[];
  extensions: { id: string; title: string; reason: string; source: string }[];
  tasks: { id: string; category: string; title: string; purpose: string; expected: unknown; focus: string[]; digest: string; deterministic_solver: boolean }[];
}

// ---------------------------------------------------------------------------------------------- statistics

export interface Distribution { n: number; min: number | null; p25: number | null; median: number | null; p75: number | null; max: number | null; mean: number | null; sd: number | null }

function quantile(sorted: number[], q: number): number {
  const pos = (sorted.length - 1) * q;
  const lo = Math.floor(pos), hi = Math.ceil(pos);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
}

export function distribution(values: number[]): Distribution {
  const v = values.filter(x => Number.isFinite(x)).sort((a, b) => a - b);
  if (v.length === 0) return { n: 0, min: null, p25: null, median: null, p75: null, max: null, mean: null, sd: null };
  const mean = v.reduce((a, b) => a + b, 0) / v.length;
  const sd = v.length > 1 ? Math.sqrt(v.reduce((a, b) => a + (b - mean) ** 2, 0) / (v.length - 1)) : 0;
  const r = (x: number) => Math.round(x * 100) / 100;
  return { n: v.length, min: r(v[0]), p25: r(quantile(v, 0.25)), median: r(quantile(v, 0.5)), p75: r(quantile(v, 0.75)), max: r(v.at(-1)!), mean: r(mean), sd: r(sd) };
}

function logChoose(n: number, k: number) {
  let s = 0;
  for (let i = 1; i <= k; i++) s += Math.log(n - k + i) - Math.log(i);
  return s;
}

/** Exact two-sided binomial test of `k` successes in `n` trials at p = 0.5 (sign test and exact McNemar). */
export function binomialTwoSided(k: number, n: number): number {
  if (n === 0) return 1;
  const lo = Math.min(k, n - k);
  let p = 0;
  for (let i = 0; i <= lo; i++) p += Math.exp(logChoose(n, i) - n * Math.LN2);
  return Math.min(1, 2 * p);
}

const ALPHA = 0.05;

// ---------------------------------------------------------------------------------------------- aggregation

type Metric = "latency_ms" | "model_calls" | "input_tokens" | "output_tokens" | "request_bytes_total" | "request_bytes_first" | "appport_context_bytes" | "model_ms" | "tool_ms" | "review_calls" | "tool_executions";

function metricValue(t: ModelTrial, m: Metric): number | null {
  const v = (t as any)[m];
  if (typeof v === "number") return v;
  return v?.available ? v.value : null;
}

function pairs(trials: ModelTrial[], a: ConfigId, b: ConfigId) {
  const key = (t: ModelTrial) => `${t.task_id}#${t.repetition}`;
  const byA = new Map(trials.filter(t => t.config === a).map(t => [key(t), t]));
  return trials.filter(t => t.config === b && byA.has(key(t))).map(t => ({ a: byA.get(key(t))!, b: t }));
}

export function summarize(results: Results) {
  const trials = results.trials;
  const configs = (Object.keys(CONFIGS) as ConfigId[]).filter(c => trials.some(t => t.config === c));
  const per = Object.fromEntries(configs.map(c => {
    const xs = trials.filter(t => t.config === c);
    const count = (o: string) => xs.filter(t => t.outcome === o).length;
    const failures: Record<string, number> = {};
    for (const t of xs) if (t.failure) failures[t.failure] = (failures[t.failure] ?? 0) + 1;
    const metrics = Object.fromEntries((["latency_ms", "model_ms", "tool_ms", "model_calls", "review_calls", "tool_executions", "input_tokens", "output_tokens", "request_bytes_total", "request_bytes_first", "appport_context_bytes"] as Metric[]).map(m => {
      const values = xs.map(t => metricValue(t, m)).filter((v): v is number => v !== null);
      return [m, { ...distribution(values), available_in: values.length, of: xs.length }];
    }));
    const passed = xs.filter(t => t.outcome === "pass");
    const costs = passed.map(t => t.cost.value).filter((v): v is number => v !== null);
    return [c, {
      name: CONFIGS[c].name, trials: xs.length,
      pass: count("pass"), partial: count("partial"), fail: count("fail"), unsupported: count("unsupported"),
      verified_completion_rate: xs.length ? Math.round((count("pass") / xs.length) * 1000) / 1000 : null,
      failure_categories: failures, metrics,
      cost_per_verified_success: costs.length === passed.length && passed.length > 0 ? costs.reduce((a, b) => a + b, 0) / passed.length : null,
      cost_note: costs.length === passed.length && passed.length > 0 ? "provider-reported" : "unavailable: fx does not report provider cost",
      clean_starts: xs.filter(t => t.clean_start).length,
    }];
  }));

  const comparisons = ([["B", "A"], ["C", "A"], ["C", "B"]] as [ConfigId, ConfigId][])
    .filter(([b, a]) => configs.includes(a) && configs.includes(b))
    .map(([b, a]) => {
      const ps = pairs(trials, a, b);
      const ok = (t: ModelTrial) => t.outcome === "pass";
      const onlyB = ps.filter(p => ok(p.b) && !ok(p.a)).length;
      const onlyA = ps.filter(p => ok(p.a) && !ok(p.b)).length;
      const paired = (m: Metric) => {
        const diffs = ps.map(p => [metricValue(p.a, m), metricValue(p.b, m)]).filter(([x, y]) => x !== null && y !== null) as [number, number][];
        const d = diffs.map(([x, y]) => y - x);
        const up = d.filter(x => x > 0).length, down = d.filter(x => x < 0).length;
        const medA = distribution(diffs.map(([x]) => x)).median, medB = distribution(diffs.map(([, y]) => y)).median;
        return {
          pairs: diffs.length, median_a: medA, median_b: medB,
          median_difference: distribution(d).median,
          relative_change_pct: medA && medB !== null ? Math.round(((medB - medA) / medA) * 1000) / 10 : null,
          increased: up, decreased: down, tied: d.length - up - down,
          sign_test_p: binomialTwoSided(up, up + down),
        };
      };
      const tasks = [...new Set(ps.map(p => p.a.task_id))].map(id => {
        const tp = ps.filter(p => p.a.task_id === id);
        const ra = tp.filter(p => ok(p.a)).length / tp.length, rb = tp.filter(p => ok(p.b)).length / tp.length;
        return { task: id, pairs: tp.length, rate_a: ra, rate_b: rb, effect: rb > ra ? "helped" : rb < ra ? "regressed" : "no difference" };
      });
      return {
        compare: `${b} vs ${a}`, a, b, pairs: ps.length,
        completion: { a: ps.filter(p => ok(p.a)).length, b: ps.filter(p => ok(p.b)).length, only_b: onlyB, only_a: onlyA, mcnemar_exact_p: binomialTwoSided(onlyB, onlyB + onlyA) },
        latency_ms: paired("latency_ms"), model_calls: paired("model_calls"),
        input_tokens: paired("input_tokens"), output_tokens: paired("output_tokens"),
        request_bytes_total: paired("request_bytes_total"), request_bytes_first: paired("request_bytes_first"),
        tasks,
      };
    });

  const interpretation = comparisons.map(c => {
    const verdict = (s: { pairs: number; increased: number; decreased: number; sign_test_p: number }, good: "increase" | "decrease") => {
      if (s.pairs === 0) return "unavailable: no paired measurements";
      const dir = s.increased > s.decreased ? "increase" : s.decreased > s.increased ? "decrease" : "none";
      if (s.sign_test_p >= ALPHA || dir === "none") return `inconclusive (${s.pairs} pairs, sign test p=${s.sign_test_p.toFixed(3)})`;
      return `${dir === good ? "yes" : "no, it went the other way"}: ${dir} in ${dir === "increase" ? s.increased : s.decreased} of ${s.pairs} pairs (sign test p=${s.sign_test_p.toFixed(3)})`;
    };
    const comp = c.completion;
    const disc = comp.only_a + comp.only_b;
    const completion = c.pairs === 0 ? "unavailable"
      : comp.mcnemar_exact_p < ALPHA ? (comp.only_b > comp.only_a ? `yes: ${comp.only_b} pairs passed only with ${c.b}, ${comp.only_a} only with ${c.a} (exact McNemar p=${comp.mcnemar_exact_p.toFixed(3)})` : `no, a regression: ${comp.only_a} pairs passed only with ${c.a}, ${comp.only_b} only with ${c.b} (exact McNemar p=${comp.mcnemar_exact_p.toFixed(3)})`)
      : `inconclusive (${disc} discordant of ${c.pairs} pairs, exact McNemar p=${comp.mcnemar_exact_p.toFixed(3)})`;
    const regressions = c.tasks.filter(t => t.effect === "regressed").map(t => t.task);
    return {
      compare: c.compare,
      improved_verified_completion: completion,
      reduced_inference: verdict(c.model_calls, "decrease"),
      reduced_latency: verdict(c.latency_ms, "decrease"),
      increased_context: verdict(c.request_bytes_total, "increase"),
      regressions: regressions.length ? `observed on ${regressions.join(", ")} (task-level, not significance-tested)` : "none observed",
      causality: "Configurations differ only in FX_APPPORT_MANIFEST and FX_APPPORT_FOCUS, with counterbalanced order; differences can still reflect provider variance, so read effects together with their p-values and sample sizes.",
    };
  });

  const det = results.deterministic;
  const detTasks = [...new Set(det.map(d => d.task_id))].map(id => {
    const xs = det.filter(d => d.task_id === id);
    return { task: id, title: xs[0].title, covers: xs[0].covers, runs: xs.length, passed: xs.filter(x => x.outcome === "pass").length, latency_ms: distribution(xs.map(x => x.latency_ms)), model_calls: 0, failures: [...new Set(xs.map(x => x.failure).filter(Boolean))] };
  });
  const solverTasks = [...new Set(results.solvers.map(s => s.task_id))].map(id => {
    const xs = results.solvers.filter(s => s.task_id === id);
    return { task: id, runs: xs.length, passed: xs.filter(x => x.outcome === "pass").length, latency_ms: distribution(xs.map(x => x.latency_ms)), commands: xs[0].commands, model_calls: 0 };
  });
  const modelTaskIds = results.tasks.filter(t => t.category !== "deterministic").map(t => t.id);
  const suitable = results.run?.statistical_comparison.suitable ?? true;
  return {
    run: results.run ? { type: results.run.type, status: results.run.status, status_detail: results.run.status_detail, git_commit: results.run.git_commit, git_dirty: results.run.git_dirty, statistical_comparison: results.run.statistical_comparison, smoke: results.run.smoke ?? null } : null,
    configurations: per,
    // Significance tests appear only for a completed comparison run.
    comparisons: suitable ? comparisons : [],
    interpretation: suitable ? interpretation : [],
    deterministic: {
      tasks: detTasks, runs: det.length, passed: det.filter(d => d.outcome === "pass").length, latency_ms: distribution(det.map(d => d.latency_ms)),
      inference_calls: 0,
    },
    deterministic_solvers: {
      tasks: solverTasks,
      solvable_without_model: solverTasks.filter(s => s.passed === s.runs).map(s => s.task),
      model_tasks: modelTaskIds.length,
    },
  };
}

// ---------------------------------------------------------------------------------------------- markdown

const fmt = (v: number | null | undefined, unit = "") => (v === null || v === undefined ? "n/a" : `${v}${unit}`);
const pct = (v: number | null) => (v === null ? "n/a" : `${v > 0 ? "+" : ""}${v}%`);

export function renderMarkdown(results: Results, summary: ReturnType<typeof summarize>): string {
  const out: string[] = [];
  const env = results.environment as any;
  const run = results.run;
  out.push(`# AppPort effectiveness benchmark`, "");
  if (run) {
    const title: Record<RunType, string> = { preflight: "Preflight", smoke: "Smoke test", comparison: "Comparison" };
    out.push(`**Run type:** ${title[run.type]} · **Status:** \`${run.status}\` · **Commit:** \`${run.git_commit}\`${run.git_dirty ? " (uncommitted changes)" : ""}`, "");
    out.push(`${run.status_detail.replace(/\.+$/, "")}.`, "");
    out.push(`**Statistical comparison:** ${run.statistical_comparison.suitable ? "suitable" : "not suitable"}: ${run.statistical_comparison.reason}.`, "");
    if (run.smoke) out.push(`**Smoke verdict:** ${run.smoke.verdict}: ${run.smoke.detail}. A smoke test checks connectivity and the pipeline; it is not evidence that AppPort context helps or hurts.`, "");
    if (run.type !== "preflight" && run.completed_trials === 0) out.push("**The effectiveness comparison did not run.** Deterministic results below do not answer whether AppPort context improves model-driven work.", "");
  }
  out.push(`- Benchmark: \`${results.benchmark_version}\``);
  out.push(`- Run: ${results.started_at} to ${results.finished_at}`);
  out.push(`- fx: ${env.fx_version} (commit ${env.git_commit}${env.git_dirty ? ", uncommitted changes" : ""}; binary sha256 ${String(env.fx_binary_sha256).slice(0, 16)}…, ${env.fx_binary_bytes} bytes)`);
  out.push(`- Fixtures: ${env.fixtures_digest ? `sha256 ${env.fixtures_digest}` : "n/a"} (see fixtures/PROVENANCE.json)`);
  out.push(`- Provider: ${results.model_tier.ran ? `${env.provider?.model ?? "unknown model"} via ${env.provider?.provider_endpoint ?? env.provider?.auth ?? "unknown"} (${env.provider_kind})` : "none"}`);
  out.push(`- Limits: ${env.limits ? `${env.limits.permission}, ${env.limits.max_agent_steps} agent steps, ${env.limits.timeout_ms} ms timeout` : "n/a"}; repetitions: ${env.repetitions ?? "n/a"}; seed: ${env.seed ?? "n/a"}`);
  out.push(`- Build mode: ${env.fx_build_mode ?? "unknown"}${env.fx_build_mode && env.fx_build_mode !== "ReleaseSafe" ? " (use a ReleaseSafe build for latency comparisons)" : ""}`);
  out.push("");
  if (results.preflight) {
    const p = results.preflight;
    out.push("## Provider readiness", "");
    out.push(`State: \`${p.state}\`. ${p.note}`, "");
    out.push(`- Provider: ${p.provider.endpoint ?? (p.provider.auth && p.provider.auth !== "missing" ? "Vercel AI Gateway" : "none")}; auth \`${p.provider.auth ?? "unknown"}\`; model \`${p.provider.model ?? "unknown"}\` (${p.provider.model_origin ?? "origin unknown"})${p.provider.requested_model ? `, requested \`${p.provider.requested_model}\`` : ""}`);
    out.push(`- Model check: ${p.model_check.status}: ${p.model_check.detail}`);
    out.push(`- Endpoint check: ${p.endpoint_check.status} (${p.endpoint_check.method}): ${p.endpoint_check.detail}`);
    out.push(`- Deterministic tier: ${p.deterministic_ready ? "can run" : "cannot run"}`);
    for (const c of p.checks.filter(c => c.status === "fail" || c.status === "warn")) out.push(`- ${c.status} ${c.name}: ${c.detail}`);
    out.push("");
  }
  if (run && run.type !== "preflight") {
    out.push("## Run accounting", "");
    out.push(`Planned: ${run.planned.tasks.length} tasks (${run.planned.tasks.join(", ") || "none"}) x ${run.planned.configurations.length} configurations x ${run.planned.repetitions} repetitions = at most ${run.planned.max_trials} trials. Scheduled ${run.scheduled_trials}; completed ${run.completed_trials}. ${run.planned.note}`, "");
    if (Object.keys(run.provider_invocations).length) {
      out.push("| Configuration | Trials | Trials that called the provider | Model calls | Review calls |");
      out.push("|---|---|---|---|---|");
      for (const [c, v] of Object.entries(run.provider_invocations)) out.push(`| ${c} | ${v.trials} | ${v.trials_with_provider_calls} | ${v.model_calls} | ${v.review_calls} |`);
      out.push("");
    }
    if (run.skipped_configurations.length) out.push(`Skipped configurations: ${run.skipped_configurations.map(s => `${s.config} (${s.reason})`).join("; ")}.`, "");
    out.push(`Provider and harness failures: ${run.connectivity_failures.count}${run.connectivity_failures.count ? ` (${Object.entries(run.connectivity_failures.by_category).map(([k, v]) => `${k} ${v}`).join(", ")}; first: ${run.connectivity_failures.first})` : ""}.`, "");
    out.push(`Token counts reported for ${run.tokens.input_available_in} of ${run.tokens.of} trials. Cost: ${run.cost.available ? "provider-reported" : `unavailable; ${run.cost.reason}`}.`, "");
  }

  out.push("## Model-driven tasks", "");
  if (!results.model_tier.ran) {
    out.push(`**Not run:** ${results.model_tier.skipped_reason}`, "", "No effectiveness or efficiency conclusion can be drawn from this run.", "");
  } else {
    if (run?.type === "smoke") out.push("> **Smoke test.** One repetition of three tasks per configuration. Outcomes and metrics are descriptive; no significance test applies.", "");
    if ((results.environment as any).provider_kind === "scripted") {
      out.push("> **Harness self-test.** These trials used a scripted provider. They validate the harness and oracles and say nothing about any model.", "");
    }
    out.push("### Effectiveness", "");
    out.push("| Configuration | Trials | Pass | Partial | Fail | Unsupported | Verified completion | Clean starts | Failure categories |");
    out.push("|---|---|---|---|---|---|---|---|---|");
    for (const [c, s] of Object.entries(summary.configurations) as [string, any][]) {
      out.push(`| ${c} ${s.name} | ${s.trials} | ${s.pass} | ${s.partial} | ${s.fail} | ${s.unsupported} | ${fmt(s.verified_completion_rate)} | ${s.clean_starts}/${s.trials} | ${Object.entries(s.failure_categories).map(([k, v]) => `${k} ${v}`).join(", ") || "none"} |`);
    }
    out.push("", "Task-level verified completion rate per configuration:", "");
    const configs = Object.keys(summary.configurations);
    out.push(`| Task | ${configs.join(" | ")} |`);
    out.push(`|---|${configs.map(() => "---").join("|")}|`);
    for (const id of [...new Set(results.trials.map(t => t.task_id))].sort()) {
      const cells = configs.map(c => {
        const xs = results.trials.filter(t => t.task_id === id && t.config === c);
        return xs.length ? `${xs.filter(t => t.outcome === "pass").length}/${xs.length}${xs.some(t => t.outcome === "partial") ? ` (+${xs.filter(t => t.outcome === "partial").length} partial)` : ""}` : "n/a";
      });
      out.push(`| ${id} | ${cells.join(" | ")} |`);
    }
    out.push("");
    for (const c of summary.comparisons) {
      const changed = c.tasks.filter(t => t.effect !== "no difference").sort((x, y) => x.task.localeCompare(y.task));
      out.push(`Per-task effect, ${c.compare}: ${changed.length ? changed.map(t => `${t.task} ${t.effect} (${t.rate_a.toFixed(2)} → ${t.rate_b.toFixed(2)})`).join("; ") : `no difference on any of ${c.tasks.length} tasks`}.`, "");
    }

    out.push("### Efficiency", "");
    out.push("Medians with [p25, p75] and n. Request bytes are UTF-8 bytes of the provider requests fx serialized; context bytes are the AppPort text a configuration adds.", "");
    out.push("| Configuration | Latency ms | Model ms | Tool ms | Model calls | Review calls | Input tokens | Output tokens | Request bytes (all) | Request bytes (first) | AppPort context bytes | Cost per verified success |");
    out.push("|---|---|---|---|---|---|---|---|---|---|---|---|");
    const cell = (d: any) => d.n === 0 ? `unavailable (0/${d.of})` : `${d.median} [${d.p25}, ${d.p75}] n=${d.n}${d.available_in < d.of ? ` (${d.of - d.available_in} unavailable)` : ""}`;
    for (const [c, s] of Object.entries(summary.configurations) as [string, any][]) {
      const m = s.metrics;
      out.push(`| ${c} | ${cell(m.latency_ms)} | ${cell(m.model_ms)} | ${cell(m.tool_ms)} | ${cell(m.model_calls)} | ${cell(m.review_calls)} | ${cell(m.input_tokens)} | ${cell(m.output_tokens)} | ${cell(m.request_bytes_total)} | ${cell(m.request_bytes_first)} | ${cell(m.appport_context_bytes)} | ${s.cost_per_verified_success ?? s.cost_note} |`);
    }
    if (!summary.comparisons.length) {
      out.push("", "### Paired comparisons", "", `Not computed: ${run?.statistical_comparison.reason ?? "no paired trials"}.`, "");
    } else {
    out.push("", "### Paired comparisons", "");
    out.push("| Comparison | Pairs | Completion (A / B, only-B, only-A, p) | Latency median diff (rel.) | Model calls median diff | Input tokens median diff | Request bytes median diff (rel.) |");
    out.push("|---|---|---|---|---|---|---|");
    for (const c of summary.comparisons) {
      const p = (x: any) => x.pairs === 0 ? "unavailable" : `${fmt(x.median_difference)} (${pct(x.relative_change_pct)}), +${x.increased}/-${x.decreased}/=${x.tied}, p=${x.sign_test_p.toFixed(3)}`;
      out.push(`| ${c.compare} | ${c.pairs} | ${c.completion.a} / ${c.completion.b}, ${c.completion.only_b}, ${c.completion.only_a}, p=${c.completion.mcnemar_exact_p.toFixed(3)} | ${p(c.latency_ms)} | ${p(c.model_calls)} | ${p(c.input_tokens)} | ${p(c.request_bytes_total)} |`);
    }
    out.push("", "### Interpretation", "");
    for (const i of summary.interpretation) {
      out.push(`**${i.compare}**`, "");
      out.push(`- Improved verified completion: ${i.improved_verified_completion}`);
      out.push(`- Reduced inference work (model calls): ${i.reduced_inference}`);
      out.push(`- Reduced latency: ${i.reduced_latency}`);
      out.push(`- Increased context overhead (request bytes): ${i.increased_context}`);
      out.push(`- Regressions: ${i.regressions}`, "");
    }
    out.push(summary.interpretation[0]?.causality ?? "", "");
    out.push("Fewer model calls do not imply lower latency, and a larger prompt can raise success and token use at once; each row above is reported on its own.", "");
    }
  }

  out.push("## Deterministic operations", "");
  out.push(`${summary.deterministic.passed}/${summary.deterministic.runs} runs matched their golden results. Every run had no provider available, so model calls are 0 by construction.`, "");
  out.push("| Task | Covers | Runs | Passed | Latency ms median [min, max] | Failures |");
  out.push("|---|---|---|---|---|---|");
  for (const t of summary.deterministic.tasks) out.push(`| ${t.task} ${t.title} | ${t.covers} | ${t.runs} | ${t.passed} | ${t.latency_ms.median} [${t.latency_ms.min}, ${t.latency_ms.max}] | ${t.failures.join(", ") || "none"} |`);
  out.push("", "### Model tasks answered without a model", "");
  out.push(`${summary.deterministic_solvers.solvable_without_model.length} of ${summary.deterministic_solvers.model_tasks} model tasks were answered correctly by \`fx appport\` alone, graded by the same oracle as model answers: ${summary.deterministic_solvers.solvable_without_model.join(", ") || "none"}. The others need inference or file changes.`, "");
  out.push("| Task | Runs | Passed | Latency ms median [min, max] | Commands |");
  out.push("|---|---|---|---|---|");
  for (const s of summary.deterministic_solvers.tasks) out.push(`| ${s.task} | ${s.runs} | ${s.passed} | ${s.latency_ms.median} [${s.latency_ms.min}, ${s.latency_ms.max}] | \`${s.commands.join("; ").replace(/\/[^ ]*\/(contracts\/)/g, "$1")}\` |`);
  out.push("");

  out.push("## Not run", "");
  for (const e of results.extensions) out.push(`- **${e.title}**: ${e.reason} Source: ${e.source}`);
  out.push("- **Provider cost**: fx does not report cost, so cost per verified success is unavailable rather than estimated.");
  out.push("");
  return out.join("\n");
}
