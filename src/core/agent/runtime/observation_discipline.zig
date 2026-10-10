//! Evidence-aware context discipline for model-facing requests.
//!
//! Behavior and invariants are taken from Rust Chip (`chip-core/src/work.rs`:
//! `classify_observations`, `omissions`, `DeduplicatedEscalationContext`;
//! tests in `tests/context_discipline.rs`), adapted to FX's tool-result
//! messages. This module is a pure projection over `ChatMessage` values:
//! it never touches stored history, evidence or logs.
//!
//! Identity and comparison rules (deterministic, no normalization):
//! * An invocation is the tool name plus the exact `arguments_json` bytes of
//!   the call that produced the result. Argument order or spacing that differs
//!   is a different invocation, which fails toward "not repeated".
//! * Two observations describe the same reality when their status and content
//!   bytes are equal. Text alone never decides identity of the invocation.
//!
//! Reuse safety (all conditions, fail closed):
//! 1. The tool's contract explicitly permits reuse. FX has no such contract on
//!    built-in tools, so production supplies none and every case is denied.
//! 2. The earlier result succeeded and carries no stored images.
//! 3. A later result of the same invocation has the same reality.
//! 4. No state-changing result, unknown tool, or new user turn lies between
//!    the earlier result and the end of the request, so both copies describe
//!    the state the model is about to act on.
//! Only then is the earlier tool message's content replaced by a fixed
//! reference to the later call id. Nothing is summarized, reordered, removed
//! or re-paired.

