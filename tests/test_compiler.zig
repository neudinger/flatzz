//! Native FBS parsing and reflection metadata tests.
const std = @import("std");
const compiler = @import("flatzz_compiler");

const reflection = compiler.reflection;

test {
    std.testing.refAllDecls(compiler);
}

test "native FBS parsing returns the exported reflection model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema: compiler.reflection.Schema = try compiler.parser.parse(
        arena.allocator(),
        "table Reading { value:uint = 42; } root_type Reading;",
    );
    try std.testing.expectEqualStrings("Reading", schema.root_table.?.name);
    try std.testing.expectEqual(@as(i64, 42), schema.root_table.?.fields[0].default_integer);
}

test "BFBS reflected records preserve metadata and shared object references" {
    const field_type: reflection.Type = .{ .base_type = .Int };
    const enum_type: reflection.Type = .{ .base_type = .Short };
    const objects = [_]reflection.Object{.{
        .name = "Message",
        .fields = &.{.{ .name = "value", .type = &field_type }},
        .attributes = &.{.{ .key = "note", .value = "root" }},
    }};
    const schema: reflection.Schema = .{
        .objects = &objects,
        .enums = &.{.{
            .name = "State",
            .values = &.{.{ .name = "Ready", .value = 7 }},
            .underlying_type = &enum_type,
        }},
        .root_table = &objects[0],
        .services = &.{.{
            .name = "Transport",
            .calls = &.{.{
                .name = "Send",
                .request = &objects[0],
                .response = &objects[0],
            }},
        }},
        .advanced_features = .{ .optional_scalars = true, .unknown_bits = 1 << 12 },
        .fbs_files = &.{.{
            .filename = "//message.fbs",
            .included_filenames = &.{"//shared.fbs"},
        }},
    };
    const bytes = try compiler.bfbs.encode(std.testing.allocator, schema);
    defer std.testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decoded = try compiler.bfbs.decode(arena.allocator(), bytes);
    const object = &decoded.objects[0];
    try std.testing.expectEqualStrings("Message", object.name);
    try std.testing.expectEqualStrings("value", object.fields[0].name);
    try std.testing.expectEqual(.Int, object.fields[0].type.base_type);
    try std.testing.expectEqualStrings("note", object.attributes.?[0].key);
    try std.testing.expectEqualStrings("root", object.attributes.?[0].value.?);
    try std.testing.expectEqualStrings("State", decoded.enums[0].name);
    try std.testing.expectEqual(.Short, decoded.enums[0].underlying_type.base_type);
    try std.testing.expectEqualStrings("Ready", decoded.enums[0].values[0].name);
    try std.testing.expectEqual(@as(i64, 7), decoded.enums[0].values[0].value);
    try std.testing.expectEqualStrings("Transport", decoded.services.?[0].name);
    const call = decoded.services.?[0].calls.?[0];
    try std.testing.expectEqualStrings("Send", call.name);
    try std.testing.expect(decoded.root_table.? == object);
    try std.testing.expect(call.request == object and call.response == object);
    try std.testing.expectEqualDeep(schema.advanced_features, decoded.advanced_features);
    const schema_file = decoded.fbs_files.?[0];
    try std.testing.expectEqualStrings("//message.fbs", schema_file.filename);
    try std.testing.expectEqualStrings("//shared.fbs", schema_file.included_filenames.?[0]);
    const reencoded = try compiler.bfbs.encode(std.testing.allocator, decoded);
    defer std.testing.allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, bytes, reencoded);
}
