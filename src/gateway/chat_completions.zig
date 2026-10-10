const std = @import("std");
const codec = @import("chat_completions_protocol.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const model_catalog_metadata = @import("../core/gateway/model_catalog_metadata.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const gateway_step = @import("../core/agent/runtime/gateway_step.zig");
const review_messages = @import("vercel_protocol.zig");
const types = @import("../core/shared/types.zig");
const model_provider = @import("../core/config/model_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const Allocator = std.mem.Allocator;

/// Every callback borrows the immutable definition from the owning profile runtime.
pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build, .project_replay_fn = project_replay },
        .model_catalog = .{ .context = context, .fetch_fn = fetch_catalog, .lookup_capabilities_fn = lookup_capabilities, .provider_id = bound_identity(definition) },
        .cli_model_catalog = .{ .context = context, .fetch_fn = fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

fn bound_identity(definition: *const definitions.Definition) model_provider.ProviderId {
    var identity = model_provider.parse(definition.id).?;
    identity.configured.binding = definition.binding_identity();
    return identity;
}

fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) ![]u8 {
    const definition = definition_at(raw);
    const identity = bound_identity(definition);
    for (request.messages) |message| if (message.provider_replay) |replay| {
        if (!replay.matches(.{ .provider = identity, .model = request.model })) {
            debug_trace.logf("gateway", "provider_replay_omitted reason=source_mismatch", .{});
            break;
        }
    };
    return codec.build_request(alloc, request, .{
        .tool_choice_mode = definition.tool_choice_mode,
        .tool_schema_mode = definition.tool_schema_mode,
        .provider = &identity,
    });
}

fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, text: bool, reasoning: bool) !?types.ProviderReplay {
    const selected = try codec.project_replay(alloc, replay, calls, text, reasoning);
    if (replay != null and selected == null) debug_trace.logf("gateway", "provider_replay_omitted reason={s}", .{if (reasoning) "associated_calls_removed" else "reasoning_removed"});
    return selected;
}

test "chat completions adapter binds replay to endpoint authority and wires projection" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"}}}
    );
    defer registry.deinit(alloc);
    var changed_registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:5678/v1","auth":{"type":"none"}}}
    );
    defer changed_registry.deinit(alloc);
    const definition = registry.get("local").?;
    const adapter = bundle(definition).agent_stream.?;
    const replay: types.ProviderReplay = .{
        .source = .{ .provider = bundle(definition).model_catalog.?.provider_id, .model = "model" },
        .parts_json = "{\"reasoning_details\":[{\"signature\":\"signed\"}],\"_tool_call_ids\":[]}",
    };
    const selected = (try adapter.projectReplay(alloc, replay, &.{}, false, true)).?;
    try std.testing.expect(selected.parts_json.ptr == replay.parts_json.ptr);
    try std.testing.expect(try adapter.projectReplay(alloc, replay, &.{}, true, false) == null);
    const request: streams.RequestData = .{
        .model = "model",
        .instructions = &.{.{ .role = .system, .content = "instructions" }},
        .messages = &.{.{ .role = .assistant, .content = "answer", .provider_replay = replay }},
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const matching = try adapter.build_request_fn.?(adapter.context, alloc, request);
    defer alloc.free(matching);
    try std.testing.expect(std.mem.find(u8, matching, "reasoning_details") != null);
    const other = bundle(changed_registry.get("local").?).agent_stream.?;
    const stripped = try other.build_request_fn.?(other.context, alloc, request);
    defer alloc.free(stripped);
    try std.testing.expect(std.mem.find(u8, stripped, "reasoning_details") == null);
    try std.testing.expect(request.messages[0].provider_replay.?.parts_json.ptr == replay.parts_json.ptr);
}

