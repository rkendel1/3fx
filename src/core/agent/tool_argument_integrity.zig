const std = @import("std");

/// JSON integrity only: neither schema validity nor permission/execution status.
pub const ToolArgumentIntegrity = enum {
    valid,
    malformed_json,
    non_object_json,

    pub fn classifySerialized(
        alloc: std.mem.Allocator,
        serialized: []const u8,
    ) std.mem.Allocator.Error!ToolArgumentIntegrity {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .malformed_json,
        };
        defer parsed.deinit();
        return .valid;
    }

    pub fn classifyFunctionInput(
        alloc: std.mem.Allocator,
        serialized: []const u8,
    ) std.mem.Allocator.Error!ToolArgumentIntegrity {
        const integrity = try classifySerialized(alloc, serialized);
        if (integrity != .valid) return integrity;
        // A complete JSON root is nonempty; only an object can start with '{'.
        return if (std.mem.trimStart(u8, serialized, " \t\r\n")[0] == '{') .valid else .non_object_json;
    }
};

test "function input classification distinguishes syntax from object shape" {
    const cases = [_]struct { input: []const u8, expected: ToolArgumentIntegrity }{
        .{ .input = "{}", .expected = .valid },
        .{ .input = " \n{\"nested\":[1,null,{}]}\t", .expected = .valid },
        .{ .input = "[]", .expected = .non_object_json },
        .{ .input = "42", .expected = .non_object_json },
        .{ .input = "null", .expected = .non_object_json },
        .{ .input = "true", .expected = .non_object_json },
        .{ .input = "\"text\"", .expected = .non_object_json },
        .{ .input = "", .expected = .malformed_json },
        .{ .input = "{} trailing", .expected = .malformed_json },
        .{ .input = "{\"a\":1,\"a\":2}", .expected = .malformed_json },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, try ToolArgumentIntegrity.classifyFunctionInput(std.testing.allocator, case.input));
        try std.testing.expectEqual(case.expected, try ToolArgumentIntegrity.classifyFunctionInput(std.testing.allocator, case.input));
        if (case.expected == .non_object_json) {
            try std.testing.expectEqual(ToolArgumentIntegrity.valid, try ToolArgumentIntegrity.classifySerialized(std.testing.allocator, case.input));
        }
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, ToolArgumentIntegrity.classifyFunctionInput(failing.allocator(), "{\"path\":\"file\"}"));
}

test "ToolArgumentIntegrity accepts complete serialized JSON roots" {
    const cases = [_][]const u8{
        "  {\"first\":1,\"second\":1e+02} \n",
        "[1,{\"nested\":true}]",
        "null",
        "true",
        "42",
        "\"text\"",
    };

    for (cases) |serialized| {
        try std.testing.expectEqual(
            ToolArgumentIntegrity.valid,
            try ToolArgumentIntegrity.classifySerialized(std.testing.allocator, serialized),
        );
    }
}

test "ToolArgumentIntegrity rejects malformed trailing and duplicate-key JSON" {
    const cases = [_][]const u8{
        "{]",
        "{} trailing",
        "{\"depth\":1,\"depth\":2}",
    };

    for (cases) |serialized| {
        try std.testing.expectEqual(
            ToolArgumentIntegrity.malformed_json,
            try ToolArgumentIntegrity.classifySerialized(std.testing.allocator, serialized),
        );
    }
}

test "ToolArgumentIntegrity preserves parser allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        ToolArgumentIntegrity.classifySerialized(failing.allocator(), "{\"path\":\"src/main.zig\"}"),
    );
}

test "argument integrity has exactly the existing payload-free tags" {
    const fields = std.meta.fields(ToolArgumentIntegrity);
    const names = .{ "valid", "malformed_json", "non_object_json" };
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    inline for (fields, names) |field, name| {
        try std.testing.expectEqualStrings(name, field.name);
        const value: ToolArgumentIntegrity = @enumFromInt(field.value);
        try std.testing.expectEqual(field.value, @intFromEnum(value));
    }
}
