const std = @import("std");
const models = @import("../model_provider.zig");

/// The neutral invocation boundary accepts only an adapter handle and a chat
/// request. Stream ownership, cancellation, and terminal errors use the same
/// contract for every protocol configuration.
pub fn chat(provider: models.ModelProvider, alloc: std.mem.Allocator, request: models.ChatRequest) !models.ChatStream {
    return provider.chat(alloc, request);
}

test "neutral model step invokes a configured model without legacy dependencies" {
    const Fake = struct {
        calls: usize = 0,
        fn chat(raw: *anyopaque, alloc: std.mem.Allocator, request: models.ChatRequest) !models.ChatStream {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqualStrings("prompt", request.messages[0].content.?);
            return .{ .completed = .{ .content = try alloc.dupe(u8, "answer"), .finish_reason = .stop } };
        }
        fn capabilities(_: *anyopaque) models.ProviderCapabilities {
            return .{};
        }
    };
    var fake: Fake = .{};
    const provider: models.ModelProvider = .{ .id = "config", .model = "arbitrary-model", .context = &fake, .chat_fn = Fake.chat, .capabilities_fn = Fake.capabilities };
    var cancelled: std.atomic.Value(bool) = .init(false);
    var delivery: models.Delivery = .{};
    var result = try chat(provider, std.testing.allocator, .{
        .messages = &.{.{ .role = .user, .content = "prompt" }},
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("answer", result.completed.content.?);
}
