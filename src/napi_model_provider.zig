//! Native runtime behind the public Node model API. It owns provider
//! configuration, per-call requests, and cancellation state; the Node-API
//! glue in napi_core_main.zig only translates values and schedules work.

const std = @import("std");
const model_provider = @import("core/agent/model_provider.zig");
const openai_provider = @import("gateway/openai_compatible_model_provider.zig");

const Allocator = std.mem.Allocator;

pub const ToolChoice = @FieldType(model_provider.ChatRequest, "tool_choice");
pub const ToolChoiceMode = @FieldType(openai_provider.OpenAICompatibleModelProvider, "tool_choice_mode");

/// Shared by the JavaScript wrapper and every in-flight call, so a handle
/// collected by JavaScript stays valid until its last worker finishes.
pub const ModelHandle = struct {
    alloc: Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    id: []u8,
    base_url: []u8,
    model: []u8,
    api_key_env: ?[]u8,
    openai: openai_provider.OpenAICompatibleModelProvider,

    /// The returned handle owns copies of every string and starts with one reference.
    pub fn create(
        alloc: Allocator,
        id: []const u8,
        base_url: []const u8,
        model: []const u8,
        api_key_env: ?[]const u8,
        tool_choice_mode: ToolChoiceMode,
    ) !*ModelHandle {
        const self = try alloc.create(ModelHandle);
        errdefer alloc.destroy(self);
        const id_copy = try alloc.dupe(u8, id);
        errdefer alloc.free(id_copy);
        const base_url_copy = try alloc.dupe(u8, base_url);
        errdefer alloc.free(base_url_copy);
        const model_copy = try alloc.dupe(u8, model);
        errdefer alloc.free(model_copy);
        const api_key_env_copy: ?[]u8 = if (api_key_env) |name| try alloc.dupe(u8, name) else null;
        errdefer if (api_key_env_copy) |name| alloc.free(name);
        // The provider borrows these copies, so they must be the handle's own storage.
        var openai = try openai_provider.OpenAICompatibleModelProvider.init(id_copy, base_url_copy, model_copy, api_key_env_copy);
        openai.tool_choice_mode = tool_choice_mode;
        self.* = .{
            .alloc = alloc,
            .id = id_copy,
            .base_url = base_url_copy,
            .model = model_copy,
            .api_key_env = api_key_env_copy,
            .openai = openai,
        };
        return self;
    }

    pub fn retain(self: *ModelHandle) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *ModelHandle) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const alloc = self.alloc;
        alloc.free(self.id);
        alloc.free(self.base_url);
        alloc.free(self.model);
        if (self.api_key_env) |name| alloc.free(name);
        alloc.destroy(self);
    }

    /// Runs one provider call on the calling thread. The result is owned by `alloc`.
    pub fn run(
        self: *ModelHandle,
        alloc: Allocator,
        request: *const Request,
        call: *Call,
        events: ?model_provider.EventSink,
    ) !model_provider.ChatStream {
        var delivery: model_provider.Delivery = .{};
        return self.openai.provider().chat(alloc, .{
            .messages = request.messages,
            .tools = request.tools,
            .tool_choice = request.tool_choice,
            .max_output_tokens = request.max_output_tokens,
            .events = events,
            .cancel_flag = &call.cancelled,
            .delivery = &delivery,
        });
    }
};

/// Cancellation state shared by the JavaScript caller and the worker thread.
pub const Call = struct {
    alloc: Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    cancelled: std.atomic.Value(bool) = .init(false),

    pub fn create(alloc: Allocator) !*Call {
        const self = try alloc.create(Call);
        self.* = .{ .alloc = alloc };
        return self;
    }

    pub fn cancel(self: *Call) void {
        self.cancelled.store(true, .seq_cst);
    }

    pub fn retain(self: *Call) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Call) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.alloc.destroy(self);
    }
};

/// A provider-neutral request whose messages, tools, and schemas all live in
/// one arena, so a worker thread never borrows JavaScript memory.
pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    messages: []const model_provider.Message = &.{},
    tools: []const model_provider.Tool = &.{},
    tool_choice: ToolChoice = .auto,
    max_output_tokens: ?u32 = null,

    pub fn init(child: Allocator) Request {
        return .{ .arena = .init(child) };
    }

    pub fn deinit(self: *Request) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parseRole(name: []const u8) ?@FieldType(model_provider.Message, "role") {
    const Role = @FieldType(model_provider.Message, "role");
    return std.meta.stringToEnum(Role, name);
}

pub fn parseToolChoice(name: []const u8) ?ToolChoice {
    return std.meta.stringToEnum(ToolChoice, name);
}

pub fn parseToolChoiceMode(name: []const u8) ?ToolChoiceMode {
    return std.meta.stringToEnum(ToolChoiceMode, name);
}

test "model handle owns configuration and survives its creator's release" {
    const alloc = std.testing.allocator;
    var base_url = "http://127.0.0.1:9/v1".*;
    var env_name = "FX_MODEL_TEST_KEY".*;
    const handle = try ModelHandle.create(alloc, "local", &base_url, "model", &env_name, .send);
    // Overwrite the caller's buffers to prove the provider does not borrow them.
    @memset(&base_url, 'x');
    @memset(&env_name, 'x');
    handle.retain();
    handle.release();
    try std.testing.expectEqualStrings("http://127.0.0.1:9/v1", handle.openai.base_url);
    try std.testing.expectEqualStrings("FX_MODEL_TEST_KEY", handle.openai.api_key_env.?);
    try std.testing.expectEqual(.send, handle.openai.tool_choice_mode);
    handle.release();
}

test "model handle without an api key environment is valid" {
    const handle = try ModelHandle.create(std.testing.allocator, "local", "http://localhost:9/v1", "model", null, .omit);
    defer handle.release();
    try std.testing.expect(handle.openai.api_key_env == null);
}

test "model handle rejects insecure remote endpoints without leaking" {
    try std.testing.expectError(
        error.InsecureBaseUrl,
        ModelHandle.create(std.testing.allocator, "remote", "http://example.com/v1", "model", null, .omit),
    );
}

test "cancelled call is observed before the provider is contacted" {
    const alloc = std.testing.allocator;
    const handle = try ModelHandle.create(alloc, "local", "http://127.0.0.1:9/v1", "model", null, .omit);
    defer handle.release();
    const call = try Call.create(alloc);
    defer call.release();
    var request = Request.init(alloc);
    defer request.deinit();
    request.messages = try request.arena.allocator().dupe(model_provider.Message, &.{.{ .role = .user, .content = "hi" }});
    call.cancel();
    try std.testing.expectError(error.Cancelled, handle.run(alloc, &request, call, null));
}

test "roles and tool choices parse only their neutral names" {
    try std.testing.expectEqual(.tool, parseRole("tool").?);
    try std.testing.expect(parseRole("developer") == null);
    try std.testing.expectEqual(.required, parseToolChoice("required").?);
    try std.testing.expect(parseToolChoice("any") == null);
    try std.testing.expectEqual(.send, parseToolChoiceMode("send").?);
    try std.testing.expect(parseToolChoiceMode("auto") == null);
}
