const std = @import("std");

pub const description_max_bytes: usize = 1024;
pub const truncation_marker = "... [truncated]";

pub const JsonType = enum {
    string,
    integer,
    boolean,
    object,
    array,
};

const no_u32_bound = std.math.maxInt(u32);
const no_u64_bound = std.math.maxInt(u64);

const PropertyShape = union(enum) {
    enum_values: []const []const u8,
    object: *const ObjectSchema,
    array_values: struct {
        json_type: JsonType,
        enum_values: []const []const u8 = &.{},
    },
    array_objects: *const ObjectSchema,
};

const PropertyBounds = struct {
    min_length: u32 = no_u32_bound,
    max_length: u32 = no_u32_bound,
    minimum: u64 = no_u64_bound,
    maximum: u64 = no_u64_bound,
    min_items: u32 = no_u32_bound,
    max_items: u32 = no_u32_bound,
};

const no_property_bounds = PropertyBounds{};

pub const Property = struct {
    name: []const u8,
    description: []const u8 = "",
    shape: ?*const PropertyShape = null,
    bounds: ?*const PropertyBounds = null,
    json_type: JsonType,
};

pub const ObjectSchema = struct {
    properties: []const Property = &.{},
    required: []const []const u8 = &.{},
    additional_properties: ?bool = null,
    min_properties: u32 = no_u32_bound,
    max_properties: u32 = no_u32_bound,
    one_of: []const ObjectSchema = &.{},
};

pub const FunctionSchema = struct {
    name: []const u8,
    description: []const u8,
    input_schema: ObjectSchema = .{},
};

pub fn isSingleRequiredObjectUnionField(
    schema: ObjectSchema,
    field_name: []const u8,
) bool {
    if (schema.properties.len != 1 or schema.required.len != 1 or
        schema.additional_properties != false or
        !std.mem.eql(u8, schema.properties[0].name, field_name) or
        !std.mem.eql(u8, schema.required[0], field_name))
    {
        return false;
    }
    const shape = schema.properties[0].shape orelse return false;
    return switch (shape.*) {
        .object => |object| object.one_of.len > 0,
        else => false,
    };
}

/// Writes the narrowly recognized full or process-only shell schema with its action union
/// projected into one object. Returns false without writing if the schema no
/// longer matches that canonical shape.
pub fn writeFlattenedShellSchema(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    schema: ObjectSchema,
) anyerror!bool {
    if (!isExpectedShellSchema(schema)) return false;
    const union_schema = schema.properties[0].shape.?.object.*;

    try writer.writeAll("{\"type\":\"object\",\"properties\":{\"request\":{\"type\":\"object\",\"properties\":{");
    var emitted: std.ArrayList([]const u8) = .empty;
    defer emitted.deinit(alloc);
    var property_count: usize = 0;
    for (union_schema.one_of) |alternative| {
        for (alternative.properties) |property| {
            if (std.mem.eql(u8, property.name, "action")) {
                if (containsName(emitted.items, "action")) continue;
                try writeProjectedPropertyName(writer, property.name, &property_count);
                try writer.writeAll("{\"type\":\"string\",\"enum\":[\"run\",\"interact\",\"stop\"]}");
                try emitted.append(alloc, property.name);
                continue;
            }
            if (containsName(emitted.items, property.name)) continue;
            var merged = property;
            var merged_bounds = no_property_bounds;
            var saw_candidate = false;
            var has_bounds = false;
            var description_matches = true;
            const description = property.description;
            for (union_schema.one_of) |candidate_schema| {
                const candidate = findProperty(candidate_schema, property.name) orelse continue;
                const candidate_bounds = candidate.bounds orelse &no_property_bounds;
                if (!saw_candidate) {
                    merged_bounds = candidate_bounds.*;
                    saw_candidate = true;
                } else {
                    merged_bounds = unionBounds(merged_bounds, candidate_bounds.*);
                }
                has_bounds = has_bounds or !std.meta.eql(candidate_bounds.*, no_property_bounds);
                if (!std.mem.eql(u8, description, candidate.description)) description_matches = false;
            }
            merged.bounds = if (has_bounds) &merged_bounds else null;
            merged.description = if (description_matches) description else "";
            try writeProjectedPropertyName(writer, property.name, &property_count);
            try writePropertySchema(alloc, writer, merged);
            try emitted.append(alloc, property.name);
        }
    }
    try writer.writeAll("},\"additionalProperties\":false,\"required\":[\"action\"]}},\"additionalProperties\":false,\"required\":[\"request\"]}");
    return true;
}

