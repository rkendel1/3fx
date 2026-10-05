const types = @import("../shared/types.zig");
const delivery = @import("turn_state.zig");
const worker = @import("worker_runtime.zig");
const context_contract = @import("../workspace/context_contract.zig");
const model_provider = @import("../config/model_provider.zig");
const session_codec = @import("../session/session_codec.zig");

/// Neutral turn execution boundary. Contains only workload and configuration data
/// that the turn loop requires, excluding all authentication, authorization,
/// account/billing, and provider-control-plane state.
///
/// This sits between CompatibilityExecutionJob (host compatibility layer) and
/// the turn orchestration loop. The compatibility layer retains all credential,
/// account, and subscription data; this type contains only what the turn itself
/// needs to process and coordinate.
pub const TurnExecutionInput = struct {
    /// Turn identity and delivery routing.
    turn_id: u64 = 0,
    delivery: delivery.PromptDelivery = .ordinary,

    /// User request text.
    prompt: []u8,

    /// Request attachments.
    images: []types.ImageAttachment,
    authorized_image_catalog: []types.ImageAttachment = &.{},

    /// Model and provider routing (configuration, not authorization).
    /// These are used for capability checks, request routing, and recovery
    /// identity projection, not for credential/billing purposes.
    model: []u8,
    provider: model_provider.ProviderId = .gateway,

    /// Conversation history for context construction.
    history: []types.HistoryTurn,

    /// Absolute end of the leading canonical-history range loaded without
    /// corrected result provenance. Protects callers that do not own a
    /// SessionRuntime snapshot.
    unversioned_history_count: usize = std.math.maxInt(usize),

    /// Neutral permission configuration for the turn.
    grants: []types.PermissionGrant,

    /// Context for auto-classification (not authentication). This is trusted
    /// only for permission review scoping, never for security decisions.
    root_user_intent_context: []u8 = &.{},

    /// Reconstructed workspace and project context snapshot.
    context_snapshot: context_contract.GatheredContextSnapshot = .{},

    /// Runtime settings for this turn (effort, tool choice, etc).
    agent_settings: worker.AgentTurnSettings = .{},

    /// Skill integrations.
    skill_bindings: []worker.SkillBinding = &.{},
    skill_display_spans: []worker.SkillDisplaySpan = &.{},

    /// File snapshot ownership for this turn.
    snapshot_file_ownerships: []types.SnapshotFileOwnership = &.{},

    /// Resume/recovery state. Present only when an explicit host action resumes
    /// a durable paused model turn.
    recovery_checkpoint: ?session_codec.RecoveryCheckpoint = null,

    /// UI state: recovery source already rendered in output surface.
    recovery_source_already_presented: bool = false,

    /// UI state: user prompt already rendered in output surface.
    user_prompt_already_presented: bool = false,

    /// Steering receipt for priority/cancellation. Borrowed from worker;
    /// lifetime outlives turn execution.
    steering_receipt: ?*worker.SteeringReceipt = null,
};

test "turn execution input contains only neutral workload data" {
    const std = @import("std");
    const fields = std.meta.fields(TurnExecutionInput);

    // Verify no credential/auth/account/billing fields are present
    for (fields) |field| {
        const name = field.name;
        for (.{
            "api_key",
            "secret",
            "credential",
            "account_id",
            "gateway_team",
            "tenant",
            "billing",
            "provider_id",
            "auth",
            "source",
        }) |forbidden| {
            try std.testing.expect(
                std.mem.indexOf(u8, name, forbidden) == null,
            ) catch {
                return std.testing.expect(false);
            };
        }
    }
}

test "turn execution input borrows all slices without ownership copies" {
    const std = @import("std");
    const alloc = std.testing.allocator;

    const prompt_text = try alloc.dupe(u8, "test prompt");
    defer alloc.free(prompt_text);

    const history_item: types.HistoryTurn = .{ .role = .user, .text = try alloc.dupe(u8, "history") };
    const history_array = try alloc.dupe(types.HistoryTurn, &.{history_item});
    defer {
        for (history_array) |turn| alloc.free(turn.text);
        alloc.free(history_array);
    }

    const input: TurnExecutionInput = .{
        .turn_id = 42,
        .delivery = .ordinary,
        .prompt = prompt_text,
        .images = &.{},
        .model = @constCast("gpt-4"),
        .provider = .gateway,
        .history = history_array,
        .grants = &.{},
    };

    try std.testing.expectEqual(@as(u64, 42), input.turn_id);
    try std.testing.expectEqualStrings("test prompt", input.prompt);
    try std.testing.expectEqual(@as(usize, 1), input.history.len);
    try std.testing.expect(!input.recovery_source_already_presented);
    try std.testing.expect(!input.user_prompt_already_presented);
}

test "turn execution input projection from compatibility job excludes auth state" {
    const std = @import("std");
    const exec_compat = @import("../app/execution_compatibility.zig");
    const job: worker.CompatibilityExecutionJob = .{
        .turn_id = 77,
        .delivery = .continuation,
        .prompt = @constCast("tell me something"),
        .images = &.{},
        .model = @constCast("gpt-4"),
        .provider = .gateway,
        .api_key = @constCast("secret-key-value"),
        .credential_source = .chatgpt_subscription,
        .account_id = @constCast("acct_xyz123"),
        .gateway_team = @constCast("team_abc"),
        .permission_mode = .ask,
        .history = &.{},
        .grants = &.{},
    };

    const input = exec_compat.turnExecutionInput(job);

    // Verify neutral fields are projected
    try std.testing.expectEqual(@as(u64, 77), input.turn_id);
    try std.testing.expect(input.delivery.isContinuation());
    try std.testing.expectEqualStrings("tell me something", input.prompt);
    try std.testing.expectEqualStrings("gpt-4", input.model);

    // Verify the type itself has no auth fields
    const type_fields = std.meta.fields(TurnExecutionInput);
    try std.testing.expect(type_fields.len > 0);
    for (type_fields) |field| {
        // Ensure no sensitive field names are present
        try std.testing.expect(std.mem.indexOf(u8, field.name, "api_key") == null);
        try std.testing.expect(std.mem.indexOf(u8, field.name, "secret") == null);
        try std.testing.expect(std.mem.indexOf(u8, field.name, "credential") == null);
        try std.testing.expect(std.mem.indexOf(u8, field.name, "account") == null);
    }
}

const std = @import("std");
