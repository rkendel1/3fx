// Task corpus for the AppPort effectiveness benchmark.
//
// Every task states its expected outcome before any run, and every oracle
// grades evidence it gathers itself: the final answer compared field by field
// with the expected values, executable tests the agent never sees, or the
// workspace files. A model's claim of success is never evidence.
//
// Model-driven tasks (categories "discovery" and "implementation") receive the
// same workspace in every configuration: the two published contracts under
// contracts/ plus any task files. Only configurations B and C add the
// AppPort context, through FX_APPPORT_MANIFEST and FX_APPPORT_FOCUS.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const BENCHMARK_VERSION = "appport-effectiveness/1";
export const here = import.meta.dir;
export const repoRoot = resolve(here, "../..");
export const fixtureDir = join(here, "fixtures");
export const parityFixtureDir = join(repoRoot, "tests/appport-parity/fixtures");

/** Contract files every model-driven workspace contains, at these relative paths. */
export const CONTRACTS = {
  "contracts/memos.manifest.json": join(fixtureDir, "apps/memos.manifest.json"),
  "contracts/vikunja.manifest.json": join(fixtureDir, "apps/vikunja.manifest.json"),
};
/** The value of FX_APPPORT_MANIFEST in configurations B and C, relative to the workspace. */
export const MANIFEST_ENV = Object.keys(CONTRACTS).join(",");

export type Category = "discovery" | "implementation" | "deterministic";
export type Outcome = "pass" | "partial" | "fail" | "unsupported";

export interface Grade {
  outcome: Outcome;
  /** Null when the task passed. */
  failure: string | null;
  detail: string;
  observed?: unknown;
}

export interface ModelTask {
  id: string;
  category: "discovery" | "implementation";
  title: string;
  /** What the task exercises, for the report. */
  purpose: string;
  /** Extra workspace files, relative path → content. */
  files?: () => Record<string, string>;
  prompt: string;
  /** FX_APPPORT_FOCUS in configuration C: the capabilities the task is about. */
  focus: string[];
  expected: unknown;
  /** Grades the trial from the final answer text and the workspace after the run. */
  grade: (answer: string, workspace: string) => Grade;
  /**
   * Answers the task with `fx appport` alone, without a model, when that is
   * possible. Graded by `grade` like a model answer.
   */
  deterministic?: (fx: FxRunner, workspace: string) => { answer: string; commands: string[] };
}

export type FxRunner = (args: string[], cwd: string) => { code: number | null; stdout: string; stderr: string; ms: number };

const answerRule =
  "Do not modify any files. End your reply with one fenced ```json block that contains only the answer object.";

/** The last fenced JSON block in the answer, or null when there is none that parses. */
export function extractAnswer(text: string): any | null {
  const blocks = [...text.matchAll(/```(?:json)?\s*\n([\s\S]*?)```/g)].map(m => m[1]);
  for (let i = blocks.length - 1; i >= 0; i--) {
    try { return JSON.parse(blocks[i]); } catch {}
  }
  return null;
}

const sortedSet = (values: unknown): string[] | null =>
  Array.isArray(values) && values.every(v => typeof v === "string") ? [...new Set(values as string[])].sort() : null;
const sameSet = (a: unknown, b: string[]) => JSON.stringify(sortedSet(a)) === JSON.stringify([...b].sort());
/** `name@1` and `name` both identify a version-1 capability in these contracts. */
const ref = (value: unknown) => (typeof value === "string" ? (value.includes("@") ? value : `${value}@1`) : value);

const pass = (detail: string, observed?: unknown): Grade => ({ outcome: "pass", failure: null, detail, observed });
const fail = (failure: string, detail: string, observed?: unknown): Grade => ({ outcome: "fail", failure, detail, observed });
const partial = (failure: string, detail: string, observed?: unknown): Grade => ({ outcome: "partial", failure, detail, observed });

/** Discovery tasks must leave the workspace as it started. */
function unchanged(workspace: string, files: Record<string, string>): string | null {
  for (const [path, content] of Object.entries(files)) {
    let now: string;
    try { now = readFileSync(join(workspace, path), "utf8"); } catch { return `${path} was removed`; }
    if (now !== content) return `${path} was modified`;
  }
  return null;
}

function contractFiles(): Record<string, string> {
  return Object.fromEntries(Object.entries(CONTRACTS).map(([rel, abs]) => [rel, readFileSync(abs, "utf8")]));
}

function gradeAnswer(answer: string, workspace: string, check: (a: any) => Grade): Grade {
  const modified = unchanged(workspace, contractFiles());
  if (modified) return fail("constraint-violation", modified);
  const parsed = extractAnswer(answer);
  if (parsed === null || typeof parsed !== "object") return fail("no-answer", "no fenced JSON answer object");
  return check(parsed);
}

