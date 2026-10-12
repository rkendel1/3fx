// Starts the real authority stack (stack.launch.ts) and talks to its control
// server. Shared by the real-stack integration test and the authority benchmark.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export type Session = { credential: string; principalId: string; tenant: string };
export type StackState = {
  host: string;
  authority: string;
  apps: Record<string, { applicationId: string; capability: string }>;
  sessions: Record<string, Session>;
  versions: { authboundry: string | null; appboundry: string | null };
};

export type RealStackConfig = { authboundryDir: string; appboundryDir: string };

export function realStackConfigFromEnv(): RealStackConfig | null {
  const authboundryDir = process.env.AUTHBOUNDRY_DIR;
  const appboundryDir = process.env.APPBOUNDRY_DIR;
  if (process.env.FX_REAL_STACK !== "1") return null;
  if (!authboundryDir || !appboundryDir) throw new Error("FX_REAL_STACK=1 requires AUTHBOUNDRY_DIR and APPBOUNDRY_DIR");
  return { authboundryDir, appboundryDir };
}

const gitSha = (dir: string) => spawnSync("git", ["-C", dir, "rev-parse", "HEAD"], { encoding: "utf8" }).stdout.trim() || "unknown";

export class RealStack {
  state!: StackState;
  scratch = "";
  private control = "";
  private launcher: ChildProcess | null = null;

  constructor(private readonly config: RealStackConfig) {}

  /** An isolated HOME for fx invocations that do not need a provider. */
  get fxHome(): string {
    return join(this.scratch, "home");
  }

  async start(): Promise<void> {
    this.scratch = mkdtempSync(join(tmpdir(), "fx-real-stack-"));
    mkdirSync(this.fxHome);
    const stateFile = join(this.scratch, "state.json");
    const configFile = join(dirname(fileURLToPath(import.meta.url)), "vitest.stack.config.mjs");
    this.launcher = spawn("pnpm", ["vitest", "run", "--config", configFile], {
      cwd: this.config.appboundryDir,
      stdio: ["ignore", "ignore", "pipe"],
      env: {
        ...process.env,
        APPBOUNDRY_DIR: this.config.appboundryDir,
        AUTHBOUNDRY_DIR: this.config.authboundryDir,
        FX_STACK_STATE: stateFile,
        FX_STACK_AUTHBOUNDRY_VERSION: gitSha(this.config.authboundryDir),
        FX_STACK_APPBOUNDRY_VERSION: gitSha(this.config.appboundryDir),
      },
    });
    let stderr = "";
    this.launcher.stderr?.on("data", (chunk) => (stderr += chunk));
    for (let i = 0; i < 240 && !existsSync(stateFile); i++) {
      if (this.launcher.exitCode !== null) throw new Error(`stack launcher exited early:\n${stderr}`);
      await Bun.sleep(500);
    }
    if (!existsSync(stateFile)) throw new Error(`stack did not start:\n${stderr}`);
    this.control = JSON.parse(readFileSync(stateFile, "utf8")).control;
    this.state = await this.api("/state");
  }

  async api(path: string, body?: unknown): Promise<any> {
    const response = await fetch(`${this.control}${path}`, body === undefined ? {} : { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
    const value = await response.json();
    if (!response.ok) throw new Error(`${path}: ${JSON.stringify(value)}`);
    return value;
  }

  executions(): Promise<Record<string, { completed: number; usage: number; usageFailures: number }>> {
    return this.api("/executions");
  }

  /** Direct MCP tools/call, for principals fx is never shown a tool for and for timing. */
  async rawCall(alias: string, credential: string | undefined, args: unknown) {
    const response = await fetch(`${this.state.host}/apps/${alias}/mcp`, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json, text/event-stream", ...(credential ? { authorization: `Bearer ${credential}` } : {}) },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "changeimpact_context", arguments: args } }),
    });
    let json: any = null;
    try {
      json = await response.json();
    } catch {}
    return { status: response.status, json };
  }

  async stop(): Promise<void> {
    try {
      await this.api("/stop", {});
      await Promise.race([new Promise((resolve) => this.launcher?.once("exit", resolve)), Bun.sleep(30_000)]);
    } catch {}
    this.launcher?.kill();
    if (this.scratch) rmSync(this.scratch, { recursive: true, force: true });
  }
}
