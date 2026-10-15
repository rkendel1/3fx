// Runs the AppPort effectiveness benchmark and writes trials.json, summary.json, and report.md.
//
//   zig build
//   cd tests/appport-effectiveness && bun install && bun run.ts [options]
//
// Options:
//   --repetitions N     model-tier repetitions per task and configuration (default 3)
//   --det-repetitions N deterministic-tier repetitions (default 5)
//   --tasks D1,I2       limit the model tier to these tasks
//   --configs A,B,C     limit the configurations (default all three)
//   --model ID          pass FX_MODEL to every trial (the same value for every configuration)
//   --permission FLAG   fx permission flag for every trial: --auto (default) or --full-access
//   --max-steps N       FX_MAX_AGENT_STEPS for every trial (default 40)
//   --timeout-ms N      per-trial timeout (default 300000)
//   --seed N            order randomization seed (default 1)
//   --no-model          skip the model tier even when a provider is configured
//   --out DIR           output directory (default results/<timestamp>)
//   --keep-workspaces   keep trial workspaces for inspection
//
// The model tier uses whatever provider fx itself resolves from the profile and
// environment. It is skipped, with the reason recorded, when fx reports none.

import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { FX_BIN } from "../evals/eval-helpers";
import { join } from "node:path";
import {
  CONFIGS, DEFAULT_LIMITS, type ConfigId, type DeterministicTrial, type Limits, type ModelTrial, type Provider, type SolverTrial,
  assertBuiltBinary, detectProvider, fxVersion, runDeterministicTrial, runModelTrial, runSolverTrial,
} from "./harness";
import { renderMarkdown, summarize, type Results } from "./report";
import { BENCHMARK_VERSION, deterministicTasks, extensions, fixtureDir, here, modelTasks, repoRoot, sha256, taskDigest } from "./tasks";

export interface RunOptions {
  repetitions: number;
  detRepetitions: number;
  tasks?: string[];
  configs: ConfigId[];
  limits: Limits;
  seed: number;
  model?: string;
  noModel?: boolean;
  keepWorkspaces?: boolean;
  /** Overrides provider detection; used by the harness self-tests. */
  provider?: Provider;
  log?: (line: string) => void;
}

/** Deterministic pseudo-random generator, so trial order is reproducible from the seed. */
export function rng(seed: number) {
  let s = seed >>> 0 || 1;
  return () => ((s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 2 ** 32);
}

/**
 * The trial plan: for each repetition, tasks in a seeded random order, and for
 * each task the configurations in a rotated order (a Latin square across
 * repetitions and tasks), so no configuration always runs first.
 */
export function plan(taskIds: string[], configs: ConfigId[], repetitions: number, seed: number) {
  const next = rng(seed);
  const out: { task: string; config: ConfigId; repetition: number; order_in_block: number }[] = [];
  for (let r = 0; r < repetitions; r++) {
    const order = [...taskIds];
    for (let i = order.length - 1; i > 0; i--) { const j = Math.floor(next() * (i + 1)); [order[i], order[j]] = [order[j], order[i]]; }
    order.forEach((task, k) => {
      const shift = (r + k) % configs.length;
      const rotated = [...configs.slice(shift), ...configs.slice(0, shift)];
      rotated.forEach((config, i) => out.push({ task, config, repetition: r, order_in_block: i }));
    });
  }
  return out;
}

function fixturesDigest(): string {
  const files: string[] = [];
  const walk = (dir: string) => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      const p = join(dir, e.name);
      if (e.isDirectory()) walk(p); else files.push(p);
    }
  };
  walk(fixtureDir);
  return sha256(files.sort().map(f => `${f.slice(fixtureDir.length)}\n${sha256(readFileSync(f))}`).join("\n"));
}

function git(args: string[]): string {
  try { return execFileSync("git", ["-C", repoRoot, ...args], { encoding: "utf8" }).trim(); } catch { return "unknown"; }
}

