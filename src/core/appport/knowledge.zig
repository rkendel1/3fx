//! Typed AppPort contract knowledge and structural inspection.
//!
//! An AppPort contract is the application manifest defined by
//! `@appport/protocol` (`AppPortManifest`), with integration metadata in
//! `attributes["appport.integration/1"]`. This file reads that JSON into a
//! small typed model and reports structural problems. It never invents
//! contract content and never consults a model.
//!
//! The published packages do not ship a structural manifest validator, so the
//! structural checks here follow the published TypeScript types and the
//! published name rules (`names.zig`). Diagnostics from these checks carry the
//! `fx.structure` source so they are never mistaken for reference results.
//!
//! All memory is owned by the arena passed in by the caller.

const std = @import("std");
const names = @import("names.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// Maximum accepted contract size. A safety bound, not a format limit.
pub const max_contract_bytes: usize = 4 * 1024 * 1024;

pub const Category = enum {
    /// The JSON shape or a value is wrong.
    malformed,
    /// A required field is absent.
    missing,
    /// The contract uses something fx does not interpret.
    unsupported,
    /// Declarations disagree with each other.
    inconsistent,
};

pub const Severity = enum { @"error", warning };

pub const Source = enum {
    /// fx structural checks against the published TypeScript types.
    structure,
    /// Native port of `lintDependencyModel` from `@appport/protocol`.
    dependency_model,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .structure => "fx.structure",
            .dependency_model => "appport.lintDependencyModel",
        };
    }
};

pub const Diagnostic = struct {
    source: Source,
    category: Category,
    severity: Severity,
    path: []const u8,
    message: []const u8,
};

pub const Verdict = enum {
    valid,
    unsupported,
    inconsistent,
    incomplete,
    malformed,

    /// The strongest verdict implied by a diagnostic list. Errors decide the
    /// verdict; any unsupported diagnostic, even a warning, prevents `valid`.
    pub fn fromDiagnostics(diagnostics: []const Diagnostic) Verdict {
        var verdict: Verdict = .valid;
        for (diagnostics) |d| {
            const implied: Verdict = switch (d.category) {
                .unsupported => .unsupported,
                .malformed => if (d.severity == .@"error") .malformed else .valid,
                .missing => if (d.severity == .@"error") .incomplete else .valid,
                .inconsistent => if (d.severity == .@"error") .inconsistent else .valid,
            };
            if (@intFromEnum(implied) > @intFromEnum(verdict)) verdict = implied;
        }
        return verdict;
    }
};

pub const CapabilityKind = enum { request, stream };
pub const Effect = enum { observation, consequential };
pub const Relationship = enum {
    invokes,
    observes,
    delegates,
    consumes_event,

    pub fn label(self: Relationship) []const u8 {
        return switch (self) {
            .invokes => "invokes",
            .observes => "observes",
            .delegates => "delegates",
            .consumes_event => "consumes-event",
        };
    }

    pub fn parse(text: []const u8) ?Relationship {
        if (std.mem.eql(u8, text, "consumes-event")) return .consumes_event;
        if (std.mem.eql(u8, text, "consumes_event")) return null;
        return std.meta.stringToEnum(Relationship, text);
    }
};
pub const AccessMode = enum { reads, changes };
pub const Coverage = enum { complete, partial };

pub const Owner = union(enum) {
    unstated,
    self,
    application: []const u8,
};

pub const Approval = union(enum) {
    /// The contract does not say. Never read as "no approval required".
    unstated,
    not_required,
    required: ?[]const u8,
};

pub const Field = struct {
    name: []const u8,
    type: ?[]const u8 = null,
    required: bool = false,
    concept: ?[]const u8 = null,
};

/// Top-level object properties of a JSON Schema. Deeper structure is not
/// interpreted.
pub const Schema = struct {
    type: ?[]const u8 = null,
    fields: []const Field = &.{},
};

pub const CapabilityVersion = struct {
    version: i64,
    kind: CapabilityKind,
    description: ?[]const u8 = null,
    input: Schema = .{},
    output: Schema = .{},
    authorization: []const []const u8 = &.{},
    effect: ?Effect = null,
    idempotency: ?[]const u8 = null,
    deprecated: bool = false,
    emits: []const []const u8 = &.{},
};

pub const Capability = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    latest_version: i64,
    definitions: []const CapabilityVersion,
};

