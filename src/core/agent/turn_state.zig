const std = @import("std");
const models = @import("model_provider.zig");

pub const PromptDelivery = union(enum) {
    ordinary,
    active_turn: u64,
    continuation,

    pub fn activeTurnId(self: PromptDelivery) ?u64 {
        return switch (self) {
            .active_turn => |turn_id| turn_id,
            .ordinary, .continuation => null,
        };
    }

    pub fn isSteering(self: PromptDelivery) bool {
        return switch (self) {
            .ordinary => false,
            .active_turn, .continuation => true,
        };
    }

    pub fn isContinuation(self: PromptDelivery) bool {
        return self == .continuation;
    }
};

/// Conversation-local turn counters and freshness. Neither queue ownership nor
/// model transport configuration is part of this state.
pub const TurnState = struct {
    fresh: bool = true,
    tokens: models.TokenUsage = .{},

    pub fn start(self: *TurnState) void {
        self.fresh = false;
        self.tokens = .{};
    }

    pub fn observe(self: *TurnState, tokens: models.TokenUsage) void {
        inline for (std.meta.fields(models.TokenUsage)) |field| {
            if (@field(tokens, field.name)) |amount| {
                const total = &@field(self.tokens, field.name);
                total.* = std.math.add(u64, total.* orelse 0, amount) catch std.math.maxInt(u64);
            }
        }
    }
};

test "neutral turn state resets and saturates token counters" {
    var state: TurnState = .{};
    try std.testing.expect(state.fresh);
    state.start();
    try std.testing.expect(!state.fresh);
    state.observe(.{ .input_tokens = 4, .output_tokens = 2 });
    state.observe(.{ .input_tokens = std.math.maxInt(u64) });
    try std.testing.expectEqual(std.math.maxInt(u64), state.tokens.input_tokens.?);
    state.start();
    try std.testing.expect(state.tokens.input_tokens == null);
}

test "neutral delivery preserves steering and continuation classification" {
    try std.testing.expect(!(@as(PromptDelivery, .ordinary)).isSteering());
    const active: PromptDelivery = .{ .active_turn = 42 };
    try std.testing.expectEqual(@as(?u64, 42), active.activeTurnId());
    try std.testing.expect(active.isSteering());
    try std.testing.expect(!active.isContinuation());
    try std.testing.expect((@as(PromptDelivery, .continuation)).isContinuation());
    try std.testing.expect((@as(PromptDelivery, .continuation)).isSteering());
    try std.testing.expect((@as(PromptDelivery, .continuation)).activeTurnId() == null);
}
