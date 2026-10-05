const Config = @import("../agent/runtime/config.zig").Config;
const ChatMessage = types.ChatMessage;
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const auto_classifier_context = @import("../permissions/auto_classifier_context.zig");
const std = @import("std");
const types = @import("../shared/types.zig");
const session_codec = @import("../session/session_codec.zig");
const auth_transition = @import("../auth/auth_transition.zig");
const credentials = @import("../auth/credentials.zig");
const credential_authority = @import("../auth/credential_authority.zig");
const secret = @import("../auth/secret.zig");
const host_target = @import("../hosts/target.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const AgentRuntimeDeps = @import("../agent/runtime/deps.zig").AgentRuntimeDeps;
const CredentialRefreshMode = @import("../agent/runtime/deps.zig").CredentialRefreshMode;
const CompatibilityExecutionJob = worker.CompatibilityExecutionJob;
const Allocator = std.mem.Allocator;
const TraceContext = debug_trace.TraceContext;

const worker = @import("../agent/worker_runtime.zig");
const submission = @import("../agent/submission.zig");
const turn_execution_input = @import("../agent/turn_execution_input.zig");

/// Transfers the captured host snapshot into the legacy execution shape.
/// No allocations, current-configuration reads, refreshes, or ownership copies.
/// Only the worker's execution handoff calls this conversion.
pub fn resolve(queued: submission.Submission, snapshot: worker.ExecutionSnapshot) worker.CompatibilityExecutionJob {
    return .{
        .turn_id = queued.turn_id,
        .prompt = queued.prompt,
        .delivery = queued.delivery,
        .steering_receipt = snapshot.steering_receipt,
        .images = snapshot.images,
        .authorized_image_catalog = snapshot.authorized_image_catalog,
        .model = snapshot.model,
        .provider = snapshot.provider,
        .api_key = snapshot.api_key,
        .gateway_team = snapshot.gateway_team,
        .credential_source = snapshot.credential_source,
        .account_id = snapshot.account_id,
        .permission_mode = snapshot.permission_mode,
        .history = snapshot.history,
        .unversioned_history_count = snapshot.unversioned_history_count,
        .root_user_intent_context = snapshot.root_user_intent_context,
        .grants = snapshot.grants,
        .skill_bindings = snapshot.skill_bindings,
        .skill_display_spans = snapshot.skill_display_spans,
        .context_snapshot = snapshot.context_snapshot,
        .agent_settings = snapshot.agent_settings,
        .snapshot_file_ownerships = snapshot.snapshot_file_ownerships,
        .recovery_checkpoint = snapshot.recovery_checkpoint,
        .recovery_source_already_presented = snapshot.recovery_source_already_presented,
        .user_prompt_already_presented = snapshot.user_prompt_already_presented,
    };
}

fn recoveryCredentialAuthorityMatches(
    checkpoint: session_codec.RecoveryCheckpoint,
    source: ?types.CredentialSource,
    account_id: ?[]const u8,
) bool {
    const expected_source = checkpoint.authority.credential_source orelse return false;
    const expected_identity = checkpoint.authority.credential_identity orelse return false;
    const current_source = source orelse return false;
    if (current_source != expected_source) return false;
    const current_identity = credential_authority.derive(
        current_source,
        account_id,
    ) orelse return false;
    return expected_identity.eql(current_identity);
}

fn shouldRejectRecoveryAuthority(
    checkpoint: session_codec.RecoveryCheckpoint,
    source: ?types.CredentialSource,
    account_id: ?[]const u8,
) bool {
    if (checkpoint.disposition == .history_only) return true;
    const provider_may_have_received_request = checkpoint.outstanding_reservation or
        checkpoint.consumed_provider_attempts > 0;
    return provider_may_have_received_request and !recoveryCredentialAuthorityMatches(
        checkpoint,
        source,
        account_id,
    );
}

test "potentially sent recovery rejects missing or changed credential authority" {
    const identity = credential_authority.derive(
        .chatgpt_subscription,
        "acct_1",
    ).?;
    const checkpoint = session_codec.RecoveryCheckpoint{
        .turn_id = 1,
        .user = .{ .text = @constCast("continue") },
        .assistant_source = @constCast("partial"),
        .cause = .response_interrupted,
        .action = .continuing_response,
        .authority = .{
            .provider = .codex,
            .model = @constCast("gpt-5.4"),
            .credential_source = .chatgpt_subscription,
            .credential_identity = identity,
        },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 3,
        .consumed_provider_attempts = 1,
    };
    try std.testing.expect(!shouldRejectRecoveryAuthority(
        checkpoint,
        .chatgpt_subscription,
        "acct_1",
    ));
    try std.testing.expect(shouldRejectRecoveryAuthority(
        checkpoint,
        .chatgpt_subscription,
        "acct_2",
    ));

    var legacy = checkpoint;
    legacy.authority.credential_source = null;
    legacy.authority.credential_identity = null;
    try std.testing.expect(shouldRejectRecoveryAuthority(
        legacy,
        .chatgpt_subscription,
        "acct_1",
    ));
    legacy.authority.credential_source = .ai_gateway_api_key;
    legacy.authority.credential_identity = credential_authority.derive(
        .ai_gateway_api_key,
        null,
    );
    try std.testing.expect(!shouldRejectRecoveryAuthority(
        legacy,
        .ai_gateway_api_key,
        null,
    ));
    try std.testing.expect(shouldRejectRecoveryAuthority(
        legacy,
        .stored_key,
        null,
    ));
    legacy.authority.credential_source = null;
    legacy.authority.credential_identity = null;
    legacy.consumed_provider_attempts = 0;
    try std.testing.expect(!shouldRejectRecoveryAuthority(
        legacy,
        .chatgpt_subscription,
        "acct_1",
    ));
    legacy.disposition = .history_only;
    try std.testing.expect(shouldRejectRecoveryAuthority(legacy, .chatgpt_subscription, "acct_1"));
    try std.testing.expect(shouldRejectRecoveryAuthority(legacy, null, null));
}

pub fn refreshCredential(
    deps: *const AgentRuntimeDeps,
    alloc: Allocator,
    job: CompatibilityExecutionJob,
    mode: CredentialRefreshMode,
    active_api_key: *[]const u8,
    owned_api_key: *?[]u8,
    trace_ctx: TraceContext,
) !bool {
    const source = job.credential_source orelse return false;
    if (!credentials.sourceRefreshable(source)) return false;
    const refresh = deps.refresh_gateway_credential orelse return false;

    const refreshed = refresh(deps.ctx, alloc, source, mode, job.account_id) catch |err| {
        if (err == error.OutOfMemory) return err;
        debug_trace.eventf(
            "gateway",
            "credential_refresh_failed",
            trace_ctx,
            "source={s} mode={s} err={s}",
            .{ @tagName(source), @tagName(mode), @errorName(err) },
        );
        return false;
    } orelse return false;
    const previous_api_key = active_api_key.*;
    if (comptime !host_target.is_wasm) {
        if (deps.usage) |usage| {
            if (source == .chatgpt_subscription or source == .grok_subscription) {
                usage.clearReconciliationCredential();
            } else {
                usage.refreshReconciliationCredential(
                    deps.usage_allocator,
                    previous_api_key,
                    refreshed,
                );
            }
        }
    }
    if (owned_api_key.*) |old| secret.zeroAndFree(alloc, old);
    owned_api_key.* = refreshed;
    active_api_key.* = refreshed;
    debug_trace.eventf(
        "gateway",
        "credential_refreshed",
        trace_ctx,
        "source={s} mode={s}",
        .{ @tagName(source), @tagName(mode) },
    );
    return true;
}

pub fn credentialLease(
    secret_value: []const u8,
    job: CompatibilityExecutionJob,
) types.CredentialLease {
    if (job.credential_source == .host_managed) return .host_managed;
    return .{ .direct = .{
        .secret_bytes = secret_value,
        .source = job.credential_source,
        .account_id = job.account_id,
        .tenant_context = job.gateway_team,
    } };
}

/// Explicit compatibility operations. These consume only the captured job
/// authority; callers coordinate retries without inspecting that authority.
pub fn initialSecret(job: CompatibilityExecutionJob) []const u8 {
    return job.api_key;
}

pub fn rejectRecovery(job: CompatibilityExecutionJob, checkpoint: session_codec.RecoveryCheckpoint) bool {
    return shouldRejectRecoveryAuthority(checkpoint, job.credential_source, job.account_id);
}

pub fn recoveryIdentity(job: CompatibilityExecutionJob) ?credential_authority.Identity {
    const source = job.credential_source orelse return null;
    return credential_authority.derive(source, job.account_id);
}

pub const ReplayFacts = struct {
    authentication_rejected: bool,
    delivery_safe: bool,
    already_replayed: bool,
};

pub fn replayDecision(job: CompatibilityExecutionJob, facts: ReplayFacts) auth_transition.AuthReplayDecision {
    return auth_transition.decideAuthReplay(.{
        .authentication_rejected = facts.authentication_rejected,
        .refreshable = if (job.credential_source) |source| credentials.sourceRefreshable(source) else false,
        .delivery_safe = facts.delivery_safe,
        .already_replayed = facts.already_replayed,
    });
}

pub fn replaceLeaseSecret(lease: *types.CredentialLease, value: []const u8) void {
    lease.direct.secret_bytes = value;
}

pub fn copyAuthorityForTurn(alloc: Allocator, job: CompatibilityExecutionJob) !CompatibilityExecutionJob {
    var copied = job;
    copied.account_id = if (job.account_id) |value| try alloc.dupe(u8, value) else null;
    errdefer if (copied.account_id) |value| alloc.free(value);
    copied.gateway_team = if (job.gateway_team) |value| try alloc.dupe(u8, value) else null;
    return copied;
}

pub fn releaseSecret(alloc: Allocator, value: []u8) void {
    secret.zeroAndFree(alloc, value);
}

pub fn recoveryAuthority(job: CompatibilityExecutionJob, model: []const u8) session_codec.TurnAuthority {
    return .{ .provider = job.provider, .model = @constCast(model), .credential_source = job.credential_source, .credential_identity = recoveryIdentity(job) };
}

pub fn validateRecovery(job: CompatibilityExecutionJob, checkpoint: session_codec.RecoveryCheckpoint) !void {
    if (rejectRecovery(job, checkpoint)) return error.RecoveryCredentialAuthorityChanged;
}

/// Only authorization fields are projected for the existing side-call adapter.
/// This does not alter its invocation, compaction policy, or lifetime.
pub fn configureSideCall(call: *@import("../agent/runtime/text_completion.zig").CompactorCaller, job: CompatibilityExecutionJob) void {
    call.credential_source = job.credential_source;
    call.account_id = job.account_id;
    call.gateway_team = job.gateway_team;
}

pub fn publishHttpError(deps: *const AgentRuntimeDeps, job: CompatibilityExecutionJob, status: std.http.Status, detail: []const u8) !void {
    try deps.push_http_error(deps.ctx, status, detail, job.credential_source);
}

pub fn buildReviewTurnContext(
    config: Config,
    model: []const u8,
    root_user_intent_context: []const u8,
    current_turn_messages: []const ChatMessage,
    pending_assistant: ChatMessage,
    authorization: types.CredentialLease,
    target_call_id: []const u8,
    review_attempt_available: bool,
) permission_auto_classifier.ReviewTurnContext {
    const trusted_root_context = auto_classifier_context.rootUserRequestContext(
        root_user_intent_context,
    ) orelse "";
    return .{
        .model = model,
        .pending_assistant = pending_assistant,
        .credential = authorization,
        .target_call_id = target_call_id,
        .review_attempt_available = review_attempt_available,
        .origin = switch (config.origin) {
            .root => .root,
            .subagent => .subagent,
        },
        .trusted_root_context = trusted_root_context,
        .current_turn_untrusted_messages = current_turn_messages,
    };
}

test "execution compatibility maps captured authority to leases and replay decisions" {
    const job: CompatibilityExecutionJob = .{
        .prompt = @constCast("prompt"),
        .images = &.{},
        .model = @constCast("model"),
        .api_key = @constCast("captured-key"),
        .provider = .codex,
        .credential_source = .chatgpt_subscription,
        .account_id = @constCast("account"),
        .gateway_team = @constCast("team"),
        .permission_mode = .ask,
        .history = &.{},
        .grants = &.{},
    };
    try std.testing.expectEqualStrings("captured-key", initialSecret(job));
    const lease = credentialLease("active-key", job);
    try std.testing.expectEqualStrings("active-key", lease.secret().?);
    try std.testing.expectEqualStrings("account", lease.accountId().?);
    try std.testing.expectEqualStrings("team", lease.tenant().?);
    const facts: ReplayFacts = .{ .authentication_rejected = true, .delivery_safe = true, .already_replayed = false };
    try std.testing.expectEqual(auth_transition.AuthReplayDecision.refresh_and_replay, replayDecision(job, facts));
    var unsafe = facts;
    unsafe.delivery_safe = false;
    try std.testing.expectEqual(auth_transition.AuthReplayDecision.fail, replayDecision(job, unsafe));
    unsafe = facts;
    unsafe.already_replayed = true;
    try std.testing.expectEqual(auth_transition.AuthReplayDecision.fail, replayDecision(job, unsafe));
    var managed = job;
    managed.credential_source = .host_managed;
    try std.testing.expect(credentialLease("ignored", managed) == .host_managed);
    var direct = job;
    direct.credential_source = .ai_gateway_api_key;
    try std.testing.expectEqual(auth_transition.AuthReplayDecision.fail, replayDecision(direct, facts));
}

test "execution compatibility refresh preserves source account and owned secret transfer" {
    const support = @import("../agent/runtime/tests/support.zig");
    const Probe = struct {
        calls: usize = 0,
        fn refresh(raw: *anyopaque, alloc: Allocator, source: types.CredentialSource, mode: CredentialRefreshMode, account: ?[]const u8) !?[]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expect(source == .chatgpt_subscription);
            try std.testing.expect(mode == .force);
            try std.testing.expectEqualStrings("account", account.?);
            return try alloc.dupe(u8, "rotated-key");
        }
    };
    const alloc = std.testing.allocator;
    var hooks = support.FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var deps = hooks.deps();
    var probe: Probe = .{};
    deps.ctx = &probe;
    deps.usage = null;
    deps.refresh_gateway_credential = Probe.refresh;
    const job: CompatibilityExecutionJob = .{
        .prompt = @constCast("prompt"),
        .images = &.{},
        .model = @constCast("model"),
        .api_key = @constCast("old-key"),
        .credential_source = .chatgpt_subscription,
        .account_id = @constCast("account"),
        .permission_mode = .ask,
        .history = &.{},
        .grants = &.{},
    };
    var active: []const u8 = initialSecret(job);
    var owned: ?[]u8 = null;
    defer if (owned) |value| releaseSecret(alloc, value);
    try std.testing.expect(try refreshCredential(&deps, alloc, job, .force, &active, &owned, .{}));
    try std.testing.expectEqualStrings("rotated-key", active);
    try std.testing.expect(active.ptr == owned.?.ptr);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(try refreshCredential(&deps, alloc, job, .force, &active, &owned, .{}));
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    var fixed = job;
    fixed.credential_source = .ai_gateway_api_key;
    try std.testing.expect(!try refreshCredential(&deps, alloc, fixed, .force, &active, &owned, .{}));
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
}

