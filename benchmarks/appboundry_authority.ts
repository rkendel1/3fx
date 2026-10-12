// Latency of the AppBoundry authority path, measured against the REAL stack
// (real `authboundry serve` + real AppBoundry host in authority mode).
//
//   FX_REAL_STACK=1 AUTHBOUNDRY_DIR=... APPBOUNDRY_DIR=... AUTHBOUNDRY_NODE_MODULES=... \
//     bun benchmarks/appboundry_authority.ts [--iterations 20] [--out result.json]
//
// It reports raw numbers and the method; it asserts no budget. All timings are
// wall clock on one machine with everything on loopback, so they bound the
// software cost of authorization and evidence handling, not network cost to a
// hosted AuthBoundry.
//
// Layers, from the inside out:
//   protocol   direct tools/call against the host: no credential (rejected before any
//              authority call), denied (session lookup + one decision, no module),
//              allowed (session lookup + decision + module + records).
//   discovery  GET /.well-known/appport, and `fx mcp list --connect` (discovery,
//              connect, tools/list for every application).
//   fx         `fx ask` with a scripted local model: no tool call (baseline) and an
//              allowed call. Subtracting the baseline isolates the call itself. A
//              denied call is not timed through fx: after revocation the host no
//              longer lists the tool to a new fx process.
import { spawnSync } from "node:child_process";
import { cpus } from "node:os";
import { join } from "node:path";
import { writeFileSync } from "node:fs";
import { runFx } from "../tests/e2e/../evals/eval-helpers";
import { completion, createConfiguredProviderFixture, toolCompletion } from "../tests/e2e/fixtures/chat-completions";
import { RealStack, realStackConfigFromEnv } from "../tests/e2e/real-stack/client";

const config = realStackConfigFromEnv();
if (!config) {
  console.error("Not run: set FX_REAL_STACK=1, AUTHBOUNDRY_DIR and APPBOUNDRY_DIR. No numbers were produced.");
  process.exit(2);
}
const argValue = (flag: string) => {
  const index = process.argv.indexOf(flag);
  return index >= 0 ? process.argv[index + 1] : undefined;
};
const iterations = Number(argValue("--iterations") ?? 20);
const warmup = 3;

const INPUT = {
  interpretedChange: { affectedConceptCandidates: ["billing", "warehouse"] },
  organizationalMappings: [{ id: "ent-1", name: "billing service", businessSystem: "ERP", certainty: "declared", evidenceIds: ["doc-7"] }],
};

type Stats = { n: number; median: number; p95: number; mean: number; min: number };
const stats = (samples: number[]): Stats => {
  const sorted = [...samples].sort((a, b) => a - b);
  const at = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))];
  return { n: sorted.length, median: at(0.5), p95: at(0.95), mean: sorted.reduce((a, b) => a + b, 0) / sorted.length, min: sorted[0] };
};
async function time(fn: () => Promise<unknown>): Promise<Stats> {
  for (let i = 0; i < warmup; i++) await fn();
  const samples: number[] = [];
  for (let i = 0; i < iterations; i++) {
    const start = performance.now();
    await fn();
    samples.push(performance.now() - start);
  }
  return stats(samples);
}

const lastTool = (body: any) => [...body.messages].reverse().find((entry: any) => entry.role === "tool")?.content ?? "";

/** One `fx ask` against the stack as `credential`; `call` selects whether the model invokes the tool. */
async function fxAsk(stack: RealStack, credential: string, call: boolean) {
  let step = 0;
  let name = "";
  const provider = createConfiguredProviderFixture((body: any) => {
    step += 1;
    if (step === 1) return toolCompletion(body.model, "capability_search", { query: "changeimpact context" });
    if (step === 2) {
      name = (JSON.parse(lastTool(body)).mcp_tools ?? []).find((tool: any) => tool.name.includes("appboundry_ctx_"))?.name ?? "";
      return name && call ? toolCompletion(body.model, "mcp_select_tool", { name }) : completion(body.model, "done");
    }
    if (step === 3) return toolCompletion(body.model, name, INPUT);
    return completion(body.model, "done");
  });
  try {
    const result = await runFx(["ask", "--json", "--no-save", "Resolve the change context"], {
      cwd: provider.workspace,
      env: { ...provider.env, FX_PERMISSION_MODE: "full-access", FX_APPBOUNDRY_URL: stack.state.host, FX_APPBOUNDRY_TOKEN: credential, FX_APPBOUNDRY_ALLOW_LOCAL_HTTP: "1", FX_APPBOUNDRY_APPS: "synapse.change-context-resolver" },
      timeoutMs: 90_000,
    });
    if (result.code !== 0) throw new Error(`fx ask failed: ${result.stderr.slice(0, 300)}`);
  } finally {
    provider.close();
  }
}

