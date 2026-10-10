// Request-context experiment: the same eight tasks under different advertised tool sets.
//
//   cd tests/e2e && bun ../../benchmarks/sequencing/context.ts [--repeats N] [--json]
//
// The "model" is a mock that follows a fixed policy and adapts to the tools it is offered.
// It can show protocol behavior (counts, bytes, truthful failure) but NOT whether a real
// model would pick the right tool from a smaller schema. Success criteria are defined here,
// before any comparison, and are identical across conditions.
import { join } from "node:path";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { toolCompletion, completion } from "../../tests/e2e/fixtures/chat-completions";
import { runScenario, type Scenario } from "./lib";

/**
 * Experimental environment per condition. `baseline` sets nothing: the production request, which now
 * advertises only what the execution path can run (no web search for a provider that cannot execute it,
 * no MCP tools or guidance without an MCP server). The allowlist conditions are separate experiments.
 */
export const CONDITIONS: Record<string, Record<string, string>> = {
  baseline: {},
  core6: { FX_EXPERIMENTAL_TOOL_ALLOWLIST: "read_file,glob_files,grep_files,edit_file,write_file,shell" },
  min4: { FX_EXPERIMENTAL_TOOL_ALLOWLIST: "read_file,edit_file,write_file,shell" },
};

const has = (b: any, name: string) => (b.tools ?? []).some((t: any) => t.function.name === name);
const toolResults = (b: any): string[] => b.messages.filter((m: any) => m.role === "tool").map((m: any) => String(m.content));
const sh = (command: string) => ({ request: { action: "run", command } });
const M = (b: any) => b.model;

export interface Task extends Scenario {
  /** Tool the task is designed to use when it is offered. */
  preferred?: string;
  /** Success predicate over the run result and workspace. */
  success: (r: any, ws: string) => boolean;
  /** Expected behavior when the preferred tool is unavailable: another tool suffices, or a truthful failure. */
  withoutPreferred: "adapts" | "truthful_failure";
}

export const tasks: Task[] = [
  { id: "C1", title: "no tools needed", preferred: undefined, withoutPreferred: "adapts",
    respond: (n, b) => completion(M(b), "Hello.", 20),
    success: r => r.exit === 0 && r.output === "Hello." && r.executed === 0 },
  { id: "C2", title: "one read-only tool", preferred: "read_file", withoutPreferred: "adapts",
    prepare: ws => writeFileSync(join(ws, "a.txt"), "alpha\n"),
    respond: (n, b) => {
      if (n === 1) return has(b, "read_file") ? toolCompletion(M(b), "read_file", { path: "a.txt" }) : toolCompletion(M(b), "shell", sh("cat a.txt"));
      return completion(M(b), toolResults(b).some(t => t.includes("alpha")) ? "FOUND alpha" : "NOT FOUND", 20);
    },
    success: r => r.exit === 0 && r.output === "FOUND alpha" && r.executed === 1 },
  { id: "C3", title: "multiple different tools", preferred: "grep_files", withoutPreferred: "adapts",
    prepare: ws => { writeFileSync(join(ws, "a.txt"), "alpha\n"); writeFileSync(join(ws, "b.txt"), "beta needle\n"); },
    respond: (n, b) => {
      if (n === 1) return has(b, "grep_files") ? toolCompletion(M(b), "grep_files", { pattern: "needle" }) : toolCompletion(M(b), "shell", sh("grep -rl needle ."));
      if (n === 2) return has(b, "read_file") ? toolCompletion(M(b), "read_file", { path: "b.txt" }, "call-2") : toolCompletion(M(b), "shell", sh("cat b.txt"), "call-2");
      return completion(M(b), toolResults(b).some(t => t.includes("beta")) ? "Located b.txt beta" : "NOT FOUND", 20);
    },
    success: r => r.exit === 0 && r.output === "Located b.txt beta" && r.executed === 2 },
  { id: "C4", title: "state-changing tool (--auto, reviewed)", preferred: "write_file", withoutPreferred: "adapts", args: ["--auto"],
    respond: (n, b) => {
      if (n === 1) return has(b, "write_file") ? toolCompletion(M(b), "write_file", { path: "out.txt", content: "done\n" }) : toolCompletion(M(b), "shell", sh("echo done > out.txt"));
      return completion(M(b), "Written.", 20);
    },
    success: (r, ws) => r.exit === 0 && existsSync(join(ws, "out.txt")) && readFileSync(join(ws, "out.txt"), "utf8").trim() === "done" },
  { id: "C5", title: "invalid call then correction", preferred: "shell", withoutPreferred: "truthful_failure", args: ["--full-access"],
    respond: (n, b) => n === 1 ? toolCompletion(M(b), "shell", { command: 42 }) : n === 2 ? toolCompletion(M(b), "shell", sh("echo ok > fixed.txt"), "call-2") : completion(M(b), "Fixed.", 20),
    success: (r, ws) => r.exit === 0 && existsSync(join(ws, "fixed.txt")) && r.executed === 1 },
  { id: "C6", title: "failed tool then correction", preferred: "shell", withoutPreferred: "truthful_failure", args: ["--full-access"],
    respond: (n, b) => n === 1 ? toolCompletion(M(b), "shell", sh("ls missing-dir")) : n === 2 ? toolCompletion(M(b), "shell", sh("ls ."), "call-2") : completion(M(b), "Recovered.", 20),
    success: r => r.exit === 0 && r.output === "Recovered." && r.executed === 2 },
  { id: "C7", title: "required tool absent (non-adaptive model)", preferred: "grep_files", withoutPreferred: "truthful_failure",
    prepare: ws => writeFileSync(join(ws, "b.txt"), "needle\n"),
    respond: (n, b) => n === 1 ? toolCompletion(M(b), "grep_files", { pattern: "needle" }) : completion(M(b), "Found.", 20),
    success: r => r.exit === 0 && r.output === "Found." && r.executed === 1 },
  { id: "C8", title: "choose between similar tools", preferred: "glob_files", withoutPreferred: "adapts",
    prepare: ws => { writeFileSync(join(ws, "a.txt"), "a\n"); writeFileSync(join(ws, "b.txt"), "b\n"); },
    respond: (n, b) => {
      if (n === 1) return has(b, "glob_files") ? toolCompletion(M(b), "glob_files", { pattern: "*.txt" }) : toolCompletion(M(b), "shell", sh("ls *.txt"));
      return completion(M(b), toolResults(b).some(t => t.includes("a.txt") && t.includes("b.txt")) ? "Files: a.txt b.txt" : "NOT FOUND", 20);
    },
    success: r => r.exit === 0 && r.output === "Files: a.txt b.txt" && r.executed === 1 },
];

export function runTask(task: Task, condition: string) {
  return runScenario(task, { env: CONDITIONS[condition] });
}

/**
 * A run is correct when the task succeeded, or when its required tool was deliberately removed and the
 * run failed truthfully: non-zero exit, nothing executed, no success claim.
 */
export function outcomeCorrect(task: Task, r: any): boolean {
  if (r.success) return true;
  const absent = task.preferred !== undefined && r.tools_count > 0 && !r.advertised?.includes(task.preferred);
  return absent && task.withoutPreferred === "truthful_failure" && r.exit !== 0 && r.executed === 0;
}
