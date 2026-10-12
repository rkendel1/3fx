const std = @import("std");
const models = @import("../core/agent/model_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const native = @import("openai_compatible_model_provider.zig");
const definitions = @import("../core/config/configured_provider.zig");
const client = @import("client.zig");
const malformed_tool_call = @import("malformed_tool_call.zig");

const Allocator = std.mem.Allocator;

/// Transitional host bridge. All legacy request/result conversion lives here,
/// never in the canonical contract. The reference adapter does not consume the
/// legacy request's authorization lease or any usage-reconciliation reference.
pub fn chat(
    alloc: Allocator,
    definition: *const definitions.Definition,
    request: streams.ModelRequest,
    payload: []const u8,
) !streams.Result {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, payload, .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    // The exact legacy serializer owns multimodal and continuation projection.
    // Reconstruct only advertised tool definitions for stream validation.
    var tools: std.ArrayList(models.Tool) = .empty;
    if (parsed.value.object.get("tools")) |value| {
        for (value.array.items) |tool| {
            const function = tool.object.get("function").?.object;
            try tools.append(arena, .{
                .name = function.get("name").?.string,
                .description = if (function.get("description")) |description| description.string else "",
                .input_schema = function.get("parameters").?,
            });
        }
    }
    var adapter = try native.OpenAICompatibleModelProvider.init(definition.id, definition.base_url, request.model, switch (definition.auth) {
        .none => null,
        .bearer => |env| env,
    });
    adapter.tool_choice_mode = definition.tool_choice_mode;
    adapter.tool_schema_mode = definition.tool_schema_mode;
    adapter.finish_reason_mode = definition.finish_reason_mode;
    var events: Events = .{ .sink = request.events };
    var delivery: models.Delivery = .{};
    defer if (delivery.possibly_sent.load(.seq_cst)) request.delivery.markPossiblySent();
    var result = @import("../core/agent/runtime/model_step.zig").chat(adapter.provider(), arena, .{
        .messages = &.{},
        .tools = tools.items,
        .tool_choice = switch (request.tool_choice) {
            .auto => .auto,
            .none => .none,
            .required => .required,
        },
        .prepared_body = payload,
        .max_output_tokens = request.max_output_tokens,
        .max_content_bytes = request.content_capture_limit,
        .events = .{ .context = &events, .emit_fn = Events.emit },
        .cancel_flag = request.cancel_flag,
        .deadline = request.deadline,
        .admission = .{ .context = @constCast(&request.admission), .admit_fn = admit },
        .delivery = &delivery,
    }) catch |err| {
        const certainty: streams.DeliveryCertainty.State = if (delivery.possibly_sent.load(.seq_cst)) .possibly_sent else .definitely_unsent;
        request.attempt_evidence.network_failure = client.networkFailureEvidence(err, certainty);
        return err;
    };
    defer result.deinit(arena);
    return switch (result) {
        .failed => |failure| try (streams.Result{ .failed = .{
            .kind = @enumFromInt(@intFromEnum(failure.kind)),
            .detail = if (failure.detail) |text| @constCast(text) else null,
            .retry_after_seconds = failure.retry_after_seconds,
        } }).dupe(alloc),
        .completed => |completion| completed: {
            const calls = try arena.alloc(types.ToolCall, completion.tool_calls.len);
            for (completion.tool_calls, 0..) |call, i| calls[i] = .{ .id = call.id, .name = call.name, .arguments_json = call.arguments_json };
            const malformed = try malformedToolCallDetail(arena, completion, tools.items, request.tool_choice != .none);
            break :completed try (streams.Result{ .completed = .{
                .completion = .{
                    .content = completion.content,
                    .tool_calls = calls,
                    .generation_id = completion.response_id,
                    .provider_state_json = completion.continuation,
                    .finish_reason = if (malformed != null) .provider_error else if (completion.finish_reason) |reason| switch (reason) {
                        .stop => .stop,
                        .tool_calls => .tool_calls,
                        .length => .length,
                        .content_filter => .content_filter,
                    } else null,
                    .provider_failure_cause = if (malformed != null) .malformed_tool_call else null,
                    .provider_failure_detail = malformed,
                    .usage = .{
                        .input_tokens = completion.usage.input_tokens,
                        .output_tokens = completion.usage.output_tokens,
                        .cache_read_tokens = completion.usage.cache_read_tokens,
                        .cache_write_tokens = completion.usage.cache_write_tokens,
                        .reasoning_tokens = completion.usage.reasoning_tokens,
                    },
                },
                .usage = .{ .unavailable = .possibly_billed },
            } }).dupe(alloc);
        },
    };
}

/// A normal stop with advertised tools and no structured calls whose text is a
/// textual tool call is a failed tool interaction, not a final answer. The text
/// is never parsed into a call; the original content stays on the completion for
/// diagnosis. Returns an arena-owned failure detail, or null for any other turn.
fn malformedToolCallDetail(
    arena: Allocator,
    completion: models.Completion,
    advertised: []const models.Tool,
    tools_allowed: bool,
) Allocator.Error!?[]const u8 {
    const name = malformed_tool_call.inCompletion(completion, advertised, tools_allowed) orelse return null;
    return try std.fmt.allocPrint(arena, "malformed_tool_call: model wrote a call to {s} as plain text instead of a structured tool call; nothing was executed", .{name});
}

fn admit(raw: *anyopaque) !void {
    const admission: *const streams.Admission = @ptrCast(@alignCast(raw));
    try admission.admit();
}

const Events = struct {
    sink: streams.EventSink,

    fn emit(raw: *anyopaque, event: models.Event) void {
        const self: *Events = @ptrCast(@alignCast(raw));
        self.sink.emit(switch (event) {
            .content_delta => |text| .{ .content_delta = text },
            .reasoning_delta => |text| .{ .reasoning_delta = text },
        });
    }
};

const test_tools = [_]models.Tool{
    .{ .name = "shell", .description = "", .input_schema = .null },
    .{ .name = "read_file", .description = "", .input_schema = .null },
};
const test_markup = "I'll check.\n\n<function=shell>\n<parameter=request>\n{\"action\": \"run\", \"command\": \"git branch --show-current\"}\n</parameter>\n</function>\n</tool_call>";

test "a stop turn with advertised tools and textual tool-call markup is a malformed tool call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const detail = try malformedToolCallDetail(arena.allocator(), .{ .content = test_markup, .finish_reason = .stop }, &test_tools, true);
    try std.testing.expect(std.mem.startsWith(u8, detail.?, "malformed_tool_call: "));
    try std.testing.expect(std.mem.find(u8, detail.?, "nothing was executed") != null);
    // The diagnostic names the tool only; no argument text from the response is copied.
    try std.testing.expect(std.mem.find(u8, detail.?, "git branch") == null);
}

