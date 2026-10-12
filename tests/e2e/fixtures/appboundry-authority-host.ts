// A double for AppBoundry running in AuthBoundry authority mode. It is NOT the
// real AuthBoundry or AppBoundry; it encodes the contract fx depends on so the
// consumer side can be proven deterministically in ordinary CI:
//
//   caller authentication  GET /auth/session semantics with `apt_<tenant>.<session>`
//   authorization          one fresh per-permission check per tools/call, made
//                          with a server-side `abc_...` check credential that
//                          fx never sees
//   evidence               `appboundry/authorization` on every decided call,
//                          `appboundry/evidence` only when execution was attempted
//
// The authority state (sessions, policies, durable decisions) is kept apart from
// the host surface. The host never trusts anything but the Authorization header:
// identity or scope fields in headers, tool arguments, or discovery are ignored.

export const CHECK_CREDENTIAL = "abc_server_side_check_credential_0123456789";
export const TENANT = "acme";

export type Decision = {
  decisionId: string;
  principal: string;
  permission: string;
  effect: "allow" | "deny" | "unavailable";
  application: string;
  capability: string;
  /** Execution context recorded by the authority; set when the host is allowed to run. */
  executionContext?: { executionUnitId: string };
};

export type InvocationRecord = {
  executionUnitId: string;
  application: string;
  capability: string;
  outcome: "succeeded" | "failed";
  decisionId: string;
};

export type AuthorityFailure = "none" | "unavailable" | "malformed" | "timeout";

export type AppSpec = {
  selector: string;
  /** Permission the capability declares, e.g. "image.resize". */
  permission: string;
  /** MCP tool name; two applications may use the same name. */
  tool: string;
  capability: string;
  /** Run, then trap, so execution evidence reports failure. */
  trap?: boolean;
  /** Accept undeclared arguments, so forged fields reach the host. */
  lenientSchema?: boolean;
  /** Append this many bytes of text to a successful result. */
  padding?: number;
  /** Respond to MCP with a redirect to this absolute URL. */
  redirectTo?: string;
};

export type AuthorityHostOptions = {
  apps?: AppSpec[];
  /** Advertise broad authority in discovery; it must have no effect. */
  forgeDiscoveryClaims?: boolean;
  /** Override the advertised MCP path of the first application. */
  advertisedMcp?: string;
};

export type RecordedRequest = {
  method: string;
  path: string;
  headers: Record<string, string>;
  body: any;
  text: string;
};

export const DEFAULT_APP: AppSpec = {
  selector: "image-resizer",
  permission: "image.resize",
  tool: "image_resize",
  capability: "image.resize@1",
};

export const RESIZE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["width", "height"],
  properties: { width: { type: "integer", minimum: 1 }, height: { type: "integer", minimum: 1 } },
};

/** Distinctive words per application so capability search can tell them apart. */
export function describe(app: AppSpec): string {
  return `${app.selector.replace(/[-_.]/g, " ")} ${app.tool.replace(/_/g, " ")} ${app.permission.replace(/[._]/g, " ")}`;
}

