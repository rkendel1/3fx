// A stand-in for an AppBoundry host, shaped from the real host's wire format:
// GET /.well-known/appport (AppPort/host-discovery/1) and stateless Streamable
// HTTP MCP at /apps/<selector>/mcp with JSON responses. Authentication, scope
// checks, input validation, and execution all happen here, never in fx.

export const APPBOUNDARY_TOKEN = "fx-appboundry-fixture-token-0123456789";
export const RESIZE_DESCRIPTION =
  "Resize a small raster image to the requested width and height.";

export type HostedRequest = {
  method: string;
  path: string;
  authorization: string | null;
  body: any;
};

export type AppBoundryHostOptions = {
  grantedScopes?: string[];
  /** Overrides the advertised MCP path for the application. */
  advertisedMcp?: string;
  /** Advertise a stopped application. */
  stopped?: boolean;
  /** List the tool even when its scope is not granted (calls are still refused). */
  listUngranted?: boolean;
  /** Make the capability fail with an execution trap. */
  trap?: boolean;
};

export const INPUT_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["width", "height", "pixels"],
  properties: {
    width: { type: "integer", minimum: 1 },
    height: { type: "integer", minimum: 1 },
    pixels: { type: "string", description: "Base64 raster bytes" },
  },
};

export function startAppBoundryHost(options: AppBoundryHostOptions = {}) {
  const requests: HostedRequest[] = [];
  const granted = new Set(options.grantedScopes ?? ["image.resize"]);
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const authorization = request.headers.get("authorization");
      const text = request.method === "POST" ? await request.text() : "";
      let body: any = null;
      try {
        body = text ? JSON.parse(text) : null;
      } catch {
        body = null;
      }
      requests.push({ method: request.method, path: url.pathname, authorization, body });

      if (url.pathname === "/.well-known/appport") {
        return Response.json({
          protocol: "AppPort/host-discovery/1",
          applications: [
            {
              id: "synapse.image-resizer",
              name: "Image Resizer",
              selector: "image-resizer",
              version: "1.0.0",
              status: options.stopped ? "stopped" : "running",
              capabilities: ["image.resize@1"],
              authorization: { "image.resize@1": ["image.resize"] },
              descriptions: { "image.resize@1": RESIZE_DESCRIPTION },
              mcp: options.advertisedMcp ?? "/apps/image-resizer/mcp",
            },
          ],
        });
      }
      if (url.pathname !== "/apps/image-resizer/mcp" || request.method !== "POST") {
        return new Response("not found", { status: 404 });
      }
      if (authorization !== `Bearer ${APPBOUNDARY_TOKEN}`) {
        return Response.json({ error: "unauthorized" }, { status: 401 });
      }
      const rpc = (result: unknown) =>
        Response.json({ jsonrpc: "2.0", id: body.id, result });
      switch (body?.method) {
        case "initialize":
          return rpc({
            protocolVersion: "2025-11-25",
            capabilities: { tools: {} },
            serverInfo: { name: "appboundry-host", version: "1.0.0" },
          });
        case "notifications/initialized":
          return new Response(null, { status: 202 });
        case "ping":
          return rpc({});
        case "tools/list": {
          const tools: unknown[] = [{
            name: "text_digest",
            description: "Condense long prose into a short abstract.",
            inputSchema: { type: "object", required: ["text"], properties: { text: { type: "string" } } },
          }];
          if (granted.has("image.resize") || options.listUngranted) {
            tools.push({
              name: "image_resize",
              description: RESIZE_DESCRIPTION,
              inputSchema: INPUT_SCHEMA,
              _meta: { "appboundry/authorization": ["image.resize"] },
            });
          }
          return rpc({ tools });
        }
        case "tools/call": {
          const args = body.params?.arguments ?? {};
          const fail = (code: string, message: string, details?: unknown) =>
            rpc({
              isError: true,
              content: [{ type: "text", text: `${code}: ${message}` }],
              _meta: { "appboundry/error": { code, message, details } },
            });
          if (!granted.has("image.resize")) {
            return fail("FORBIDDEN", "missing scope", { missingScopes: ["image.resize"] });
          }
          if (
            !Number.isInteger(args.width) || !Number.isInteger(args.height) ||
            typeof args.pixels !== "string"
          ) {
            return fail("INVALID_INPUT", "input does not satisfy the contract");
          }
          if (options.trap) {
            return fail("appboundry.SYNAPSE_TRAP", "the capability trapped");
          }
          const result = { width: args.width, height: args.height, bytes: args.width * args.height };
          return rpc({
            content: [{ type: "text", text: JSON.stringify(result) }],
            structuredContent: result,
            _meta: { "appboundry/evidence": { executionUnitId: "unit-1", capability: "image.resize@1" } },
          });
        }
        default:
          return Response.json({
            jsonrpc: "2.0",
            id: body?.id ?? null,
            error: { code: -32601, message: "method not found" },
          });
      }
    },
  });
  return {
    url: `http://127.0.0.1:${server.port}`,
    requests,
    stop: () => server.stop(true),
  };
}