test "structured calls, prose, code examples, and unadvertised or disabled tools are not malformed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const call = [_]models.ToolCall{.{ .id = "c1", .name = "shell", .arguments_json = "{}" }};
    // A valid structured call keeps its existing meaning, even with stray markup in the text.
    try std.testing.expect(try malformedToolCallDetail(a, .{ .content = test_markup, .tool_calls = &call, .finish_reason = .tool_calls }, &test_tools, true) == null);
    try std.testing.expect(try malformedToolCallDetail(a, .{ .content = test_markup, .tool_calls = &call, .finish_reason = .stop }, &test_tools, true) == null);
    // Ordinary prose and fenced examples remain valid final answers.
    try std.testing.expect(try malformedToolCallDetail(a, .{ .content = "Tools are called with a <function=shell> tag.", .finish_reason = .stop }, &test_tools, true) == null);
    try std.testing.expect(try malformedToolCallDetail(a, .{ .content = "Example:\n```\n" ++ test_markup ++ "\n```", .finish_reason = .stop }, &test_tools, true) == null);
    try std.testing.expect(try malformedToolCallDetail(a, .{ .content = null, .finish_reason = .stop }, &test_tools, true) == null);
    // Only a normal stop with tools in play is classified.
    try std.testing.expect(try malformedToolCallDetail(a, .{ .content = test_markup, .finish_reason = .length }, &test_tools, true) == null);
    try std.testing.expect(try malformedToolCallDetail(a, .{ .content = test_markup, .finish_reason = .stop }, &test_tools, false) == null);
    try std.testing.expect(try malformedToolCallDetail(a, .{ .content = test_markup, .finish_reason = .stop }, &.{}, true) == null);
    try std.testing.expect(try malformedToolCallDetail(a, .{ .content = "<function=other>\n<parameter=x>1</parameter>\n</function>", .finish_reason = .stop }, &test_tools, true) == null);
}