pub const Event = struct {
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const Transport = struct {
    kind: []const u8,
    endpoint: ?[]const u8 = null,
};

pub const Dependency = struct {
    id: []const u8,
    relationship: Relationship,
    target_application: ?[]const u8 = null,
    target_capability: ?[]const u8 = null,
    target_event: ?[]const u8 = null,
    required: bool,
    version_constraint: ?[]const u8 = null,
    purpose: ?[]const u8 = null,
};

pub const Access = struct {
    resource: []const u8,
    mode: AccessMode,
    operations: ?[]const []const u8 = null,
};

pub const VerifyMethod = struct {
    id: []const u8,
    kind: enum { state, event },
    /// `name@version` of the observation capability, for state methods.
    via: ?[]const u8 = null,
    via_name: ?[]const u8 = null,
    via_version: ?i64 = null,
    event: ?[]const u8 = null,
};

pub const Failure = struct {
    code: []const u8,
    retry: []const u8,
    effect: []const u8,
};

pub const CapabilityIntegration = struct {
    /// `name@version`.
    key: []const u8,
    purpose: ?[]const u8 = null,
    authority: ?[]const u8 = null,
    effects: []const []const u8 = &.{},
    requires: []const Dependency = &.{},
    access: []const Access = &.{},
    coverage_requires: ?Coverage = null,
    coverage_access: ?Coverage = null,
    approval: Approval = .unstated,
    verify: []const VerifyMethod = &.{},
    preconditions: []const []const u8 = &.{},
    failures: []const Failure = &.{},
};

pub const Resource = struct {
    id: []const u8,
    kind: ?[]const u8 = null,
    concept: ?[]const u8 = null,
    owner: Owner = .unstated,
};

pub const Integration = struct {
    capabilities: []const CapabilityIntegration = &.{},
    requires: []const Dependency = &.{},
    resources: []const Resource = &.{},

    pub fn capability(self: Integration, key: []const u8) ?*const CapabilityIntegration {
        for (self.capabilities) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry;
        }
        return null;
    }
};

pub const Application = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    version: []const u8 = "",
    description: ?[]const u8 = null,
};

pub const Manifest = struct {
    protocol: []const u8 = "",
    application: Application = .{},
    capabilities: []const Capability = &.{},
    events: []const Event = &.{},
    transports: []const Transport = &.{},
    extensions: []const []const u8 = &.{},
    integration: ?Integration = null,

    pub fn findCapability(self: *const Manifest, name: []const u8) ?*const Capability {
        for (self.capabilities) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    pub fn findVersion(self: *const Manifest, name: []const u8, version: i64) ?*const CapabilityVersion {
        const entry = self.findCapability(name) orelse return null;
        for (entry.definitions) |*definition| {
            if (definition.version == version) return definition;
        }
        return null;
    }

    pub fn hasEvent(self: *const Manifest, name: []const u8) bool {
        for (self.events) |event| {
            if (std.mem.eql(u8, event.name, name)) return true;
        }
        return false;
    }
};

/// Result of structural inspection. `value` is the parsed JSON, kept for
/// the dependency-model checks; `manifest` is null when the document is not
/// a JSON object.
pub const Parsed = struct {
    value: ?Value,
    manifest: ?Manifest,
    diagnostics: std.ArrayList(Diagnostic),
};

const known_top_level = [_][]const u8{
    "protocol",    "application", "capabilities", "events",          "transports",
    "conformance", "extensions",  "attributes",   "materialization", "ui",
};

const Checker = struct {
    arena: Allocator,
    diagnostics: *std.ArrayList(Diagnostic),

    fn add(self: Checker, category: Category, severity: Severity, path: []const u8, message: []const u8) !void {
        try self.diagnostics.append(self.arena, .{
            .source = .structure,
            .category = category,
            .severity = severity,
            .path = path,
            .message = message,
        });
    }

    fn malformed(self: Checker, path: []const u8, message: []const u8) !void {
        try self.add(.malformed, .@"error", path, message);
    }

    fn missing(self: Checker, path: []const u8, message: []const u8) !void {
        try self.add(.missing, .@"error", path, message);
    }

    fn join(self: Checker, base: []const u8, key: []const u8) ![]const u8 {
        if (base.len == 0) return key;
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ base, key });
    }

    fn index(self: Checker, base: []const u8, i: usize) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ base, i });
    }

    /// A required string. Reports and returns null when absent or not a string.
    fn requiredString(self: Checker, object: ObjectMap, base: []const u8, key: []const u8) !?[]const u8 {
        const value = object.get(key) orelse {
            try self.missing(try self.join(base, key), "required");
            return null;
        };
        if (value != .string) {
            try self.malformed(try self.join(base, key), "must be a string");
            return null;
        }
        return value.string;
    }

    fn optionalString(self: Checker, object: ObjectMap, base: []const u8, key: []const u8) !?[]const u8 {
        const value = object.get(key) orelse return null;
        if (value != .string) {
            try self.malformed(try self.join(base, key), "must be a string");
            return null;
        }
        return value.string;
    }

    fn optionalBool(self: Checker, object: ObjectMap, base: []const u8, key: []const u8) !?bool {
        const value = object.get(key) orelse return null;
        if (value != .bool) {
            try self.malformed(try self.join(base, key), "must be true or false");
            return null;
        }
        return value.bool;
    }

    fn requiredArray(self: Checker, object: ObjectMap, base: []const u8, key: []const u8) !?[]const Value {
        const value = object.get(key) orelse {
            try self.missing(try self.join(base, key), "required");
            return null;
        };
        if (value != .array) {
            try self.malformed(try self.join(base, key), "must be an array");
            return null;
        }
        return value.array.items;
    }

    fn optionalArray(self: Checker, object: ObjectMap, base: []const u8, key: []const u8) !?[]const Value {
        const value = object.get(key) orelse return null;
        if (value != .array) {
            try self.malformed(try self.join(base, key), "must be an array");
            return null;
        }
        return value.array.items;
    }

    fn stringList(self: Checker, items: []const Value, path: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (items, 0..) |item, i| {
            if (item != .string) {
                try self.malformed(try self.index(path, i), "must be a string");
                continue;
            }
            try out.append(self.arena, item.string);
        }
        return out.items;
    }

    fn positiveVersion(self: Checker, value: ?Value, path: []const u8) !?i64 {
        const v = value orelse {
            try self.missing(path, "required");
            return null;
        };
        const n = integerValue(v) orelse {
            try self.malformed(path, "must be a positive integer");
            return null;
        };
        if (n < 1) {
            try self.malformed(path, "must be a positive integer");
            return null;
        }
        return n;
    }
};