const std = @import("std");
const types = @import("../../shared/types.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

/// Chip semantics: compared with the most recent earlier observation of the
/// same invocation.
pub const Class = enum {
    /// The first observation of its tool.
    new,
    /// Same invocation as an earlier observation, with the same reality.
    repeated,
    /// Same invocation as an earlier observation, with a different reality.
    changed,
    /// The tool was observed before, but with a different invocation.
    same_capability,
};

/// What a tool declares about reusing its earlier results. Supplied by the
/// caller; never inferred from a name or from identical output.
pub const ReuseContract = struct {
    /// An earlier identical result may be left out of a request.
    permits_reuse: bool = false,
    /// Running this tool can change state later results depend on.
    mutates_state: bool = true,
};

pub const ContractSource = struct {
    context: ?*const anyopaque = null,
    lookup_fn: ?*const fn (context: ?*const anyopaque, tool_name: []const u8) ?ReuseContract = null,

    /// No contracts: nothing may be omitted, every tool counts as state-changing.
    pub const none: ContractSource = .{};

    fn find(self: ContractSource, tool_name: []const u8) ?ReuseContract {
        const lookup = self.lookup_fn orelse return null;
        return lookup(self.context, tool_name);
    }
};

pub const Observation = struct {
    /// Index of the tool message in the projected message list.
    message_index: usize,
    call_id: []const u8,
    tool_name: []const u8,
    arguments: []const u8,
    status: ?types.PersistedToolStatus,
    content: []const u8,
    /// Number of state-changing events before this result.
    epoch: u64,
    class: Class,
};

pub const Stats = struct {
    observations: usize = 0,
    repeated: usize = 0,
    changed: usize = 0,
    same_capability: usize = 0,
    /// Results replaced by a reference in the returned messages.
    omitted: usize = 0,
    /// Results that had a later identical result but could not safely be omitted.
    denied: usize = 0,
};

pub const Projection = struct {
    /// Equal to the input slice (same pointer) when nothing was omitted.
    messages: []const ChatMessage,
    observations: []const Observation,
    stats: Stats,
};

/// Why a model call is being made, derived only from the request's tail.
pub const CallReason = enum {
    /// The request ends with a user (or system) message, not tool results.
    initial,
    /// The request ends with tool results, at least one of which succeeded.
    after_tools,
    /// The request ends with tool results and every one of them failed or was rejected.
    after_failed_tools,
};

pub fn callReason(messages: []const ChatMessage) CallReason {
    var end = messages.len;
    var any = false;
    var all_failed = true;
    while (end > 0 and messages[end - 1].role == .tool) : (end -= 1) {
        any = true;
        if (messages[end - 1].tool_result_status != .failure) all_failed = false;
    }
    if (!any) return .initial;
    return if (all_failed) .after_failed_tools else .after_tools;
}

const PendingCall = struct { id: []const u8, name: []const u8, arguments: []const u8 };

/// Classifies the tool results in `messages` and, when `reuse_enabled`,
/// omits those that every reuse condition allows. Allocations (and the
/// returned slices) belong to `alloc`; use a request-scoped arena.
pub fn project(
    alloc: Allocator,
    messages: []const ChatMessage,
    contracts: ContractSource,
    reuse_enabled: bool,
) Allocator.Error!Projection {
    var calls: std.ArrayList(PendingCall) = .empty;
    var observations: std.ArrayList(Observation) = .empty;
    var epoch: u64 = 0;

    for (messages, 0..) |message, index| {
        switch (message.role) {
            .user => epoch += 1,
            .assistant => for (message.tool_calls) |call| {
                try calls.append(alloc, .{ .id = call.id, .name = call.name, .arguments = call.arguments_json });
            },
            .tool => {
                const call_id = message.tool_call_id orelse continue;
                const call = findCall(calls.items, call_id) orelse continue;
                const name = message.tool_name orelse call.name;
                try observations.append(alloc, .{
                    .message_index = index,
                    .call_id = call_id,
                    .tool_name = name,
                    .arguments = call.arguments,
                    .status = message.tool_result_status,
                    .content = message.content orelse "",
                    .epoch = epoch,
                    .class = .new,
                });
                // Unknown tools are assumed to change state.
                const mutates = if (contracts.find(name)) |contract| contract.mutates_state else true;
                if (mutates) epoch += 1;
            },
            else => {},
        }
    }

    var stats: Stats = .{ .observations = observations.items.len };
    for (observations.items, 0..) |*current, i| {
        current.class = classify(observations.items[0..i], current.*);
        switch (current.class) {
            .repeated => stats.repeated += 1,
            .changed => stats.changed += 1,
            .same_capability => stats.same_capability += 1,
            .new => {},
        }
    }

    var rewritten: ?[]ChatMessage = null;
    for (observations.items, 0..) |earlier, i| {
        const later = latestIdentical(observations.items, i) orelse continue;
        if (!reuseAllowed(messages, contracts, earlier, later, epoch)) {
            stats.denied += 1;
            continue;
        }
        if (!reuse_enabled) continue;
        if (rewritten == null) rewritten = try alloc.dupe(ChatMessage, messages);
        rewritten.?[earlier.message_index].content = try std.fmt.allocPrint(
            alloc,
            "[fx: omitted; identical to the result of tool call {s}]",
            .{later.call_id},
        );
        stats.omitted += 1;
    }

    return .{
        .messages = rewritten orelse messages,
        .observations = observations.items,
        .stats = stats,
    };
}

fn findCall(calls: []const PendingCall, id: []const u8) ?PendingCall {
    var i = calls.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, calls[i].id, id)) return calls[i];
    }
    return null;
}

fn sameInvocation(a: Observation, b: Observation) bool {
    return std.mem.eql(u8, a.tool_name, b.tool_name) and std.mem.eql(u8, a.arguments, b.arguments);
}

fn sameReality(a: Observation, b: Observation) bool {
    return a.status == b.status and std.mem.eql(u8, a.content, b.content);
}

fn classify(earlier: []const Observation, current: Observation) Class {
    var i = earlier.len;
    while (i > 0) {
        i -= 1;
        if (sameInvocation(earlier[i], current)) {
            return if (sameReality(earlier[i], current)) .repeated else .changed;
        }
    }
    for (earlier) |candidate| {
        if (std.mem.eql(u8, candidate.tool_name, current.tool_name)) return .same_capability;
    }
    return .new;
}

fn latestIdentical(observations: []const Observation, index: usize) ?Observation {
    var j = observations.len;
    while (j > index + 1) {
        j -= 1;
        if (sameInvocation(observations[index], observations[j]) and sameReality(observations[index], observations[j])) {
            return observations[j];
        }
    }
    return null;
}

