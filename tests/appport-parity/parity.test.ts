// Parity between fx's native AppPort knowledge (src/core/appport/) and the
// published AppPort packages pinned in package.json.
//
// Every explicitly supported semantic is compared against the reference
// implementation on shared fixtures. Unsupported semantics are tested
// separately: fx must report them as unsupported, never answer them.
//
// fx runs with an empty PATH, so the native runtime cannot reach Node.js or
// npm while it inspects contracts.

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import * as protocol from "@appport/protocol";
import * as integration from "@appport/integration";
import { createApplication, createClient, createHttpTransport, createServer, defineCapability, s } from "@appport/sdk";
import { serve } from "@appport/sdk/node";

const here = import.meta.dir;
const repo = resolve(here, "../..");
const fxBin = process.env.FX_BIN ?? join(repo, "zig-out/bin/fx");
const scratch = mkdtempSync(join(tmpdir(), "fx-appport-parity-"));
afterAll(() => rmSync(scratch, { recursive: true, force: true }));

function fixturePath(name: string) {
  return join(here, "fixtures", `${name}.json`);
}

function load(name: string) {
  return JSON.parse(readFileSync(fixturePath(name), "utf8"));
}

let counter = 0;
function writeTemp(value: unknown): string {
  const path = join(scratch, `contract-${counter++}.json`);
  writeFileSync(path, typeof value === "string" ? value : JSON.stringify(value));
  return path;
}

function fx(args: string[]) {
  const result = spawnSync(fxBin, ["appport", ...args], {
    cwd: scratch,
    env: { HOME: scratch, PATH: "/nonexistent", FX_AUTO_UPGRADE: "0", NO_COLOR: "1" },
    encoding: "utf8",
  });
  if (result.error) throw result.error;
  return { code: result.status, stdout: result.stdout, stderr: result.stderr };
}

function fxJson(args: string[]) {
  const result = fx([...args, "--json"]);
  expect(result.stderr).toBe("");
  return { code: result.code, body: JSON.parse(result.stdout) };
}

const byteOrder = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
const byId = (a: { id: string }, b: { id: string }) => byteOrder(a.id, b.id);

/** Reference graphs sort with localeCompare; fx sorts by bytes. Compare content, not collation. */
function normalizeGraph(graph: any) {
  const g = JSON.parse(JSON.stringify(graph));
  g.nodes.sort(byId);
  g.edges.sort(byId);
  g.unknowns.sort(byId);
  g.risks.sort(byId);
  g.resourceRelations.sort((a: any, b: any) => byteOrder(a.resource, b.resource));
  return g;
}

function referenceLint(manifest: unknown) {
  return protocol.lintDependencyModel(manifest as any).map(issue => ({ severity: issue.level, path: issue.path, message: issue.message }));
}

function nativeLint(path: string) {
  const { body } = fxJson(["inspect", path]);
  const contract = body.contracts[0];
  expect(contract.dependency_model_checked).toBe(true);
  return contract.diagnostics
    .filter((d: any) => d.source === "appport.lintDependencyModel")
    .map((d: any) => ({ severity: d.severity, path: d.path, message: d.message }));
}

function capability(name: string, extra: Record<string, unknown> = {}) {
  const definition = { version: 1, kind: "request", inputSchema: {}, outputSchema: {}, authorization: [], effect: "observation", ...extra };
  return { name, versions: [1], latestVersion: 1, kind: "request", inputSchema: {}, outputSchema: {}, authorization: definition.authorization, definitions: [definition] };
}

function manifest(capabilities: unknown[], extra: Record<string, unknown> = {}) {
  return { protocol: "appport/1", application: { id: "com.example.parity", name: "Parity", version: "1" }, capabilities, events: [], transports: [], ...extra };
}

