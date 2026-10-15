//! Integration-graph knowledge ported from `@appport/integration` 1.1.0.
//!
//! Supported:
//! - `deriveGraph` for published manifests only: application, capability,
//!   event, and resource nodes; `invokes`, `observes`, `delegates`,
//!   `consumes-event`, `reads`, `changes`, `emits`, `verified-by`, and `owns`
//!   edges, all with `declared` provenance; coverage and unresolved-target
//!   unknowns; ownership, foreign-write, and cycle risks; resource relations.
//! - `findCapabilities` for every selector criterion except `concept`.
//!
//! Not supported, and reported as such instead of approximated: mapping
//! artifacts and `data-flow` edges, inferred or observed findings, observation
//! coverage, `concept` selectors, `planIntegration`, `compareBehavior`, and
//! `assessReplacement`.
//!
//! Output ordering uses byte order where the reference uses `localeCompare`.

const std = @import("std");
const knowledge = @import("knowledge.zig");
const names = @import("names.zig");

const Allocator = std.mem.Allocator;
const Manifest = knowledge.Manifest;

pub const Evidence = struct {
    provenance: []const u8 = "declared",
    source: []const u8,
    detail: []const u8,
};

pub const Attributes = struct {
    operations: []const []const u8,
};

pub const Node = struct {
    id: []const u8,
    kind: []const u8,
    label: []const u8,
    application: ?[]const u8 = null,
    resolved: bool,
};

pub const Edge = struct {
    id: []const u8,
    kind: []const u8,
    from: []const u8,
    to: []const u8,
    provenance: []const []const u8,
    evidence: []const Evidence,
    required: ?bool = null,
    resolved: bool,
    attributes: ?Attributes = null,
};

pub const Finding = struct {
    id: []const u8,
    kind: []const u8,
    severity: ?[]const u8 = null,
    subject: []const u8,
    message: []const u8,
    edges: ?[]const []const u8 = null,
};

pub const ResourceRelation = struct {
    resource: []const u8,
    applications: []const []const u8,
    identity: []const u8,
    semantics: []const u8,
    ownership: []const u8,
    owners: []const []const u8,
    physicalSharing: []const u8 = "unknown",
};

pub const Graph = struct {
    nodes: []const Node,
    edges: []const Edge,
    unknowns: []const Finding,
    risks: []const Finding,
    resourceRelations: []const ResourceRelation,
    cycles: []const []const []const u8,
    boundary: struct {
        applications: []const []const u8,
        mappings: []const []const u8 = &.{},
        findingSources: []const []const u8 = &.{},
        observation: []const []const u8 = &.{},
    },
    summary: struct {
        nodes: usize,
        edges: usize,
        byProvenance: struct { declared: usize, inferred: usize = 0, observed: usize = 0 },
        unknowns: usize,
        risks: usize,
    },
};

const MutableEdge = struct {
    edge: Edge,
    evidence: std.ArrayList(Evidence),
};

const Claim = struct {
    application: []const u8,
    resource: ?*const knowledge.Resource,
};

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sortStrings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, lessThanString);
}

fn uniqueSorted(arena: Allocator, items: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        const seen = for (out.items) |existing| {
            if (std.mem.eql(u8, existing, item)) break true;
        } else false;
        if (!seen) try out.append(arena, item);
    }
    sortStrings(out.items);
    return out.items;
}