fn reuseAllowed(
    messages: []const ChatMessage,
    contracts: ContractSource,
    earlier: Observation,
    later: Observation,
    current_epoch: u64,
) bool {
    const contract = contracts.find(earlier.tool_name) orelse return false;
    if (!contract.permits_reuse) return false;
    if (earlier.status != .success or later.status != .success) return false;
    // The model must still see the complete current evidence.
    if (earlier.epoch != later.epoch or later.epoch + @intFromBool(contract.mutates_state) != current_epoch) return false;
    const memory = messages[earlier.message_index].tool_result_memory;
    if (memory) |stored| {
        if (stored.tool_images.len != 0 or stored.tool_image_handle != null) return false;
    }
    if (messages[earlier.message_index].images.len != 0) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests. Each table row is a message history; the first table adapts Chip's
// `observations_are_classified_new_repeated_changed_or_from_the_same_capability`.

const test_contracts = struct {
    fn lookup(_: ?*const anyopaque, name: []const u8) ?ReuseContract {
        if (std.mem.eql(u8, name, "read")) return .{ .permits_reuse = true, .mutates_state = false };
        if (std.mem.eql(u8, name, "write")) return .{ .permits_reuse = false, .mutates_state = true };
        if (std.mem.eql(u8, name, "peek")) return .{ .permits_reuse = false, .mutates_state = false };
        return null;
    }
    const source: ContractSource = .{ .lookup_fn = lookup };
};

const Step = struct {
    tool: []const u8,
    args: []const u8,
    out: []const u8,
    status: types.PersistedToolStatus = .success,
};

/// Builds assistant(call)/tool(result) pairs in one turn after a user message.
fn history(alloc: Allocator, steps: []const Step) ![]ChatMessage {
    var list: std.ArrayList(ChatMessage) = .empty;
    try list.append(alloc, .{ .role = .user, .content = "task" });
    for (steps, 0..) |step, n| {
        const id = try std.fmt.allocPrint(alloc, "call-{d}", .{n});
        const calls = try alloc.alloc(types.ToolCall, 1);
        calls[0] = .{ .id = id, .name = step.tool, .arguments_json = step.args };
        try list.append(alloc, .{ .role = .assistant, .tool_calls = calls });
        try list.append(alloc, .{
            .role = .tool,
            .content = step.out,
            .tool_call_id = id,
            .tool_name = step.tool,
            .tool_result_status = step.status,
        });
    }
    return list.items;
}

fn expectClasses(steps: []const Step, expected: []const Class) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const messages = try history(arena.allocator(), steps);
    const projection = try project(arena.allocator(), messages, test_contracts.source, false);
    try std.testing.expectEqual(expected.len, projection.observations.len);
    for (expected, projection.observations) |want, got| try std.testing.expectEqual(want, got.class);
}

test "observations are classified new, repeated, changed or same capability" {
    const A = "{\"path\":\"a\"}";
    const B = "{\"path\":\"b\"}";
    const cases = [_]struct { steps: []const Step, expected: []const Class }{
        // 1 new
        .{ .steps = &.{.{ .tool = "read", .args = A, .out = "x" }}, .expected = &.{.new} },
        // 2 identical invocation and reality
        .{ .steps = &.{ .{ .tool = "read", .args = A, .out = "x" }, .{ .tool = "read", .args = A, .out = "x" } }, .expected = &.{ .new, .repeated } },
        // 3 same invocation, different reality
        .{ .steps = &.{ .{ .tool = "read", .args = A, .out = "x" }, .{ .tool = "read", .args = A, .out = "y" } }, .expected = &.{ .new, .changed } },
        // 4 same tool, different invocation, identical text is still a different invocation
        .{ .steps = &.{ .{ .tool = "read", .args = A, .out = "x" }, .{ .tool = "read", .args = B, .out = "x" } }, .expected = &.{ .new, .same_capability } },
        // 5 read, write, read: the second read changed
        .{ .steps = &.{ .{ .tool = "read", .args = A, .out = "old" }, .{ .tool = "write", .args = A, .out = "ok" }, .{ .tool = "read", .args = A, .out = "new" } }, .expected = &.{ .new, .new, .changed } },
        // 6 a failure and a success of one invocation differ in reality
        .{ .steps = &.{ .{ .tool = "read", .args = A, .out = "e", .status = .failure }, .{ .tool = "read", .args = A, .out = "e" } }, .expected = &.{ .new, .changed } },
        // 7 compared with the most recent same invocation
        .{ .steps = &.{ .{ .tool = "read", .args = A, .out = "x" }, .{ .tool = "read", .args = A, .out = "y" }, .{ .tool = "read", .args = A, .out = "y" } }, .expected = &.{ .new, .changed, .repeated } },
        // 8 argument bytes decide the invocation
        .{ .steps = &.{ .{ .tool = "read", .args = "{\"a\":1,\"b\":2}", .out = "x" }, .{ .tool = "read", .args = "{\"b\":2,\"a\":1}", .out = "x" } }, .expected = &.{ .new, .same_capability } },
    };
    for (cases) |case| try expectClasses(case.steps, case.expected);
}

