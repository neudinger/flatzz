const std = @import("std");
const runtime = @import("runtime");
const reading = @import("reading");
const fixtures = @import("test_array_schema.zig");
const structs = @import("test_struct_schema.zig");

const buffer_access = runtime.buffer_access;
const Reading = reading.Reading;
const Location = reading.Location;
const testing = std.testing;
const Storage = [fixtures.storage_capacity]u8;
const EnvelopeCodec = runtime.StructCodec(structs.Envelope.Layout);

const array_frames = .{
    .{ runtime.Builder.FinishOptions.ordinary, runtime.framing.Options{} },
    .{
        runtime.Builder.FinishOptions{ .identifier = "ARRY".* },
        runtime.framing.Options{ .identifier = "ARRY".* },
    },
    .{
        runtime.Builder.FinishOptions.size_prefixed,
        runtime.framing.Options{ .format = .size_prefixed },
    },
    .{
        runtime.Builder.FinishOptions{ .size_prefixed_identifier = "ARRY".* },
        runtime.framing.Options{
            .format = .size_prefixed,
            .identifier = "ARRY".*,
        },
    },
};

test "arrays of structs containing arrays preserve schema layout" {
    const Group = struct { matrices: [2]fixtures.Matrix };
    const Layout = runtime.StructLayout(Group, .{
        .size = 2 * fixtures.Matrix.Layout.wire_size,
        .alignment = fixtures.Matrix.Layout.wire_alignment,
    }, .{ .matrices = runtime.ArrayMember(
        .{ .structure = fixtures.Matrix.Layout },
        2,
        0,
    ) });
    var bytes: [Layout.wire_size]u8 = undefined;
    Layout.encode(&bytes, .{ .matrices = @splat(fixtures.matrix) });
    try Layout.verify(&bytes);
    const view = try runtime.StructView(Layout, .mutable).from(&bytes, 0);
    const matrices = try view.get(.matrices);
    const second = try matrices.get(1);
    const values = try second.get(.values);
    try values.update(2, 10);
    const native = try view.read();
    try testing.expectEqualDeep(fixtures.matrix, native.matrices[0]);
    try testing.expectEqual(@as(f64, 10), native.matrices[1].values[2]);
    const Maximum = runtime.ArrayMember(
        .{ .scalar = u8 },
        std.math.maxInt(u16),
        0,
    );
    try testing.expectEqual(@as(usize, 65535), Maximum.wire_size);
}

test "struct vector stride and inline arrays work with every frame" {
    inline for (array_frames) |frame| {
        var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
        const bytes = try fixtures.build(&storage, frame[0]);
        try runtime.Verifier.verify(fixtures.Packet, bytes, .{ .frame = frame[1] });
        const table = try runtime.Table.from(bytes, .{ .options = frame[1] });
        const packet = try fixtures.Packet.Schema.read(table);
        const entries = packet.entries.?;
        try testing.expectEqual(@as(usize, 2), entries.element_count);
        try testing.expectEqual(@as(usize, 0), entries.payload_start % 8);
        try testing.expectEqual(
            @as(usize, 40),
            (try entries.elementStart(1)) - (try entries.elementStart(0)),
        );
        for (fixtures.envelopes, 0..) |value, element_index| {
            const view = try entries.get(element_index);
            try testing.expectEqualDeep(value, try view.read());
            // Padding is zero, independent of native struct declaration order.
            try testing.expectEqualSlices(
                u8,
                &@as([7]u8, @splat(0)),
                bytes[view.struct_start + 1 ..][0..7],
            );
        }
        try testing.expectEqual(@as(usize, 0), packet.empty.?.element_count);
        try testing.expectEqualDeep(fixtures.matrix, try packet.matrix.?.read());
        try testing.expectEqualDeep(
            fixtures.matrix,
            try (try packet.blocks.?.get(0)).read(),
        );
        const flags = try packet.matrix.?.get(.flags);
        try testing.expectEqual(@as(usize, 3), @TypeOf(flags).element_count);
        const values = try packet.matrix.?.get(.values);
        // Schema offsets point straight at elements, with no count prefix.
        try testing.expectEqual(
            @as(f64, 1.5),
            try buffer_access.readScalar(f64, bytes, packet.matrix.?.struct_start + 8),
        );
        try testing.expectEqual(@as(f64, 3.75), try values.get(2));
    }
}

