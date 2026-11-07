const std = @import("std");
const runtime = @import("runtime");
const reading = @import("reading");
const fixtures = @import("test_struct_schema.zig");

const Reading = reading.Reading;
const Location = reading.Location;
const testing = std.testing;

const Storage = [fixtures.storage_capacity]u8;

const struct_frames = .{
    .{ runtime.Builder.FinishOptions.ordinary, runtime.framing.Options{} },
    .{
        runtime.Builder.FinishOptions{ .identifier = "STRU".* },
        runtime.framing.Options{ .identifier = "STRU".* },
    },
    .{
        runtime.Builder.FinishOptions.size_prefixed,
        runtime.framing.Options{ .format = .size_prefixed },
    },
    .{
        runtime.Builder.FinishOptions{
            .size_prefixed_identifier = "STRU".*,
        },
        runtime.framing.Options{
            .format = .size_prefixed,
            .identifier = "STRU".*,
        },
    },
};

// Independent literal layout: both internal and tail padding must be zero.
const envelope_bytes = [_]u8{
    0x7f, 0,    0,    0,    0, 0, 0,    0,
    1,    200,  0x45, 0x23, 0, 0, 0,    0,
    8,    7,    6,    5,    4, 3, 2,    1,
    0,    0,    0,    0,    0, 0, 0x29, 0xc0,
    0x34, 0x12, 0,    0,    0, 0, 0,    0,
};

test "inline structs use schema layout and padding across all frame modes" {
    inline for (struct_frames) |frame| {
        var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
        const bytes = try fixtures.build(&storage, frame[0]);
        try runtime.Verifier.verify(fixtures.Packet, bytes, .{ .frame = frame[1] });
        const table = try runtime.MutableTable.from(bytes, .{
            .options = frame[1],
        });
        const view = (try table.readStruct(fixtures.Envelope.Layout, 1)).?;
        try testing.expectEqual(@as(usize, 0), view.struct_start % 8);
        try testing.expectEqualSlices(
            u8,
            &envelope_bytes,
            bytes[view.struct_start..][0..envelope_bytes.len],
        );
        try testing.expectEqualDeep(fixtures.envelope, try view.read());
        const nested = try view.get(.sample);
        try testing.expectEqual(fixtures.sample.number, try nested.get(.number));
        try nested.update(.number, 123);
        try testing.expectEqual(@as(u64, 123), (try view.read()).sample.number);
        // Readers ignore padding contents; writers must never leak native padding.
        bytes[view.struct_start + 1] = 0xab;
        try runtime.Verifier.verify(fixtures.Packet, bytes, .{ .frame = frame[1] });
        try view.replace(fixtures.envelope);
        try testing.expectEqualSlices(
            u8,
            &envelope_bytes,
            bytes[view.struct_start..][0..envelope_bytes.len],
        );
    }
}

test "Reading storage includes nested structs and mutable views remain borrowed" {
    var storage: runtime.Storage(Reading.Schema, .{
        .label = 5,
        .samples = 3,
        .tags = .{ .count = 1, .bytes = 3 },
    }, .{}) = .{};
    const initial: Location = .{
        .coordinates = .{ .latitude = 48.5, .longitude = 2.25 },
        .altitude = 35,
    };
    const bytes = try Reading.serialize(.{
        .label = "start",
        .samples = &.{ 1, 2, 3 },
        .tags = &.{"lab"},
        .temperature = 0,
        .location = initial,
    }, &storage.buffer, .{ .force_defaults = true });
    const borrowed = (try Reading.read(bytes)).location.?;
    const snapshot = try borrowed.read();
    const table = try runtime.MutableTable.from(bytes, .root);
    const mutable = (try Reading.borrowMutable(table, .location)).?;
    try mutable.update(.coordinates, .{ .latitude = 49, .longitude = 3 });
    const coordinates = try mutable.get(.coordinates);
    try coordinates.update(.longitude, 4);
    try testing.expectEqual(@as(f32, 4), (try borrowed.read()).coordinates.longitude);
    try testing.expectEqualDeep(initial, snapshot);
    try testing.expect(try Reading.update(bytes, .location, initial));
    try testing.expectEqualDeep(initial, try borrowed.read());
    const before = storage.buffer;
    try testing.expectError(
        error.CannotClearField,
        Reading.update(bytes, .location, null),
    );
    try testing.expectEqualSlices(u8, &before, &storage.buffer);
    try Reading.verify(bytes, .{});
}

