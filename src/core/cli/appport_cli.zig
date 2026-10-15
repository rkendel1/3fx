//! `fx appport`: deterministic AppPort contract inspection.
//!
//! Every subcommand reads contract files and answers from the native
//! knowledge in `src/core/appport/`. No subcommand reads credentials, opens a
//! network connection, or calls a model.

const std = @import("std");
const appport = @import("../appport/appport.zig");

const Allocator = std.mem.Allocator;

pub const Outcome = enum { success, failure, usage };

/// Output for the caller to write. All memory is owned by the arena passed
/// to `run`.
pub const Result = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    outcome: Outcome,
};

pub const usage =
    \\usage: fx appport <command> <contract.json>... [options]
    \\
    \\commands:
    \\  inspect   check structure and the dependency model; exits 1 unless every contract is valid
    \\  graph     derive the declared capability graph
    \\  find      select capabilities by published fields
    \\            --application ID --capability NAME[@VERSION] --reads IRI --changes IRI
    \\            --operation create|update|delete --effect-type ID
    \\  context   render the compact model context; --focus NAME[@VERSION] (repeatable)
    \\  coverage  list the AppPort semantics fx covers natively (takes no contracts)
    \\
    \\options:
    \\  --json    write one JSON object
    \\
;

const Command = enum { inspect, graph, find, context, coverage };

const Options = struct {
    json: bool = false,
    files: std.ArrayList([]const u8) = .empty,
    focus: std.ArrayList([]const u8) = .empty,
    selector: appport.graph.Selector = .{},
};

const ParseError = error{ InvalidArguments, OutOfMemory };

fn takeValue(args: []const []const u8, i: *usize) ParseError![]const u8 {
    if (i.* + 1 >= args.len) return error.InvalidArguments;
    i.* += 1;
    const value = args[i.*];
    if (value.len == 0) return error.InvalidArguments;
    return value;
}

fn setOnce(slot: *?[]const u8, value: []const u8) ParseError!void {
    if (slot.* != null) return error.InvalidArguments;
    slot.* = value;
}

fn parseOptions(arena: Allocator, command: Command, args: []const []const u8) ParseError!Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            if (options.json) return error.InvalidArguments;
            options.json = true;
        } else if (command == .context and std.mem.eql(u8, arg, "--focus")) {
            try options.focus.append(arena, try takeValue(args, &i));
        } else if (command == .find and std.mem.eql(u8, arg, "--application")) {
            try setOnce(&options.selector.application, try takeValue(args, &i));
        } else if (command == .find and std.mem.eql(u8, arg, "--capability")) {
            try setOnce(&options.selector.capability, try takeValue(args, &i));
        } else if (command == .find and std.mem.eql(u8, arg, "--reads")) {
            try setOnce(&options.selector.reads, try takeValue(args, &i));
        } else if (command == .find and std.mem.eql(u8, arg, "--changes")) {
            try setOnce(&options.selector.changes, try takeValue(args, &i));
        } else if (command == .find and std.mem.eql(u8, arg, "--operation")) {
            try setOnce(&options.selector.operation, try takeValue(args, &i));
        } else if (command == .find and std.mem.eql(u8, arg, "--effect-type")) {
            try setOnce(&options.selector.effect_type, try takeValue(args, &i));
        } else if (command == .find and std.mem.eql(u8, arg, "--concept")) {
            try setOnce(&options.selector.concept, try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.InvalidArguments;
        } else {
            try options.files.append(arena, arg);
        }
    }
    if (command == .coverage and options.files.items.len > 0) return error.InvalidArguments;
    if (command != .coverage and options.files.items.len == 0) return error.InvalidArguments;
    return options;
}

fn failure(arena: Allocator, json: bool, kind: []const u8, code: []const u8, message: []const u8) !Result {
    if (json) {
        var out: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(.{ .kind = kind, .@"error" = message, .code = code }, .{}, &out.writer);
        try out.writer.writeByte('\n');
        return .{ .stdout = out.written(), .outcome = .failure };
    }
    return .{ .stderr = try std.fmt.allocPrint(arena, "fx appport: {s}\n", .{message}), .outcome = .failure };
}

fn usageResult(arena: Allocator, args: []const []const u8) !Result {
    for (args) |arg| if (std.mem.eql(u8, arg, "--json")) {
        return .{ .stdout = try std.fmt.allocPrint(
            arena,
            "{{\"kind\":\"appport\",\"error\":\"invalid appport arguments\",\"code\":\"InvalidArguments\"}}\n",
            .{},
        ), .outcome = .usage };
    };
    return .{ .stderr = usage, .outcome = .usage };
}