/// A JSON number with an integral value, as JavaScript reads it.
pub fn integerValue(value: Value) ?i64 {
    return switch (value) {
        .integer => |n| n,
        .float => |f| if (@floor(f) == f and @abs(f) < 9.007199254740992e15) @as(i64, @intFromFloat(f)) else null,
        else => null,
    };
}

fn nameDiagnostic(checker: Checker, path: []const u8, name: []const u8) !void {
    switch (names.validateName(name)) {
        .valid => {},
        .invalid => |reason| try checker.malformed(path, reason),
        .reserved_segment => |segment| try checker.malformed(path, try std.fmt.allocPrint(
            checker.arena,
            "name must not contain the transport segment \"{s}\"",
            .{segment},
        )),
    }
}

/// Parses `bytes` as an AppPort manifest. Invalid JSON produces a single
/// malformed diagnostic. Returns `error.OutOfMemory` only.
pub fn parse(arena: Allocator, bytes: []const u8) Allocator.Error!Parsed {
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    const checker = Checker{ .arena = arena, .diagnostics = &diagnostics };
    if (bytes.len > max_contract_bytes) {
        try checker.malformed("", "contract exceeds the 4 MiB inspection limit");
        return .{ .value = null, .manifest = null, .diagnostics = diagnostics };
    }
    if (std.mem.trim(u8, bytes, " \t\r\n").len == 0) {
        try checker.malformed("", "contract is empty");
        return .{ .value = null, .manifest = null, .diagnostics = diagnostics };
    }
    const value = std.json.parseFromSliceLeaky(Value, arena, bytes, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try checker.malformed("", try std.fmt.allocPrint(arena, "not valid JSON ({s})", .{@errorName(err)}));
            return .{ .value = null, .manifest = null, .diagnostics = diagnostics };
        },
    };
    if (value != .object) {
        try checker.malformed("", "a manifest must be a JSON object");
        return .{ .value = value, .manifest = null, .diagnostics = diagnostics };
    }
    const manifest = try readManifest(checker, value.object);
    return .{ .value = value, .manifest = manifest, .diagnostics = diagnostics };
}