test "absent inline fields and present zero structs remain distinct" {
    var storage: runtime.Storage(Reading.Schema, .{}, .{}) = .{};
    const absent = try Reading.serialize(.{}, &storage.buffer, .{});
    try testing.expect((try Reading.read(absent)).location == null);
    const table = try runtime.MutableTable.from(absent, .root);
    try testing.expect(try Reading.borrowMutable(table, .location) == null);
    const zero: Location = .{
        .coordinates = .{ .latitude = 0, .longitude = 0 },
        .altitude = 0,
    };
    try testing.expect(!try Reading.update(absent, .location, zero));
    const present = try Reading.serialize(.{
        .location = zero,
    }, &storage.buffer, .{});
    try testing.expectEqualDeep(
        zero,
        try (try Reading.read(present)).location.?.read(),
    );
    // A pre-extension producer has a shorter vtable, not a zero-valued struct.
    var builder = runtime.Builder.init(&storage.buffer);
    var old_table = try runtime.TableBuilder(0).init(&builder);
    const old_bytes = try builder.finish(try old_table.endTable(), .ordinary);
    try Reading.verify(old_bytes, .{});
    try testing.expect((try Reading.read(old_bytes)).location == null);
}

test "required structs preflight inline values" {
    var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
    var builder = runtime.Builder.init(&storage);
    const before_storage = storage;
    const before_builder = builder;
    try testing.expectError(
        error.MissingRequiredField,
        fixtures.Packet.Schema.create(&builder, .{ .extra = fixtures.sample }, .{}),
    );
    try testing.expectEqualSlices(u8, &before_storage, &storage);
    try testing.expectEqualDeep(before_builder, builder);
    var table = try fixtures.Packet.Schema.Context.init(&builder);
    const before_table = table;
    try testing.expectError(
        error.MissingRequiredField,
        fixtures.Packet.Schema.addFields(&table, .{}),
    );
    try testing.expectEqualDeep(before_table, table);
    try testing.expectEqualSlices(u8, &before_storage, &storage);
    try testing.expectError(
        error.MissingRequiredField,
        fixtures.Packet.Schema.endTable(&table),
    );
    try table.addStruct(fixtures.Envelope.Layout, 1, fixtures.envelope);
    const bytes = try builder.finish(
        try fixtures.Packet.Schema.endTable(&table),
        .ordinary,
    );
    try runtime.Verifier.verify(fixtures.Packet, bytes, .{});
    builder.reset();
    table = try fixtures.Packet.Schema.Context.init(&builder);
    try table.addStruct(fixtures.Envelope.Layout, 1, null);
    try testing.expectError(
        error.MissingRequiredField,
        fixtures.Packet.Schema.endTable(&table),
    );
    const invalid = try builder.finish(try table.endTable(), .ordinary);
    try testing.expectError(
        error.MissingRequiredField,
        runtime.Verifier.verify(fixtures.Packet, invalid, .{}),
    );
}

test "inline additions preserve state on capacity duplicate and stale failures" {
    var storage: [8]u8 align(runtime.storage_alignment) = @splat(0xa5);
    var builder = runtime.Builder.init(&storage);
    var table = try runtime.TableBuilder(1).init(&builder);
    const before_storage = storage;
    const before_builder = builder;
    const before_table = table;
    try testing.expectError(
        error.NoSpaceLeft,
        table.addStruct(fixtures.Envelope.Layout, 0, fixtures.envelope),
    );
    try testing.expectEqualSlices(u8, &before_storage, &storage);
    try testing.expectEqualDeep(before_builder, builder);
    try testing.expectEqualDeep(before_table, table);
    try table.addStruct(fixtures.Envelope.Layout, 0, null);
    try testing.expectError(
        error.DuplicateField,
        table.addStruct(fixtures.Envelope.Layout, 0, null),
    );
    builder.reset();
    try testing.expectError(
        error.InvalidState,
        table.addStruct(fixtures.Envelope.Layout, 0, null),
    );
}

