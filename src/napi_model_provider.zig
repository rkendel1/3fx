// NAPI boundary for the public FX model/provider API
// Maps JavaScript FxChatRequest ↔ ModelProvider.ChatRequest
// Does not expose native Zig types directly to JavaScript

const std = @import("std");
const model_provider = @import("core/agent/model_provider.zig");
const openai_provider = @import("gateway/openai_compatible_model_provider.zig");
const io_mod = @import("core/shared/io.zig");

const Allocator = std.mem.Allocator;

/// NAPI-managed model provider handle with owned string storage
pub const NapiModelHandle = struct {
    id: []u8,
    base_url: []u8,
    model: []u8,
    api_key_env: ?[]u8,
    openai: openai_provider.OpenAICompatibleModelProvider,
    allocator: Allocator,

    pub fn deinit(self: *NapiModelHandle) void {
        self.allocator.free(self.id);
        self.allocator.free(self.base_url);
        self.allocator.free(self.model);
        if (self.api_key_env) |env| self.allocator.free(env);
    }
};

pub const ModelProviderHandle = struct {
    id: []const u8,
    openai: openai_provider.OpenAICompatibleModelProvider,
    allocator: Allocator,

    pub fn deinit(self: *ModelProviderHandle) void {
        self.allocator.free(self.id);
    }
};

/// Public FFI-safe request type corresponding to ChatRequest
pub const FxChatMessage = struct {
    role: enum { system, user, assistant, tool },
    content: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls: []const FxToolCall = &.{},
};

pub const FxToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const FxTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,  // raw JSON string
};

pub const FxChatRequest = struct {
    messages: []const FxChatMessage,
    model: []const u8,
    tools: []const FxTool = &.{},
    tool_choice: enum { auto, none, required } = .auto,
    max_output_tokens: ?u32 = null,
};

/// Public FFI-safe result type corresponding to ChatStream
pub const FxChatCompletion = struct {
    content: ?[]const u8 = null,
    tool_calls: []const FxToolCall = &.{},
    usage: FxTokenUsage = .{},
};

pub const FxTokenUsage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_read_tokens: ?u64 = null,
    cache_write_tokens: ?u64 = null,
    reasoning_tokens: ?u64 = null,
};

/// Streaming events from provider
pub const FxStreamEvent = union(enum) {
    text_delta: []const u8,
    tool_call_delta: struct { id: []const u8, name: []const u8, arguments_delta: []const u8 },
    completion: struct { content: ?[]const u8, tool_calls: []const FxToolCall, finish_reason: ?[]const u8, usage: FxTokenUsage },
    failure: struct { kind: []const u8, detail: ?[]const u8 },
};

