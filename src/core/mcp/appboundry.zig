//! AppBoundry capability provider.
//!
//! AppBoundry hosts governed capabilities and advertises each hosted
//! application's MCP endpoint through `GET /.well-known/appport`. This module
//! only turns that discovery document into ordinary `McpServerConfig` entries.
//! Connection, `tools/list`, schema loading, `tools/call`, timeouts,
//! cancellation, and tool naming stay with the existing MCP runtime.
//! Authentication, scope enforcement, contract validation, and WASM execution
//! stay with AppBoundry.
//!
//! The bearer token is never read here. A config carries only the name of the
//! environment variable, which the MCP transport resolves per request.

const std = @import("std");
const mcp_contract = @import("mcp_contract.zig");
const streamable_http = @import("streamable_http.zig");

const Allocator = std.mem.Allocator;
const McpServerConfig = mcp_contract.McpServerConfig;

pub const url_env = "FX_APPBOUNDRY_URL";
pub const token_env = "FX_APPBOUNDRY_TOKEN";
pub const apps_env = "FX_APPBOUNDRY_APPS";
pub const disable_env = "FX_APPBOUNDRY_DISABLE";
pub const allow_local_http_env = "FX_APPBOUNDRY_ALLOW_LOCAL_HTTP";
pub const timeout_env = "FX_APPBOUNDRY_TIMEOUT_MS";

pub const discovery_path = "/.well-known/appport";
pub const discovery_protocol = "AppPort/host-discovery/1";
pub const server_prefix = "appboundry_";
pub const default_timeout_ms: u32 = 5_000;
pub const max_timeout_ms: u32 = 60_000;
pub const max_discovery_bytes: usize = 1024 * 1024;
/// Bound on applications read from one discovery document. A safety limit, not
/// a catalog size: a host advertising more has the remainder ignored.
pub const max_applications: usize = 256;
const max_selector_bytes: usize = 48;
const max_path_bytes: usize = 512;

pub const Settings = struct {
    /// Trusted host. Borrowed.
    base_url: []const u8,
    /// Environment variable holding the bearer token. Borrowed.
    token_env_name: []const u8 = token_env,
    /// Optional allowlist matched against an application's selector or id.
    apps: []const []const u8 = &.{},
    allow_local_http: bool = false,
    /// Bounds discovery, and each capability connection and call.
    timeout_ms: u32 = default_timeout_ms,
};

pub const Error = error{
    InvalidBaseUrl,
    InsecureBaseUrl,
    DiscoveryUnavailable,
    DiscoveryUnauthorized,
    DiscoveryMalformed,
    OutOfMemory,
};

pub const Response = struct {
    status: std.http.Status,
    /// Owned by the caller of `FetchFn`'s result consumer; freed by `discover`.
    body: []u8,
};

/// Fetches `url` with an optional bearer token. Must not follow redirects.
pub const FetchFn = *const fn (
    context: ?*anyopaque,
    alloc: Allocator,
    url: []const u8,
    bearer: ?[]const u8,
) anyerror!Response;

pub const Discovery = struct {
    configs: std.ArrayList(McpServerConfig) = .empty,
    /// Advertised applications not turned into servers (stopped, no MCP
    /// endpoint, filtered out, malformed, or a duplicate name).
    skipped: usize = 0,
    /// Subset of `skipped` whose advertised endpoint or identity was rejected.
    rejected: usize = 0,

    pub fn deinit(self: *Discovery, alloc: Allocator) void {
        for (self.configs.items) |*config| config.deinit(alloc);
        self.configs.deinit(alloc);
        self.* = undefined;
    }
};

