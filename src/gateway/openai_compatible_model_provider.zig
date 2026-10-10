const std = @import("std");
const models = @import("../core/agent/model_provider.zig");
const codec = @import("chat_completions_protocol.zig");
const streams = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const io = @import("../core/shared/io.zig");
const client_mod = @import("client.zig");
const secret = @import("../core/auth/secret.zig");
const definitions = @import("../core/config/configured_provider.zig");
const Allocator = std.mem.Allocator;

/// Protocol configuration owns invocation and optional environment lookup.
/// The canonical handle exposes neither the endpoint nor transport secrets.
/// Storage borrows from the configuration owner for the lifetime of the handle.
pub const OpenAICompatibleModelProvider = struct {
    id: []const u8,
    base_url: []const u8,
    model: []const u8,
    api_key_env: ?[]const u8 = null,
    tool_choice_mode: definitions.ToolChoiceMode = .omit,
    tool_schema_mode: definitions.ToolSchemaMode = .canonical,
    finish_reason_mode: definitions.FinishReasonMode = .strict,

    pub fn init(id: []const u8, base_url: []const u8, model: []const u8, api_key_env: ?[]const u8) !OpenAICompatibleModelProvider {
        // Reuse the protocol configuration validator, without loading profile
        // state or constructing any authorization-session objects.
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const alloc = scratch.allocator();
        const config = try std.json.Stringify.valueAlloc(alloc, .{
            .type = "openai-compatible",
            .baseURL = base_url,
            .model = model,
        }, .{});
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, config, .{});
        defer parsed.deinit();
        if (api_key_env) |env| try parsed.value.object.put(alloc, "apiKeyEnv", .{ .string = env });
        const portable = try definitions.Portable.parse(parsed.value);
        return .{ .id = id, .base_url = base_url[0..portable.base_url.len], .model = model, .api_key_env = api_key_env };
    }

    pub fn provider(self: *OpenAICompatibleModelProvider) models.ModelProvider {
        return .{ .id = self.id, .model = self.model, .context = self, .chat_fn = chat, .capabilities_fn = capabilities };
    }

    fn capabilities(_: *anyopaque) models.ProviderCapabilities {
        return .{ .tool_calls = true };
    }

    fn chat(raw: *anyopaque, alloc: Allocator, request: models.ChatRequest) !models.ChatStream {
        const self: *OpenAICompatibleModelProvider = @ptrCast(@alignCast(raw));
        const token = if (self.api_key_env) |env| io.getenv(env) orelse return error.MissingConfiguredProviderCredential else null;
        if (token) |value| {
            if (value.len == 0) return error.MissingConfiguredProviderCredential;
            if (value.len > 16 * 1024) return error.InvalidConfiguredProviderCredential;
            for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidConfiguredProviderCredential;
        }
        const payload = request.prepared_body orelse try self.build(alloc, request);
        defer if (request.prepared_body == null) alloc.free(payload);
        return post(alloc, self, request, token, payload) catch |err| {
            if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
            if (request.deadline) |deadline| if (expired(deadline)) return error.Timeout;
            return err;
        };
    }

    pub fn build(self: *OpenAICompatibleModelProvider, alloc: Allocator, request: models.ChatRequest) ![]u8 {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const parser = try parser_request(scratch.allocator(), self.model, request);
        const messages = try scratch.allocator().alloc(types.ChatMessage, request.messages.len);
        var instruction_count: usize = 0;
        for (request.messages, 0..) |message, index| {
            const calls = try scratch.allocator().alloc(types.ToolCall, message.tool_calls.len);
            for (message.tool_calls, 0..) |call, i| calls[i] = .{ .id = call.id, .name = call.name, .arguments_json = call.arguments_json };
            messages[index] = .{ .role = switch (message.role) {
                .system => .system,
                .user => .user,
                .assistant => .assistant,
                .tool => .tool,
            }, .content = message.content, .tool_call_id = message.tool_call_id, .tool_calls = calls };
            if (message.role == .system) {
                if (index != instruction_count) return error.InvalidProviderPrompt;
                instruction_count += 1;
            }
        }
        var data = parser;
        data.instructions = messages[0..instruction_count];
        data.messages = messages[instruction_count..];
        data.max_output_tokens = request.max_output_tokens;
        return codec.build_request(alloc, data, .{
            .tool_choice_mode = self.tool_choice_mode,
            .tool_schema_mode = self.tool_schema_mode,
        });
    }
};