export async function runBenchmark(opts: RunOptions): Promise<Results> {
  const log = opts.log ?? (() => {});
  assertBuiltBinary();
  const startedAt = new Date().toISOString();
  const selected = modelTasks.filter(t => !opts.tasks || opts.tasks.includes(t.id));

  // Deterministic tier: always runs, never needs a provider.
  const deterministic: DeterministicTrial[] = [];
  const solvers: SolverTrial[] = [];
  for (let r = 0; r < opts.detRepetitions; r++) {
    for (const t of deterministicTasks) deterministic.push(runDeterministicTrial(t, r));
    for (const t of modelTasks) { const s = runSolverTrial(t, r); if (s) solvers.push(s); }
  }
  log(`deterministic: ${deterministic.filter(d => d.outcome === "pass").length}/${deterministic.length} passed; solvers ${solvers.filter(s => s.outcome === "pass").length}/${solvers.length}`);

  // Model tier.
  let provider = opts.provider;
  let skipped: string | null = null;
  if (opts.noModel) skipped = "the model tier was disabled with --no-model";
  else if (!provider) {
    const env = { FX_MODEL: opts.model };
    const probe = await detectProvider(env);
    if (probe.available) provider = { kind: "configured", env, identity: probe.identity };
    else skipped = probe.reason;
  }
  const trials: ModelTrial[] = [];
  if (provider && !skipped) {
    const steps = plan(selected.map(t => t.id), opts.configs, opts.repetitions, opts.seed);
    let sequence = 0;
    for (const step of steps) {
      const task = selected.find(t => t.id === step.task)!;
      const trial = await runModelTrial(task, step.config, provider, opts.limits, {
        repetition: step.repetition, sequence, order_in_block: step.order_in_block, cold: sequence === 0, keep_workspace: opts.keepWorkspaces,
      });
      trials.push(trial);
      log(`[${sequence + 1}/${steps.length}] ${task.id} ${step.config} rep ${step.repetition}: ${trial.outcome}${trial.failure ? ` (${trial.failure})` : ""} ${trial.latency_ms} ms`);
      sequence++;
    }
  } else log(`model tier skipped: ${skipped}`);

  return {
    format: "fx.appport-effectiveness-results/1",
    benchmark_version: BENCHMARK_VERSION,
    started_at: startedAt,
    finished_at: new Date().toISOString(),
    environment: {
      fx_version: fxVersion(), fx_binary_sha256: sha256(readFileSync(FX_BIN)), fx_binary_bytes: statSync(FX_BIN).size,
      git_commit: git(["rev-parse", "HEAD"]), git_dirty: git(["status", "--porcelain"]) !== "",
      platform: `${process.platform}-${process.arch}`, bun: Bun.version,
      fixtures_digest: fixturesDigest(),
      provider_kind: provider?.kind ?? null, provider: provider?.identity ?? null,
      configurations: Object.fromEntries(opts.configs.map(c => [c, CONFIGS[c]])),
      limits: opts.limits, repetitions: opts.repetitions, det_repetitions: opts.detRepetitions, seed: opts.seed,
      timing: "latency_ms is spawn to exit of fx ask, measured by the harness. model_ms and tool_ms come from fx trace timestamps. Tracing is enabled identically in every configuration. harness_ms covers workspace setup, context measurement, and grading outside the fx process.",
      context_units: "request_bytes are UTF-8 bytes of serialized provider requests as fx reports them; appport_context_bytes are UTF-8 bytes of the AppPort context text.",
    },
    model_tier: { ran: trials.length > 0, skipped_reason: skipped },
    trials, deterministic, solvers,
    extensions,
    tasks: modelTasks.map(t => ({ id: t.id, category: t.category, title: t.title, purpose: t.purpose, expected: t.expected, focus: t.focus, digest: taskDigest(t), deterministic_solver: Boolean(t.deterministic) })),
  };
}

export function writeResults(results: Results, dir: string) {
  mkdirSync(dir, { recursive: true });
  const summary = summarize(results);
  writeFileSync(join(dir, "trials.json"), JSON.stringify(results, null, 1) + "\n");
  writeFileSync(join(dir, "summary.json"), JSON.stringify(summary, null, 1) + "\n");
  writeFileSync(join(dir, "report.md"), renderMarkdown(results, summary));
  return summary;
}

if (import.meta.main) {
  const argv = process.argv.slice(2);
  const opt = (name: string) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
  const num = (name: string, fallback: number) => { const v = opt(name); return v === undefined ? fallback : Number(v); };
  const permission = opt("--permission") ?? DEFAULT_LIMITS.permission;
  if (!["--auto", "--full-access"].includes(permission)) throw new Error("--permission must be --auto or --full-access");
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const out = opt("--out") ?? join(here, "results", stamp);
  const results = await runBenchmark({
    repetitions: num("--repetitions", 3),
    detRepetitions: num("--det-repetitions", 5),
    tasks: opt("--tasks")?.split(","),
    configs: (opt("--configs")?.split(",") ?? ["A", "B", "C"]) as ConfigId[],
    limits: { permission, max_agent_steps: num("--max-steps", DEFAULT_LIMITS.max_agent_steps), timeout_ms: num("--timeout-ms", DEFAULT_LIMITS.timeout_ms) },
    seed: num("--seed", 1),
    model: opt("--model"),
    noModel: argv.includes("--no-model"),
    keepWorkspaces: argv.includes("--keep-workspaces"),
    log: line => console.error(line),
  });
  writeResults(results, out);
  console.log(`wrote ${join(out, "trials.json")}, summary.json, and report.md`);
  if (!results.model_tier.ran) console.log(`model tier skipped: ${results.model_tier.skipped_reason}`);
  // A deterministic mismatch means fx or a golden is wrong, not a performance result.
  const broken = [...results.deterministic, ...results.solvers].filter(t => t.outcome !== "pass");
  if (broken.length) {
    console.error(`deterministic results that did not match: ${broken.map(t => `${t.task_id} (${t.detail})`).join("; ")}`);
    process.exit(1);
  }
}
