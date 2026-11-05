const standard_library = @import("std");
const runtime = @import("runtime");
const Reading = @import("reading").Reading;
const fixtures = @import("test_schema.zig");
const structs = @import("test_struct_schema.zig");
const arrays = @import("test_array_schema.zig");
const testing = standard_library.testing;

test "C++ C and Go union fixtures verify decode and mutate" {
    inline for (.{ "cpp", "c", "go" }) |language| {
        const fixture = @embedFile("testdata/" ++ language ++ "-unions.bin");
        var bytes: [fixture.len]u8 = fixture.*;
        try @import("test_union.zig").checkFixture(&bytes, .{});
    }
}

test "C++ C and Go struct vectors and arrays verify decode and mutate" {
    inline for (.{ "cpp", "c", "go" }) |language| {
        const fixture = @embedFile("testdata/" ++ language ++ "-arrays.bin");
        var bytes: [fixture.len]u8 = fixture.*;
        try runtime.Verifier.verify(arrays.Packet, &bytes, .{});
        const packet = try arrays.Packet.Schema.read(
            try runtime.Table.from(&bytes, .root),
        );
        try testing.expectEqualDeep(arrays.matrix, try packet.matrix.?.read());
        try testing.expectEqual(@as(usize, 2), packet.entries.?.element_count);
        for (arrays.envelopes, 0..) |value, element_index| {
            try testing.expectEqualDeep(
                value,
                try (try packet.entries.?.get(element_index)).read(),
            );
        }
        try testing.expectEqual(@as(usize, 0), packet.empty.?.element_count);
        try testing.expectEqual(@as(usize, 1), packet.blocks.?.element_count);
        try testing.expectEqualDeep(
            arrays.matrix,
            try (try packet.blocks.?.get(0)).read(),
        );
        const table = try runtime.MutableTable.from(&bytes, .root);
        // C++ may leave the unused payload address unaligned for count zero.
        try testing.expect(try arrays.Packet.Schema.update(table, .empty, &.{}));
        const entries = (try table.readVector(
            runtime.StructCodec(structs.Envelope.Layout),
            0,
        )).?;
        try (try entries.get(1)).update(.measure, 25.5);
        try testing.expectEqual(
            @as(f64, 25.5),
            try (try packet.entries.?.get(1)).get(.measure),
        );
        const matrix = (try table.readStruct(arrays.Matrix.Layout, 1)).?;
        try (try matrix.get(.values)).update(2, 99);
        const envelopes = try matrix.get(.envelopes);
        try (try envelopes.get(1)).update(.leading, 33);
        try testing.expectEqual(@as(f64, 99), (try packet.matrix.?.read()).values[2]);
        try testing.expectEqual(
            @as(u8, 33),
            (try packet.matrix.?.read()).envelopes[1].leading,
        );
        try testing.expect(try arrays.Packet.Schema.update(
            table,
            .entries,
            &arrays.envelopes,
        ));
        try runtime.Verifier.verify(arrays.Packet, &bytes, .{});
    }
}

test "C++ C and Go Reading fixtures verify decode and mutate" {
    inline for (.{ "cpp", "c", "go" }) |language| {
        const fixture = @embedFile("testdata/" ++ language ++ "-reading.bin");
        var bytes: [fixture.len]u8 = fixture.*;
        try Reading.verify(&bytes, .{});
        const reading = try Reading.read(&bytes);
        try testing.expectEqual(@as(u32, 42), reading.sequence);
        try testing.expectEqual(@as(f32, 1.5), reading.value);
        try testing.expectEqualStrings("sensor", reading.label.?);
        try testing.expect(reading.active);
        try testing.expectEqual(@as(u8, 200), @backingInt(reading.status));
        try testing.expectEqual(@as(?f32, 0), reading.temperature);
        const location = try reading.location.?.read();
        try testing.expectEqual(@as(f32, 48.5), location.coordinates.latitude);
        try testing.expectEqual(@as(f32, 2.25), location.coordinates.longitude);
        try testing.expectEqual(@as(f32, 35), location.altitude);
        const mutable_location = (try Reading.mutableLocation(&bytes)).?;
        const coordinates = try mutable_location.get(.coordinates);
        try coordinates.update(.latitude, 49.5);
        try testing.expectEqual(
            @as(f32, 49.5),
            try (try reading.location.?.get(.coordinates)).get(.latitude),
        );
        const samples = [_]f32{ -1.5, 0, 2.5 };
        for (samples, 0..) |value, element_index| {
            try testing.expectEqual(
                value,
                try reading.samples.?.get(element_index),
            );
        }
        const tags = [_][]const u8{ "one", "", "é", "one" };
        for (tags, 0..) |value, element_index| {
            try testing.expectEqualStrings(
                value,
                try reading.tags.?.get(element_index),
            );
        }
        try testing.expect(
            try Reading.update(&bytes, .tags, &.{ "new", "", "à", "new" }),
        );
        try testing.expect(try Reading.update(&bytes, .temperature, -3.5));
        try Reading.verify(&bytes, .{});
        try testing.expectEqualStrings("new", try reading.tags.?.get(3));
        try testing.expectEqual(
            @as(?f32, -3.5),
            (try Reading.read(&bytes)).temperature,
        );
    }
}

