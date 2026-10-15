// Trial execution for the AppPort effectiveness benchmark.
//
// A trial runs the freshly built ./zig-out/bin/fx once, through the same
// runFx helper and trace metrics the evals and sequencing benchmarks use. The
// only difference between configurations is the pair of environment variables
// the existing AppPort context hook reads; the harness clears both for the
// baseline so an inherited value cannot leak in.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { traceMetrics } from "../../benchmarks/sequencing/lib";
import { scrubSecrets } from "./preflight";
import {
  BENCHMARK_VERSION, CONTRACTS, MANIFEST_ENV, type DeterministicTask, type FxRunner, type Grade, type ModelTask,
  taskDigest, workspaceDigest, workspaceFiles,
} from "./tasks";

export type ConfigId = "A" | "B" | "C";

export const CONFIGS: Record<ConfigId, { name: string; manifest: boolean; focus: boolean }> = {
  A: { name: "baseline", manifest: false, focus: false },
  B: { name: "appport-context", manifest: true, focus: false },
  C: { name: "focused-context", manifest: true, focus: true },
};

/** The only environment that differs between configurations. */
export function configEnv(config: ConfigId, task: ModelTask): Record<string, string | undefined> {
  return {
    FX_APPPORT_MANIFEST: CONFIGS[config].manifest ? MANIFEST_ENV : undefined,
    FX_APPPORT_FOCUS: CONFIGS[config].focus ? task.focus.join(",") : undefined,
  };
}

export interface Provider {
  /** "configured": whatever fx resolves from the user's profile and environment. "scripted": a harness self-test fixture. */
  kind: "configured" | "scripted";
  /** Environment applied to every trial with this provider, identical across configurations. */
  env: Record<string, string | undefined>;
  identity: ProviderIdentity;
}

export interface ProviderIdentity {
  model: string | null;
  model_source: string | null;
  provider_endpoint: string | null;
  auth: string | null;
  build_revision: string | null;
}

export interface Limits {
  /** fx permission flag passed to every trial, for example "--auto". */
  permission: string;
  max_agent_steps: number;
  timeout_ms: number;
}

export const DEFAULT_LIMITS: Limits = { permission: "--auto", max_agent_steps: 40, timeout_ms: 300_000 };

/** Never use an fx found on PATH: only the binary built from this checkout. */
export function assertBuiltBinary() {
  if (!existsSync(FX_BIN)) throw new Error(`fx binary not found at ${FX_BIN}; run zig build first`);
}

export function fxVersion(): string {
  const r = spawnSync(FX_BIN, ["--version"], { encoding: "utf8", env: { ...process.env, NO_COLOR: "1" } });
  return (r.stdout || r.stderr).trim();
}

/**
 * Asks fx which provider it would use. A provider is available when fx
 * reports any authentication other than "missing". Nothing is sent to a model.
 */
export async function detectProvider(env: Record<string, string | undefined>): Promise<{ available: boolean; reason: string | null; identity: ProviderIdentity }> {
  const ws = mkdtempSync(join(tmpdir(), "fx-appport-probe-"));
  try {
    const r = await runFx(["status", "--json"], { cwd: ws, env: { ...env, FX_APPPORT_MANIFEST: undefined, FX_APPPORT_FOCUS: undefined }, timeoutMs: 30_000 });
    let s: any = {};
    try { s = JSON.parse(r.stdout); } catch {
      return { available: false, reason: `fx status --json failed: ${(r.stderr || r.stdout).trim().slice(0, 200)}`, identity: emptyIdentity() };
    }
    const identity: ProviderIdentity = {
      model: s.model ?? null, model_source: s.model_source ?? s.model_origin ?? null,
      provider_endpoint: s.provider_endpoint ?? null, auth: s.auth ?? null, build_revision: s.build_revision ?? null,
    };
    if (!s.auth || s.auth === "missing") {
      return { available: false, reason: `no model provider is configured for fx (fx status reports auth "${s.auth ?? "unknown"}"${s.auth_help ? `: ${s.auth_help}` : ""})`, identity };
    }
    return { available: true, reason: null, identity };
  } finally { rmSync(ws, { recursive: true, force: true }); }
}

function emptyIdentity(): ProviderIdentity {
  return { model: null, model_source: null, provider_endpoint: null, auth: null, build_revision: null };
}

