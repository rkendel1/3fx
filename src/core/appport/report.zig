//! Text and JSON rendering for `fx appport` results. Both formats render
//! from the same snapshot. Contract text is untrusted, so text output passes
//! every contract-derived string through the terminal-safe encoder.

const std = @import("std");
const appport = @import("appport.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const knowledge = appport.knowledge;
const graph_mod = appport.graph;
const context_mod = appport.context;

pub const Snapshot = union(enum) {
    inspect: []const appport.Inspection,
    graph: struct { inspections: []const appport.Inspection, graph: graph_mod.Graph },
    find: struct { inspections: []const appport.Inspection, selector: graph_mod.Selector, result: graph_mod.FindResult },
    context: struct { inspections: []const appport.Inspection, context: context_mod.Context },
    coverage,

    /// Renders the snapshot. Memory is owned by `arena`.
    pub fn render(self: Snapshot, arena: Allocator, json: bool) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        if (json) try self.writeJson(&out.writer) else try self.writeText(arena, &out.writer);
        return out.written();
    }

    fn writeJson(self: Snapshot, w: *std.Io.Writer) !void {
        const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
        switch (self) {
            .inspect => |inspections| {
                try w.writeAll("{\"kind\":\"appport.inspect\",\"verdict\":");
                try std.json.Stringify.value(@tagName(overallVerdict(inspections)), options, w);
                try w.writeAll(",\"contracts\":");
                try writeContracts(w, inspections, true);
                try writeCommonTail(w);
                try w.writeByte('}');
            },
            .graph => |g| {
                try w.writeAll("{\"kind\":\"appport.graph\",\"contracts\":");
                try writeContracts(w, g.inspections, false);
                try w.writeAll(",\"graph\":");
                try std.json.Stringify.value(g.graph, options, w);
                try w.writeAll(",\"unsupported_inputs\":[\"mappings\",\"findings\",\"coverage\"]");
                try writeCommonTail(w);
                try w.writeByte('}');
            },
            .find => |f| {
                try w.writeAll("{\"kind\":\"appport.find\",\"contracts\":");
                try writeContracts(w, f.inspections, false);
                try w.writeAll(",\"selector\":");
                try std.json.Stringify.value(f.selector, options, w);
                try w.writeAll(",\"matches\":");
                try std.json.Stringify.value(f.result.matches, options, w);
                try w.writeAll(",\"undeclared\":");
                try std.json.Stringify.value(f.result.undeclared, options, w);
                try writeCommonTail(w);
                try w.writeByte('}');
            },
            .context => |c| {
                try w.writeAll("{\"kind\":\"appport.context\",\"contracts\":");
                try writeContracts(w, c.inspections, false);
                try w.writeAll(",\"selected\":");
                try std.json.Stringify.value(c.context.selected, options, w);
                try w.writeAll(",\"unmatched_focus\":");
                try std.json.Stringify.value(c.context.unmatched_focus, options, w);
                try w.writeAll(",\"omitted\":");
                try std.json.Stringify.value(c.context.omitted, options, w);
                try w.print(",\"bytes\":{d},\"text\":", .{c.context.text.len});
                try std.json.Stringify.value(c.context.text, options, w);
                try w.writeByte('}');
            },
            .coverage => {
                try w.writeAll("{\"kind\":\"appport.coverage\",\"coverage\":[");
                for (appport.coverage, 0..) |entry, i| {
                    if (i > 0) try w.writeByte(',');
                    try w.writeAll("{\"semantic\":");
                    try std.json.Stringify.value(entry.semantic, options, w);
                    try w.writeAll(",\"reference\":");
                    try std.json.Stringify.value(entry.reference, options, w);
                    try w.writeAll(",\"status\":");
                    try std.json.Stringify.value(@tagName(entry.status), options, w);
                    try w.writeByte('}');
                }
                try w.writeByte(']');
                try writeCommonTail(w);
                try w.writeByte('}');
            },
        }
    }

    fn writeText(self: Snapshot, arena: Allocator, w: *std.Io.Writer) !void {
        switch (self) {
            .inspect => |inspections| {
                for (inspections) |inspection| try writeInspectionText(arena, w, inspection);
                try w.print("[appport] verdict={s}\n", .{@tagName(overallVerdict(inspections))});
                try w.writeAll("[appport] not checked by fx:\n");
                for (appport.not_checked) |item| try w.print("  - {s}\n", .{item});
            },
            .graph => |g| {
                for (g.inspections) |inspection| try writeContractLine(arena, w, inspection);
                try w.print("[appport] graph nodes={d} edges={d} unknowns={d} risks={d}\n", .{
                    g.graph.summary.nodes, g.graph.summary.edges, g.graph.summary.unknowns, g.graph.summary.risks,
                });
                for (g.graph.edges) |edge| {
                    try w.writeAll("  edge ");
                    try safe(arena, w, edge.kind);
                    try w.writeByte(' ');
                    try safe(arena, w, edge.from);
                    try w.writeAll(" -> ");
                    try safe(arena, w, edge.to);
                    if (edge.required) |required| try w.writeAll(if (required) " required" else " optional");
                    if (!edge.resolved) try w.writeAll(" unresolved");
                    try w.writeByte('\n');
                }
                for (g.graph.risks) |risk| {
                    try w.writeAll("  risk ");
                    try safe(arena, w, risk.message);
                    try w.writeByte('\n');
                }
                for (g.graph.unknowns) |unknown| {
                    try w.writeAll("  unknown ");
                    try safe(arena, w, unknown.message);
                    try w.writeByte('\n');
                }
                try w.writeAll("[appport] not derived natively: mapping data-flow edges, inferred or observed findings, observation coverage\n");
            },
            .find => |f| {
                for (f.inspections) |inspection| try writeContractLine(arena, w, inspection);
                try w.print("[appport] matches={d} undeclared={d}\n", .{ f.result.matches.len, f.result.undeclared.len });
                for (f.result.matches) |match| {
                    try w.writeAll("  match ");
                    try safe(arena, w, match.application);
                    try w.writeByte(' ');
                    try safe(arena, w, match.capability);
                    try w.writeAll(" on ");
                    for (match.matchedOn, 0..) |on, i| {
                        if (i > 0) try w.writeAll(", ");
                        try safe(arena, w, on);
                    }
                    try w.writeByte('\n');
                }
                for (f.result.undeclared) |u| {
                    try w.writeAll("  unknown ");
                    try safe(arena, w, u.application);
                    try w.writeByte(' ');
                    try safe(arena, w, u.capability);
                    try w.writeAll(" publishes no integration entry, so the selector cannot be evaluated\n");
                }
            },
            .context => |c| {
                var lines = std.mem.splitScalar(u8, c.context.text, '\n');
                var first = true;
                while (lines.next()) |line| {
                    if (!first) try w.writeByte('\n');
                    first = false;
                    const encoded = try text_utils.encodeTerminalSafe(arena, line, std.math.maxInt(usize));
                    try w.writeAll(encoded.bytes);
                }
            },
            .coverage => {
                try w.writeAll("[appport] reference packages:\n");
                for (appport.reference_packages) |pkg| try w.print("  {s}@{s}\n", .{ pkg.name, pkg.version });
                try w.writeAll("[appport] coverage:\n");
                for (appport.coverage) |entry| {
                    try w.print("  {s:<13} {s} ({s})\n", .{ @tagName(entry.status), entry.semantic, entry.reference });
                }
            },
        }
    }
};