fn parser_request(alloc: Allocator, model: []const u8, request: models.ChatRequest) !streams.RequestData {
    const tools = try alloc.alloc(streams.DynamicFunctionTool, request.tools.len);
    for (request.tools, 0..) |tool, i| tools[i] = .{ .name = tool.name, .description = tool.description, .input_schema = tool.input_schema };
    return .{ .model = model, .messages = &.{}, .tools = .{ .selected_dynamic = tools }, .tool_choice = switch (request.tool_choice) {
        .auto => .auto,
        .none => .none,
        .required => .required,
    }, .provider_options = .{} };
}

const Events = struct {
    sink: ?models.EventSink,
    fn emit(raw: *anyopaque, event: streams.Event) void {
        const self: *Events = @ptrCast(@alignCast(raw));
        const sink = self.sink orelse return;
        switch (event) {
            .content_delta => |text| sink.emit(.{ .content_delta = text }),
            .reasoning_delta => |text| sink.emit(.{ .reasoning_delta = text }),
            else => {},
        }
    }
};

fn consume(alloc: Allocator, reader: *std.Io.Reader, model: []const u8, request: models.ChatRequest, limits: codec.Limits) !models.ChatStream {
    // The existing hardened protocol reducer is reused at the transport edge.
    // Only neutral completion fields cross back to the canonical contract.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var events: Events = .{ .sink = request.events };
    const parser = try parser_request(scratch.allocator(), model, request);
    var legacy = try codec.consume_stream(scratch.allocator(), reader, parser, limits, .{ .context = &events, .emit_fn = Events.emit }, request.cancel_flag);
    defer legacy.deinit(scratch.allocator());
    const source = legacy.completed.completion;
    var result: models.ChatStream = .{ .completed = .{ .usage = .{
        .input_tokens = source.usage.input_tokens,
        .output_tokens = source.usage.output_tokens,
        .cache_read_tokens = source.usage.cache_read_tokens,
        .cache_write_tokens = source.usage.cache_write_tokens,
        .reasoning_tokens = source.usage.reasoning_tokens,
    } } };
    errdefer result.deinit(alloc);
    if (source.content) |text| result.completed.content = try alloc.dupe(u8, text);
    if (source.generation_id) |id| result.completed.response_id = try alloc.dupe(u8, id);
    if (source.provider_state_json) |data| result.completed.continuation = try alloc.dupe(u8, data);
    if (source.finish_reason) |reason| result.completed.finish_reason = switch (reason) {
        .stop => .stop,
        .tool_calls => .tool_calls,
        .length => .length,
        .content_filter => .content_filter,
        else => return error.InvalidFinishReason,
    };
    var calls: std.ArrayList(models.ToolCall) = .empty;
    errdefer {
        for (calls.items) |call| {
            alloc.free(call.id);
            alloc.free(call.name);
            alloc.free(call.arguments_json);
        }
        calls.deinit(alloc);
    }
    for (source.tool_calls) |call| {
        const id = try alloc.dupe(u8, call.id);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, call.name);
        errdefer alloc.free(name);
        const arguments = try alloc.dupe(u8, call.arguments_json);
        errdefer alloc.free(arguments);
        try calls.append(alloc, .{ .id = id, .name = name, .arguments_json = arguments });
    }
    result.completed.tool_calls = try calls.toOwnedSlice(alloc);
    return result;
}

fn expired(deadline: std.Io.Clock.Timestamp) bool {
    return !std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io.getIo(), .awake), .lt, deadline);
}

fn phase_deadline(milliseconds: i64, caller: ?std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    const phase = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(milliseconds) });
    if (caller) |deadline| if (std.Io.Clock.Timestamp.compare(deadline, .lt, phase)) return deadline;
    return phase;
}