/// The primary legacy stream historically defaults an unspecified source to
/// the API-key source. Permission-review leases preserve null provenance.
pub fn modelRequestLease(value: []const u8, job: CompatibilityExecutionJob) types.CredentialLease {
    var lease = credentialLease(value, job);
    if (lease == .direct) lease.direct.source = job.credential_source orelse .ai_gateway_api_key;
    return lease;
}

test "execution compatibility preserves primary-request default without changing review provenance" {
    const job: CompatibilityExecutionJob = .{
        .prompt = @constCast("prompt"),
        .images = &.{},
        .model = @constCast("model"),
        .api_key = @constCast("key"),
        .permission_mode = .ask,
        .history = &.{},
        .grants = &.{},
    };
    try std.testing.expect(credentialLease("key", job).credentialSource() == null);
    try std.testing.expectEqual(types.CredentialSource.ai_gateway_api_key, modelRequestLease("key", job).credentialSource().?);
}

test "execution compatibility turn authority copy is allocation-failure safe" {
    const Check = struct {
        fn run(alloc: Allocator) !void {
            const job: CompatibilityExecutionJob = .{
                .prompt = @constCast("prompt"),
                .images = &.{},
                .model = @constCast("model"),
                .api_key = @constCast("key"),
                .account_id = @constCast("account"),
                .gateway_team = @constCast("team"),
                .permission_mode = .ask,
                .history = &.{},
                .grants = &.{},
            };
            const copied = try copyAuthorityForTurn(alloc, job);
            defer alloc.free(copied.account_id.?);
            defer alloc.free(copied.gateway_team.?);
            try std.testing.expectEqualStrings("account", copied.account_id.?);
            try std.testing.expectEqualStrings("team", copied.gateway_team.?);
            try std.testing.expect(copied.account_id.?.ptr != job.account_id.?.ptr);
            try std.testing.expect(copied.gateway_team.?.ptr != job.gateway_team.?.ptr);
            try std.testing.expect(copied.prompt.ptr == job.prompt.ptr);
            try std.testing.expect(copied.api_key.ptr == job.api_key.ptr);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

/// Project only neutral turn coordination. The caller has already established
/// the effective turn ID. Captured execution authority stays in the host job.
pub fn coordinator(job: worker.CompatibilityExecutionJob, turn: *@import("../agent/turn_state.zig").TurnState, cancel: *std.atomic.Value(bool), step_limit: usize) @import("../agent/turn_coordinator.zig").TurnCoordinator {
    return .{ .turn_id = job.turn_id, .delivery = job.delivery, .turn_state = turn, .cancel_flag = cancel, .step_limit = step_limit };
}

test "turn coordinator projection preserves identity delivery and borrowed state links" {
    var turn: @import("../agent/turn_state.zig").TurnState = .{};
    var cancel: std.atomic.Value(bool) = .init(false);
    const job: worker.CompatibilityExecutionJob = .{
        .turn_id = 77,
        .delivery = .continuation,
        .prompt = @constCast("prompt"),
        .images = &.{},
        .model = @constCast("model"),
        .api_key = @constCast("key"),
        .permission_mode = .ask,
        .history = &.{},
        .grants = &.{},
    };
    const projected = coordinator(job, &turn, &cancel, 9);
    try std.testing.expectEqual(@as(u64, 77), projected.turn_id);
    try std.testing.expect(projected.delivery.isContinuation());
    try std.testing.expect(projected.turn_state == &turn);
    try std.testing.expect(projected.cancel_flag == &cancel);
    try std.testing.expectEqual(@as(usize, 9), projected.step_limit);
    try std.testing.expectEqual(@as(usize, 0), projected.attempt);
    try std.testing.expectEqual(@as(usize, 0), projected.step);
}

/// Borrow the already-projected neutral coordinator; no captured host data is
/// read or retained by loop control and no additional allocation is performed.
pub fn loopControl(coordinator_state: *@import("../agent/turn_coordinator.zig").TurnCoordinator) @import("../agent/loop_control.zig").LoopControl {
    return .{ .coordinator = coordinator_state };
}

test "loop control projection preserves coordinator identity and initial index" {
    var state: @import("../agent/turn_state.zig").TurnState = .{};
    var cancel: std.atomic.Value(bool) = .init(false);
    var turn: @import("../agent/turn_coordinator.zig").TurnCoordinator = .{
        .turn_id = 7,
        .delivery = .ordinary,
        .turn_state = &state,
        .cancel_flag = &cancel,
        .step_limit = 3,
    };
    const control = loopControl(&turn);
    try std.testing.expect(control.coordinator == &turn);
    try std.testing.expectEqual(@as(usize, 0), control.current_step_index);
}

/// Project the neutral execution boundary from the compatibility job.
/// Borrows all slices from the job; no allocations are performed.
/// The compatibility job retains all credential, account, and billing state;
/// this projection contains only the workload and configuration data the turn
/// orchestration loop requires.
pub fn turnExecutionInput(job: CompatibilityExecutionJob) turn_execution_input.TurnExecutionInput {
    return .{
        .turn_id = job.turn_id,
        .delivery = job.delivery,
        .prompt = job.prompt,
        .images = job.images,
        .authorized_image_catalog = job.authorized_image_catalog,
        .model = job.model,
        .provider = job.provider,
        .history = job.history,
        .unversioned_history_count = job.unversioned_history_count,
        .grants = job.grants,
        .root_user_intent_context = job.root_user_intent_context,
        .context_snapshot = job.context_snapshot,
        .agent_settings = job.agent_settings,
        .skill_bindings = job.skill_bindings,
        .skill_display_spans = job.skill_display_spans,
        .snapshot_file_ownerships = job.snapshot_file_ownerships,
        .recovery_checkpoint = job.recovery_checkpoint,
        .recovery_source_already_presented = job.recovery_source_already_presented,
        .user_prompt_already_presented = job.user_prompt_already_presented,
        .steering_receipt = job.steering_receipt,
    };
}

test "turn execution input projection excludes all auth and account state" {
    const job: CompatibilityExecutionJob = .{
        .turn_id = 99,
        .delivery = .continuation,
        .prompt = @constCast("test"),
        .images = &.{},
        .model = @constCast("gpt-4"),
        .api_key = @constCast("secret-key"),
        .credential_source = .chatgpt_subscription,
        .account_id = @constCast("acct_123"),
        .gateway_team = @constCast("team_456"),
        .permission_mode = .ask,
        .history = &.{},
        .grants = &.{},
    };

    const input = turnExecutionInput(job);

    // Verify neutral fields are present
    try std.testing.expectEqual(@as(u64, 99), input.turn_id);
    try std.testing.expect(input.delivery.isContinuation());
    try std.testing.expectEqualStrings("test", input.prompt);
    try std.testing.expectEqualStrings("gpt-4", input.model);

    // Verify auth/account fields are not present by checking the type
    const fields = std.meta.fields(turn_execution_input.TurnExecutionInput);
    for (fields) |field| {
        try std.testing.expect(
            std.mem.indexOf(u8, field.name, "credential") == null,
        );
        try std.testing.expect(
            std.mem.indexOf(u8, field.name, "account") == null,
        );
        try std.testing.expect(
            std.mem.indexOf(u8, field.name, "api_key") == null,
        );
    }
}

/// Extract neutral model routing from the compatibility job.
/// Borrows provider and model fields; no allocations.
/// The compatibility job retains all credential, account, billing, and
/// authorization state; this projection contains only the routing identity
/// ("which endpoint/capability should execute this request").
///
/// ProviderSelection is the neutral routing type: it contains only the
/// provider name (gateway, codex, grok, or configured provider name) and the
/// model identifier, suitable for:
/// - Model capability queries
/// - ProviderSelection creation for replay identity
/// - Recovery selection comparison
/// - Routing decisions (gateway vs vendor-specific behavior)
/// - Telemetry/metrics labels
///
/// It does NOT contain:
/// - api_key or secret values
/// - credential_source (auth provenance)
/// - account_id (billing/authorization)
/// - gateway_team (tenant/control-plane)
/// - permission_mode (authorization policy)
pub fn neutralModelRoute(job: CompatibilityExecutionJob) model_provider.ProviderSelection {
    return .{
        .provider = job.provider,
        .model = job.model,
    };
}

test "neutral model route projection extracts only routing identity" {
    const job: CompatibilityExecutionJob = .{
        .turn_id = 42,
        .delivery = .ordinary,
        .prompt = @constCast("test"),
        .images = &.{},
        .model = @constCast("claude-opus-5-5"),
        .provider = .gateway,
        .api_key = @constCast("secret-key-abc123"),
        .credential_source = .ai_gateway_api_key,
        .account_id = @constCast("account_xyz"),
        .gateway_team = @constCast("team_abc"),
        .permission_mode = .auto,
        .history = &.{},
        .grants = &.{},
    };

    const route = neutralModelRoute(job);

    // Verify routing fields are present
    try std.testing.expect(route.provider == .gateway);
    try std.testing.expectEqualStrings("claude-opus-5-5", route.model);

    // Verify the route borrows from the job (no copy)
    try std.testing.expect(route.model.ptr == job.model.ptr);
}

test "neutral model route works with configured providers" {
    const job: CompatibilityExecutionJob = .{
        .turn_id = 77,
        .delivery = .ordinary,
        .prompt = @constCast("test"),
        .images = &.{},
        .model = @constCast("mistral-large"),
        .provider = model_provider.parse("local-ollama").?,
        .api_key = @constCast("ignored-key"),
        .permission_mode = .auto,
        .history = &.{},
        .grants = &.{},
    };

    const route = neutralModelRoute(job);

    try std.testing.expect(route.provider == .configured);
    try std.testing.expectEqualStrings("mistral-large", route.model);
    try std.testing.expectEqualStrings("local-ollama", route.provider.label());
}
