const std = @import("std");
const build_options = @import("build_options");
const acp_server = @import("acp/server.zig");
const jsonrpc = @import("acp/jsonrpc.zig");
const gateway_provider = @import("core/gateway/gateway_provider.zig");
const provider_set = @import("core/gateway/provider_set.zig");
const agent_steps = @import("core/config/agent_steps.zig");
const context_contract = @import("core/workspace/context_contract.zig");
const host = @import("core/hosts/host.zig");
const host_attachments = @import("core/hosts/host_attachments.zig");
const agent_checkpoint = @import("core/agent/runtime/checkpoint.zig");
const io_mod = @import("core/shared/io.zig");
const fetch_state = @import("napi_fetch_state.zig");
const streamable_http = @import("core/mcp/streamable_http.zig");
const host_stream_provider = @import("gateway/host_stream_provider.zig");
const oauth_transport = @import("core/auth/oauth_transport.zig");
const builtin_gateway = @import("builtins/gateway.zig");
const builtin_modes = @import("builtins/modes.zig");

const c = @cImport({
    @cInclude("node_api.h");
});

const napi_model = @import("napi_model_provider.zig");
const model_provider = @import("core/agent/model_provider.zig");

const Allocator = std.mem.Allocator;
const max_drain_bytes = 1024 * 1024;
const max_input_bytes = 8 * 1024 * 1024;
const max_output_bytes = 8 * 1024 * 1024;
const max_output_message_bytes = 64 * 1024 * 1024;
const max_fetch_request_bytes = 8 * 1024 * 1024;
const max_fetch_response_bytes = 8 * 1024 * 1024;
// One attachment holds one prompt image or one kernel checkpoint, the larger.
const max_attachment_bytes = agent_checkpoint.max_checkpoint_bytes;
const max_inbound_attachments = 8;
const max_inbound_attachment_bytes = 8 * 1024 * 1024;
const max_outbound_attachments = 4;
const max_outbound_attachment_bytes = 8 * 1024 * 1024;
const max_api_key_bytes = 64 * 1024;
const max_model_bytes = 1024;
// Matches types.ReasoningEffort.max_name_bytes.
const max_effort_bytes = 64;
const max_path_bytes = 16 * 1024;
const max_url_bytes = 16 * 1024;
const max_active_runtimes = 64;
const runtime_handle_type_tag = c.napi_type_tag{
    .lower = 0x4c4942465852544d,
    .upper = 0xa71d7c52e9314b08,
};

const ReadyNotifier = struct {
    reader: ?c_int,
    writer: c_int,

    fn init() error{ReadyChannelFailed}!ReadyNotifier {
        var pair: [2]c_int = undefined;
        const flags = if (@import("builtin").os.tag == .macos) 0 else std.c.SOCK.CLOEXEC | std.c.SOCK.NONBLOCK;
        const socket_type = std.c.SOCK.STREAM | flags;
        if (std.c.socketpair(std.c.AF.UNIX, socket_type, 0, &pair) != 0) return error.ReadyChannelFailed;
        errdefer for (pair) |fd| {
            _ = std.c.close(fd);
        };
        // Darwin does not accept close-on-exec/nonblocking bits in socketpair's type.
        if (flags == 0) for (pair) |fd| {
            if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) != 0 or
                std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true }))) != 0)
                return error.ReadyChannelFailed;
        };
        return .{ .reader = pair[0], .writer = pair[1] };
    }

    fn notify(self: *ReadyNotifier) void {
        const byte: u8 = 1;
        while (true) {
            const written = std.c.send(self.writer, &byte, 1, std.c.MSG.NOSIGNAL);
            if (written == 1) return;
            switch (std.posix.errno(written)) {
                .INTR => continue,
                // A full socket already has a wake pending; queue contents are authoritative.
                .AGAIN => return,
                else => {
                    // Surface a broken notification channel as EOF instead of silently hanging.
                    _ = std.c.shutdown(self.writer, std.c.SHUT.WR);
                    return;
                },
            }
        }
    }

    fn deinit(self: *ReadyNotifier) void {
        if (self.reader) |fd| _ = std.c.close(fd);
        _ = std.c.close(self.writer);
    }
};

comptime {
    if (build_options.napi_surface != .core) {
        @compileError("libfx N-API core requires -Dnapi-surface=core");
    }
}

const InputQueue = struct {
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    bytes: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    closed: bool = false,

    fn read(self: *InputQueue, alloc: Allocator, destination: []u8) usize {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.offset == self.bytes.items.len and !self.closed) {
            self.bytes.clearRetainingCapacity();
            self.offset = 0;
            self.wake.waitUncancelable(io, &self.mutex);
        }
        const available = self.bytes.items.len - self.offset;
        if (available == 0) return 0;
        const len = @min(destination.len, available);
        @memcpy(destination[0..len], self.bytes.items[self.offset..][0..len]);
        self.offset += len;
        if (self.offset == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.offset = 0;
        }
        _ = alloc;
        return len;
    }

    fn write(self: *InputQueue, alloc: Allocator, data: []const u8) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return error.InputClosed;
        const queued = self.bytes.items.len - self.offset;
        if (data.len > max_input_bytes or queued > max_input_bytes - data.len) return error.InputQueueFull;
        if (self.offset > 0) {
            std.mem.copyForwards(u8, self.bytes.items[0..queued], self.bytes.items[self.offset..]);
            self.bytes.items.len = queued;
            self.offset = 0;
        }
        try self.bytes.appendSlice(alloc, data);
        self.wake.signal(io);
    }

    fn close(self: *InputQueue) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.wake.broadcast(io);
        self.mutex.unlock(io);
    }

    fn deinit(self: *InputQueue, alloc: Allocator) void {
        self.bytes.deinit(alloc);
    }
};

const OutputQueue = struct {
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    bytes: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    ready: ?*ReadyNotifier = null,
    closed: bool = false,
    failed: bool = false,

    fn write(self: *OutputQueue, alloc: Allocator, data: []const u8) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        errdefer |err| if (err != error.OutputClosed) {
            self.failed = true;
            self.wake.broadcast(io);
            self.ready.?.notify();
        };
        if (data.len > max_output_message_bytes) return error.OutputMessageTooLarge;
        var written: usize = 0;
        while (written < data.len) {
            if (self.failed) return error.OutputFailed;
            if (self.closed) return error.OutputClosed;
            const queued = self.bytes.items.len - self.offset;
            if (queued == max_output_bytes) {
                self.wake.waitUncancelable(io, &self.mutex);
                continue;
            }
            if (self.offset > 0) {
                std.mem.copyForwards(u8, self.bytes.items[0..queued], self.bytes.items[self.offset..]);
                self.bytes.items.len = queued;
                self.offset = 0;
            }
            const len = @min(data.len - written, max_output_bytes - queued);
            const needed = queued + len;
            if (needed > self.bytes.capacity) {
                const capacity = @min(max_output_bytes, @max(needed, self.bytes.capacity + self.bytes.capacity / 2 + 8));
                try self.bytes.ensureTotalCapacityPrecise(alloc, capacity);
            }
            self.bytes.appendSliceAssumeCapacity(data[written..][0..len]);
            written += len;
            if (queued == 0) self.ready.?.notify();
        }
    }

    fn drain(self: *OutputQueue, destination: []u8) usize {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const available_bytes = self.bytes.items.len - self.offset;
        const len = @min(destination.len, available_bytes);
        if (len == 0) return 0;
        @memcpy(destination[0..len], self.bytes.items[self.offset..][0..len]);
        self.offset += len;
        if (self.offset == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.offset = 0;
        }
        self.wake.broadcast(io);
        return len;
    }

    fn available(self: *OutputQueue) !usize {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.failed) return error.OutputFailed;
        return self.bytes.items.len - self.offset;
    }

    fn close(self: *OutputQueue) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.closed = true;
        self.wake.broadcast(io);
    }

    fn deinit(self: *OutputQueue, alloc: Allocator) void {
        self.bytes.deinit(alloc);
    }
};