pub fn overallVerdict(inspections: []const appport.Inspection) knowledge.Verdict {
    var verdict: knowledge.Verdict = .valid;
    for (inspections) |inspection| {
        if (@intFromEnum(inspection.verdict) > @intFromEnum(verdict)) verdict = inspection.verdict;
    }
    return verdict;
}

fn writeCommonTail(w: *std.Io.Writer) !void {
    try w.writeAll(",\"not_checked\":");
    try std.json.Stringify.value(appport.not_checked, .{}, w);
    try w.writeAll(",\"reference\":");
    try std.json.Stringify.value(appport.reference_packages, .{}, w);
}

fn writeContracts(w: *std.Io.Writer, inspections: []const appport.Inspection, with_diagnostics: bool) !void {
    try w.writeByte('[');
    for (inspections, 0..) |inspection, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"source\":");
        try std.json.Stringify.value(inspection.source, .{}, w);
        try w.writeAll(",\"digest\":");
        try std.json.Stringify.value(inspection.digest, .{}, w);
        try w.writeAll(",\"verdict\":");
        try std.json.Stringify.value(@tagName(inspection.verdict), .{}, w);
        if (inspection.manifest) |m| {
            try w.writeAll(",\"application\":");
            try std.json.Stringify.value(.{ .id = m.application.id, .name = m.application.name, .version = m.application.version }, .{}, w);
            try w.print(",\"capabilities\":{d},\"events\":{d}", .{ m.capabilities.len, m.events.len });
        } else try w.writeAll(",\"application\":null");
        try w.print(",\"dependency_model_checked\":{}", .{inspection.dependency_model_checked});
        if (with_diagnostics) {
            try w.writeAll(",\"diagnostics\":[");
            for (inspection.diagnostics, 0..) |d, j| {
                if (j > 0) try w.writeByte(',');
                try std.json.Stringify.value(.{
                    .source = d.source.label(),
                    .category = @tagName(d.category),
                    .severity = @tagName(d.severity),
                    .path = d.path,
                    .message = d.message,
                }, .{}, w);
            }
            try w.writeByte(']');
        } else try w.print(",\"diagnostics\":{d}", .{inspection.diagnostics.len});
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn safe(arena: Allocator, w: *std.Io.Writer, raw: []const u8) !void {
    const encoded = try text_utils.encodeTerminalSafeInline(arena, raw, 512);
    try w.writeAll(encoded.bytes);
}

