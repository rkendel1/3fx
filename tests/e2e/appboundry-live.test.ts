import { afterEach, describe, expect, test } from "bun:test";
import { runFx } from "../evals/eval-helpers";
import {
  completion,
  createConfiguredProviderFixture as providerFixture,
  toolCompletion,
} from "./fixtures/chat-completions";

// Runs fx against a real AppBoundry host. Opt in with:
//   FX_APPBOUNDRY_E2E_URL, FX_APPBOUNDRY_E2E_TOKEN   host origin and an authorized token
//   FX_APPBOUNDRY_E2E_QUERY                          capability description to search for
//   FX_APPBOUNDRY_E2E_ARGS                           JSON arguments matching that capability's schema
// Optional: FX_APPBOUNDRY_E2E_ALLOW_HTTP=1 for a loopback development host.
// The model is scripted, but it learns the tool name from capability discovery;
// no tool name, schema, or endpoint is hardcoded here.
const url = process.env.FX_APPBOUNDRY_E2E_URL;
const token = process.env.FX_APPBOUNDRY_E2E_TOKEN;
const query = process.env.FX_APPBOUNDRY_E2E_QUERY;
const argsJson = process.env.FX_APPBOUNDRY_E2E_ARGS;
const enabled = Boolean(url && token && query && argsJson);

let close: (() => void) | null = null;
afterEach(() => {
  close?.();
  close = null;
});

function lastToolResult(body: any): string {
  const message = [...body.messages].reverse().find((entry: any) => entry.role === "tool");
  return typeof message?.content === "string" ? message.content : "";
}

describe.skipIf(!enabled)("AppBoundry live host", () => {
  test("fx discovers, selects, and invokes a deployed capability", async () => {
    let step = 0;
    let toolName = "";
    const provider = providerFixture((body) => {
      step += 1;
      if (step === 1) return toolCompletion(body.model, "capability_search", { query });
      if (step === 2) {
        const found = JSON.parse(lastToolResult(body)).mcp_tools?.[0];
        if (!found) return completion(body.model, "no matching capability");
        toolName = found.name;
        return toolCompletion(body.model, "mcp_select_tool", { name: toolName });
      }
      if (step === 3) return toolCompletion(body.model, toolName, JSON.parse(argsJson!));
      return completion(body.model, "the capability returned; the result still needs review");
    });
    close = () => provider.close();
    const result = await runFx(["ask", "--json", "--no-save", `Task: ${query}`], {
      cwd: provider.workspace,
      env: {
        ...provider.env,
        FX_PERMISSION_MODE: "full-access",
        FX_APPBOUNDRY_URL: url,
        FX_APPBOUNDRY_TOKEN: token,
        FX_APPBOUNDRY_ALLOW_LOCAL_HTTP: process.env.FX_APPBOUNDRY_E2E_ALLOW_HTTP,
      },
      timeoutMs: 120_000,
    });
    expect(result.code).toBe(0);
    const output = JSON.parse(result.stdout);
    if (output.tool_calls.length !== 3) console.log(result.stdout, result.stderr, JSON.stringify(provider.requests.at(-1)!.body.messages.at(-1)));
    expect(output.tool_calls.map((call: any) => call.status)).toEqual(["success", "success", "success"]);
    expect(toolName.startsWith("mcp_appboundry_")).toBe(true);
    const toolResult = lastToolResult(provider.requests.at(-1)!.body);
    console.log(`AppBoundry tool ${toolName} returned: ${toolResult.slice(0, 600)}`);
    expect(toolResult.length).toBeGreaterThan(0);
    for (const request of provider.requests) expect(JSON.stringify(request.body)).not.toContain(token!);
    expect(result.stdout + result.stderr).not.toContain(token!);
  }, 150_000);
});