const Builder = struct {
    arena: Allocator,
    manifests: []const Manifest,
    nodes: std.StringArrayHashMapUnmanaged(Node) = .empty,
    edges: std.StringArrayHashMapUnmanaged(MutableEdge) = .empty,
    unknowns: std.StringArrayHashMapUnmanaged(Finding) = .empty,
    risks: std.StringArrayHashMapUnmanaged(Finding) = .empty,
    claims: std.StringArrayHashMapUnmanaged(std.ArrayList(Claim)) = .empty,

    fn print(self: *Builder, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.arena, fmt, args);
    }

    /// `manifests.get(id)`: the last supplied manifest with that id.
    fn manifestFor(self: *Builder, application: []const u8) ?*const Manifest {
        var i = self.manifests.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.manifests[i].application.id, application)) return &self.manifests[i];
        }
        return null;
    }

    fn addNode(self: *Builder, id: []const u8, kind: []const u8, label: []const u8, resolved: bool, application: ?[]const u8) !void {
        const gop = try self.nodes.getOrPut(self.arena, id);
        if (gop.found_existing) {
            if (resolved) gop.value_ptr.resolved = true;
            return;
        }
        gop.value_ptr.* = .{ .id = id, .kind = kind, .label = label, .resolved = resolved, .application = application };
    }

    fn unknown(self: *Builder, kind: []const u8, subject: []const u8, message: []const u8) !void {
        const id = try self.print("{s}|{s}|{s}", .{ kind, subject, message });
        const gop = try self.unknowns.getOrPut(self.arena, id);
        if (!gop.found_existing) gop.value_ptr.* = .{ .id = id, .kind = kind, .subject = subject, .message = message };
    }

    fn risk(self: *Builder, kind: []const u8, subject: []const u8, message: []const u8, edges: ?[]const []const u8) !void {
        const id = try self.print("{s}|{s}|{s}", .{ kind, subject, message });
        const gop = try self.risks.getOrPut(self.arena, id);
        if (!gop.found_existing) gop.value_ptr.* = .{
            .id = id,
            .kind = kind,
            .severity = "high",
            .subject = subject,
            .message = message,
            .edges = edges,
        };
    }

    const EdgeExtra = struct {
        required: ?bool = null,
        resolved: ?bool = null,
        attributes: ?Attributes = null,
    };

    fn addEdge(self: *Builder, kind: []const u8, from: []const u8, to: []const u8, evidence: Evidence, extra: EdgeExtra) !void {
        const id = try self.print("{s}|{s}|{s}", .{ kind, from, to });
        const gop = try self.edges.getOrPut(self.arena, id);
        if (gop.found_existing) {
            const existing = gop.value_ptr;
            try existing.evidence.append(self.arena, evidence);
            if (extra.required orelse false) existing.edge.required = true;
            if (extra.resolved) |resolved| if (!resolved) {
                existing.edge.resolved = false;
            };
            if (extra.attributes) |attributes| existing.edge.attributes = attributes;
            return;
        }
        gop.value_ptr.* = .{
            .edge = .{
                .id = id,
                .kind = kind,
                .from = from,
                .to = to,
                .provenance = &.{"declared"},
                .evidence = &.{},
                .required = extra.required,
                .resolved = extra.resolved orelse true,
                .attributes = extra.attributes,
            },
            .evidence = .empty,
        };
        try gop.value_ptr.evidence.append(self.arena, evidence);
    }

    fn claim(self: *Builder, resource: []const u8, application: []const u8, declaration: ?*const knowledge.Resource) !void {
        const gop = try self.claims.getOrPut(self.arena, resource);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.arena, .{ .application = application, .resource = declaration });
    }

    const CapNode = struct { id: []const u8, resolved: bool };

    fn capabilityNode(self: *Builder, application: []const u8, ref: []const u8) !CapNode {
        var resolved = false;
        if (names.parseDependencyRef(ref)) |parsed| if (parsed.version) |version| if (self.manifestFor(application)) |manifest| {
            if (manifest.findCapability(parsed.name)) |entry| {
                for (entry.definitions) |definition| {
                    if (definition.version == version) resolved = true;
                }
            }
        };
        const id = try self.print("cap:{s}:{s}", .{ application, ref });
        try self.addNode(id, "capability", try self.print("{s} {s}", .{ application, ref }), resolved, application);
        return .{ .id = id, .resolved = resolved };
    }

    fn addDependency(self: *Builder, app: []const u8, from: []const u8, ref: ?[]const u8, dependency: knowledge.Dependency, source: []const u8) !void {
        const target_app = dependency.target_application orelse app;
        const relationship = dependency.relationship.label();
        const evidence = Evidence{ .source = source, .detail = try self.print("{s} {s} {s} ({s}{s})", .{
            ref orelse app,
            relationship,
            dependency.target_capability orelse dependency.target_event.?,
            dependency.id,
            if (dependency.required) ", required" else ", optional",
        }) };
        if (dependency.target_event) |event| {
            const id = try self.print("event:{s}:{s}", .{ target_app, event });
            const resolved = if (self.manifestFor(target_app)) |m| m.hasEvent(event) else false;
            try self.addNode(id, "event", try self.print("{s} {s}", .{ target_app, event }), resolved, target_app);
            try self.addEdge("consumes-event", from, id, evidence, .{ .required = dependency.required, .resolved = resolved });
            if (!resolved) try self.unknown("unresolved-target", from, try self.print(
                "{s} consumes event {s} of {s}, which no supplied manifest declares",
                .{ from, event, target_app },
            ));
            return;
        }
        const parsed = names.parseDependencyRef(dependency.target_capability.?) orelse return;
        var versions: std.ArrayList(i64) = .empty;
        if (parsed.version) |version| {
            try versions.append(self.arena, version);
        } else if (self.manifestFor(target_app)) |manifest| {
            if (manifest.findCapability(parsed.name)) |entry| {
                for (entry.definitions) |definition| {
                    if (names.satisfiesVersionConstraint(definition.version, dependency.version_constraint orelse "")) {
                        try versions.append(self.arena, definition.version);
                    }
                }
            }
        }
        if (parsed.version == null and versions.items.len == 0) {
            const label = try self.print("{s} ({s})", .{ parsed.name, dependency.version_constraint orelse "undefined" });
            const id = try self.print("cap:{s}:{s}", .{ target_app, label });
            try self.addNode(id, "capability", try self.print("{s} {s}", .{ target_app, label }), false, target_app);
            try self.addEdge(relationship, from, id, evidence, .{ .required = dependency.required, .resolved = false });
            try self.unknown("unresolved-target", from, try self.print(
                "{s} {s} {s} of {s}, which no supplied manifest satisfies",
                .{ from, relationship, label, target_app },
            ));
            return;
        }
        for (versions.items) |version| {
            const target_ref = try self.print("{s}@{d}", .{ parsed.name, version });
            const node = try self.capabilityNode(target_app, target_ref);
            try self.addEdge(relationship, from, node.id, evidence, .{ .required = dependency.required, .resolved = node.resolved });
            if (!node.resolved) try self.unknown("unresolved-target", from, try self.print(
                "{s} {s} {s} of {s}, which no supplied manifest declares",
                .{ from, relationship, target_ref, target_app },
            ));
        }
    }

    fn addManifest(self: *Builder, manifest: *const Manifest) !void {
        const app = manifest.application.id;
        const app_node = try self.print("app:{s}", .{app});
        try self.addNode(app_node, "application", app, true, app);
        const descriptor = manifest.integration;
        const source = try self.print("manifest:{s}", .{app});
        for (manifest.capabilities) |entry| {
            if (std.mem.startsWith(u8, entry.name, "appport.")) continue;
            for (entry.definitions) |definition| {
                const ref = try self.print("{s}@{d}", .{ entry.name, definition.version });
                const self_node = try self.capabilityNode(app, ref);
                const integration = if (descriptor) |d| d.capability(ref) else null;
                for (definition.emits) |event| {
                    const event_id = try self.print("event:{s}:{s}", .{ app, event });
                    try self.addNode(event_id, "event", try self.print("{s} {s}", .{ app, event }), manifest.hasEvent(event), app);
                    try self.addEdge("emits", self_node.id, event_id, .{ .source = source, .detail = try self.print("{s} emits {s}", .{ ref, event }) }, .{});
                }
                if (integration) |cap| {
                    for (cap.verify) |method| {
                        if (method.kind != .state) continue;
                        const via = method.via orelse continue;
                        const probe = try self.capabilityNode(app, via);
                        try self.addEdge("verified-by", self_node.id, probe.id, .{
                            .source = source,
                            .detail = try self.print("method {s}", .{method.id}),
                        }, .{ .resolved = probe.resolved });
                    }
                    for (cap.requires) |dependency| try self.addDependency(app, self_node.id, ref, dependency, source);
                    for (cap.access) |access| {
                        const resource_id = try self.print("res:{s}", .{access.resource});
                        var declared = false;
                        for (descriptor.?.resources) |resource| {
                            if (std.mem.eql(u8, resource.id, access.resource)) declared = true;
                        }
                        try self.addNode(resource_id, "resource", access.resource, declared, null);
                        const mode = @tagName(access.mode);
                        const detail = if (access.operations) |ops|
                            try self.print("{s} {s} ({s})", .{ ref, mode, try std.mem.join(self.arena, ", ", ops) })
                        else
                            try self.print("{s} {s}", .{ ref, mode });
                        try self.addEdge(mode, self_node.id, resource_id, .{ .source = source, .detail = detail }, .{
                            .attributes = if (access.operations) |ops| .{ .operations = ops } else null,
                        });
                        try self.claim(access.resource, app, null);
                    }
                }
                const dimensions = [_]struct { name: []const u8, noun: []const u8, coverage: ?knowledge.Coverage }{
                    .{ .name = "requires", .noun = "dependencies", .coverage = if (integration) |cap| cap.coverage_requires else null },
                    .{ .name = "access", .noun = "state access", .coverage = if (integration) |cap| cap.coverage_access else null },
                };
                for (dimensions) |dimension| {
                    const coverage = dimension.coverage orelse {
                        try self.unknown("coverage-unstated", self_node.id, try self.print(
                            "{s} does not state whether its declared {s} are complete",
                            .{ ref, dimension.noun },
                        ));
                        continue;
                    };
                    if (coverage == .complete) continue;
                    try self.unknown("coverage-partial", self_node.id, try self.print(
                        "{s} declares its {s} as partial: further {s} exist and are not listed",
                        .{ ref, dimension.name, dimension.noun },
                    ));
                }
            }
        }
        if (descriptor) |d| {
            for (d.requires) |dependency| try self.addDependency(app, app_node, null, dependency, source);
            for (d.resources) |*resource| {
                const id = try self.print("res:{s}", .{resource.id});
                try self.addNode(id, "resource", resource.id, true, null);
                try self.claim(resource.id, app, resource);
                if (resource.owner == .self) try self.addEdge("owns", app_node, id, .{
                    .source = source,
                    .detail = "declares itself the system of record",
                }, .{});
            }
        }
    }

    fn resourceRelations(self: *Builder, owner_of: *std.StringHashMapUnmanaged([]const []const u8)) ![]const ResourceRelation {
        const keys = try self.arena.dupe([]const u8, self.claims.keys());
        sortStrings(keys);
        var relations: std.ArrayList(ResourceRelation) = .empty;
        for (keys) |resource| {
            const claims = self.claims.get(resource).?.items;
            var apps: std.ArrayList([]const u8) = .empty;
            var concepts: std.ArrayList([]const u8) = .empty;
            var declaring: std.ArrayList([]const u8) = .empty;
            var self_owners: std.ArrayList([]const u8) = .empty;
            var all_owners: std.ArrayList([]const u8) = .empty;
            for (claims) |c| {
                try apps.append(self.arena, c.application);
                const declaration = c.resource orelse continue;
                if (declaration.concept) |concept| {
                    try concepts.append(self.arena, concept);
                    try declaring.append(self.arena, c.application);
                }
                switch (declaration.owner) {
                    .self => {
                        const seen = for (self_owners.items) |o| {
                            if (std.mem.eql(u8, o, c.application)) break true;
                        } else false;
                        if (!seen) try self_owners.append(self.arena, c.application);
                        try all_owners.append(self.arena, c.application);
                    },
                    .application => |owner| try all_owners.append(self.arena, owner),
                    .unstated => {},
                }
            }
            const applications = try uniqueSorted(self.arena, apps.items);
            const owners = try uniqueSorted(self.arena, all_owners.items);
            const concept_count = (try uniqueSorted(self.arena, concepts.items)).len;
            const declaring_count = (try uniqueSorted(self.arena, declaring.items)).len;
            const ownership: []const u8 = if (owners.len == 0) "no-owner" else blk: {
                if (owners.len == 1) {
                    const all_match = for (self_owners.items) |o| {
                        if (!std.mem.eql(u8, o, owners[0])) break false;
                    } else true;
                    if (all_match) break :blk "single-owner";
                }
                break :blk "conflicting-owners";
            };
            try owner_of.put(self.arena, resource, owners);
            try relations.append(self.arena, .{
                .resource = resource,
                .applications = applications,
                .identity = if (applications.len > 1) "claimed-shared" else "single-application",
                .semantics = if (concept_count == 0) "unstated" else if (concept_count > 1) "different-concepts" else if (declaring_count == applications.len) "same-concept" else "unstated",
                .ownership = ownership,
                .owners = owners,
            });
            if (std.mem.eql(u8, ownership, "conflicting-owners")) {
                const message = if (self_owners.items.len > 1)
                    try self.print("{s}: {s} each declare themselves the system of record", .{ resource, try std.mem.join(self.arena, " and ", self_owners.items) })
                else
                    try self.print("{s}: applications disagree about who owns it ({s})", .{ resource, try std.mem.join(self.arena, ", ", owners) });
                try self.risk("conflicting-ownership", try self.print("res:{s}", .{resource}), message, null);
            }
        }
        return relations.items;
    }
};

