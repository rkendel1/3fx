//! AppPort naming, identifier, and version-constraint rules.
//!
//! Each function mirrors one published `@appport/protocol` 1.1.0 rule and
//! keeps its exact acceptance set. The regular expressions in the reference
//! are recorded beside each port. `tests/appport-parity/` checks these ports
//! against the published package for a shared set of inputs.

const std = @import("std");

/// `PROTOCOL_ID` in `@appport/protocol`.
pub const protocol_id = "appport/1";
/// `INTEGRATION_EXTENSION` in `@appport/protocol`.
pub const integration_extension = "appport.integration/1";

/// `RESERVED_NAME_SEGMENTS`: transport words that must never name a segment.
const reserved_name_segments = [_][]const u8{
    "http", "https",    "ws",    "wss",  "websocket", "webtransport",
    "ipc",  "electron", "tauri", "rest", "grpc",      "inprocess",
};

pub const NameCheck = union(enum) {
    valid,
    /// Static reason text, identical to the reference message.
    invalid: []const u8,
    /// A reserved transport segment. The reference message embeds it.
    reserved_segment: []const u8,
};

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// `^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)+$`
pub fn matchesNamePattern(name: []const u8) bool {
    var segments: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |segment| {
        if (segment.len == 0 or !isLower(segment[0])) return false;
        for (segment[1..]) |c| if (!isLower(c) and !isDigit(c)) return false;
        segments += 1;
    }
    return segments >= 2;
}

/// Length in UTF-16 code units, which is what JavaScript `length` reports.
/// Invalid UTF-8 counts one unit per byte.
fn jsLength(text: []const u8) usize {
    return std.unicode.calcUtf16LeLen(text) catch text.len;
}

/// `validateName`: capability and event names.
pub fn validateName(name: []const u8) NameCheck {
    if (name.len == 0) return .{ .invalid = "name must be a non-empty string" };
    if (jsLength(name) > 128) return .{ .invalid = "name must be at most 128 characters" };
    if (!matchesNamePattern(name)) return .{
        .invalid = "name must be lowercase <namespace>.<operation> using ASCII letters and digits",
    };
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |segment| {
        for (reserved_name_segments) |reserved| {
            if (std.mem.eql(u8, segment, reserved)) return .{ .reserved_segment = segment };
        }
    }
    return .valid;
}

pub fn isValidName(name: []const u8) bool {
    return validateName(name) == .valid;
}

/// `isValidApplicationId`: `^[a-z][a-z0-9]*(\.[a-z0-9][a-z0-9-]*)+$`, at most 190.
pub fn isValidApplicationId(id: []const u8) bool {
    if (jsLength(id) > 190) return false;
    var it = std.mem.splitScalar(u8, id, '.');
    const first = it.next() orelse return false;
    if (first.len == 0 or !isLower(first[0])) return false;
    for (first[1..]) |c| if (!isLower(c) and !isDigit(c)) return false;
    var rest: usize = 0;
    while (it.next()) |segment| {
        if (segment.len == 0 or !(isLower(segment[0]) or isDigit(segment[0]))) return false;
        for (segment[1..]) |c| if (!isLower(c) and !isDigit(c) and c != '-') return false;
        rest += 1;
    }
    return rest >= 1;
}

/// `isValidPermission`: the same pattern as names, without reserved segments.
pub fn isValidPermission(permission: []const u8) bool {
    return matchesNamePattern(permission);
}

/// Decodes one UTF-8 code point. Invalid bytes decode as themselves so they
/// never match whitespace.
fn nextCodePoint(text: []const u8, index: usize) struct { cp: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(text[index]) catch return .{ .cp = text[index], .len = 1 };
    if (index + len > text.len) return .{ .cp = text[index], .len = 1 };
    const cp = std.unicode.utf8Decode(text[index .. index + len]) catch return .{ .cp = text[index], .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// JavaScript `\s` and the set `String.prototype.trim` removes.
fn isJsWhitespace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

fn containsJsWhitespace(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const d = nextCodePoint(text, i);
        if (isJsWhitespace(d.cp)) return true;
        i += d.len;
    }
    return false;
}

/// `String.prototype.trim`.
pub fn jsTrim(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len) {
        const d = nextCodePoint(text, start);
        if (!isJsWhitespace(d.cp)) break;
        start += d.len;
    }
    var end = text.len;
    while (end > start) {
        // Walk back to the start of the last code point.
        var back = end - 1;
        while (back > start and (text[back] & 0xC0) == 0x80) back -= 1;
        const d = nextCodePoint(text, back);
        if (back + d.len != end or !isJsWhitespace(d.cp)) break;
        end = back;
    }
    return text[start..end];
}

