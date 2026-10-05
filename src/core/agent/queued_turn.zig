const delivery = @import("turn_state.zig");

/// Process-local typed handle into the owning worker's execution snapshot store.
/// It contains no execution configuration and cannot resolve itself.
pub const ExecutionSnapshotId = struct { value: u64 };

/// The sole production FIFO item. The queue owns prompt text; captured execution
/// authority remains in the host-owned typed snapshot store until terminal use.
pub const QueuedTurn = struct {
    turn_id: u64,
    prompt: []u8,
    delivery: delivery.PromptDelivery = .ordinary,
    execution_snapshot_id: ExecutionSnapshotId,
};