/// Validates the configured host and returns an owned `scheme://host[:port]`.
pub fn normalizeOrigin(alloc: Allocator, settings: Settings) Error![]u8 {
    const uri = std.Uri.parse(settings.base_url) catch return error.InvalidBaseUrl;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
        return error.InvalidBaseUrl;
    }
    const path = uri.path.percent_encoded;
    if (path.len != 0 and !std.mem.eql(u8, path, "/")) return error.InvalidBaseUrl;
    const host_component = uri.host orelse return error.InvalidBaseUrl;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return error.InvalidBaseUrl;
    if (host.len == 0) return error.InvalidBaseUrl;

    const secure = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!secure) {
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidBaseUrl;
        // Plain HTTP is a local-development mode: explicit opt-in and loopback only.
        if (!settings.allow_local_http) return error.InsecureBaseUrl;
        streamable_http.validateEndpoint(settings.base_url) catch return error.InsecureBaseUrl;
    }
    const scheme: []const u8 = if (secure) "https" else "http";
    if (uri.port) |port| {
        return std.fmt.allocPrint(alloc, "{s}://{s}:{d}", .{ scheme, host, port });
    }
    return std.fmt.allocPrint(alloc, "{s}://{s}", .{ scheme, host });
}

/// Fetches the discovery document and builds one HTTP MCP server per running,
/// eligible application. The caller owns the result.
pub fn discover(
    alloc: Allocator,
    settings: Settings,
    bearer: ?[]const u8,
    fetch_context: ?*anyopaque,
    fetch: FetchFn,
) Error!Discovery {
    const origin = try normalizeOrigin(alloc, settings);
    defer alloc.free(origin);
    const url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ origin, discovery_path });
    defer alloc.free(url);

    const response = fetch(fetch_context, alloc, url, bearer) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.DiscoveryUnavailable,
    };
    defer alloc.free(response.body);
    switch (response.status) {
        .ok => {},
        .unauthorized, .forbidden => return error.DiscoveryUnauthorized,
        else => return error.DiscoveryUnavailable,
    }
    return parseDocument(alloc, settings, origin, response.body);
}

pub fn parseDocument(
    alloc: Allocator,
    settings: Settings,
    origin: []const u8,
    body: []const u8,
) Error!Discovery {
    if (body.len > max_discovery_bytes) return error.DiscoveryMalformed;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.DiscoveryMalformed,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.DiscoveryMalformed;
    const protocol = stringField(parsed.value.object, "protocol") orelse return error.DiscoveryMalformed;
    if (!std.mem.eql(u8, protocol, discovery_protocol)) return error.DiscoveryMalformed;
    const applications = parsed.value.object.get("applications") orelse return error.DiscoveryMalformed;
    if (applications != .array) return error.DiscoveryMalformed;

    var result: Discovery = .{};
    errdefer result.deinit(alloc);
    for (applications.array.items, 0..) |application, index| {
        if (index >= max_applications) {
            result.skipped += applications.array.items.len - index;
            break;
        }
        const outcome = try configForApplication(alloc, settings, origin, application, result.configs.items);
        switch (outcome) {
            .config => |config| {
                result.configs.append(alloc, config) catch |err| {
                    var owned = config;
                    owned.deinit(alloc);
                    return err;
                };
            },
            .skipped => result.skipped += 1,
            .rejected => {
                result.skipped += 1;
                result.rejected += 1;
            },
        }
    }
    return result;
}

const Outcome = union(enum) {
    config: McpServerConfig,
    skipped,
    rejected,
};

fn configForApplication(
    alloc: Allocator,
    settings: Settings,
    origin: []const u8,
    application: std.json.Value,
    existing: []const McpServerConfig,
) Allocator.Error!Outcome {
    if (application != .object) return .rejected;
    const object = application.object;
    const selector = stringField(object, "selector") orelse return .rejected;
    if (!validSelector(selector)) return .rejected;
    if (!selected(settings.apps, selector, stringField(object, "id"))) return .skipped;
    // A stopped application is not callable; advertised metadata is not evidence of availability.
    if (stringField(object, "status")) |status| {
        if (!std.mem.eql(u8, status, "running")) return .skipped;
    }
    const mcp_value = object.get("mcp") orelse return .skipped;
    if (mcp_value != .string) return .rejected;

    const url = resolveEndpoint(alloc, origin, mcp_value.string) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidEndpoint => return .rejected,
    };
    errdefer alloc.free(url);
    const name = try serverName(alloc, selector);
    errdefer alloc.free(name);
    for (existing) |other| if (std.mem.eql(u8, other.name, name)) {
        alloc.free(name);
        alloc.free(url);
        return .rejected;
    };
    const env_name = try alloc.dupe(u8, settings.token_env_name);
    errdefer alloc.free(env_name);
    return .{ .config = .{
        .name = name,
        .transport = .http,
        .url = url,
        .bearer_token_env = env_name,
        .startup_timeout_ms = settings.timeout_ms,
        .operation_timeout_ms = settings.timeout_ms,
    } };
}