test "truncated misaligned and escaping struct fields reject without mutation" {
    var storage: Storage align(runtime.storage_alignment) = undefined;
    const bytes = try fixtures.build(&storage, .ordinary);
    const snapshot = storage;
    for (0..bytes.len) |byte_count| {
        if (runtime.Verifier.verify(fixtures.Packet, bytes[0..byte_count], .{}))
            return error.AcceptedTruncatedStruct
        else |_| {}
    }
    const table = try runtime.MutableTable.from(bytes, .root);
    const entry_start = table.layout.vtable_start +
        runtime.vtable_header_size + runtime.vtable_entry_size;
    const original_offset = try runtime.read(u16, bytes, entry_start);
    const malformed_offsets = [_]u16{
        1, // Cannot overwrite the table's vtable displacement.
        original_offset + 1, // Breaks the eight-byte wire alignment.
        @intCast(table.layout.table_size), // Starts outside the table body.
    };
    for (malformed_offsets) |field_offset| {
        storage = snapshot;
        try runtime.write(u16, bytes, entry_start, field_offset);
        const before = storage;
        if (table.mutateStruct(fixtures.Envelope.Layout, 1, fixtures.envelope)) |_|
            return error.AcceptedMalformedStruct
        else |_| {}
        try testing.expectEqualSlices(u8, &before, &storage);
        if (runtime.Verifier.verify(fixtures.Packet, bytes, .{}))
            return error.AcceptedMalformedStruct
        else |_| {}
    }
    const View = runtime.StructView(fixtures.Envelope.Layout, .mutable);
    const forged: View = .{
        .bytes = bytes,
        .struct_start = std.math.maxInt(usize),
    };
    const before = storage;
    try testing.expectError(error.OutOfBounds, forged.get(.sample));
    try testing.expectError(error.OutOfBounds, forged.update(.leading, 0));
    try testing.expectEqualSlices(u8, &before, &storage);
}

test "struct verification charges member work before decoding exhaustive enums" {
    const Closed = struct {
        state: enum(u8) { known = 1 },
        pub const Layout = runtime.StructLayout(@This(), .{
            .size = 1,
            .alignment = 1,
        }, .{ .state = runtime.ScalarMember(@FieldType(@This(), "state"), 0) });
    };
    const Packet = struct {
        value: ?Closed = null,
        pub const Schema = runtime.Schema(@This(), .{
            .value = runtime.StructField(Closed.Layout, 0, .{}),
        });
    };
    var storage: Storage align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    const bytes = try builder.finish(try Packet.Schema.create(
        &builder,
        .{ .value = .{ .state = .known } },
        .{},
    ), .ordinary);
    const table = try runtime.MutableTable.from(bytes, .root);
    const view = (try table.readStruct(Closed.Layout, 0)).?;
    bytes[view.struct_start] = 200;
    // Opening an inline view is local; full verification decodes every member.
    try testing.expectError(error.InvalidBuffer, view.read());
    const table_work = table.layout.table_size + table.layout.vtable_size + 1;
    try testing.expectError(
        error.WorkLimit,
        runtime.Verifier.verify(Packet, bytes, .{ .max_work = table_work }),
    );
    try testing.expectError(
        error.InvalidBuffer,
        runtime.Verifier.verify(Packet, bytes, .{ .max_work = table_work + 1 }),
    );
    try view.update(.state, .known);
    try runtime.Verifier.verify(Packet, bytes, .{
        .max_depth = 1,
        .max_objects = 1,
        .max_work = table_work + 1,
    });
}

test "nested tables and offset vectors retain inline struct access" {
    const Parent = struct {
        child: ?*const fixtures.Packet = null,
        children: ?[]const *const fixtures.Packet = null,

        pub const Schema = runtime.Schema(@This(), .{
            .child = runtime.ReferenceField(
                0,
                .{ .table = fixtures.Packet },
                .{},
            ),
            .children = runtime.ReferenceField(
                1,
                .{ .vector = runtime.TableCodec(fixtures.Packet) },
                .{},
            ),
        });
    };
    var storage: Storage align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    const child_handle = try fixtures.Packet.Schema.create(
        &builder,
        .{
            .envelope = fixtures.envelope,
        },
        .{},
    );
    const vector_handle = try builder.createReferenceVector(
        &[_]runtime.Builder.Offset{
            child_handle,
            child_handle,
        },
        .{},
    );
    var context = try Parent.Schema.Context.init(&builder);
    try Parent.Schema.addFields(&context, .{ .child = child_handle, .children = vector_handle });
    const bytes = try builder.finish(
        try Parent.Schema.endTable(&context),
        .{ .size_prefixed_identifier = "STRU".* },
    );
    const options: runtime.framing.Options = .{
        .format = .size_prefixed,
        .identifier = "STRU".*,
    };
    try runtime.Verifier.verify(Parent, bytes, .{ .frame = options });
    const parent = try runtime.MutableTable.from(bytes, .{
        .options = options,
    });
    const child = (try parent.readTable(0)).?;
    const structure = (try child.readStruct(fixtures.Envelope.Layout, 1)).?;
    const sample = try structure.get(.sample);
    try sample.update(.number, 123);
    const children = (try parent.readVector(runtime.TableCodec(fixtures.Packet), 1)).?;
    for (0..children.element_count) |element_index| {
        const child_view = try fixtures.Packet.Schema.read(
            try children.get(element_index),
        );
        try testing.expectEqual(
            @as(u64, 123),
            (try child_view.envelope.?.read()).sample.number,
        );
    }
    try runtime.Verifier.verify(Parent, bytes, .{ .frame = options });
}
