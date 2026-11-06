const std = @import("std");
const flatzz = @import("flatzz");
const compiler = @import("flatzz_compiler");
const codegen = @import("codegen");
const generated = @import("generated");

test "fresh Reading output builds verifies reads and mutates using only flatzz" {
    const Reading = generated.Reading;
    var storage: Reading.Storage(6, 3, .{ .count = 2, .bytes = 4 }, 1) = .{};
    const location: generated.Location = .{ .coordinates = .{ .latitude = 1, .longitude = 2 }, .altitude = 3 };
    const bytes = try Reading.write(&storage.buffer, .{
        .value = 1.5,
        .label = "sensor",
        .samples = &.{ 1, 2, 3 },
        .tags = &.{ "ab", "cd" },
        .temperature = 0,
        .status = .ok,
        .location = location,
        .history = &.{location},
        .calibration = .{ .gains = .{ 1, 2, 3 }, .locations = .{ location, location } },
    }, .{ .force_defaults = true });
    try Reading.verify(bytes, .{});
    const view = try Reading.read(bytes);
    try std.testing.expectEqual(@as(u8, 1), @backingInt(view.status));
    try std.testing.expectEqual(@as(?f32, 0), view.temperature);
    try std.testing.expectEqual(@as(f32, 3), (try view.calibration.?.read()).gains[2]);
    try std.testing.expect(try Reading.update(bytes, .sequence, 42));
    try (try Reading.mutableLocation(bytes)).?.update(.altitude, 9);
    try std.testing.expectEqual(@as(f32, 9), (try (try Reading.read(bytes)).location.?.read()).altitude);
    try (try (try Reading.mutableHistory(bytes)).?.get(0)).update(.altitude, 8);
    try std.testing.expectEqual(@as(f32, 8), try (try (try Reading.read(bytes)).history.?.get(0)).get(.altitude));
    try Reading.verify(bytes, .{});
}

test "fresh union output uses paired IDs and struct string table payloads" {
    var storage: [512]u8 align(flatzz.storage_alignment) = undefined;
    var builder = flatzz.Builder.init(&storage);
    const temperature = try generated.Temperature.Schema.create(&builder, .{ .value = 25 });
    const point = try builder.createStruct(generated.Location.Layout, .{
        .coordinates = .{ .latitude = 1, .longitude = 2 },
        .altitude = 3,
    });
    const text = try builder.createString("text");
    const root = try generated.ReadingMessage.Schema.create(&builder, .{
        .current = .{ .temperature = temperature },
        .history = &.{ .none, .{ .location = point }, .{ .text = text }, .{ .previous = point } },
    });
    const bytes = try builder.finish(root, .ordinary);
    try generated.ReadingMessage.verify(bytes, .{});
    const message = try generated.ReadingMessage.read(bytes);
    try std.testing.expectEqual(@as(f32, 25), (try generated.Temperature.Schema.read(message.current.temperature)).value);
    try std.testing.expectEqualStrings("text", (try message.history.?.get(2)).text);
    try std.testing.expectEqual(@as(f32, 3), try (try message.history.?.get(3)).previous.get(.altitude));
}

test "unsupported wire features and invalid references produce no source" {
    const reflection = compiler.reflection;
    try std.testing.expectError(error.UnsupportedFeature, codegen.generate(std.testing.allocator, .{
        .objects = &.{},
        .enums = &.{},
        .advanced_features = .{ .unknown_bits = 1 },
    }));
    for ([_]reflection.Type{
        .{ .base_type = .Obj, .index = 5 },
        .{ .base_type = .Int, .index = -2 },
        .{ .base_type = .Int, .index = 0 },
        .{ .base_type = .Vector64 },
    }) |field_type| {
        const schema: reflection.Schema = .{
            .enums = &.{},
            .objects = &.{.{
                .name = "T",
                .fields = &.{.{ .name = "x", .type = &field_type }},
            }},
        };
        const expected = if (field_type.base_type == .Vector64) error.UnsupportedFeature else error.InvalidSchema;
        try std.testing.expectError(expected, codegen.generate(std.testing.allocator, schema));
    }
}

const cases = @import("cases");

test "generated defaults retain integer limits enum bits float bits and sparse wire IDs" {
    const packet: cases.Packet = .{};
    try std.testing.expectEqual(std.math.minInt(i64), packet.low);
    try std.testing.expectEqual(std.math.maxInt(u64), packet.high);
    try std.testing.expectEqual(cases.Signed.low, packet.signed);
    try std.testing.expectEqual(cases.Wide.max, packet.wide);
    try std.testing.expect(packet.optional == null);
    try std.testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast(packet.negative_zero)));
    try std.testing.expectEqual(@as(f64, 0.1), packet.fraction);
    try std.testing.expectEqual(std.math.inf(f64), packet.positive_inf);
    try std.testing.expectEqual(-std.math.inf(f32), packet.negative_inf);
    try std.testing.expect(std.math.isNan(packet.not_a_number));
    try std.testing.expect(packet.@"const");
    try std.testing.expect(!@hasField(cases.Packet, "legacy"));
    try std.testing.expectEqual(@as(usize, 1), cases.Packet.fields.low.wire_id);
    try std.testing.expectEqualStrings("GENR", cases.file_identifier);
    try std.testing.expectEqualStrings("gen", cases.file_extension);
}

