const std = @import("std");

/// Detects a tool call that the model wrote as plain assistant text instead of
/// a structured `tool_calls` entry, for example the Qwen style
/// `<function=shell><parameter=request>{...}</parameter></function>` block that
/// some OpenAI-compatible servers pass through as content.
///
/// Detection is deliberately narrow. A match needs all of:
///   * a `<function=NAME>` tag that opens a line outside any fenced code block,
///   * NAME equal to a tool that was advertised on the request,
///   * a later `<parameter=` tag and a later closing `</function>` tag.
/// Prose that merely mentions the syntax, inline code, and fenced examples do
/// not match. The text is never parsed into arguments; only the matched tool
/// name is returned, so nothing here can become executable input.
///
/// `tools` is any slice whose elements expose a `name: []const u8` field. The
/// returned slice borrows from `content`.
pub fn find(content: []const u8, tools: anytype) ?[]const u8 {
    if (tools.len == 0) return null;
    const open = "<function=";
    var fenced = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            fenced = !fenced;
            continue;
        }
        if (fenced or !std.mem.startsWith(u8, trimmed, open)) continue;
        const after_open = trimmed[open.len..];
        const close = std.mem.findScalar(u8, after_open, '>') orelse continue;
        const name = std.mem.trim(u8, after_open[0..close], " \t");
        const advertised = for (tools) |tool| {
            if (std.mem.eql(u8, tool.name, name)) break tool.name;
        } else continue;
        const rest = content[@intFromPtr(trimmed.ptr) - @intFromPtr(content.ptr) + open.len + close + 1 ..];
        const parameter = std.mem.find(u8, rest, "<parameter=") orelse continue;
        if (std.mem.find(u8, rest[parameter..], "</function>") == null) continue;
        return advertised;
    }
    return null;
}

const Tool = struct { name: []const u8 };
const test_tools = [_]Tool{ .{ .name = "shell" }, .{ .name = "read_file" } };

const captured =
    \\I'll inspect the current Git branch and status using the available tools.
    \\
    \\<function=shell>
    \\<parameter=request>
    \\{"action": "run", "command": "git branch --show-current"}
    \\</parameter>
    \\</function>
    \\</tool_call>
;

test "captured Ollama qwen3-coder markup is detected with the advertised tool name" {
    try std.testing.expectEqualStrings("shell", find(captured, &test_tools).?);
}

test "markup for a tool that was not advertised is not a malformed call" {
    const only_read = [_]Tool{.{ .name = "read_file" }};
    try std.testing.expect(find(captured, &only_read) == null);
    try std.testing.expect(find(captured, &[_]Tool{}) == null);
}

test "ordinary prose that mentions tool syntax is not detected" {
    try std.testing.expect(find("To call a tool, emit a <function=shell> tag with <parameter=request> and close it with </function>.", &test_tools) == null);
    try std.testing.expect(find("Use `<function=shell>` followed by `<parameter=request>` ... `</function>`.", &test_tools) == null);
    try std.testing.expect(find("I ran git status and the tree is clean.", &test_tools) == null);
}

test "markup inside a fenced code block is an example, not a call" {
    const fenced_example =
        \\Here is how the format looks:
        \\
        \\```xml
        \\<function=shell>
        \\<parameter=request>{"action":"run","command":"ls"}</parameter>
        \\</function>
        \\```
    ;
    try std.testing.expect(find(fenced_example, &test_tools) == null);
    const tilde_example = "~~~\n<function=shell>\n<parameter=request>{}</parameter>\n</function>\n~~~";
    try std.testing.expect(find(tilde_example, &test_tools) == null);
}

test "a call after a closed fence is still detected" {
    const mixed = "```\nexample\n```\n<function=read_file>\n<parameter=path>\nREADME.md\n</parameter>\n</function>";
    try std.testing.expectEqualStrings("read_file", find(mixed, &test_tools).?);
}

test "incomplete structure is not detected" {
    try std.testing.expect(find("<function=shell>\n", &test_tools) == null);
    try std.testing.expect(find("<function=shell>\n<parameter=request>{}", &test_tools) == null);
    try std.testing.expect(find("<parameter=request>{}</parameter>\n</function>", &test_tools) == null);
}