describe("reference pins", () => {
  test("installed reference packages match the versions fx embeds", () => {
    const source = readFileSync(join(repo, "src/core/appport/appport.zig"), "utf8");
    const pins = [...source.matchAll(/\.name = "(@appport\/[a-z-]+)", \.version = "([^"]+)"/g)].map(m => [m[1], m[2]]);
    expect(pins.length).toBeGreaterThan(0);
    for (const [name, version] of pins) {
      const installed = JSON.parse(readFileSync(join(here, "node_modules", name, "package.json"), "utf8")).version;
      expect(`${name}@${installed}`).toBe(`${name}@${version}`);
    }
  });

  test("reference sources match the reviewed digests", () => {
    const { files } = JSON.parse(readFileSync(join(here, "reference-digests.json"), "utf8"));
    for (const [file, digest] of Object.entries(files)) {
      const actual = createHash("sha256").update(readFileSync(join(here, "node_modules", file))).digest("hex");
      expect(`${file} ${actual}`).toBe(`${file} ${digest}`);
    }
  });

  test("fx coverage lists every supported and unsupported area", () => {
    const { code, body } = fxJson(["coverage"]);
    expect(code).toBe(0);
    const statuses = new Set(body.coverage.map((entry: any) => entry.status));
    expect([...statuses].sort()).toEqual(["fx_native", "not_supported", "ported"]);
    expect(body.reference).toEqual([
      { name: "@appport/protocol", version: "1.1.0" },
      { name: "@appport/integration", version: "1.1.0" },
    ]);
  });
});

describe("name rules (validateName, isValidApplicationId, isValidPermission, isSupportedProtocol)", () => {
  const nameCases = [
    "documents.save", "a.b", "a1.b2.c3", "documents", "Documents.save", "documents.Save", "documents..save", ".documents.save",
    "documents.save.", "documents.2save", "2documents.save", "documents.http", "rest.call", "a.inprocess", "documents.save-it",
    "documents_save.x", "a." + "b".repeat(126), "a." + "b".repeat(127), "é.b", "docs.wss.x",
  ];
  test.each(nameCases)("capability name %p", name => {
    const path = writeTemp(manifest([capability(name)]));
    const { body } = fxJson(["inspect", path]);
    const diagnostic = body.contracts[0].diagnostics.find((d: any) => d.path === "capabilities[0].name");
    const reference = protocol.validateName(name);
    if (reference.valid) expect(diagnostic).toBeUndefined();
    else expect(diagnostic?.message).toBe(reference.reason);
  });

  const appIds = ["com.example.app", "com.9x.my-app", "com", "com.-x", "Com.example", "com.example-", "c.0", "com.example.app_x", "a." + "b".repeat(188), "a." + "b".repeat(189)];
  test.each(appIds)("application id %p", id => {
    const path = writeTemp({ ...manifest([]), application: { id, name: "X", version: "1" } });
    const { body } = fxJson(["inspect", path]);
    const flagged = body.contracts[0].diagnostics.some((d: any) => d.path === "application.id");
    expect(flagged).toBe(!protocol.isValidApplicationId(id));
  });

  const permissions = ["documents.write", "documents", "Documents.write", "documents.http", "a.b.c"];
  test.each(permissions)("permission %p", permission => {
    const path = writeTemp(manifest([capability("docs.get", { authorization: [permission] })]));
    const { body } = fxJson(["inspect", path]);
    const flagged = body.contracts[0].diagnostics.some((d: any) => d.path === "capabilities[0].authorization[0]");
    expect(flagged).toBe(!protocol.isValidPermission(permission));
  });

  test.each(["appport/1", "appport/2", "AppPort/1", ""])("protocol %p", id => {
    const path = writeTemp({ ...manifest([]), protocol: id });
    const { body } = fxJson(["inspect", path]);
    const unsupported = body.contracts[0].diagnostics.some((d: any) => d.path === "protocol" && d.category === "unsupported");
    expect(unsupported).toBe(!protocol.isSupportedProtocol(id));
  });
});