/// `^[A-Za-z][A-Za-z0-9+.-]*:` followed by the remainder. Returns the
/// index of the colon, or null when there is no valid scheme.
fn schemeEnd(text: []const u8) ?usize {
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return null;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == ':') return i;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '.' and c != '-') return null;
    }
    return null;
}

/// The reference `IRI` pattern: `^[A-Za-z][A-Za-z0-9+.-]*:[^\s]+$`.
pub fn isIri(text: []const u8) bool {
    const colon = schemeEnd(text) orelse return false;
    const rest = text[colon + 1 ..];
    return rest.len > 0 and !containsJsWhitespace(rest);
}

/// The reference `DATABASE_SCHEMES` pattern, case-insensitive.
pub fn hasDatabaseScheme(text: []const u8) bool {
    const schemes = [_][]const u8{
        "postgres", "postgresql", "mysql", "mariadb",   "mongodb", "mongodb+srv", "redis", "rediss",
        "sqlite",   "jdbc",       "mssql", "sqlserver", "oracle",  "amqp",        "amqps", "file",
    };
    for (schemes) |scheme| {
        if (text.len > scheme.len and std.ascii.startsWithIgnoreCase(text, scheme) and text[scheme.len] == ':') return true;
    }
    return false;
}

/// The reference `USERINFO_URL` pattern: `^scheme://[^/?#]*@`.
pub fn hasUserinfo(text: []const u8) bool {
    const colon = schemeEnd(text) orelse return false;
    if (!std.mem.startsWith(u8, text[colon + 1 ..], "//")) return false;
    for (text[colon + 3 ..]) |c| {
        if (c == '@') return true;
        if (c == '/' or c == '?' or c == '#') return false;
    }
    return false;
}

/// `isVersionConstraint`: `^(\^|~|>=|>|<=|<)?\d+(\.\d+)*$` after trim.
pub fn isVersionConstraint(value: []const u8) bool {
    const text = jsTrim(value);
    var rest = text;
    for ([_][]const u8{ ">=", "<=", "^", "~", ">", "<" }) |prefix| {
        if (std.mem.startsWith(u8, rest, prefix)) {
            rest = rest[prefix.len..];
            break;
        }
    }
    if (rest.len == 0) return false;
    var it = std.mem.splitScalar(u8, rest, '.');
    while (it.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| if (!isDigit(c)) return false;
    }
    return true;
}

/// `Number.parseInt(text, 10)`; null stands for NaN.
fn jsParseInt(text: []const u8) ?i64 {
    const trimmed = jsTrim(text);
    var i: usize = 0;
    var negative = false;
    if (i < trimmed.len and (trimmed[i] == '+' or trimmed[i] == '-')) {
        negative = trimmed[i] == '-';
        i += 1;
    }
    const start = i;
    var value: i64 = 0;
    while (i < trimmed.len and isDigit(trimmed[i])) : (i += 1) {
        value = std.math.mul(i64, value, 10) catch return std.math.maxInt(i64);
        value = std.math.add(i64, value, trimmed[i] - '0') catch return std.math.maxInt(i64);
    }
    if (i == start) return null;
    return if (negative) -value else value;
}

/// `satisfiesVersionConstraint`: major-only semantics, as in the reference.
pub fn satisfiesVersionConstraint(version: i64, constraint: []const u8) bool {
    const c = jsTrim(constraint);
    if (std.mem.startsWith(u8, c, "^") or std.mem.startsWith(u8, c, "~")) {
        var it = std.mem.splitScalar(u8, c[1..], '.');
        const major = jsParseInt(it.first()) orelse return false;
        return version == major;
    }
    if (std.mem.startsWith(u8, c, ">=")) return if (jsParseInt(c[2..])) |n| version >= n else false;
    if (std.mem.startsWith(u8, c, ">")) return if (jsParseInt(c[1..])) |n| version > n else false;
    if (std.mem.startsWith(u8, c, "<=")) return if (jsParseInt(c[2..])) |n| version <= n else false;
    if (std.mem.startsWith(u8, c, "<")) return if (jsParseInt(c[1..])) |n| version < n else false;
    return if (jsParseInt(c)) |n| version == n else false;
}

pub const DependencyRef = struct {
    name: []const u8,
    version: ?i64 = null,
};

/// `parseDependencyRef`: `name` or `name@version` with a positive version.
pub fn parseDependencyRef(reference: []const u8) ?DependencyRef {
    const at = std.mem.findScalar(u8, reference, '@');
    const name = if (at) |i| reference[0..i] else reference;
    if (!matchesNamePattern(name)) return null;
    const i = at orelse return .{ .name = name };
    const digits = reference[i + 1 ..];
    if (digits.len == 0 or digits[0] < '1' or digits[0] > '9') return null;
    for (digits) |c| if (!isDigit(c)) return null;
    const version = std.fmt.parseInt(i64, digits, 10) catch return null;
    return .{ .name = name, .version = version };
}