test "C++ C and Go padded nested structs verify decode and mutate" {
    inline for (.{ "cpp", "c", "go" }) |language| {
        const fixture = @embedFile("testdata/" ++ language ++ "-structs.bin");
        var bytes: [fixture.len]u8 = fixture.*;
        try runtime.Verifier.verify(structs.Packet, &bytes, .{});
        const packet = try structs.Packet.Schema.read(
            try runtime.Table.from(&bytes, .root),
        );
        try testing.expectEqual(structs.marker, packet.marker);
        try testing.expectEqualDeep(structs.envelope, try packet.envelope.?.read());
        try testing.expectEqualDeep(structs.sample, try packet.extra.?.read());
        const table = try runtime.MutableTable.from(&bytes, .root);
        const envelope = (try table.readStruct(structs.Envelope.Layout, 1)).?;
        const nested = try envelope.get(.sample);
        try nested.update(.count, 123);
        try envelope.update(.measure, 1.5);
        try testing.expectEqual(
            @as(u16, 123),
            (try packet.envelope.?.read()).sample.count,
        );
        try testing.expectEqual(@as(f64, 1.5), try packet.envelope.?.get(.measure));
        try testing.expect(try structs.Packet.Schema.update(
            table,
            .envelope,
            structs.envelope,
        ));
        try runtime.Verifier.verify(structs.Packet, &bytes, .{});
        try testing.expectEqualDeep(structs.envelope, try packet.envelope.?.read());
    }
}

test "C++ C and Go recursive graph fixtures verify and preserve values" {
    inline for (.{ "cpp", "c", "go" }) |language| {
        const bytes = @embedFile("testdata/" ++ language ++ "-graph.bin");
        try checkGraph(bytes, .{});
    }
}

test "C++ and flatcc size-prefixed Graph fixtures verify and preserve values" {
    inline for (.{ "cpp", "c" }) |language| {
        inline for (.{ "", "-id" }) |suffix| {
            const bytes = @embedFile(
                "testdata/" ++ language ++ "-graph-prefixed" ++ suffix ++ ".bin",
            );
            try checkGraph(bytes, .{
                .format = .size_prefixed,
                .identifier = switch (suffix.len) {
                    0 => null,
                    else => "GRPH".*,
                },
            });
        }
    }
}

fn checkGraph(bytes: []const u8, options: runtime.framing.Options) !void {
    try runtime.Verifier.verify(fixtures.Graph, bytes, .{ .frame = options });
    const graph = try fixtures.Graph.Schema.read(
        try runtime.Table.from(bytes, .{ .framed_root = options }),
    );
    try testing.expectEqual(fixtures.revision, graph.revision);
    const parent = try fixtures.Node.Schema.read(graph.child.?);
    try testing.expectEqual(fixtures.parent_number, parent.number);
    try testing.expectEqualStrings("parent", parent.name.?);
    const leaf = try fixtures.Node.Schema.read(parent.next.?);
    try testing.expectEqual(fixtures.leaf_number, leaf.number);
    try testing.expectEqualStrings("leaf", leaf.name.?);
    try testing.expect(leaf.next == null);
    try testing.expectEqual(@as(usize, 2), graph.children.?.element_count);
    for (0..graph.children.?.element_count) |element_index| {
        const child = try fixtures.Node.Schema.read(
            try graph.children.?.get(element_index),
        );
        try testing.expectEqual(fixtures.leaf_number, child.number);
        try testing.expectEqualStrings("leaf", child.name.?);
    }
    for (fixtures.payload, 0..) |value, element_index| {
        try testing.expectEqual(
            value,
            try graph.payload.?.get(element_index),
        );
    }
}
