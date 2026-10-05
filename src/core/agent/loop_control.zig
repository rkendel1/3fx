const std = @import("std");
const turn = @import("turn_coordinator.zig");

/// Neutral loop control. The coordinator remains the sole owner of turn,
/// attempt, step and cancellation state. This value owns the last entered
/// one-based step index used when presenting or finalizing a loop outcome.
pub const LoopControl = struct {
    coordinator: *turn.TurnCoordinator,
    current_step_index: usize = 0,
};

test "loop control borrows authoritative coordinator without duplicating counters" {
    var state: @import("turn_state.zig").TurnState = .{};
    var cancel: std.atomic.Value(bool) = .init(false);
    var coordinator: turn.TurnCoordinator = .{
        .turn_id = 41,
        .delivery = .continuation,
        .turn_state = &state,
        .cancel_flag = &cancel,
        .step_limit = 4,
    };
    var control: LoopControl = .{ .coordinator = &coordinator };
    try std.testing.expect(control.coordinator == &coordinator);
    control.coordinator.attempt += 1;
    control.coordinator.step += 1;
    control.current_step_index = control.coordinator.step + 1;
    try std.testing.expectEqual(@as(usize, 1), coordinator.attempt);
    try std.testing.expectEqual(@as(usize, 1), coordinator.step);
    try std.testing.expectEqual(@as(usize, 2), control.current_step_index);
    cancel.store(true, .seq_cst);
    try std.testing.expect(control.coordinator.cancel_flag.load(.seq_cst));
    try std.testing.expect(control.coordinator.delivery.isContinuation());
    try std.testing.expectEqual(@as(u64, 41), control.coordinator.turn_id);
    const fields = std.meta.fields(LoopControl);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(fields[0].type == *turn.TurnCoordinator);
    try std.testing.expect(fields[1].type == usize);
}
