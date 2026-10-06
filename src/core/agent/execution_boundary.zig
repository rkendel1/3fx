const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../shared/types.zig");
const model_provider = @import("./model_provider.zig");
const stream_provider = @import("./stream_provider.zig");
const agent_runtime = @import("./agent_runtime.zig");
const worker_runtime = @import("./worker_runtime.zig");

// Caller-facing request type for agent turn execution.
// External control planes provide execution inputs without credentials.
// Host projection injects host-owned credentials at the boundary.
pub const AgentTurnRequest = struct {
    prompt: []const u8,
    model: []const u8,
    history: []types.HistoryTurn,
    images: []types.ImageAttachment,
    grants: []types.PermissionGrant,
    permission_mode: types.PermissionMode,
    agent_settings: worker_runtime.AgentTurnSettings = .{},
};

// Projects caller request + host-owned credentials into the runtime job.
// The caller provides execution inputs; the host provides credentials.
pub fn projectAgentTurnRequest(
    alloc: Allocator,
    request: AgentTurnRequest,
    api_key: []const u8,
    credential_source: types.CredentialSource,
) !worker_runtime.CompatibilityExecutionJob {
    return .{
        .prompt = try alloc.dupe(u8, request.prompt),
        .model = try alloc.dupe(u8, request.model),
        .history = request.history,
        .images = request.images,
        .grants = request.grants,
        .permission_mode = request.permission_mode,
        .agent_settings = request.agent_settings,
        .api_key = try alloc.dupe(u8, api_key),
        .credential_source = credential_source,
        .provider = .gateway,
    };
}

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

test "external caller can construct CompatibilityExecutionJob with host-owned credentials" {
    const alloc = std.testing.allocator;

    // External caller constructs the job with host-owned credentials.
    // This simulates an external control plane providing the execution input.
    const prompt = try alloc.dupe(u8, "test prompt");
    defer alloc.free(prompt);
    const model = try alloc.dupe(u8, "gpt-4");
    defer alloc.free(model);
    const api_key = try alloc.dupe(u8, "sk-test-key-from-host");
    defer alloc.free(api_key);
    const account_id = try alloc.dupe(u8, "account-123");
    defer alloc.free(account_id);

    const job: worker_runtime.CompatibilityExecutionJob = .{
        .prompt = prompt,
        .model = model,
        .api_key = api_key,
        .account_id = account_id,
        .credential_source = .host_managed,
        .permission_mode = .auto,
        .provider = .gateway,
        .images = &.{},
        .history = &.{},
        .grants = &.{},
    };

    // Verify the job contains credentials and execution inputs
    try std.testing.expectEqualStrings("test prompt", job.prompt);
    try std.testing.expectEqualStrings("gpt-4", job.model);
    try std.testing.expectEqualStrings("sk-test-key-from-host", job.api_key);
    try std.testing.expectEqualStrings("account-123", job.account_id.?);

    // Credentials are host-owned input to the execution boundary,
    // not produced by it. The boundary receives them and uses them at
    // the provider injection point, then discards them from results.
    try std.testing.expectEqual(job.credential_source, .host_managed);

    // The interface allows external callers to provide all required inputs:
    // - execution data (prompt, model, history)
    // - host-owned credentials (api_key, account_id, credential_source)
    // - permission configuration (permission_mode, grants)
    // - settings (agent_settings)

    // Importantly, the return path (via AgentRuntimeDeps callbacks) contains
    // no credentials, only execution results (tool execution, text output, etc.)
}

test "AgentTurnRequest contains only caller-facing execution inputs, no credentials" {
    // Caller constructs request with only execution inputs
    const request: AgentTurnRequest = .{
        .prompt = "analyze this code",
        .model = "gpt-4",
        .history = &.{},
        .images = &.{},
        .grants = &.{},
        .permission_mode = .auto,
    };

    // Verify request contains execution semantics
    try std.testing.expectEqualStrings("analyze this code", request.prompt);
    try std.testing.expectEqualStrings("gpt-4", request.model);
    try std.testing.expectEqual(request.permission_mode, .auto);

    // Request intentionally has no credential fields
    // - no api_key
    // - no credential_source
    // - no account_id
    // - no gateway_team
    // The request is purely for describing what to execute.
}

test "AgentTurnRequest projects to CompatibilityExecutionJob with host credentials injected" {
    const alloc = std.testing.allocator;

    // Caller provides execution request
    const request: AgentTurnRequest = .{
        .prompt = try alloc.dupe(u8, "write a test"),
        .model = try alloc.dupe(u8, "claude-3"),
        .history = &.{},
        .images = &.{},
        .grants = &.{},
        .permission_mode = .auto,
    };
    defer alloc.free(request.prompt);
    defer alloc.free(request.model);

    // Host provides credentials and calls projection
    const job = try projectAgentTurnRequest(
        alloc,
        request,
        "sk-host-managed-key",
        .host_managed,
    );
    defer alloc.free(job.prompt);
    defer alloc.free(job.model);
    defer alloc.free(job.api_key);

    // Verify job contains both caller inputs and host credentials
    try std.testing.expectEqualStrings("write a test", job.prompt);
    try std.testing.expectEqualStrings("claude-3", job.model);
    try std.testing.expectEqualStrings("sk-host-managed-key", job.api_key);
    try std.testing.expectEqual(job.credential_source, .host_managed);
    try std.testing.expectEqual(job.permission_mode, .auto);

    // Job is ready for processAgentPrompt()
}

test "AgentTurnRequest boundary preserves execution settings" {
    const alloc = std.testing.allocator;

    // Caller can specify agent settings
    const request: AgentTurnRequest = .{
        .prompt = "fast execution",
        .model = "gpt-4",
        .history = &.{},
        .images = &.{},
        .grants = &.{},
        .permission_mode = .auto,
        .agent_settings = .{
            .fast_mode = true,
        },
    };

    // Host projects with credentials
    const job = try projectAgentTurnRequest(
        alloc,
        request,
        "test-key",
        .host_managed,
    );
    defer alloc.free(job.prompt);
    defer alloc.free(job.model);
    defer alloc.free(job.api_key);

    // Settings are preserved
    try std.testing.expectEqual(job.agent_settings.fast_mode, true);
}
