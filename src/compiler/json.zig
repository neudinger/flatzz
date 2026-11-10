//! Portable schema-metadata JSON shared by native and Wasm compilers.
//! This describes declarations, not application message values. Numeric feature bits,
//! omitted null members, and quoted nonfinite real defaults match the native CLI.
//! Integer defaults retain the reflection model's signed storage representation;
//! do not round-trip this output through JavaScript Number when precision matters.
const std = @import("std");
const reflection = @import("reflection.zig");

/// Write schema metadata directly to a caller-configured JSON writer without allocating
/// a second metadata tree. The schema must remain valid for the call. Writer errors
/// propagate and may leave partial output; choose framing/whitespace on the JSON writer.
pub fn write(schema: reflection.Schema, json: *std.json.Stringify) std.json.Stringify.Error!void {
    try writeJson(schema, json);
}

/// Walk the reflection model without constructing a second tree. JSON uses
/// numeric feature bits, omits null fields, and quotes nonfinite real defaults.
fn writeJson(value: anytype, json: *std.json.Stringify) std.json.Stringify.Error!void {
    const Value = @TypeOf(value);
    if (Value == reflection.AdvancedFeatures) return json.write(@as(u64, @bitCast(value)));
    switch (@typeInfo(Value)) {
        .@"struct" => |structure| {
            try json.beginObject();
            inline for (structure.field_names) |name| {
                const member = @field(value, name);
                const omit = if (@typeInfo(@TypeOf(member)) == .optional) member == null else false;
                if (!omit) {
                    try json.objectField(name);
                    try writeJson(member, json);
                }
            }
            try json.endObject();
        },
        .optional => if (value) |member| try writeJson(member, json) else try json.write(null),
        .pointer => |pointer| switch (pointer.size) {
            .one => try writeJson(value.*, json),
            .slice => if (pointer.child == u8) {
                try json.write(value);
            } else {
                try json.beginArray();
                for (value) |member| try writeJson(member, json);
                try json.endArray();
            },
            else => @compileError("reflection JSON requires single pointers or slices"),
        },
        .float => if (std.math.isFinite(value)) {
            try json.write(value);
        } else {
            try json.write(if (std.math.isNan(value)) "nan" else if (value < 0) "-inf" else "inf");
        },
        else => try json.write(value),
    }
}
