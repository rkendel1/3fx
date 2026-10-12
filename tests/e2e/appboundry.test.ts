import { afterEach, describe, expect, test } from "bun:test";
import { runFx } from "../evals/eval-helpers";
import {
  APPBOUNDARY_TOKEN,
  INPUT_SCHEMA,
  RESIZE_DESCRIPTION,
  startAppBoundryHost,
  type AppBoundryHostOptions,
} from "./fixtures/appboundry-host";
import {
  completion,
  createConfiguredProviderFixture as providerFixture,
  toolCompletion,
} from "./fixtures/chat-completions";

type Provider = ReturnType<typeof providerFixture>;
let cleanups: Array<() => void> = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

function lastToolResult(body: any): string {
  const message = [...body.messages].reverse().find((entry: any) => entry.role === "tool");
  return typeof message?.content === "string" ? message.content : "";
}

/**
 * A scripted model that discovers the capability the way a user task would:
 * capability_search by description, mcp_select_tool for the real schema, then
 * the call. Tool names come from the search result, never from this script.
 */
function scriptedModel(args: Record<string, unknown>, state: { toolName?: string; schema?: string }) {
  let step = 0;
  return (body: any) => {
    step += 1;
    if (step === 1) return toolCompletion(body.model, "capability_search", { query: "requested width height" });
    if (step === 2) {
      const found = JSON.parse(lastToolResult(body)).mcp_tools?.[0];
      if (!found) return completion(body.model, "no matching capability");
      state.toolName = found.name;
      return toolCompletion(body.model, "mcp_select_tool", { name: found.name });
    }
    if (step === 3) {
      state.schema = lastToolResult(body);
      return toolCompletion(body.model, state.toolName!, args);
    }
    return completion(body.model, "tool finished; I still need to verify the output");
  };
}

async function runTask(
  provider: Provider,
  host: { url: string },
  env: Record<string, string | undefined> = {},
) {
  return runFx(["ask", "--json", "--no-save", "Resize this small raster to 4x2"], {
    cwd: provider.workspace,
    env: {
      ...provider.env,
      FX_PERMISSION_MODE: "full-access",
      FX_APPBOUNDRY_URL: host.url,
      FX_APPBOUNDRY_TOKEN: APPBOUNDARY_TOKEN,
      FX_APPBOUNDRY_ALLOW_LOCAL_HTTP: "1",
      ...env,
    },
    timeoutMs: 30_000,
  });
}

function setup(options: AppBoundryHostOptions, args: Record<string, unknown>) {
  const host = startAppBoundryHost(options);
  const state: { toolName?: string; schema?: string } = {};
  const provider = providerFixture(scriptedModel(args, state));
  cleanups.push(() => host.stop(), () => provider.close());
  return { host, provider, state };
}

const GOOD_ARGS = { width: 4, height: 2, pixels: "AAECAwQFBgc=" };
const methods = (host: { requests: Array<{ body: any; path: string }> }) =>
  host.requests.map((request) => request.body?.method ?? request.path);