test "configured provider projects only the full shell schema when opted in" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"default":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"}},
        \\"compat":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"},"tool_schema_mode":"flatten_unions"}}
    );
    defer registry.deinit(alloc);
    const request: streams.RequestData = .{
        .model = "model",
        .messages = &.{.{ .role = .user, .content = "run pwd" }},
        .tools = .{
            .advertised_names = &.{"shell"},
            .advertised_functions = &.{@import("../builtins/tools.zig").shell.model_schema},
        },
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const canonical_adapter = bundle(registry.get("default").?).agent_stream.?;
    const canonical = try canonical_adapter.build_request_fn.?(canonical_adapter.context, alloc, request);
    defer alloc.free(canonical);
    try std.testing.expect(std.mem.find(u8, canonical, "\"oneOf\"") != null);

    const compatible_adapter = bundle(registry.get("compat").?).agent_stream.?;
    const compatible = try compatible_adapter.build_request_fn.?(compatible_adapter.context, alloc, request);
    defer alloc.free(compatible);
    try std.testing.expect(std.mem.find(u8, compatible, "\"oneOf\"") == null);
    try std.testing.expect(std.mem.find(u8, compatible, "\"enum\":[\"run\",\"interact\",\"stop\"]") != null);
}

const discipline_fixture = struct {
    const observation_discipline = @import("../core/agent/runtime/observation_discipline.zig");

    fn lookup(_: ?*const anyopaque, name: []const u8) ?observation_discipline.ReuseContract {
        if (std.mem.eql(u8, name, "read_file")) return .{ .permits_reuse = true, .mutates_state = false };
        return null;
    }
    const contracts: observation_discipline.ContractSource = .{ .lookup_fn = lookup };

    const body = "line of file content that the model needs to see once\n" ** 80;

    /// `reads` identical read_file results, optionally followed by a state change and another read.
    fn messages(alloc: Allocator, reads: usize, change_state: bool) ![]types.ChatMessage {
        var list: std.ArrayList(types.ChatMessage) = .empty;
        try list.append(alloc, .{ .role = .user, .content = "inspect the file" });
        const total = reads + @intFromBool(change_state);
        for (0..total) |n| {
            const id = try std.fmt.allocPrint(alloc, "call-{d}", .{n});
            const calls = try alloc.alloc(types.ToolCall, 1);
            const write_step = change_state and n == reads;
            calls[0] = .{ .id = id, .name = if (write_step) "shell" else "read_file", .arguments_json = if (write_step) "{\"request\":{\"action\":\"run\",\"command\":\"echo x > a.txt\"}}" else "{\"path\":\"a.txt\"}" };
            try list.append(alloc, .{ .role = .assistant, .tool_calls = calls });
            try list.append(alloc, .{
                .role = .tool,
                .content = if (write_step) "{\"exit_code\":0}" else body,
                .tool_call_id = id,
                .tool_name = calls[0].name,
                .tool_result_status = .success,
            });
        }
        return list.items;
    }

    fn serialize(alloc: Allocator, conversation: []const types.ChatMessage) ![]u8 {
        const functions = [_]@import("../core/tooling/model_tool_schema.zig").FunctionSchema{
            @import("../builtins/tools.zig").read_file.model_schema,
            @import("../builtins/tools.zig").shell.model_schema,
        };
        return codec.build_request(alloc, .{
            .model = "model",
            .messages = conversation,
            .tools = .{ .advertised_names = &.{ "read_file", "shell" }, .advertised_functions = &functions },
            .tool_choice = .auto,
            .provider_options = .{},
        }, .{});
    }
};

