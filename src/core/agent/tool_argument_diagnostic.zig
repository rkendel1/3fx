const std = @import("std");
const ToolArgumentIntegrity = @import("tool_argument_integrity.zig").ToolArgumentIntegrity;

/// Explains why raw function arguments were `malformed_json`, captured before
/// fx replaces them with `{}`. It carries positions only: rejected argument
/// bytes never leave the parse step.
pub const ToolArgumentDiagnostic = struct {
    pub const Failure = enum {
        /// The input ended before the JSON value was complete.
        truncated,
        /// The scanner rejected the input at `error_offset`.
        syntax_error,
        /// The syntax was complete, but the parsed value was refused, such as
        /// an object that repeats a key.
        rejected_value,
    };

    failure: Failure,
    input_bytes: usize,
    /// Byte offset where scanning stopped; null when no single byte is at fault.
    error_offset: ?usize,

    /// Diagnoses raw input that failed `ToolArgumentIntegrity` classification.
    /// `scratch` backs only the scanner's nesting stack, released before return.
    pub fn diagnose(scratch: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!ToolArgumentDiagnostic {
        var scanner = std.json.Scanner.initCompleteInput(scratch, raw);
        defer scanner.deinit();
        var position: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&position);
        while (true) {
            const token = scanner.next() catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                // Complete input cannot underrun; treat it as the same missing tail.
                error.UnexpectedEndOfInput, error.BufferUnderrun => .{
                    .failure = .truncated,
                    .input_bytes = raw.len,
                    .error_offset = raw.len,
                },
                error.SyntaxError => .{
                    .failure = .syntax_error,
                    .input_bytes = raw.len,
                    .error_offset = @min(raw.len, std.math.cast(usize, position.getByteOffset()) orelse raw.len),
                },
            };
            if (token == .end_of_document) return .{
                .failure = .rejected_value,
                .input_bytes = raw.len,
                .error_offset = null,
            };
        }
    }
};

test "tool argument diagnostic locates truncated, syntax, and rejected input" {
    const alloc = std.testing.allocator;
    const cut = "{\"request\":{\"action\":\"run\",\"task\":\"Investigate the \\\"slow exit\\\" path and report";
    try std.testing.expectEqual(
        ToolArgumentDiagnostic{ .failure = .truncated, .input_bytes = cut.len, .error_offset = cut.len },
        try ToolArgumentDiagnostic.diagnose(alloc, cut),
    );

    const unescaped = "{\"task\":\"say \"hi\" now\"}";
    try std.testing.expectEqual(
        ToolArgumentDiagnostic{ .failure = .syntax_error, .input_bytes = unescaped.len, .error_offset = std.mem.find(u8, unescaped, "hi").? },
        try ToolArgumentDiagnostic.diagnose(alloc, unescaped),
    );

    const trailing = "{\"path\":\"a\",}";
    try std.testing.expectEqual(
        ToolArgumentDiagnostic{ .failure = .syntax_error, .input_bytes = trailing.len, .error_offset = trailing.len - 1 },
        try ToolArgumentDiagnostic.diagnose(alloc, trailing),
    );

    const repeated = "{\"path\":\"a\",\"path\":\"b\"}";
    try std.testing.expectEqual(
        ToolArgumentDiagnostic{ .failure = .rejected_value, .input_bytes = repeated.len, .error_offset = null },
        try ToolArgumentDiagnostic.diagnose(alloc, repeated),
    );

    try std.testing.expectEqual(
        ToolArgumentDiagnostic{ .failure = .truncated, .input_bytes = 0, .error_offset = 0 },
        try ToolArgumentDiagnostic.diagnose(alloc, ""),
    );

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, ToolArgumentDiagnostic.diagnose(failing.allocator(), "[" ** 4096));
}

fn fuzzToolArgumentDiagnostic(_: void, smith: *std.testing.Smith) anyerror!void {
    var input_buffer: [1024]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input_buffer));
    const input = input_buffer[0..input_len];
    if (try ToolArgumentIntegrity.classifyFunctionInput(std.testing.allocator, input) != .malformed_json) return;
    const diagnostic = try ToolArgumentDiagnostic.diagnose(std.testing.allocator, input);
    try std.testing.expectEqual(input.len, diagnostic.input_bytes);
    if (diagnostic.error_offset) |offset| try std.testing.expect(offset <= input.len);
    try std.testing.expectEqual(diagnostic.failure == .rejected_value, diagnostic.error_offset == null);
}

test "fuzz tool argument diagnostic" {
    try std.testing.fuzz({}, fuzzToolArgumentDiagnostic, .{
        .corpus = &.{
            "{\"request\":{\"task\":\"cut",
            "{\"a\":1,}",
            "{\"a\":1,\"a\":2}",
            "{\"t\":\"\xc3\xa9\xe2\x82",
            "\xff\x00{",
        },
    });
}

test "diagnostic failure has exactly the existing payload-free tags" {
    const fields = std.meta.fields(ToolArgumentDiagnostic.Failure);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("truncated", fields[0].name);
    try std.testing.expectEqualStrings("syntax_error", fields[1].name);
    try std.testing.expectEqualStrings("rejected_value", fields[2].name);
}