fn readManifest(c: Checker, root: ObjectMap) !Manifest {
    var manifest: Manifest = .{};

    var key_it = root.iterator();
    while (key_it.next()) |entry| {
        const key = entry.key_ptr.*;
        var known = false;
        for (known_top_level) |k| {
            if (std.mem.eql(u8, k, key)) known = true;
        }
        if (!known) try c.add(.unsupported, .warning, key, "not an AppPort manifest field; fx does not interpret it");
    }

    if (try c.requiredString(root, "", "protocol")) |protocol| {
        manifest.protocol = protocol;
        if (!std.mem.eql(u8, protocol, names.protocol_id)) {
            try c.add(.unsupported, .@"error", "protocol", try std.fmt.allocPrint(
                c.arena,
                "fx understands {s}, not {s}",
                .{ names.protocol_id, protocol },
            ));
        }
    }

    if (root.get("application")) |application| {
        if (application != .object) {
            try c.malformed("application", "must be an object");
        } else {
            const obj = application.object;
            if (try c.requiredString(obj, "application", "id")) |id| {
                manifest.application.id = id;
                if (!names.isValidApplicationId(id)) {
                    try c.add(.malformed, .warning, "application.id", "not the recommended reverse-domain application id form");
                }
            }
            if (try c.requiredString(obj, "application", "name")) |name| manifest.application.name = name;
            if (try c.requiredString(obj, "application", "version")) |version| manifest.application.version = version;
            manifest.application.description = try c.optionalString(obj, "application", "description");
        }
    } else try c.missing("application", "required");

    if (try c.requiredArray(root, "", "capabilities")) |items| {
        manifest.capabilities = try readCapabilities(c, items);
    }
    if (try c.requiredArray(root, "", "events")) |items| {
        manifest.events = try readEvents(c, items);
    }
    if (try c.requiredArray(root, "", "transports")) |items| {
        var transports: std.ArrayList(Transport) = .empty;
        for (items, 0..) |item, i| {
            const path = try c.index("transports", i);
            if (item != .object) {
                try c.malformed(path, "must be an object");
                continue;
            }
            const kind = try c.requiredString(item.object, path, "kind") orelse continue;
            try transports.append(c.arena, .{ .kind = kind, .endpoint = try c.optionalString(item.object, path, "endpoint") });
        }
        manifest.transports = transports.items;
    }
    if (try c.optionalArray(root, "", "extensions")) |items| {
        manifest.extensions = try c.stringList(items, "extensions");
        for (manifest.extensions, 0..) |extension, i| {
            if (std.mem.eql(u8, extension, names.integration_extension)) continue;
            try c.add(.unsupported, .warning, try c.index("extensions", i), try std.fmt.allocPrint(
                c.arena,
                "extension {s} is not interpreted by fx",
                .{extension},
            ));
        }
    }

    if (root.get("attributes")) |attributes| {
        if (attributes != .object) {
            try c.malformed("attributes", "must be an object");
        } else if (attributes.object.get(names.integration_extension)) |descriptor| {
            manifest.integration = try readIntegration(c, descriptor);
        }
    }
    return manifest;
}

fn readKind(c: Checker, object: ObjectMap, path: []const u8) !?CapabilityKind {
    const text = try c.requiredString(object, path, "kind") orelse return null;
    return std.meta.stringToEnum(CapabilityKind, text) orelse {
        try c.malformed(try c.join(path, "kind"), "must be request or stream");
        return null;
    };
}

fn readSchema(c: Checker, object: ObjectMap, path: []const u8, key: []const u8) !Schema {
    const value = object.get(key) orelse {
        try c.missing(try c.join(path, key), "required");
        return .{};
    };
    if (value == .bool) return .{};
    if (value != .object) {
        try c.malformed(try c.join(path, key), "must be a JSON Schema object");
        return .{};
    }
    const schema = value.object;
    var out: Schema = .{};
    if (schema.get("type")) |t| {
        if (t == .string) out.type = t.string;
    }
    var required_names: []const Value = &.{};
    if (schema.get("required")) |r| {
        if (r == .array) required_names = r.array.items;
    }
    const properties = schema.get("properties") orelse return out;
    if (properties != .object) return out;
    var fields: std.ArrayList(Field) = .empty;
    var it = properties.object.iterator();
    while (it.next()) |entry| {
        var field = Field{ .name = entry.key_ptr.* };
        for (required_names) |r| {
            if (r == .string and std.mem.eql(u8, r.string, field.name)) field.required = true;
        }
        if (entry.value_ptr.* == .object) {
            const prop = entry.value_ptr.object;
            if (prop.get("type")) |t| {
                if (t == .string) field.type = t.string;
            }
            if (prop.get("x-appport-concept")) |concept| {
                if (concept == .string) field.concept = concept.string;
            }
        }
        try fields.append(c.arena, field);
    }
    out.fields = fields.items;
    return out;
}

fn readAuthorization(c: Checker, object: ObjectMap, path: []const u8) ![]const []const u8 {
    const items = try c.requiredArray(object, path, "authorization") orelse return &.{};
    const list_path = try c.join(path, "authorization");
    const scopes = try c.stringList(items, list_path);
    for (scopes, 0..) |scope, i| {
        if (!names.isValidPermission(scope)) {
            try c.malformed(try c.index(list_path, i), "permission must be lowercase <namespace>.<operation>");
        }
    }
    return scopes;
}