fn isExpectedShellSchema(schema: ObjectSchema) bool {
    if (!isSingleRequiredObjectUnionField(schema, "request") or
        schema.min_properties != no_u32_bound or schema.max_properties != no_u32_bound)
    {
        return false;
    }
    const request = schema.properties[0];
    if (request.json_type != .object or request.bounds != null or request.description.len != 0) return false;
    const union_schema = request.shape.?.object.*;
    if ((union_schema.one_of.len != 4 and union_schema.one_of.len != 3) or union_schema.properties.len != 0 or
        union_schema.required.len != 0 or union_schema.additional_properties != null or
        union_schema.min_properties != no_u32_bound or union_schema.max_properties != no_u32_bound)
    {
        return false;
    }

    var run_variants: usize = 0;
    var interact_variants: usize = 0;
    var stop_variants: usize = 0;
    for (union_schema.one_of) |alternative| {
        if (alternative.additional_properties != false or alternative.one_of.len != 0 or
            alternative.min_properties != no_u32_bound or alternative.max_properties != no_u32_bound)
        {
            return false;
        }
        for (alternative.required) |required_name| {
            if (findProperty(alternative, required_name) == null) return false;
        }
        const action = findProperty(alternative, "action") orelse return false;
        if (action.json_type != .string or action.bounds != null or action.description.len != 0) return false;
        const values = action.shape orelse return false;
        const action_value = switch (values.*) {
            .enum_values => |enum_values| if (enum_values.len == 1) enum_values[0] else return false,
            else => return false,
        };
        if (!containsName(alternative.required, "action")) return false;
        if (std.mem.eql(u8, action_value, "run")) {
            if (containsName(alternative.required, "shell") and containsName(alternative.required, "tty")) {
                if (!hasExactlyRequired(alternative, &.{ "action", "command", "shell", "tty" })) return false;
            } else if (!hasExactlyRequired(alternative, &.{ "action", "command" })) return false;
            run_variants += 1;
        } else if (std.mem.eql(u8, action_value, "interact")) {
            if (!hasExactlyRequired(alternative, &.{ "action", "session_id" })) return false;
            interact_variants += 1;
        } else if (std.mem.eql(u8, action_value, "stop")) {
            if (!hasExactlyRequired(alternative, &.{ "action", "session_id" })) return false;
            stop_variants += 1;
        } else return false;
    }
    // Full session shell: run, run with a pty shell, interact, stop. Process-only shell
    // (no interactive session fields): run, interact, stop.
    const full_shape = union_schema.one_of.len == 4 and run_variants == 2;
    const process_shape = union_schema.one_of.len == 3 and run_variants == 1;
    return (full_shape or process_shape) and interact_variants == 1 and stop_variants == 1 and
        projectedPropertiesAreCompatible(union_schema);
}

fn projectedPropertiesAreCompatible(schema: ObjectSchema) bool {
    for (schema.one_of) |alternative| {
        for (alternative.properties) |property| {
            if (std.mem.eql(u8, property.name, "action")) continue;
            for (schema.one_of) |candidate_schema| {
                const candidate = findProperty(candidate_schema, property.name) orelse continue;
                if (candidate.json_type != property.json_type or !sameShape(candidate.shape, property.shape)) return false;
            }
        }
    }
    return true;
}

fn hasExactlyRequired(schema: ObjectSchema, names: []const []const u8) bool {
    if (schema.required.len != names.len) return false;
    for (names) |name| if (!containsName(schema.required, name)) return false;
    return true;
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn findProperty(schema: ObjectSchema, name: []const u8) ?Property {
    for (schema.properties) |property| {
        if (std.mem.eql(u8, property.name, name)) return property;
    }
    return null;
}

fn sameShape(left: ?*const PropertyShape, right: ?*const PropertyShape) bool {
    if (left == null or right == null) return left == null and right == null;
    return switch (left.?.*) {
        .enum_values => |values| switch (right.?.*) {
            .enum_values => |other| valuesEqual(values, other),
            else => false,
        },
        .object => |object| switch (right.?.*) {
            .object => |other| object == other,
            else => false,
        },
        .array_values => |values| switch (right.?.*) {
            .array_values => |other| values.json_type == other.json_type and valuesEqual(values.enum_values, other.enum_values),
            else => false,
        },
        .array_objects => |object| switch (right.?.*) {
            .array_objects => |other| object == other,
            else => false,
        },
    };
}

fn valuesEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    return true;
}

