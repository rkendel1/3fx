// Runs the AppPort effectiveness benchmark and writes trials.json, summary.json, and report.md.
//
//   zig build -Doptimize=ReleaseSafe
//   cd tests/appport-effectiveness && bun install
//   bun run.ts --preflight            # readiness only; no model requests
//   bun run.ts --smoke                # 3 tasks x 3 configurations x 1 repetition
//   bun run.ts --repetitions 5        # the paired comparison (the default profile)
//
// Options:
//   --preflight         check provider readiness and stop; makes no model requests
//   --smoke             run the fixed smoke subset (D1, D6, D7) once in every configuration
//   --repetitions N     comparison repetitions per task and configuration (default 3)
//   --det-repetitions N deterministic-tier repetitions (default 5)
//   --tasks D1,I2       limit the comparison to these tasks
//   --configs A,B,C     limit the comparison configurations (default all three)
//   --model ID          pass FX_MODEL to every trial (the same value for every configuration)
//   --permission FLAG   fx permission flag for every trial: --auto (default) or --full-access
//   --max-steps N       FX_MAX_AGENT_STEPS for every trial (default 40)
//   --timeout-ms N      per-trial timeout (default 300000)
//   --seed N            order randomization seed (default 1)
//   --no-model          skip the model tier even when a provider is ready
//   --require-model     exit 2 when the model tier does not run or every trial fails to reach the provider
//   --out DIR           output directory (default results/<timestamp>)
//   --keep-workspaces   keep trial workspaces for inspection
//
// The model tier uses whatever provider fx itself resolves from the profile and
// environment. It runs only when the preflight reports "ready"; otherwise the
// run is recorded as blocked, with the reason.

import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  CONFIGS, DEFAULT_LIMITS, type ConfigId, type DeterministicTrial, type Limits, type ModelTrial, type Provider, type SolverTrial,
  assertBuiltBinary, fxVersion, runDeterministicTrial, runModelTrial, runSolverTrial,
} from "./harness";
import { renderPreflight, runPreflight, scrubSecrets, type Preflight } from "./preflight";
import { renderMarkdown, runSection, summarize, type Results, type RunType } from "./report";
import { BENCHMARK_VERSION, deterministicTasks, extensions, fixtureDir, here, modelTasks, repoRoot, sha256, taskDigest } from "./tasks";

/** The smoke subset: capability discovery and both negative cases. Existing tasks and oracles, unchanged. */
export const SMOKE_TASKS = ["D1", "D6", "D7"];
const ALL_CONFIGS: ConfigId[] = ["A", "B", "C"];

