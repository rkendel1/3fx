// A scripted provider for the harness self-tests. It drives the real fx
// binary through the same trial code path as a configured provider, so the
// tests can check the harness, the configurations, and the oracles without a
// model. Scripted trials are labelled and never count as model results.

import { completion, toolCompletion, createConfiguredProviderFixture as fixture } from "../e2e/fixtures/chat-completions";
import { detectProvider, type Provider } from "./harness";
import { modelTasks, type ModelTask } from "./tasks";

/** Correct answers and reference implementations for every model task. */
export const REFERENCE_SOLUTIONS: Record<string, { answer?: unknown; files?: Record<string, string> }> = {
  D1: { answer: { capability: "vikunja.tasks.setdone@1" } },
  D2: { answer: { capability: "memos.search@1" } },
  D3: { answer: { capability: "vikunja.tasks.get@1", required_inputs: ["id"], required_outputs: ["id", "title", "description", "projectId", "done", "doneAt", "dueDate", "priority", "percentDone", "identifier", "createdBy", "created", "updated"] } },
  D4: { answer: { verify_via: "vikunja.tasks.get@1", changes: "urn:appport:vikunja:tasks", requires: [] } },
  D5: { answer: { capabilities: ["memos.search@1", "memos.get@1", "vikunja.tasks.setdone@1"] } },
  D6: { answer: { status: "refused", capability: null, code: "UNSUPPORTED" } },
  D7: { answer: { status: "refused", capability: "vikunja.tasks.setdone@1", code: "INCOMPATIBLE" } },
  D8: { answer: { retry: "after-verification", state_may_have_changed: "unknown" } },
  D9: { answer: { scopes: ["vikunja.tasks.write"] } },
  I1: { files: { "src/vikunja.mjs": `export function buildSetDoneRequest(taskId, done) {
  if (!Number.isInteger(taskId) || taskId < 1 || taskId > 9007199254740991) throw new TypeError("id must be an integer from 1");
  if (typeof done !== "boolean") throw new TypeError("done must be a boolean");
  return { capability: "vikunja.tasks.setdone", version: 1, input: { id: taskId, done } };
}
` } },
  I2: { files: { "src/complete.mjs": `export async function completeAndVerify(call, id) {
  try {
    await call("vikunja.tasks.setdone", 1, { id, done: true });
  } catch (error) {
    // INTERNAL_ERROR: retry only after verification, and the state is unknown. Every other code is unsafe to retry.
    if (error?.code !== "INTERNAL_ERROR") throw error;
  }
  const task = await call("vikunja.tasks.get", 1, { id });
  return { id, done: task.done, verified: task.done === true };
}
` } },
  I3: { answer: { compatible: false, breaking: [{ capability: "vikunja.tasks.get", change: "removed" }, { capability: "vikunja.tasks.setdone@1", change: "new required input projectId" }] } },
  I4: { files: { "src/references.mjs": `export function extractTaskRefs(text) {
  const seen = new Set();
  const refs = [];
  for (const match of text.matchAll(/(~?)vikunja-task:(\\d+)/g)) {
    if (match[1]) continue;
    const id = Number(match[2]);
    if (id > 0 && !seen.has(id)) {
      seen.add(id);
      refs.push(id);
    }
  }
  return refs;
}
` } },
};

/** Wrong answers that still claim success, to prove the oracles ignore claims. */
export const WRONG_BUT_CONFIDENT: Record<string, unknown> = {
  D1: { capability: "vikunja.tasks.get@1" },
  D2: { capability: "memos.get@1" },
  D3: { capability: "vikunja.tasks.get@1", required_inputs: ["id", "projectId"], required_outputs: ["id"] },
  D4: { verify_via: "memos.get@1", changes: "urn:appport:memos:memos", requires: ["vikunja.tasks.get@1"] },
  D5: { capabilities: ["vikunja.tasks.create@1"] },
  D6: { status: "completed", capability: "vikunja.tasks.create@1", code: null },
  D7: { status: "send", capability: "vikunja.tasks.setdone@1", code: null },
  D8: { retry: "safe", state_may_have_changed: "no" },
  D9: { scopes: ["vikunja.read"] },
  I3: { compatible: true, breaking: [] },
};

export type Behaviour = "correct" | "wrong" | "no-usage" | "request-error" | "provider-unavailable";

export function taskForBody(body: any): ModelTask | undefined {
  const user = [...body.messages].reverse().find((m: any) => m.role === "user");
  const text = typeof user?.content === "string" ? user.content : JSON.stringify(user?.content ?? "");
  return modelTasks.find(t => text.includes(t.prompt));
}

const isReview = (body: any) => body.tools?.length === 1 && body.tools[0]?.function?.name === "permission_decision";

function completionWithoutUsage(model: string, text: string) {
  const chunks = [
    { id: "chat-local", model, choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: null }] },
    { id: "chat-local", model, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
  ];
  return new Response(chunks.map(v => `data: ${JSON.stringify(v)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
}

/**
 * Starts a scripted provider. `behaviour(taskId)` decides each task's script.
 * Every request body is recorded so tests can inspect what each configuration sent.
 */
export async function scriptedProvider(behaviour: (taskId: string) => Behaviour = () => "correct") {
  const f = fixture(body => {
    if (isReview(body)) return toolCompletion(body.model, "permission_decision", { decision: "clear" }, "review");
    const task = taskForBody(body);
    if (!task) return completion(body.model, "unknown task");
    const mode = behaviour(task.id);
    // 400 fails the request at once; fx retries a 500 until the trial times out.
    if (mode === "request-error" || mode === "provider-unavailable") {
      return new Response(JSON.stringify({ error: { message: "scripted failure" } }), { status: mode === "request-error" ? 400 : 500, headers: { "content-type": "application/json" } });
    }
    const solution = REFERENCE_SOLUTIONS[task.id];
    const turns = body.messages.filter((m: any) => m.role === "tool").length;
    if (mode !== "wrong" && solution.files && turns < Object.keys(solution.files).length) {
      const [path, content] = Object.entries(solution.files)[turns];
      return toolCompletion(body.model, "write_file", { path, content }, `call-${turns + 1}`);
    }
    const answer = mode === "wrong" ? WRONG_BUT_CONFIDENT[task.id] : solution.answer;
    const text = answer === undefined
      ? "Implemented the change and verified it: all tests pass. SUCCESS."
      : `Verified against the contract. SUCCESS.\n\n\`\`\`json\n${JSON.stringify(answer)}\n\`\`\``;
    return mode === "no-usage" ? completionWithoutUsage(body.model, text) : completion(body.model, text, 50);
  });
  const env = { ...f.env } as Record<string, string | undefined>;
  const probe = await detectProvider(env);
  if (!probe.available) { f.close(); throw new Error(`scripted provider unavailable: ${probe.reason}`); }
  const provider: Provider = { kind: "scripted", env, identity: probe.identity };
  return { provider, requests: f.requests, close: () => f.close() };
}