/** A metric fx did not expose. Never estimated. */
export interface Measured<T> { value: T | null; available: boolean; source: string }
const measured = <T>(value: T | null | undefined, source: string): Measured<T> =>
  value === null || value === undefined || (typeof value === "number" && !Number.isFinite(value))
    ? { value: null, available: false, source }
    : { value, available: true, source };

export interface ModelTrial {
  benchmark_version: string;
  kind: "model";
  task_id: string;
  task_category: string;
  task_digest: string;
  config: ConfigId;
  config_name: string;
  config_env: { FX_APPPORT_MANIFEST: string | null; FX_APPPORT_FOCUS: string | null };
  provider_kind: Provider["kind"];
  provider: ProviderIdentity;
  limits: Limits;
  repetition: number;
  /** Position of this trial in the whole run, from 0. */
  sequence: number;
  /** Position of this configuration within its task-repetition block (0, 1, 2). */
  order_in_block: number;
  /** True for the first model trial of the run, when caches and connections are cold. */
  cold: boolean;
  started_at: string;
  ended_at: string;
  workspace_digest_expected: string;
  workspace_digest_before: string;
  clean_start: boolean;
  fx_exit: number | null;
  fx_timed_out: boolean;
  fx_stderr_tail: string;
  /** Spawn to exit of `fx ask`, measured by the harness. */
  latency_ms: number;
  /** Sum of provider request durations from the fx trace (admission to measurement). */
  model_ms: Measured<number>;
  /** Sum of tool execution durations from the fx trace. */
  tool_ms: Measured<number>;
  /** Harness time outside the fx process for this trial (workspace setup, context measurement, grading). */
  harness_ms: number;
  oracle_ms: number;
  model_calls: Measured<number>;
  review_calls: Measured<number>;
  tool_calls: Measured<number>;
  tool_executions: Measured<number>;
  input_tokens: Measured<number>;
  output_tokens: Measured<number>;
  cost: Measured<number>;
  /** UTF-8 bytes of every serialized provider request in the trial, as fx reports them. */
  request_bytes_total: Measured<number>;
  /** UTF-8 bytes of the first serialized provider request. */
  request_bytes_first: Measured<number>;
  /** UTF-8 bytes of the AppPort context text this configuration adds (0 for the baseline). */
  appport_context_bytes: number;
  inference_required: boolean;
  answer_tail: string;
  outcome: Grade["outcome"];
  failure: string | null;
  detail: string;
  observed: unknown;
  /** True when the outcome comes from the task's independent oracle. */
  independently_verified: boolean;
}

function lastLines(text: string, n = 3) {
  return text.trim().split("\n").slice(-n).join("\n").slice(0, 400);
}

export const fxRunner: FxRunner = (args, cwd) => {
  const started = performance.now();
  const r = spawnSync(FX_BIN, args, { cwd, encoding: "utf8", env: { HOME: cwd, PATH: "/nonexistent", NO_COLOR: "1", FX_AUTO_UPGRADE: "0" } });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr, ms: performance.now() - started };
};

/** Bytes of the context text configuration `config` adds, from the same builder fx uses. */
export function appportContextBytes(config: ConfigId, task: ModelTask, workspace: string): number {
  if (!CONFIGS[config].manifest) return 0;
  const args = ["appport", "context", ...Object.keys(CONTRACTS), "--json"];
  if (CONFIGS[config].focus) for (const f of task.focus) args.push("--focus", f);
  const r = fxRunner(args, workspace);
  if (r.code !== 0) throw new Error(`fx appport context failed: ${r.stderr || r.stdout}`);
  return JSON.parse(r.stdout).bytes;
}

function writeWorkspace(files: Record<string, string>): string {
  const ws = mkdtempSync(join(tmpdir(), "fx-appport-trial-"));
  for (const [rel, content] of Object.entries(files)) {
    const path = join(ws, rel);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, content);
  }
  return ws;
}

function readWorkspace(ws: string, files: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const rel of Object.keys(files)) { try { out[rel] = readFileSync(join(ws, rel), "utf8"); } catch { out[rel] = "<missing>"; } }
  return out;
}

export interface TrialContext {
  repetition: number;
  sequence: number;
  order_in_block: number;
  cold: boolean;
  keep_workspace?: boolean;
}