fn unionBounds(left: PropertyBounds, right: PropertyBounds) PropertyBounds {
    return .{
        .min_length = if (left.min_length == no_u32_bound or right.min_length == no_u32_bound) no_u32_bound else @min(left.min_length, right.min_length),
        .max_length = if (left.max_length == no_u32_bound or right.max_length == no_u32_bound) no_u32_bound else @max(left.max_length, right.max_length),
        .minimum = if (left.minimum == no_u64_bound or right.minimum == no_u64_bound) no_u64_bound else @min(left.minimum, right.minimum),
        .maximum = if (left.maximum == no_u64_bound or right.maximum == no_u64_bound) no_u64_bound else @max(left.maximum, right.maximum),
        .min_items = if (left.min_items == no_u32_bound or right.min_items == no_u32_bound) no_u32_bound else @min(left.min_items, right.min_items),
        .max_items = if (left.max_items == no_u32_bound or right.max_items == no_u32_bound) no_u32_bound else @max(left.max_items, right.max_items),
    };
}

fn writeProjectedPropertyName(writer: *std.Io.Writer, name: []const u8, count: *usize) anyerror!void {
    if (count.* != 0) try writer.writeByte(',');
    count.* += 1;
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
}

test "static property representation stays within the measured size budget" {
    try std.testing.expect(@sizeOf(Property) <= 64);
}

fn cappedDescriptionAlloc(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len <= description_max_bytes) return alloc.dupe(u8, text);

    const prefix_len = description_max_bytes - truncation_marker.len;
    var out = try alloc.alloc(u8, description_max_bytes);
    @memcpy(out[0..prefix_len], text[0..prefix_len]);
    @memcpy(out[prefix_len..], truncation_marker);
    return out;
}

pub fn writeCappedDescriptionJsonString(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    text: []const u8,
) !void {
    const capped_description = try cappedDescriptionAlloc(alloc, text);
    defer alloc.free(capped_description);
    try std.json.Stringify.value(capped_description, .{}, writer);
}

/// Opens the gateway's flattened function-tool envelope, up to the
/// "inputSchema" value. The caller writes the schema and the closing brace.
fn writeFunctionSchemaOpen(
    writer: *std.Io.Writer,
    name: []const u8,
    description: []const u8,
) !void {
    try writer.writeAll("{\"type\":\"function\",\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(description, .{}, writer);
    try writer.writeAll(",\"inputSchema\":");
}

pub fn writeBuiltinFunctionSchema(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    schema: FunctionSchema,
) !void {
    const description = try cappedDescriptionAlloc(alloc, schema.description);
    defer alloc.free(description);
    try writeFunctionSchemaOpen(writer, schema.name, description);
    try writeObjectSchema(alloc, writer, schema.input_schema);
    try writer.writeByte('}');
}

pub fn builtinFunctionSchemaJsonAlloc(alloc: std.mem.Allocator, schema: FunctionSchema) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeBuiltinFunctionSchema(alloc, &out.writer, schema);
    return try out.toOwnedSlice();
}