/// Derives the declared capability graph for `manifests`. All memory is
/// owned by `arena`.
pub fn deriveGraph(arena: Allocator, manifests: []const Manifest) !Graph {
    var b = Builder{ .arena = arena, .manifests = manifests };
    for (manifests) |*manifest| try b.addManifest(manifest);

    var owner_of: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    const relations = try b.resourceRelations(&owner_of);

    for (b.edges.values()) |*mutable| {
        const edge = mutable.edge;
        if (!std.mem.eql(u8, edge.kind, "changes") or !std.mem.startsWith(u8, edge.to, "res:")) continue;
        const resource = edge.to[4..];
        const owners = owner_of.get(resource) orelse &.{};
        const writer: ?[]const u8 = if (std.mem.startsWith(u8, edge.from, "cap:"))
            edge.from[4 .. 4 + (std.mem.findScalar(u8, edge.from[4..], ':') orelse 0)]
        else if (std.mem.startsWith(u8, edge.from, "app:"))
            edge.from[4..]
        else
            null;
        if (writer) |w| if (owners.len == 1 and !std.mem.eql(u8, owners[0], w)) {
            const edge_ids = try arena.dupe([]const u8, &.{edge.id});
            try b.risk("writes-foreign-resource", edge.from, try b.print(
                "{s} changes {s}, whose declared owner is {s}: the write does not go through the owner's capabilities (declared)",
                .{ edge.from, resource, owners[0] },
            ), edge_ids);
        };
    }

    // Cycles of required synchronous declared edges between resolved nodes.
    var adjacency: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    for (b.edges.values()) |mutable| {
        const edge = mutable.edge;
        const sync = std.mem.eql(u8, edge.kind, "invokes") or std.mem.eql(u8, edge.kind, "observes");
        if (!sync or !(edge.required orelse false) or !edge.resolved) continue;
        const gop = try adjacency.getOrPut(arena, edge.from);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, edge.to);
    }
    var cycles: std.ArrayList([]const []const u8) = .empty;
    var state: std.StringHashMapUnmanaged(bool) = .empty; // true = visiting
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const starts = try arena.dupe([]const u8, adjacency.keys());
    sortStrings(starts);
    const Visitor = struct {
        fn visit(
            builder: *Builder,
            adj: *std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)),
            st: *std.StringHashMapUnmanaged(bool),
            seen_cycles: *std.StringHashMapUnmanaged(void),
            out: *std.ArrayList([]const []const u8),
            node: []const u8,
            trail: *std.ArrayList([]const u8),
        ) !void {
            const a = builder.arena;
            try st.put(a, node, true);
            const next_nodes = if (adj.get(node)) |list| list.items else &.{};
            for (next_nodes) |next| {
                if (st.get(next)) |visiting| {
                    if (!visiting) continue;
                    var start: usize = 0;
                    for (trail.items, 0..) |t, i| if (std.mem.eql(u8, t, next)) {
                        start = i;
                        break;
                    };
                    var cycle: std.ArrayList([]const u8) = .empty;
                    try cycle.appendSlice(a, trail.items[start..]);
                    try cycle.append(a, next);
                    const unique = try uniqueSorted(a, cycle.items);
                    const id = try std.mem.join(a, "|", unique);
                    if (seen_cycles.contains(id)) continue;
                    try seen_cycles.put(a, id, {});
                    try out.append(a, cycle.items);
                    try builder.risk("required-synchronous-cycle", cycle.items[0], try builder.print(
                        "required synchronous dependency cycle: {s}",
                        .{try std.mem.join(a, " → ", cycle.items)},
                    ), null);
                } else {
                    try trail.append(a, next);
                    try visit(builder, adj, st, seen_cycles, out, next, trail);
                    _ = trail.pop();
                }
            }
            try st.put(a, node, false);
        }
    };
    for (starts) |node| {
        if (state.contains(node)) continue;
        var trail: std.ArrayList([]const u8) = .empty;
        try trail.append(arena, node);
        try Visitor.visit(&b, &adjacency, &state, &seen, &cycles, node, &trail);
    }

    var app_ids: std.ArrayList([]const u8) = .empty;
    for (manifests) |m| try app_ids.append(arena, m.application.id);
    const applications = try uniqueSorted(arena, app_ids.items);
    try b.unknown("consumers-open", "graph", try b.print(
        "consumers are known only from the supplied manifests ({s}) and findings (none); any other caller of these capabilities is unknown",
        .{if (applications.len == 0) "none" else try std.mem.join(arena, ", ", applications)},
    ));

    var edges: std.ArrayList(Edge) = .empty;
    for (b.edges.values()) |mutable| {
        var edge = mutable.edge;
        edge.evidence = mutable.evidence.items;
        try edges.append(arena, edge);
    }
    std.mem.sort(Edge, edges.items, {}, struct {
        fn lt(_: void, x: Edge, y: Edge) bool {
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.lt);
    const nodes = try arena.dupe(Node, b.nodes.values());
    std.mem.sort(Node, nodes, {}, struct {
        fn lt(_: void, x: Node, y: Node) bool {
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.lt);
    const finding_lt = struct {
        fn lt(_: void, x: Finding, y: Finding) bool {
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.lt;
    const unknowns = try arena.dupe(Finding, b.unknowns.values());
    std.mem.sort(Finding, unknowns, {}, finding_lt);
    const risks = try arena.dupe(Finding, b.risks.values());
    std.mem.sort(Finding, risks, {}, finding_lt);

    return .{
        .nodes = nodes,
        .edges = edges.items,
        .unknowns = unknowns,
        .risks = risks,
        .resourceRelations = relations,
        .cycles = cycles.items,
        .boundary = .{ .applications = applications },
        .summary = .{
            .nodes = nodes.len,
            .edges = edges.items.len,
            .byProvenance = .{ .declared = edges.items.len },
            .unknowns = unknowns.len,
            .risks = risks.len,
        },
    };
}

pub const Selector = struct {
    application: ?[]const u8 = null,
    /// `name` or `name@version`.
    capability: ?[]const u8 = null,
    reads: ?[]const u8 = null,
    changes: ?[]const u8 = null,
    operation: ?[]const u8 = null,
    effect_type: ?[]const u8 = null,
    /// Not supported natively. A selector with a concept returns
    /// `error.UnsupportedSelector`.
    concept: ?[]const u8 = null,
};

pub const Match = struct {
    application: []const u8,
    capability: []const u8,
    matchedOn: []const []const u8,
};

pub const Undeclared = struct {
    application: []const u8,
    capability: []const u8,
};

pub const FindResult = struct {
    matches: []const Match,
    undeclared: []const Undeclared,
};

/// Port of `findCapabilities`. Selector criteria match only published
/// fields; prose is never matched. A capability without an integration entry
/// is reported as undeclared, which means unknown, not "no".
pub fn findCapabilities(arena: Allocator, manifests: []const Manifest, selector: Selector) !FindResult {
    if (selector.concept != null) return error.UnsupportedSelector;
    var matches: std.ArrayList(Match) = .empty;
    var undeclared: std.ArrayList(Undeclared) = .empty;
    const wants_descriptor = selector.reads != null or selector.changes != null or selector.operation != null or selector.effect_type != null;
    const pinned = if (selector.capability) |c| std.mem.findScalar(u8, c, '@') != null else false;
    for (manifests) |*manifest| {
        if (selector.application) |app| if (!std.mem.eql(u8, manifest.application.id, app)) continue;
        for (manifest.capabilities) |entry| {
            for (entry.definitions) |definition| {
                if (definition.kind != .request) continue;
                const key = try std.fmt.allocPrint(arena, "{s}@{d}", .{ entry.name, definition.version });
                if (selector.capability) |c| if (!std.mem.eql(u8, c, key) and !std.mem.eql(u8, c, entry.name)) continue;
                if (definition.deprecated and !pinned) continue;
                const integration = if (manifest.integration) |d| d.capability(key) else null;
                var matched_on: std.ArrayList([]const u8) = .empty;
                if (selector.capability != null) try matched_on.append(arena, try std.fmt.allocPrint(arena, "capability:{s}", .{key}));
                if (wants_descriptor and integration == null) {
                    if (std.mem.startsWith(u8, entry.name, "appport.")) continue;
                    try undeclared.append(arena, .{ .application = manifest.application.id, .capability = key });
                    continue;
                }
                const access = if (integration) |i| i.access else &.{};
                var ok = true;
                if (selector.reads) |resource| {
                    const hit = for (access) |a| {
                        if (a.mode == .reads and std.mem.eql(u8, a.resource, resource)) break true;
                    } else false;
                    ok = ok and hit;
                    if (hit) try matched_on.append(arena, try std.fmt.allocPrint(arena, "access:reads:{s}", .{resource}));
                }
                if (selector.changes) |resource| {
                    const hit = for (access) |a| {
                        if (a.mode != .changes or !std.mem.eql(u8, a.resource, resource)) continue;
                        const operation = selector.operation orelse break true;
                        const ops = a.operations orelse &.{};
                        const has = for (ops) |op| {
                            if (std.mem.eql(u8, op, operation)) break true;
                        } else false;
                        if (has) break true;
                    } else false;
                    ok = ok and hit;
                    if (hit) try matched_on.append(arena, try std.fmt.allocPrint(arena, "access:changes:{s}", .{resource}));
                } else if (selector.operation != null) ok = false;
                if (selector.effect_type) |effect_type| {
                    const effects = if (integration) |i| i.effects else &.{};
                    const hit = for (effects) |e| {
                        if (std.mem.eql(u8, e, effect_type)) break true;
                    } else false;
                    ok = ok and hit;
                    if (hit) try matched_on.append(arena, try std.fmt.allocPrint(arena, "effect:{s}", .{effect_type}));
                }
                if (matched_on.items.len == 0) continue;
                if (ok) try matches.append(arena, .{ .application = manifest.application.id, .capability = key, .matchedOn = matched_on.items });
            }
        }
    }
    std.mem.sort(Match, matches.items, {}, struct {
        fn lt(_: void, x: Match, y: Match) bool {
            return switch (std.mem.order(u8, x.application, y.application)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.lessThan(u8, x.capability, y.capability),
            };
        }
    }.lt);
    std.mem.sort(Undeclared, undeclared.items, {}, struct {
        fn lt(_: void, x: Undeclared, y: Undeclared) bool {
            return switch (std.mem.order(u8, x.application, y.application)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.lessThan(u8, x.capability, y.capability),
            };
        }
    }.lt);
    return .{ .matches = matches.items, .undeclared = undeclared.items };
}

/// Integration operations from `@appport/integration` that fx does not
/// implement natively. Requests for them are reported, not approximated.
pub const unsupported_operations = [_][]const u8{ "planIntegration", "compareBehavior", "assessReplacement" };

const test_manifest =
    \\{"protocol":"appport/1","application":{"id":"com.example.docs","name":"Docs","version":"1"},"events":[{"name":"docs.saved","definitions":[]}],"transports":[],
    \\"capabilities":[
    \\{"name":"docs.save","versions":[1],"latestVersion":1,"kind":"request","inputSchema":{},"outputSchema":{},"authorization":[],"definitions":[{"version":1,"kind":"request","inputSchema":{},"outputSchema":{},"authorization":[],"effect":"consequential","emits":["docs.saved"]}]},
    \\{"name":"docs.get","versions":[1],"latestVersion":1,"kind":"request","inputSchema":{},"outputSchema":{},"authorization":[],"definitions":[{"version":1,"kind":"request","inputSchema":{},"outputSchema":{},"authorization":[],"effect":"observation"}]}],
    \\"attributes":{"appport.integration/1":{"resources":[{"id":"urn:docs:document","owner":"self"}],
    \\"capabilities":{"docs.save@1":{"effects":[{"type":"urn:effect:save"}],"requires":[{"id":"r","relationship":"observes","target":{"capability":"docs.get@1"},"required":true},
    \\{"id":"bill","relationship":"invokes","target":{"application":"com.example.billing","capability":"billing.charge@2"},"required":false}],
    \\"access":[{"resource":"urn:docs:document","mode":"changes","operations":["update"]}],"coverage":{"requires":"complete","access":"partial"},
    \\"verify":[{"id":"readback","kind":"state","via":{"capability":"docs.get","version":1,"input":{}},"expect":[]}]}}}}}
;

test "deriveGraph reports declared edges, unknowns, and boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try knowledge.parse(arena, test_manifest);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.len);
    const graph = try deriveGraph(arena, &.{parsed.manifest.?});

    var kinds: std.ArrayList([]const u8) = .empty;
    for (graph.edges) |edge| try kinds.append(arena, edge.id);
    const expected_edges = [_][]const u8{
        "changes|cap:com.example.docs:docs.save@1|res:urn:docs:document",
        "emits|cap:com.example.docs:docs.save@1|event:com.example.docs:docs.saved",
        "invokes|cap:com.example.docs:docs.save@1|cap:com.example.billing:billing.charge@2",
        "observes|cap:com.example.docs:docs.save@1|cap:com.example.docs:docs.get@1",
        "owns|app:com.example.docs|res:urn:docs:document",
        "verified-by|cap:com.example.docs:docs.save@1|cap:com.example.docs:docs.get@1",
    };
    try std.testing.expectEqual(expected_edges.len, kinds.items.len);
    for (expected_edges, kinds.items) |want, got| try std.testing.expectEqualStrings(want, got);

    var saw_unresolved = false;
    var saw_partial = false;
    for (graph.unknowns) |u| {
        if (std.mem.eql(u8, u.kind, "unresolved-target")) saw_unresolved = true;
        if (std.mem.eql(u8, u.kind, "coverage-partial")) saw_partial = true;
    }
    try std.testing.expect(saw_unresolved and saw_partial);
    try std.testing.expectEqual(@as(usize, 0), graph.risks.len);
    try std.testing.expectEqualStrings("single-owner", graph.resourceRelations[0].ownership);
}

test "findCapabilities matches only published fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const manifest = (try knowledge.parse(arena, test_manifest)).manifest.?;
    const changes = try findCapabilities(arena, &.{manifest}, .{ .changes = "urn:docs:document", .operation = "update" });
    try std.testing.expectEqual(@as(usize, 1), changes.matches.len);
    try std.testing.expectEqualStrings("docs.save@1", changes.matches[0].capability);
    try std.testing.expectEqual(@as(usize, 1), changes.undeclared.len);
    const wrong_op = try findCapabilities(arena, &.{manifest}, .{ .changes = "urn:docs:document", .operation = "delete" });
    try std.testing.expectEqual(@as(usize, 0), wrong_op.matches.len);
    const empty = try findCapabilities(arena, &.{manifest}, .{});
    try std.testing.expectEqual(@as(usize, 0), empty.matches.len);
    try std.testing.expectError(error.UnsupportedSelector, findCapabilities(arena, &.{manifest}, .{ .concept = "urn:x" }));
}