/// Resolves an advertised path against the configured origin. Only an
/// absolute path is accepted, so the result cannot leave the trusted origin.
/// Returns an owned URL.
pub fn resolveEndpoint(
    alloc: Allocator,
    origin: []const u8,
    advertised: []const u8,
) error{ InvalidEndpoint, OutOfMemory }![]u8 {
    if (!validEndpointPath(advertised)) return error.InvalidEndpoint;
    const url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ origin, advertised });
    errdefer alloc.free(url);
    streamable_http.validateEndpoint(url) catch return error.InvalidEndpoint;
    return url;
}

fn validEndpointPath(path: []const u8) bool {
    if (path.len < 2 or path.len > max_path_bytes) return false;
    if (path[0] != '/' or path[1] == '/') return false;
    for (path, 0..) |byte, index| {
        if (byte <= 0x20 or byte >= 0x7f) return false;
        switch (byte) {
            '?', '#', '\\' => return false,
            '%' => {
                if (index + 3 > path.len) return false;
                const hex = path[index + 1 .. index + 3];
                if (std.ascii.eqlIgnoreCase(hex, "2e") or
                    std.ascii.eqlIgnoreCase(hex, "2f") or
                    std.ascii.eqlIgnoreCase(hex, "5c")) return false;
            },
            else => {},
        }
    }
    var segments = std.mem.splitScalar(u8, path[1..], '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..") or std.mem.eql(u8, segment, ".")) return false;
    }
    return true;
}

fn validSelector(selector: []const u8) bool {
    if (selector.len == 0 or selector.len > max_selector_bytes) return false;
    for (selector) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.') continue;
        return false;
    }
    return true;
}

/// Server names are traceable to the AppBoundry application selector.
fn serverName(alloc: Allocator, selector: []const u8) Allocator.Error![]u8 {
    const name = try alloc.alloc(u8, server_prefix.len + selector.len);
    @memcpy(name[0..server_prefix.len], server_prefix);
    for (selector, 0..) |byte, index| {
        name[server_prefix.len + index] = if (byte == '.') '_' else byte;
    }
    return name;
}

fn selected(apps: []const []const u8, selector: []const u8, id: ?[]const u8) bool {
    if (apps.len == 0) return true;
    for (apps) |wanted| {
        if (std.mem.eql(u8, wanted, selector)) return true;
        if (id) |value| if (std.mem.eql(u8, wanted, value)) return true;
    }
    return false;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

/// Splits a comma-separated application filter. The result borrows `raw`;
/// the caller frees only the returned slice.
pub fn parseAppFilter(alloc: Allocator, raw: []const u8) Allocator.Error![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(alloc);
    var parts = std.mem.splitScalar(u8, raw, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len != 0) try list.append(alloc, trimmed);
    }
    return list.toOwnedSlice(alloc);
}

/// Returns the user-facing reason for a failed discovery. Never includes the
/// token, the configured URL, or response content.
pub fn describeError(err: Error) []const u8 {
    return switch (err) {
        error.InvalidBaseUrl => "FX_APPBOUNDRY_URL must be an origin such as https://appboundry.example",
        error.InsecureBaseUrl => "FX_APPBOUNDRY_URL must use https (http is allowed only for loopback with FX_APPBOUNDRY_ALLOW_LOCAL_HTTP=1)",
        error.DiscoveryUnavailable => "AppBoundry host unreachable or returned an unexpected status",
        error.DiscoveryUnauthorized => "AppBoundry host rejected the credentials",
        error.DiscoveryMalformed => "AppBoundry discovery document is malformed",
        error.OutOfMemory => "out of memory",
    };
}

// Tests ----------------------------------------------------------------