const stack = new RealStack(config);
await stack.start();
try {
  const alice = stack.state.sessions.alice.credential;
  const bob = stack.state.sessions.bob.credential; // authenticated, never granted
  const report: Record<string, Stats> = {};

  report["protocol: no credential (rejected before any authority call)"] = await time(() => stack.rawCall("ctx", undefined, INPUT));
  report["protocol: denied (ungranted principal, no module run)"] = await time(() => stack.rawCall("ctx", bob, INPUT));
  report["protocol: allowed (decision + module + records)"] = await time(() => stack.rawCall("ctx", alice, INPUT));
  const executions = await stack.executions();

  report["discovery: GET /.well-known/appport"] = await time(() => fetch(`${stack.state.host}/.well-known/appport`).then((r) => r.text()));
  const home = stack.fxHome;
  const listEnv = { HOME: home, FX_PERMISSION_MODE: "full-access", FX_APPBOUNDRY_URL: stack.state.host, FX_APPBOUNDRY_ALLOW_LOCAL_HTTP: "1", FX_APPBOUNDRY_TOKEN: alice };
  report["discovery: fx mcp list --connect (3 apps, authorized)"] = await time(() => runFx(["mcp", "list", "--connect"], { cwd: stack.scratch, env: listEnv, timeoutMs: 90_000 }));

  report["fx ask: baseline, search only"] = await time(() => fxAsk(stack, alice, false));
  report["fx ask: allowed call"] = await time(() => fxAsk(stack, alice, true));

  const rows = Object.entries(report).map(([name, s]) => `| ${name} | ${s.n} | ${s.median.toFixed(1)} | ${s.p95.toFixed(1)} | ${s.mean.toFixed(1)} | ${s.min.toFixed(1)} |`);
  const delta = (a: string, b: string) => (report[a].median - report[b].median).toFixed(1);
  const output = [
    `AppBoundry authority latency (ms), ${iterations} iterations after ${warmup} warmup, loopback, ${cpus().length} CPUs`,
    `authboundry ${stack.state.versions.authboundry}, appboundry ${stack.state.versions.appboundry}, fx ${spawnSync(join(process.cwd(), "zig-out/bin/fx"), ["--version"], { encoding: "utf8" }).stdout.trim() || "unknown"}`,
    "",
    "| measurement | n | median | p95 | mean | min |",
    "| --- | --- | --- | --- | --- | --- |",
    ...rows,
    "",
    `protocol: allowed - denied (module, records, evidence) = ${delta("protocol: allowed (decision + module + records)", "protocol: denied (ungranted principal, no module run)")} ms median`,
    `protocol: denied - unauthenticated (session lookup + one durable authorization decision) = ${delta("protocol: denied (ungranted principal, no module run)", "protocol: no credential (rejected before any authority call)")} ms median`,
    `fx: allowed call - baseline = ${delta("fx ask: allowed call", "fx ask: baseline, search only")} ms median`,
    "denied latency is measured at the protocol layer only: a fresh fx process after revocation is no longer shown the tool, so it never issues the call",
    `module executions during the protocol phase: ctx completed=${executions.ctx.completed} (denied and unauthenticated calls added none)`,
  ].join("\n");
  console.log(output);
  const out = argValue("--out");
  if (out) writeFileSync(out, JSON.stringify({ iterations, warmup, versions: stack.state.versions, report }, null, 2));
} finally {
  await stack.stop();
}