/// Raw payloads exchanged beside ACP frames. JavaScript writes inbound prompt
/// images and restore checkpoints; the core writes outbound checkpoints for
/// JavaScript to take. One mutex guards both maps, and every entry is owned by
/// the C allocator. The core thread never touches JavaScript values here.
const AttachmentTable = struct {
    mutex: std.Io.Mutex = .init,
    inbound: std.AutoHashMapUnmanaged(host_attachments.Id, []u8) = .empty,
    inbound_bytes: usize = 0,
    outbound: std.AutoHashMapUnmanaged(host_attachments.Id, []u8) = .empty,
    outbound_bytes: usize = 0,
    next_outbound: host_attachments.Id = 1,

    const WriteError = Allocator.Error || error{ AttachmentExists, AttachmentTooLarge, AttachmentTableFull };

    fn write(self: *AttachmentTable, id: host_attachments.Id, bytes: []const u8) WriteError!void {
        if (bytes.len > max_attachment_bytes) return error.AttachmentTooLarge;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.inbound.contains(id)) return error.AttachmentExists;
        if (self.inbound.count() >= max_inbound_attachments or
            bytes.len > max_inbound_attachment_bytes - self.inbound_bytes) return error.AttachmentTableFull;
        const owned = try std.heap.c_allocator.dupe(u8, bytes);
        errdefer std.heap.c_allocator.free(owned);
        try self.inbound.put(std.heap.c_allocator, id, owned);
        self.inbound_bytes += owned.len;
    }

    /// Removes outbound `id` for JavaScript. The caller frees the result with
    /// the C allocator.
    fn takeOutbound(self: *AttachmentTable, id: host_attachments.Id) ?[]u8 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const entry = self.outbound.fetchRemove(id) orelse return null;
        self.outbound_bytes -= entry.value.len;
        return entry.value;
    }

    /// Drops inbound payloads left by a prompt or restore that never reached
    /// the core. JavaScript calls this before attaching new payloads.
    fn discardInbound(self: *AttachmentTable) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        freeEntries(&self.inbound);
        self.inbound.clearRetainingCapacity();
        self.inbound_bytes = 0;
    }

    fn store(self: *AttachmentTable) host_attachments.Store {
        return .{ .context = self, .take_fn = coreTake, .put_fn = corePut };
    }

    fn coreTake(
        raw: ?*anyopaque,
        alloc: Allocator,
        id: host_attachments.Id,
        max_bytes: usize,
    ) host_attachments.TakeError![]u8 {
        const self: *AttachmentTable = @ptrCast(@alignCast(raw.?));
        const bytes = taken: {
            const io = io_mod.getIo();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const entry = self.inbound.fetchRemove(id) orelse return error.AttachmentUnavailable;
            self.inbound_bytes -= entry.value.len;
            break :taken entry.value;
        };
        defer std.heap.c_allocator.free(bytes);
        if (bytes.len > max_bytes) return error.AttachmentTooLarge;
        return alloc.dupe(u8, bytes);
    }

    fn corePut(raw: ?*anyopaque, bytes: []const u8) host_attachments.PutError!host_attachments.Id {
        const self: *AttachmentTable = @ptrCast(@alignCast(raw.?));
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (bytes.len > max_attachment_bytes or
            self.outbound.count() >= max_outbound_attachments or
            bytes.len > max_outbound_attachment_bytes - self.outbound_bytes) return error.AttachmentStoreFull;
        // At most max_outbound_attachments ids are in use, so this ends quickly.
        var id = self.next_outbound;
        while (self.outbound.contains(id)) id = nextAttachmentId(id);
        self.next_outbound = nextAttachmentId(id);
        const owned = try std.heap.c_allocator.dupe(u8, bytes);
        errdefer std.heap.c_allocator.free(owned);
        try self.outbound.put(std.heap.c_allocator, id, owned);
        self.outbound_bytes += owned.len;
        return id;
    }

    fn nextAttachmentId(id: host_attachments.Id) host_attachments.Id {
        return if (id == std.math.maxInt(host_attachments.Id)) 1 else id + 1;
    }

    fn freeEntries(map: *std.AutoHashMapUnmanaged(host_attachments.Id, []u8)) void {
        var values = map.valueIterator();
        while (values.next()) |bytes| std.heap.c_allocator.free(bytes.*);
    }

    fn deinit(self: *AttachmentTable) void {
        freeEntries(&self.inbound);
        freeEntries(&self.outbound);
        self.inbound.deinit(std.heap.c_allocator);
        self.outbound.deinit(std.heap.c_allocator);
    }
};

const FetchBridge = struct {
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    /// JSON metadata for the pending request. Its body stays raw beside it.
    request: std.ArrayList(u8) = .empty,
    request_body: std.ArrayList(u8) = .empty,
    response: std.ArrayList(u8) = .empty,
    response_offset: usize = 0,
    phase: fetch_state.Phase = .idle,
    next_handle: fetch_state.Handle = 1,
    status: u16 = 0,
    ready: ?*ReadyNotifier = null,

    fn clearPendingRequest(self: *FetchBridge) void {
        self.request.clearRetainingCapacity();
        self.request_body.clearRetainingCapacity();
    }

    fn advance_handle(self: *FetchBridge) void {
        self.next_handle = if (self.next_handle == std.math.maxInt(fetch_state.Handle))
            0
        else
            self.next_handle + 1;
    }

    fn open(raw: ?*anyopaque, method: []const u8, url: []const u8, headers: []const u8, body: []const u8) !i32 {
        const self: *FetchBridge = @ptrCast(@alignCast(raw.?));
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.next_handle == 0) return error.HostStreamUnavailable;
        const handle = self.next_handle;
        const decision = fetch_state.decide(self.phase, .{ .open = handle });
        switch (decision.action) {
            .unavailable, .shutting_down => return error.HostStreamUnavailable,
            .applied => {},
            else => unreachable,
        }
        if (body.len > max_fetch_request_bytes or method.len > max_fetch_request_bytes or
            url.len > max_fetch_request_bytes or headers.len > max_fetch_request_bytes)
            return error.HostStreamBackpressure;
        const request: struct {
            handle: fetch_state.Handle,
            method: []const u8,
            url: []const u8,
            headers: []const u8,
        } = .{
            .handle = handle,
            .method = method,
            .url = url,
            .headers = headers,
        };
        var writer: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer writer.deinit();
        try std.json.Stringify.value(request, .{}, &writer.writer);
        const metadata = writer.writer.buffered();
        // The body travels raw beside its metadata, and both share one budget.
        if (metadata.len > max_fetch_request_bytes - body.len) return error.HostStreamBackpressure;
        self.clearPendingRequest();
        try self.request.appendSlice(std.heap.c_allocator, metadata);
        try self.request_body.appendSlice(std.heap.c_allocator, body);
        self.response_offset = 0;
        self.response.clearRetainingCapacity();
        self.phase = decision.phase;
        self.advance_handle();
        self.wake.broadcast(io);
        self.ready.?.notify();
        return handle;
    }

    fn statusFn(raw: ?*anyopaque, handle: i32, status_out: *u16) i32 {
        const self: *FetchBridge = @ptrCast(@alignCast(raw.?));
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) switch (self.phase) {
            .request_pending, .awaiting_response => |active| {
                if (active != handle) return -2;
                self.wake.waitUncancelable(io, &self.mutex);
            },
            .streaming => |active| {
                if (active != handle) return -2;
                status_out.* = self.status;
                return 1;
            },
            .terminal => |terminal| {
                if (terminal.handle != handle) return -2;
                return switch (terminal.kind) {
                    .success => result: {
                        status_out.* = self.status;
                        break :result 1;
                    },
                    .failure => -1,
                    .aborted => -2,
                };
            },
            else => return -2,
        };
    }

    fn next(raw: ?*anyopaque, handle: i32, out: []u8) i32 {
        const self: *FetchBridge = @ptrCast(@alignCast(raw.?));
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) {
            const terminal_kind: ?fetch_state.TerminalKind = switch (self.phase) {
                .streaming => |active| if (active == handle) null else return -2,
                .terminal => |terminal| if (terminal.handle == handle) terminal.kind else return -2,
                else => return -2,
            };
            if (terminal_kind) |kind| switch (kind) {
                .failure => return -1,
                .aborted => return -2,
                .success => {},
            };
            const available = self.response.items.len - self.response_offset;
            if (available > 0) {
                const len = @min(out.len, available);
                @memcpy(out[0..len], self.response.items[self.response_offset..][0..len]);
                self.response_offset += len;
                self.wake.broadcast(io);
                return @intCast(len);
            }
            self.response.clearRetainingCapacity();
            self.response_offset = 0;
            if (terminal_kind != null) return 0;
            self.wake.waitUncancelable(io, &self.mutex);
        }
    }

    fn close(raw: ?*anyopaque, handle: i32) void {
        const self: *FetchBridge = @ptrCast(@alignCast(raw.?));
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const decision = fetch_state.decide(self.phase, .{ .close = handle });
        if (decision.action == .stale) return;
        self.clearPendingRequest();
        self.phase = decision.phase;
        self.status = 0;
        self.response.clearRetainingCapacity();
        self.response_offset = 0;
        self.wake.broadcast(io);
        self.ready.?.notify();
    }

    fn startResponse(self: *FetchBridge, handle: fetch_state.Handle, status: u16) FetchOperationResult {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const decision = fetch_state.decide(self.phase, .{ .start = handle });
        if (decision.action == .stale) return .stale;
        self.status = status;
        self.phase = decision.phase;
        self.wake.broadcast(io);
        return .applied;
    }

    fn pushResponse(self: *FetchBridge, handle: fetch_state.Handle, data: []const u8) !FetchOperationResult {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const decision = fetch_state.decide(self.phase, .{ .push = handle });
        if (decision.action == .stale) return .stale;
        const queued = self.response.items.len - self.response_offset;
        if (data.len > max_fetch_response_bytes or queued > max_fetch_response_bytes - data.len) return .backpressure;
        if (self.response_offset > 0) {
            std.mem.copyForwards(u8, self.response.items[0..queued], self.response.items[self.response_offset..]);
            self.response.items.len = queued;
            self.response_offset = 0;
        }
        try self.response.appendSlice(std.heap.c_allocator, data);
        self.wake.broadcast(io);
        return .applied;
    }

    fn finishResponse(self: *FetchBridge, handle: fetch_state.Handle) FetchOperationResult {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const decision = fetch_state.decide(self.phase, .{ .finish = handle });
        if (decision.action == .stale) return .stale;
        self.phase = decision.phase;
        self.wake.broadcast(io);
        return .applied;
    }

    fn failResponse(self: *FetchBridge, handle: fetch_state.Handle) FetchOperationResult {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const decision = fetch_state.decide(self.phase, .{ .fail = handle });
        if (decision.action == .stale) return .stale;
        self.phase = decision.phase;
        self.wake.broadcast(io);
        return .applied;
    }

    fn is_active(self: *FetchBridge, handle: fetch_state.Handle) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return fetch_state.is_active(self.phase, handle);
    }

    fn abort(self: *FetchBridge) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const decision = fetch_state.decide(self.phase, .cancel);
        self.clearPendingRequest();
        self.phase = decision.phase;
        self.wake.broadcast(io);
    }

    fn shutdown(self: *FetchBridge) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const decision = fetch_state.decide(self.phase, .shutdown);
        self.clearPendingRequest();
        self.phase = decision.phase;
        self.wake.broadcast(io);
    }

    fn deinit(self: *FetchBridge) void {
        self.request.deinit(std.heap.c_allocator);
        self.request_body.deinit(std.heap.c_allocator);
        self.response.deinit(std.heap.c_allocator);
    }
};

