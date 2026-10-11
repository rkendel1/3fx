//! Composition for the optional AppBoundry provider: reads configuration from
//! the environment, performs the bounded discovery request, and appends the
//! discovered MCP servers to the profile server list.

const std = @import("std");
const appboundry = @import("../core/mcp/appboundry.zig");
const mcp_contract = @import("../core/mcp/mcp_contract.zig");
const streamable_http = @import("../core/mcp/streamable_http.zig");
const gateway_client = @import("../gateway/client.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;
const McpServerConfig = mcp_contract.McpServerConfig;

/// Appends one server per running AppBoundry application, unless the provider
/// is unconfigured or disabled. Never fails the caller for provider problems:
/// an unavailable host leaves every other server untouched.
pub fn appendDiscoveredServers(
    alloc: Allocator,
    configs: *std.ArrayList(McpServerConfig),
) Allocator.Error!void {
    const base_url = io_mod.getenv(appboundry.url_env) orelse return;
    if (base_url.len == 0 or isTruthy(io_mod.getenv(appboundry.disable_env))) return;

    const filter = if (io_mod.getenv(appboundry.apps_env)) |raw|
        try appboundry.parseAppFilter(alloc, raw)
    else
        try alloc.alloc([]const u8, 0);
    defer alloc.free(filter);
    const settings: appboundry.Settings = .{
        .base_url = base_url,
        .apps = filter,
        .allow_local_http = isTruthy(io_mod.getenv(appboundry.allow_local_http_env)),
        .timeout_ms = timeoutFromEnv(),
    };
    const bearer = io_mod.getenv(appboundry.token_env);
    var context = FetchContext{ .timeout_ms = settings.timeout_ms };
    var found = appboundry.discover(alloc, settings, bearer, &context, fetch) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("mcp", "appboundry discovery failed: {s}", .{appboundry.describeError(err)});
        return;
    };
    defer found.deinit(alloc);
    debug_trace.logf("mcp", "appboundry discovered servers={d} skipped={d} rejected={d}", .{ found.configs.items.len, found.skipped, found.rejected });

    while (found.configs.items.len > 0) {
        var config = found.configs.orderedRemove(0);
        // A server the user configured by hand with the same name always wins.
        if (hasServer(configs.items, config.name)) {
            config.deinit(alloc);
            continue;
        }
        configs.append(alloc, config) catch |err| {
            config.deinit(alloc);
            return err;
        };
    }
}

fn hasServer(configs: []const McpServerConfig, name: []const u8) bool {
    for (configs) |config| if (std.mem.eql(u8, config.name, name)) return true;
    return false;
}

fn isTruthy(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.mem.eql(u8, text, "1") or std.ascii.eqlIgnoreCase(text, "true");
}

fn timeoutFromEnv() u32 {
    const text = io_mod.getenv(appboundry.timeout_env) orelse return appboundry.default_timeout_ms;
    const parsed = std.fmt.parseInt(u32, text, 10) catch return appboundry.default_timeout_ms;
    if (parsed == 0) return appboundry.default_timeout_ms;
    return @min(parsed, appboundry.max_timeout_ms);
}

const FetchContext = struct {
    timeout_ms: u32,
};

const Operation = struct {
    alloc: Allocator,
    url: []const u8,
    authorization: ?[]const u8,

    const Result = struct {
        response: appboundry.Response,

        pub fn deinit(self: *Result, alloc: Allocator) void {
            alloc.free(self.response.body);
            self.* = undefined;
        }
    };

    pub fn run(self: *Operation) !Result {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const buffer = try self.alloc.alloc(u8, appboundry.max_discovery_bytes + 1);
        defer self.alloc.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        const accept = [_]std.http.Header{.{ .name = "Accept", .value = "application/json" }};
        const result = try client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
                .authorization = if (self.authorization) |value| .{ .override = value } else .default,
            },
            .extra_headers = &accept,
            // A redirect could carry the credential across a trust boundary.
            .redirect_behavior = .unhandled,
            .response_writer = &writer,
        });
        return .{ .response = .{
            .status = result.status,
            .body = try self.alloc.dupe(u8, writer.buffered()),
        } };
    }
};

fn fetch(
    raw: ?*anyopaque,
    alloc: Allocator,
    url: []const u8,
    bearer: ?[]const u8,
) anyerror!appboundry.Response {
    const context: *FetchContext = @ptrCast(@alignCast(raw.?));
    var authorization: ?[]u8 = null;
    defer if (authorization) |value| {
        std.crypto.secureZero(u8, value);
        alloc.free(value);
    };
    if (bearer) |token| {
        if (token.len == 0) return error.InvalidCredential;
        streamable_http.validateHeaderValue(token) catch return error.InvalidCredential;
        authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
    }
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(context.timeout_ms),
    });
    var cancel = std.atomic.Value(bool).init(false);
    var operation = Operation{ .alloc = alloc, .url = url, .authorization = authorization };
    var result = try gateway_client.runBoundedHttpOperation(Operation.Result, alloc, &cancel, deadline, &operation);
    errdefer result.deinit(alloc);
    if (result.response.body.len > appboundry.max_discovery_bytes) return error.ResponseTooLarge;
    return result.response;
}

test "env truthiness accepts only explicit values" {
    try std.testing.expect(isTruthy("1"));
    try std.testing.expect(isTruthy("TRUE"));
    try std.testing.expect(!isTruthy("0"));
    try std.testing.expect(!isTruthy(null));
    try std.testing.expect(!isTruthy("yes"));
}

test "server name conflicts keep the user-configured server" {
    const configs = [_]McpServerConfig{.{ .name = "appboundry_x" }};
    try std.testing.expect(hasServer(&configs, "appboundry_x"));
    try std.testing.expect(!hasServer(&configs, "appboundry_y"));
}

test "provider is inert when unconfigured" {
    const alloc = std.testing.allocator;
    var configs: std.ArrayList(McpServerConfig) = .empty;
    defer configs.deinit(alloc);
    try appendDiscoveredServers(alloc, &configs);
    try std.testing.expectEqual(@as(usize, 0), configs.items.len);
}