export interface RunOptions {
  /** Defaults to "comparison", the original benchmark. */
  runType?: RunType;
  repetitions: number;
  detRepetitions: number;
  tasks?: string[];
  configs: ConfigId[];
  limits: Limits;
  seed: number;
  model?: string;
  noModel?: boolean;
  keepWorkspaces?: boolean;
  /** Overrides provider detection; used by the harness self-tests. The preflight still runs against its environment. */
  provider?: Provider;
  log?: (line: string) => void;
  /** Called with the results so far after each model trial, so an interrupted run leaves artifacts. */
  checkpoint?: (partial: Results) => void;
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

/** What a run will execute, resolved from the options before anything starts. */
export function resolvePlan(opts: RunOptions) {
  const runType = opts.runType ?? "comparison";
  if (runType === "preflight") return { runType, tasks: [] as string[], configs: [] as ConfigId[], repetitions: 0 };
  if (runType === "smoke") return { runType, tasks: [...SMOKE_TASKS], configs: [...ALL_CONFIGS], repetitions: 1 };
  const tasks = modelTasks.filter(t => !opts.tasks || opts.tasks.includes(t.id)).map(t => t.id);
  return { runType, tasks, configs: opts.configs, repetitions: opts.repetitions };
}

export function describePlan(p: ReturnType<typeof resolvePlan>, limits: Limits): string {
  if (p.runType === "preflight") return "plan: preflight only; no model requests";
  const max = p.tasks.length * p.configs.length * p.repetitions;
  return [
    `plan: ${p.runType}; ${p.tasks.length} tasks (${p.tasks.join(", ")}) x ${p.configs.length} configurations (${p.configs.join(", ")}) x ${p.repetitions} repetitions = at most ${max} model trials`,
    `  each trial is one fx ask run; it can make up to ${limits.max_agent_steps} agent model requests plus safety-review requests, so trials are not provider requests`,
    "  cost: not estimated. fx does not report provider pricing; the report shows provider-reported tokens where available",
  ].join("\n");
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

/** A trial the harness could not complete. It stays in the results and the denominators. */
function harnessFailure(task: string, config: ConfigId, provider: Provider, limits: Limits, step: { repetition: number; order_in_block: number }, sequence: number, error: unknown, env: Record<string, string | undefined>): ModelTrial {
  const now = new Date().toISOString();
  const unavailable = (source: string) => ({ value: null, available: false, source });
  const t = modelTasks.find(x => x.id === task)!;
  return {
    benchmark_version: BENCHMARK_VERSION, kind: "model", task_id: task, task_category: t.category, task_digest: taskDigest(t),
    config, config_name: CONFIGS[config].name, config_env: { FX_APPPORT_MANIFEST: null, FX_APPPORT_FOCUS: null },
    provider_kind: provider.kind, provider: provider.identity, limits, repetition: step.repetition, sequence, order_in_block: step.order_in_block, cold: sequence === 0,
    started_at: now, ended_at: now, workspace_digest_expected: "", workspace_digest_before: "", clean_start: false,
    fx_exit: null, fx_timed_out: false, fx_stderr_tail: "", latency_ms: 0,
    model_ms: unavailable("trial did not run"), tool_ms: unavailable("trial did not run"), harness_ms: 0, oracle_ms: 0,
    model_calls: unavailable("trial did not run"), review_calls: unavailable("trial did not run"), tool_calls: unavailable("trial did not run"),
    tool_executions: unavailable("trial did not run"), input_tokens: unavailable("trial did not run"), output_tokens: unavailable("trial did not run"),
    cost: unavailable("fx does not report provider cost"), request_bytes_total: unavailable("trial did not run"), request_bytes_first: unavailable("trial did not run"),
    appport_context_bytes: 0, inference_required: true, answer_tail: "",
    outcome: "fail", failure: "harness-error", detail: scrubSecrets(String((error as Error)?.message ?? error), env), observed: null, independently_verified: false,
  };
}

export async function runBenchmark(opts: RunOptions): Promise<Results> {
  const log = opts.log ?? (() => {});
  assertBuiltBinary();
  const startedAt = new Date().toISOString();
  const p = resolvePlan(opts);
  log(describePlan(p, opts.limits));

  // Deterministic tier: always runs, never needs a provider. A preflight only checks that it can run.
  const deterministic: DeterministicTrial[] = [];
  const solvers: SolverTrial[] = [];
  if (p.runType !== "preflight") {
    for (let r = 0; r < opts.detRepetitions; r++) {
      for (const t of deterministicTasks) deterministic.push(runDeterministicTrial(t, r));
      for (const t of modelTasks) { const s = runSolverTrial(t, r); if (s) solvers.push(s); }
    }
    log(`deterministic: ${deterministic.filter(d => d.outcome === "pass").length}/${deterministic.length} passed; solvers ${solvers.filter(s => s.outcome === "pass").length}/${solvers.length}`);
  }

  // Readiness. The preflight uses the same environment as the trials.
  const env = opts.provider?.env ?? { FX_MODEL: opts.model };
  const preflight: Preflight = await runPreflight({ env, model: opts.model });
  log(renderPreflight(preflight));

  let provider = opts.provider;
  let skipped: string | null = null;
  if (p.runType === "preflight") skipped = "preflight only: no model trials were requested";
  else if (opts.noModel) skipped = "the model tier was disabled with --no-model";
  else if (!preflight.model_ready) {
    const failing = preflight.checks.filter(c => c.status === "fail").map(c => `${c.name}: ${c.detail}`).join("; ");
    skipped = `provider not ready (${preflight.state})${failing ? `: ${failing}` : ""}`;
  } else if (!provider) {
    provider = {
      kind: "configured", env,
      identity: {
        model: preflight.provider.model, model_source: preflight.provider.model_source, provider_endpoint: preflight.provider.endpoint,
        auth: preflight.provider.auth, build_revision: preflight.fx.build_revision,
      },
    };
  }

  const environment = {
    fx_version: fxVersion(), fx_binary_sha256: sha256(readFileSync(FX_BIN)), fx_binary_bytes: statSync(FX_BIN).size,
    fx_build_mode: preflight.fx.build_mode, fx_build_revision: preflight.fx.build_revision,
    git_commit: git(["rev-parse", "HEAD"]), git_dirty: git(["status", "--porcelain"]) !== "",
    platform: `${process.platform}-${process.arch}`, bun: Bun.version,
    fixtures_digest: fixturesDigest(),
    provider_kind: skipped ? null : provider?.kind ?? null, provider: skipped ? null : provider?.identity ?? null,
    configurations: Object.fromEntries(p.configs.map(c => [c, CONFIGS[c]])),
    limits: opts.limits, repetitions: p.repetitions, det_repetitions: p.runType === "preflight" ? 0 : opts.detRepetitions, seed: opts.seed,
    timing: "latency_ms is spawn to exit of fx ask, measured by the harness. model_ms and tool_ms come from fx trace timestamps. Tracing is enabled identically in every configuration. harness_ms covers workspace setup, context measurement, and grading outside the fx process.",
    context_units: "request_bytes are UTF-8 bytes of serialized provider requests as fx reports them; appport_context_bytes are UTF-8 bytes of the AppPort context text.",
  };
  const trials: ModelTrial[] = [];
  const steps = skipped ? [] : plan(p.tasks, p.configs, p.repetitions, opts.seed);
  const build = (finished: boolean): Results => {
    const base: Results = {
      format: "fx.appport-effectiveness-results/1",
      benchmark_version: BENCHMARK_VERSION,
      started_at: startedAt,
      finished_at: new Date().toISOString(),
      environment,
      model_tier: { ran: trials.length > 0, skipped_reason: skipped },
      run: undefined as any,
      preflight,
      trials, deterministic, solvers,
      extensions,
      tasks: modelTasks.map(t => ({ id: t.id, category: t.category, title: t.title, purpose: t.purpose, expected: t.expected, focus: t.focus, digest: taskDigest(t), deterministic_solver: Boolean(t.deterministic) })),
    };
    base.run = runSection(base, {
      type: p.runType, planned_tasks: p.tasks, planned_configs: p.configs, repetitions: p.repetitions,
      planned_trials: p.tasks.length * p.configs.length * p.repetitions, scheduled_trials: steps.length, finished, no_model: Boolean(opts.noModel),
    });
    return base;
  };

  if (!skipped && provider) {
    let sequence = 0;
    for (const step of steps) {
      const task = modelTasks.find(t => t.id === step.task)!;
      let trial: ModelTrial;
      try {
        trial = await runModelTrial(task, step.config, provider, opts.limits, {
          repetition: step.repetition, sequence, order_in_block: step.order_in_block, cold: sequence === 0, keep_workspace: opts.keepWorkspaces,
        });
      } catch (error) {
        trial = harnessFailure(task.id, step.config, provider, opts.limits, step, sequence, error, provider.env);
      }
      trials.push(trial);
      log(`[${sequence + 1}/${steps.length}] ${task.id} ${step.config} rep ${step.repetition}: ${trial.outcome}${trial.failure ? ` (${trial.failure})` : ""} ${trial.latency_ms} ms, model calls ${trial.model_calls.value ?? "n/a"}`);
      sequence++;
      opts.checkpoint?.(build(false));
    }
  } else log(`model tier skipped: ${skipped}`);

  return build(true);
}

export function writeResults(results: Results, dir: string) {
  mkdirSync(dir, { recursive: true });
  const summary = summarize(results);
  writeFileSync(join(dir, "trials.json"), JSON.stringify(results, null, 1) + "\n");
  writeFileSync(join(dir, "summary.json"), JSON.stringify(summary, null, 1) + "\n");
  writeFileSync(join(dir, "report.md"), renderMarkdown(results, summary));
  return summary;
}

export interface Cli {
  options: RunOptions;
  out: string;
  requireModel: boolean;
}

/** Parses run.ts arguments. Throws on invalid combinations. */
export function parseArgs(argv: string[], now = new Date()): Cli {
  const opt = (name: string) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
  const num = (name: string, fallback: number) => {
    const v = opt(name);
    if (v === undefined) return fallback;
    const n = Number(v);
    if (!Number.isInteger(n) || n < 0) throw new Error(`${name} must be a non-negative integer`);
    return n;
  };
  const permission = opt("--permission") ?? DEFAULT_LIMITS.permission;
  if (!["--auto", "--full-access"].includes(permission)) throw new Error("--permission must be --auto or --full-access");
  const smoke = argv.includes("--smoke");
  const preflightOnly = argv.includes("--preflight");
  if (smoke && preflightOnly) throw new Error("--smoke and --preflight are separate profiles; choose one");
  if ((smoke || preflightOnly) && (opt("--tasks") || opt("--configs") || opt("--repetitions"))) {
    throw new Error("--tasks, --configs, and --repetitions apply to the comparison profile only; the smoke subset and preflight are fixed");
  }
  const configs = (opt("--configs")?.split(",") ?? ALL_CONFIGS) as ConfigId[];
  if (configs.some(c => !ALL_CONFIGS.includes(c))) throw new Error("--configs takes A, B, and C");
  const tasks = opt("--tasks")?.split(",");
  if (tasks?.some(id => !modelTasks.some(t => t.id === id))) throw new Error(`--tasks takes ${modelTasks.map(t => t.id).join(", ")}`);
  const stamp = now.toISOString().replace(/[:.]/g, "-");
  const runType: RunType = preflightOnly ? "preflight" : smoke ? "smoke" : "comparison";
  return {
    out: opt("--out") ?? join(here, "results", `${stamp}-${runType}`),
    requireModel: argv.includes("--require-model"),
    options: {
      runType,
      repetitions: num("--repetitions", 3),
      detRepetitions: num("--det-repetitions", 5),
      tasks, configs,
      limits: { permission, max_agent_steps: num("--max-steps", DEFAULT_LIMITS.max_agent_steps), timeout_ms: num("--timeout-ms", DEFAULT_LIMITS.timeout_ms) },
      seed: num("--seed", 1),
      model: opt("--model"),
      noModel: argv.includes("--no-model"),
      keepWorkspaces: argv.includes("--keep-workspaces"),
    },
  };
}

/** Exit status for a finished run. 1 means a deterministic golden failed; 2 means the requested model work did not happen. */
export function exitCode(results: Results, requireModel: boolean): number {
  const broken = [...results.deterministic, ...results.solvers].some(t => t.outcome !== "pass");
  if (broken) return 1;
  const run = results.run;
  if (run.type === "preflight") return results.preflight?.model_ready ? 0 : 2;
  if (run.type === "smoke") return run.smoke?.verdict === "passed" ? 0 : 2;
  if (requireModel && run.status !== "completed") return 2;
  return 0;
}

if (import.meta.main) {
  let cli: Cli;
  try { cli = parseArgs(process.argv.slice(2)); } catch (error) {
    console.error(`run.ts: ${(error as Error).message}`);
    process.exit(64);
  }
  let latest: Results | null = null;
  const save = (r: Results) => { latest = r; writeResults(r, cli.out); };
  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => {
      if (latest) {
        latest.run.status = "incomplete";
        latest.run.status_detail = `interrupted by ${signal} after ${latest.trials.length} of ${latest.run.scheduled_trials} scheduled trials`;
        latest.run.statistical_comparison = { suitable: false, reason: "the run was interrupted" };
        writeResults(latest, cli.out);
        console.error(`interrupted; partial artifacts in ${cli.out}`);
      }
      process.exit(130);
    });
  }
  const results = await runBenchmark({ ...cli.options, log: line => console.error(line), checkpoint: save });
  save(results);
  console.log(`wrote ${join(cli.out, "trials.json")}, summary.json, and report.md`);
  console.log(`run ${results.run.type}: ${results.run.status} (${results.run.status_detail})`);
  const broken = [...results.deterministic, ...results.solvers].filter(t => t.outcome !== "pass");
  if (broken.length) console.error(`deterministic results that did not match: ${broken.map(t => `${t.task_id} (${t.detail})`).join("; ")}`);
  process.exit(exitCode(results, cli.requireModel));
}
