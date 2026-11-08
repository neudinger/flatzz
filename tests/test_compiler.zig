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

test "primitive facts retain wire widths signedness and unknown code fallbacks" {
    const expected = [_]struct {
        base: reflection.BaseType,
        scalar: bool,
        unsigned: bool,
        bytes: u32,
    }{
        .{ .base = .None, .scalar = false, .unsigned = false, .bytes = 1 },
        .{ .base = .UType, .scalar = true, .unsigned = true, .bytes = 1 },
        .{ .base = .Bool, .scalar = true, .unsigned = true, .bytes = 1 },
        .{ .base = .Byte, .scalar = true, .unsigned = false, .bytes = 1 },
        .{ .base = .UByte, .scalar = true, .unsigned = true, .bytes = 1 },
        .{ .base = .Short, .scalar = true, .unsigned = false, .bytes = 2 },
        .{ .base = .UShort, .scalar = true, .unsigned = true, .bytes = 2 },
        .{ .base = .Int, .scalar = true, .unsigned = false, .bytes = 4 },
        .{ .base = .UInt, .scalar = true, .unsigned = true, .bytes = 4 },
        .{ .base = .Long, .scalar = true, .unsigned = false, .bytes = 8 },
        .{ .base = .ULong, .scalar = true, .unsigned = true, .bytes = 8 },
        .{ .base = .Float, .scalar = true, .unsigned = false, .bytes = 4 },
        .{ .base = .Double, .scalar = true, .unsigned = false, .bytes = 8 },
        .{ .base = .String, .scalar = false, .unsigned = false, .bytes = 4 },
        .{ .base = .Vector, .scalar = false, .unsigned = false, .bytes = 4 },
        .{ .base = .Obj, .scalar = false, .unsigned = false, .bytes = 4 },
        .{ .base = .Union, .scalar = false, .unsigned = false, .bytes = 4 },
        .{ .base = .Array, .scalar = false, .unsigned = false, .bytes = 4 },
        .{ .base = .Vector64, .scalar = false, .unsigned = false, .bytes = 8 },
        .{ .base = .MaxBaseType, .scalar = false, .unsigned = false, .bytes = 4 },
    };
    for (expected) |item| {
        try std.testing.expectEqual(item.scalar, item.base.isScalar());
        try std.testing.expectEqual(item.unsigned, item.base.isUnsigned());
        try std.testing.expectEqual(item.bytes, item.base.byteSize());
    }
    for ([_]i8{ -1, 127 }) |code| {
        const base: reflection.BaseType = @fromBackingInt(code);
        try std.testing.expect(!base.isScalar());
        try std.testing.expect(!base.isUnsigned());
        try std.testing.expectEqual(@as(u32, 4), base.byteSize());
    }
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
    // RPC references revisit the cached Object subtree at a greater depth.
    _ = try compiler.bfbs.decodeWithOptions(arena.allocator(), bytes, .{ .max_depth = 6 });
    try std.testing.expectError(
        error.DepthLimit,
        compiler.bfbs.decodeWithOptions(arena.allocator(), bytes, .{ .max_depth = 5 }),
    );
}

