const std = @import("std");

/// Existing leading parallel-group classification only. This is not permission
/// approval or a promise that any call will execute. Length and call payloads
/// remain with the existing scheduler and its caller.
pub const ParallelGroupDecision = enum {
    none,
    read_only,
    subagent,
};

test "parallel group decision contains exactly the existing scheduling classifications" {
    const fields = std.meta.fields(ParallelGroupDecision);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("none", fields[0].name);
    try std.testing.expectEqualStrings("read_only", fields[1].name);
    try std.testing.expectEqualStrings("subagent", fields[2].name);
    inline for (fields) |field| {
        const decision: ParallelGroupDecision = @enumFromInt(field.value);
        try std.testing.expectEqual(field.value, @intFromEnum(decision));
    }
}