/// Runs `fx appport` with `args` (everything after `appport`). Relative
/// contract paths resolve against `base_dir`, or the current directory.
pub fn run(arena: Allocator, args: []const []const u8, base_dir: ?[]const u8) !Result {
    if (args.len == 0) return usageResult(arena, args);
    const name = args[0];
    if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "help")) {
        return .{ .stdout = usage, .outcome = .success };
    }
    for (appport.graph.unsupported_operations) |operation| {
        const short = if (std.mem.eql(u8, operation, "planIntegration")) "plan" else if (std.mem.eql(u8, operation, "compareBehavior")) "compare" else "assess";
        if (std.mem.eql(u8, name, short)) {
            const json = for (args[1..]) |arg| {
                if (std.mem.eql(u8, arg, "--json")) break true;
            } else false;
            return failure(arena, json, "appport", "UnsupportedOperation", try std.fmt.allocPrint(
                arena,
                "{s} is not implemented natively; use @appport/integration. fx does not approximate it",
                .{operation},
            ));
        }
    }
    const command = std.meta.stringToEnum(Command, name) orelse return usageResult(arena, args);
    const options = parseOptions(arena, command, args[1..]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => return usageResult(arena, args),
    };
    const kind = try std.fmt.allocPrint(arena, "appport.{s}", .{name});

    if (command == .coverage) {
        return .{ .stdout = try renderLine(arena, .coverage, options.json), .outcome = .success };
    }

    var inspections: std.ArrayList(appport.Inspection) = .empty;
    for (options.files.items) |path| {
        const bytes = appport.readContractFile(arena, base_dir, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return failure(arena, options.json, kind, @errorName(err), try std.fmt.allocPrint(
                arena,
                "{s}: {s}",
                .{ path, appport.describeLoadError(err) },
            )),
        };
        try inspections.append(arena, try appport.inspect(arena, path, bytes));
    }

    switch (command) {
        .inspect => {
            const verdict = appport.report.overallVerdict(inspections.items);
            return .{
                .stdout = try renderLine(arena, .{ .inspect = inspections.items }, options.json),
                .outcome = if (verdict == .valid) .success else .failure,
            };
        },
        .graph => {
            const manifests = try appport.usableManifests(arena, inspections.items);
            const graph = try appport.graph.deriveGraph(arena, manifests);
            return .{ .stdout = try renderLine(arena, .{ .graph = .{ .inspections = inspections.items, .graph = graph } }, options.json), .outcome = .success };
        },
        .find => {
            const manifests = try appport.usableManifests(arena, inspections.items);
            const result = appport.graph.findCapabilities(arena, manifests, options.selector) catch |err| switch (err) {
                error.UnsupportedSelector => return failure(arena, options.json, kind, "UnsupportedSelector", "--concept selectors need footprint semantics fx does not embed; use @appport/integration"),
                else => |e| return e,
            };
            return .{ .stdout = try renderLine(arena, .{ .find = .{
                .inspections = inspections.items,
                .selector = options.selector,
                .result = result,
            } }, options.json), .outcome = .success };
        },
        .context => {
            const ctx = try appport.context.build(arena, inspections.items, options.focus.items);
            return .{ .stdout = try renderLine(arena, .{ .context = .{ .inspections = inspections.items, .context = ctx } }, options.json), .outcome = .success };
        },
        .coverage => unreachable,
    }
}

fn renderLine(arena: Allocator, snapshot: appport.report.Snapshot, json: bool) ![]const u8 {
    const text = try snapshot.render(arena, json);
    if (json or (text.len > 0 and text[text.len - 1] == '\n')) {
        return if (json) try std.fmt.allocPrint(arena, "{s}\n", .{text}) else text;
    }
    return std.fmt.allocPrint(arena, "{s}\n", .{text});
}

fn testRun(arena: Allocator, args: []const []const u8, base: []const u8) !Result {
    return run(arena, args, base);
}

test "argument errors return usage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(Outcome.usage, (try run(arena, &.{}, null)).outcome);
    const help = try run(arena, &.{"--help"}, null);
    try std.testing.expectEqual(Outcome.success, help.outcome);
    try std.testing.expectEqualStrings(usage, help.stdout);
    try std.testing.expectEqual(Outcome.usage, (try run(arena, &.{"inspect"}, null)).outcome);
    try std.testing.expectEqual(Outcome.usage, (try run(arena, &.{ "inspect", "a.json", "--focus", "x" }, null)).outcome);
    try std.testing.expectEqual(Outcome.usage, (try run(arena, &.{ "find", "a.json", "--reads" }, null)).outcome);
    try std.testing.expectEqual(Outcome.usage, (try run(arena, &.{ "coverage", "a.json" }, null)).outcome);
    const json_usage = try run(arena, &.{ "bogus", "--json" }, null);
    try std.testing.expect(std.mem.indexOf(u8, json_usage.stdout, "InvalidArguments") != null);
}

test "unsupported integration operations are reported, not approximated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try run(arena, &.{ "assess", "a.json", "--json" }, null);
    try std.testing.expectEqual(Outcome.failure, result.outcome);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "assessReplacement is not implemented natively") != null);
}

test "inspect reads files and fails for invalid contracts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.json", .data = appport.knowledge.fixture_minimal });
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.json", .data = "{\"protocol\":\"appport/1\"}" });
    const io_mod = @import("../shared/io.zig");
    const base = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");

    const ok = try testRun(arena, &.{ "inspect", "ok.json", "--json" }, base);
    try std.testing.expectEqual(Outcome.success, ok.outcome);
    try std.testing.expect(std.mem.indexOf(u8, ok.stdout, "\"verdict\":\"valid\"") != null);

    const bad = try testRun(arena, &.{ "inspect", "ok.json", "bad.json" }, base);
    try std.testing.expectEqual(Outcome.failure, bad.outcome);
    try std.testing.expect(std.mem.indexOf(u8, bad.stdout, "verdict=incomplete") != null);

    const missing = try testRun(arena, &.{ "graph", "nope.json", "--json" }, base);
    try std.testing.expectEqual(Outcome.failure, missing.outcome);
    try std.testing.expect(std.mem.indexOf(u8, missing.stdout, "ContractNotFound") != null);
}