/// Envelope for a dynamic (MCP) tool whose input schema is already rendered
/// JSON. Caller owns the returned slice.
pub fn dynamicFunctionSchemaJsonAlloc(
    alloc: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeFunctionSchemaOpen(&out.writer, name, description);
    try out.writer.writeAll(input_schema_json);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

pub fn writeObjectSchema(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    schema: ObjectSchema,
) anyerror!void {
    if (schema.one_of.len > 0) {
        if (schema.properties.len > 0 or
            schema.required.len > 0 or
            schema.additional_properties != null or
            schema.min_properties != no_u32_bound or
            schema.max_properties != no_u32_bound)
        {
            return error.InvalidObjectSchema;
        }
        try writer.writeAll("{\"oneOf\":[");
        for (schema.one_of, 0..) |alternative, index| {
            if (index > 0) try writer.writeByte(',');
            try writeObjectSchema(alloc, writer, alternative);
        }
        try writer.writeAll("]}");
        return;
    }

    try writer.writeAll("{\"type\":\"object\",\"properties\":{");
    for (schema.properties, 0..) |property, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(property.name, .{}, writer);
        try writer.writeByte(':');
        try writePropertySchema(alloc, writer, property);
    }
    try writer.writeByte('}');
    if (schema.additional_properties) |value| {
        try writer.writeAll(",\"additionalProperties\":");
        try writer.writeAll(if (value) "true" else "false");
    }
    if (schema.min_properties != no_u32_bound) try writer.print(",\"minProperties\":{d}", .{schema.min_properties});
    if (schema.max_properties != no_u32_bound) try writer.print(",\"maxProperties\":{d}", .{schema.max_properties});
    if (schema.required.len > 0) {
        try writer.writeAll(",\"required\":[");
        for (schema.required, 0..) |name, index| {
            if (index > 0) try writer.writeByte(',');
            try std.json.Stringify.value(name, .{}, writer);
        }
        try writer.writeByte(']');
    }
    try writer.writeByte('}');
}

fn writePropertySchema(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    property: Property,
) anyerror!void {
    if (property.shape) |shape| {
        switch (shape.*) {
            .object => |object_schema| {
                try writeObjectSchema(alloc, writer, object_schema.*);
                return;
            },
            else => {},
        }
    }
    try writer.writeAll("{\"type\":");
    try std.json.Stringify.value(@tagName(property.json_type), .{}, writer);
    if (property.shape) |shape| {
        switch (shape.*) {
            .enum_values => |values| {
                try writer.writeAll(",\"enum\":[");
                for (values, 0..) |value, index| {
                    if (index > 0) try writer.writeByte(',');
                    try std.json.Stringify.value(value, .{}, writer);
                }
                try writer.writeByte(']');
            },
            else => {},
        }
    }
    const bounds = property.bounds orelse &no_property_bounds;
    if (bounds.min_length != no_u32_bound) try writer.print(",\"minLength\":{d}", .{bounds.min_length});
    if (bounds.max_length != no_u32_bound) try writer.print(",\"maxLength\":{d}", .{bounds.max_length});
    if (bounds.minimum != no_u64_bound) try writer.print(",\"minimum\":{d}", .{bounds.minimum});
    if (bounds.maximum != no_u64_bound) try writer.print(",\"maximum\":{d}", .{bounds.maximum});
    if (property.description.len > 0) {
        try writer.writeAll(",\"description\":");
        try writeCappedDescriptionJsonString(alloc, writer, property.description);
    }
    if (bounds.min_items != no_u32_bound) try writer.print(",\"minItems\":{d}", .{bounds.min_items});
    if (bounds.max_items != no_u32_bound) try writer.print(",\"maxItems\":{d}", .{bounds.max_items});
    if (property.shape) |shape| {
        switch (shape.*) {
            .array_values => |values| {
                try writer.writeAll(",\"items\":{\"type\":");
                try std.json.Stringify.value(@tagName(values.json_type), .{}, writer);
                if (values.enum_values.len > 0) {
                    try writer.writeAll(",\"enum\":[");
                    for (values.enum_values, 0..) |value, index| {
                        if (index > 0) try writer.writeByte(',');
                        try std.json.Stringify.value(value, .{}, writer);
                    }
                    try writer.writeByte(']');
                }
                try writer.writeByte('}');
            },
            .array_objects => |items| {
                try writer.writeAll(",\"items\":");
                try writeObjectSchema(alloc, writer, items.*);
            },
            else => {},
        }
    }
    try writer.writeByte('}');
}

test "nested object schema serializes exact property bounds" {
    const alloc = std.testing.allocator;
    const nested = ObjectSchema{
        .properties = &.{.{ .name = "create", .json_type = .object, .shape = &.{ .object = &.{
            .properties = &.{.{ .name = "name", .json_type = .string }},
            .required = &.{"name"},
            .additional_properties = false,
        } } }},
        .additional_properties = false,
        .min_properties = 1,
        .max_properties = 1,
    };
    const schema = FunctionSchema{
        .name = "nested",
        .description = "nested",
        .input_schema = nested,
    };

    const json = try builtinFunctionSchemaJsonAlloc(alloc, schema);
    defer alloc.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"minProperties\":1") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"maxProperties\":1") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"create\":{\"type\":\"object\",\"properties\":{") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"additionalProperties\":false") != null);
}