fn writeContractLine(arena: Allocator, w: *std.Io.Writer, inspection: appport.Inspection) !void {
    try w.writeAll("[appport] contract ");
    try safe(arena, w, inspection.source);
    try w.print(" {s} verdict={s}", .{ inspection.digest, @tagName(inspection.verdict) });
    if (inspection.manifest) |m| {
        try w.writeAll(" application=");
        try safe(arena, w, m.application.id);
    }
    try w.writeByte('\n');
}

fn writeInspectionText(arena: Allocator, w: *std.Io.Writer, inspection: appport.Inspection) !void {
    try writeContractLine(arena, w, inspection);
    if (inspection.manifest) |m| {
        try w.print("  capabilities={d} events={d} transports={d} integration={s} dependency_model={s}\n", .{
            m.capabilities.len,
            m.events.len,
            m.transports.len,
            if (m.integration != null) "declared" else "absent",
            if (inspection.dependency_model_checked) "checked" else "not-checked",
        });
    }
    for (inspection.diagnostics) |d| {
        try w.print("  {s} {s} [{s}] ", .{ @tagName(d.severity), @tagName(d.category), d.source.label() });
        try safe(arena, w, if (d.path.len == 0) "(document)" else d.path);
        try w.writeAll(": ");
        try safe(arena, w, d.message);
        try w.writeByte('\n');
    }
}

test "inspect renders text and JSON from the same snapshot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inspection = try appport.inspect(arena, "minimal.json", knowledge.fixture_minimal);
    const snapshot = Snapshot{ .inspect = &.{inspection} };
    const json = try snapshot.render(arena, true);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    try std.testing.expectEqualStrings("appport.inspect", parsed.object.get("kind").?.string);
    try std.testing.expectEqualStrings("valid", parsed.object.get("verdict").?.string);
    const text = try snapshot.render(arena, false);
    try std.testing.expect(std.mem.indexOf(u8, text, "verdict=valid") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "not checked by fx") != null);
}

test "text output neutralizes terminal escapes from contracts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inspection = try appport.inspect(arena, "x.json", "{\"protocol\":\"appport/1\",\"\\u001b[31mevil\":1}");
    const text = try (Snapshot{ .inspect = &.{inspection} }).render(arena, false);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0x1b) == null);
}