fn readCapabilities(c: Checker, items: []const Value) ![]const Capability {
    var out: std.ArrayList(Capability) = .empty;
    for (items, 0..) |item, i| {
        const path = try c.index("capabilities", i);
        if (item != .object) {
            try c.malformed(path, "must be an object");
            continue;
        }
        const obj = item.object;
        const name = try c.requiredString(obj, path, "name") orelse continue;
        try nameDiagnostic(c, try c.join(path, "name"), name);
        for (out.items) |previous| {
            if (std.mem.eql(u8, previous.name, name)) {
                try c.add(.inconsistent, .@"error", try c.join(path, "name"), try std.fmt.allocPrint(
                    c.arena,
                    "capability {s} is declared twice",
                    .{name},
                ));
            }
        }
        _ = try readKind(c, obj, path);
        _ = try readSchema(c, obj, path, "inputSchema");
        _ = try readSchema(c, obj, path, "outputSchema");
        _ = try readAuthorization(c, obj, path);

        var versions: []const i64 = &.{};
        if (try c.requiredArray(obj, path, "versions")) |list| {
            var parsed_versions: std.ArrayList(i64) = .empty;
            for (list, 0..) |v, j| {
                if (try c.positiveVersion(v, try c.index(try c.join(path, "versions"), j))) |n| {
                    try parsed_versions.append(c.arena, n);
                }
            }
            versions = parsed_versions.items;
        }
        const latest = try c.positiveVersion(obj.get("latestVersion"), try c.join(path, "latestVersion"));

        var definitions: std.ArrayList(CapabilityVersion) = .empty;
        if (try c.requiredArray(obj, path, "definitions")) |list| {
            for (list, 0..) |d, j| {
                const dpath = try c.index(try c.join(path, "definitions"), j);
                if (d != .object) {
                    try c.malformed(dpath, "must be an object");
                    continue;
                }
                if (try readDefinition(c, d.object, dpath)) |definition| {
                    for (definitions.items) |previous| {
                        if (previous.version == definition.version) {
                            try c.add(.inconsistent, .@"error", try c.join(dpath, "version"), "version is defined twice");
                        }
                    }
                    try definitions.append(c.arena, definition);
                }
            }
        }

        for (definitions.items) |definition| {
            if (std.mem.findScalar(i64, versions, definition.version) == null) {
                try c.add(.inconsistent, .warning, try c.join(path, "versions"), try std.fmt.allocPrint(
                    c.arena,
                    "definition version {d} is not listed in versions",
                    .{definition.version},
                ));
            }
        }
        for (versions) |v| {
            var defined = false;
            for (definitions.items) |definition| {
                if (definition.version == v) defined = true;
            }
            if (!defined) try c.add(.inconsistent, .@"error", try c.join(path, "definitions"), try std.fmt.allocPrint(
                c.arena,
                "version {d} is listed but has no definition",
                .{v},
            ));
        }
        if (latest) |l| {
            if (versions.len > 0 and std.mem.findScalar(i64, versions, l) == null) {
                try c.add(.inconsistent, .@"error", try c.join(path, "latestVersion"), "latestVersion is not one of versions");
            }
        }

        try out.append(c.arena, .{
            .name = name,
            .description = try c.optionalString(obj, path, "description"),
            .latest_version = latest orelse 0,
            .definitions = definitions.items,
        });
    }
    return out.items;
}

fn readDefinition(c: Checker, obj: ObjectMap, path: []const u8) !?CapabilityVersion {
    const version = try c.positiveVersion(obj.get("version"), try c.join(path, "version"));
    const kind = try readKind(c, obj, path);
    const input = try readSchema(c, obj, path, "inputSchema");
    const output = try readSchema(c, obj, path, "outputSchema");
    const authorization = try readAuthorization(c, obj, path);
    var effect: ?Effect = null;
    if (try c.optionalString(obj, path, "effect")) |text| {
        effect = std.meta.stringToEnum(Effect, text) orelse blk: {
            try c.malformed(try c.join(path, "effect"), "must be observation or consequential");
            break :blk null;
        };
    }
    var idempotency: ?[]const u8 = null;
    if (try c.optionalString(obj, path, "idempotency")) |text| {
        if (std.mem.eql(u8, text, "supported") or std.mem.eql(u8, text, "unsupported")) {
            idempotency = text;
        } else try c.malformed(try c.join(path, "idempotency"), "must be supported or unsupported");
    }
    var emits: []const []const u8 = &.{};
    if (try c.optionalArray(obj, path, "emits")) |list| emits = try c.stringList(list, try c.join(path, "emits"));
    const deprecated = try c.optionalBool(obj, path, "deprecated") orelse false;
    return .{
        .version = version orelse return null,
        .kind = kind orelse return null,
        .description = try c.optionalString(obj, path, "description"),
        .input = input,
        .output = output,
        .authorization = authorization,
        .effect = effect,
        .idempotency = idempotency,
        .deprecated = deprecated,
        .emits = emits,
    };
}

fn readEvents(c: Checker, items: []const Value) ![]const Event {
    var out: std.ArrayList(Event) = .empty;
    for (items, 0..) |item, i| {
        const path = try c.index("events", i);
        if (item != .object) {
            try c.malformed(path, "must be an object");
            continue;
        }
        const name = try c.requiredString(item.object, path, "name") orelse continue;
        try nameDiagnostic(c, try c.join(path, "name"), name);
        if (item.object.get("definitions")) |definitions| {
            if (definitions != .array) try c.malformed(try c.join(path, "definitions"), "must be an array");
        } else try c.missing(try c.join(path, "definitions"), "required");
        try out.append(c.arena, .{ .name = name, .description = try c.optionalString(item.object, path, "description") });
    }
    return out.items;
}