test "generated recursive references required fields enum vectors and struct arrays serialize" {
    var storage: [2048]u8 align(flatzz.storage_alignment) = undefined;
    var builder = flatzz.Builder.init(&storage);
    const name = try builder.createString("child");
    var child = try cases.Node.Schema.Context.init(&builder);
    try cases.Node.Schema.addFields(&child, .{}, .{ name, null });
    const child_handle = try cases.Node.Schema.endTable(&child);
    const nodes = try builder.createOffsetVector(&.{child_handle});
    const text = try builder.createString("required");
    const statuses = try builder.createVector(cases.Signed, &.{ .low, .high });
    var root = try cases.Packet.Schema.Context.init(&builder);
    var offsets: cases.Packet.Schema.Offsets = @splat(null);
    offsets[cases.Packet.fields.required_text.wire_id] = text;
    offsets[cases.Packet.fields.nodes.wire_id] = nodes;
    offsets[cases.Packet.fields.child.wire_id] = child_handle;
    offsets[cases.Packet.fields.statuses.wire_id] = statuses;
    try cases.Packet.Schema.addFields(&root, .{
        .block = .{
            .points = .{ .{ .x = -2, .status = .low }, .{ .x = 3, .status = .high } },
            .values = .{ .zero, .max },
        },
    }, offsets);
    const bytes = try builder.finish(try cases.Packet.Schema.endTable(&root), .{ .identifier = cases.file_identifier.* });
    try cases.Packet.verify(bytes, .{ .frame = .{ .identifier = cases.file_identifier.* } });
    const view = try cases.Packet.read(bytes);
    try std.testing.expectEqualStrings("child", (try cases.Node.Schema.read(view.child.?)).name.?);
    try std.testing.expectEqual(cases.Signed.high, try view.statuses.?.get(1));
    try std.testing.expectEqual(cases.Wide.max, (try view.block.?.read()).values[1]);
    builder = flatzz.Builder.init(&storage);
    var missing = try cases.Node.Schema.Context.init(&builder);
    try std.testing.expectError(error.MissingRequiredField, cases.Node.Schema.addFields(&missing, .{}, .{ null, null }));
}

test "namespaces retain distinct qualified declarations and generated-name collisions fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try compiler.parser.parse(arena.allocator(), "namespace A; table Node { value:int; } namespace B; table Node { other:A.Node; } root_type Node;");
    const source = try codegen.generate(std.testing.allocator, schema);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "@\"A.Node\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@\"B.Node\"") != null);
    for ([_][]const u8{
        "table T { Schema:int; }",
        "enum E:byte { HTTP=0, Http=1 }",
        "table T { x:[int]; mutableX:int; }",
    }) |input| {
        const invalid = try compiler.parser.parse(arena.allocator(), input);
        try std.testing.expectError(error.NameCollision, codegen.generate(std.testing.allocator, invalid));
    }
}

test "generation releases descriptions AST source and rendered output on allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try compiler.parser.parse(arena.allocator(), "enum E:byte { Negative=-1, Zero=0 } struct S { x:[E:2]; } table T { s:S; names:[string]; } root_type T;");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, generateAndFree, .{schema});
}

fn generateAndFree(backing: std.mem.Allocator, schema: compiler.reflection.Schema) !void {
    var failing = std.testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
    const allocator = failing.allocator();
    const source = try codegen.generate(allocator, schema);
    defer allocator.free(source);
}

test "qualified types and keyword fields compile without helper-name shadowing" {
    const names = @import("names");
    const FirstTable = names.@"One.Schema";
    const SecondTable = names.@"Two.Schema";
    var storage: [256]u8 align(flatzz.storage_alignment) = undefined;
    var builder = flatzz.Builder.init(&storage);
    const first_handle = try FirstTable.Schema.create(&builder, .{});
    var second_context = try SecondTable.Schema.Context.init(&builder);
    try SecondTable.Schema.addFields(&second_context, .{}, .{first_handle});
    const bytes = try builder.finish(try SecondTable.Schema.endTable(&second_context), .ordinary);
    try SecondTable.verify(bytes, .{});
    const view = try SecondTable.read(bytes);
    try std.testing.expectEqual(@as(i32, 9), (try FirstTable.Schema.read(view.other.?)).@"const");
}
