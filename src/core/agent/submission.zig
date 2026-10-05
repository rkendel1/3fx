const delivery = @import("turn_state.zig");

/// Owned admission request. Captured model authority is a separate host input.
pub const Submission = struct {
    turn_id: u64 = 0,
    prompt: []u8,
    delivery: delivery.PromptDelivery = .ordinary,
};

test "neutral submission exposes only work fields" {
    const std = @import("std");
    const fields = std.meta.fields(Submission);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("turn_id", fields[0].name);
    try std.testing.expectEqualStrings("prompt", fields[1].name);
    try std.testing.expectEqualStrings("delivery", fields[2].name);
}