test "object alternatives serialize as exclusive object branches" {
    const alloc = std.testing.allocator;
    const alternatives = [_]ObjectSchema{
        .{
            .properties = &.{
                .{ .name = "action", .json_type = .string, .shape = &.{ .enum_values = &.{"read"} } },
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{ "action", "path" },
            .additional_properties = false,
        },
        .{
            .properties = &.{
                .{ .name = "action", .json_type = .string, .shape = &.{ .enum_values = &.{"list"} } },
            },
            .required = &.{"action"},
            .additional_properties = false,
        },
    };
    const schema = FunctionSchema{
        .name = "alternative",
        .description = "alternative",
        .input_schema = .{ .one_of = &alternatives },
    };

    const json = try builtinFunctionSchemaJsonAlloc(alloc, schema);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const input_schema = parsed.value.object.get("inputSchema").?.object;
    try std.testing.expect(input_schema.get("type") == null);
    try std.testing.expect(input_schema.get("properties") == null);
    const one_of = input_schema.get("oneOf").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), one_of.len);
    try std.testing.expectEqualStrings(
        "read",
        one_of[0].object.get("properties").?.object.get("action").?.object.get("enum").?.array.items[0].string,
    );
    try std.testing.expectEqualStrings(
        "list",
        one_of[1].object.get("properties").?.object.get("action").?.object.get("enum").?.array.items[0].string,
    );
    try std.testing.expectEqual(false, one_of[0].object.get("additionalProperties").?.bool);
    try std.testing.expectEqual(false, one_of[1].object.get("additionalProperties").?.bool);
}

test "object alternatives reject contradictory ordinary object metadata" {
    const schema = FunctionSchema{
        .name = "invalid_alternative",
        .description = "invalid alternative",
        .input_schema = .{
            .properties = &.{.{ .name = "value", .json_type = .string }},
            .one_of = &.{.{
                .properties = &.{.{ .name = "action", .json_type = .string }},
            }},
        },
    };

    try std.testing.expectError(
        error.InvalidObjectSchema,
        builtinFunctionSchemaJsonAlloc(std.testing.allocator, schema),
    );
}

test "cappedDescriptionAlloc appends explicit truncation marker" {
    const alloc = std.testing.allocator;
    const oversized = "x" ** (description_max_bytes + 20);

    const capped = try cappedDescriptionAlloc(alloc, oversized);
    defer alloc.free(capped);

    try std.testing.expectEqual(description_max_bytes, capped.len);
    try std.testing.expect(std.mem.endsWith(u8, capped, truncation_marker));
}

test "builtinFunctionSchemaJsonAlloc serializes strings and object schema" {
    const alloc = std.testing.allocator;
    const schema = FunctionSchema{
        .name = "read_file",
        .description = "Read \"quoted\" paths. When to use: test escaping. When NOT to use: unescaped JSON.",
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string, .description = "File path \"with quotes\"." },
            },
            .required = &.{"path"},
        },
    };

    const json = try builtinFunctionSchemaJsonAlloc(alloc, schema);
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("read_file", parsed.value.object.get("name").?.string);
    try std.testing.expect(std.mem.find(u8, json, "\\\"quoted\\\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\\\"with quotes\\\"") != null);
}

