//! Context and observation measurement for one agent turn.
//!
//! Every counter is advanced by a runtime event that actually happened: a
//! model call that was admitted, a tool execution that started, a request
//! projection that was built for a call that was sent. Provider-reported token
//! usage and runtime byte counts are kept in separate fields; a count the
//! provider (or adapter) did not report stays null and is never estimated.

const std = @import("std");
const types = @import("../../shared/types.zig");
const agent_stream_provider = @import("../stream_provider.zig");
const observation_discipline = @import("observation_discipline.zig");
const debug_trace = @import("../../shared/debug_trace.zig");

pub const ContextMeter = struct {
    /// Model calls that reached the provider (admitted).
    model_calls: u64 = 0,
    /// Tool executions that started (rejected requests never count).
    tool_executions: u64 = 0,
    /// Sums of provider-reported usage; null until some call reports a value.
    provider_input_tokens: ?u64 = null,
    provider_output_tokens: ?u64 = null,
    /// Bytes of serialized request bodies the adapter reported sending, and how
    /// many calls reported one. Adapters that do not report leave this unknown.
    serialized_request_bytes: u64 = 0,
    requests_with_known_bytes: u64 = 0,
    last_request_bytes: ?u64 = null,
    /// Message count of the most recent request sent.
    last_request_messages: u64 = 0,
    /// Repeated observations in the history of the most recent request sent.
    repeated_observations: u64 = 0,
    /// Totals over requests actually sent.
    omitted_observations: u64 = 0,
    omissions_denied: u64 = 0,
    /// Admitted model calls by reason (see `observation_discipline.CallReason`).
    calls_initial: u64 = 0,
    calls_after_tools: u64 = 0,
    calls_after_failed_tools: u64 = 0,

    staged: ?observation_discipline.Stats = null,
    staged_reason: observation_discipline.CallReason = .initial,

    /// Records the projection built for the request about to be sent. It is
    /// committed only if that request is then admitted by the provider.
    pub fn stage(self: *ContextMeter, stats: observation_discipline.Stats, reason: observation_discipline.CallReason) void {
        self.staged = stats;
        self.staged_reason = reason;
    }

    pub fn recordToolExecution(self: *ContextMeter) void {
        self.tool_executions += 1;
    }

    /// `usage` is null when the call produced no completion.
    pub fn recordModelCall(
        self: *ContextMeter,
        evidence: agent_stream_provider.AttemptEvidence,
        usage: ?types.Usage,
        message_count: usize,
    ) void {
        if (!evidence.provider_admitted) {
            self.staged = null;
            return;
        }
        self.model_calls += 1;
        switch (self.staged_reason) {
            .initial => self.calls_initial += 1,
            .after_tools => self.calls_after_tools += 1,
            .after_failed_tools => self.calls_after_failed_tools += 1,
        }
        self.last_request_messages = message_count;
        if (evidence.serialized_request_bytes) |bytes| {
            self.serialized_request_bytes += bytes;
            self.requests_with_known_bytes += 1;
            self.last_request_bytes = bytes;
        } else {
            self.last_request_bytes = null;
        }
        if (usage) |reported| {
            if (reported.input_tokens) |tokens| self.provider_input_tokens = (self.provider_input_tokens orelse 0) +| tokens;
            if (reported.output_tokens) |tokens| self.provider_output_tokens = (self.provider_output_tokens orelse 0) +| tokens;
        }
        if (self.staged) |stats| {
            self.repeated_observations = stats.repeated;
            self.omitted_observations += stats.omitted;
            self.omissions_denied += stats.denied;
            self.staged = null;
        }
    }

    pub fn trace(self: *const ContextMeter, ctx: debug_trace.TraceContext) void {
        debug_trace.eventf(
            "context",
            "measurement",
            ctx,
            "model_calls={d} tool_executions={d} provider_input_tokens={?d} provider_output_tokens={?d} serialized_request_bytes={d} requests_with_known_bytes={d} last_request_messages={d} repeated_observations={d} omitted_observations={d} omissions_denied={d} calls_initial={d} calls_after_tools={d} calls_after_failed_tools={d}",
            .{
                self.model_calls,
                self.tool_executions,
                self.provider_input_tokens,
                self.provider_output_tokens,
                self.serialized_request_bytes,
                self.requests_with_known_bytes,
                self.last_request_messages,
                self.repeated_observations,
                self.omitted_observations,
                self.omissions_denied,
                self.calls_initial,
                self.calls_after_tools,
                self.calls_after_failed_tools,
            },
        );
    }
};

test "model calls count only admitted requests and tokens stay unknown when unreported" {
    var meter: ContextMeter = .{};
    meter.recordModelCall(.{ .provider_admitted = false }, .{ .input_tokens = 99 }, 3);
    try std.testing.expectEqual(@as(u64, 0), meter.model_calls);
    try std.testing.expect(meter.provider_input_tokens == null);

    meter.recordModelCall(.{ .provider_admitted = true, .serialized_request_bytes = 1200 }, .{}, 4);
    try std.testing.expectEqual(@as(u64, 1), meter.model_calls);
    try std.testing.expect(meter.provider_input_tokens == null);
    try std.testing.expect(meter.provider_output_tokens == null);
    try std.testing.expectEqual(@as(u64, 1200), meter.serialized_request_bytes);

    meter.recordModelCall(.{ .provider_admitted = true }, .{ .input_tokens = 50, .output_tokens = 7 }, 6);
    try std.testing.expectEqual(@as(u64, 2), meter.model_calls);
    try std.testing.expectEqual(@as(?u64, 50), meter.provider_input_tokens);
    try std.testing.expectEqual(@as(?u64, 7), meter.provider_output_tokens);
    // Tokens never leak into byte counts and an unreported byte count stays unknown.
    try std.testing.expectEqual(@as(u64, 1200), meter.serialized_request_bytes);
    try std.testing.expectEqual(@as(u64, 1), meter.requests_with_known_bytes);
    try std.testing.expect(meter.last_request_bytes == null);
}

test "projection counters commit only for a request that was sent" {
    var meter: ContextMeter = .{};
    meter.stage(.{ .repeated = 2, .omitted = 1, .denied = 3 }, .initial);
    meter.recordModelCall(.{ .provider_admitted = false }, null, 2);
    try std.testing.expectEqual(@as(u64, 0), meter.omitted_observations);
    try std.testing.expectEqual(@as(u64, 0), meter.omissions_denied);

    meter.stage(.{ .repeated = 2, .omitted = 1, .denied = 3 }, .initial);
    meter.recordModelCall(.{ .provider_admitted = true }, null, 2);
    meter.stage(.{ .repeated = 1, .omitted = 0, .denied = 1 }, .after_failed_tools);
    meter.recordModelCall(.{ .provider_admitted = true }, null, 2);
    try std.testing.expectEqual(@as(u64, 1), meter.omitted_observations);
    try std.testing.expectEqual(@as(u64, 4), meter.omissions_denied);
    try std.testing.expectEqual(@as(u64, 1), meter.repeated_observations);
    // Reasons are committed with the same rule: the unsent request counted nothing.
    try std.testing.expectEqual(@as(u64, 1), meter.calls_initial);
    try std.testing.expectEqual(@as(u64, 1), meter.calls_after_failed_tools);
    try std.testing.expectEqual(@as(u64, 0), meter.calls_after_tools);
}

test "tool executions are counted from started executions" {
    var meter: ContextMeter = .{};
    meter.recordToolExecution();
    meter.recordToolExecution();
    try std.testing.expectEqual(@as(u64, 2), meter.tool_executions);
}