/** Runs one model-driven trial in a fresh workspace and grades it with the task's oracle. */
export async function runModelTrial(task: ModelTask, config: ConfigId, provider: Provider, limits: Limits, ctx: TrialContext): Promise<ModelTrial> {
  const trialStart = performance.now();
  const startedAt = new Date().toISOString();
  const files = workspaceFiles(task);
  const expectedDigest = workspaceDigest(files);
  const ws = writeWorkspace(files);
  const traceDir = mkdtempSync(join(tmpdir(), "fx-appport-trace-"));
  const trace = join(traceDir, "trace.log");
  try {
    const beforeDigest = workspaceDigest(readWorkspace(ws, files));
    const contextBytes = appportContextBytes(config, task, ws);
    const env = {
      ...provider.env,
      ...configEnv(config, task),
      FX_TRACE_LOG: trace,
      FX_TRACE_SCOPES: "agent,tool,context,permission",
      FX_MAX_AGENT_STEPS: String(limits.max_agent_steps),
      FX_AUTO_UPGRADE: "0",
    };
    const r = await runFx(["ask", "--json", "--no-save", limits.permission, task.prompt], { cwd: ws, env, timeoutMs: limits.timeout_ms });
    const endedAt = new Date().toISOString();
    let json: any = {};
    try { json = JSON.parse(r.stdout); } catch {}
    const answer = String(json.final_output ?? json.output ?? "");
    const log = existsSync(trace) ? readFileSync(trace, "utf8").split("\n") : [];
    const t = traceMetrics(log);
    const num = (k: string) => (t.has_measurement && t.field(k) !== "n/a" ? Number(t.field(k)) : null);
    const first = log.find(l => l.includes("event=measurement"))?.match(/serialized_request_bytes=(\d+)/)?.[1];

    const oracleStart = performance.now();
    let grade = task.grade(answer, ws);
    const oracleMs = performance.now() - oracleStart;
    if (grade.outcome !== "pass") {
      if (r.timedOut) grade = { ...grade, failure: "timeout", detail: `fx did not finish within ${limits.timeout_ms} ms; ${grade.detail}` };
      else if (r.code !== 0 && grade.failure === "no-answer") grade = { ...grade, failure: "fx-error", detail: `fx exited ${r.code}: ${lastLines(r.stderr, 1)}` };
    }
    const usage = json.usage ?? {};
    const modelCalls = num("model_calls");
    return {
      benchmark_version: BENCHMARK_VERSION, kind: "model",
      task_id: task.id, task_category: task.category, task_digest: taskDigest(task),
      config, config_name: CONFIGS[config].name,
      config_env: { FX_APPPORT_MANIFEST: env.FX_APPPORT_MANIFEST ?? null, FX_APPPORT_FOCUS: env.FX_APPPORT_FOCUS ?? null },
      provider_kind: provider.kind, provider: provider.identity, limits,
      repetition: ctx.repetition, sequence: ctx.sequence, order_in_block: ctx.order_in_block, cold: ctx.cold,
      started_at: startedAt, ended_at: endedAt,
      workspace_digest_expected: expectedDigest, workspace_digest_before: beforeDigest, clean_start: beforeDigest === expectedDigest,
      fx_exit: r.code, fx_timed_out: r.timedOut, fx_stderr_tail: scrubSecrets(lastLines(r.stderr), env),
      latency_ms: Math.round(r.elapsedMs),
      model_ms: measured(t.has_measurement ? t.model_ms : null, "fx trace: provider_admitted to measurement"),
      tool_ms: measured(t.has_measurement ? t.tool_ms : null, "fx trace: execution_start to execution_result"),
      // Workspace setup, context measurement, and grading; cleanup after the record is excluded.
      harness_ms: Math.max(0, Math.round(performance.now() - trialStart - r.elapsedMs)), oracle_ms: Math.round(oracleMs),
      model_calls: measured(modelCalls, "fx trace: measurement model_calls"),
      review_calls: measured(t.has_measurement ? t.review_sends : null, "fx trace: auto_review_send events"),
      tool_calls: measured(Array.isArray(json.tool_calls) ? json.tool_calls.length : null, "fx ask --json tool_calls"),
      tool_executions: measured(num("tool_executions"), "fx trace: measurement tool_executions"),
      input_tokens: measured(typeof usage.input_tokens === "number" ? usage.input_tokens : null, "fx ask --json usage.input_tokens (provider-reported)"),
      output_tokens: measured(typeof usage.output_tokens === "number" ? usage.output_tokens : null, "fx ask --json usage.output_tokens (provider-reported)"),
      cost: measured<number>(null, "fx does not report provider cost"),
      request_bytes_total: measured(num("serialized_request_bytes"), "fx trace: measurement serialized_request_bytes (cumulative)"),
      request_bytes_first: measured(first ? Number(first) : null, "fx trace: first measurement serialized_request_bytes"),
      appport_context_bytes: contextBytes,
      inference_required: (modelCalls ?? 0) > 0,
      answer_tail: scrubSecrets(answer.slice(-600), env),
      outcome: grade.outcome, failure: grade.failure, detail: scrubSecrets(grade.detail, env),
      // The observed answer is model output and can repeat anything it saw, so it is scrubbed too.
      observed: grade.observed === undefined || grade.observed === null ? null : JSON.parse(scrubSecrets(JSON.stringify(grade.observed), env)),
      independently_verified: grade.failure !== "verification-unavailable",
    };
  } finally {
    if (!ctx.keep_workspace) rmSync(ws, { recursive: true, force: true });
    rmSync(traceDir, { recursive: true, force: true });
  }
}