const FetchOperationResult = enum(u8) {
    stale = 0,
    applied = 1,
    backpressure = 2,
};

const Runtime = struct {
    alloc: Allocator,
    fetch: FetchBridge = .{},
    attachments: AttachmentTable = .{},
    stream_context: host_stream_provider.ProviderContext = undefined,
    input: InputQueue = .{},
    output: OutputQueue = .{},
    credential: []u8,
    model: ?[]u8,
    effort: ?[]u8,
    fast: ?bool,
    ultrafast: ?bool,
    home: []u8,
    workspace_root: []u8,
    gateway_chat_url: []u8,
    ready: ReadyNotifier,
    thread: std.Thread,
    exited: std.atomic.Value(bool) = .init(false),
    exit_code: std.atomic.Value(u8) = .init(0),

    fn readInput(context: ?*anyopaque, destination: []u8) usize {
        const self: *Runtime = @ptrCast(@alignCast(context.?));
        return self.input.read(self.alloc, destination);
    }

    fn writeOutput(context: ?*anyopaque, bytes: []const u8) !void {
        const self: *Runtime = @ptrCast(@alignCast(context.?));
        self.output.write(self.alloc, bytes) catch |err| {
            if (err != error.OutputClosed) {
                self.exit_code.store(1, .seq_cst);
                self.input.close();
                self.fetch.shutdown();
                self.ready.notify();
            }
            return err;
        };
    }

    fn run(self: *Runtime) void {
        const provider = gateway_provider.Provider{
            .oauth_transport = oauth_transport.unavailable_provider,
            .chat_url = builtin_gateway.provider.chat_url,
        };
        const providers = provider_set.gateway_only(.{
            .presentation = builtin_gateway.provider_bundle.presentation,
            .auth_strategy = .vercel,
            .fallback_model_capabilities_fn = builtin_gateway.provider_bundle.fallback_model_capabilities_fn,
            .agent_stream = host_stream_provider.provider(&self.stream_context),
            .model_catalog = @import("gateway/host_model_catalog.zig").provider(&self.stream_context.transport),
        });
        acp_server.runWithTransport(
            self.alloc,
            .{
                .default_model = builtin_gateway.default_model,
                .default_agent_step_limit = agent_steps.default_max_agent_steps,
                .gateway_retry_count = 0,
                .gateway_chat_url = self.gateway_chat_url,
                .gateway_models_path = builtin_gateway.models_path,
                .gateway_provider = provider,
                .provider_set = providers,
                .secret_store = host.unavailable_secret_store,
                .prompt_policy = .{ .system_prompt = "" },
                .ignored_list_entries = &.{},
                .max_list_entries = 0,
                .max_read_file_bytes = 0,
                .max_read_file_lines = 0,
                .max_read_file_line_len = 0,
                .max_command_output_bytes = 0,
                .max_tool_result_bytes = 64 * 1024,
                .max_history_turns = 100,
                .context_registry = .{ .default_provider = context_contract.empty_provider },
                .mode_registry = builtin_modes.registry,
                .credential_override = self.credential,
                .model_override = self.model,
                .effort_override = self.effort,
                .fast_override = self.fast,
                .ultrafast_override = self.ultrafast,
                .home_override = self.home,
                .workspace_root_override = self.workspace_root,
                .allow_acp_mcp = false,
                .allow_native_tools = false,
                .minimal_kernel = true,
                .host_attachments = self.attachments.store(),
            },
            jsonrpc.Reader.initCallback(self, Runtime.readInput),
            jsonrpc.Writer.initCallback(self, Runtime.writeOutput),
        ) catch {
            self.exit_code.store(1, .seq_cst);
        };
        self.exited.store(true, .seq_cst);
        self.ready.notify();
    }

    fn closeInput(self: *Runtime) void {
        self.output.close();
        self.input.close();
    }

    fn abortHostEffects(self: *Runtime) void {
        self.fetch.abort();
    }

    fn deinit(self: *Runtime) void {
        self.closeInput();
        self.fetch.shutdown();
        self.thread.join();
        self.ready.deinit();
        self.fetch.deinit();
        self.attachments.deinit();
        self.input.deinit(self.alloc);
        self.output.deinit(self.alloc);
        self.alloc.free(self.credential);
        if (self.model) |model| self.alloc.free(model);
        if (self.effort) |effort| self.alloc.free(effort);
        self.alloc.free(self.home);
        self.alloc.free(self.workspace_root);
        self.alloc.free(self.gateway_chat_url);
        self.alloc.destroy(self);
        releaseRuntimeSlot();
    }
};

const RuntimeHandle = struct {
    mutex: std.Io.Mutex = .init,
    runtime: ?*Runtime,
    cleanup_hook_registered: bool,

    fn unregisterCleanup(self: *RuntimeHandle, env: c.napi_env) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const registered = self.cleanup_hook_registered;
        self.cleanup_hook_registered = false;
        self.mutex.unlock(io);
        if (registered) _ = c.napi_remove_env_cleanup_hook(env, cleanupRuntimeHandle, self);
    }

    fn destroy(self: *RuntimeHandle) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const runtime = self.runtime;
        self.runtime = null;
        self.mutex.unlock(io);
        if (runtime) |value| value.deinit();
    }
};

fn cleanupRuntimeHandle(data: ?*anyopaque) callconv(.c) void {
    const handle: *RuntimeHandle = @ptrCast(@alignCast(data orelse return));
    const io = io_mod.getIo();
    handle.mutex.lockUncancelable(io);
    handle.cleanup_hook_registered = false;
    handle.mutex.unlock(io);
    handle.destroy();
}

var threaded_io: ?std.Io.Threaded = null;
var threaded_io_state: std.atomic.Value(u8) = .init(0);
var active_runtime_count: std.atomic.Value(usize) = .init(0);

fn claimRuntimeSlot() bool {
    var current = active_runtime_count.load(.acquire);
    while (current < max_active_runtimes) {
        if (active_runtime_count.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |observed| {
            current = observed;
        } else return true;
    }
    return false;
}

fn releaseRuntimeSlot() void {
    _ = active_runtime_count.fetchSub(1, .acq_rel);
}

fn ensureThreadedIo() void {
    if (threaded_io_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        threaded_io = std.Io.Threaded.init(std.heap.c_allocator, .{});
        io_mod.setIo(threaded_io.?.io());
        const raw_environ: io_mod.RawEnviron = @ptrCast(std.c.environ);
        io_mod.setRawEnviron(raw_environ);
        threaded_io_state.store(2, .release);
        return;
    }
    while (threaded_io_state.load(.acquire) != 2) std.atomic.spinLoopHint();
}

fn throw(env: c.napi_env, code: [*:0]const u8, message: [*:0]const u8) c.napi_value {
    _ = c.napi_throw_error(env, code, message);
    return null;
}

fn statusOk(env: c.napi_env, status: c.napi_status, message: [*:0]const u8) bool {
    if (status == c.napi_ok) return true;
    _ = c.napi_throw_error(env, "LIBFX_NAPI", message);
    return false;
}

fn callbackArgs(env: c.napi_env, info: c.napi_callback_info, argv: []c.napi_value) bool {
    var argc = argv.len;
    if (!statusOk(env, c.napi_get_cb_info(env, info, &argc, argv.ptr, null, null), "could not read arguments")) return false;
    if (argc == argv.len) return true;
    _ = c.napi_throw_type_error(env, "LIBFX_INVALID_ARGUMENT", "missing required argument");
    return false;
}

fn stringArg(env: c.napi_env, value: c.napi_value, alloc: Allocator, max_len: usize) ![]u8 {
    var len: usize = 0;
    if (c.napi_get_value_string_utf8(env, value, null, 0, &len) != c.napi_ok) return error.InvalidArgument;
    if (len > max_len) return error.ArgumentTooLong;
    const bytes = try alloc.alloc(u8, len + 1);
    errdefer alloc.free(bytes);
    var written: usize = 0;
    if (c.napi_get_value_string_utf8(env, value, bytes.ptr, bytes.len, &written) != c.napi_ok) return error.InvalidArgument;
    return bytes[0..written];
}

fn getNamedString(
    env: c.napi_env,
    object: c.napi_value,
    name: [*:0]const u8,
    alloc: Allocator,
    max_len: usize,
) !?[]u8 {
    var present = false;
    if (c.napi_has_named_property(env, object, name, &present) != c.napi_ok) {
        if (exceptionPending(env)) return error.JavaScriptException;
        return error.InvalidArgument;
    }
    if (!present) return null;
    var value: c.napi_value = undefined;
    if (c.napi_get_named_property(env, object, name, &value) != c.napi_ok) {
        if (exceptionPending(env)) return error.JavaScriptException;
        return error.InvalidArgument;
    }
    var value_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, value, &value_type) != c.napi_ok or value_type != c.napi_string) return error.InvalidArgument;
    return try stringArg(env, value, alloc, max_len);
}

fn getNamedBool(
    env: c.napi_env,
    object: c.napi_value,
    name: [*:0]const u8,
) !?bool {
    var present = false;
    if (c.napi_has_named_property(env, object, name, &present) != c.napi_ok) {
        if (exceptionPending(env)) return error.JavaScriptException;
        return error.InvalidArgument;
    }
    if (!present) return null;
    var value: c.napi_value = undefined;
    if (c.napi_get_named_property(env, object, name, &value) != c.napi_ok) {
        if (exceptionPending(env)) return error.JavaScriptException;
        return error.InvalidArgument;
    }
    var value_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, value, &value_type) != c.napi_ok or value_type != c.napi_boolean) return error.InvalidArgument;
    var result = false;
    if (c.napi_get_value_bool(env, value, &result) != c.napi_ok) return error.InvalidArgument;
    return result;
}

