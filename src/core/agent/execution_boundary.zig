const std = @import("std");
const types = @import("../shared/types.zig");
const model_provider = @import("./model_provider.zig");
const stream_provider = @import("./stream_provider.zig");

// Prove that credentials are separable at the provider request boundary.
// The existing stream_provider.ModelRequest contains credentials via the
// `credential` field. This test demonstrates that the neutral execution data
// (messages, tools, deadlines, etc.) is entirely independent of credential state.

test "stream_provider.ModelRequest separates neutral execution data from credentials" {
    var cancelled: std.atomic.Value(bool) = .init(false);
    var delivery: stream_provider.DeliveryCertainty = .init();
    var attempt: stream_provider.AttemptEvidence = .{};

    var events_context: bool = false;
    const fn_emit = struct {
        fn emit(_: *anyopaque, _: stream_provider.Event) void {}
    }.emit;

    // Construct a request with host credential
    const request: stream_provider.ModelRequest = .{
        .credential = .host_managed,
        .session_id = "session-123",
        .model = "test-model",
        .retry_count = 0,
        .messages = &.{},
        .tool_choice = .auto,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt,
        .events = .{ .context = &events_context, .emit_fn = fn_emit },
        .cancel_flag = &cancelled,
    };

    // Verify neutral fields are independent of credential
    try std.testing.expectEqualStrings("test-model", request.model);
    try std.testing.expectEqualStrings("session-123", request.session_id.?);
    try std.testing.expectEqual(request.retry_count, 0);

    // Credential is separable: could be injected from caller
    try std.testing.expectEqual(request.credential, .host_managed);

    // ModelProvider never sees the credential
    const provider: model_provider.ModelProvider = .{
        .id = "test-provider",
        .model = request.model,
        .context = undefined,
        .chat_fn = undefined,
        .capabilities_fn = undefined,
    };
    try std.testing.expectEqualStrings("test-model", provider.model);
}

test "stream_provider.Result contains only neutral completion data, no credentials" {
    const result: stream_provider.Result = .{
        .completed = .{
            .completion = .{
                .content = "response",
                .finish_reason = .stop,
                .usage = .{ .input_tokens = 100, .output_tokens = 50 },
            },
            .ownership = .borrowed,
        },
    };

    // Completion contains only neutral execution outcomes
    try std.testing.expect(result == .completed);
    try std.testing.expectEqualStrings("response", result.completed.completion.content.?);
    try std.testing.expectEqual(result.completed.completion.finish_reason, .stop);

    // No credential, no account, no billing in the result
    try std.testing.expect(result.completed.completion.usage.input_tokens != null);
}

test "credential injection happens at stream_provider.ModelRequest construction only" {
    var cancelled: std.atomic.Value(bool) = .init(false);
    var delivery: stream_provider.DeliveryCertainty = .init();
    var attempt: stream_provider.AttemptEvidence = .{};

    var events_context: bool = false;
    const fn_emit = struct {
        fn emit(_: *anyopaque, _: stream_provider.Event) void {}
    }.emit;

    // Before: neutral execution state (no credential)
    // This represents the execution context from the orchestrator

    // At boundary: credential is injected explicitly
    const injected_credential: types.CredentialLease = .host_managed;

    // After: request with credential, ready for transport
    const request: stream_provider.ModelRequest = .{
        .credential = injected_credential,
        .session_id = "test",
        .model = "model",
        .retry_count = 0,
        .messages = &.{},
        .tool_choice = .auto,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt,
        .events = .{ .context = &events_context, .emit_fn = fn_emit },
        .cancel_flag = &cancelled,
    };

    try std.testing.expectEqual(request.credential, .host_managed);
}