/// `^(.+)@([1-9][0-9]*)$` as used for integration-descriptor keys. The
/// name part is not validated, matching the reference.
pub fn splitIntegrationKey(key: []const u8) ?DependencyRef {
    const at = std.mem.lastIndexOfScalar(u8, key, '@') orelse return null;
    if (at == 0) return null;
    const digits = key[at + 1 ..];
    if (digits.len == 0 or digits[0] < '1' or digits[0] > '9') return null;
    for (digits) |c| if (!isDigit(c)) return null;
    const version = std.fmt.parseInt(i64, digits, 10) catch return null;
    return .{ .name = key[0..at], .version = version };
}

test "validateName follows the reference rules" {
    try std.testing.expect(validateName("documents.save") == .valid);
    try std.testing.expect(validateName("a.b2.c") == .valid);
    try std.testing.expect(validateName("") == .invalid);
    try std.testing.expect(validateName("documents") == .invalid);
    try std.testing.expect(validateName("Documents.save") == .invalid);
    try std.testing.expect(validateName("documents.2save") == .invalid);
    try std.testing.expect(validateName("documents..save") == .invalid);
    switch (validateName("documents.http")) {
        .reserved_segment => |segment| try std.testing.expectEqualStrings("http", segment),
        else => return error.TestUnexpectedResult,
    }
    const long = "a." ++ "b" ** 127;
    try std.testing.expectEqualStrings("name must be at most 128 characters", validateName(long).invalid);
}

test "application ids and permissions" {
    try std.testing.expect(isValidApplicationId("com.example.sherpa"));
    try std.testing.expect(isValidApplicationId("com.9example.my-app"));
    try std.testing.expect(!isValidApplicationId("com"));
    try std.testing.expect(!isValidApplicationId("com.-x"));
    try std.testing.expect(!isValidApplicationId("Com.example"));
    try std.testing.expect(isValidPermission("documents.write"));
    try std.testing.expect(!isValidPermission("documents"));
}

test "iri and locator checks" {
    try std.testing.expect(isIri("urn:example:doc"));
    try std.testing.expect(isIri("https://example.com/x"));
    try std.testing.expect(!isIri("example"));
    try std.testing.expect(!isIri("urn:has space"));
    try std.testing.expect(!isIri("urn:"));
    try std.testing.expect(!isIri("urn:nbsp\u{a0}x"));
    try std.testing.expect(hasDatabaseScheme("PostgreSQL://db/x"));
    try std.testing.expect(hasDatabaseScheme("file:/tmp/x"));
    try std.testing.expect(!hasDatabaseScheme("urn:file:x"));
    try std.testing.expect(hasUserinfo("https://user:pw@example.com/x"));
    try std.testing.expect(!hasUserinfo("https://example.com/a@b"));
}

test "version constraints use major-only semantics" {
    try std.testing.expect(isVersionConstraint("1"));
    try std.testing.expect(isVersionConstraint(" ^1.2 "));
    try std.testing.expect(isVersionConstraint(">=2"));
    try std.testing.expect(!isVersionConstraint("=1"));
    try std.testing.expect(!isVersionConstraint("1."));
    try std.testing.expect(!isVersionConstraint(""));
    try std.testing.expect(satisfiesVersionConstraint(1, "^1.9"));
    try std.testing.expect(!satisfiesVersionConstraint(2, "~1"));
    try std.testing.expect(satisfiesVersionConstraint(3, ">=2.5"));
    try std.testing.expect(satisfiesVersionConstraint(1, "<2"));
    try std.testing.expect(!satisfiesVersionConstraint(1, ""));
    try std.testing.expect(!satisfiesVersionConstraint(1, "abc"));
}

test "dependency refs and integration keys" {
    const pinned = parseDependencyRef("documents.save@2").?;
    try std.testing.expectEqualStrings("documents.save", pinned.name);
    try std.testing.expectEqual(@as(?i64, 2), pinned.version);
    try std.testing.expectEqual(@as(?i64, null), parseDependencyRef("documents.save").?.version);
    try std.testing.expect(parseDependencyRef("documents.save@0") == null);
    try std.testing.expect(parseDependencyRef("documents.save@") == null);
    try std.testing.expect(parseDependencyRef("Documents.save") == null);
    const key = splitIntegrationKey("x@y@3").?;
    try std.testing.expectEqualStrings("x@y", key.name);
    try std.testing.expect(splitIntegrationKey("x@03") == null);
}