const MockFetch = struct {
    status: std.http.Status = .ok,
    body: []const u8,
    fail: bool = false,
    seen_bearer: ?[]const u8 = null,
    url_buf: [128]u8 = undefined,
    seen_url: ?[]const u8 = null,

    fn run(ctx: ?*anyopaque, alloc: Allocator, url: []const u8, bearer: ?[]const u8) anyerror!Response {
        const self: *MockFetch = @ptrCast(@alignCast(ctx.?));
        self.seen_bearer = bearer;
        @memcpy(self.url_buf[0..url.len], url);
        self.seen_url = self.url_buf[0..url.len];
        if (self.fail) return error.ConnectionRefused;
        return .{ .status = self.status, .body = try alloc.dupe(u8, self.body) };
    }
};

const sample_document =
    \\{"protocol":"AppPort/host-discovery/1","applications":[
    \\{"id":"app.one","selector":"image-tools","name":"Image","status":"running","mcp":"/apps/image-tools/mcp","capabilities":["resize@1"],"descriptions":{"resize@1":"Resize a raster"}},
    \\{"id":"app.two","selector":"stopped-app","status":"stopped","mcp":"/apps/stopped-app/mcp"},
    \\{"id":"app.three","selector":"no-mcp","status":"running"},
    \\{"id":"app.four","selector":"evil","status":"running","mcp":"//evil.test/mcp"},
    \\{"id":"app.five","selector":"evil2","status":"running","mcp":"https://evil.test/mcp"},
    \\{"id":"app.six","selector":"dotted.name","status":"running","mcp":"/apps/dotted.name/mcp"}
    \\]}
;

test "discovery builds one http server per running application with an in-origin endpoint" {
    const alloc = std.testing.allocator;
    var mock = MockFetch{ .body = sample_document };
    var found = try discover(alloc, .{ .base_url = "https://host.test" }, "secret-token", &mock, MockFetch.run);
    defer found.deinit(alloc);

    try std.testing.expectEqualStrings("https://host.test/.well-known/appport", mock.seen_url.?);
    try std.testing.expectEqual(@as(usize, 2), found.configs.items.len);
    try std.testing.expectEqual(@as(usize, 4), found.skipped);
    try std.testing.expectEqual(@as(usize, 2), found.rejected);
    const first = found.configs.items[0];
    try std.testing.expectEqualStrings("appboundry_image-tools", first.name);
    try std.testing.expectEqualStrings("https://host.test/apps/image-tools/mcp", first.url.?);
    try std.testing.expectEqual(mcp_contract.McpTransport.http, first.transport);
    try std.testing.expectEqualStrings("FX_APPBOUNDRY_TOKEN", first.bearer_token_env.?);
    try std.testing.expect(!first.allow_stored_credentials);
    try std.testing.expect(!first.always_loaded);
    try std.testing.expectEqualStrings("appboundry_dotted_name", found.configs.items[1].name);
}

test "the token reaches only the fetch call and never a config" {
    const alloc = std.testing.allocator;
    var mock = MockFetch{ .body = sample_document };
    var found = try discover(alloc, .{ .base_url = "https://host.test" }, "secret-token", &mock, MockFetch.run);
    defer found.deinit(alloc);
    try std.testing.expectEqualStrings("secret-token", mock.seen_bearer.?);
    for (found.configs.items) |config| {
        try std.testing.expect(std.mem.indexOf(u8, config.url.?, "secret-token") == null);
        try std.testing.expectEqual(@as(usize, 0), config.headers.len);
        try std.testing.expectEqual(@as(usize, 0), config.env.len);
    }
    for ([_]Error{
        error.InvalidBaseUrl,       error.InsecureBaseUrl,
        error.DiscoveryUnavailable, error.DiscoveryUnauthorized,
        error.DiscoveryMalformed,
    }) |err| try std.testing.expect(std.mem.indexOf(u8, describeError(err), "secret") == null);
}

test "application filter matches selector or id and leaves others undiscovered" {
    const alloc = std.testing.allocator;
    var mock = MockFetch{ .body = sample_document };
    const wanted = [_][]const u8{"app.six"};
    var found = try discover(alloc, .{ .base_url = "https://host.test", .apps = &wanted }, null, &mock, MockFetch.run);
    defer found.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), found.configs.items.len);
    try std.testing.expectEqualStrings("appboundry_dotted_name", found.configs.items[0].name);
    try std.testing.expect(mock.seen_bearer == null);
}

