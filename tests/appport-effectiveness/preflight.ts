// Provider readiness for the AppPort effectiveness benchmark.
//
// The preflight asks fx what it would use and whether that looks usable,
// without sending any inference request:
//
//   fx --version                 binary version
//   fx status --json             provider, model, authentication, build revision and mode
//   fx models --json             whether the selected model is offered; for the Vercel AI
//                                Gateway this fetches the model catalog, which also shows
//                                whether the Gateway is reachable
//   GET <provider_endpoint>/models, without credentials, for a configured connection
//                                (fx lists those models from settings, so it does not
//                                contact the endpoint itself)
//   fx appport coverage --json   whether the deterministic tier can run
//
// "ready" means these checks passed. It is not proof that a model request will
// succeed: the first trial's request is the definitive connectivity test.
//
// Every string this file returns passes through `scrubSecrets`. It never reads
// credential files and never prints environment values.

import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";

export type ReadinessState = "ready" | "missing_auth" | "missing_provider" | "endpoint_unreachable" | "unsupported_model" | "preflight_error";

export interface Check {
  name: string;
  status: "ok" | "warn" | "fail" | "skipped";
  detail: string;
}

export interface Preflight {
  state: ReadinessState;
  /** True only when `state` is "ready". */
  model_ready: boolean;
  deterministic_ready: boolean;
  checked_at: string;
  fx: { binary: string; version: string | null; build_revision: string | null; build_mode: string | null; sha256: string | null };
  provider: {
    auth: string | null;
    connected_providers: string[];
    /** The model fx resolved: FX_MODEL when --model is given, otherwise the profile default. */
    model: string | null;
    model_origin: string | null;
    model_source: string | null;
    /** Endpoint without credentials, query, or fragment. Null for the Vercel AI Gateway. */
    endpoint: string | null;
    requested_model: string | null;
  };
  model_check: { status: "listed" | "not_listed" | "not_verified" | "unavailable" | "skipped"; detail: string };
  endpoint_check: { status: "reachable" | "unreachable" | "not_checked"; method: string; http_status: number | null; detail: string };
  checks: Check[];
  note: string;
}

const NOTE = "A ready preflight is not proof that a model request will succeed. The first trial's request is the definitive connectivity test.";

/** Environment names whose values are secrets. Values shorter than 12 characters are not treated as secrets. */
const SECRET_NAME = /(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|COOKIE)/i;

/**
 * Removes secret material from diagnostic text: the values of secret-named
 * environment variables (from the process and from `env`), bearer tokens,
 * common API key shapes, URL credentials, and credential query parameters.
 */