fn post(alloc: Allocator, self: *OpenAICompatibleModelProvider, request: models.ChatRequest, token: ?[]const u8, payload: []const u8) !models.ChatStream {
    const url = try std.mem.concat(alloc, u8, &.{ self.base_url, "/chat/completions" });
    defer alloc.free(url);
    const authorization = if (token) |value| try std.fmt.allocPrint(alloc, "Bearer {s}", .{value}) else null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    var client: std.http.Client = .{ .allocator = alloc, .io = io.getIo() };
    defer client.deinit();
    var uri = try std.Uri.parse(url);
    uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) "http" else return error.UnsupportedUriScheme;
    var operation = client_mod.PostOperation{
        .client = &client,
        .uri = uri,
        .authorization = authorization,
        .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
    };
    try request.admission.admit();
    var opened = try client_mod.openBoundedPost(alloc, request.cancel_flag, phase_deadline(30_000, request.deadline), &operation);
    defer opened.deinit(alloc);
    const http = &opened.request.?;
    var watch: client_mod.CancelWatch = .{};
    defer watch.stop();
    const head_deadline = phase_deadline(120_000, request.deadline);
    if (http.connection) |connection| try watch.start(request.cancel_flag, head_deadline, connection.stream_writer.stream);
    http.transfer_encoding = .{ .content_length = payload.len };
    var buffer: [8192]u8 = undefined;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    request.delivery.possibly_sent.store(true, .seq_cst);
    var body = try http.sendBodyUnflushed(&buffer);
    try body.writer.writeAll(payload);
    try body.end();
    if (http.connection) |connection| try connection.flush();
    var response = http.receiveHead(&.{}) catch |err| {
        if (expired(head_deadline)) return error.Timeout;
        return err;
    };
    watch.stop();
    if (http.connection) |connection| try watch.start(request.cancel_flag, if (response.head.status == .ok) request.deadline else phase_deadline(30_000, request.deadline), connection.stream_writer.stream);
    var retry_after: ?u64 = null;
    var headers = response.head.iterateHeaders();
    while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
        retry_after = std.fmt.parseUnsigned(u64, std.mem.trim(u8, header.value, " \t"), 10) catch null;
        break;
    };
    var transfer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    if (response.head.status != .ok) {
        var detail = reader.allocRemaining(alloc, .limited(64 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "Provider error response exceeded the local limit"),
            else => return err,
        };
        errdefer alloc.free(detail);
        if (token) |value| {
            const redacted = try codec.redact_error_detail(alloc, detail, value);
            alloc.free(detail);
            detail = redacted;
        }

        return .{ .failed = .{
            .kind = switch (response.head.status) {
                .bad_request => .invalid_request,
                .unauthorized => .unauthorized,
                .forbidden => .forbidden,
                .payload_too_large => .request_too_large,
                .too_many_requests => .rate_limited,
                .internal_server_error => .server_error,
                .bad_gateway => .bad_gateway,
                .service_unavailable => .unavailable,
                .gateway_timeout => .gateway_timeout,
                else => .provider_error,
            },
            .detail = detail,
            .retry_after_seconds = retry_after,
        } };
    }
    var limits: codec.Limits = .{ .accept_stop_with_tool_calls = self.finish_reason_mode == .accept_stop_with_tool_calls };
    if (request.max_content_bytes) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return consume(alloc, reader, self.model, request, limits);
}

test "OpenAICompatibleModelProvider accepts arbitrary local configuration with optional environment auth" {
    var local = try OpenAICompatibleModelProvider.init("local-config", "http://localhost:8080/v1/", "arbitrary/model:name", null);
    try std.testing.expectEqualStrings("http://localhost:8080/v1", local.base_url);
    try std.testing.expect(local.api_key_env == null);
    try std.testing.expect(local.provider().capabilities().tool_calls);
    var remote = try OpenAICompatibleModelProvider.init("remote-config", "https://example.com/v1", "arbitrary-model", "MODEL_API_KEY");
    try std.testing.expectEqualStrings("MODEL_API_KEY", remote.api_key_env.?);
    try std.testing.expectEqualStrings("remote-config", remote.provider().id);
    try std.testing.expectError(error.InsecureBaseUrl, OpenAICompatibleModelProvider.init("bad", "http://example.com/v1", "model", null));
}

test "OpenAICompatibleModelProvider serializes neutral chat and tool definitions" {
    const alloc = std.testing.allocator;
    var provider = try OpenAICompatibleModelProvider.init("config", "http://localhost:8080/v1", "anything:local", null);
    var cancelled: std.atomic.Value(bool) = .init(false);
    var delivery: models.Delivery = .{};
    var schema = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
    , .{});
    defer schema.deinit();
    const body = try provider.build(alloc, .{
        .messages = &.{ .{ .role = .system, .content = "instructions" }, .{ .role = .user, .content = "Read the file" } },
        .tools = &.{.{ .name = "read_file", .description = "Read a file", .input_schema = schema.value }},
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    });
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("anything:local", parsed.value.object.get("model").?.string);
    try std.testing.expect(parsed.value.object.get("stream").?.bool);
    try std.testing.expectEqualStrings("read_file", parsed.value.object.get("tools").?.array.items[0].object.get("function").?.object.get("name").?.string);
    cancelled.store(true, .seq_cst);
    try std.testing.expectError(error.Cancelled, provider.provider().chat(alloc, .{ .messages = &.{}, .cancel_flag = &cancelled, .delivery = &delivery }));
}
