const std = @import("std");
const flatzz = @import("flatzz");
const compiler = @import("flatzz_compiler");
const codegen = @import("codegen");
const generated = @import("generated");
const cases = @import("cases");
const names = @import("names");

const reflection = compiler.reflection;

const invalid_reference_types = [_]reflection.Type{
    .{ .base_type = .Obj, .index = 5 },
    .{ .base_type = .Int, .index = -2 },
    .{ .base_type = .Int, .index = 0 },
    .{ .base_type = .Vector64 },
};
const collision_schemas = [_][]const u8{
    "table T { Schema:int; }",
    "table Reading { Field:int; }",
    "table Reading { View:int; }",
    "table Reading { serialize:int; }",
    "table Reading { read:int; }",
    "table Reading { update:int; }",
    "table Reading { verify:int; }",
    "struct Location { Field:int; }",
    "struct Location { View:int; }",
    "struct Location { serialize:int; }",
    "struct Location { read:int; }",
    "struct Location { update:int; }",
    "struct Location { verify:int; }",
    "enum E:byte { HTTP=0, Http=1 }",
    "table T { borrowMutable:int; }",
    "struct Location { borrowMutable:int; }",
};

test "fresh Reading output builds verifies reads and mutates using only flatzz" {
    const Reading = generated.Reading;
    try std.testing.expect(!@hasDecl(Reading, "write"));
    try std.testing.expect(!@hasDecl(Reading.Schema, "writeRoot"));
    try std.testing.expect(!@hasDecl(Reading, "Storage"));
    try std.testing.expect(!@hasDecl(generated.ReadingMessage, "Storage"));
    try std.testing.expect(!@hasDecl(generated.Temperature, "Storage"));
    try std.testing.expect(!@hasDecl(Reading, "mutableLocation"));
    var storage: flatzz.Storage(Reading.Schema, .{
        .label = 6,
        .samples = 3,
        .tags = .{ .count = 2, .bytes = 4 },
        .history = 1,
    }, .{}) = .{};
    const location: generated.Location = .{
        .coordinates = .{ .latitude = 1, .longitude = 2 },
        .altitude = 3,
    };
    const value: Reading = .{
        .value = 1.5,
        .label = "sensor",
        .samples = &.{ 1, 2, 3 },
        .tags = &.{ "ab", "cd" },
        .temperature = 0,
        .status = .ok,
        .location = location,
        .history = &.{location},
        .calibration = .{ .gains = .{ 1, 2, 3 }, .locations = .{ location, location } },
    };
    const bytes = try value.serialize(&storage.buffer, .{ .force_defaults = true });
    var output: [storage.buffer.len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writer.writeAll(bytes);
    try std.testing.expectEqualSlices(u8, bytes, writer.buffered());
    try Reading.verify(bytes, .{});
    const view = try Reading.read(bytes);
    try std.testing.expectEqual(@as(u8, 1), @backingInt(view.status));
    try std.testing.expectEqual(@as(?f32, 0), view.temperature);
    try std.testing.expectEqual(@as(f32, 3), (try view.calibration.?.read()).gains[2]);
    try std.testing.expect(try Reading.update(bytes, .sequence, 42));
    const table = try flatzz.MutableTable.from(bytes, .root);
    const samples = (try Reading.borrowMutable(table, .samples)).?;
    const tags = (try Reading.borrowMutable(table, .tags)).?;
    try std.testing.expectEqual(@as(f32, 2), try samples.get(1));
    try std.testing.expectEqualStrings("cd", try tags.get(1));
    const calibration = (try Reading.borrowMutable(table, .calibration)).?;
    try (try calibration.get(.gains)).update(2, 4);
    try std.testing.expectEqual(@as(f32, 4), (try view.calibration.?.read()).gains[2]);
    try (try Reading.borrowMutable(table, .location)).?.update(.altitude, 9);
    try std.testing.expectEqual(
        @as(f32, 9),
        (try (try Reading.read(bytes)).location.?.read()).altitude,
    );
    try (try (try Reading.borrowMutable(table, .history)).?.get(0)).update(.altitude, 8);
    try std.testing.expectEqual(
        @as(f32, 8),
        try (try (try Reading.read(bytes)).history.?.get(0)).get(.altitude),
    );
    try Reading.verify(bytes, .{});
}

test "serialize is generated for every native table schema" {
    inline for (.{
        generated.Reading, generated.Temperature,    cases.NativePacket,
        cases.Empty,       generated.ReadingMessage, cases.Node,
        cases.Packet,      cases.UnionPacket,        cases.UnionList,
        cases.TablePacket, cases.TableList,          names.@"Two.Schema",
        cases.UnionNode,
    }) |Native| {
        try std.testing.expect(@hasDecl(Native, "serialize"));
        try std.testing.expect(@hasDecl(Native, "read"));
        try std.testing.expect(@hasDecl(Native, "update"));
        try std.testing.expect(@hasDecl(Native, "borrowMutable"));
        try std.testing.expect(@hasDecl(Native, "verify"));
    }
    inline for (.{
        "legacy_child", "legacy_children", "legacy_payload", "legacy_payloads",
    }) |field| {
        try std.testing.expect(!@hasField(cases.NativePacket, field));
    }
    var storage: [128]u8 align(flatzz.storage_alignment) = undefined;
    const value: cases.NativePacket = .{ .value = 42 };
    const bytes = try value.serialize(&storage, .{});
    try cases.NativePacket.verify(bytes, .{});
    try std.testing.expectEqual(@as(i32, 42), (try cases.NativePacket.read(bytes)).value);
    const empty: cases.Empty = .{};
    try cases.Empty.verify(try empty.serialize(&storage, .{}), .{});
}

test "generated native child tables and table vectors serialize recursively" {
    const leaf: cases.Node = .{ .name = "leaf" };
    const branch: cases.Node = .{ .name = "branch", .next = &leaf };
    const value: cases.Packet = .{
        .required_text = "required",
        .child = &branch,
        .nodes = &.{ &leaf, &branch },
        .statuses = &.{ .low, .high },
        .block = .{
            .points = .{ .{ .x = -2, .status = .low }, .{ .x = 3, .status = .high } },
            .values = .{ .zero, .max },
        },
    };
    var storage: [4096]u8 align(flatzz.storage_alignment) = undefined;
    const bytes = try value.serialize(&storage, .{});
    try cases.Packet.verify(bytes, .{});
    const view = try cases.Packet.read(bytes);
    try std.testing.expectEqualStrings("branch", (try cases.Node.Schema.read(view.child.?)).name.?);
    const nested = (try cases.Node.Schema.read(view.child.?)).next.?;
    try std.testing.expectEqualStrings("leaf", (try cases.Node.Schema.read(nested)).name.?);
    try std.testing.expectEqual(@as(usize, 2), view.nodes.?.element_count);
    try std.testing.expectEqualStrings(
        "branch",
        (try cases.Node.Schema.read(try view.nodes.?.get(1))).name.?,
    );
    try std.testing.expectEqual(cases.Signed.high, try view.statuses.?.get(1));
    try std.testing.expectEqual(cases.Wide.max, (try view.block.?.read()).values[1]);
    try std.testing.expectError(
        error.MissingRequiredField,
        cases.Node.serialize(.{}, &storage, .{}),
    );
}

test "generated native union payloads and recursive union graphs serialize" {
    const temperature: generated.Temperature = .{ .value = 25.5 };
    const location: generated.Location = .{
        .coordinates = .{ .latitude = 1, .longitude = 2 },
        .altitude = 3,
    };
    const value: generated.ReadingMessage = .{
        .current = .{ .temperature = &temperature },
        .history = &.{
            .none,                     .{ .location = location },
            .{ .text = "native é" },
            .{ .previous = location },
        },
    };
    var storage: [2048]u8 align(flatzz.storage_alignment) = undefined;
    const bytes = try value.serialize(&storage, .{});
    try generated.ReadingMessage.verify(bytes, .{});
    const view = try generated.ReadingMessage.read(bytes);
    try std.testing.expectEqual(
        temperature.value,
        (try generated.Temperature.Schema.read(view.current.temperature)).value,
    );
    try std.testing.expectEqual(@as(usize, 4), view.history.?.element_count);
    try std.testing.expect(try view.history.?.get(0) == .none);
    try std.testing.expectEqualDeep(location, try (try view.history.?.get(1)).location.read());
    try std.testing.expectEqualStrings("native é", (try view.history.?.get(2)).text);
    try std.testing.expectEqualDeep(location, try (try view.history.?.get(3)).previous.read());
    const leaf: cases.UnionNode = .{};
    const branch: cases.UnionNode = .{ .next = .{ .union_node = &leaf } };
    const root: cases.UnionNode = .{ .next = .{ .union_node = &branch } };
    const recursive = try root.serialize(&storage, .{});
    try cases.UnionNode.verify(recursive, .{});
    const first = (try cases.UnionNode.read(recursive)).next.union_node;
    const second = (try cases.UnionNode.Schema.read(first)).next.union_node;
    try std.testing.expect((try cases.UnionNode.Schema.read(second)).next == .none);
}

test "fresh union output uses paired IDs and struct string table payloads" {
    const Temperature = generated.Temperature;
    const ReadingMessage = generated.ReadingMessage;
    var storage: [512]u8 align(flatzz.storage_alignment) = undefined;
    var builder = flatzz.Builder.init(&storage);
    const temperature = try Temperature.Schema.create(&builder, .{ .value = 25 }, .{});
    const point = try builder.createStruct(generated.Location.Layout, .{
        .coordinates = .{ .latitude = 1, .longitude = 2 },
        .altitude = 3,
    });
    const text = try builder.createString("text");
    const history_handles = try builder.createReferenceVector(
        &[_]generated.ReadingPayload.Handle{
            .none, .{ .location = point }, .{ .text = text }, .{ .previous = point },
        },
        .{ .union_type = generated.ReadingPayload },
    );
    var root = try ReadingMessage.Schema.Context.init(&builder);
    try ReadingMessage.Schema.addFields(&root, .{
        .current = .{ .temperature = temperature },
        .history = history_handles,
    });
    const bytes = try builder.finish(try ReadingMessage.Schema.endTable(&root), .ordinary);
    try ReadingMessage.verify(bytes, .{});
    const message = try ReadingMessage.read(bytes);
    try std.testing.expectEqual(
        @as(f32, 25),
        (try Temperature.Schema.read(message.current.temperature)).value,
    );
    try std.testing.expectEqualStrings("text", (try message.history.?.get(2)).text);
    const table = try flatzz.MutableTable.from(bytes, .root);
    const current = try ReadingMessage.borrowMutable(table, .current);
    try std.testing.expect(try Temperature.Schema.update(current.temperature, .value, 26));
    const history = (try ReadingMessage.borrowMutable(table, .history)).?;
    try (try history.get(1)).location.update(.altitude, 4);
    try std.testing.expectEqual(
        @as(f32, 26),
        (try Temperature.Schema.read(message.current.temperature)).value,
    );
    const location = (try message.history.?.get(1)).location;
    try std.testing.expectEqual(@as(f32, 4), try location.get(.altitude));
    // Both variants borrow the same inline payload, so each observes the update.
    try std.testing.expectEqual(
        @as(f32, 4),
        try (try message.history.?.get(3)).previous.get(.altitude),
    );
}

test "unsupported wire features and invalid references produce no source" {
    try std.testing.expectError(error.UnsupportedFeature, codegen.generate(std.testing.allocator, .{
        .objects = &.{},
        .enums = &.{},
        .advanced_features = .{ .unknown_bits = 1 },
    }));
    for (invalid_reference_types) |field_type| {
        const schema: reflection.Schema = .{
            .enums = &.{},
            .objects = &.{.{
                .name = "T",
                .fields = &.{.{ .name = "x", .type = &field_type }},
            }},
        };
        const expected = if (field_type.base_type == .Vector64)
            error.UnsupportedFeature
        else
            error.InvalidSchema;
        try std.testing.expectError(expected, codegen.generate(std.testing.allocator, schema));
    }
}

test "generated defaults retain integer limits enum bits float bits and sparse wire IDs" {
    const packet: cases.Packet = .{};
    const fields: cases.Packet.Schema.Fields = .{};
    try std.testing.expectEqual(std.math.minInt(i64), fields.low);
    try std.testing.expectEqual(std.math.maxInt(u64), fields.high);
    try std.testing.expectEqual(cases.Signed.low, fields.signed);
    try std.testing.expectEqual(cases.Wide.max, fields.wide);
    try std.testing.expect(fields.optional == null and fields.required_text == null);
    try std.testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast(fields.negative_zero)));
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
    try cases.Node.Schema.addFields(&child, .{ .name = name });
    const child_handle = try cases.Node.Schema.endTable(&child);
    const nodes = try builder.createReferenceVector(&.{child_handle}, .{});
    const text = try builder.createString("required");
    const statuses = try builder.createVector(cases.Signed, &.{ .low, .high });
    var root = try cases.Packet.Schema.Context.init(&builder);
    try cases.Packet.Schema.addFields(&root, .{
        .required_text = text,
        .nodes = nodes,
        .child = child_handle,
        .statuses = statuses,
        .block = .{
            .points = .{ .{ .x = -2, .status = .low }, .{ .x = 3, .status = .high } },
            .values = .{ .zero, .max },
        },
    });
    const bytes = try builder.finish(
        try cases.Packet.Schema.endTable(&root),
        .{ .identifier = cases.file_identifier.* },
    );
    try cases.Packet.verify(bytes, .{ .frame = .{ .identifier = cases.file_identifier.* } });
    const view = try cases.Packet.read(bytes);
    try std.testing.expectEqualStrings("child", (try cases.Node.Schema.read(view.child.?)).name.?);
    try std.testing.expectEqual(cases.Signed.high, try view.statuses.?.get(1));
    try std.testing.expectEqual(cases.Wide.max, (try view.block.?.read()).values[1]);
    builder = flatzz.Builder.init(&storage);
    var missing = try cases.Node.Schema.Context.init(&builder);
    try std.testing.expectError(
        error.MissingRequiredField,
        cases.Node.Schema.addFields(&missing, .{}),
    );
}