test "mutable vectors and fixed arrays update borrowed views atomically" {
    var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
    const bytes = try fixtures.build(&storage, .ordinary);
    const borrowed = try fixtures.Packet.Schema.read(
        try runtime.Table.from(bytes, .root),
    );
    const table = try runtime.MutableTable.from(bytes, .root);
    const entries = (try table.readVector(EnvelopeCodec, 0)).?;
    const second = try entries.get(1);
    const sample = try second.get(.sample);
    try sample.update(.number, 123);
    try testing.expectEqual(
        @as(u64, 123),
        (try (try borrowed.entries.?.get(1)).read()).sample.number,
    );
    try testing.expect(try fixtures.Packet.Schema.update(
        table,
        .entries,
        &fixtures.envelopes,
    ));
    const matrix = (try table.readStruct(fixtures.Matrix.Layout, 1)).?;
    const flags = try matrix.get(.flags);
    try flags.update(1, true);
    const states = try matrix.get(.states);
    try states.update(0, .ready);
    const values = try matrix.get(.values);
    try values.update(2, 5.5);
    const envelopes = try matrix.get(.envelopes);
    try envelopes.update(0, fixtures.envelopes[1]);
    try (try envelopes.get(1)).update(.leading, 22);
    try matrix.update(.values, .{ 5, 6, 7 });
    const changed = try borrowed.matrix.?.read();
    try testing.expect(changed.flags[1]);
    try testing.expectEqual(structs.State.ready, changed.states[0]);
    try testing.expectEqual(@as([3]f64, .{ 5, 6, 7 }), changed.values);
    try testing.expectEqual(@as(u8, 9), changed.envelopes[0].leading);
    try testing.expectEqual(@as(u8, 22), changed.envelopes[1].leading);
    const before = storage;
    try testing.expectError(error.OutOfBounds, values.update(3, 0));
    try testing.expectError(
        error.OutOfBounds,
        envelopes.update(2, structs.envelope),
    );
    try testing.expectError(
        error.LengthMismatch,
        fixtures.Packet.Schema.update(table, .entries, &.{structs.envelope}),
    );
    try testing.expectError(
        error.CannotClearField,
        fixtures.Packet.Schema.update(table, .entries, null),
    );
    try testing.expectEqualSlices(u8, &before, &storage);
    try runtime.Verifier.verify(fixtures.Packet, bytes, .{});
}

test "struct vectors distinguish missing and empty with required preflight" {
    var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
    var builder = runtime.Builder.init(&storage);
    const before = storage;
    const before_builder = builder;
    try testing.expectError(
        error.MissingRequiredField,
        fixtures.Packet.Schema.create(&builder, .{ .matrix = fixtures.matrix }, .{}),
    );
    try testing.expectEqualSlices(u8, &before, &storage);
    try testing.expectEqualDeep(before_builder, builder);
    const bytes = try builder.finish(try fixtures.Packet.Schema.create(
        &builder,
        .{ .matrix = fixtures.matrix, .entries = &.{} },
        .{},
    ), .ordinary);
    const table = try runtime.MutableTable.from(bytes, .root);
    try runtime.Verifier.verify(fixtures.Packet, bytes, .{});
    const packet = try fixtures.Packet.Schema.read(
        try runtime.Table.from(bytes, .root),
    );
    try testing.expectEqual(@as(usize, 0), packet.entries.?.element_count);
    try testing.expect(packet.empty == null);
    try testing.expect(try fixtures.Packet.Schema.update(table, .entries, &.{}));
    try testing.expect(!try fixtures.Packet.Schema.update(table, .empty, &.{}));
}

test "struct vector preflight rejects capacity and native input aliasing" {
    var small: [8]u8 align(runtime.storage_alignment) = @splat(0xa5);
    var small_builder = runtime.Builder.init(&small);
    const before_small = small;
    const before_builder = small_builder;
    try testing.expectError(
        error.NoSpaceLeft,
        small_builder.createStructVector(
            structs.Envelope.Layout,
            &fixtures.envelopes,
        ),
    );
    try testing.expectEqualSlices(u8, &before_small, &small);
    try testing.expectEqualDeep(before_builder, small_builder);
    var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
    const native: *[2]structs.Envelope = @ptrCast(&storage);
    native.* = fixtures.envelopes;
    var builder = runtime.Builder.init(&storage);
    const before = storage;
    const original = builder;
    try testing.expectError(
        error.AliasedInput,
        builder.createStructVector(structs.Envelope.Layout, native),
    );
    try testing.expectEqualSlices(u8, &before, &storage);
    try testing.expectEqualDeep(original, builder);
    const bytes = try fixtures.build(&storage, .ordinary);
    const table = try runtime.MutableTable.from(bytes, .root);
    const entries = (try table.readVector(EnvelopeCodec, 0)).?;
    const aliased: [*]const structs.Envelope = @ptrCast(@alignCast(
        bytes[entries.payload_start..].ptr,
    ));
    const snapshot = storage;
    try testing.expectError(
        error.AliasedInput,
        table.mutateVector(EnvelopeCodec, 0, aliased[0..2]),
    );
    try testing.expectEqualSlices(u8, &snapshot, &storage);
}