test "context projection experiment: serialized bytes with and without reuse on repeated reads" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const od = discipline_fixture.observation_discipline;

    const conversation = try discipline_fixture.messages(a, 6, false);
    const baseline = try od.project(a, conversation, discipline_fixture.contracts, false);
    const projected = try od.project(a, conversation, discipline_fixture.contracts, true);
    const baseline_wire = try discipline_fixture.serialize(a, baseline.messages);
    const projected_wire = try discipline_fixture.serialize(a, projected.messages);

    // Reuse disabled: the exact same messages, so the exact same request.
    try std.testing.expect(baseline.messages.ptr == conversation.ptr);
    try std.testing.expectEqual(@as(usize, 5), baseline.stats.repeated);
    try std.testing.expectEqual(@as(usize, 0), baseline.stats.omitted);
    // Reuse enabled: five earlier copies become references, one full copy stays.
    try std.testing.expectEqual(@as(usize, 5), projected.stats.omitted);
    try std.testing.expectEqual(conversation.len, projected.messages.len);
    try std.testing.expect(projected_wire.len < baseline_wire.len);
    // The retained copy is the newest one, so the evidence is still available.
    try std.testing.expectEqualStrings(discipline_fixture.body, projected.messages[projected.messages.len - 1].content.?);
    try std.testing.expect(std.mem.find(u8, projected_wire, "identical to the result of tool call call-5") != null);
    // Every call still has exactly one result with the same id and order.
    for (conversation, projected.messages) |before, after| {
        try std.testing.expectEqual(before.role, after.role);
        try std.testing.expectEqualStrings(before.tool_call_id orelse "", after.tool_call_id orelse "");
    }
    std.debug.print(
        "\ncontext experiment (repeated reads): messages {d} -> {d}, serialized request bytes {d} -> {d}, omitted {d}, denied {d}\n",
        .{ baseline.messages.len, projected.messages.len, baseline_wire.len, projected_wire.len, projected.stats.omitted, projected.stats.denied },
    );
}

test "context projection experiment: a state change after the reads keeps every copy" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const od = discipline_fixture.observation_discipline;

    const conversation = try discipline_fixture.messages(a, 6, true);
    const projected = try od.project(a, conversation, discipline_fixture.contracts, true);
    try std.testing.expectEqual(@as(usize, 0), projected.stats.omitted);
    try std.testing.expect(projected.messages.ptr == conversation.ptr);
    const baseline_wire = try discipline_fixture.serialize(a, conversation);
    const projected_wire = try discipline_fixture.serialize(a, projected.messages);
    try std.testing.expectEqualStrings(baseline_wire, projected_wire);
}

test "serialized request bytes reported by the adapter match the body it builds" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const conversation = try discipline_fixture.messages(a, 2, false);
    const wire = try discipline_fixture.serialize(a, conversation);
    var evidence: streams.AttemptEvidence = .{};
    evidence.serialized_request_bytes = wire.len;
    var meter: @import("../core/agent/runtime/context_meter.zig").ContextMeter = .{};
    evidence.provider_admitted = true;
    meter.recordModelCall(evidence, .{ .input_tokens = 321, .output_tokens = 9 }, conversation.len);
    try std.testing.expectEqual(@as(u64, wire.len), meter.serialized_request_bytes);
    // Provider tokens are separate from bytes.
    try std.testing.expectEqual(@as(?u64, 321), meter.provider_input_tokens);
    try std.testing.expect(meter.serialized_request_bytes != 321);
}

test "only a provider that can execute search keeps the provider-executed web-search tool" {
    var registry = try definitions.Registry.parse_json(std.testing.allocator,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"}}}
    );
    defer registry.deinit(std.testing.allocator);
    const configured = bundle(registry.get("local").?);
    const gateway = @import("../builtins/gateway.zig").provider_bundle;
    // These flags are the capability source for both tool projection and the web-search backend.
    try std.testing.expect(!configured.capabilities.fx_search);
    try std.testing.expect(gateway.capabilities.fx_search);
    try std.testing.expectEqual(configured.agentFeatures().native_search, configured.capabilities.fx_search);
    try std.testing.expectEqual(gateway.agentFeatures().native_search, gateway.capabilities.fx_search);
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) !streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    if (request.credential.credentialSource() != .configured) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    if (token) |value| {
        if (value.len > 16 * 1024) return error.InvalidConfiguredProviderCredential;
        for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidConfiguredProviderCredential;
    }
    switch (definition.auth) {
        .none => if (token != null) return error.UnexpectedConfiguredProviderCredential,
        .bearer => if (token == null) return error.MissingConfiguredProviderCredential,
    }
    const payload = request.prepared_request_body orelse try build(raw, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    request.attempt_evidence.serialized_request_bytes = payload.len;
    return @import("legacy_model_provider.zig").chat(alloc, definition, request, payload);
}