export interface DeterministicTrial {
  benchmark_version: string;
  kind: "deterministic";
  task_id: string;
  title: string;
  covers: string;
  repetition: number;
  latency_ms: number;
  exit: number | null;
  expected_exit: number;
  outcome: "pass" | "fail";
  failure: string | null;
  detail: string;
  inference_required: false;
  /** Provider requests observed while this operation ran, when the run counts them. */
  model_calls: Measured<number>;
}

/** Runs one `fx appport` operation with no provider available, so it cannot reach a model. */
export function runDeterministicTrial(task: DeterministicTask, repetition: number): DeterministicTrial {
  const ws = mkdtempSync(join(tmpdir(), "fx-appport-det-"));
  try {
    const r = fxRunner(["appport", ...task.args, "--json"], ws);
    let failure: string | null = null;
    let detail = task.expected;
    if (r.code !== task.exit) { failure = "wrong-exit"; detail = `exit ${r.code}, expected ${task.exit}`; }
    else {
      try {
        const problem = task.check(JSON.parse(r.stdout));
        if (problem) { failure = "wrong-answer"; detail = problem; }
      } catch (e) { failure = "no-answer"; detail = `output is not JSON: ${String(e)}`; }
    }
    return {
      benchmark_version: BENCHMARK_VERSION, kind: "deterministic", task_id: task.id, title: task.title, covers: task.covers,
      repetition, latency_ms: Math.round(r.ms * 100) / 100, exit: r.code, expected_exit: task.exit,
      outcome: failure ? "fail" : "pass", failure, detail, inference_required: false,
      model_calls: { value: 0, available: true, source: "no provider configured: fx ran with an empty HOME and no PATH" },
    };
  } finally { rmSync(ws, { recursive: true, force: true }); }
}

export interface SolverTrial {
  benchmark_version: string;
  kind: "solver";
  task_id: string;
  repetition: number;
  commands: string[];
  latency_ms: number;
  outcome: Grade["outcome"];
  failure: string | null;
  detail: string;
  inference_required: false;
}

/** Answers a model task with `fx appport` alone and grades it with the task's own oracle. */
export function runSolverTrial(task: ModelTask, repetition: number): SolverTrial | null {
  if (!task.deterministic) return null;
  const ws = writeWorkspace(workspaceFiles(task));
  try {
    let ms = 0;
    const timed: FxRunner = (args, cwd) => { const r = fxRunner(args, cwd); ms += r.ms; return r; };
    const { answer, commands } = task.deterministic(timed, ws);
    const g = task.grade(answer, ws);
    return {
      benchmark_version: BENCHMARK_VERSION, kind: "solver", task_id: task.id, repetition, commands,
      latency_ms: Math.round(ms * 100) / 100, outcome: g.outcome, failure: g.failure, detail: g.detail, inference_required: false,
    };
  } finally { rmSync(ws, { recursive: true, force: true }); }
}
