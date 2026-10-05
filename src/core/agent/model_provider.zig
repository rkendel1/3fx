const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ProviderCapabilities = struct {
    chat: bool = true,
    streaming: bool = true,
    tool_calls: bool = false,
    vision: bool = false,
    structured_output: bool = false,
};

/// Host-enabled features are separate from the model's protocol capabilities.
pub const ModelFeatures = struct {
    prompt_caching: bool = false,
    native_search: bool = false,
    vision_fallback: bool = false,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const Message = struct {
    role: enum { system, user, assistant, tool },
    content: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: std.json.Value,
};

pub const Event = union(enum) {
    content_delta: []const u8,
    reasoning_delta: []const u8,
};

/// Events borrow their text only for the synchronous callback. A consumer
/// that retains a delta must copy it before returning from emit_fn.
pub const EventSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, Event) void,

    pub fn emit(self: EventSink, event: Event) void {
        self.emit_fn(self.context, event);
    }
};

pub const Admission = struct {
    context: ?*anyopaque = null,
    admit_fn: ?*const fn (*anyopaque) anyerror!void = null,

    pub fn admit(self: Admission) !void {
        const callback = self.admit_fn orelse return;
        try callback(self.context orelse return error.MissingAdmissionContext);
    }
};

pub const Delivery = struct {
    possibly_sent: std.atomic.Value(bool) = .init(false),
};

/// Inputs borrow from the caller until chat returns. The endpoint and any
/// transport authorization stay in the adapter, not in the conversation.
pub const ChatRequest = struct {
    messages: []const Message,
    tools: []const Tool = &.{},
    tool_choice: enum { auto, none, required } = .auto,
    max_output_tokens: ?u32 = null,
    max_content_bytes: ?usize = null,
    events: ?EventSink = null,
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp = null,
    admission: Admission = .{},
    delivery: *Delivery,
    /// An exact body previously serialized by this same adapter. This optional
    /// optimization permits capacity measurement without rebuilding a body.
    /// Never reuse it after changing the model, messages, or tool selection.
    prepared_body: ?[]const u8 = null,
};

pub const TokenUsage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_read_tokens: ?u64 = null,
    cache_write_tokens: ?u64 = null,
    reasoning_tokens: ?u64 = null,
};

pub const FinishReason = enum { stop, tool_calls, length, content_filter };

pub const Completion = struct {
    content: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    response_id: ?[]const u8 = null,
    /// Opaque protocol continuation data. Only the originating adapter may
    /// interpret it; it is not conversation authority or a tool result.
    continuation: ?[]const u8 = null,
    finish_reason: ?FinishReason = null,
    usage: TokenUsage = .{},
};

pub const FailureKind = enum {
    invalid_request,
    unauthorized,
    forbidden,
    request_too_large,
    rate_limited,
    server_error,
    bad_gateway,
    unavailable,
    gateway_timeout,
    provider_error,
};

pub const Failure = struct {
    kind: FailureKind,
    detail: ?[]const u8 = null,
    retry_after_seconds: ?u64 = null,
};

/// Streaming follows the runtime's synchronous EventSink convention. chat
/// emits ordered deltas before returning the terminal result. The allocator
/// owns every slice in this result, even when the result is a failure.
pub const ChatStream = union(enum) {
    completed: Completion,
    failed: Failure,

    pub fn deinit(self: *ChatStream, alloc: Allocator) void {
        switch (self.*) {
            .completed => |completion| {
                if (completion.content) |text| alloc.free(text);
                if (completion.response_id) |id| alloc.free(id);
                if (completion.continuation) |data| alloc.free(data);
                for (completion.tool_calls) |call| {
                    alloc.free(call.id);
                    alloc.free(call.name);
                    alloc.free(call.arguments_json);
                }
                alloc.free(completion.tool_calls);
            },
            .failed => |failure| if (failure.detail) |text| alloc.free(text),
        }
        self.* = undefined;
    }
};

/// Canonical agent-facing model invocation. Context, id, and model borrow
/// adapter-owned storage and must outlive every in-flight call. No transport
/// implementation is imported by this contract.
pub const ModelProvider = struct {
    id: []const u8,
    model: []const u8,
    context: *anyopaque,
    chat_fn: *const fn (*anyopaque, Allocator, ChatRequest) anyerror!ChatStream,
    capabilities_fn: *const fn (*anyopaque) ProviderCapabilities,

    pub fn chat(self: ModelProvider, alloc: Allocator, request: ChatRequest) !ChatStream {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (self.model.len == 0) return error.InvalidModel;
        return self.chat_fn(self.context, alloc, request);
    }

    pub fn capabilities(self: ModelProvider) ProviderCapabilities {
        return self.capabilities_fn(self.context);
    }
};

test "ModelProvider is constructible and streams without control-plane state" {
    const Fake = struct {
        fn chat(_: *anyopaque, alloc: Allocator, request: ChatRequest) !ChatStream {
            try request.admission.admit();
            request.events.?.emit(.{ .content_delta = "answer" });
            return .{ .completed = .{ .content = try alloc.dupe(u8, "answer"), .finish_reason = .stop } };
        }
        fn capabilities(_: *anyopaque) ProviderCapabilities {
            return .{ .tool_calls = true };
        }
        fn emit(raw: *anyopaque, event: Event) void {
            const received: *bool = @ptrCast(@alignCast(raw));
            received.* = event == .content_delta and std.mem.eql(u8, event.content_delta, "answer");
        }
    };
    var received = false;
    var cancelled: std.atomic.Value(bool) = .init(false);
    var delivery: Delivery = .{};
    const provider: ModelProvider = .{ .id = "configuration-id", .model = "arbitrary-model", .context = &received, .chat_fn = Fake.chat, .capabilities_fn = Fake.capabilities };
    var result = try provider.chat(std.testing.allocator, .{
        .messages = &.{.{ .role = .user, .content = "prompt" }},
        .events = .{ .context = &received, .emit_fn = Fake.emit },
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(received);
    try std.testing.expect(provider.capabilities().tool_calls);
    cancelled.store(true, .seq_cst);
    try std.testing.expectError(error.Cancelled, provider.chat(std.testing.allocator, .{ .messages = &.{}, .cancel_flag = &cancelled, .delivery = &delivery }));
}

test "ModelProvider contract closure has no control-plane fields" {
    inline for (.{ ModelProvider, ChatRequest, Completion, ProviderCapabilities, Failure }) |T| {
        inline for (std.meta.fields(T)) |field| {
            inline for (.{ "vendor", "account", "subscription", "team", "billing", "credential", "oauth", "login", "upgrade" }) |forbidden| {
                try std.testing.expect(std.mem.indexOf(u8, field.name, forbidden) == null);
            }
        }
    }
}