test "struct vectors and arrays reject truncated misaligned and forged views" {
    var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
    const bytes = try fixtures.build(&storage, .ordinary);
    const table = try runtime.MutableTable.from(bytes, .root);
    const entries = (try table.readVector(EnvelopeCodec, 0)).?;
    try testing.expectError(error.OutOfBounds, entries.get(2));
    try testing.expectError(
        error.OutOfBounds,
        entries.get(std.math.maxInt(usize)),
    );
    var forged = entries;
    forged.element_count = std.math.maxInt(usize);
    try testing.expectError(error.OutOfBounds, forged.get(0));
    forged = entries;
    forged.payload_start += 1;
    if (forged.get(0)) |_| return error.AcceptedMisalignment else |_| {}
    const matrix = (try table.readStruct(fixtures.Matrix.Layout, 1)).?;
    var array = try matrix.get(.values);
    const before = storage;
    array.array_start = std.math.maxInt(usize);
    try testing.expectError(error.OutOfBounds, array.get(0));
    try testing.expectError(error.OutOfBounds, array.update(0, 0));
    try testing.expectEqualSlices(u8, &before, &storage);
    for (0..bytes.len) |byte_count| {
        if (runtime.Verifier.verify(fixtures.Packet, bytes[0..byte_count], .{}))
            return error.AcceptedTruncatedArray
        else |_| {}
    }
    try buffer_access.writeScalar(
        u32,
        bytes,
        entries.payload_start - runtime.sequence_length_size,
        std.math.maxInt(u32),
    );
    try testing.expectError(error.OutOfBounds, table.readVector(EnvelopeCodec, 0));
}

test "array verification budgets work and checks the last vector member" {
    const Closed = struct {
        states: [3]enum(u8) { known = 1 },
        pub const Layout = runtime.StructLayout(@This(), .{
            .size = 3,
            .alignment = 1,
        }, .{ .states = runtime.ArrayMember(
            .{ .scalar = @typeInfo(@FieldType(@This(), "states")).array.child },
            3,
            0,
        ) });
    };
    const Packet = struct {
        blocks: ?[]const Closed = null,
        pub const Schema = runtime.Schema(@This(), .{
            .blocks = runtime.ReferenceField(
                0,
                .{ .vector = runtime.StructCodec(Closed.Layout) },
                .{},
            ),
        });
    };
    const value: Closed = .{ .states = @splat(.known) };
    var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
    var builder = runtime.Builder.init(&storage);
    const bytes = try builder.finish(try Packet.Schema.create(
        &builder,
        .{ .blocks = &.{ value, value } },
        .{},
    ), .ordinary);
    const table = try runtime.MutableTable.from(bytes, .root);
    const blocks = (try table.readVector(runtime.StructCodec(Closed.Layout), 0)).?;
    const last = try blocks.get(1);
    bytes[last.struct_start + 2] = 200;
    const table_work = table.layout.table_size + table.layout.vtable_size + 1;
    const vector_work = runtime.sequence_length_size + 2 * Closed.Layout.wire_size;
    try testing.expectError(error.WorkLimit, runtime.Verifier.verify(
        Packet,
        bytes,
        .{ .max_work = table_work + vector_work },
    ));
    try testing.expectError(error.InvalidBuffer, runtime.Verifier.verify(
        Packet,
        bytes,
        .{ .max_work = table_work + vector_work + 2 * Closed.Layout.work_size },
    ));
    try (try last.get(.states)).update(2, .known);
    try runtime.Verifier.verify(Packet, bytes, .{});
}

test "Reading capacity includes struct vectors and fixed arrays" {
    const location: Location = .{
        .coordinates = .{ .latitude = 1, .longitude = 2 },
        .altitude = 3,
    };
    inline for (.{ 0, 1, 3, 17 }) |count| {
        const history: [count]Location = @splat(location);
        var storage: runtime.Storage(Reading.Schema, .{
            .label = 5,
            .samples = 3,
            .tags = .{ .count = 2, .bytes = 6 },
            .history = count,
        }, .{}) = .{};
        const bytes = try Reading.serialize(.{
            .label = "start",
            .samples = &.{ 1, 2, 3 },
            .tags = &.{ "lab", "new" },
            .temperature = 0,
            .location = location,
            .history = &history,
            .calibration = .{
                .gains = .{ 1, 2, 3 },
                .locations = @splat(location),
            },
        }, &storage.buffer, .{ .force_defaults = true });
        try Reading.verify(bytes, .{});
        const view = try Reading.read(bytes);
        try testing.expectEqual(count, view.history.?.element_count);
        for (0..count) |element_index| {
            try testing.expectEqualDeep(
                location,
                try (try view.history.?.get(element_index)).read(),
            );
        }
    }
}