test "identical histories give identical classifications and projections" {
    var first = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first.deinit();
    var second = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second.deinit();
    const steps = [_]Step{
        .{ .tool = "read", .args = "{\"p\":1}", .out = "same" },
        .{ .tool = "read", .args = "{\"p\":1}", .out = "same" },
        .{ .tool = "read", .args = "{\"p\":2}", .out = "same" },
    };
    const a = try project(first.allocator(), try history(first.allocator(), &steps), test_contracts.source, true);
    const b = try project(second.allocator(), try history(second.allocator(), &steps), test_contracts.source, true);
    try std.testing.expectEqual(a.stats, b.stats);
    for (a.observations, b.observations) |x, y| try std.testing.expectEqual(x.class, y.class);
    for (a.messages, b.messages) |x, y| {
        try std.testing.expectEqualStrings(x.content orelse "", y.content orelse "");
    }
}

test "a reusable earlier identical result is omitted with a reference and nothing else changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const messages = try history(alloc, &.{
        .{ .tool = "read", .args = "{\"p\":1}", .out = "BODY" },
        .{ .tool = "read", .args = "{\"p\":1}", .out = "BODY" },
    });
    const projection = try project(alloc, messages, test_contracts.source, true);
    try std.testing.expectEqual(@as(usize, 1), projection.stats.omitted);
    try std.testing.expectEqual(@as(usize, 0), projection.stats.denied);
    try std.testing.expectEqual(messages.len, projection.messages.len);
    // The earlier result carries only a deterministic reference, no summary.
    try std.testing.expectEqualStrings(
        "[fx: omitted; identical to the result of tool call call-1]",
        projection.messages[2].content.?,
    );
    // The later copy is kept verbatim, and the source messages are untouched.
    try std.testing.expectEqualStrings("BODY", projection.messages[4].content.?);
    try std.testing.expectEqualStrings("BODY", messages[2].content.?);
    // Role, pairing and order are unchanged for every message.
    for (messages, projection.messages) |before, after| {
        try std.testing.expectEqual(before.role, after.role);
        try std.testing.expectEqualStrings(before.tool_call_id orelse "", after.tool_call_id orelse "");
        try std.testing.expectEqual(before.tool_calls.len, after.tool_calls.len);
    }
}