test "builtinFunctionSchemaJsonAlloc serializes every supported property shape" {
    const alloc = std.testing.allocator;
    const object_value_schema = ObjectSchema{
        .properties = &.{.{ .name = "name", .json_type = .string }},
        .required = &.{"name"},
        .additional_properties = false,
    };
    const array_item_schema = ObjectSchema{
        .properties = &.{.{ .name = "id", .json_type = .integer }},
        .required = &.{"id"},
        .additional_properties = false,
    };
    const schema = FunctionSchema{
        .name = "schema_matrix",
        .description = "schema matrix",
        .input_schema = .{
            .properties = &.{
                .{
                    .name = "text",
                    .json_type = .string,
                    .description = "bounded choice",
                    .shape = &.{ .enum_values = &.{ "alpha", "beta" } },
                    .bounds = &.{ .min_length = 1, .max_length = 8 },
                },
                .{ .name = "count", .json_type = .integer, .bounds = &.{ .minimum = 2, .maximum = 9 } },
                .{ .name = "enabled", .json_type = .boolean },
                .{ .name = "config", .json_type = .object, .shape = &.{ .object = &object_value_schema } },
                .{
                    .name = "tags",
                    .json_type = .array,
                    .bounds = &.{ .min_items = 1, .max_items = 3 },
                    .shape = &.{ .array_values = .{ .json_type = .string, .enum_values = &.{ "red", "blue" } } },
                },
                .{ .name = "records", .json_type = .array, .shape = &.{ .array_objects = &array_item_schema } },
            },
            .required = &.{ "text", "count", "enabled", "config", "tags", "records" },
            .additional_properties = false,
            .min_properties = 6,
            .max_properties = 6,
        },
    };

    const json = try builtinFunctionSchemaJsonAlloc(alloc, schema);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const input_schema = parsed.value.object.get("inputSchema").?.object;
    try std.testing.expectEqualStrings("object", input_schema.get("type").?.string);
    try std.testing.expectEqual(false, input_schema.get("additionalProperties").?.bool);
    try std.testing.expectEqual(@as(i64, 6), input_schema.get("minProperties").?.integer);
    try std.testing.expectEqual(@as(i64, 6), input_schema.get("maxProperties").?.integer);
    try std.testing.expectEqual(@as(usize, 6), input_schema.get("required").?.array.items.len);

    const properties = input_schema.get("properties").?.object;
    const text_property = properties.get("text").?.object;
    try std.testing.expectEqualStrings("string", text_property.get("type").?.string);
    try std.testing.expectEqualStrings("bounded choice", text_property.get("description").?.string);
    try std.testing.expectEqual(@as(usize, 2), text_property.get("enum").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), text_property.get("minLength").?.integer);
    try std.testing.expectEqual(@as(i64, 8), text_property.get("maxLength").?.integer);

    const count_property = properties.get("count").?.object;
    try std.testing.expectEqualStrings("integer", count_property.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 2), count_property.get("minimum").?.integer);
    try std.testing.expectEqual(@as(i64, 9), count_property.get("maximum").?.integer);
    try std.testing.expectEqualStrings("boolean", properties.get("enabled").?.object.get("type").?.string);

    const config_property = properties.get("config").?.object;
    try std.testing.expectEqualStrings("object", config_property.get("type").?.string);
    try std.testing.expectEqual(false, config_property.get("additionalProperties").?.bool);
    try std.testing.expectEqualStrings(
        "string",
        config_property.get("properties").?.object.get("name").?.object.get("type").?.string,
    );

    const tags_property = properties.get("tags").?.object;
    try std.testing.expectEqualStrings("array", tags_property.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 1), tags_property.get("minItems").?.integer);
    try std.testing.expectEqual(@as(i64, 3), tags_property.get("maxItems").?.integer);
    try std.testing.expectEqualStrings("string", tags_property.get("items").?.object.get("type").?.string);
    try std.testing.expectEqual(@as(usize, 2), tags_property.get("items").?.object.get("enum").?.array.items.len);

    const record_items = properties.get("records").?.object.get("items").?.object;
    try std.testing.expectEqualStrings("object", record_items.get("type").?.string);
    try std.testing.expectEqualStrings(
        "integer",
        record_items.get("properties").?.object.get("id").?.object.get("type").?.string,
    );
}

test "dynamicFunctionSchemaJsonAlloc wraps rendered input schema in the flattened envelope" {
    const alloc = std.testing.allocator;
    const description = ("d" ** (description_max_bytes + 1)) ++ "tail";
    const json = try dynamicFunctionSchemaJsonAlloc(alloc, "mcp_fs_read", description, "{\"type\":\"object\",\"properties\":{}}");
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("function", parsed.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("mcp_fs_read", parsed.value.object.get("name").?.string);
    try std.testing.expectEqualStrings(description, parsed.value.object.get("description").?.string);
    try std.testing.expect(parsed.value.object.get("inputSchema").?.object.get("properties") != null);
    try std.testing.expect(parsed.value.object.get("function") == null);
}
