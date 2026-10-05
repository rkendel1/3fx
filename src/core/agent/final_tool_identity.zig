pub const FinalToolIdentity = enum {
    valid,
    absent,
    empty,
    wrong_type,
};

test "final tool identity preserves the existing payload-free tags" {
    const std = @import("std");
    const fields = std.meta.fields(FinalToolIdentity);
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    const names = [_][]const u8{ "valid", "absent", "empty", "wrong_type" };
    inline for (fields, names, 0..) |field, name, index| {
        try std.testing.expectEqualStrings(name, field.name);
        try std.testing.expectEqual(index, field.value);
    }
}