test "reuse is denied unless every condition holds" {
    const A = "{\"p\":1}";
    const Row = struct { name: []const u8, steps: []const Step, source: ContractSource, enabled: bool = true, denied: usize, omitted: usize };
    const cases = [_]Row{
        .{ .name = "non-reusable contract retains identical evidence", .steps = &.{ .{ .tool = "peek", .args = A, .out = "x" }, .{ .tool = "peek", .args = A, .out = "x" } }, .source = test_contracts.source, .denied = 1, .omitted = 0 },
        .{ .name = "missing contract denies", .steps = &.{ .{ .tool = "unknown", .args = A, .out = "x" }, .{ .tool = "unknown", .args = A, .out = "x" } }, .source = test_contracts.source, .denied = 1, .omitted = 0 },
        .{ .name = "no contract source denies", .steps = &.{ .{ .tool = "read", .args = A, .out = "x" }, .{ .tool = "read", .args = A, .out = "x" } }, .source = ContractSource.none, .denied = 1, .omitted = 0 },
        .{ .name = "write between identical reads makes earlier evidence stale", .steps = &.{ .{ .tool = "read", .args = A, .out = "x" }, .{ .tool = "write", .args = A, .out = "ok" }, .{ .tool = "read", .args = A, .out = "x" } }, .source = test_contracts.source, .denied = 1, .omitted = 0 },
        .{ .name = "write after the later copy makes both stale", .steps = &.{ .{ .tool = "read", .args = A, .out = "x" }, .{ .tool = "read", .args = A, .out = "x" }, .{ .tool = "write", .args = A, .out = "ok" } }, .source = test_contracts.source, .denied = 1, .omitted = 0 },
        .{ .name = "unknown tool in between counts as a state change", .steps = &.{ .{ .tool = "read", .args = A, .out = "x" }, .{ .tool = "mystery", .args = "{}", .out = "z" }, .{ .tool = "read", .args = A, .out = "x" } }, .source = test_contracts.source, .denied = 1, .omitted = 0 },
        .{ .name = "failed (including cancelled) results are never reusable", .steps = &.{ .{ .tool = "read", .args = A, .out = "cancelled", .status = .failure }, .{ .tool = "read", .args = A, .out = "cancelled", .status = .failure } }, .source = test_contracts.source, .denied = 1, .omitted = 0 },
        .{ .name = "changed result is not reused", .steps = &.{ .{ .tool = "read", .args = A, .out = "x" }, .{ .tool = "read", .args = A, .out = "y" } }, .source = test_contracts.source, .denied = 0, .omitted = 0 },
        .{ .name = "permitted but disabled leaves messages alone", .steps = &.{ .{ .tool = "read", .args = A, .out = "x" }, .{ .tool = "read", .args = A, .out = "x" } }, .source = test_contracts.source, .enabled = false, .denied = 0, .omitted = 0 },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const messages = try history(arena.allocator(), case.steps);
        const projection = try project(arena.allocator(), messages, case.source, case.enabled);
        std.testing.expectEqual(case.denied, projection.stats.denied) catch |err| {
            std.debug.print("case: {s}\n", .{case.name});
            return err;
        };
        std.testing.expectEqual(case.omitted, projection.stats.omitted) catch |err| {
            std.debug.print("case: {s}\n", .{case.name});
            return err;
        };
        if (case.omitted == 0) try std.testing.expect(projection.messages.ptr == messages.ptr);
    }
}

test "a new user turn invalidates earlier evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const first = try history(alloc, &.{.{ .tool = "read", .args = "{}", .out = "x" }});
    const second = try history(alloc, &.{.{ .tool = "read", .args = "{}", .out = "x" }});
    // history() starts with a user message, so concatenation has one per turn.
    const messages = try std.mem.concat(alloc, ChatMessage, &.{ first, second });
    // Call ids repeat across the two fixtures; give the second pair its own.
    messages[4].tool_calls = &.{.{ .id = "later", .name = "read", .arguments_json = "{}" }};
    messages[5].tool_call_id = "later";
    const projection = try project(alloc, messages, test_contracts.source, true);
    try std.testing.expectEqual(@as(usize, 0), projection.stats.omitted);
    try std.testing.expectEqual(@as(usize, 1), projection.stats.denied);
}

test "stored images are never omitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const messages = try history(alloc, &.{
        .{ .tool = "read", .args = "{}", .out = "x" },
        .{ .tool = "read", .args = "{}", .out = "x" },
    });
    messages[2].tool_result_memory = .{ .tool_image_handle = "image-1" };
    const projection = try project(alloc, messages, test_contracts.source, true);
    try std.testing.expectEqual(@as(usize, 0), projection.stats.omitted);
    try std.testing.expectEqual(@as(usize, 1), projection.stats.denied);
}

test "call reason is derived from the request tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const none = try history(alloc, &.{});
    try std.testing.expectEqual(CallReason.initial, callReason(none));
    try std.testing.expectEqual(CallReason.initial, callReason(&.{}));
    const ok = try history(alloc, &.{.{ .tool = "read", .args = "{}", .out = "x" }});
    try std.testing.expectEqual(CallReason.after_tools, callReason(ok));
    const failed = try history(alloc, &.{.{ .tool = "read", .args = "{}", .out = "e", .status = .failure }});
    try std.testing.expectEqual(CallReason.after_failed_tools, callReason(failed));
    // A batch with one success is not a pure failure.
    const mixed = try history(alloc, &.{
        .{ .tool = "read", .args = "{}", .out = "e", .status = .failure },
        .{ .tool = "read", .args = "{\"b\":1}", .out = "x" },
    });
    // Two separate steps end with a single success: after_tools.
    try std.testing.expectEqual(CallReason.after_tools, callReason(mixed));
}