// ---------------------------------------------------------------------------------------------- discovery

const discovery: ModelTask[] = [
  {
    id: "D1", category: "discovery", title: "Find the capability that marks a task done",
    purpose: "capability discovery for a requested operation (workload behaviour task-set-done)",
    prompt: `The contracts/ directory holds the published AppPort contracts of two applications, Memos and Vikunja.
Which capability marks a Vikunja task as done? ${answerRule}
Answer object: {"capability": "<name>@<version>"}`,
    focus: ["vikunja.tasks.setdone"],
    expected: { capability: "vikunja.tasks.setdone@1" },
    grade: (answer, ws) => gradeAnswer(answer, ws, a =>
      ref(a.capability) === "vikunja.tasks.setdone@1" ? pass("exact capability") : fail("wrong-answer", `answered ${JSON.stringify(a.capability)}`, a)),
    deterministic: (fx, ws) => {
      const args = ["appport", "find", ...Object.keys(CONTRACTS), "--changes", "urn:appport:vikunja:tasks", "--operation", "update", "--json"];
      const out = JSON.parse(fx(args, ws).stdout);
      const answer = out.matches.length === 1 && out.undeclared.length === 0 ? { capability: out.matches[0].capability } : { capability: null };
      return { answer: "```json\n" + JSON.stringify(answer) + "\n```", commands: [args.join(" ")] };
    },
  },
  {
    id: "D2", category: "discovery", title: "Find the capability that searches memos by tag",
    purpose: "capability discovery when two capabilities read the same resource (workload behaviour memo-search)",
    prompt: `The contracts/ directory holds the published AppPort contracts of two applications, Memos and Vikunja.
Which capability finds the memos a user may see that carry a given tag? ${answerRule}
Answer object: {"capability": "<name>@<version>"}`,
    focus: ["memos.search"],
    expected: { capability: "memos.search@1" },
    grade: (answer, ws) => gradeAnswer(answer, ws, a =>
      ref(a.capability) === "memos.search@1" ? pass("exact capability") : fail("wrong-answer", `answered ${JSON.stringify(a.capability)}`, a)),
  },
  {
    id: "D3", category: "discovery", title: "Required inputs and outputs of reading one task",
    purpose: "identify required inputs and outputs of a selected capability",
    prompt: `The contracts/ directory holds the published AppPort contracts of two applications, Memos and Vikunja.
For the capability that reads one Vikunja task, list its required input fields and its required output fields. ${answerRule}
Answer object: {"capability": "<name>@<version>", "required_inputs": ["..."], "required_outputs": ["..."]}`,
    focus: ["vikunja.tasks.get"],
    expected: {
      capability: "vikunja.tasks.get@1",
      required_inputs: ["id"],
      required_outputs: ["created", "createdBy", "description", "done", "doneAt", "dueDate", "id", "identifier", "percentDone", "priority", "projectId", "title", "updated"],
    },
    grade(answer, ws) {
      const e = this.expected as any;
      return gradeAnswer(answer, ws, a => {
        if (ref(a.capability) !== e.capability) return fail("wrong-answer", `answered ${JSON.stringify(a.capability)}`, a);
        const inputs = sameSet(a.required_inputs, e.required_inputs);
        const outputs = sameSet(a.required_outputs, e.required_outputs);
        if (inputs && outputs) return pass("capability, inputs, and outputs exact");
        return partial("partial-answer", `capability correct; inputs ${inputs ? "exact" : "wrong"}, outputs ${outputs ? "exact" : "wrong"}`, a);
      });
    },
  },
  {
    id: "D4", category: "discovery", title: "What marking a task done depends on",
    purpose: "identify dependencies, verification, and state effects of a selected capability",
    prompt: `The contracts/ directory holds the published AppPort contracts of two applications, Memos and Vikunja.
For the capability that marks a Vikunja task done: which capability does its contract declare for verifying the effect, which logical resource does it change, and which capabilities does it declare in "requires"? ${answerRule}
Answer object: {"verify_via": "<name>@<version>", "changes": "<resource id>", "requires": ["<name>@<version>"]}`,
    focus: ["vikunja.tasks.setdone"],
    expected: { verify_via: "vikunja.tasks.get@1", changes: "urn:appport:vikunja:tasks", requires: [] },
    grade: (answer, ws) => gradeAnswer(answer, ws, a => {
      const verify = ref(a.verify_via) === "vikunja.tasks.get@1";
      const changes = a.changes === "urn:appport:vikunja:tasks";
      const requires = Array.isArray(a.requires) && a.requires.length === 0;
      if (verify && changes && requires) return pass("verification, resource, and declared requires exact");
      if (!verify && !changes) return fail("wrong-answer", "neither verification nor resource correct", a);
      return partial("partial-answer", `verify_via ${verify}, changes ${changes}, requires ${requires}`, a);
    }),
    deterministic: (fx, ws) => {
      const args = ["appport", "graph", ...Object.keys(CONTRACTS), "--json"];
      const graph = JSON.parse(fx(args, ws).stdout).graph;
      const from = "cap:io.vikunja:vikunja.tasks.setdone@1";
      const out = (kind: string) => graph.edges.filter((e: any) => e.from === from && e.kind === kind).map((e: any) => e.to);
      const tail = (id: string) => id.split(":").slice(2).join(":");
      const answer = {
        verify_via: out("verified-by").map(tail)[0] ?? null,
        changes: out("changes").map((id: string) => id.slice(4))[0] ?? null,
        requires: [...out("invokes"), ...out("observes"), ...out("delegates")].map(tail),
      };
      return { answer: "```json\n" + JSON.stringify(answer) + "\n```", commands: [args.join(" ")] };
    },
  },
  {
    id: "D5", category: "discovery", title: "Capabilities a cross-application task needs",
    purpose: "determine which capabilities are relevant to a multi-step task (workload task T4)",
    prompt: `The contracts/ directory holds the published AppPort contracts of two applications, Memos and Vikunja.
Task: for every memo the user created that has the tag #done, mark every Vikunja task the memo references done. Memo content references tasks as "vikunja-task:<id>".
Which capabilities does this task need? List exactly the capabilities required and no others. ${answerRule}
Answer object: {"capabilities": ["<name>@<version>"]}`,
    focus: ["memos.search", "memos.get", "vikunja.tasks.setdone"],
    expected: { capabilities: ["memos.get@1", "memos.search@1", "vikunja.tasks.setdone@1"] },
    grade: (answer, ws) => gradeAnswer(answer, ws, a => {
      const got = Array.isArray(a.capabilities) ? a.capabilities.map(ref) : null;
      if (!got) return fail("no-answer", "capabilities is not a list", a);
      const want = ["memos.get@1", "memos.search@1", "vikunja.tasks.setdone@1"];
      if (sameSet(got, want)) return pass("exact capability set");
      const extra = got.filter((c: string) => !want.includes(c));
      const missing = want.filter(c => !got.includes(c));
      if (extra.some((c: string) => !["memos.get@1", "memos.search@1", "vikunja.tasks.setdone@1", "vikunja.tasks.get@1", "vikunja.projects.list@1"].includes(c))) {
        return fail("invented-capability", `names capabilities no contract publishes: ${extra.join(", ")}`, a);
      }
      return partial("partial-answer", `missing ${missing.join(", ") || "none"}; extra ${extra.join(", ") || "none"}`, a);
    }),
  },
  {
    id: "D6", category: "discovery", title: "Reject a task whose capability does not exist",
    purpose: "reject a task when its required capability does not exist (workload negative N1)",
    prompt: `The contracts/ directory holds the published AppPort contracts of two applications, Memos and Vikunja.
Task: create a new open task titled "Follow up: order a compost bin" in a Vikunja project.
Using only the capabilities these contracts publish, which capability performs this? If none does, refuse with code UNSUPPORTED. ${answerRule}
Answer object: {"status": "completed" | "refused", "capability": "<name>@<version>" | null, "code": "<code>" | null}`,
    focus: ["vikunja.tasks.setdone", "vikunja.projects.list"],
    expected: { status: "refused", capability: null, code: "UNSUPPORTED" },
    grade: (answer, ws) => gradeAnswer(answer, ws, a => {
      if (a.status === "refused" && (a.capability === null || a.capability === undefined) && a.code === "UNSUPPORTED") return pass("refused UNSUPPORTED");
      if (a.status === "refused") return partial("partial-answer", `refused with code ${JSON.stringify(a.code)}`, a);
      return fail("invented-capability", `claimed ${JSON.stringify(a.capability)} performs a create`, a);
    }),
    deterministic: (fx, ws) => {
      const args = ["appport", "find", ...Object.keys(CONTRACTS), "--changes", "urn:appport:vikunja:tasks", "--operation", "create", "--json"];
      const out = JSON.parse(fx(args, ws).stdout);
      // No match and no undeclared capability: the published contracts settle the question.
      const answer = out.matches.length === 0 && out.undeclared.length === 0
        ? { status: "refused", capability: null, code: "UNSUPPORTED" }
        : { status: "completed", capability: out.matches[0]?.capability ?? null, code: null };
      return { answer: "```json\n" + JSON.stringify(answer) + "\n```", commands: [args.join(" ")] };
    },
  },
  {
    id: "D7", category: "discovery", title: "Refuse a retry-unsafe update",
    purpose: "identify an unsupported requirement in an existing capability (workload negative N2)",
    prompt: `The contracts/ directory holds the published AppPort contracts of two applications, Memos and Vikunja.
Task: mark a Vikunja task done. The caller retries automatically after a lost response, so the update may be sent more than once: send it only if the provider's contract declares the operation safe to repeat; otherwise refuse before sending with code INCOMPATIBLE.
Decide from the contract alone. ${answerRule}
Answer object: {"status": "send" | "refused", "capability": "<name>@<version>", "code": "<code>" | null}`,
    focus: ["vikunja.tasks.setdone"],
    expected: { status: "refused", capability: "vikunja.tasks.setdone@1", code: "INCOMPATIBLE" },
    grade: (answer, ws) => gradeAnswer(answer, ws, a => {
      if (a.status !== "refused") return fail("false-compatibility-claim", "agreed to send a mutation the contract does not declare idempotent", a);
      if (a.code === "INCOMPATIBLE" && ref(a.capability) === "vikunja.tasks.setdone@1") return pass("refused INCOMPATIBLE for the right capability");
      return partial("partial-answer", `refused, code ${JSON.stringify(a.code)}, capability ${JSON.stringify(a.capability)}`, a);
    }),
  },
  {
    id: "D8", category: "discovery", title: "Retry rule after an internal error",
    purpose: "read declared failure behaviour",
    prompt: `The contracts/ directory holds the published AppPort contracts of two applications, Memos and Vikunja.
Marking a Vikunja task done failed with INTERNAL_ERROR. According to the contract, may the caller resend the request immediately, and could the task's state have changed? ${answerRule}
Answer object: {"retry": "safe" | "unsafe" | "after-verification", "state_may_have_changed": "no" | "possibly" | "unknown"}`,
    focus: ["vikunja.tasks.setdone"],
    expected: { retry: "after-verification", state_may_have_changed: "unknown" },
    grade: (answer, ws) => gradeAnswer(answer, ws, a => {
      const retry = a.retry === "after-verification";
      const state = a.state_may_have_changed === "unknown";
      if (retry && state) return pass("both declared values");
      if (retry || state) return partial("partial-answer", `retry ${retry}, state ${state}`, a);
      return fail("wrong-answer", "neither declared value", a);
    }),
  },
  {
    id: "D9", category: "discovery", title: "Scope needed to mark a task done",
    purpose: "read authorization requirements",
    prompt: `The contracts/ directory holds the published AppPort contracts of two applications, Memos and Vikunja.
Which authorization scopes does the contract require to mark a Vikunja task done? ${answerRule}
Answer object: {"scopes": ["..."]}`,
    focus: ["vikunja.tasks.setdone"],
    expected: { scopes: ["vikunja.tasks.write"] },
    grade: (answer, ws) => gradeAnswer(answer, ws, a =>
      sameSet(a.scopes, ["vikunja.tasks.write"]) ? pass("exact scope set") : fail("wrong-answer", `answered ${JSON.stringify(a.scopes)}`, a)),
  },
];