export function startAuthorityHost(options: AuthorityHostOptions = {}) {
  const apps = options.apps ?? [DEFAULT_APP];
  const requests: RecordedRequest[] = [];
  const decisions: Decision[] = [];
  const invocations: InvocationRecord[] = [];
  let executions = 0;
  let counter = 0;
  let failure: AuthorityFailure = "none";

  // AuthBoundry-side state: live sessions and the grants (policies) behind them.
  const sessions = new Map<string, string>(); // credential -> principal
  const policies = new Set<string>(); // `${principal}|${permission}`

  const authority = {
    addSession(principal: string, session = "s1") {
      const credential = `apt_${TENANT}.${session}`;
      sessions.set(credential, principal);
      return credential;
    },
    signOut(credential: string) {
      sessions.delete(credential);
    },
    grant(principal: string, permission: string) {
      policies.add(`${principal}|${permission}`);
    },
    revoke(principal: string, permission: string) {
      policies.delete(`${principal}|${permission}`);
    },
    setFailure(next: AuthorityFailure) {
      failure = next;
    },
  };

  // Calls the authority the way AppBoundry does: with the server-side credential.
  function check(principal: string, permission: string): "allow" | "deny" | "unavailable" {
    if (failure === "unavailable" || failure === "timeout") return "unavailable";
    if (failure === "malformed") return "unavailable"; // an unparseable decision is not a decision
    return policies.has(`${principal}|${permission}`) ? "allow" : "deny";
  }

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const text = request.method === "POST" ? await request.text() : "";
      let body: any = null;
      try {
        body = text ? JSON.parse(text) : null;
      } catch {
        body = null;
      }
      const headers: Record<string, string> = {};
      request.headers.forEach((value, key) => (headers[key] = value));
      requests.push({ method: request.method, path: url.pathname, headers, body, text });

      if (url.pathname === "/.well-known/appport") {
        return Response.json({
          protocol: "AppPort/host-discovery/1",
          applications: apps.map((app, index) => ({
            id: `synapse.${app.selector}`,
            name: app.selector,
            selector: app.selector,
            status: "running",
            capabilities: [app.capability],
            descriptions: { [app.capability]: describe(app) },
            mcp: index === 0 && options.advertisedMcp ? options.advertisedMcp : `/apps/${app.selector}/mcp`,
            ...(options.forgeDiscoveryClaims
              ? {
                  principal: "admin",
                  scopes: ["*"],
                  granted: true,
                  authorization: { [app.capability]: [] },
                }
              : {}),
          })),
        });
      }

      const app = apps.find((candidate) => url.pathname === `/apps/${candidate.selector}/mcp`);
      if (!app || request.method !== "POST") return new Response("not found", { status: 404 });
      if (app.redirectTo) return new Response(null, { status: 302, headers: { location: app.redirectTo } });

      // Caller authentication. Only the bearer credential counts; every other
      // identity-looking header is deliberately ignored.
      const bearer = (headers["authorization"] ?? "").replace(/^Bearer /, "");
      const principal = sessions.get(bearer);
      if (!principal) {
        return Response.json({ error: "UNAUTHENTICATED" }, { status: 401, headers: { "www-authenticate": 'Bearer realm="appboundry"' } });
      }

      const rpc = (result: unknown) => Response.json({ jsonrpc: "2.0", id: body.id, result });
      switch (body?.method) {
        case "initialize":
          return rpc({
            protocolVersion: "2025-11-25",
            capabilities: { tools: {} },
            serverInfo: { name: "appboundry-authority-double", version: "1.0.0" },
          });
        case "notifications/initialized":
          return new Response(null, { status: 202 });
        case "ping":
          return rpc({});
        case "tools/list":
          // Metadata only. This is not a grant and is never consulted at call time.
          return rpc({
            tools: [
              {
                name: app.tool,
                description: describe(app),
                inputSchema: app.lenientSchema ? { ...RESIZE_SCHEMA, additionalProperties: true } : RESIZE_SCHEMA,
                _meta: { "appboundry/authorization": [app.permission] },
              },
            ],
          });
        case "tools/call": {
          const decision: Decision = {
            decisionId: `dec-${++counter}`,
            principal,
            permission: app.permission,
            effect: check(principal, app.permission),
            application: app.selector,
            capability: app.capability,
          };
          decisions.push(decision);
          const authorization = {
            authority: "authboundry",
            principal,
            decisions: [{ permission: app.permission, effect: decision.effect, decisionId: decision.decisionId }],
          };
          const fail = (code: string, message: string) =>
            rpc({
              isError: true,
              content: [{ type: "text", text: `${code}: ${message}` }],
              _meta: { "appboundry/error": { code, message }, "appboundry/authorization": authorization },
            });
          if (failure === "malformed") {
            // The authority answered, but not with a decision.
            return fail("AUTHORITY_UNAVAILABLE", "authority returned an unreadable decision");
          }
          if (decision.effect === "unavailable") {
            return fail("AUTHORITY_UNAVAILABLE", "authorization could not be decided");
          }
          if (decision.effect === "deny") {
            return fail("FORBIDDEN", `missing permission ${app.permission}`);
          }
          // Allowed: only now does the module run.
          executions += 1;
          const executionUnitId = `unit-${executions}`;
          decision.executionContext = { executionUnitId };
          const outcome = app.trap ? "failed" : "succeeded";
          invocations.push({
            executionUnitId,
            application: app.selector,
            capability: app.capability,
            outcome,
            decisionId: decision.decisionId,
          });
          const evidence = {
            capability: app.capability,
            package: `pkg:${app.selector}@1.0.0`,
            artifactHash: "sha256:" + "ab".repeat(32),
            contractFingerprint: "sha256:" + "cd".repeat(32),
            outcome,
            executionUnitId,
          };
          if (app.trap) {
            return rpc({
              isError: true,
              content: [{ type: "text", text: "appboundry.SYNAPSE_SKILL_TRAP: the capability trapped" }],
              _meta: { "appboundry/authorization": authorization, "appboundry/evidence": evidence },
            });
          }
          const args = body.params?.arguments ?? {};
          const result = { width: args.width, height: args.height, ranBy: app.selector };
          return rpc({
            content: [{ type: "text", text: JSON.stringify(result) + "x".repeat(app.padding ?? 0) }],
            structuredContent: result,
            _meta: { "appboundry/authorization": authorization, "appboundry/evidence": evidence },
          });
        }
        default:
          return Response.json({ jsonrpc: "2.0", id: body?.id ?? null, error: { code: -32601, message: "method not found" } });
      }
    },
  });

  return {
    url: `http://127.0.0.1:${server.port}`,
    requests,
    decisions,
    invocations,
    authority,
    /** Number of times a capability module actually ran. */
    get executions() {
      return executions;
    },
    stop: () => server.stop(true),
  };
}
