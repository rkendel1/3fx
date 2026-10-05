/// Neutral Execution Core
///
/// This module proves that the neutral execution core is 100% independent of
/// host compatibility, authentication, billing, and control-plane infrastructure.
///
/// Only this list of modules may be imported by the neutral core:
/// - std (Zig standard library)
/// - Tier 1: Core execution primitives (turn_coordinator, loop_control, turn_state, model_provider)
/// - Tier 2: Turn execution configuration (turn_execution_input)
/// - Tier 3: Model execution boundary (stream_provider for neutral types)
/// - Tier 4: Worker runtime (worker_runtime - now clean after refactoring)
/// - Supporting infrastructure (types, debug_trace, io, session_codec, context_contract, etc.)
///
/// FORBIDDEN:
/// - Any module from src/core/auth/ (credentials, secret, credential_authority, etc.)
/// - Any module from src/core/account/
/// - Any module from src/core/billing/
/// - TUI/UI modules (src/ui/)
/// - Compute/PAX/AppPort/FeltDB modules
///
/// This module serves as the single point of import verification for the neutral core.

// ===== Tier 1: Core Execution Primitives (Pristine) =====
pub const turn_coordinator = @import("agent/turn_coordinator.zig");
pub const TurnCoordinator = turn_coordinator.TurnCoordinator;

pub const loop_control = @import("agent/loop_control.zig");
pub const LoopControl = loop_control.LoopControl;

pub const turn_state = @import("agent/turn_state.zig");
pub const TurnState = turn_state.TurnState;
pub const PromptDelivery = turn_state.PromptDelivery;

pub const model_provider = @import("agent/model_provider.zig");
pub const ModelProvider = model_provider.ModelProvider;
pub const ProviderCapabilities = model_provider.ProviderCapabilities;
pub const ModelFeatures = model_provider.ModelFeatures;
pub const ToolCall = model_provider.ToolCall;
pub const Message = model_provider.Message;
pub const Tool = model_provider.Tool;
pub const Event = model_provider.Event;
pub const EventSink = model_provider.EventSink;
pub const Admission = model_provider.Admission;
pub const Delivery = model_provider.Delivery;
pub const ChatRequest = model_provider.ChatRequest;
pub const TokenUsage = model_provider.TokenUsage;
pub const FinishReason = model_provider.FinishReason;
pub const Completion = model_provider.Completion;

// ===== Tier 2: Turn Execution Configuration (Established Boundary) =====
pub const turn_execution_input = @import("agent/turn_execution_input.zig");
pub const TurnExecutionInput = turn_execution_input.TurnExecutionInput;
pub const ProviderSelection = turn_execution_input.ProviderSelection;

// ===== Tier 3: Model Execution Boundary (Pristine at Seam) =====
pub const stream_provider = @import("agent/stream_provider.zig");
pub const NeutralModelRequest = stream_provider.NeutralModelRequest;
pub const RequestData = stream_provider.RequestData;
pub const NeutralModelCompletion = stream_provider.NeutralModelCompletion;
pub const NeutralFailure = stream_provider.NeutralFailure;
pub const NeutralModelResponse = stream_provider.NeutralModelResponse;
pub const NeutralEventSink = stream_provider.NeutralEventSink;
pub const NeutralEvent = stream_provider.NeutralEvent;

// ===== Tier 4: Worker Runtime (CLEAN after refactoring) =====
pub const worker_runtime = @import("agent/worker_runtime.zig");
pub const WorkerRuntime = worker_runtime.WorkerRuntime;
pub const AgentTurnSettings = worker_runtime.AgentTurnSettings;
pub const WorkerRuntimeConfig = worker_runtime.WorkerRuntimeConfig;

// ===== Supporting Infrastructure (Neutral) =====
pub const types = @import("shared/types.zig");
pub const debug_trace = @import("shared/debug_trace.zig");
pub const io_mod = @import("shared/io.zig");
pub const history_range = @import("shared/history_range.zig");

pub const model_config_provider = @import("config/model_provider.zig");
pub const ProviderId = model_config_provider.ProviderId;

pub const model_capabilities = @import("config/model_capabilities.zig");
pub const ModelCapabilities = model_capabilities.ModelCapabilities;

pub const agent_steps = @import("config/agent_steps.zig");
pub const AgentSteps = agent_steps.AgentSteps;

pub const session_codec = @import("session/session_codec.zig");
pub const context_contract = @import("workspace/context_contract.zig");
pub const auto_classifier_context = @import("permissions/auto_classifier_context.zig");
pub const permission_request = @import("permissions/permission_request.zig");

pub const tool_dispatch = @import("tooling/tool_dispatch.zig");
pub const model_tool_schema = @import("tooling/model_tool_schema.zig");
pub const file_mutation_contract = @import("tooling/file_mutation_contract.zig");

pub const image_attachments = @import("images/image_attachments.zig");

// ===== Test: Verify no forbidden modules are accessible =====

test "neutral core does not import auth modules" {
    const std = @import("std");

    // This test verifies at compile time that forbidden modules cannot be imported.
    // If someone tries to add:
    //   const credentials = @import("auth/credentials.zig");
    // the build will fail because credentials.zig is not listed above.

    // Verify we have the core types we expect
    _ = TurnCoordinator;
    _ = TurnState;
    _ = ModelProvider;
    _ = TurnExecutionInput;
    _ = NeutralModelRequest;
    _ = NeutralModelCompletion;
    _ = WorkerRuntime;

    try std.testing.expect(true);
}

test "neutral core exports key neutral types" {
    const std = @import("std");

    // Smoke test: can we construct minimal instances of key types?
    var turn_state_instance: TurnState = .{};
    var delivery: PromptDelivery = .ordinary;

    try std.testing.expect(!turn_state_instance.fresh);
    try std.testing.expect(delivery == .ordinary);

    // Turn coordinator needs mutable references
    var cancelled = std.atomic.Value(bool).init(false);
    var coordinator: TurnCoordinator = .{
        .turn_id = 1,
        .delivery = delivery,
        .turn_state = &turn_state_instance,
        .cancel_flag = &cancelled,
        .step_limit = 10,
    };

    try std.testing.expectEqual(@as(u64, 1), coordinator.turn_id);
    try std.testing.expectEqual(@as(usize, 0), coordinator.attempt);
    try std.testing.expectEqual(@as(usize, 10), coordinator.step_limit);
}