fn exceptionPending(env: c.napi_env) bool {
    var pending = false;
    return c.napi_is_exception_pending(env, &pending) == c.napi_ok and pending;
}

const CreateError = error{
    JavaScriptException,
    TooManyRuntimes,
    InvalidApiKey,
    InvalidModel,
    InvalidEffort,
    InvalidFast,
    InvalidUltrafast,
    InvalidHome,
    InvalidWorkspaceRoot,
    InvalidGatewayUrl,
    OutOfMemory,
    ThreadFailed,
    ReadyChannelFailed,
};

fn createRuntime(env: c.napi_env, options: c.napi_value) CreateError!*Runtime {
    if (!claimRuntimeSlot()) return error.TooManyRuntimes;
    errdefer releaseRuntimeSlot();
    const alloc = std.heap.c_allocator;
    const credential = getNamedString(env, options, "apiKey", alloc, max_api_key_bytes) catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidApiKey,
    };
    const api_key = credential orelse return error.InvalidApiKey;
    errdefer alloc.free(api_key);
    const model = getNamedString(env, options, "model", alloc, max_model_bytes) catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModel,
    };
    errdefer if (model) |value| alloc.free(value);
    const effort = getNamedString(env, options, "effort", alloc, max_effort_bytes) catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEffort,
    };
    errdefer if (effort) |value| alloc.free(value);
    const fast = getNamedBool(env, options, "fast") catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        else => return error.InvalidFast,
    };
    const ultrafast = getNamedBool(env, options, "ultrafast") catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        else => return error.InvalidUltrafast,
    };
    const home = (getNamedString(env, options, "home", alloc, max_path_bytes) catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidHome,
    }) orelse return error.InvalidHome;
    errdefer alloc.free(home);
    const workspace_root = (getNamedString(env, options, "workspaceRoot", alloc, max_path_bytes) catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidWorkspaceRoot,
    }) orelse return error.InvalidWorkspaceRoot;
    errdefer alloc.free(workspace_root);
    const gateway_chat_url = (getNamedString(env, options, "gatewayChatUrl", alloc, max_url_bytes) catch |err| switch (err) {
        error.JavaScriptException => return error.JavaScriptException,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidGatewayUrl,
    }) orelse (alloc.dupe(u8, builtin_gateway.default_chat_url) catch return error.OutOfMemory);
    errdefer alloc.free(gateway_chat_url);
    streamable_http.validateEndpoint(gateway_chat_url) catch return error.InvalidGatewayUrl;
    if (!std.mem.eql(u8, gateway_chat_url, builtin_gateway.default_chat_url)) {
        const uri = std.Uri.parse(gateway_chat_url) catch return error.InvalidGatewayUrl;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidGatewayUrl;
    }

    const runtime = alloc.create(Runtime) catch return error.OutOfMemory;
    errdefer alloc.destroy(runtime);
    var ready = try ReadyNotifier.init();
    errdefer ready.deinit();
    runtime.* = .{
        .alloc = alloc,
        .credential = api_key,
        .model = model,
        .effort = effort,
        .fast = fast,
        .ultrafast = ultrafast,
        .home = home,
        .workspace_root = workspace_root,
        .gateway_chat_url = gateway_chat_url,
        .ready = ready,
        .thread = undefined,
    };
    runtime.fetch.ready = &runtime.ready;
    runtime.output.ready = &runtime.ready;
    runtime.stream_context = host_stream_provider.initContext(builtin_gateway.buildAgentRequest, .{ .fixed = runtime.gateway_chat_url }, .{
        .context = &runtime.fetch,
        .open_fn = FetchBridge.open,
        .status_fn = FetchBridge.statusFn,
        .next_fn = FetchBridge.next,
        .close_fn = FetchBridge.close,
    });
    runtime.thread = std.Thread.spawn(.{}, Runtime.run, .{runtime}) catch return error.ThreadFailed;
    return runtime;
}

fn throwCreateError(env: c.napi_env, err: CreateError) c.napi_value {
    return switch (err) {
        error.JavaScriptException => null,
        error.TooManyRuntimes => throw(env, "LIBFX_NATIVE_LIMIT", "too many active native runtimes"),
        error.InvalidApiKey => throw(env, "LIBFX_INVALID_ARGUMENT", "apiKey is required and must be a bounded string"),
        error.InvalidModel => throw(env, "LIBFX_INVALID_ARGUMENT", "model must be a bounded string"),
        error.InvalidEffort => throw(env, "LIBFX_INVALID_ARGUMENT", "effort must be a bounded string"),
        error.InvalidFast => throw(env, "LIBFX_INVALID_ARGUMENT", "fast must be a boolean"),
        error.InvalidUltrafast => throw(env, "LIBFX_INVALID_ARGUMENT", "ultrafast must be a boolean"),
        error.InvalidHome => throw(env, "LIBFX_INVALID_ARGUMENT", "home is required and must be a bounded string"),
        error.InvalidWorkspaceRoot => throw(env, "LIBFX_INVALID_ARGUMENT", "workspaceRoot is required and must be a bounded string"),
        error.InvalidGatewayUrl => throw(env, "LIBFX_INVALID_ARGUMENT", "gatewayChatUrl must be a bounded string"),
        error.OutOfMemory => throw(env, "LIBFX_NATIVE_OOM", "could not allocate native runtime"),
        error.ThreadFailed => throw(env, "LIBFX_NATIVE_THREAD", "could not start native runtime thread"),
        error.ReadyChannelFailed => throw(env, "LIBFX_NATIVE_IO", "could not create native readiness channel"),
    };
}

fn finalizeRuntimeHandle(env: c.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const handle: *RuntimeHandle = @ptrCast(@alignCast(data orelse return));
    handle.unregisterCleanup(env);
    handle.destroy();
    std.heap.c_allocator.destroy(handle);
}

fn createCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    if (!callbackArgs(env, info, &argv)) return null;
    const runtime = createRuntime(env, argv[0]) catch |err| return throwCreateError(env, err);
    var runtime_owned = true;
    defer if (runtime_owned) runtime.deinit();
    const handle = std.heap.c_allocator.create(RuntimeHandle) catch
        return throw(env, "LIBFX_NATIVE_OOM", "could not allocate runtime handle");
    var handle_owned = true;
    defer if (handle_owned) {
        handle.unregisterCleanup(env);
        std.heap.c_allocator.destroy(handle);
    };
    handle.* = .{ .runtime = runtime, .cleanup_hook_registered = false };

    if (!statusOk(
        env,
        c.napi_add_env_cleanup_hook(env, cleanupRuntimeHandle, handle),
        "could not register native runtime cleanup",
    )) return null;
    handle.cleanup_hook_registered = true;

    var result: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_object(env, &result), "could not create runtime handle")) return null;
    if (!statusOk(
        env,
        c.napi_type_tag_object(env, result, &runtime_handle_type_tag),
        "could not brand runtime handle",
    )) return null;
    if (!statusOk(
        env,
        c.napi_wrap(env, result, handle, finalizeRuntimeHandle, null, null),
        "could not attach native runtime",
    )) return null;
    runtime_owned = false;
    handle_owned = false;
    return result;
}

fn runtimeHandleArg(env: c.napi_env, info: c.napi_callback_info, argv: []c.napi_value) ?*RuntimeHandle {
    if (!callbackArgs(env, info, argv)) return null;
    var branded = false;
    if (!statusOk(
        env,
        c.napi_check_object_type_tag(env, argv[0], &runtime_handle_type_tag, &branded),
        "could not validate runtime handle",
    )) return null;
    if (!branded) {
        _ = c.napi_throw_type_error(env, "LIBFX_INVALID_ARGUMENT", "invalid runtime handle");
        return null;
    }
    var context: ?*anyopaque = null;
    if (!statusOk(env, c.napi_unwrap(env, argv[0], &context), "invalid runtime handle")) return null;
    return @ptrCast(@alignCast(context orelse return null));
}

fn lockRuntime(env: c.napi_env, handle: *RuntimeHandle) ?*Runtime {
    handle.mutex.lockUncancelable(io_mod.getIo());
    const runtime = handle.runtime orelse {
        handle.mutex.unlock(io_mod.getIo());
        _ = c.napi_throw_error(env, "LIBFX_NATIVE_CLOSED", "native runtime is closed");
        return null;
    };
    return runtime;
}

fn unlockRuntime(handle: *RuntimeHandle) void {
    handle.mutex.unlock(io_mod.getIo());
}

fn takeCoreReadyFd(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    const reader = runtime.ready.reader orelse
        return throw(env, "LIBFX_INVALID_ARGUMENT", "readiness descriptor already transferred");
    var value: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_int32(env, reader, &value), "could not transfer readiness descriptor")) return null;
    runtime.ready.reader = null;
    return value;
}

fn fetch_handle_arg(env: c.napi_env, value: c.napi_value) ?fetch_state.Handle {
    var number: f64 = 0;
    if (c.napi_get_value_double(env, value, &number) != c.napi_ok or
        !std.math.isFinite(number) or
        number < 1 or
        number > @as(f64, @floatFromInt(std.math.maxInt(fetch_state.Handle))) or
        @floor(number) != number)
    {
        _ = c.napi_throw_type_error(env, "LIBFX_INVALID_ARGUMENT", "fetch handle must be a positive int32");
        return null;
    }
    return @intFromFloat(number);
}

fn fetch_operation_value(env: c.napi_env, result: FetchOperationResult) c.napi_value {
    var value: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_uint32(env, @intFromEnum(result), &value), "could not create fetch operation result")) return null;
    return value;
}

