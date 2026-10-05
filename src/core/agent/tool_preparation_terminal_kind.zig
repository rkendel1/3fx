const std = @import("std");

/// Existing pre-execution terminal reason, not permission or execution status.
pub const ToolPreparationTerminalKind = enum {
    idempotent_skip,
    validation_failure,
    availability_failure,
    unsupported,
    file_mutation_failure,
};

test "preparation terminal kind preserves the exact existing classifications" {
    const fields = std.meta.fields(ToolPreparationTerminalKind);
    const names = .{ "idempotent_skip", "validation_failure", "availability_failure", "unsupported", "file_mutation_failure" };
    try std.testing.expectEqual(@as(usize, 5), fields.len);
    inline for (fields, names) |field, name| {
        try std.testing.expectEqualStrings(name, field.name);
        const value: ToolPreparationTerminalKind = @enumFromInt(field.value);
        try std.testing.expectEqual(field.value, @intFromEnum(value));
    }
}
