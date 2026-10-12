import { afterEach, describe, expect, test } from "bun:test";
import { runFx } from "../evals/eval-helpers";
import {
  completion,
  createConfiguredProviderFixture as providerFixture,
  toolCompletion,
} from "./fixtures/chat-completions";

// Opt-in: drives fx against a REAL AppBoundry host in AuthBoundry authority mode.
// It never starts services and never invents an AuthBoundry endpoint. The
// operator provides a running stack and two commands that act on it:
//
//   FX_AUTHORITY_E2E_URL           AppBoundry host origin (authority mode)
//   FX_AUTHORITY_E2E_SESSION       an existing AuthBoundry session credential, apt_<tenant>.<session>
//   FX_AUTHORITY_E2E_QUERY         words that find the capability by description or name
//   FX_AUTHORITY_E2E_ARGS          JSON arguments for the capability
//   FX_AUTHORITY_E2E_REVOKE_CMD    shell command that revokes the grant (or signs the session out)
//   FX_AUTHORITY_E2E_CORRELATE_CMD optional shell command; receives FX_DECISION_ID and
//                                  FX_EXECUTION_UNIT_ID and exits 0 only when AuthBoundry's
//                                  decision and AppBoundry's invocation record agree
//   FX_AUTHORITY_E2E_ALLOW_HTTP=1  loopback development hosts only
//
// When the variables are absent the whole suite is reported as skipped, which is
// "not verified against the real service", never a pass. See
// docs/appboundry-provider.md for prerequisites and the exact command.
const url = process.env.FX_AUTHORITY_E2E_URL;
const session = process.env.FX_AUTHORITY_E2E_SESSION;
const query = process.env.FX_AUTHORITY_E2E_QUERY;
const argsJson = process.env.FX_AUTHORITY_E2E_ARGS;
const revokeCmd = process.env.FX_AUTHORITY_E2E_REVOKE_CMD;
const correlateCmd = process.env.FX_AUTHORITY_E2E_CORRELATE_CMD;
const enabled = Boolean(url && session && query && argsJson && revokeCmd);

let close: (() => void) | null = null;
afterEach(() => {
  close?.();
  close = null;
});

function lastToolResult(body: any): string {
  const message = [...body.messages].reverse().find((entry: any) => entry.role === "tool");
  return typeof message?.content === "string" ? message.content : "";
}

function sh(command: string, env: Record<string, string> = {}) {
  return Bun.spawnSync(["sh", "-c", command], { env: { ...process.env, ...env }, stdout: "pipe", stderr: "pipe" });
}

describe.skipIf(!enabled)("AppBoundry authority: real service", () => {
  test("authorized call, revocation on the next call in the same process, and evidence correlation", async () => {
    const results: any[] = [];
    let step = 0;
    let issued = 0;
    let toolName = "";
    const provider = providerFixture((body: any) => {
      step += 1;
      if (step === 1) return toolCompletion(body.model, "capability_search", { query });
      if (step === 2) {
        const found = JSON.parse(lastToolResult(body)).mcp_tools?.[0];
        if (!found) return completion(body.model, "no matching capability");
        toolName = found.name;
        return toolCompletion(body.model, "mcp_select_tool", { name: toolName });
      }
      if (issued > 0) {
        try {
          results.push(JSON.parse(lastToolResult(body)).result);
        } catch {
          results.push(null);
        }
      }
      if (issued === 0) {
        issued += 1;
        return toolCompletion(body.model, toolName, JSON.parse(argsJson!));
      }
      if (issued === 1) {
        // Revoke between calls. fx keeps the tool list it discovered earlier.
        const revoked = sh(revokeCmd!);
        if (revoked.exitCode !== 0) throw new Error(`revoke command failed: ${revoked.stderr.toString()}`);
        issued += 1;
        return toolCompletion(body.model, toolName, JSON.parse(argsJson!));
      }
      return completion(body.model, "both calls finished; the goal is not established by them");
    });
    close = () => provider.close();

    const result = await runFx(["ask", "--json", "--no-save", `Task: ${query}`], {
      cwd: provider.workspace,
      env: {
        ...provider.env,
        FX_PERMISSION_MODE: "full-access",
        FX_APPBOUNDRY_URL: url,
        FX_APPBOUNDRY_TOKEN: session,
        FX_APPBOUNDRY_ALLOW_LOCAL_HTTP: process.env.FX_AUTHORITY_E2E_ALLOW_HTTP,
      },
      timeoutMs: 120_000,
    });
    expect(result.code).toBe(0);
    expect(toolName.startsWith("mcp_appboundry_")).toBe(true);
    expect(results).toHaveLength(2);
    expect(result.stdout + result.stderr + JSON.stringify(provider.requests.map((request) => request.body))).not.toContain(session!);

    // 1. The authorized call succeeded and carries both kinds of evidence.
    const first = results[0];
    expect(first.isError).not.toBe(true);
    const authorization = first._meta?.["appboundry/authorization"];
    const evidence = first._meta?.["appboundry/evidence"];
    expect(authorization?.authority).toBeDefined();
    expect(evidence?.executionUnitId).toBeDefined();
    const decisionId = authorization.decisions?.[0]?.decisionId;
    expect(decisionId).toBeDefined();

    // 2. After revocation the same process is denied, with authorization evidence
    //    and without execution evidence.
    const second = results[1];
    expect(second.isError).toBe(true);
    expect(JSON.stringify(second)).toMatch(/FORBIDDEN|UNAUTHENTICATED|AUTHORITY_UNAVAILABLE/);
    expect(second._meta?.["appboundry/evidence"]).toBeUndefined();

    // 3. Correlation is checked by the operator's command against the durable records.
    if (correlateCmd) {
      const correlated = sh(correlateCmd, { FX_DECISION_ID: String(decisionId), FX_EXECUTION_UNIT_ID: String(evidence.executionUnitId) });
      expect(correlated.exitCode).toBe(0);
    } else {
      console.log("FX_AUTHORITY_E2E_CORRELATE_CMD not set: decision/execution correlation was NOT verified against durable records");
    }
  }, 180_000);
});