test "BFBS decoding rejects malformed framing required fields and string payloads" {
    const objects = [_]reflection.Object{.{ .name = "Malformed", .fields = &.{} }};
    const schema: reflection.Schema = .{ .objects = &objects, .enums = &.{} };
    const bytes = try compiler.bfbs.encode(std.testing.allocator, schema);
    defer std.testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Shift objects by eight bytes so their existing scalar alignment is retained.
    const prefixed = try std.testing.allocator.alloc(u8, bytes.len + 8);
    defer std.testing.allocator.free(prefixed);
    std.mem.writeInt(u32, prefixed[0..4], @intCast(prefixed.len - 4), .little);
    std.mem.writeInt(u32, prefixed[4..8], std.mem.readInt(u32, bytes[0..4], .little) + 4, .little);
    @memcpy(prefixed[8..12], bytes[4..8]);
    @memset(prefixed[12..16], 0);
    @memcpy(prefixed[16..], bytes[8..]);
    const decoded = try compiler.bfbs.decodeWithOptions(arena.allocator(), prefixed, .{
        .format = .size_prefixed,
    });
    try std.testing.expectEqualStrings("Malformed", decoded.objects[0].name);
    try std.testing.expectError(
        error.InvalidBfbs,
        compiler.bfbs.decode(arena.allocator(), bytes[0..7]),
    );
    bytes[4] = 'X';
    try std.testing.expectError(
        error.InvalidBfbs,
        compiler.bfbs.decode(arena.allocator(), bytes),
    );
    bytes[4] = 'B';
    const name_start = std.mem.indexOf(u8, bytes, "Malformed").?;
    bytes[name_start] = 0xff;
    try std.testing.expectError(
        error.InvalidBfbs,
        compiler.bfbs.decode(arena.allocator(), bytes),
    );
    // Independent wire fixture: identified root with a valid empty vtable.
    // The required objects/enums references are absent.
    const missing_required = [_]u8{
        12, 0, 0, 0, 'B', 'F', 'B', 'S',
        4,  0, 4, 0, 4,   0,   0,   0,
    };
    try std.testing.expectError(
        error.InvalidBfbs,
        compiler.bfbs.decode(arena.allocator(), &missing_required),
    );
}

test "BFBS resource limits precede allocation failures" {
    const bytes = try compiler.bfbs.encode(std.testing.allocator, .{
        .objects = &.{},
        .enums = &.{},
    });
    defer std.testing.allocator.free(bytes);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    try std.testing.expectError(error.DepthLimit, compiler.bfbs.decodeWithOptions(
        allocator,
        bytes,
        .{ .max_depth = 0, .max_objects = 0, .max_work = 0 },
    ));
    try std.testing.expectError(error.ObjectLimit, compiler.bfbs.decodeWithOptions(
        allocator,
        bytes,
        .{ .max_objects = 0, .max_work = 0 },
    ));
    try std.testing.expectError(error.WorkLimit, compiler.bfbs.decodeWithOptions(
        allocator,
        bytes,
        .{ .max_work = 0 },
    ));
    try std.testing.expect(!failing.has_induced_failure);
}

test "BFBS allocation failures release encoding buffers and decoder arenas" {
    const field_type: reflection.Type = .{ .base_type = .Int };
    const objects = [_]reflection.Object{.{
        .name = "LargeObject",
        .fields = &.{.{ .name = "value", .type = &field_type }},
        .attributes = &.{
            .{
                .key = "second",
                .value = "payloadpayloadpayloadpayloadpayloadpayloadpayloadpayload" ++
                    "payloadpayloadpayloadpayloadpayloadpayloadpayloadpayload" ++
                    "payloadpayloadpayloadpayloadpayloadpayloadpayloadpayload" ++
                    "payloadpayloadpayloadpayloadpayloadpayloadpayloadpayload" ++
                    "payloadpayloadpayloadpayloadpayloadpayloadpayloadpayload" ++
                    "payloadpayloadpayloadpayloadpayloadpayloadpayloadpayload",
            },
            .{ .key = "first", .value = "value" },
        },
        .documentation = &.{ "first line", "second line" },
    }};
    const schema: reflection.Schema = .{
        .objects = &objects,
        .enums = &.{},
        .root_table = &objects[0],
        .services = &.{.{
            .name = "Transport",
            .calls = &.{.{
                .name = "Send",
                .request = &objects[0],
                .response = &objects[0],
            }},
        }},
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, encodeAndFree, .{schema});
    const bytes = try compiler.bfbs.encode(std.testing.allocator, schema);
    defer std.testing.allocator.free(bytes);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeAndRelease, .{bytes});
}

fn encodeAndFree(backing: std.mem.Allocator, schema: reflection.Schema) !void {
    var failing = std.testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
    const allocator = failing.allocator();
    const bytes = try compiler.bfbs.encode(allocator, schema);
    defer allocator.free(bytes);
}

fn decodeAndRelease(backing: std.mem.Allocator, bytes: []const u8) !void {
    var failing = std.testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
    var arena = std.heap.ArenaAllocator.init(failing.allocator());
    defer arena.deinit();
    _ = try compiler.bfbs.decode(arena.allocator(), bytes);
}
