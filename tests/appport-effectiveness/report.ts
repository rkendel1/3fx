// Aggregates trial records into the benchmark report. The JSON summary and the
// Markdown report are both built from the same records by this file.
//
// Deterministic operations and model-driven tasks are reported separately and
// never combined into one score. Every interpretation is derived from the
// paired data with exact tests; with too few pairs the answer is
// "inconclusive", never an improvement.

import type { ConfigId, DeterministicTrial, ModelTrial, SolverTrial } from "./harness";
import { CONFIGS } from "./harness";

export interface Results {
  format: "fx.appport-effectiveness-results/1";
  benchmark_version: string;
  started_at: string;
  finished_at: string;
  environment: Record<string, unknown>;
  model_tier: { ran: boolean; skipped_reason: string | null };
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
  return {
    configurations: per, comparisons, interpretation,
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
  out.push(`# AppPort effectiveness benchmark`, "");
  out.push(`- Benchmark: \`${results.benchmark_version}\``);
  out.push(`- Run: ${results.started_at} to ${results.finished_at}`);
  out.push(`- fx: ${env.fx_version} (commit ${env.git_commit}${env.git_dirty ? ", uncommitted changes" : ""}; binary sha256 ${String(env.fx_binary_sha256).slice(0, 16)}…, ${env.fx_binary_bytes} bytes)`);
  out.push(`- Fixtures: ${env.fixtures_digest ? `sha256 ${env.fixtures_digest}` : "n/a"} (see fixtures/PROVENANCE.json)`);
  out.push(`- Provider: ${results.model_tier.ran ? `${env.provider?.model ?? "unknown model"} via ${env.provider?.provider_endpoint ?? env.provider?.auth ?? "unknown"} (${env.provider_kind})` : "none"}`);
  out.push(`- Limits: ${env.limits ? `${env.limits.permission}, ${env.limits.max_agent_steps} agent steps, ${env.limits.timeout_ms} ms timeout` : "n/a"}; repetitions: ${env.repetitions ?? "n/a"}; seed: ${env.seed ?? "n/a"}`);
  out.push("");

  out.push("## Model-driven tasks", "");
  if (!results.model_tier.ran) {
    out.push(`**Skipped:** ${results.model_tier.skipped_reason}`, "", "No effectiveness or efficiency conclusion can be drawn from this run.", "");
  } else {
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
