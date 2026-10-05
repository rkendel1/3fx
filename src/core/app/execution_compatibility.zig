const worker = @import("../agent/worker_runtime.zig");
const queue = @import("../agent/queued_turn.zig");

/// Transfers the captured host snapshot into the legacy execution shape.
/// No allocations, current-configuration reads, refreshes, or ownership copies.
/// Only the worker's execution handoff calls this conversion.
pub fn resolve(queued: queue.QueuedTurn, snapshot: worker.ExecutionSnapshot) worker.CompatibilityExecutionJob {
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