describe("lintDependencyModel", () => {
  test.each(["docs", "billing", "lint-errors"])("fixture %s matches the reference exactly", name => {
    expect(nativeLint(fixturePath(name))).toEqual(referenceLint(load(name)));
  });

  const constraints = ["1", "2", "^1", "^2.9", "~1.0", ">=2", ">1", "<=1", "<3", " ^2 ", "=2", "1.", "", "x", ">=", "^", "01", ">=1.5"];
  test.each(constraints)("version constraint %p", constraint => {
    const target = { ...capability("dep.target"), versions: [1, 2, 3], latestVersion: 3, definitions: [1, 2, 3].map(version => ({ ...capability("dep.target").definitions[0], version })) };
    const value = manifest([capability("dep.source"), target], {
      attributes: {
        "appport.integration/1": {
          capabilities: {
            "dep.source@1": { requires: [{ id: "t", relationship: "invokes", target: { capability: "dep.target" }, versionConstraint: constraint, required: true }] },
          },
        },
      },
    });
    const path = writeTemp(value);
    expect(nativeLint(path)).toEqual(referenceLint(value));
    const native = fxJson(["graph", path]).body.graph;
    expect(normalizeGraph(native)).toEqual(normalizeGraph(integration.deriveGraph({ manifests: [value as any] })));
  });

  test("a manifest generated by @appport/server matches the reference", () => {
    const generated = generatedManifest();
    const path = writeTemp(generated);
    expect(nativeLint(path)).toEqual(referenceLint(generated));
    expect(fxJson(["inspect", path]).body.verdict).toBe("valid");
  });
});

describe("deriveGraph (published manifests)", () => {
  const sets: Record<string, string[]> = {
    "docs alone": ["docs"],
    "billing alone": ["billing"],
    "docs and billing": ["docs", "billing"],
    "billing and docs": ["billing", "docs"],
  };
  test.each(Object.keys(sets))("%s", label => {
    const names = sets[label];
    const native = fxJson(["graph", ...names.map(fixturePath)]).body.graph;
    const reference = integration.deriveGraph({ manifests: names.map(load) });
    expect(normalizeGraph(native)).toEqual(normalizeGraph(reference));
  });

  test("the docs and billing graph exercises risks and cycles", () => {
    const native = fxJson(["graph", fixturePath("docs"), fixturePath("billing")]).body.graph;
    const kinds = new Set(native.risks.map((r: any) => r.kind));
    expect([...kinds].sort()).toEqual(["conflicting-ownership", "required-synchronous-cycle", "writes-foreign-resource"]);
    expect(native.cycles.length).toBe(1);
  });

  test("a manifest generated by @appport/server", () => {
    const generated = generatedManifest();
    const native = fxJson(["graph", writeTemp(generated)]).body.graph;
    expect(normalizeGraph(native)).toEqual(normalizeGraph(integration.deriveGraph({ manifests: [generated] })));
  });
});

describe("findCapabilities", () => {
  const selectors: Array<Record<string, string>> = [
    { capability: "docs.save" },
    { capability: "docs.save@1" },
    { capability: "docs.watch" },
    { reads: "urn:example:billing:invoice" },
    { changes: "urn:example:docs:document" },
    { changes: "urn:example:docs:document", operation: "create" },
    { changes: "urn:example:docs:document", operation: "delete" },
    { operation: "update" },
    { effectType: "urn:example:effect:charged" },
    { application: "com.example.billing", changes: "urn:example:billing:invoice" },
    { application: "com.example.none", capability: "docs.get" },
    {},
  ];
  const flags: Record<string, string> = { application: "--application", capability: "--capability", reads: "--reads", changes: "--changes", operation: "--operation", effectType: "--effect-type" };
  test.each(selectors.map(selector => [JSON.stringify(selector), selector]))("selector %s", (_label, selector) => {
    const args = Object.entries(selector as Record<string, string>).flatMap(([key, value]) => [flags[key], value]);
    const { code, body } = fxJson(["find", fixturePath("docs"), fixturePath("billing"), ...args]);
    expect(code).toBe(0);
    const reference = integration.findCapabilities([load("docs"), load("billing")], selector as any);
    expect({ matches: body.matches, undeclared: body.undeclared }).toEqual(JSON.parse(JSON.stringify(reference)));
  });
});

