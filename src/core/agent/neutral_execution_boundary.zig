const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");
const context_contract = @import("../workspace/context_contract.zig");
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

    /// User request text.
    prompt: []u8,

    /// Request attachments.
    images: []types.ImageAttachment,

    /// Model and provider routing (configuration, not authorization).
    model: []u8,
    provider: model_provider.ProviderId = .gateway,

    /// Conversation history for context construction.
    history: []types.HistoryTurn,

    /// Neutral permission configuration for the turn.
    grants: []types.PermissionGrant,
};

/// Provider-neutral model request. Constructed from neutral boundary data,
/// independent of host auth/credentials/account/billing.
pub const NeutralModelRequest = struct {
    turn_id: u64,
    model: []u8,
    provider: model_provider.ProviderId,
    messages: []const types.ChatMessage,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
};

/// Provider-neutral model response. Carries only observable model output,
/// independent of host state.
pub const NeutralModelCompletion = struct {
    pub const Kind = enum {
        success,
        stop,
        tool_use,
        error,
    };

    kind: Kind,
    text: []u8,
    /// Present when kind is tool_use
    tool_calls: []types.ToolCall = &.{},
    /// Present when kind is error
    error_message: ?[]u8 = null,
};

test "neutral execution boundary contains only workload data" {
    const std = @import("std");
    const fields = std.meta.fields(TurnExecutionInput);

    // Verify no auth/account/billing fields are present
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
            "auth",
            "credential_source",
        }) |forbidden| {
            try std.testing.expect(
                std.mem.indexOf(u8, name, forbidden) == null,
            ) catch {
                return std.testing.expect(false);
            };
        }
    }
}