/// Reads the integration descriptor. Shapes that would make the published
/// dependency checks throw are reported as malformed here; value-level
/// problems are left to the dependency-model checks, which report them in
/// the reference wording.
fn readIntegration(c: Checker, descriptor: Value) !?Integration {
    const base = "attributes[\"appport.integration/1\"]";
    if (descriptor != .object) {
        try c.malformed(base, "the integration descriptor must be an object");
        return null;
    }
    const obj = descriptor.object;
    const capabilities = obj.get("capabilities") orelse {
        try c.missing(base ++ ".capabilities", "an integration descriptor needs a capabilities object");
        return null;
    };
    if (capabilities != .object) {
        try c.malformed(base ++ ".capabilities", "must be an object keyed by name@version");
        return null;
    }
    var integration: Integration = .{};
    var entries: std.ArrayList(CapabilityIntegration) = .empty;
    var it = capabilities.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const path = try std.fmt.allocPrint(c.arena, "capabilities[{s}]", .{key});
        if (kv.value_ptr.* != .object) {
            try c.malformed(path, "must be an object");
            continue;
        }
        try entries.append(c.arena, try readCapabilityIntegration(c, key, path, kv.value_ptr.object));
    }
    integration.capabilities = entries.items;
    if (try c.optionalArray(obj, "descriptor", "requires")) |items| {
        integration.requires = try readDependencies(c, items, "descriptor.requires");
    }
    if (try c.optionalArray(obj, base, "resources")) |items| {
        var resources: std.ArrayList(Resource) = .empty;
        for (items, 0..) |item, i| {
            const path = try c.index("resources", i);
            if (item != .object) {
                try c.malformed(path, "must be an object");
                continue;
            }
            const r = item.object;
            const id = (r.get("id") orelse continue);
            if (id != .string) continue;
            var resource = Resource{ .id = id.string };
            if (r.get("kind")) |k| if (k == .string) {
                resource.kind = k.string;
            };
            if (r.get("concept")) |k| if (k == .string) {
                resource.concept = k.string;
            };
            if (r.get("owner")) |owner| switch (owner) {
                .string => |s| if (std.mem.eql(u8, s, "self")) {
                    resource.owner = .self;
                },
                .object => |o| if (o.get("application")) |a| if (a == .string and a.string.len > 0) {
                    resource.owner = .{ .application = a.string };
                },
                else => {},
            };
            try resources.append(c.arena, resource);
        }
        integration.resources = resources.items;
    }
    return integration;
}

