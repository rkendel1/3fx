// Sequencing scenarios: drives the real ./zig-out/bin/fx against the mock
// OpenAI-compatible fixture and records what actually happened.
//
//   cd tests/e2e && bun ../../benchmarks/sequencing/run.ts [--json]
//
// Model time is the mock server's (about zero), so these numbers separate
// request shape and call counts from runtime overhead; they say nothing about
// real-model latency or token cost.
import { join } from "node:path";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { runFx } from "../../tests/evals/eval-helpers";
import { completion, toolCompletion, createConfiguredProviderFixture as fixture } from "../../tests/e2e/fixtures/chat-completions";

type Respond = (n: number, body: any, ws: string) => Response;
export interface Scenario {
  id: string; title: string; args?: string[]; env?: Record<string, string>;
  settings?: Record<string, unknown>; respond: Respond; prepare?: (ws: string) => void;
}

const shell = (command: string) => ({ request: { action: "run", command } });
const MODEL = (b: any) => b.model;

export const scenarios: Scenario[] = [
  { id: "S1", title: "no tool needed", respond: (n, b) => completion(MODEL(b), "Hello.", 20) },
  { id: "S2", title: "one read-only tool call", prepare: ws => writeFileSync(join(ws, "a.txt"), "alpha\n".repeat(50)),
    respond: (n, b) => n === 1 ? toolCompletion(MODEL(b), "read_file", { path: "a.txt" }) : completion(MODEL(b), "Read it.", 20) },
  { id: "S3", title: "three sequential tool calls", prepare: ws => { for (const f of ["a", "b", "c"]) writeFileSync(join(ws, `${f}.txt`), `${f}\n`.repeat(50)); },
    respond: (n, b) => n <= 3 ? toolCompletion(MODEL(b), "read_file", { path: `${"abc"[n - 1]}.txt` }, `call-${n}`) : completion(MODEL(b), "Read all.", 20) },
  { id: "S4", title: "state-changing action", args: ["--full-access"],
    respond: (n, b) => n === 1 ? toolCompletion(MODEL(b), "shell", shell("echo changed > out.txt")) : completion(MODEL(b), "Written.", 20) },
  { id: "S5", title: "malformed shell call then correction", args: ["--full-access"],
    respond: (n, b) => n === 1 ? toolCompletion(MODEL(b), "shell", { command: 42 }) : n === 2 ? toolCompletion(MODEL(b), "shell", shell("echo ok > fixed.txt"), "call-2") : completion(MODEL(b), "Fixed.", 20) },
  { id: "S6", title: "execution failure then correction", args: ["--full-access"],
    respond: (n, b) => n === 1 ? toolCompletion(MODEL(b), "shell", shell("ls missing-dir")) : n === 2 ? toolCompletion(MODEL(b), "shell", shell("ls ."), "call-2") : completion(MODEL(b), "Recovered.", 20) },
  { id: "S7", title: "repeated identical failure", args: ["--full-access"],
    respond: (n, b) => toolCompletion(MODEL(b), "shell", shell("ls missing-dir"), `call-${n}`) },
  { id: "S7b", title: "repeated invalid shell call", args: ["--full-access"],
    respond: (n, b) => toolCompletion(MODEL(b), "shell", { command: 42 }, `call-${n}`) },
  { id: "S8", title: "repeated identical read-only calls", prepare: ws => writeFileSync(join(ws, "a.txt"), "alpha\n".repeat(200)),
    respond: (n, b) => n <= 4 ? toolCompletion(MODEL(b), "read_file", { path: "a.txt" }, `call-${n}`) : completion(MODEL(b), "Done.", 20) },
  { id: "S9", title: "step limit reached", env: { FX_MAX_AGENT_STEPS: "2" }, prepare: ws => writeFileSync(join(ws, "a.txt"), "x\n"),
    respond: (n, b) => toolCompletion(MODEL(b), "read_file", { path: "a.txt" }, `call-${n}`) },
  { id: "S11", title: "auto review: default-profile ls", args: ["--auto"],
    respond: (n, b) => n === 1 ? toolCompletion(MODEL(b), "shell", shell("ls .")) : completion(MODEL(b), "Listed.", 20) },
  { id: "S12", title: "auto review: clean-profile ls", args: ["--auto"],
    respond: (n, b) => n === 1 ? toolCompletion(MODEL(b), "shell", { request: { action: "run", command: "ls .", profile: "clean" } }) : completion(MODEL(b), "Listed.", 20) },
  { id: "S13", title: "auto review: invalid call (no review expected)", args: ["--auto"],
    respond: (n, b) => n === 1 ? toolCompletion(MODEL(b), "shell", { command: 42 }) : completion(MODEL(b), "Gave up.", 20) },
  { id: "S14", title: "auto review: same new-file command twice", args: ["--auto"],
    respond: (n, b) => n <= 2 ? toolCompletion(MODEL(b), "shell", shell("echo a > o.txt"), `call-${n}`) : completion(MODEL(b), "Done.", 20) },
  { id: "S15", title: "default permission mode, state change", respond: (n, b) => n === 1 ? toolCompletion(MODEL(b), "shell", shell("echo a > o.txt")) : completion(MODEL(b), "Done.", 20) },
  { id: "S10", title: "Ollama-style stop finish with tool call", args: ["--full-access"],
    settings: { tool_schema_mode: "flatten_unions", finish_reason_mode: "accept_stop_with_tool_calls" },
    respond: (n, b) => {
      if (n > 1) return completion(MODEL(b), "Ran.", 20);
      const chunks = [
        { id: "c", model: MODEL(b), choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: "call-1", type: "function", function: { name: "shell", arguments: JSON.stringify(shell("echo hi")) } }] }, finish_reason: null }] },
        { id: "c", model: MODEL(b), choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
      ];
      return new Response(chunks.map(v => `data: ${JSON.stringify(v)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
    } },
];

const isReview = (body: any) => (body.tools?.length ?? 0) <= 1;

export async function runScenario(s: Scenario) {
  let n = 0;
  const f = fixture(body => {
    if (isReview(body)) return toolCompletion(MODEL(body), "permission_decision", { decision: "clear" }, "review");
    n++; return s.respond(n, body, f.workspace);
  });
  try {
    if (s.settings) { Object.assign(f.settings.providers.local, s.settings); f.save(); }
    s.prepare?.(f.workspace);
    const trace = join(f.home, "trace.log");
    const started = Date.now();
    const r = await runFx(["ask", "--json", "--no-save", ...(s.args ?? []), "do the task"], {
      cwd: f.workspace, env: { ...f.env, ...(s.env ?? {}), FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "agent,tool,context,permission" }, timeoutMs: 60000,
    });
    const wall = Date.now() - started;
    let json: any = {}; try { json = JSON.parse(r.stdout); } catch {}
    const log = existsSync(trace) ? readFileSync(trace, "utf8").split("\n") : [];
    const at = (needle: string) => log.filter(l => l.includes(needle)).map(l => Number(l.split(" ")[0]));
    const meas = log.filter(l => l.includes("event=measurement")).at(-1) ?? "";
    const field = (k: string) => meas.match(new RegExp(`${k}=(\\S+)`))?.[1] ?? "n/a";
    const reviews = f.requests.filter(q => isReview(q.body)).length;
    const main = f.requests.filter(q => !isReview(q.body));
    let prefixOk = true;
    for (let i = 1; i < main.length; i++) {
      const a = main[i - 1].body, b = main[i].body;
      if (JSON.stringify(a.tools) !== JSON.stringify(b.tools)) prefixOk = false;
      for (let k = 0; k < a.messages.length; k++) if (JSON.stringify(a.messages[k]) !== JSON.stringify(b.messages[k])) prefixOk = false;
    }
    const calls = json.tool_calls ?? [];
    const first = f.requests[0]?.body;
    const part = (o: unknown) => Buffer.byteLength(JSON.stringify(o ?? null));
    const tools = first ? part(first.tools) : 0;
    const msgs = first ? part(first.messages) : 0;
    return {
      id: s.id, title: s.title, exit: r.code, finalSupported: undefined as unknown,
      model_calls: main.length, review_calls: reviews, reasons: `${field("calls_initial")}/${field("calls_after_tools")}/${field("calls_after_failed_tools")}`, prefix_stable: prefixOk, proposed: calls.length,
      executed: Number(field("tool_executions")), rejected_or_failed: calls.filter((c: any) => c.status !== "success").length,
      request_bytes: main.map(q => q.bytes), messages: main.map(q => q.body.messages.length),
      tools_bytes: tools, first_messages_bytes: msgs,
      provider_in: field("provider_input_tokens"), provider_out: field("provider_output_tokens"),
      steps: json.steps, wall_ms: wall, overhead_before_first_call_ms: (at("event=provider_admitted")[0] ?? 0) - (at("event=prompt_start")[0] ?? 0),
      files: ["out.txt", "fixed.txt"].filter(x => existsSync(join(f.workspace, x))),
      output: String(json.final_output ?? json.output ?? "").slice(0, 40), stderr: r.stderr.trim().split("\n").at(-1)?.slice(0, 90) ?? "",
    };
  } finally { f.close(); }
}

