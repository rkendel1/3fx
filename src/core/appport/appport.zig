//! AppPort contract knowledge: the front door.
//!
//! fx reads published AppPort contracts (application manifests defined by
//! `@appport/protocol`) and answers deterministic questions about them without
//! a model call: structure, dependency consistency, the declared integration
//! graph, capability selection, and compact model context.
//!
//! The published AppPort packages remain the authority. This module embeds a
//! minimal native representation of the subset listed in `coverage`, checked
//! against the pinned `reference_packages` by `tests/appport-parity/`. Anything
//! outside that subset is reported as not checked, never as passing.
//!
//! Outside code imports only this file.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
pub const knowledge = @import("knowledge.zig");
pub const names = @import("names.zig");
pub const graph = @import("graph.zig");
pub const context = @import("context.zig");
pub const report = @import("report.zig");
const lint = @import("lint.zig");

const Allocator = std.mem.Allocator;

pub const ReferencePackage = struct {
    name: []const u8,
    version: []const u8,
};

/// The published packages whose semantics the native port follows. The
/// parity check fails when the installed reference differs from these pins.
pub const reference_packages = [_]ReferencePackage{
    .{ .name = "@appport/protocol", .version = "1.1.0" },
    .{ .name = "@appport/integration", .version = "1.1.0" },
};

pub const CoverageStatus = enum { ported, fx_native, not_supported };

pub const CoverageEntry = struct {
    semantic: []const u8,
    reference: []const u8,
    status: CoverageStatus,
};

/// What the embedded knowledge covers. `ported` entries have parity tests
/// against the reference; `fx_native` entries have no published reference
/// validator; `not_supported` entries are reported to callers as unchecked.
pub const coverage = [_]CoverageEntry{
    .{ .semantic = "validateName, isValidApplicationId, isValidPermission, isSupportedProtocol", .reference = "@appport/protocol", .status = .ported },
    .{ .semantic = "isVersionConstraint, satisfiesVersionConstraint, parseDependencyRef", .reference = "@appport/protocol", .status = .ported },
    .{ .semantic = "lintDependencyModel (requires, resources, access, coverage, cycles)", .reference = "@appport/protocol", .status = .ported },
    .{ .semantic = "deriveGraph over published manifests (declared provenance)", .reference = "@appport/integration", .status = .ported },
    .{ .semantic = "findCapabilities (application, capability, reads, changes, operation, effectType)", .reference = "@appport/integration", .status = .ported },
    .{ .semantic = "manifest structure against the AppPortManifest types", .reference = "@appport/protocol types", .status = .fx_native },
    .{ .semantic = "lintIntegration, lintAgentContract, validateSemanticAnnotations", .reference = "@appport/protocol", .status = .not_supported },
    .{ .semantic = "JSON Schema validation of capability input and output", .reference = "@appport/schema", .status = .not_supported },
    .{ .semantic = "contractDigest, capabilityDigest, public descriptions, signatures", .reference = "@appport/protocol", .status = .not_supported },
    .{ .semantic = "deriveGraph mappings, findings, and observation coverage", .reference = "@appport/integration", .status = .not_supported },
    .{ .semantic = "findCapabilities concept selectors", .reference = "@appport/integration", .status = .not_supported },
    .{ .semantic = "planIntegration, compareBehavior, assessReplacement", .reference = "@appport/integration", .status = .not_supported },
};

/// Checks a successful inspection does not cover. Every report lists them so a
/// clean native result is never read as a full AppPort validation.
pub const not_checked = [_][]const u8{
    "lintIntegration and lintAgentContract (verify, preconditions, failures, approval, mappings, effects)",
    "JSON Schema validity of inputSchema and outputSchema",
    "contract and capability digests, publication, and signatures",
    "runtime behavior: a valid contract is not evidence that any capability works",
};

pub const Inspection = struct {
    /// Where the contract came from, as given by the caller.
    source: []const u8,
    /// `sha256:<hex>` of the exact bytes inspected.
    digest: []const u8,
    verdict: knowledge.Verdict,
    /// Null when the document is not a JSON object.
    manifest: ?knowledge.Manifest,
    diagnostics: []const knowledge.Diagnostic,
    /// True when the dependency-model checks ran.
    dependency_model_checked: bool,
};

/// Inspects contract bytes. Pure and deterministic: no I/O, no model call.
/// All memory is owned by `arena`.
pub fn inspect(arena: Allocator, source: []const u8, bytes: []const u8) Allocator.Error!Inspection {
    var parsed = try knowledge.parse(arena, bytes);
    var blocked = false;
    for (parsed.diagnostics.items) |d| {
        if (d.severity == .@"error" and (d.category == .malformed or d.category == .missing)) blocked = true;
    }
    var checked = false;
    if (!blocked) if (parsed.value) |value| {
        try lint.lintDependencyModel(arena, value.object, &parsed.diagnostics);
        checked = true;
    };
    return .{
        .source = source,
        .digest = try digestOf(arena, bytes),
        .verdict = knowledge.Verdict.fromDiagnostics(parsed.diagnostics.items),
        .manifest = parsed.manifest,
        .diagnostics = parsed.diagnostics.items,
        .dependency_model_checked = checked,
    };
}

fn digestOf(arena: Allocator, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.allocPrint(arena, "sha256:{x}", .{hash});
}

pub const LoadError = error{
    ContractNotFound,
    ContractUnreadable,
    ContractTooLarge,
} || Allocator.Error;

