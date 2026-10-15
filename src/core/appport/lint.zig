//! Native port of `lintDependencyModel` from `@appport/protocol` 1.1.0.
//!
//! It checks `requires`, `resources`, `access`, and `coverage` in the
//! integration descriptor against the rest of the manifest. The port keeps the
//! reference order of checks, paths, and message text so parity can compare
//! results exactly. It runs only on documents that passed the structural
//! checks in `knowledge.zig`, which reject the shapes that make the
//! reference throw.

const std = @import("std");
const knowledge = @import("knowledge.zig");
const names = @import("names.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Diagnostic = knowledge.Diagnostic;

const relationships = [_][]const u8{ "invokes", "observes", "delegates", "consumes-event" };
const resource_kinds = [_][]const u8{ "entity", "collection", "counter", "document", "stream" };
const resource_operations = [_][]const u8{ "create", "update", "delete" };
const coverage_keys = [_][]const u8{ "requires", "access", "preconditions", "failures" };
const sync_relationships = [_][]const u8{ "invokes", "observes" };

fn oneOf(value: ?Value, comptime set: []const []const u8) bool {
    const v = value orelse return false;
    if (v != .string) return false;
    for (set) |item| if (std.mem.eql(u8, item, v.string)) return true;
    return false;
}

fn isString(value: ?Value, text: []const u8) bool {
    const v = value orelse return false;
    return v == .string and std.mem.eql(u8, v.string, text);
}

/// JavaScript template-literal rendering of a JSON value, where an absent
/// key renders as `undefined`.
fn jsText(arena: Allocator, value: ?Value) Allocator.Error![]const u8 {
    const v = value orelse return "undefined";
    return switch (v) {
        .null => "null",
        .bool => |b| if (b) "true" else "false",
        .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .float => |f| if (knowledge.integerValue(v)) |n| try std.fmt.allocPrint(arena, "{d}", .{n}) else try std.fmt.allocPrint(arena, "{d}", .{f}),
        .number_string => |s| s,
        .string => |s| s,
        .array => |array| blk: {
            // `Array.prototype.toString`: elements joined by commas, with
            // null and undefined rendered as empty strings.
            var parts: std.ArrayList([]const u8) = .empty;
            for (array.items) |item| try parts.append(arena, if (item == .null) "" else try jsText(arena, item));
            break :blk try std.mem.join(arena, ",", parts.items);
        },
        .object => "[object Object]",
    };
}

const VisitState = enum { visiting, done };

const Linter = struct {
    arena: Allocator,
    out: *std.ArrayList(Diagnostic),
    manifest: ObjectMap,
    self_id: ?[]const u8,
    /// Required synchronous same-application edges, in insertion order.
    edges: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,

    fn issue(self: *Linter, severity: knowledge.Severity, path: []const u8, message: []const u8) !void {
        try self.out.append(self.arena, .{
            .source = .dependency_model,
            .category = .inconsistent,
            .severity = severity,
            .path = path,
            .message = message,
        });
    }

    fn err(self: *Linter, path: []const u8, comptime fmt: []const u8, args: anytype) !void {
        try self.issue(.@"error", path, try std.fmt.allocPrint(self.arena, fmt, args));
    }

    fn warn(self: *Linter, path: []const u8, comptime fmt: []const u8, args: anytype) !void {
        try self.issue(.warning, path, try std.fmt.allocPrint(self.arena, fmt, args));
    }

    fn items(object: ObjectMap, key: []const u8) []const Value {
        const value = object.get(key) orelse return &.{};
        return if (value == .array) value.array.items else &.{};
    }

    /// `manifest.capabilities.find(c => c.name === name)?.definitions`.
    fn definitionsOf(self: *Linter, name: []const u8) []const Value {
        for (items(self.manifest, "capabilities")) |entry| {
            if (entry != .object) continue;
            if (isString(entry.object.get("name"), name)) return items(entry.object, "definitions");
        }
        return &.{};
    }

    fn definitionVersion(definition: Value) ?i64 {
        if (definition != .object) return null;
        return knowledge.integerValue(definition.object.get("version") orelse return null);
    }

    fn hasEvent(self: *Linter, name: []const u8) bool {
        for (items(self.manifest, "events")) |event| {
            if (event == .object and isString(event.object.get("name"), name)) return true;
        }
        return false;
    }

    fn addEdge(self: *Linter, from: []const u8, to: []const u8) !void {
        const gop = try self.edges.getOrPut(self.arena, from);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.arena, to);
    }

    fn checkDependencies(self: *Linter, owner: []const u8, dependencies: []const Value, from: ?[]const u8) !void {
        var ids: std.StringHashMapUnmanaged(void) = .empty;
        for (dependencies, 0..) |dep_value, index| {
            const path = try std.fmt.allocPrint(self.arena, "{s}.requires[{d}]", .{ owner, index });
            if (dep_value != .object) continue;
            const dependency = dep_value.object;
            const id = dependency.get("id");
            if (id == null or id.? != .string or id.?.string.len == 0) {
                try self.err(path, "a dependency needs an id", .{});
            } else if (ids.contains(id.?.string)) {
                try self.err(path, "duplicate dependency id \"{s}\"", .{id.?.string});
            } else try ids.put(self.arena, id.?.string, {});

            const relationship = dependency.get("relationship");
            if (!oneOf(relationship, &relationships)) {
                try self.err(path, "relationship must be one of invokes, observes, delegates, consumes-event", .{});
            }
            const required = dependency.get("required");
            if (required == null or required.? != .bool) try self.err(path, "required must be true or false", .{});
            const constraint: ?[]const u8 = if (dependency.get("versionConstraint")) |v| (if (v == .string) v.string else "") else null;
            if (constraint) |vc| if (!names.isVersionConstraint(vc)) {
                try self.err(try std.fmt.allocPrint(self.arena, "{s}.versionConstraint", .{path}), "not a valid version constraint", .{});
            };

            const target_value = dependency.get("target");
            const target: ObjectMap = blk: {
                const t = target_value orelse break :blk null;
                break :blk switch (t) {
                    .object => |o| o,
                    .array => ObjectMap.empty,
                    else => null,
                };
            } orelse {
                try self.err(path, "a dependency needs a target", .{});
                continue;
            };
            if (target.get("application")) |application| {
                if (application != .string or application.string.len == 0) {
                    try self.err(try std.fmt.allocPrint(self.arena, "{s}.target.application", .{path}), "must be an application id", .{});
                }
            }
            const local = if (target.get("application")) |application|
                (application == .string and self.self_id != null and std.mem.eql(u8, application.string, self.self_id.?))
            else
                true;
            const capability = target.get("capability");
            const event = target.get("event");
            if ((capability == null) == (event == null)) {
                try self.err(try std.fmt.allocPrint(self.arena, "{s}.target", .{path}), "give exactly one of capability / event", .{});
                continue;
            }
            if (event) |event_value| {
                if (!isString(relationship, "consumes-event")) {
                    try self.err(path, "{s} targets a capability, not an event", .{try jsText(self.arena, relationship)});
                }
                const event_name = try jsText(self.arena, event_value);
                if (local and !(event_value == .string and self.hasEvent(event_value.string))) {
                    try self.err(try std.fmt.allocPrint(self.arena, "{s}.target.event", .{path}), "event {s} is not declared", .{event_name});
                }
                continue;
            }
            if (isString(relationship, "consumes-event")) {
                try self.err(path, "consumes-event targets an event", .{});
                continue;
            }
            const capability_text = if (capability.? == .string) capability.?.string else "";
            const ref = names.parseDependencyRef(capability_text) orelse {
                try self.err(try std.fmt.allocPrint(self.arena, "{s}.target.capability", .{path}), "must be name or name@version", .{});
                continue;
            };
            if (ref.version == null and constraint == null) {
                try self.err(path, "an unpinned target needs a versionConstraint", .{});
            }
            if (!local) continue;

            var candidates: std.ArrayList(ObjectMap) = .empty;
            for (self.definitionsOf(ref.name)) |definition| {
                const version = definitionVersion(definition) orelse continue;
                const matches = if (ref.version) |pinned| version == pinned else names.satisfiesVersionConstraint(version, constraint orelse "");
                if (matches) try candidates.append(self.arena, definition.object);
            }
            if (candidates.items.len == 0) {
                try self.err(try std.fmt.allocPrint(self.arena, "{s}.target", .{path}), "{s} is not declared by this application", .{capability_text});
                continue;
            }
            for (candidates.items) |candidate| {
                const version = knowledge.integerValue(candidate.get("version").?).?;
                if (!isString(candidate.get("kind"), "request")) {
                    try self.err(try std.fmt.allocPrint(self.arena, "{s}.target", .{path}), "a dependency target must be a request capability", .{});
                }
                if (isString(relationship, "observes") and !isString(candidate.get("effect"), "observation")) {
                    try self.err(path, "observes {s}@{d}, which is not an observation capability", .{ ref.name, version });
                }
                if (candidate.get("deprecated")) |deprecated| if (deprecated == .bool and deprecated.bool) {
                    try self.warn(path, "{s}@{d} is deprecated", .{ ref.name, version });
                };
                const key = try std.fmt.allocPrint(self.arena, "{s}@{d}", .{ ref.name, version });
                if (from) |f| {
                    if (std.mem.eql(u8, key, f)) try self.err(path, "{s} depends on itself", .{key});
                    const is_required = required != null and required.? == .bool and required.?.bool;
                    if (is_required and oneOf(relationship, &sync_relationships)) try self.addEdge(f, key);
                }
            }
        }
    }

    fn visit(
        self: *Linter,
        node: []const u8,
        trail: *std.ArrayList([]const u8),
        state: *std.StringHashMapUnmanaged(VisitState),
        reported: *std.StringHashMapUnmanaged(void),
    ) !void {
        try state.put(self.arena, node, .visiting);
        const next_nodes = if (self.edges.get(node)) |list| list.items else &.{};
        for (next_nodes) |next| {
            if (state.get(next)) |s| {
                if (s != .visiting) continue;
                var start: usize = 0;
                for (trail.items, 0..) |t, i| if (std.mem.eql(u8, t, next)) {
                    start = i;
                    break;
                };
                var cycle: std.ArrayList([]const u8) = .empty;
                try cycle.appendSlice(self.arena, trail.items[start..]);
                try cycle.append(self.arena, next);
                const sorted = try self.arena.dupe([]const u8, cycle.items);
                std.mem.sort([]const u8, sorted, {}, lessThan);
                const id = try std.mem.join(self.arena, "|", sorted);
                if (!reported.contains(id)) {
                    try reported.put(self.arena, id, {});
                    try self.err("requires", "required synchronous dependency cycle: {s}", .{try std.mem.join(self.arena, " → ", cycle.items)});
                }
            } else {
                try trail.append(self.arena, next);
                try self.visit(next, trail, state, reported);
                _ = trail.pop();
            }
        }
        try state.put(self.arena, node, .done);
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Appends dependency-model issues for `manifest` (the parsed root object) to
/// `out`. Strings are allocated in `arena`.
pub fn lintDependencyModel(arena: Allocator, manifest: ObjectMap, out: *std.ArrayList(Diagnostic)) !void {
    const attributes = manifest.get("attributes") orelse return;
    if (attributes != .object) return;
    const descriptor_value = attributes.object.get(names.integration_extension) orelse return;
    if (descriptor_value != .object) return;
    const descriptor = descriptor_value.object;
    const capabilities = descriptor.get("capabilities") orelse return;
    if (capabilities != .object) return;

    var self_id: ?[]const u8 = null;
    if (manifest.get("application")) |application| if (application == .object) {
        if (application.object.get("id")) |id| if (id == .string) {
            self_id = id.string;
        };
    };
    var linter = Linter{ .arena = arena, .out = out, .manifest = manifest, .self_id = self_id };

    var declared: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (Linter.items(descriptor, "resources"), 0..) |resource_value, index| {
        const path = try std.fmt.allocPrint(arena, "resources[{d}]", .{index});
        if (resource_value != .object) continue;
        const resource = resource_value.object;
        const id = resource.get("id");
        if (id == null or id.? != .string or !names.isIri(id.?.string)) {
            try linter.err(path, "id must be an absolute IRI", .{});
        } else {
            const text = id.?.string;
            if (names.hasDatabaseScheme(text)) try linter.err(path, "a resource id is a logical identity: it must not be a database, queue or file locator", .{});
            if (names.hasUserinfo(text)) try linter.err(path, "a resource id must not embed credentials", .{});
            if (declared.contains(text)) try linter.err(path, "resource {s} is declared twice", .{text});
            try declared.put(arena, text, {});
        }
        if (resource.get("kind")) |kind| if (!oneOf(kind, &resource_kinds)) {
            try linter.err(try std.fmt.allocPrint(arena, "{s}.kind", .{path}), "must be one of entity, collection, counter, document, stream", .{});
        };
        if (resource.get("concept")) |concept| if (!(concept == .string and names.isIri(concept.string))) {
            try linter.err(try std.fmt.allocPrint(arena, "{s}.concept", .{path}), "must be an absolute IRI", .{});
        };
        if (resource.get("owner")) |owner| {
            const is_self = owner == .string and std.mem.eql(u8, owner.string, "self");
            const application: ?Value = if (owner == .object) owner.object.get("application") else null;
            const valid_object = application != null and application.? == .string and application.?.string.len > 0;
            if (!is_self and !valid_object) {
                try linter.err(try std.fmt.allocPrint(arena, "{s}.owner", .{path}), "must be \"self\" or {{ application }}", .{});
            }
            if (owner == .object and application != null and application.? == .string and self_id != null and std.mem.eql(u8, application.?.string, self_id.?)) {
                try linter.err(try std.fmt.allocPrint(arena, "{s}.owner", .{path}), "an application that owns a resource says \"self\"", .{});
            }
        }
    }

    var it = capabilities.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        if (kv.value_ptr.* != .object) continue;
        const entry = kv.value_ptr.object;
        const split = names.splitIntegrationKey(key) orelse continue;
        var definition: ?ObjectMap = null;
        for (linter.definitionsOf(split.name)) |d| {
            if (Linter.definitionVersion(d) == split.version.?) {
                definition = d.object;
                break;
            }
        }
        const def = definition orelse continue;
        const owner = try std.fmt.allocPrint(arena, "capabilities[{s}]", .{key});
        try linter.checkDependencies(owner, Linter.items(entry, "requires"), key);

        const access = Linter.items(entry, "access");
        for (access, 0..) |access_value, index| {
            const path = try std.fmt.allocPrint(arena, "capabilities[{s}].access[{d}]", .{ key, index });
            if (access_value != .object) continue;
            const a = access_value.object;
            const resource = a.get("resource");
            if (!(resource != null and resource.? == .string and declared.contains(resource.?.string))) {
                try linter.err(path, "resource {s} is not declared in resources", .{try jsText(arena, resource)});
            }
            const mode = a.get("mode");
            if (!isString(mode, "reads") and !isString(mode, "changes")) {
                try linter.err(path, "mode must be \"reads\" or \"changes\"", .{});
            }
            if (a.get("operations")) |operations| {
                if (!isString(mode, "changes")) try linter.err(path, "operations apply only to changes", .{});
                const ops = if (operations == .array) operations.array.items else &[_]Value{};
                var all_known = true;
                for (ops) |op| if (!oneOf(op, &resource_operations)) {
                    all_known = false;
                };
                if (ops.len == 0 or !all_known) {
                    try linter.err(path, "operations must be a non-empty subset of create, update, delete", .{});
                }
            }
            if (isString(mode, "changes") and isString(def.get("effect"), "observation")) {
                try linter.err(path, "{s} is an observation capability and cannot change state", .{key});
            }
        }

        const coverage: ?ObjectMap = if (entry.get("coverage")) |c| (if (c == .object) c.object else null) else null;
        if (coverage) |cov| {
            var cov_it = cov.iterator();
            while (cov_it.next()) |field| {
                const known = for (coverage_keys) |k| {
                    if (std.mem.eql(u8, k, field.key_ptr.*)) break true;
                } else false;
                if (!known or !(isString(field.value_ptr.*, "complete") or isString(field.value_ptr.*, "partial"))) {
                    try linter.err(try std.fmt.allocPrint(arena, "capabilities[{s}].coverage", .{key}), "{s}: must be \"complete\" or \"partial\"", .{field.key_ptr.*});
                }
            }
            if (isString(cov.get("access"), "complete") and isString(def.get("effect"), "consequential")) {
                var changes = false;
                for (access) |a| if (a == .object and isString(a.object.get("mode"), "changes")) {
                    changes = true;
                };
                if (!changes) try linter.warn(
                    try std.fmt.allocPrint(arena, "capabilities[{s}].access", .{key}),
                    "claims complete access but a consequential capability declares no resource it changes",
                    .{},
                );
            }
        }
    }
    try linter.checkDependencies("descriptor", Linter.items(descriptor, "requires"), null);

    var state: std.StringHashMapUnmanaged(VisitState) = .empty;
    var reported: std.StringHashMapUnmanaged(void) = .empty;
    for (linter.edges.keys()) |node| {
        if (state.contains(node)) continue;
        var trail: std.ArrayList([]const u8) = .empty;
        try trail.append(arena, node);
        try linter.visit(node, &trail, &state, &reported);
    }
}

fn lintText(arena: Allocator, json: []const u8) ![]const Diagnostic {
    const parsed = try knowledge.parse(arena, json);
    var out: std.ArrayList(Diagnostic) = .empty;
    try lintDependencyModel(arena, parsed.value.?.object, &out);
    return out.items;
}

const manifest_prefix =
    \\{"protocol":"appport/1","application":{"id":"com.example.docs","name":"Docs","version":"1"},"events":[{"name":"docs.saved","definitions":[]}],"transports":[],
    \\"capabilities":[
    \\{"name":"docs.save","versions":[1],"latestVersion":1,"kind":"request","inputSchema":{},"outputSchema":{},"authorization":[],"definitions":[{"version":1,"kind":"request","inputSchema":{},"outputSchema":{},"authorization":[],"effect":"consequential"}]},
    \\{"name":"docs.get","versions":[1],"latestVersion":1,"kind":"request","inputSchema":{},"outputSchema":{},"authorization":[],"definitions":[{"version":1,"kind":"request","inputSchema":{},"outputSchema":{},"authorization":[],"effect":"observation"}]}],
    \\"attributes":{"appport.integration/1":
;

test "a consistent dependency model has no issues" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const issues = try lintText(arena_state.allocator(), manifest_prefix ++
        \\{"resources":[{"id":"urn:docs:document","kind":"document","owner":"self"}],
        \\"capabilities":{"docs.save@1":{"requires":[{"id":"read","relationship":"observes","target":{"capability":"docs.get@1"},"required":true}],
        \\"access":[{"resource":"urn:docs:document","mode":"changes","operations":["update"]}],"coverage":{"requires":"complete","access":"complete"}}}}}}
    );
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "dependency inconsistencies produce reference diagnostics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const issues = try lintText(arena_state.allocator(), manifest_prefix ++
        \\{"resources":[{"id":"postgres://db/docs"}],
        \\"capabilities":{"docs.get@1":{"requires":[{"id":"x","relationship":"observes","target":{"capability":"docs.save@1"},"required":true},
        \\{"id":"x","relationship":"invokes","target":{"capability":"docs.missing"},"required":"yes"}],
        \\"access":[{"resource":"urn:none","mode":"changes"}]}}}}}
    );
    const expected = [_][2][]const u8{
        .{ "resources[0]", "a resource id is a logical identity: it must not be a database, queue or file locator" },
        .{ "capabilities[docs.get@1].requires[0]", "observes docs.save@1, which is not an observation capability" },
        .{ "capabilities[docs.get@1].requires[1]", "duplicate dependency id \"x\"" },
        .{ "capabilities[docs.get@1].requires[1]", "required must be true or false" },
        .{ "capabilities[docs.get@1].requires[1]", "an unpinned target needs a versionConstraint" },
        .{ "capabilities[docs.get@1].requires[1].target", "docs.missing is not declared by this application" },
        .{ "capabilities[docs.get@1].access[0]", "resource urn:none is not declared in resources" },
        .{ "capabilities[docs.get@1].access[0]", "docs.get@1 is an observation capability and cannot change state" },
    };
    try std.testing.expectEqual(expected.len, issues.len);
    for (expected, issues) |want, got| {
        try std.testing.expectEqualStrings(want[0], got.path);
        try std.testing.expectEqualStrings(want[1], got.message);
    }
}

test "required synchronous cycles are reported once with their path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const issues = try lintText(arena_state.allocator(), manifest_prefix ++
        \\{"capabilities":{"docs.save@1":{"requires":[{"id":"a","relationship":"invokes","target":{"capability":"docs.get@1"},"required":true}]},
        \\"docs.get@1":{"requires":[{"id":"b","relationship":"invokes","target":{"capability":"docs.save@1"},"required":true}]}}}}}
    );
    try std.testing.expectEqual(@as(usize, 1), issues.len);
    try std.testing.expectEqualStrings("required synchronous dependency cycle: docs.save@1 → docs.get@1 → docs.save@1", issues[0].message);
}