fn writeCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    var data: ?*anyopaque = null;
    var len: usize = 0;
    if (!statusOk(env, c.napi_get_buffer_info(env, argv[1], &data, &len), "write() requires a Buffer")) return null;
    const bytes = if (len == 0) &.{} else @as([*]const u8, @ptrCast(data orelse return throw(env, "LIBFX_NATIVE_IO", "Buffer data is unavailable")))[0..len];
    runtime.input.write(runtime.alloc, bytes) catch |err| return switch (err) {
        error.InputClosed => throw(env, "LIBFX_NATIVE_CLOSED", "native runtime input is closed"),
        error.InputQueueFull => throw(env, "LIBFX_NATIVE_BACKPRESSURE", "native runtime input queue is full"),
        error.OutOfMemory => throw(env, "LIBFX_NATIVE_OOM", "could not queue native input"),
    };
    var value: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &value);
    return value;
}

fn closeCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    runtime.closeInput();
    var value: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &value);
    return value;
}

fn drainCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    const available = runtime.output.available() catch
        return throw(env, "LIBFX_NATIVE_IO", "native output delivery failed");
    const len = @min(available, max_drain_bytes);
    var value: c.napi_value = undefined;
    var data: ?*anyopaque = null;
    if (!statusOk(env, c.napi_create_buffer(env, len, &data, &value), "could not allocate output Buffer")) return null;
    if (len == 0) return value;
    const written = runtime.output.drain(@as([*]u8, @ptrCast(data.?))[0..len]);
    if (written != len) return throw(env, "LIBFX_NATIVE_IO", "native output changed while draining");
    return value;
}

fn takeCoreFetch(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    const io = io_mod.getIo();
    runtime.fetch.mutex.lockUncancelable(io);
    defer runtime.fetch.mutex.unlock(io);
    const decision = fetch_state.decide(runtime.fetch.phase, .take_request);
    if (decision.action != .applied) return nullValue(env);
    // `request` is the JSON metadata record; `body` is the raw request body.
    var value: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_object(env, &value), "could not allocate fetch request")) return null;
    const request = bufferFromBytes(env, runtime.fetch.request.items, "could not allocate fetch request Buffer") orelse return null;
    const body = bufferFromBytes(env, runtime.fetch.request_body.items, "could not allocate fetch body Buffer") orelse return null;
    if (!statusOk(env, c.napi_set_named_property(env, value, "request", request), "could not publish fetch request")) return null;
    if (!statusOk(env, c.napi_set_named_property(env, value, "body", body), "could not publish fetch body")) return null;
    runtime.fetch.clearPendingRequest();
    runtime.fetch.phase = decision.phase;
    return value;
}

fn nullValue(env: c.napi_env) c.napi_value {
    var value: c.napi_value = undefined;
    _ = c.napi_get_null(env, &value);
    return value;
}

fn undefinedValue(env: c.napi_env) c.napi_value {
    var value: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &value);
    return value;
}

/// Copies `bytes` into a new Node Buffer. Returns null after throwing.
fn bufferFromBytes(env: c.napi_env, bytes: []const u8, message: [*:0]const u8) c.napi_value {
    var value: c.napi_value = undefined;
    var data: ?*anyopaque = null;
    if (!statusOk(env, c.napi_create_buffer(env, bytes.len, &data, &value), message)) return null;
    if (bytes.len > 0) @memcpy(@as([*]u8, @ptrCast(data.?))[0..bytes.len], bytes);
    return value;
}

fn attachmentIdArg(env: c.napi_env, value: c.napi_value) ?host_attachments.Id {
    var number: f64 = 0;
    if (c.napi_get_value_double(env, value, &number) != c.napi_ok or
        !std.math.isFinite(number) or
        number < 1 or
        number > @as(f64, @floatFromInt(std.math.maxInt(host_attachments.Id))) or
        @floor(number) != number)
    {
        _ = c.napi_throw_type_error(env, "LIBFX_INVALID_ARGUMENT", "attachment id must be a positive uint32");
        return null;
    }
    return @intFromFloat(number);
}

fn writeCoreAttachment(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [3]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const id = attachmentIdArg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    var data: ?*anyopaque = null;
    var len: usize = 0;
    if (!statusOk(env, c.napi_get_buffer_info(env, argv[2], &data, &len), "writeCoreAttachment() requires a Buffer")) return null;
    const bytes = if (len == 0) &.{} else @as([*]const u8, @ptrCast(data orelse return throw(env, "LIBFX_NATIVE_IO", "Buffer data is unavailable")))[0..len];
    runtime.attachments.write(id, bytes) catch |err| return switch (err) {
        error.AttachmentExists => throw(env, "LIBFX_INVALID_ARGUMENT", "attachment id is already pending"),
        error.AttachmentTooLarge => throw(env, "LIBFX_INVALID_ARGUMENT", "attachment exceeds the native attachment limit"),
        error.AttachmentTableFull => throw(env, "LIBFX_NATIVE_BACKPRESSURE", "native attachment table is full"),
        error.OutOfMemory => throw(env, "LIBFX_NATIVE_OOM", "could not store native attachment"),
    };
    return undefinedValue(env);
}

fn takeCoreAttachment(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const id = attachmentIdArg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    const bytes = runtime.attachments.takeOutbound(id) orelse return nullValue(env);
    defer std.heap.c_allocator.free(bytes);
    return bufferFromBytes(env, bytes, "could not allocate attachment Buffer");
}

fn discardCoreAttachments(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    runtime.attachments.discardInbound();
    return undefinedValue(env);
}

fn coreFetchActive(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    var value: c.napi_value = undefined;
    _ = c.napi_get_boolean(env, runtime.fetch.is_active(fetch_handle), &value);
    return value;
}

fn startCoreFetchResponse(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [3]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    var status: u32 = 0;
    if (c.napi_get_value_uint32(env, argv[2], &status) != c.napi_ok or status > std.math.maxInt(u16))
        return throw(env, "LIBFX_INVALID_ARGUMENT", "fetch response status must be a uint16");
    return fetch_operation_value(env, runtime.fetch.startResponse(fetch_handle, @intCast(status)));
}

fn pushCoreFetchResponse(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [3]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    var data: ?*anyopaque = null;
    var len: usize = 0;
    if (!statusOk(env, c.napi_get_buffer_info(env, argv[2], &data, &len), "fetch response chunk requires a Buffer")) return null;
    const bytes = if (len == 0) &.{} else @as([*]const u8, @ptrCast(data.?))[0..len];
    const result = runtime.fetch.pushResponse(fetch_handle, bytes) catch
        return throw(env, "LIBFX_NATIVE_OOM", "could not queue fetch response");
    return fetch_operation_value(env, result);
}

fn finishCoreFetch(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    return fetch_operation_value(env, runtime.fetch.finishResponse(fetch_handle));
}

fn failCoreFetch(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    return fetch_operation_value(env, runtime.fetch.failResponse(fetch_handle));
}

fn abortCoreFetch(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    runtime.abortHostEffects();
    var value: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &value);
    return value;
}

fn coreExited(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    var value: c.napi_value = undefined;
    _ = c.napi_get_boolean(env, runtime.exited.load(.seq_cst), &value);
    return value;
}

fn coreExitCode(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    var value: c.napi_value = undefined;
    _ = c.napi_create_uint32(env, runtime.exit_code.load(.seq_cst), &value);
    return value;
}

fn destroyCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    handle.unregisterCleanup(env);
    handle.destroy();
    var value: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &value);
    return value;
}

fn exportFunction(env: c.napi_env, exports: c.napi_value, name: [*:0]const u8, callback: c.napi_callback) bool {
    var function: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_function(env, name, c.NAPI_AUTO_LENGTH, callback, null, &function), "could not create addon function")) return false;
    return statusOk(env, c.napi_set_named_property(env, exports, name, function), "could not export addon function");
}

// Model API: a provider-neutral model call surface. Requests are parsed into
// arena-owned native values, run on the libuv pool, and delivered back either
// as one settled promise (modelChat) or as ordered stream events (modelStream).
const model_handle_type_tag = c.napi_type_tag{
    .lower = 0x4c494246584d4f44,
    .upper = 0x9b3e51d27a0c46f8,
};
const model_call_type_tag = c.napi_type_tag{
    .lower = 0x4c494246584d434c,
    .upper = 0x24c8e09f61b73d5a,
};
const max_model_messages = 4096;
const max_model_tools = 512;
const max_model_tool_calls = 512;
const max_model_role_bytes = 32;
const max_model_text_bytes = max_input_bytes;
const model_delivery_queue_size = 64;
const max_active_model_calls = 256;
var active_model_calls: std.atomic.Value(u32) = .init(0);

const ModelValueError = error{ JavaScriptException, InvalidArgument, ArgumentTooLong, OutOfMemory };

fn propertyError(env: c.napi_env) ModelValueError {
    return if (exceptionPending(env)) error.JavaScriptException else error.InvalidArgument;
}

fn objectValue(env: c.napi_env, value: c.napi_value) ModelValueError!c.napi_value {
    var value_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, value, &value_type) != c.napi_ok or value_type != c.napi_object) return error.InvalidArgument;
    return value;
}

/// Absent, undefined, and null properties are all reported as null.
fn optionalProperty(env: c.napi_env, object: c.napi_value, name: [*:0]const u8) ModelValueError!?c.napi_value {
    var present = false;
    if (c.napi_has_named_property(env, object, name, &present) != c.napi_ok) return propertyError(env);
    if (!present) return null;
    var value: c.napi_value = undefined;
    if (c.napi_get_named_property(env, object, name, &value) != c.napi_ok) return propertyError(env);
    var value_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, value, &value_type) != c.napi_ok) return error.InvalidArgument;
    if (value_type == c.napi_undefined or value_type == c.napi_null) return null;
    return value;
}

