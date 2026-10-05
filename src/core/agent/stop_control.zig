const std = @import("std");

/// Once-per-turn stop-checkpoint dispatch control. This latch does not decide
/// completion, retain a hook outcome, own cancellation, or materialize text.
/// Mark it only after dispatch succeeds, never after a cancelled dispatch.
pub const StopControl = struct {
    dispatched: bool = false,

    pub fn markDispatched(self: *StopControl) void {
        self.dispatched = true;
    }

    pub fn needsDispatch(self: StopControl) bool {
        return !self.dispatched;
    }
};

test "stop control permits dispatch once and is idempotent" {
    var control: StopControl = .{};
    try std.testing.expect(control.needsDispatch());
    // A cancelled dispatch does not mark the latch; steering may continue.
    try std.testing.expect(control.needsDispatch());
    control.markDispatched();
    try std.testing.expect(!control.needsDispatch());
    control.markDispatched();
    try std.testing.expect(!control.needsDispatch());
    const fields = std.meta.fields(StopControl);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("dispatched", fields[0].name);
    try std.testing.expect(fields[0].type == bool);
}