describe("client and transport-http compatibility", () => {
  let running: Awaited<ReturnType<typeof serve>>;
  beforeAll(async () => {
    running = await serve({ server: createServer({ application: generatedApplication() }), port: 0, host: "127.0.0.1", websocket: false });
  });
  afterAll(async () => { await running?.close(); });

  test("a manifest loaded over HTTP by @appport/client inspects as valid and matches the reference", async () => {
    const client = createClient({ transport: createHttpTransport({ url: `${running.url}/appport` }) });
    const loaded = await client.load();
    await client.close();
    expect(loaded.transports.map(t => t.kind)).toContain("http");
    const path = writeTemp(loaded);
    const { code, body } = fxJson(["inspect", path]);
    expect(code).toBe(0);
    expect(body.contracts[0].application.id).toBe("com.example.generated");
    expect(nativeLint(path)).toEqual(referenceLint(loaded));
    const native = fxJson(["graph", path]).body.graph;
    expect(normalizeGraph(native)).toEqual(normalizeGraph(integration.deriveGraph({ manifests: [loaded] })));
  });
});

describe("unsupported semantics are reported, not answered", () => {
  test("concept selectors", () => {
    const reference = integration.findCapabilities([load("docs")], { concept: "https://schema.org/name" });
    expect(Array.isArray(reference.matches)).toBe(true);
    const { code, body } = fxJson(["find", fixturePath("docs"), "--concept", "https://schema.org/name"]);
    expect(code).toBe(1);
    expect(body.code).toBe("UnsupportedSelector");
  });

  test.each([["plan", "planIntegration"], ["compare", "compareBehavior"], ["assess", "assessReplacement"]])("%s", (command, exported) => {
    expect(typeof (integration as any)[exported]).toBe("function");
    const { code, body } = fxJson([command, fixturePath("docs")]);
    expect(code).toBe(1);
    expect(body.code).toBe("UnsupportedOperation");
    expect(body.error).toContain(exported);
  });

  test("lintIntegration findings are listed as not checked, never as passing", () => {
    const value = load("docs");
    value.attributes["appport.integration/1"].capabilities["docs.missing@1"] = { purpose: "declared for a capability that does not exist" };
    expect(protocol.lintIntegration(value).some(issue => issue.level === "error")).toBe(true);
    const { body } = fxJson(["inspect", writeTemp(value)]);
    expect(body.not_checked.some((item: string) => item.startsWith("lintIntegration"))).toBe(true);
  });

  test.each([
    ["requires is not an array", { requires: 5 }],
    ["an access entry is null", { access: [null] }],
    ["operations is a string", { access: [{ resource: "urn:x:y", mode: "changes", operations: "update" }] }],
  ])("shapes the reference cannot process: %s", (_label, entry) => {
    const value = manifest([capability("docs.get")], {
      attributes: { "appport.integration/1": { resources: [{ id: "urn:x:y" }], capabilities: { "docs.get@1": entry } } },
    });
    expect(() => protocol.lintDependencyModel(value as any)).toThrow();
    const { code, body } = fxJson(["inspect", writeTemp(value)]);
    expect(code).toBe(1);
    expect(body.contracts[0].verdict).toBe("malformed");
    expect(body.contracts[0].dependency_model_checked).toBe(false);
  });

  test("unknown extensions and fields make a contract unsupported, not valid", () => {
    const value = { ...load("docs"), extensions: ["appport.integration/1", "vendor.experimental/1"] };
    const { code, body } = fxJson(["inspect", writeTemp(value)]);
    expect(code).toBe(1);
    expect(body.verdict).toBe("unsupported");
  });
});