test "namespaces retain distinct qualified declarations and generated-name collisions fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try compiler.parser.parse(
        arena.allocator(),
        "namespace A; table Node { value:int; } namespace B; table Node { other:A.Node; } root_type Node;",
    );
    const source = try codegen.generate(std.testing.allocator, schema);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "@\"A.Node\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@\"B.Node\"") != null);
    for (collision_schemas) |input| {
        const invalid = try compiler.parser.parse(arena.allocator(), input);
        try std.testing.expectError(
            error.NameCollision,
            codegen.generate(std.testing.allocator, invalid),
        );
    }
}

test "generation releases descriptions AST source and rendered output on allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try compiler.parser.parse(
        arena.allocator(),
        "enum E:byte { Negative=-1, Zero=0 } struct S { x:[E:2]; } table T { s:S; names:[string]; } root_type T;",
    );
    try std.testing.checkAllAllocationFailures(std.testing.allocator, generateAndFree, .{schema});
}

fn generateAndFree(backing: std.mem.Allocator, schema: compiler.reflection.Schema) !void {
    var failing = std.testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
    const allocator = failing.allocator();
    const source = try codegen.generate(allocator, schema);
    defer allocator.free(source);
}

test "qualified types and keyword fields compile without helper-name shadowing" {
    const FirstTable = names.@"One.Schema";
    const SecondTable = names.@"Two.Schema";
    var storage: [256]u8 align(flatzz.storage_alignment) = undefined;
    var builder = flatzz.Builder.init(&storage);
    const first_handle = try FirstTable.Schema.create(&builder, .{}, .{});
    var second_context = try SecondTable.Schema.Context.init(&builder);
    try SecondTable.Schema.addFields(&second_context, .{ .other = first_handle });
    const bytes = try builder.finish(try SecondTable.Schema.endTable(&second_context), .ordinary);
    try SecondTable.verify(bytes, .{});
    const view = try SecondTable.read(bytes);
    try std.testing.expectEqual(@as(i32, 9), (try FirstTable.Schema.read(view.other.?)).@"const");
    try std.testing.expectEqual(@as(i32, 7), (try FirstTable.Schema.read(view.other.?)).write);
    const child = try FirstTable.Schema.read(view.other.?);
    try std.testing.expectEqual(@as(i32, 11), child.Storage);
    try std.testing.expectEqual(@as(i32, 13), child.mutableX);
    try std.testing.expect(child.x == null);
    const first: FirstTable = .{ .write = 42 };
    const serialized = try first.serialize(&storage, .{});
    try FirstTable.verify(serialized, .{});
    try std.testing.expectEqual(@as(i32, 42), (try FirstTable.read(serialized)).write);
}

test "generation orders wire IDs without changing caller-owned field metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try compiler.parser.parse(arena.allocator(),
        \\table Message {
        \\    alpha:int = 2 (id:2);
        \\    zebra:int = 1 (id:0);
        \\    legacy:int (id:1, deprecated);
        \\}
        \\root_type Message;
    );
    const fields = schema.root_table.?.fields;
    const original = try std.testing.allocator.dupe(reflection.Field, fields);
    defer std.testing.allocator.free(original);
    const source = try codegen.generate(std.testing.allocator, schema);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualDeep(@as([]const reflection.Field, original), fields);
    const zebra_position = std.mem.indexOf(u8, source, "zebra: i32").?;
    const alpha_position = std.mem.indexOf(u8, source, "alpha: i32").?;
    try std.testing.expect(zebra_position < alpha_position);
    try std.testing.expect(std.mem.indexOf(u8, source, "legacy") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        ".zebra = runtime.ScalarField(i32, 0, 1)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        ".alpha = runtime.ScalarField(i32, 2, 2)",
    ) != null);
}