test "malformed discovery documents are rejected" {
    const alloc = std.testing.allocator;
    const bodies = [_][]const u8{
        "",
        "not json",
        "[]",
        "{}",
        "{\"protocol\":\"other/1\",\"applications\":[]}",
        "{\"protocol\":\"AppPort/host-discovery/1\"}",
        "{\"protocol\":\"AppPort/host-discovery/1\",\"applications\":{}}",
    };
    for (bodies) |body| {
        var mock = MockFetch{ .body = body };
        try std.testing.expectError(
            error.DiscoveryMalformed,
            discover(alloc, .{ .base_url = "https://host.test" }, null, &mock, MockFetch.run),
        );
    }
}

test "malformed application entries are skipped without failing the host" {
    const alloc = std.testing.allocator;
    var mock = MockFetch{ .body = "{\"protocol\":\"AppPort/host-discovery/1\",\"applications\":[3,{},{\"selector\":\"a b\"},{\"selector\":\"ok\",\"mcp\":5}]}" };
    var found = try discover(alloc, .{ .base_url = "https://host.test" }, null, &mock, MockFetch.run);
    defer found.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), found.configs.items.len);
    try std.testing.expectEqual(@as(usize, 4), found.rejected);
}

test "transport and authentication failures map to typed errors" {
    const alloc = std.testing.allocator;
    var down = MockFetch{ .body = "", .fail = true };
    try std.testing.expectError(error.DiscoveryUnavailable, discover(alloc, .{ .base_url = "https://host.test" }, null, &down, MockFetch.run));
    var denied = MockFetch{ .body = "", .status = .unauthorized };
    try std.testing.expectError(error.DiscoveryUnauthorized, discover(alloc, .{ .base_url = "https://host.test" }, null, &denied, MockFetch.run));
    var forbidden = MockFetch{ .body = "", .status = .forbidden };
    try std.testing.expectError(error.DiscoveryUnauthorized, discover(alloc, .{ .base_url = "https://host.test" }, null, &forbidden, MockFetch.run));
    var redirect = MockFetch{ .body = "", .status = .found };
    try std.testing.expectError(error.DiscoveryUnavailable, discover(alloc, .{ .base_url = "https://host.test" }, null, &redirect, MockFetch.run));
}

test "base url requires https unless local http is explicitly enabled on loopback" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InsecureBaseUrl, normalizeOrigin(alloc, .{ .base_url = "http://host.test" }));
    try std.testing.expectError(error.InsecureBaseUrl, normalizeOrigin(alloc, .{ .base_url = "http://127.0.0.1:8080" }));
    try std.testing.expectError(error.InsecureBaseUrl, normalizeOrigin(alloc, .{ .base_url = "http://host.test:8080", .allow_local_http = true }));
    try std.testing.expectError(error.InvalidBaseUrl, normalizeOrigin(alloc, .{ .base_url = "ftp://host.test" }));
    try std.testing.expectError(error.InvalidBaseUrl, normalizeOrigin(alloc, .{ .base_url = "https://user:pw@host.test" }));
    try std.testing.expectError(error.InvalidBaseUrl, normalizeOrigin(alloc, .{ .base_url = "https://host.test/base" }));
    try std.testing.expectError(error.InvalidBaseUrl, normalizeOrigin(alloc, .{ .base_url = "https://host.test/?x=1" }));
    try std.testing.expectError(error.InvalidBaseUrl, normalizeOrigin(alloc, .{ .base_url = "not a url" }));

    const local = try normalizeOrigin(alloc, .{ .base_url = "http://127.0.0.1:8080/", .allow_local_http = true });
    defer alloc.free(local);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", local);
    const remote = try normalizeOrigin(alloc, .{ .base_url = "https://host.test:8443" });
    defer alloc.free(remote);
    try std.testing.expectEqualStrings("https://host.test:8443", remote);
}