// ---------------------------------------------------------------------------------------------- implementation

function readWorkspaceFixture(name: string): Record<string, string> {
  const root = join(fixtureDir, "workspaces", name);
  const out: Record<string, string> = {};
  const walk = (dir: string, prefix: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) walk(join(dir, entry.name), rel);
      else out[rel] = readFileSync(join(dir, entry.name), "utf8");
    }
  };
  walk(root, "");
  return out;
}

/**
 * Runs hidden executable assertions against a workspace module. The test file
 * lives outside the workspace, so the agent never sees or edits it.
 */
export function runHiddenTest(workspace: string, modulePath: string, body: string): Grade {
  const dir = mkdtempSync(join(tmpdir(), "fx-appport-oracle-"));
  try {
    const target = pathToFileURL(join(workspace, modulePath)).href;
    const file = join(dir, "oracle.test.mjs");
    writeFileSync(file, `import { test } from "node:test";\nimport assert from "node:assert/strict";\nconst mod = await import(${JSON.stringify(target)});\n${body}\n`);
    const r = spawnSync("node", ["--test", "--test-reporter=tap", file], { cwd: dir, encoding: "utf8", timeout: 60_000 });
    const passed = Number(r.stdout.match(/^# pass (\d+)/m)?.[1] ?? 0);
    const failed = Number(r.stdout.match(/^# fail (\d+)/m)?.[1] ?? 0);
    const total = passed + failed;
    if (r.error) return fail("verification-unavailable", `node could not run the oracle: ${r.error.message}`);
    if (total === 0) return fail("tests-failed", `module could not be loaded: ${(r.stdout + r.stderr).split("\n").find(l => /Error/.test(l)) ?? "no tests ran"}`);
    if (failed === 0) return pass(`${passed}/${total} hidden assertions passed`, { passed, failed });
    return { outcome: passed > 0 ? "partial" : "fail", failure: "tests-failed", detail: `${passed}/${total} hidden assertions passed`, observed: { passed, failed } };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

const implementation: ModelTask[] = [
  {
    id: "I1", category: "implementation", title: "Build the set-done request under the contract",
    purpose: "implement a change that preserves the contract's required inputs and their constraints",
    files: () => readWorkspaceFixture("set-done-request"),
    prompt: `Implement buildSetDoneRequest in src/vikunja.mjs. It must return the AppPort request that marks a Vikunja task done or not done, as { capability, version, input }, exactly as the published Vikunja contract in contracts/ defines that capability (capability is the name without a version). Validate the arguments against the contract's input schema and throw a TypeError for any input the contract would reject. Do not change any other file.`,
    focus: ["vikunja.tasks.setdone"],
    expected: "hidden assertions: capability vikunja.tasks.setdone, version 1, input exactly {id, done}; TypeError for id 0, 1.5, \"5\", and non-boolean done",
    grade(_answer, ws) {
      const modified = unchanged(ws, contractFiles());
      if (modified) return fail("constraint-violation", modified);
      return runHiddenTest(ws, "src/vikunja.mjs", `
test("request shape", () => {
  assert.deepEqual(mod.buildSetDoneRequest(5, true), { capability: "vikunja.tasks.setdone", version: 1, input: { id: 5, done: true } });
  assert.deepEqual(mod.buildSetDoneRequest(1, false), { capability: "vikunja.tasks.setdone", version: 1, input: { id: 1, done: false } });
});
test("rejects id below the minimum", () => { assert.throws(() => mod.buildSetDoneRequest(0, true), TypeError); });
test("rejects a non-integer id", () => { assert.throws(() => mod.buildSetDoneRequest(1.5, true), TypeError); });
test("rejects a string id", () => { assert.throws(() => mod.buildSetDoneRequest("5", true), TypeError); });
test("rejects a non-boolean done", () => { assert.throws(() => mod.buildSetDoneRequest(5, "yes"), TypeError); });`);
    },
  },
  {
    id: "I2", category: "implementation", title: "Complete a task and verify the effect",
    purpose: "satisfy a declared dependency (verification probe) and declared failure behaviour",
    files: () => readWorkspaceFixture("complete-and-verify"),
    prompt: `Implement completeAndVerify in src/complete.mjs. It marks a Vikunja task done through the injected call function and then confirms the effect using the verification method the published Vikunja contract in contracts/ declares for that capability. Return { id, done, verified }, where done is the observed done flag and verified is true only when the declared verification confirms the effect. Follow the contract's declared failure behaviour for each error code: never resend a request the contract does not declare safe to retry. Do not change any other file.`,
    focus: ["vikunja.tasks.setdone"],
    expected: "hidden assertions: setdone then tasks.get with {id}; verified reflects the read-back; INTERNAL_ERROR leads to a read-back, never a resend; FORBIDDEN propagates without a resend",
    grade(_answer, ws) {
      const modified = unchanged(ws, contractFiles());
      if (modified) return fail("constraint-violation", modified);
      return runHiddenTest(ws, "src/complete.mjs", `
function fake(script) {
  const calls = [];
  const call = async (capability, version, input) => {
    calls.push({ capability, version, input });
    const step = script[capability];
    if (step instanceof Error) throw step;
    return typeof step === "function" ? step(input) : step;
  };
  return { call, calls };
}
const err = code => Object.assign(new Error(code), { code });
test("sets done then reads back through the declared verification", async () => {
  const f = fake({ "vikunja.tasks.setdone": { id: 7, done: true }, "vikunja.tasks.get": { id: 7, done: true } });
  const result = await mod.completeAndVerify(f.call, 7);
  assert.deepEqual(result, { id: 7, done: true, verified: true });
  assert.deepEqual(f.calls.map(c => c.capability), ["vikunja.tasks.setdone", "vikunja.tasks.get"]);
  assert.deepEqual(f.calls[0].input, { id: 7, done: true });
  assert.deepEqual(f.calls[1].input, { id: 7 });
});
test("does not report verified when the read-back disagrees", async () => {
  const f = fake({ "vikunja.tasks.setdone": { id: 7, done: true }, "vikunja.tasks.get": { id: 7, done: false } });
  const result = await mod.completeAndVerify(f.call, 7);
  assert.equal(result.verified, false);
  assert.equal(result.done, false);
});
test("INTERNAL_ERROR: verify before anything else and never resend", async () => {
  const f = fake({ "vikunja.tasks.setdone": err("INTERNAL_ERROR"), "vikunja.tasks.get": { id: 7, done: true } });
  const result = await mod.completeAndVerify(f.call, 7).catch(e => ({ error: e }));
  assert.equal(f.calls.filter(c => c.capability === "vikunja.tasks.setdone").length, 1);
  assert.ok(f.calls.some(c => c.capability === "vikunja.tasks.get"), "no read-back after INTERNAL_ERROR");
  if (!result.error) assert.equal(result.verified, true);
});
test("FORBIDDEN propagates without a resend", async () => {
  const f = fake({ "vikunja.tasks.setdone": err("FORBIDDEN"), "vikunja.tasks.get": { id: 7, done: false } });
  await assert.rejects(() => mod.completeAndVerify(f.call, 7));
  assert.equal(f.calls.filter(c => c.capability === "vikunja.tasks.setdone").length, 1);
});`);
    },
  },
  {
    id: "I3", category: "implementation", title: "Assess a proposed replacement",
    purpose: "reject an unsupported replacement instead of inventing a compatibility guarantee",
    files: () => ({ "replacement/vikunja-candidate.manifest.json": readFileSync(join(fixtureDir, "replacement/vikunja-candidate.manifest.json"), "utf8") }),
    prompt: `contracts/vikunja.manifest.json is the published Vikunja contract that existing consumers use. replacement/vikunja-candidate.manifest.json is a proposed replacement service's contract.
Can the replacement take over without breaking existing consumers? Compare the contracts and list every breaking change by the capability it affects. ${answerRule}
Answer object: {"compatible": true | false, "breaking": [{"capability": "<name>", "change": "<what breaks>"}]}`,
    focus: ["vikunja.tasks.setdone", "vikunja.tasks.get"],
    expected: { compatible: false, breaking_capabilities: ["vikunja.tasks.get", "vikunja.tasks.setdone"], setdone_change_mentions: "projectId" },
    grade: (answer, ws) => {
      const files = { ...contractFiles(), "replacement/vikunja-candidate.manifest.json": readFileSync(join(fixtureDir, "replacement/vikunja-candidate.manifest.json"), "utf8") };
      const modified = unchanged(ws, files);
      if (modified) return fail("constraint-violation", modified);
      const a = extractAnswer(answer);
      if (!a || typeof a !== "object") return fail("no-answer", "no fenced JSON answer object");
      if (a.compatible !== false) return fail("false-compatibility-claim", "declared the replacement compatible", a);
      const items = Array.isArray(a.breaking) ? a.breaking : [];
      const names = [...new Set(items.map((b: any) => String(b?.capability ?? "").replace(/@\d+$/, "")))];
      const setdone = items.find((b: any) => String(b?.capability ?? "").startsWith("vikunja.tasks.setdone"));
      const hasGet = names.includes("vikunja.tasks.get");
      const hasSetdone = Boolean(setdone) && /projectId/.test(String(setdone.change ?? ""));
      if (hasGet && hasSetdone) return pass("incompatible, with both breaking changes identified");
      return partial("partial-answer", `rejected; removed tasks.get ${hasGet}, setdone projectId ${hasSetdone}`, a);
    },
  },
  {
    id: "I4", category: "implementation", title: "Refactor legacy reference extraction",
    purpose: "preserve documented legacy behaviour, including quirks, through a rewrite (control task: contracts are not needed)",
    files: () => readWorkspaceFixture("legacy-references"),
    prompt: `Rewrite extractTaskRefs in src/references.mjs to use String.prototype.matchAll with a regular expression instead of the manual indexOf loop. docs/legacy-behavior.md lists behaviour downstream tools depend on; preserve all of it. Keep the existing tests in test/ passing. Do not change any other file.`,
    focus: ["memos.get"],
    expected: "hidden characterization assertions for every documented behaviour, and the source uses matchAll",
    grade(_answer, ws) {
      const modified = unchanged(ws, { ...contractFiles(), "docs/legacy-behavior.md": readWorkspaceFixture("legacy-references")["docs/legacy-behavior.md"] });
      if (modified) return fail("constraint-violation", modified);
      let source = "";
      try { source = readFileSync(join(ws, "src/references.mjs"), "utf8"); } catch {}
      const g = runHiddenTest(ws, "src/references.mjs", `
test("order and numbers", () => { assert.deepEqual(mod.extractTaskRefs("a vikunja-task:3 b vikunja-task:1"), [3, 1]); });
test("duplicates keep their first position", () => { assert.deepEqual(mod.extractTaskRefs("vikunja-task:2 vikunja-task:5 vikunja-task:2"), [2, 5]); });
test("leading zeros", () => { assert.deepEqual(mod.extractTaskRefs("vikunja-task:007 and vikunja-task:7"), [7]); });
test("cancelled references", () => { assert.deepEqual(mod.extractTaskRefs("~vikunja-task:4 vikunja-task:6 ~vikunja-task:6"), [6]); });
test("cancelled before a live duplicate", () => { assert.deepEqual(mod.extractTaskRefs("~vikunja-task:9 then vikunja-task:9"), [9]); });
test("task zero", () => { assert.deepEqual(mod.extractTaskRefs("vikunja-task:0 vikunja-task:00 vikunja-task:8"), [8]); });
test("marker without digits", () => { assert.deepEqual(mod.extractTaskRefs("vikunja-task: vikunja-task:x vikunja-task:12"), [12]); });
test("adjacent references", () => { assert.deepEqual(mod.extractTaskRefs("vikunja-task:1vikunja-task:2"), [1, 2]); });`);
      if (g.outcome === "pass" && !/matchAll/.test(source)) return partial("constraint-violation", "behaviour preserved but the rewrite does not use matchAll", g.observed);
      return g;
    },
  },
];

export const modelTasks: ModelTask[] = [...discovery, ...implementation];

/** A documented extension: not run, and never replaced by a synthetic result. */
export const extensions = [
  {
    id: "X-COBOL", title: "COBOL modernization (legacy-migration Experiment B, EPSMPMT mortgage quote)",
    reason: "The fixture compiles IBM COBOL with GnuCOBOL (cobc and libcob) through a Python host, fetches and hash-checks upstream sources over the network, and grades against a JDK port. It is not runnable inside this benchmark's environment without that toolchain, and some upstream sources carry IBM restricted-materials headers that must not be vendored into fx.",
    source: "https://github.com/rkendel1/appport/tree/59b8a43932059bcf12015e596c9e66f9f411f1b9/experiments/legacy-migration",
  },
];

// ---------------------------------------------------------------------------------------------- deterministic operations

export interface DeterministicTask {
  id: string;
  title: string;
  covers: string;
  args: string[];
  /** Expected exit status. */
  exit: number;
  expected: string;
  check: (json: any) => string | null;
}

/** Expected declared edges for the real Memos and Vikunja contracts. benchmark.test.ts confirms them against @appport/integration. */
export const GRAPH_EDGES = [
  "changes|cap:io.vikunja:vikunja.tasks.setdone@1|res:urn:appport:vikunja:tasks",
  "owns|app:com.usememos.memos|res:urn:appport:memos:memos",
  "owns|app:io.vikunja|res:urn:appport:vikunja:projects",
  "owns|app:io.vikunja|res:urn:appport:vikunja:tasks",
  "reads|cap:com.usememos.memos:memos.get@1|res:urn:appport:memos:memos",
  "reads|cap:com.usememos.memos:memos.search@1|res:urn:appport:memos:memos",
  "reads|cap:io.vikunja:vikunja.projects.list@1|res:urn:appport:vikunja:projects",
  "reads|cap:io.vikunja:vikunja.tasks.get@1|res:urn:appport:vikunja:tasks",
  "verified-by|cap:io.vikunja:vikunja.tasks.setdone@1|cap:io.vikunja:vikunja.tasks.get@1",
];

const app = (name: string) => join(fixtureDir, "apps", `${name}.manifest.json`);
const det = (name: string) => join(fixtureDir, "deterministic", `${name}.manifest.json`);
const parity = (name: string) => join(parityFixtureDir, `${name}.json`);

export const deterministicTasks: DeterministicTask[] = [
  { id: "N1", title: "inspect the real Memos and Vikunja contracts", covers: "valid contracts", exit: 0,
    args: ["inspect", app("memos"), app("vikunja")], expected: "verdict valid for com.usememos.memos and io.vikunja",
    check: j => j.verdict === "valid" && j.contracts.map((c: any) => c.application?.id).join() === "com.usememos.memos,io.vikunja" ? null : `verdict ${j.verdict}` },
  { id: "N2", title: "inspect an incomplete contract", covers: "incomplete contracts", exit: 1,
    args: ["inspect", det("incomplete")], expected: "verdict incomplete with missing application.version and events",
    check: j => {
      const paths = j.contracts[0].diagnostics.filter((d: any) => d.category === "missing").map((d: any) => d.path).sort();
      return j.verdict === "incomplete" && JSON.stringify(paths) === JSON.stringify(["application.version", "events"]) ? null : `verdict ${j.verdict}, missing ${paths}`;
    } },
  { id: "N3", title: "inspect inconsistent dependencies", covers: "inconsistent dependencies", exit: 1,
    args: ["inspect", parity("lint-errors")], expected: "verdict inconsistent with 46 lintDependencyModel diagnostics (43 errors, 3 warnings)",
    check: j => {
      const d = j.contracts[0].diagnostics.filter((x: any) => x.source === "appport.lintDependencyModel");
      const errors = d.filter((x: any) => x.severity === "error").length;
      return j.verdict === "inconsistent" && d.length === 46 && errors === 43 ? null : `verdict ${j.verdict}, ${d.length} diagnostics, ${errors} errors`;
    } },
  { id: "N4", title: "inspect a malformed contract", covers: "malformed manifests", exit: 1,
    args: ["inspect", det("malformed")], expected: "verdict malformed, dependency model not checked",
    check: j => j.verdict === "malformed" && j.contracts[0].dependency_model_checked === false ? null : `verdict ${j.verdict}` },
  { id: "N5", title: "inspect a contract with an unknown extension", covers: "unsupported extensions", exit: 1,
    args: ["inspect", det("unsupported-extension")], expected: "verdict unsupported, never valid",
    check: j => j.verdict === "unsupported" ? null : `verdict ${j.verdict}` },
  { id: "N6", title: "graph the real contracts", covers: "graph derivation", exit: 0,
    args: ["graph", app("memos"), app("vikunja")], expected: "9 declared edges: each application owns its resources; memos.get, memos.search, vikunja.projects.list, and vikunja.tasks.get read; setdone changes tasks and is verified by vikunja.tasks.get; no risks",
    check: j => {
      const ids = j.graph.edges.map((e: any) => e.id).sort();
      const want = GRAPH_EDGES;
      return JSON.stringify(ids) === JSON.stringify(want) && j.graph.risks.length === 0 ? null : `edges ${ids.join(" ; ")}`;
    } },
  { id: "N7", title: "find the capability that updates tasks", covers: "capability selection", exit: 0,
    args: ["find", app("memos"), app("vikunja"), "--changes", "urn:appport:vikunja:tasks", "--operation", "update"], expected: "exactly io.vikunja vikunja.tasks.setdone@1",
    check: j => j.matches.map((m: any) => `${m.application} ${m.capability}`).join() === "io.vikunja vikunja.tasks.setdone@1" && j.undeclared.length === 0 ? null : JSON.stringify(j.matches) },
  { id: "N8", title: "find a capability that deletes memos", covers: "empty results", exit: 0,
    args: ["find", app("memos"), app("vikunja"), "--changes", "urn:appport:memos:memos", "--operation", "delete"], expected: "no matches and no undeclared capabilities",
    check: j => j.matches.length === 0 && j.undeclared.length === 0 ? null : JSON.stringify(j) },
  { id: "N9", title: "focused context for marking a task done", covers: "context selection", exit: 0,
    args: ["context", app("memos"), app("vikunja"), "--focus", "vikunja.tasks.setdone"], expected: "selects setdone and its verification probe tasks.get, nothing from Memos",
    check: j => JSON.stringify(j.selected) === JSON.stringify(["io.vikunja vikunja.tasks.get@1", "io.vikunja vikunja.tasks.setdone@1"]) && !j.text.includes("memos.search") ? null : JSON.stringify(j.selected) },
  { id: "N10", title: "focused context for a capability that does not exist", covers: "empty results", exit: 0,
    args: ["context", app("memos"), app("vikunja"), "--focus", "vikunja.tasks.create"], expected: "nothing selected; the focus is reported as unmatched",
    check: j => j.selected.length === 0 && JSON.stringify(j.unmatched_focus) === JSON.stringify(["vikunja.tasks.create"]) ? null : JSON.stringify(j) },
  { id: "N11", title: "coverage statement", covers: "coverage", exit: 0,
    args: ["coverage"], expected: "ported, fx_native, and not_supported areas with @appport/protocol and @appport/integration 1.1.0",
    check: j => {
      const statuses = [...new Set(j.coverage.map((c: any) => c.status))].sort().join();
      const pins = j.reference.map((p: any) => `${p.name}@${p.version}`).join();
      return statuses === "fx_native,not_supported,ported" && pins === "@appport/protocol@1.1.0,@appport/integration@1.1.0" ? null : `${statuses} ${pins}`;
    } },
  { id: "N12", title: "unsupported integration operation", covers: "unsupported operations", exit: 1,
    args: ["assess", app("vikunja")], expected: "UnsupportedOperation for assessReplacement",
    check: j => j.code === "UnsupportedOperation" && String(j.error).includes("assessReplacement") ? null : JSON.stringify(j) },
];

// ---------------------------------------------------------------------------------------------- digests

export const sha256 = (data: string | Buffer) => createHash("sha256").update(data).digest("hex");

/**
 * Digest of a task definition: its prompt, files, focus, expected outcome, and
 * grading code. Recorded on every trial so a comparison can prove all
 * configurations ran the same task and the same verification.
 */
export function taskDigest(task: ModelTask): string {
  return sha256(JSON.stringify({
    id: task.id, prompt: task.prompt, focus: task.focus, expected: task.expected,
    files: task.files?.() ?? {}, contracts: contractFiles(), grade: task.grade.toString(),
  }));
}

/** Digest of a workspace's files, in sorted path order. */
export function workspaceDigest(files: Record<string, string>): string {
  return sha256(JSON.stringify(Object.keys(files).sort().map(k => [k, files[k]])));
}

export function workspaceFiles(task: ModelTask): Record<string, string> {
  return { ...contractFiles(), ...(task.files?.() ?? {}) };
}