fn readCapabilityIntegration(c: Checker, key: []const u8, path: []const u8, obj: ObjectMap) !CapabilityIntegration {
    var entry = CapabilityIntegration{ .key = key };
    if (obj.get("purpose")) |v| if (v == .string) {
        entry.purpose = v.string;
    };
    if (obj.get("authority")) |v| if (v == .string) {
        entry.authority = v.string;
    };
    if (try c.optionalArray(obj, path, "effects")) |items| {
        var effects: std.ArrayList([]const u8) = .empty;
        for (items) |item| {
            if (item == .object) if (item.object.get("type")) |t| if (t == .string) {
                try effects.append(c.arena, t.string);
            };
        }
        entry.effects = effects.items;
    }
    if (try c.optionalArray(obj, path, "requires")) |items| {
        entry.requires = try readDependencies(c, items, try c.join(path, "requires"));
    }
    if (try c.optionalArray(obj, path, "access")) |items| {
        var access: std.ArrayList(Access) = .empty;
        for (items, 0..) |item, i| {
            const apath = try c.index(try c.join(path, "access"), i);
            if (item != .object) {
                try c.malformed(apath, "must be an object");
                continue;
            }
            const a = item.object;
            var operations: ?[]const []const u8 = null;
            if (a.get("operations")) |ops| {
                if (ops != .array) {
                    try c.malformed(try c.join(apath, "operations"), "must be an array");
                    continue;
                }
                var list: std.ArrayList([]const u8) = .empty;
                for (ops.array.items) |op| if (op == .string) try list.append(c.arena, op.string);
                operations = list.items;
            }
            const resource = a.get("resource") orelse continue;
            const mode_value = a.get("mode") orelse continue;
            if (resource != .string or mode_value != .string) continue;
            const mode = std.meta.stringToEnum(AccessMode, mode_value.string) orelse continue;
            try access.append(c.arena, .{ .resource = resource.string, .mode = mode, .operations = operations });
        }
        entry.access = access.items;
    }
    if (obj.get("coverage")) |coverage| {
        if (coverage != .object and coverage != .null) {
            try c.malformed(try c.join(path, "coverage"), "must be an object");
        } else if (coverage == .object) {
            if (coverage.object.get("requires")) |v| if (v == .string) {
                entry.coverage_requires = std.meta.stringToEnum(Coverage, v.string);
            };
            if (coverage.object.get("access")) |v| if (v == .string) {
                entry.coverage_access = std.meta.stringToEnum(Coverage, v.string);
            };
        }
    }
    if (obj.get("approval")) |approval| {
        if (approval == .object) if (approval.object.get("required")) |required| if (required == .bool) {
            if (required.bool) {
                var approver: ?[]const u8 = null;
                if (approval.object.get("approver")) |a| if (a == .string) {
                    approver = a.string;
                };
                entry.approval = .{ .required = approver };
            } else entry.approval = .not_required;
        };
    }
    if (obj.get("verify")) |verify| if (verify == .array) {
        var methods: std.ArrayList(VerifyMethod) = .empty;
        for (verify.array.items) |item| {
            if (item != .object) continue;
            const m = item.object;
            const id = m.get("id") orelse continue;
            const kind = m.get("kind") orelse continue;
            if (id != .string or kind != .string) continue;
            if (std.mem.eql(u8, kind.string, "state")) {
                var method = VerifyMethod{ .id = id.string, .kind = .state };
                if (m.get("via")) |via| if (via == .object) {
                    const cap = via.object.get("capability");
                    const ver = via.object.get("version");
                    if (cap != null and ver != null and cap.? == .string) {
                        if (integerValue(ver.?)) |n| {
                            method.via_name = cap.?.string;
                            method.via_version = n;
                            method.via = try std.fmt.allocPrint(c.arena, "{s}@{d}", .{ cap.?.string, n });
                        }
                    }
                };
                try methods.append(c.arena, method);
            } else if (std.mem.eql(u8, kind.string, "event")) {
                var method = VerifyMethod{ .id = id.string, .kind = .event };
                if (m.get("event")) |e| if (e == .string) {
                    method.event = e.string;
                };
                try methods.append(c.arena, method);
            }
        }
        entry.verify = methods.items;
    };
    if (obj.get("preconditions")) |preconditions| if (preconditions == .array) {
        var ids: std.ArrayList([]const u8) = .empty;
        for (preconditions.array.items) |item| {
            if (item == .object) if (item.object.get("id")) |id| if (id == .string) {
                try ids.append(c.arena, id.string);
            };
        }
        entry.preconditions = ids.items;
    };
    if (obj.get("failures")) |failures| if (failures == .array) {
        var list: std.ArrayList(Failure) = .empty;
        for (failures.array.items) |item| {
            if (item != .object) continue;
            const f = item.object;
            const code = f.get("code") orelse continue;
            const retry = f.get("retry") orelse continue;
            const effect = f.get("effect") orelse continue;
            if (code != .string or retry != .string or effect != .string) continue;
            try list.append(c.arena, .{ .code = code.string, .retry = retry.string, .effect = effect.string });
        }
        entry.failures = list.items;
    };
    return entry;
}

/// Reads a dependency list. Entries whose values the dependency-model checks
/// reject are left out of the typed model; those checks report them.
fn readDependencies(c: Checker, items: []const Value, path: []const u8) ![]const Dependency {
    var out: std.ArrayList(Dependency) = .empty;
    for (items, 0..) |item, i| {
        const dpath = try c.index(path, i);
        if (item != .object) {
            try c.malformed(dpath, "a dependency must be an object");
            continue;
        }
        const d = item.object;
        var shape_ok = true;
        if (d.get("versionConstraint")) |v| if (v != .string) {
            try c.malformed(try c.join(dpath, "versionConstraint"), "must be a string");
            shape_ok = false;
        };
        var target_application: ?[]const u8 = null;
        var target_capability: ?[]const u8 = null;
        var target_event: ?[]const u8 = null;
        if (d.get("target")) |target| if (target == .object) {
            if (target.object.get("capability")) |v| {
                if (v != .string) {
                    try c.malformed(try c.join(dpath, "target.capability"), "must be a string");
                    shape_ok = false;
                } else target_capability = v.string;
            }
            if (target.object.get("event")) |v| {
                if (v != .string) {
                    try c.malformed(try c.join(dpath, "target.event"), "must be a string");
                    shape_ok = false;
                } else target_event = v.string;
            }
            if (target.object.get("application")) |v| if (v == .string) {
                target_application = v.string;
            };
        };
        if (!shape_ok) continue;
        const id = d.get("id") orelse continue;
        const relationship = d.get("relationship") orelse continue;
        const required = d.get("required") orelse continue;
        if (id != .string or relationship != .string or required != .bool) continue;
        if ((target_capability == null) == (target_event == null)) continue;
        try out.append(c.arena, .{
            .id = id.string,
            .relationship = Relationship.parse(relationship.string) orelse continue,
            .target_application = target_application,
            .target_capability = target_capability,
            .target_event = target_event,
            .required = required.bool,
            .version_constraint = if (d.get("versionConstraint")) |v| v.string else null,
            .purpose = if (d.get("purpose")) |v| (if (v == .string) v.string else null) else null,
        });
    }
    return out.items;
}