fn optionalStringProperty(env: c.napi_env, object: c.napi_value, name: [*:0]const u8, alloc: Allocator, max_len: usize) ModelValueError!?[]u8 {
    const value = try optionalProperty(env, object, name) orelse return null;
    var value_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, value, &value_type) != c.napi_ok or value_type != c.napi_string) return error.InvalidArgument;
    return stringArg(env, value, alloc, max_len) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ArgumentTooLong => error.ArgumentTooLong,
        else => error.InvalidArgument,
    };
}

fn requiredStringProperty(env: c.napi_env, object: c.napi_value, name: [*:0]const u8, alloc: Allocator, max_len: usize) ModelValueError![]u8 {
    return try optionalStringProperty(env, object, name, alloc, max_len) orelse error.InvalidArgument;
}

const ModelArray = struct {
    value: c.napi_value,
    len: u32,

    fn element(self: ModelArray, env: c.napi_env, index: usize) ModelValueError!c.napi_value {
        var item: c.napi_value = undefined;
        if (c.napi_get_element(env, self.value, @intCast(index), &item) != c.napi_ok) return propertyError(env);
        return objectValue(env, item);
    }
};

fn optionalArrayProperty(env: c.napi_env, object: c.napi_value, name: [*:0]const u8, max_len: u32) ModelValueError!?ModelArray {
    const value = try optionalProperty(env, object, name) orelse return null;
    var is_array = false;
    if (c.napi_is_array(env, value, &is_array) != c.napi_ok or !is_array) return error.InvalidArgument;
    var len: u32 = 0;
    if (c.napi_get_array_length(env, value, &len) != c.napi_ok) return error.InvalidArgument;
    if (len > max_len) return error.ArgumentTooLong;
    return .{ .value = value, .len = len };
}

fn parseModelToolCalls(env: c.napi_env, message: c.napi_value, alloc: Allocator) ModelValueError![]const model_provider.ToolCall {
    const array = try optionalArrayProperty(env, message, "tool_calls", max_model_tool_calls) orelse return &.{};
    const calls = try alloc.alloc(model_provider.ToolCall, array.len);
    for (calls, 0..) |*call, index| {
        const item = try array.element(env, index);
        call.* = .{
            .id = try requiredStringProperty(env, item, "id", alloc, max_model_bytes),
            .name = try requiredStringProperty(env, item, "name", alloc, max_model_bytes),
            .arguments_json = try requiredStringProperty(env, item, "arguments_json", alloc, max_model_text_bytes),
        };
    }
    return calls;
}

/// Copies every borrowed JavaScript value into the request arena.
fn parseModelRequest(env: c.napi_env, value: c.napi_value, request: *napi_model.Request) ModelValueError!void {
    const alloc = request.arena.allocator();
    const object = try objectValue(env, value);

    const message_array = try optionalArrayProperty(env, object, "messages", max_model_messages) orelse return error.InvalidArgument;
    const messages = try alloc.alloc(model_provider.Message, message_array.len);
    for (messages, 0..) |*message, index| {
        const item = try message_array.element(env, index);
        const role = try requiredStringProperty(env, item, "role", alloc, max_model_role_bytes);
        message.* = .{
            .role = napi_model.parseRole(role) orelse return error.InvalidArgument,
            .content = try optionalStringProperty(env, item, "content", alloc, max_model_text_bytes),
            .tool_call_id = try optionalStringProperty(env, item, "tool_call_id", alloc, max_model_bytes),
            .tool_calls = try parseModelToolCalls(env, item, alloc),
        };
    }
    request.messages = messages;

    if (try optionalArrayProperty(env, object, "tools", max_model_tools)) |tool_array| {
        const tools = try alloc.alloc(model_provider.Tool, tool_array.len);
        for (tools, 0..) |*tool, index| {
            const item = try tool_array.element(env, index);
            const schema_json = try requiredStringProperty(env, item, "input_schema_json", alloc, max_model_text_bytes);
            tool.* = .{
                .name = try requiredStringProperty(env, item, "name", alloc, max_model_bytes),
                .description = try optionalStringProperty(env, item, "description", alloc, max_model_text_bytes) orelse "",
                .input_schema = std.json.parseFromSliceLeaky(std.json.Value, alloc, schema_json, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidArgument,
                },
            };
        }
        request.tools = tools;
    }

    if (try optionalStringProperty(env, object, "tool_choice", alloc, max_model_role_bytes)) |choice| {
        request.tool_choice = napi_model.parseToolChoice(choice) orelse return error.InvalidArgument;
    }

    if (try optionalProperty(env, object, "max_output_tokens")) |limit| {
        var number: f64 = 0;
        if (c.napi_get_value_double(env, limit, &number) != c.napi_ok) return error.InvalidArgument;
        if (!(number >= 1 and number <= std.math.maxInt(u32)) or @floor(number) != number) return error.InvalidArgument;
        request.max_output_tokens = @intFromFloat(number);
    }
}

fn throwModelArgument(env: c.napi_env, err: ModelValueError, message: [*:0]const u8) c.napi_value {
    switch (err) {
        error.JavaScriptException => if (exceptionPending(env)) return null,
        error.OutOfMemory => return throw(env, "LIBFX_NATIVE_OOM", message),
        else => {},
    }
    _ = c.napi_throw_type_error(env, "LIBFX_INVALID_ARGUMENT", message);
    return null;
}

fn wrapModelObject(env: c.napi_env, data: *anyopaque, tag: *const c.napi_type_tag, finalize: c.napi_finalize) ?c.napi_value {
    var result: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_object(env, &result), "could not create model handle")) return null;
    if (!statusOk(env, c.napi_type_tag_object(env, result, tag), "could not brand model handle")) return null;
    if (!statusOk(env, c.napi_wrap(env, result, data, finalize, null, null), "could not attach model handle")) return null;
    return result;
}

fn unwrapModelObject(comptime T: type, env: c.napi_env, value: c.napi_value, tag: *const c.napi_type_tag, message: [*:0]const u8) ?*T {
    var value_type: c.napi_valuetype = undefined;
    var branded = false;
    if (c.napi_typeof(env, value, &value_type) != c.napi_ok or value_type != c.napi_object or
        c.napi_check_object_type_tag(env, value, tag, &branded) != c.napi_ok or !branded)
    {
        _ = c.napi_throw_type_error(env, "LIBFX_INVALID_ARGUMENT", message);
        return null;
    }
    var context: ?*anyopaque = null;
    if (!statusOk(env, c.napi_unwrap(env, value, &context), message)) return null;
    return @ptrCast(@alignCast(context orelse return null));
}

fn finalizeModelHandle(_: c.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const handle: *napi_model.ModelHandle = @ptrCast(@alignCast(data orelse return));
    handle.release();
}

fn finalizeModelCall(_: c.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const call: *napi_model.Call = @ptrCast(@alignCast(data orelse return));
    call.release();
}

fn createModel(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    if (!callbackArgs(env, info, &argv)) return null;
    var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch.deinit();
    const alloc = scratch.allocator();
    const config = objectValue(env, argv[0]) catch |err| return throwModelArgument(env, err, "model configuration must be an object");
    const id = requiredStringProperty(env, config, "id", alloc, max_model_bytes) catch |err| return throwModelArgument(env, err, "invalid model id");
    const base_url = requiredStringProperty(env, config, "baseUrl", alloc, max_url_bytes) catch |err| return throwModelArgument(env, err, "invalid model baseUrl");
    const model = requiredStringProperty(env, config, "model", alloc, max_model_bytes) catch |err| return throwModelArgument(env, err, "invalid model name");
    const api_key_env = optionalStringProperty(env, config, "apiKeyEnv", alloc, max_model_bytes) catch |err| return throwModelArgument(env, err, "invalid model apiKeyEnv");
    const mode_name = optionalStringProperty(env, config, "toolChoiceMode", alloc, max_model_role_bytes) catch |err| return throwModelArgument(env, err, "invalid model toolChoiceMode");
    const tool_choice_mode = if (mode_name) |name|
        napi_model.parseToolChoiceMode(name) orelse return throwModelArgument(env, error.InvalidArgument, "toolChoiceMode must be omit or send")
    else
        .omit;

    const handle = napi_model.ModelHandle.create(std.heap.c_allocator, id, base_url, model, api_key_env, tool_choice_mode) catch |err| switch (err) {
        error.OutOfMemory => return throw(env, "LIBFX_NATIVE_OOM", "could not allocate model handle"),
        else => return throw(env, "LIBFX_INVALID_MODEL_CONFIG", @errorName(err)),
    };
    return wrapModelObject(env, handle, &model_handle_type_tag, finalizeModelHandle) orelse {
        handle.release();
        return null;
    };
}

fn createModelCall(env: c.napi_env, _: c.napi_callback_info) callconv(.c) c.napi_value {
    const call = napi_model.Call.create(std.heap.c_allocator) catch return throw(env, "LIBFX_NATIVE_OOM", "could not allocate model call");
    return wrapModelObject(env, call, &model_call_type_tag, finalizeModelCall) orelse {
        call.release();
        return null;
    };
}

fn cancelModelCall(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    if (!callbackArgs(env, info, &argv)) return null;
    const call = unwrapModelObject(napi_model.Call, env, argv[0], &model_call_type_tag, "invalid model call") orelse return null;
    call.cancel();
    return undefinedValue(env);
}

const ModelResultError = error{NapiFailed};

fn checked(status: c.napi_status) ModelResultError!void {
    if (status != c.napi_ok) return error.NapiFailed;
}

fn modelObject(env: c.napi_env) ModelResultError!c.napi_value {
    var value: c.napi_value = undefined;
    try checked(c.napi_create_object(env, &value));
    return value;
}