describe("AppBoundry capability provider", () => {
  test("discovers, selects by description, uses the real schema, and invokes through MCP", async () => {
    const { host, provider, state } = setup({}, GOOD_ARGS);
    const result = await runTask(provider, host);
    expect(result.code).toBe(0);
    const output = JSON.parse(result.stdout);
    expect(output.output).toContain("tool finished");
    expect(output.tool_calls.map((call: any) => call.status)).toEqual(["success", "success", "success"]);

    // Dynamic discovery and the standard MCP lifecycle, with the configured token.
    expect(methods(host)).toEqual(["/.well-known/appport", "initialize", "notifications/initialized", "tools/list", "tools/call"]);
    for (const request of host.requests) expect(request.authorization).toBe(`Bearer ${APPBOUNDARY_TOKEN}`);
    const call = host.requests.at(-1)!.body.params;
    expect(call.name).toBe("image_resize");
    expect(call.arguments).toEqual(GOOD_ARGS);

    // Provenance is in the tool name; the schema is the host's, loaded on demand.
    expect(state.toolName).toBe("mcp_appboundry_image-resizer_image_resize");
    const firstPrompt = JSON.stringify(provider.requests[0].body);
    expect(firstPrompt).not.toContain("pixels");
    expect(firstPrompt).not.toContain(RESIZE_DESCRIPTION);
    expect(provider.requests[0].body.tools.map((tool: any) => tool.function.name)).not.toContain(state.toolName);
    const selected = provider.requests[2].body.tools.find((tool: any) => tool.function.name === state.toolName);
    expect(selected.function.parameters.required).toEqual(INPUT_SCHEMA.required);
    expect(Object.keys(selected.function.parameters.properties)).toEqual(Object.keys(INPUT_SCHEMA.properties));

    // The structured result reaches the model as untrusted tool output.
    expect(lastToolResult(provider.requests.at(-1)!.body)).toContain('"bytes":8');

    // Credentials never reach the model or the provider.
    for (const request of provider.requests) {
      expect(JSON.stringify(request.body)).not.toContain(APPBOUNDARY_TOKEN);
      expect(request.authorization).toBeNull();
    }
    expect(result.stdout + result.stderr).not.toContain(APPBOUNDARY_TOKEN);
  }, 45_000);

  test("the host's invalid-input decision reaches the agent without a retry", async () => {
    const { host, provider } = setup({}, { width: "wide", height: 2, pixels: "AA==" });
    const result = await runTask(provider, host);
    expect(result.code).toBe(0);
    expect(host.requests.filter((request) => request.body?.method === "tools/call").length).toBeLessThanOrEqual(1);
    expect(lastToolResult(provider.requests.at(-1)!.body)).toMatch(/width|INVALID_INPUT/);
  }, 45_000);

  test("a token without the scope sees no tool and cannot reach the capability", async () => {
    const { host, provider } = setup({ grantedScopes: [] }, GOOD_ARGS);
    const result = await runTask(provider, host);
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout).output).toBe("no matching capability");
    expect(methods(host)).not.toContain("tools/call");
  }, 45_000);

  test("a listed but unauthorized capability is refused by the host, not by fx", async () => {
    const { host, provider } = setup({ grantedScopes: [], listUngranted: true }, GOOD_ARGS);
    const result = await runTask(provider, host);
    expect(result.code).toBe(0);
    const calls = host.requests.filter((request) => request.body?.method === "tools/call");
    expect(calls).toHaveLength(1);
    expect(lastToolResult(provider.requests.at(-1)!.body)).toContain("FORBIDDEN");
  }, 45_000);

  test("an execution trap is surfaced as an error and not replayed", async () => {
    const { host, provider } = setup({ trap: true }, GOOD_ARGS);
    const result = await runTask(provider, host);
    expect(result.code).toBe(0);
    expect(host.requests.filter((request) => request.body?.method === "tools/call")).toHaveLength(1);
    expect(lastToolResult(provider.requests.at(-1)!.body)).toContain("SYNAPSE_TRAP");
  }, 45_000);

  test("stopped applications are not callable", async () => {
    const { host, provider } = setup({ stopped: true }, GOOD_ARGS);
    const result = await runTask(provider, host);
    expect(result.code).toBe(0);
    expect(methods(host)).toEqual(["/.well-known/appport"]);
  }, 45_000);

  test("an advertised endpoint outside the configured origin is never contacted", async () => {
    const stranger = startAppBoundryHost();
    cleanups.push(() => stranger.stop());
    for (const advertisedMcp of [`${stranger.url}/apps/image-resizer/mcp`, "//127.0.0.1/apps/image-resizer/mcp"]) {
      const { host, provider } = setup({ advertisedMcp }, GOOD_ARGS);
      const result = await runTask(provider, host);
      expect(result.code).toBe(0);
      expect(methods(host)).toEqual(["/.well-known/appport"]);
    }
    expect(stranger.requests).toHaveLength(0);
  }, 60_000);

  test("an unauthorized or unreachable host leaves unrelated functionality working", async () => {
    const { host, provider } = setup({}, GOOD_ARGS);
    const denied = await runTask(provider, host, { FX_APPBOUNDRY_TOKEN: "wrong-token-wrong-token-wrong" });
    expect(denied.code).toBe(0);
    expect(denied.stdout + denied.stderr).not.toContain("wrong-token");
    expect(methods(host)).not.toContain("tools/call");

    const down = setup({}, GOOD_ARGS);
    const unreachable = await runTask(down.provider, { url: "http://127.0.0.1:1" });
    expect(unreachable.code).toBe(0);
    expect(JSON.parse(unreachable.stdout).output).toBe("no matching capability");
  }, 60_000);

  test("plain http is refused without the explicit local-development opt-in", async () => {
    const { host, provider } = setup({}, GOOD_ARGS);
    const result = await runTask(provider, host, { FX_APPBOUNDRY_ALLOW_LOCAL_HTTP: undefined });
    expect(result.code).toBe(0);
    expect(host.requests).toHaveLength(0);
  }, 45_000);

  test("the provider can be disabled without affecting fx", async () => {
    const { host, provider } = setup({}, GOOD_ARGS);
    const result = await runTask(provider, host, { FX_APPBOUNDRY_DISABLE: "1" });
    expect(result.code).toBe(0);
    expect(host.requests).toHaveLength(0);
  }, 45_000);

  test("fx without AppBoundry configuration behaves as before", async () => {
    const { provider } = setup({}, GOOD_ARGS);
    const result = await runFx(["ask", "--json", "--auto", "--no-save", "hello"], {
      cwd: provider.workspace,
      env: provider.env,
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    expect(result.stderr).not.toContain("appboundry");
  }, 45_000);

  test("mcp list --connect reports the discovered, ready server", async () => {
    const { host, provider } = setup({}, GOOD_ARGS);
    const result = await runFx(["mcp", "list", "--connect"], {
      cwd: provider.workspace,
      env: {
        ...provider.env,
        FX_PERMISSION_MODE: "full-access",
      FX_APPBOUNDRY_URL: host.url,
        FX_APPBOUNDRY_TOKEN: APPBOUNDARY_TOKEN,
        FX_APPBOUNDRY_ALLOW_LOCAL_HTTP: "1",
      },
      timeoutMs: 30_000,
    });
    expect(result.code).toBe(0);
    expect(result.stdout).toMatch(/appboundry_image-resizer[\s\S]{0,200}state=ready/);
    expect(result.stdout).toContain("tools=2");
    expect(result.stdout + result.stderr).not.toContain(APPBOUNDARY_TOKEN);
  }, 45_000);
});