/// The returned entry borrows its strings; fetch_catalog replaces them with owned copies.
fn metadata_entry(metadata: definitions.ModelMetadata) catalog.ModelCatalogEntry {
    const vision = metadata.supports_vision orelse false;
    return .{
        .id = @constCast(metadata.id),
        .model_type = @constCast("language"),
        .has_tool_use = metadata.supports_tool_use orelse false,
        // Chat completions sends images as inline base64 content parts, so
        // vision support implies file input through the same path.
        .has_vision = vision,
        .has_file_input = vision,
        .context_window = metadata.context_window orelse 0,
        .max_tokens = metadata.max_output_tokens orelse 0,
    };
}

fn lookup_capabilities(raw: ?*anyopaque, model: []const u8) model_capabilities.Capabilities {
    const metadata = definition_at(raw).model(model) orelse return .{};
    return model_capabilities.mergeCapabilities(.{}, model_catalog_metadata.fromCatalogEntry(metadata_entry(metadata.*)));
}

fn fetch_catalog(raw: ?*anyopaque, alloc: Allocator, input: catalog.FetchInput) Allocator.Error!catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    const definition = definition_at(raw);
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    errdefer catalog.freeModelCatalog(alloc, &entries);
    for (definition.model_metadata) |metadata| {
        var entry = metadata_entry(metadata);
        entry.id = try alloc.dupe(u8, entry.id);
        errdefer alloc.free(entry.id);
        entry.model_type = try alloc.dupe(u8, entry.model_type);
        errdefer alloc.free(entry.model_type);
        try entries.append(alloc, entry);
    }
    return .{ .catalog = entries };
}

test "configured capability lookup matches catalog projection and preserves unknowns" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"},"model_metadata":{"small":{"context_window":8192,"max_output_tokens":512,"supports_tool_use":true,"supports_vision":true},"large":{"context_window":32768,"max_output_tokens":1024,"supports_tool_use":false},"partial":{"max_output_tokens":128},"unknown":{}}}}
    );
    defer registry.deinit(alloc);
    const provider = bundle(registry.get("local").?).model_catalog.?;
    var fetched = try provider.fetch(alloc, .{ .endpoint = "unused" });
    defer catalog.freeModelCatalog(alloc, &fetched.catalog);
    for (fetched.catalog.items) |entry| {
        const actual = provider.lookupCapabilities(entry.id).?;
        try std.testing.expectEqualDeep(model_capabilities.mergeCapabilities(.{}, model_catalog_metadata.fromCatalogEntry(entry)), actual);
        const declared_vision = std.mem.eql(u8, entry.id, "small");
        try std.testing.expectEqual(declared_vision, actual.supports_vision);
        try std.testing.expectEqual(
            if (declared_vision) model_capabilities.ImageInputSupport.native else model_capabilities.ImageInputSupport.non_native,
            actual.image_input_support,
        );
    }
    try std.testing.expectEqual(@as(?u32, 512), provider.lookupCapabilities("small").?.max_output_tokens);
    try std.testing.expectEqual(@as(?u32, 1024), provider.lookupCapabilities("large").?.max_output_tokens);
    try std.testing.expect(provider.lookupCapabilities("partial").?.context_window == null);
    try std.testing.expect(provider.lookupCapabilities("unknown").?.max_output_tokens == null);
    try std.testing.expectEqualDeep(model_capabilities.Capabilities{}, provider.lookupCapabilities("missing-fast").?);
}