/// Reads a contract file. A relative `path` resolves against `base_dir`
/// when given, otherwise against the current directory.
pub fn readContractFile(arena: Allocator, base_dir: ?[]const u8, path: []const u8) LoadError![]const u8 {
    const io = io_mod.getIo();
    const resolved = if (base_dir != null and !std.fs.path.isAbsolute(path))
        try std.fs.path.join(arena, &.{ base_dir.?, path })
    else
        path;
    var file = io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), resolved, .follow) catch |err| switch (err) {
        error.FileNotFound => return error.ContractNotFound,
        else => return error.ContractUnreadable,
    };
    defer file.close(io);
    const bytes = io_mod.readFileToEnd(arena, &file, knowledge.max_contract_bytes + 1) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ContractUnreadable,
    };
    if (bytes.len > knowledge.max_contract_bytes) return error.ContractTooLarge;
    return bytes;
}

pub fn describeLoadError(err: LoadError) []const u8 {
    return switch (err) {
        error.ContractNotFound => "contract file not found",
        error.ContractUnreadable => "contract file could not be read",
        error.ContractTooLarge => "contract exceeds the 4 MiB inspection limit",
        error.OutOfMemory => "out of memory",
    };
}

/// Manifests from inspections that produced one and are not malformed.
pub fn usableManifests(arena: Allocator, inspections: []const Inspection) ![]const knowledge.Manifest {
    var out: std.ArrayList(knowledge.Manifest) = .empty;
    for (inspections) |inspection| {
        if (inspection.verdict == .malformed) continue;
        if (inspection.manifest) |manifest| try out.append(arena, manifest);
    }
    return out.items;
}

test {
    _ = knowledge;
    _ = names;
    _ = graph;
    _ = context;
    _ = report;
    _ = lint;
}

test "inspect computes a digest and skips dependency checks for malformed input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ok = try inspect(arena, "minimal.json", knowledge.fixture_minimal);
    try std.testing.expectEqual(knowledge.Verdict.valid, ok.verdict);
    try std.testing.expect(ok.dependency_model_checked);
    try std.testing.expect(std.mem.startsWith(u8, ok.digest, "sha256:"));
    try std.testing.expectEqual(@as(usize, 7 + 64), ok.digest.len);

    const bad = try inspect(arena, "bad.json", "{\"protocol\":1}");
    try std.testing.expectEqual(knowledge.Verdict.malformed, bad.verdict);
    try std.testing.expect(!bad.dependency_model_checked);
}

test "inspection is deterministic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = "{\"protocol\":\"appport/2\",\"capabilities\":{},\"zeta\":1,\"alpha\":2}";
    const a = try inspect(arena, "x", input);
    const b = try inspect(arena, "x", input);
    try std.testing.expectEqual(a.diagnostics.len, b.diagnostics.len);
    for (a.diagnostics, b.diagnostics) |x, y| {
        try std.testing.expectEqualStrings(x.path, y.path);
        try std.testing.expectEqualStrings(x.message, y.message);
    }
}

/// Environment variable naming contract files whose knowledge is given to
/// the model, comma-separated. Unset means fx adds no AppPort context.
pub const manifest_env = "FX_APPPORT_MANIFEST";
/// Optional comma-separated capability names that narrow the context.
pub const focus_env = "FX_APPPORT_FOCUS";

fn splitList(arena: Allocator, raw: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len > 0) try out.append(arena, trimmed);
    }
    return out.items;
}

/// Builds the model-visible AppPort context from explicit contract paths.
/// Returns null when `manifest_list` names no files, so ordinary runs are
/// unchanged. A contract that cannot be read becomes a short notice in the
/// context instead of failing the turn. Relative paths resolve against
/// `workspace_root`. Deterministic and model-free.
pub fn modelContext(
    arena: Allocator,
    workspace_root: ?[]const u8,
    manifest_list: ?[]const u8,
    focus_list: ?[]const u8,
) Allocator.Error!?[]const u8 {
    const files = try splitList(arena, manifest_list orelse return null);
    if (files.len == 0) return null;
    const focus = try splitList(arena, focus_list orelse "");
    var inspections: std.ArrayList(Inspection) = .empty;
    var notices: std.ArrayList(u8) = .empty;
    for (files) |path| {
        const bytes = readContractFile(arena, workspace_root, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try notices.print(arena, "AppPort contract {s} is unavailable: {s}.\n", .{ path, describeLoadError(err) });
                continue;
            },
        };
        try inspections.append(arena, try inspect(arena, path, bytes));
    }
    if (inspections.items.len == 0) return notices.items;
    // The allocating writer fails only when allocation fails.
    const ctx = context.build(arena, inspections.items, focus) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    if (notices.items.len == 0) return ctx.text;
    return try std.fmt.allocPrint(arena, "{s}\n{s}", .{ ctx.text, notices.items });
}

/// `modelContext` driven by `FX_APPPORT_MANIFEST` and `FX_APPPORT_FOCUS`.
pub fn modelContextFromEnvironment(arena: Allocator, workspace_root: ?[]const u8) Allocator.Error!?[]const u8 {
    return modelContext(arena, workspace_root, io_mod.getenv(manifest_env), io_mod.getenv(focus_env));
}

test "model context is absent unless contracts are named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect((try modelContext(arena, null, null, null)) == null);
    try std.testing.expect((try modelContext(arena, null, " , ", null)) == null);
}

test "model context reports unreadable contracts without failing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.json", .data = knowledge.fixture_minimal });
    const root = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const text = (try modelContext(arena, root, "notes.json, missing.json", "notes.list")).?;
    try std.testing.expect(std.mem.indexOf(u8, text, "capability notes.list@1 request observation") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "AppPort contract missing.json is unavailable: contract file not found.") != null);
    const only_missing = (try modelContext(arena, root, "missing.json", null)).?;
    try std.testing.expect(std.mem.startsWith(u8, only_missing, "AppPort contract missing.json is unavailable"));
}
