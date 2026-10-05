const std = @import("std");

/// Classification only. Guidance and its allocator remain owned by the worker
/// boundary result; copying a decision never copies or transfers that payload.
pub const SteeringDecision = enum {
    none,
    continue_turn,
    handoff,
    interrupt,
};

test "steering decision has exactly the existing payload-free classifications" {
    const fields = std.meta.fields(SteeringDecision);
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqualStrings("none", fields[0].name);
    try std.testing.expectEqualStrings("continue_turn", fields[1].name);
    try std.testing.expectEqualStrings("handoff", fields[2].name);
    try std.testing.expectEqualStrings("interrupt", fields[3].name);
    inline for (fields) |field| {
        const decision: SteeringDecision = @enumFromInt(field.value);
        try std.testing.expectEqual(field.value, @intFromEnum(decision));
    }
}