pub const FxFailureKind = enum {
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

pub const FxChatFailure = struct {
    kind: FxFailureKind,
    detail: ?[]const u8 = null,
    retry_after_seconds: ?u64 = null,
};

pub const FxChatResult = union(enum) {
    completed: FxChatCompletion,
    failed: FxChatFailure,

    pub fn deinit(self: *FxChatResult, alloc: Allocator) void {
        switch (self.*) {
            .completed => |completion| {
                if (completion.content) |text| alloc.free(text);
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

/// Create a model provider handle from OpenAI-compatible endpoint configuration
pub fn createModelProvider(
    alloc: Allocator,
    id: []const u8,
    base_url: []const u8,
    model: []const u8,
    api_key_env: ?[]const u8,
) !*ModelProviderHandle {
    const handle = try alloc.create(ModelProviderHandle);
    errdefer alloc.destroy(handle);

    handle.id = try alloc.dupe(u8, id);
    errdefer alloc.free(handle.id);

    handle.openai = try openai_provider.OpenAICompatibleModelProvider.init(id, base_url, model, api_key_env);
    handle.allocator = alloc;

    return handle;
}

/// Create a NAPI-managed model provider handle with owned string storage
pub fn createNapiModelHandle(
    alloc: Allocator,
    id: []const u8,
    base_url: []const u8,
    model: []const u8,
    api_key_env: ?[]const u8,
) !*NapiModelHandle {
    const handle = try alloc.create(NapiModelHandle);
    errdefer alloc.destroy(handle);

    handle.id = try alloc.dupe(u8, id);
    errdefer alloc.free(handle.id);

    handle.base_url = try alloc.dupe(u8, base_url);
    errdefer alloc.free(handle.base_url);

    handle.model = try alloc.dupe(u8, model);
    errdefer alloc.free(handle.model);

    if (api_key_env) |env| {
        handle.api_key_env = try alloc.dupe(u8, env);
        errdefer alloc.free(handle.api_key_env.?);
    } else {
        handle.api_key_env = null;
    }

    handle.openai = try openai_provider.OpenAICompatibleModelProvider.init(handle.id, handle.base_url, handle.model, handle.api_key_env);
    handle.allocator = alloc;

    return handle;
}

/// Execute a chat request through the model provider
pub fn modelChat(
    handle: *ModelProviderHandle,
    alloc: Allocator,
    request: FxChatRequest,
) !FxChatResult {
    // Convert FxChatRequest → model_provider.ChatRequest
    const messages = try alloc.alloc(model_provider.Message, request.messages.len);
    defer alloc.free(messages);

    for (request.messages, 0..) |fx_msg, i| {
        const tool_calls = try alloc.alloc(model_provider.ToolCall, fx_msg.tool_calls.len);
        for (fx_msg.tool_calls, 0..) |fx_call, j| {
            tool_calls[j] = .{
                .id = fx_call.id,
                .name = fx_call.name,
                .arguments_json = fx_call.arguments_json,
            };
        }
        messages[i] = .{
            .role = switch (fx_msg.role) {
                .system => .system,
                .user => .user,
                .assistant => .assistant,
                .tool => .tool,
            },
            .content = fx_msg.content,
            .tool_call_id = fx_msg.tool_call_id,
            .tool_calls = tool_calls,
        };
    }

    const tools = try alloc.alloc(model_provider.Tool, request.tools.len);
    defer alloc.free(tools);

    for (request.tools, 0..) |fx_tool, i| {
        var parser = std.json.Parser.init(alloc, false);
        defer parser.deinit();
        const schema = try parser.parse(std.json.Value, alloc, fx_tool.input_schema_json, .{});
        tools[i] = .{
            .name = fx_tool.name,
            .description = fx_tool.description,
            .input_schema = schema,
        };
    }

    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = model_provider.Delivery{};

    const chat_request: model_provider.ChatRequest = .{
        .messages = messages,
        .tools = tools,
        .tool_choice = switch (request.tool_choice) {
            .auto => .auto,
            .none => .none,
            .required => .required,
        },
        .max_output_tokens = request.max_output_tokens,
        .events = null,  // no streaming for now
        .cancel_flag = &cancelled,
        .deadline = null,
        .delivery = &delivery,
    };

    const provider = handle.openai.provider();
    const stream = try provider.chat(alloc, chat_request);

    // Convert ChatStream → FxChatResult
    var result: FxChatResult = undefined;
    switch (stream) {
        .completed => |completion| {
            const tool_calls = try alloc.alloc(FxToolCall, completion.tool_calls.len);
            for (completion.tool_calls, 0..) |call, i| {
                tool_calls[i] = .{
                    .id = try alloc.dupe(u8, call.id),
                    .name = try alloc.dupe(u8, call.name),
                    .arguments_json = try alloc.dupe(u8, call.arguments_json),
                };
            }

            result = .{
                .completed = .{
                    .content = if (completion.content) |text| try alloc.dupe(u8, text) else null,
                    .tool_calls = tool_calls,
                    .usage = .{
                        .input_tokens = completion.usage.input_tokens,
                        .output_tokens = completion.usage.output_tokens,
                        .cache_read_tokens = completion.usage.cache_read_tokens,
                        .cache_write_tokens = completion.usage.cache_write_tokens,
                        .reasoning_tokens = completion.usage.reasoning_tokens,
                    },
                },
            };
        },
        .failed => |failure| {
            result = .{
                .failed = .{
                    .kind = switch (failure.kind) {
                        .invalid_request => .invalid_request,
                        .unauthorized => .unauthorized,
                        .forbidden => .forbidden,
                        .request_too_large => .request_too_large,
                        .rate_limited => .rate_limited,
                        .server_error => .server_error,
                        .bad_gateway => .bad_gateway,
                        .unavailable => .unavailable,
                        .gateway_timeout => .gateway_timeout,
                        .provider_error => .provider_error,
                    },
                    .detail = if (failure.detail) |text| try alloc.dupe(u8, text) else null,
                    .retry_after_seconds = failure.retry_after_seconds,
                },
            };
        },
    }

    return result;
}