function generatedApplication() {
  return createApplication({
    application: { id: "com.example.generated", name: "Generated", version: "1.0.0" },
    resources: [{ id: "urn:example:generated:note", kind: "document", owner: "self" }],
    capabilities: [
      defineCapability({
        name: "notes.get", version: 1, effect: "observation", authorization: ["notes.read"],
        input: s.object({ id: s.string() }), output: s.object({ id: s.string(), body: s.string() }),
        integration: { access: [{ resource: "urn:example:generated:note", mode: "reads" }], coverage: { requires: "complete", access: "complete" } },
        handler: async (input: { id: string }) => ({ id: input.id, body: "" }),
      }),
      defineCapability({
        name: "notes.save", version: 1, effect: "consequential", idempotency: "supported", authorization: ["notes.write"],
        input: s.object({ id: s.string(), body: s.string() }), output: s.object({ id: s.string() }),
        integration: {
          purpose: "Save a note",
          requires: [{ id: "read", relationship: "observes", target: { capability: "notes.get@1" }, required: true }],
          access: [{ resource: "urn:example:generated:note", mode: "changes", operations: ["create", "update"] }],
          coverage: { requires: "complete", access: "complete" },
          verify: [{ id: "readback", kind: "state", via: { capability: "notes.get", version: 1, input: { id: { $input: "/id" } } }, expect: [{ at: "/body", equals: { $input: "/body" } }] }],
        },
        handler: async (input: { id: string }) => ({ id: input.id }),
      }),
    ],
  });
}

function generatedManifest() {
  return createServer({ application: generatedApplication() }).manifest();
}

describe("seeded mutation parity", () => {
  // Deterministic perturbations of the integration descriptor. Cases the
  // reference throws on are skipped (fx must call those malformed, covered
  // above); every other case must match the reference exactly.
  const pool: unknown[] = [null, "", "x", 0, 2, true, [], {}, "urn:a:b", "postgres://h/d", "invokes", "observes", "delegates", "consumes-event",
    "changes", "reads", "^1", ">=2", "1.", "docs.get@1", "docs.get", "docs.save@2", "docs.saved", "self", "complete", "partial", ["update"], ["upsert"],
    { application: "com.example.docs" }, { capability: "docs.get@1" }, { event: "docs.saved" }];
  function random(seed: number) {
    let state = seed >>> 0;
    return () => ((state = (Math.imul(state, 1664525) + 1013904223) >>> 0) / 2 ** 32);
  }
  function paths(value: any, prefix: (string | number)[] = [], out: (string | number)[][] = []) {
    if (value && typeof value === "object") {
      for (const key of Object.keys(value)) {
        const child = [...prefix, Array.isArray(value) ? Number(key) : key];
        out.push(child);
        paths(value[key], child, out);
      }
    }
    return out;
  }
  const cases = 600;
  test(`${cases} mutations of the docs and lint-errors fixtures`, () => {
    const next = random(0x5eed);
    let compared = 0;
    for (let i = 0; i < cases; i++) {
      const value = load(i % 2 ? "docs" : "lint-errors");
      const descriptor = value.attributes["appport.integration/1"];
      for (let m = 0; m < 1 + Math.floor(next() * 3); m++) {
        const all = paths(descriptor);
        const path = all[Math.floor(next() * all.length)];
        let parent = descriptor;
        for (const key of path.slice(0, -1)) parent = parent[key];
        const last = path[path.length - 1];
        if (next() < 0.2 && !Array.isArray(parent)) delete parent[last];
        else parent[last] = structuredClone(pool[Math.floor(next() * pool.length)]);
      }
      let reference;
      try { reference = referenceLint(value); } catch { continue; }
      const { body } = fxJson(["inspect", writeTemp(value)]);
      const contract = body.contracts[0];
      if (!contract.dependency_model_checked) continue;
      const native = contract.diagnostics
        .filter((d: any) => d.source === "appport.lintDependencyModel")
        .map((d: any) => ({ severity: d.severity, path: d.path, message: d.message }));
      expect({ case: i, issues: native }).toEqual({ case: i, issues: reference });
      compared++;
    }
    expect(compared).toBeGreaterThan(cases / 2);
  }, 60000);
});