fn modelString(env: c.napi_env, text: []const u8) ModelResultError!c.napi_value {
    var value: c.napi_value = undefined;
    try checked(c.napi_create_string_utf8(env, text.ptr, text.len, &value));
    return value;
}

fn modelNull(env: c.napi_env) ModelResultError!c.napi_value {
    var value: c.napi_value = undefined;
    try checked(c.napi_get_null(env, &value));
    return value;
}

fn modelOptionalString(env: c.napi_env, text: ?[]const u8) ModelResultError!c.napi_value {
    return if (text) |value| modelString(env, value) else modelNull(env);
}

fn modelOptionalNumber(env: c.napi_env, number: ?u64) ModelResultError!c.napi_value {
    const raw = number orelse return modelNull(env);
    var value: c.napi_value = undefined;
    try checked(c.napi_create_double(env, @floatFromInt(raw), &value));
    return value;
}

fn modelSet(env: c.napi_env, object: c.napi_value, name: [*:0]const u8, value: c.napi_value) ModelResultError!void {
    try checked(c.napi_set_named_property(env, object, name, value));
}

fn modelError(env: c.napi_env, code: []const u8, message: []const u8) ?c.napi_value {
    const code_value = modelString(env, code) catch return null;
    const message_value = modelString(env, message) catch return null;
    var value: c.napi_value = undefined;
    if (c.napi_create_error(env, code_value, message_value, &value) != c.napi_ok) return null;
    return value;
}

/// Transport and runtime errors become JavaScript Errors with a stable code.
/// Provider-reported failures are values, not errors; see failureValue.
fn modelErrorValue(env: c.napi_env, err: anyerror) ?c.napi_value {
    return switch (err) {
        error.Cancelled => modelError(env, "LIBFX_MODEL_CANCELLED", "model call was cancelled"),
        error.Timeout => modelError(env, "LIBFX_MODEL_TIMEOUT", "model call timed out"),
        error.MissingConfiguredProviderCredential => modelError(env, "LIBFX_MODEL_CREDENTIAL_MISSING", "the model apiKeyEnv variable is not set"),
        error.InvalidConfiguredProviderCredential => modelError(env, "LIBFX_MODEL_CREDENTIAL_INVALID", "the model apiKeyEnv variable holds an invalid credential"),
        error.OutOfMemory => modelError(env, "LIBFX_NATIVE_OOM", "model call ran out of memory"),
        else => modelError(env, "LIBFX_MODEL_REQUEST_FAILED", @errorName(err)),
    };
}

fn completionValue(env: c.napi_env, completion: model_provider.Completion) ModelResultError!c.napi_value {
    const object = try modelObject(env);
    try modelSet(env, object, "content", try modelOptionalString(env, completion.content));
    var calls: c.napi_value = undefined;
    try checked(c.napi_create_array_with_length(env, completion.tool_calls.len, &calls));
    for (completion.tool_calls, 0..) |tool_call, index| {
        const item = try modelObject(env);
        try modelSet(env, item, "id", try modelString(env, tool_call.id));
        try modelSet(env, item, "name", try modelString(env, tool_call.name));
        try modelSet(env, item, "arguments_json", try modelString(env, tool_call.arguments_json));
        try checked(c.napi_set_element(env, calls, @intCast(index), item));
    }
    try modelSet(env, object, "tool_calls", calls);
    const finish_reason: ?[]const u8 = if (completion.finish_reason) |reason| @tagName(reason) else null;
    try modelSet(env, object, "finish_reason", try modelOptionalString(env, finish_reason));
    try modelSet(env, object, "response_id", try modelOptionalString(env, completion.response_id));
    const usage = try modelObject(env);
    try modelSet(env, usage, "input_tokens", try modelOptionalNumber(env, completion.usage.input_tokens));
    try modelSet(env, usage, "output_tokens", try modelOptionalNumber(env, completion.usage.output_tokens));
    try modelSet(env, usage, "cache_read_tokens", try modelOptionalNumber(env, completion.usage.cache_read_tokens));
    try modelSet(env, usage, "cache_write_tokens", try modelOptionalNumber(env, completion.usage.cache_write_tokens));
    try modelSet(env, usage, "reasoning_tokens", try modelOptionalNumber(env, completion.usage.reasoning_tokens));
    try modelSet(env, object, "usage", usage);
    return object;
}

fn failureValue(env: c.napi_env, failure: model_provider.Failure) ModelResultError!c.napi_value {
    const object = try modelObject(env);
    try modelSet(env, object, "kind", try modelString(env, @tagName(failure.kind)));
    try modelSet(env, object, "detail", try modelOptionalString(env, failure.detail));
    try modelSet(env, object, "retry_after_seconds", try modelOptionalNumber(env, failure.retry_after_seconds));
    return object;
}

fn chatResultValue(env: c.napi_env, stream: model_provider.ChatStream) ModelResultError!c.napi_value {
    const object = try modelObject(env);
    switch (stream) {
        .completed => |completion| try modelSet(env, object, "completed", try completionValue(env, completion)),
        .failed => |failure| try modelSet(env, object, "failed", try failureValue(env, failure)),
    }
    return object;
}

fn modelConversionError(env: c.napi_env) c.napi_value {
    var exception: c.napi_value = undefined;
    if (exceptionPending(env) and c.napi_get_and_clear_last_exception(env, &exception) == c.napi_ok) return exception;
    return modelError(env, "LIBFX_NATIVE", "could not convert model result") orelse undefinedValue(env);
}

