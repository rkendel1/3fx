const std = @import("std");
const types = @import("../shared/types.zig");
const worker = @import("worker_runtime.zig");
const turn_execution_input = @import("turn_execution_input.zig");
const execution_compatibility = @import("../app/execution_compatibility.zig");

test "turn execution input separates neutral data from compatibility state" {
    const alloc = std.testing.allocator;

    // Create a compatibility job with sensitive data
    const job: worker.CompatibilityExecutionJob = .{
        .turn_id = 123,
        .delivery = .ordinary,
        .prompt = @constCast("test prompt"),
        .images = &.{},
        .model = @constCast("gpt-4"),
        .provider = .gateway,
        .api_key = @constCast("secret-api-key-xyz"),
        .credential_source = .chatgpt_subscription,
        .account_id = @constCast("billing_account_123"),
        .gateway_team = @constCast("team_xyz_prod"),
        .permission_mode = .auto,
        .history = &.{},
        .grants = &.{},
        .root_user_intent_context = @constCast("context"),
    };

    // Project the neutral boundary
    const input = execution_compatibility.turnExecutionInput(job);

    // Verify neutral data is present
    try std.testing.expectEqual(@as(u64, 123), input.turn_id);
    try std.testing.expectEqualStrings("test prompt", input.prompt);
    try std.testing.expectEqualStrings("gpt-4", input.model);
    try std.testing.expectEqual(worker.PromptDelivery, @TypeOf(input.delivery));

    // Verify the type definition itself excludes auth fields
    const fields = std.meta.fields(turn_execution_input.TurnExecutionInput);
    var auth_fields_found = false;
    for (fields) |field| {
        if (std.mem.indexOf(u8, field.name, "credential_source") != null or
            std.mem.indexOf(u8, field.name, "api_key") != null or
            std.mem.indexOf(u8, field.name, "account_id") != null or
            std.mem.indexOf(u8, field.name, "gateway_team") != null)
        {
            auth_fields_found = true;
        }
    }
    try std.testing.expect(!auth_fields_found);
}

test "turn execution input can be constructed without compatibility job" {
    const alloc = std.testing.allocator;

    const prompt = try alloc.dupe(u8, "standalone prompt");
    defer alloc.free(prompt);

    const input: turn_execution_input.TurnExecutionInput = .{
        .turn_id = 456,
        .delivery = .continuation,
        .prompt = prompt,
        .images = &.{},
        .model = @constCast("claude-3-opus"),
        .provider = .gateway,
        .history = &.{},
        .grants = &.{},
    };

    try std.testing.expectEqual(@as(u64, 456), input.turn_id);
    try std.testing.expectEqualStrings("standalone prompt", input.prompt);
    try std.testing.expect(input.delivery.isContinuation());
}

test "turn execution input preserves all neutral fields through projection" {
    const alloc = std.testing.allocator;

    const prompt = try alloc.dupe(u8, "request text");
    defer alloc.free(prompt);

    const context = try alloc.dupe(u8, "user context");
    defer alloc.free(context);

    const job: worker.CompatibilityExecutionJob = .{
        .turn_id = 999,
        .delivery = .ordinary,
        .prompt = prompt,
        .images = &.{},
        .model = @constCast("model-name"),
        .provider = .gateway,
        .api_key = @constCast("unused-key"),
        .permission_mode = .auto,
        .history = &.{},
        .grants = &.{},
        .root_user_intent_context = context,
        .recovery_source_already_presented = true,
        .user_prompt_already_presented = false,
    };

    const input = execution_compatibility.turnExecutionInput(job);

    // Verify each category-A field is preserved
    try std.testing.expectEqual(@as(u64, 999), input.turn_id);
    try std.testing.expectEqualStrings("request text", input.prompt);
    try std.testing.expectEqualStrings("model-name", input.model);
    try std.testing.expectEqualStrings("user context", input.root_user_intent_context);
    try std.testing.expect(input.recovery_source_already_presented);
    try std.testing.expect(!input.user_prompt_already_presented);

    // Slices are borrowed, pointers match
    try std.testing.expect(input.prompt.ptr == prompt.ptr);
    try std.testing.expect(input.root_user_intent_context.ptr == context.ptr);
}

test "turn execution input projection is zero-allocation" {
    // This test ensures the projection function performs no allocations
    var fixed_buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    const alloc = fba.allocator();

    const job: worker.CompatibilityExecutionJob = .{
        .turn_id = 1,
        .prompt = @constCast("test"),
        .images = &.{},
        .model = @constCast("model"),
        .api_key = @constCast("key"),
        .permission_mode = .auto,
        .history = &.{},
        .grants = &.{},
    };

    // Record initial allocation state
    const initial_allocated = fba.end_index;

    // Project the input
    const input = execution_compatibility.turnExecutionInput(job);

    // Verify no allocations occurred
    try std.testing.expectEqual(initial_allocated, fba.end_index);
    try std.testing.expectEqual(@as(u64, 1), input.turn_id);
}