pub const fixture_minimal =
    \\{"protocol":"appport/1","application":{"id":"com.example.notes","name":"Notes","version":"1.0.0"},
    \\"capabilities":[{"name":"notes.list","versions":[1],"latestVersion":1,"kind":"request",
    \\"inputSchema":{"type":"object"},"outputSchema":{"type":"object"},"authorization":["notes.read"],
    \\"definitions":[{"version":1,"kind":"request","inputSchema":{"type":"object"},"outputSchema":{"type":"object"},
    \\"authorization":["notes.read"],"effect":"observation"}]}],"events":[],"transports":[{"kind":"http","endpoint":"/appport"}]}
;

test "a minimal manifest parses without diagnostics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try parse(arena_state.allocator(), fixture_minimal);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.items.len);
    const manifest = parsed.manifest.?;
    try std.testing.expectEqualStrings("com.example.notes", manifest.application.id);
    try std.testing.expectEqual(@as(usize, 1), manifest.capabilities.len);
    try std.testing.expectEqual(Effect.observation, manifest.findVersion("notes.list", 1).?.effect.?);
    try std.testing.expectEqual(Verdict.valid, Verdict.fromDiagnostics(parsed.diagnostics.items));
}

test "empty and malformed inputs are malformed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "", "   ", "{", "[]", "42", "{\"protocol\":" }) |input| {
        const parsed = try parse(arena, input);
        try std.testing.expectEqual(Verdict.malformed, Verdict.fromDiagnostics(parsed.diagnostics.items));
    }
}

test "missing required fields are incomplete, not malformed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try parse(arena_state.allocator(),
        \\{"protocol":"appport/1","application":{"id":"com.example.x","name":"X"},"capabilities":[],"transports":[]}
    );
    try std.testing.expectEqual(Verdict.incomplete, Verdict.fromDiagnostics(parsed.diagnostics.items));
    var saw_version = false;
    var saw_events = false;
    for (parsed.diagnostics.items) |d| {
        try std.testing.expectEqual(Category.missing, d.category);
        if (std.mem.eql(u8, d.path, "application.version")) saw_version = true;
        if (std.mem.eql(u8, d.path, "events")) saw_events = true;
    }
    try std.testing.expect(saw_version and saw_events);
}

test "unsupported protocol and extensions are never valid" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const other_protocol = try std.mem.replaceOwned(u8, arena, fixture_minimal, "appport/1", "appport/2");
    try std.testing.expectEqual(Verdict.unsupported, Verdict.fromDiagnostics((try parse(arena, other_protocol)).diagnostics.items));
    const with_extension = try std.mem.replaceOwned(u8, arena, fixture_minimal, "\"events\":[]", "\"events\":[],\"extensions\":[\"vendor.thing/1\"]");
    try std.testing.expectEqual(Verdict.unsupported, Verdict.fromDiagnostics((try parse(arena, with_extension)).diagnostics.items));
    const with_unknown_key = try std.mem.replaceOwned(u8, arena, fixture_minimal, "\"events\":[]", "\"events\":[],\"futureField\":1");
    try std.testing.expectEqual(Verdict.unsupported, Verdict.fromDiagnostics((try parse(arena, with_unknown_key)).diagnostics.items));
}

test "invalid structures are malformed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad_name = try std.mem.replaceOwned(u8, arena, fixture_minimal, "\"notes.list\"", "\"notes.http\"");
    const parsed = try parse(arena, bad_name);
    try std.testing.expectEqual(Verdict.malformed, Verdict.fromDiagnostics(parsed.diagnostics.items));
    try std.testing.expectEqualStrings("name must not contain the transport segment \"http\"", parsed.diagnostics.items[0].message);
    const bad_kind = try std.mem.replaceOwned(u8, arena, fixture_minimal, "\"kind\":\"request\"", "\"kind\":\"rpc\"");
    try std.testing.expectEqual(Verdict.malformed, Verdict.fromDiagnostics((try parse(arena, bad_kind)).diagnostics.items));
    const bad_versions = try std.mem.replaceOwned(u8, arena, fixture_minimal, "\"versions\":[1]", "\"versions\":[1,2]");
    try std.testing.expectEqual(Verdict.inconsistent, Verdict.fromDiagnostics((try parse(arena, bad_versions)).diagnostics.items));
}