fn claimModelCallSlot() bool {
    var current = active_model_calls.load(.acquire);
    while (current < max_active_model_calls) {
        if (active_model_calls.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |observed| {
            current = observed;
        } else return true;
    }
    return false;
}

fn releaseModelCallSlot() void {
    _ = active_model_calls.fetchSub(1, .acq_rel);
}

const ModelStreamItem = struct {
    event: union(enum) {
        text_delta: []u8,
        reasoning_delta: []u8,
        finished: model_provider.ChatStream,
        failed: anyerror,
    },

    fn create(event: @FieldType(ModelStreamItem, "event")) !*ModelStreamItem {
        const self = try std.heap.c_allocator.create(ModelStreamItem);
        self.* = .{ .event = event };
        return self;
    }

    fn destroy(self: *ModelStreamItem) void {
        switch (self.event) {
            .text_delta, .reasoning_delta => |text| std.heap.c_allocator.free(text),
            .finished => |*stream| stream.deinit(std.heap.c_allocator),
            .failed => {},
        }
        std.heap.c_allocator.destroy(self);
    }
};

/// One provider call. Model calls run on their own native thread rather than
/// the libuv pool: a long stream would otherwise starve Node's file system,
/// DNS, and crypto work, and Node waits for pool work before tearing down a
/// worker. Results reach JavaScript through a thread-safe function whose
/// finalizer cancels the call, joins the thread, and frees this work.
const ModelWork = struct {
    handle: *napi_model.ModelHandle,
    call: *napi_model.Call,
    request: napi_model.Request,
    streaming: bool,
    terminal: ?*ModelStreamItem,
    delivery: c.napi_threadsafe_function = null,
    deferred: c.napi_deferred = null,
    thread: ?std.Thread = null,
    // Worker-thread state: napi_closing already released this thread's reference.
    delivery_closed: bool = false,

    fn create(handle: *napi_model.ModelHandle, call: *napi_model.Call, streaming: bool) !*ModelWork {
        const self = try std.heap.c_allocator.create(ModelWork);
        errdefer std.heap.c_allocator.destroy(self);
        // The terminal event is allocated up front so every call can always end.
        const terminal = try ModelStreamItem.create(.{ .failed = error.Cancelled });
        handle.retain();
        call.retain();
        self.* = .{
            .handle = handle,
            .call = call,
            .request = .init(std.heap.c_allocator),
            .streaming = streaming,
            .terminal = terminal,
        };
        return self;
    }

    fn destroy(self: *ModelWork) void {
        if (self.terminal) |item| item.destroy();
        self.request.deinit();
        self.call.release();
        self.handle.release();
        std.heap.c_allocator.destroy(self);
    }

    /// Worker thread only. Blocks while the JavaScript queue is full.
    fn deliver(self: *ModelWork, item: *ModelStreamItem) void {
        if (!self.delivery_closed) switch (c.napi_call_threadsafe_function(self.delivery, item, c.napi_tsfn_blocking)) {
            c.napi_ok => return,
            c.napi_closing => self.delivery_closed = true,
            else => {},
        };
        item.destroy();
        // A consumer that can no longer receive events must not keep the provider running.
        self.call.cancel();
    }
};

/// Copies each provider delta, because EventSink text is borrowed only for
/// the synchronous emit, then posts it to JavaScript in provider order.
const ModelStreamSink = struct {
    work: *ModelWork,

    fn emit(raw: *anyopaque, event: model_provider.Event) void {
        const self: *ModelStreamSink = @ptrCast(@alignCast(raw));
        if (self.work.delivery_closed) return;
        const item = switch (event) {
            .content_delta => |text| itemForText(.text_delta, text),
            .reasoning_delta => |text| itemForText(.reasoning_delta, text),
        } catch return self.work.call.cancel();
        self.work.deliver(item);
    }

    fn itemForText(comptime kind: enum { text_delta, reasoning_delta }, text: []const u8) !*ModelStreamItem {
        const copy = try std.heap.c_allocator.dupe(u8, text);
        errdefer std.heap.c_allocator.free(copy);
        return ModelStreamItem.create(switch (kind) {
            .text_delta => .{ .text_delta = copy },
            .reasoning_delta => .{ .reasoning_delta = copy },
        });
    }
};

fn runModelWork(work: *ModelWork) void {
    var sink: ModelStreamSink = .{ .work = work };
    const events: ?model_provider.EventSink = if (work.streaming)
        .{ .context = &sink, .emit_fn = ModelStreamSink.emit }
    else
        null;
    const outcome = work.handle.run(std.heap.c_allocator, &work.request, work.call, events);
    const terminal = work.terminal.?;
    work.terminal = null;
    terminal.event = if (outcome) |stream| .{ .finished = stream } else |err| .{ .failed = err };
    work.deliver(terminal);
    if (!work.delivery_closed) _ = c.napi_release_threadsafe_function(work.delivery, c.napi_tsfn_release);
}

/// Runs on the JavaScript thread after the queue drains, or during environment
/// teardown while the provider may still be waiting on the network.
fn finalizeModelWork(_: c.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const work: *ModelWork = @ptrCast(@alignCast(data orelse return));
    work.call.cancel();
    if (work.thread) |thread| thread.join();
    work.destroy();
    releaseModelCallSlot();
}

fn settleModelChat(env: c.napi_env, deferred: c.napi_deferred, item: *const ModelStreamItem) void {
    const value = switch (item.event) {
        .finished => |stream| chatResultValue(env, stream) catch {
            _ = c.napi_reject_deferred(env, deferred, modelConversionError(env));
            return;
        },
        .failed => |err| {
            _ = c.napi_reject_deferred(env, deferred, modelErrorValue(env, err) orelse modelConversionError(env));
            return;
        },
        .text_delta, .reasoning_delta => return,
    };
    _ = c.napi_resolve_deferred(env, deferred, value);
}

fn streamEventValue(env: c.napi_env, item: *const ModelStreamItem) ModelResultError!c.napi_value {
    const object = try modelObject(env);
    switch (item.event) {
        .text_delta => |text| {
            try modelSet(env, object, "type", try modelString(env, "text_delta"));
            try modelSet(env, object, "text", try modelString(env, text));
        },
        .reasoning_delta => |text| {
            try modelSet(env, object, "type", try modelString(env, "reasoning_delta"));
            try modelSet(env, object, "text", try modelString(env, text));
        },
        .finished => |stream| switch (stream) {
            .completed => |completion| {
                try modelSet(env, object, "type", try modelString(env, "completion"));
                try modelSet(env, object, "completion", try completionValue(env, completion));
            },
            .failed => |failure| {
                try modelSet(env, object, "type", try modelString(env, "failure"));
                try modelSet(env, object, "failure", try failureValue(env, failure));
            },
        },
        .failed => |err| {
            try modelSet(env, object, "type", try modelString(env, "error"));
            try modelSet(env, object, "error", modelErrorValue(env, err) orelse return error.NapiFailed);
        },
    }
    return object;
}

fn deliverModelEvent(env: c.napi_env, callback: c.napi_value, context: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const item: *ModelStreamItem = @ptrCast(@alignCast(data orelse return));
    defer item.destroy();
    // A null environment means teardown; the work may already be freed.
    if (env == null) return;
    const work: *ModelWork = @ptrCast(@alignCast(context orelse return));
    if (!work.streaming) {
        if (work.deferred) |deferred| settleModelChat(env, deferred, item);
        return;
    }
    const event = streamEventValue(env, item) catch fallback: {
        _ = modelConversionError(env);
        const fallback = modelObject(env) catch return;
        modelSet(env, fallback, "type", modelString(env, "error") catch return) catch return;
        modelSet(env, fallback, "error", modelError(env, "LIBFX_NATIVE", "could not convert model event") orelse return) catch return;
        break :fallback fallback;
    };
    var receiver: c.napi_value = undefined;
    if (c.napi_get_undefined(env, &receiver) != c.napi_ok) return;
    _ = c.napi_call_function(env, receiver, callback, 1, &event, null);
}

fn prepareModelWork(env: c.napi_env, model_value: c.napi_value, call_value: c.napi_value, request_value: c.napi_value, streaming: bool) ?*ModelWork {
    const handle = unwrapModelObject(napi_model.ModelHandle, env, model_value, &model_handle_type_tag, "invalid model handle") orelse return null;
    const call = unwrapModelObject(napi_model.Call, env, call_value, &model_call_type_tag, "invalid model call") orelse return null;
    if (!claimModelCallSlot()) {
        _ = throw(env, "LIBFX_MODEL_CALL_LIMIT", "too many model calls are in flight");
        return null;
    }
    const work = ModelWork.create(handle, call, streaming) catch {
        releaseModelCallSlot();
        _ = throw(env, "LIBFX_NATIVE_OOM", "could not allocate model call");
        return null;
    };
    parseModelRequest(env, request_value, &work.request) catch |err| {
        work.destroy();
        releaseModelCallSlot();
        _ = throwModelArgument(env, err, "invalid model request");
        return null;
    };
    return work;
}

/// Hands the work to its delivery finalizer and starts the provider thread.
/// On failure the work is released and a JavaScript exception is pending.
fn startModelWork(env: c.napi_env, work: *ModelWork, callback: c.napi_value) bool {
    var name: c.napi_value = undefined;
    if (c.napi_create_string_utf8(env, "libfx.model", c.NAPI_AUTO_LENGTH, &name) != c.napi_ok or
        c.napi_create_threadsafe_function(env, callback, null, name, model_delivery_queue_size, 1, work, finalizeModelWork, work, deliverModelEvent, &work.delivery) != c.napi_ok)
    {
        work.destroy();
        releaseModelCallSlot();
        _ = throw(env, "LIBFX_NAPI", "could not create model call");
        return false;
    }
    work.thread = std.Thread.spawn(.{}, runModelWork, .{work}) catch {
        _ = c.napi_release_threadsafe_function(work.delivery, c.napi_tsfn_release);
        _ = throw(env, "LIBFX_NATIVE_THREAD", "could not start model call");
        return false;
    };
    return true;
}

/// modelChat(model, call, request) resolves { completed } or { failed } and
/// rejects with a coded Error for cancellation and transport failures.
fn modelChat(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [3]c.napi_value = undefined;
    if (!callbackArgs(env, info, &argv)) return null;
    const work = prepareModelWork(env, argv[0], argv[1], argv[2], false) orelse return null;
    if (!startModelWork(env, work, null)) return null;
    // The result is delivered on this thread, so the deferred is always set first.
    var promise: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_promise(env, &work.deferred, &promise), "could not create model promise")) {
        work.call.cancel();
        return null;
    }
    return promise;
}

/// modelStream(model, call, request, onEvent) delivers text_delta and
/// reasoning_delta events in provider order, then exactly one terminal
/// completion, failure, or error event.
fn modelStream(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [4]c.napi_value = undefined;
    if (!callbackArgs(env, info, &argv)) return null;
    var callback_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, argv[3], &callback_type) != c.napi_ok or callback_type != c.napi_function) {
        _ = c.napi_throw_type_error(env, "LIBFX_INVALID_ARGUMENT", "model stream requires an event callback");
        return null;
    }
    const work = prepareModelWork(env, argv[0], argv[1], argv[2], true) orelse return null;
    if (!startModelWork(env, work, argv[3])) return null;
    return undefinedValue(env);
}

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) callconv(.c) c.napi_value {
    ensureThreadedIo();
    var api_version: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_uint32(env, 4, &api_version), "could not create API version")) return null;
    if (!statusOk(env, c.napi_set_named_property(env, exports, "libfxApiVersion", api_version), "could not export API version")) return null;
    var supports_ultrafast: c.napi_value = undefined;
    if (!statusOk(env, c.napi_get_boolean(env, true, &supports_ultrafast), "could not create ultrafast capability")) return null;
    if (!statusOk(env, c.napi_set_named_property(env, exports, "supportsUltrafast", supports_ultrafast), "could not export ultrafast capability")) return null;
    if (!exportFunction(env, exports, "createCore", createCore)) return null;
    if (!exportFunction(env, exports, "takeCoreReadyFd", takeCoreReadyFd)) return null;
    if (!exportFunction(env, exports, "writeCore", writeCore)) return null;
    if (!exportFunction(env, exports, "closeCore", closeCore)) return null;
    if (!exportFunction(env, exports, "drainCore", drainCore)) return null;
    if (!exportFunction(env, exports, "writeCoreAttachment", writeCoreAttachment)) return null;
    if (!exportFunction(env, exports, "takeCoreAttachment", takeCoreAttachment)) return null;
    if (!exportFunction(env, exports, "discardCoreAttachments", discardCoreAttachments)) return null;
    if (!exportFunction(env, exports, "takeCoreFetch", takeCoreFetch)) return null;
    if (!exportFunction(env, exports, "coreFetchActive", coreFetchActive)) return null;
    if (!exportFunction(env, exports, "startCoreFetchResponse", startCoreFetchResponse)) return null;
    if (!exportFunction(env, exports, "pushCoreFetchResponse", pushCoreFetchResponse)) return null;
    if (!exportFunction(env, exports, "finishCoreFetch", finishCoreFetch)) return null;
    if (!exportFunction(env, exports, "failCoreFetch", failCoreFetch)) return null;
    if (!exportFunction(env, exports, "abortCoreFetch", abortCoreFetch)) return null;
    if (!exportFunction(env, exports, "coreExited", coreExited)) return null;
    if (!exportFunction(env, exports, "coreExitCode", coreExitCode)) return null;
    if (!exportFunction(env, exports, "destroyCore", destroyCore)) return null;
    if (!exportFunction(env, exports, "createModel", createModel)) return null;
    if (!exportFunction(env, exports, "createModelCall", createModelCall)) return null;
    if (!exportFunction(env, exports, "cancelModelCall", cancelModelCall)) return null;
    if (!exportFunction(env, exports, "modelChat", modelChat)) return null;
    if (!exportFunction(env, exports, "modelStream", modelStream)) return null;
    return exports;
}
