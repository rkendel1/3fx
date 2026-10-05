const std = @import("std");
const state = @import("turn_state.zig");

/// Borrowed coordination links outlive the turn. Counters are owned here;
/// model invocation, checkpoint interpretation, and conversation data are not.
pub const TurnCoordinator = struct {
    turn_id: u64,
    delivery: state.PromptDelivery,
    turn_state: *state.TurnState,
    cancel_flag: *std.atomic.Value(bool),
    attempt: usize = 0,
    attempt_limit: usize = 1,
    step: usize = 0,
    step_limit: usize,
};

test "turn coordinator shares cancellation and turn state without model authority" {
    var turn: state.TurnState = .{};
    var cancelled: std.atomic.Value(bool) = .init(false);
    var coordinator: TurnCoordinator = .{ .turn_id = 42, .delivery = .continuation, .turn_state = &turn, .cancel_flag = &cancelled, .step_limit = 3 };
    coordinator.turn_state.start();
    try std.testing.expect(!turn.fresh);
    cancelled.store(true, .seq_cst);
    try std.testing.expect(coordinator.cancel_flag.load(.seq_cst));
    try std.testing.expect(coordinator.delivery.isContinuation());
    coordinator.attempt += 1;
    coordinator.step += 1;
    try std.testing.expectEqual(@as(usize, 1), coordinator.attempt);
    try std.testing.expectEqual(@as(usize, 1), coordinator.step);
    inline for (std.meta.fields(TurnCoordinator)) |field| {
        inline for (.{ "provider", "credential", "account", "team", "billing", "auth" }) |forbidden| {
            try std.testing.expect(std.mem.indexOf(u8, field.name, forbidden) == null);
        }
    }
}