export function scrubSecrets(text: string, env: Record<string, string | undefined> = {}): string {
  let out = text;
  const values = new Set<string>();
  for (const source of [process.env, env]) {
    for (const [name, value] of Object.entries(source)) {
      if (value && value.length >= 12 && SECRET_NAME.test(name)) values.add(value);
    }
  }
  for (const value of [...values].sort((a, b) => b.length - a.length)) out = out.split(value).join("<redacted>");
  return out
    .replace(/(authorization\s*[:=]\s*)(bearer\s+)?[^\s"',;]+/gi, "$1<redacted>")
    .replace(/\bbearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, "Bearer <redacted>")
    .replace(/\b(sk|pk|rk|xai|gsk|vck)[-_][A-Za-z0-9_-]{8,}/g, "<redacted>")
    .replace(/([a-z][a-z0-9+.-]*:\/\/)[^\s/@]+@/gi, "$1<redacted>@")
    .replace(/([?&](?:api[_-]?key|key|token|access_token|secret|signature)=)[^&\s"']+/gi, "$1<redacted>");
}

/** An endpoint for display: no user info, query, or fragment. */
export function displayEndpoint(endpoint: string | null | undefined): string | null {
  if (!endpoint) return null;
  try {
    const url = new URL(endpoint);
    url.username = "";
    url.password = "";
    url.search = "";
    url.hash = "";
    return url.toString().replace(/\/$/, "");
  } catch {
    return scrubSecrets(endpoint);
  }
}

export interface PreflightOptions {
  /** Environment for fx, identical to the one trials use. */
  env: Record<string, string | undefined>;
  /** Requested model; passed to fx as FX_MODEL. */
  model?: string;
  /** Probe timeout for a configured endpoint. */
  probeTimeoutMs?: number;
}

/**
 * Probes a configured endpoint with an unauthenticated GET of `<endpoint>/models`.
 * Any HTTP response, including 401 or 404, means the host answered. No
 * credentials or headers from the environment are sent.
 */
export async function probeEndpoint(endpoint: string, timeoutMs = 5_000): Promise<{ reachable: boolean; http_status: number | null; detail: string }> {
  const url = `${endpoint.replace(/\/$/, "")}/models`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { method: "GET", signal: controller.signal, redirect: "manual", headers: { accept: "application/json" } });
    await response.body?.cancel();
    return { reachable: true, http_status: response.status, detail: `HTTP ${response.status} from ${displayEndpoint(endpoint)}/models without credentials` };
  } catch (error) {
    const reason = controller.signal.aborted ? `no response within ${timeoutMs} ms` : String((error as Error)?.message ?? error);
    return { reachable: false, http_status: null, detail: scrubSecrets(`${displayEndpoint(endpoint)} did not answer: ${reason}`) };
  } finally {
    clearTimeout(timer);
  }
}

export async function runPreflight(opts: PreflightOptions): Promise<Preflight> {
  const env: Record<string, string | undefined> = {
    ...opts.env,
    FX_MODEL: opts.model ?? opts.env.FX_MODEL,
    FX_APPPORT_MANIFEST: undefined,
    FX_APPPORT_FOCUS: undefined,
    FX_AUTO_UPGRADE: "0",
  };
  const scrub = (s: string) => scrubSecrets(s, env);
  const checks: Check[] = [];
  const result: Preflight = {
    state: "preflight_error", model_ready: false, deterministic_ready: false, checked_at: new Date().toISOString(),
    fx: { binary: FX_BIN, version: null, build_revision: null, build_mode: null, sha256: null },
    provider: { auth: null, connected_providers: [], model: null, model_origin: null, model_source: null, endpoint: null, requested_model: opts.model ?? null },
    model_check: { status: "skipped", detail: "not checked" },
    endpoint_check: { status: "not_checked", method: "none", http_status: null, detail: "not checked" },
    checks, note: NOTE,
  };
  const finish = (state: ReadinessState) => {
    result.state = state;
    result.model_ready = state === "ready";
    return result;
  };

  let binary: Buffer;
  try { binary = readFileSync(FX_BIN); } catch {
    checks.push({ name: "binary", status: "fail", detail: `fx binary not found at ${FX_BIN}; run zig build` });
    return finish("preflight_error");
  }
  result.fx.sha256 = createHash("sha256").update(binary).digest("hex");

  const cwd = mkdtempSync(join(tmpdir(), "fx-appport-preflight-"));
  try {
    const version = await runFx(["--version"], { cwd, env, timeoutMs: 30_000 });
    result.fx.version = scrub((version.stdout || version.stderr).trim()) || null;
    checks.push({ name: "binary", status: version.code === 0 ? "ok" : "fail", detail: `fx ${result.fx.version ?? "version unknown"}` });

    const det = await runFx(["appport", "coverage", "--json"], { cwd, env: { HOME: cwd, PATH: "/nonexistent" }, timeoutMs: 30_000 });
    result.deterministic_ready = det.code === 0;
    checks.push({ name: "deterministic", status: det.code === 0 ? "ok" : "fail", detail: det.code === 0 ? "fx appport runs without a provider" : scrub(`fx appport coverage exited ${det.code}: ${det.stderr.trim()}`) });

    const statusRun = await runFx(["status", "--json"], { cwd, env, timeoutMs: 30_000 });
    let status: any;
    try { status = JSON.parse(statusRun.stdout); } catch {
      const detail = scrub((statusRun.stderr || statusRun.stdout).trim().slice(0, 300));
      if (/UnknownConfiguredProvider/.test(statusRun.stderr + statusRun.stdout)) {
        checks.push({ name: "provider", status: "fail", detail: `fx does not know the selected provider (${detail}). Configure it in ~/.fx/settings.json or unset FX_PROVIDER.` });
        return finish("missing_provider");
      }
      checks.push({ name: "status", status: "fail", detail: `fx status --json failed: ${detail}` });
      return finish("preflight_error");
    }
    result.fx.build_revision = status.build_revision ?? null;
    result.fx.build_mode = status.build_mode ?? null;
    Object.assign(result.provider, {
      auth: status.auth ?? null,
      connected_providers: Array.isArray(status.connected_providers) ? status.connected_providers : [],
      model: status.model ?? null,
      model_origin: status.model_origin ?? null,
      model_source: status.model_source ?? null,
      endpoint: displayEndpoint(status.provider_endpoint),
    });
    const providerLabel = status.provider_endpoint ? `connection ${result.provider.connected_providers.join(", ") || status.model_source}` : "Vercel AI Gateway";
    checks.push({ name: "provider", status: "ok", detail: `${providerLabel}; model ${status.model} (${status.model_origin ?? "origin unknown"})` });

    if (!status.auth || status.auth === "missing") {
      checks.push({ name: "auth", status: "fail", detail: scrub(status.auth_help ?? "fx reports no authentication") });
      return finish("missing_auth");
    }
    checks.push({ name: "auth", status: "ok", detail: `fx reports auth "${scrub(String(status.auth))}"` });

    // Model support, and Gateway reachability through its catalog.
    const models = await runFx(["models", "--json"], { cwd, env, timeoutMs: 60_000 });
    let list: any = null;
    try { list = JSON.parse(models.stdout); } catch {}
    const wanted = status.model as string;
    if (!list || list.error) {
      const code = list?.code ?? `exit ${models.code}`;
      const detail = scrub(`fx models failed: ${list?.error ?? models.stderr.trim()} (${code})`);
      result.model_check = { status: "unavailable", detail };
      if (!status.provider_endpoint && /Transport|Unavailable|Timeout|Connect/i.test(`${code} ${list?.error ?? ""}`)) {
        result.endpoint_check = { status: "unreachable", method: "fx models --json (Gateway catalog)", http_status: null, detail };
        checks.push({ name: "endpoint", status: "fail", detail });
        return finish("endpoint_unreachable");
      }
      if (/auth|unauthor|forbidden|401|403/i.test(detail)) {
        checks.push({ name: "auth", status: "fail", detail });
        return finish("missing_auth");
      }
      checks.push({ name: "models", status: "fail", detail });
      return finish("preflight_error");
    }
    const ids: string[] = Array.isArray(list.ids) ? list.ids : [];
    if (!status.provider_endpoint) {
      result.endpoint_check = { status: "reachable", method: "fx models --json (Gateway catalog)", http_status: null, detail: `catalog returned ${list.count ?? ids.length} models` };
      checks.push({ name: "endpoint", status: "ok", detail: "the Gateway model catalog responded" });
    }
    if (ids.includes(wanted)) {
      result.model_check = { status: "listed", detail: `${wanted} is listed by fx models` };
      checks.push({ name: "model", status: "ok", detail: result.model_check.detail });
    } else if ((list.more_count ?? 0) > 0) {
      result.model_check = { status: "not_verified", detail: `${wanted} is not among the ${ids.length} models fx listed, and the list is truncated` };
      checks.push({ name: "model", status: "warn", detail: result.model_check.detail });
    } else {
      result.model_check = { status: "not_listed", detail: `${wanted} is not offered by the configured provider; fx lists ${ids.slice(0, 10).join(", ") || "no models"}${ids.length > 10 ? ", …" : ""}` };
      checks.push({ name: "model", status: "fail", detail: result.model_check.detail });
      return finish("unsupported_model");
    }

    if (status.provider_endpoint) {
      const probe = await probeEndpoint(status.provider_endpoint, opts.probeTimeoutMs);
      result.endpoint_check = { status: probe.reachable ? "reachable" : "unreachable", method: "unauthenticated GET <endpoint>/models", http_status: probe.http_status, detail: probe.detail };
      checks.push({ name: "endpoint", status: probe.reachable ? "ok" : "fail", detail: probe.detail });
      if (!probe.reachable) return finish("endpoint_unreachable");
    }
    return finish("ready");
  } catch (error) {
    checks.push({ name: "preflight", status: "fail", detail: scrub(String((error as Error)?.message ?? error)) });
    return finish("preflight_error");
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
}

export function renderPreflight(p: Preflight): string {
  const lines = [
    `preflight: ${p.state}${p.model_ready ? " (model tier can start)" : " (model tier cannot start)"}`,
    `fx: ${p.fx.version ?? "unknown"} revision ${p.fx.build_revision ?? "unknown"} build ${p.fx.build_mode ?? "unknown"}`,
    `provider: ${p.provider.endpoint ?? (p.provider.auth && p.provider.auth !== "missing" ? "Vercel AI Gateway" : "none")}; model ${p.provider.model ?? "unknown"}${p.provider.requested_model ? ` (requested ${p.provider.requested_model})` : ""}; auth ${p.provider.auth ?? "unknown"}`,
    ...p.checks.map(c => `  ${c.status.padEnd(7)} ${c.name}: ${c.detail}`),
    `deterministic tier: ${p.deterministic_ready ? "can run" : "cannot run"}`,
    p.note,
  ];
  return lines.join("\n");
}