test "advertised endpoints cannot leave the configured origin" {
    const alloc = std.testing.allocator;
    const bad = [_][]const u8{
        "",
        "/",
        "mcp",
        "//evil.test/mcp",
        "https://evil.test/mcp",
        "/\\evil.test",
        "/a/../b",
        "/a/./b",
        "/a?x=1",
        "/a#f",
        "/a b",
        "/%2e%2e/x",
        "/a%2Fb",
        "/a%5cb",
        "/a%",
        "/a%2",
    };
    for (bad) |path| {
        try std.testing.expectError(error.InvalidEndpoint, resolveEndpoint(alloc, "https://host.test", path));
    }
    const ok = try resolveEndpoint(alloc, "https://host.test", "/apps/x/mcp");
    defer alloc.free(ok);
    try std.testing.expectEqualStrings("https://host.test/apps/x/mcp", ok);
}

test "colliding server names keep only the first application" {
    const alloc = std.testing.allocator;
    var mock = MockFetch{ .body = "{\"protocol\":\"AppPort/host-discovery/1\",\"applications\":[{\"selector\":\"a.b\",\"mcp\":\"/1\"},{\"selector\":\"a_b\",\"mcp\":\"/2\"}]}" };
    var found = try discover(alloc, .{ .base_url = "https://host.test" }, null, &mock, MockFetch.run);
    defer found.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), found.configs.items.len);
    try std.testing.expectEqualStrings("https://host.test/1", found.configs.items[0].url.?);
    try std.testing.expectEqual(@as(usize, 1), found.rejected);
}

test "refresh reflects a changed advertisement" {
    const alloc = std.testing.allocator;
    var mock = MockFetch{ .body = sample_document };
    var first = try discover(alloc, .{ .base_url = "https://host.test" }, null, &mock, MockFetch.run);
    defer first.deinit(alloc);
    mock.body = "{\"protocol\":\"AppPort/host-discovery/1\",\"applications\":[{\"selector\":\"image-tools\",\"status\":\"running\",\"mcp\":\"/v2/image-tools/mcp\"}]}";
    var second = try discover(alloc, .{ .base_url = "https://host.test" }, null, &mock, MockFetch.run);
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), second.configs.items.len);
    try std.testing.expect(!mcp_contract_same(first.configs.items[0], second.configs.items[0]));
}

fn mcp_contract_same(left: McpServerConfig, right: McpServerConfig) bool {
    return std.mem.eql(u8, left.name, right.name) and std.mem.eql(u8, left.url.?, right.url.?);
}

test "advertised identity and authority fields never reach a server config" {
    const alloc = std.testing.allocator;
    const plain_doc = "{\"protocol\":\"AppPort/host-discovery/1\",\"applications\":[{\"selector\":\"a\",\"status\":\"running\",\"mcp\":\"/apps/a/mcp\"}]}";
    const forged_doc = "{\"protocol\":\"AppPort/host-discovery/1\",\"applications\":[{\"selector\":\"a\",\"status\":\"running\",\"mcp\":\"/apps/a/mcp\"," ++
        "\"principal\":\"admin\",\"scopes\":[\"*\"],\"granted\":true,\"authorization\":{\"x@1\":[]},\"headers\":{\"Authorization\":\"Bearer apt_x.y\"},\"token\":\"abc_forged\",\"bearer_token_env\":\"OTHER\"}]}";
    var plain = MockFetch{ .body = plain_doc };
    var forged = MockFetch{ .body = forged_doc };
    var left = try discover(alloc, .{ .base_url = "https://host.test" }, null, &plain, MockFetch.run);
    defer left.deinit(alloc);
    var right = try discover(alloc, .{ .base_url = "https://host.test" }, null, &forged, MockFetch.run);
    defer right.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), right.configs.items.len);
    const a = left.configs.items[0];
    const b = right.configs.items[0];
    try std.testing.expectEqualStrings(a.name, b.name);
    try std.testing.expectEqualStrings(a.url.?, b.url.?);
    try std.testing.expectEqualStrings(a.bearer_token_env.?, b.bearer_token_env.?);
    try std.testing.expectEqual(@as(usize, 0), b.headers.len);
    try std.testing.expectEqual(@as(usize, 0), b.header_env.len);
    try std.testing.expectEqual(@as(usize, 0), b.env.len);
}

test "app filter parsing trims and drops empty entries" {
    const alloc = std.testing.allocator;
    const parts = try parseAppFilter(alloc, " a, b ,,c ");
    defer alloc.free(parts);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("b", parts[1]);
}