fn fetch_cli_catalog(raw: ?*anyopaque, alloc: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    const provenance = catalog.Provenance{ .access = catalog.AccessMetadata.init(input.access) };
    const result = fetch_catalog(raw, alloc, .{ .access = input.access, .endpoint = input.endpoint, .cancel_flag = input.cancel_flag }) catch
        return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
    switch (result) {
        .failure => |failure| return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = failure } },
        .catalog => |value| {
            var entries = value;
            defer catalog.freeModelCatalog(alloc, &entries);
            const ids = catalog.projectModelIds(alloc, entries.items) catch return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
            return .{ .loaded = .{ .ids = ids, .provenance = provenance } };
        },
    }
}

const Review = struct { definition: *const definitions.Definition, input: classifier.ProviderInput };
fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) !classifier.ParseOutcome {
    var state = Review{ .definition = definition_at(raw), .input = input };
    return classifier.Reviewer.withTransportModel(.{ .context = &state, .build_fn = build_review, .send_fn = send_review }, input.cancel_flag, classifier.Reviewer.default_timeout_ms, state.definition.reviewer_model orelse request.review_turn.model).review(alloc, request);
}
fn build_review(raw: *anyopaque, alloc: Allocator, model: []const u8, _: []const u8, instructions: []const types.ChatMessage, messages: []const types.ChatMessage, target_id: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) ![]u8 {
    const state: *Review = @ptrCast(@alignCast(raw));
    const expanded = try review_messages.expandPendingToolReviewMessages(alloc, messages, target_id, deadline, cancel);
    defer alloc.free(expanded);
    const output_limit = if (state.definition.model(model)) |metadata| @min(metadata.max_output_tokens orelse 2048, 2048) else 2048;
    return build(@ptrCast(@constCast(state.definition)), alloc, .{ .model = model, .instructions = instructions, .messages = expanded, .tools = .{ .additional_functions = &.{classifier.function_schema} }, .tool_choice = .required, .provider_options = .{}, .max_output_tokens = output_limit });
}
fn ignore_event(_: *anyopaque, _: streams.Event) void {}
fn free_result(raw: *anyopaque, alloc: Allocator) void {
    const result: *streams.Result = @ptrCast(@alignCast(raw));
    result.deinit(alloc);
    alloc.destroy(result);
}
fn send_review(raw: *anyopaque, alloc: Allocator, model: []const u8, payload: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) !classifier.TransportOutcome {
    const state: *Review = @ptrCast(@alignCast(raw));
    var delivery: streams.DeliveryCertainty = .init();
    var evidence: streams.AttemptEvidence = .{};
    var event_context: u8 = 0;
    var result = gateway_step.streamModelCompletion(bundle(state.definition).agent_stream.?, alloc, .{
        .credential = .{ .direct = .{ .secret_bytes = state.input.credential, .source = state.input.credential_source } },
        .model = model,
        .retry_count = 1,
        .messages = &.{},
        .tools = .{ .additional_functions = &.{classifier.function_schema} },
        .tool_choice = .required,
        .provider_options = .{},
        .prepared_request_body = payload,
        .trace_ctx = .{},
        .content_capture_limit = 16 * 1024,
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &event_context, .emit_fn = ignore_event },
        .cancel_flag = cancel,
    }, state.input.usage, state.input.usage_allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return .cancelled,
        error.Timeout => return .timed_out,
        error.RequiredToolMissing => return .{ .completion = .{ .completion = .{} } },
        else => return .permanent_failure,
    };
    errdefer result.deinit(alloc);
    if (result == .failed) {
        result.deinit(alloc);
        return .permanent_failure;
    }
    const owned = try alloc.create(streams.Result);
    owned.* = result;
    return .{ .completion = .{ .completion = owned.completed.completion, .context = owned, .deinit_fn = free_result } };
}
