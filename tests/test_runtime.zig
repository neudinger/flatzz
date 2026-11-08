const std = @import("std");
const runtime = @import("runtime");
const reading = @import("reading");
const fixtures = @import("test_schema.zig");

const buffer_access = runtime.buffer_access;
const Reading = reading.Reading;
const testing = std.testing;

const integer_scalar_types = [_]type{ u8, i8, u16, i16, u32, i32, u64, i64 };

// Independent wire bytes catch paired encoder/decoder regressions after
// @bitCast changes, including sign bits and noncanonical NaN payloads.
const scalar_wire_cases = .{
    .{
        i16,
        u16,
        0x8000,
        [_]u8{ 0, 0x80 },
    },
    .{
        i64,
        u64,
        0x8000000000000000,
        [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0x80 },
    },
    .{
        f32,
        u32,
        0x80000000,
        [_]u8{ 0, 0, 0, 0x80 },
    },
    .{
        f32,
        u32,
        0x7f800000,
        [_]u8{ 0, 0, 0x80, 0x7f },
    },
    .{
        f32,
        u32,
        0x7fc01234,
        [_]u8{ 0x34, 0x12, 0xc0, 0x7f },
    },
    .{
        f64,
        u64,
        0x8000000000000000,
        [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0x80 },
    },
    .{
        f64,
        u64,
        0x7ff0000000000000,
        [_]u8{ 0, 0, 0, 0, 0, 0, 0xf0, 0x7f },
    },
    .{
        f64,
        u64,
        0x7ff8123456789abc,
        [_]u8{ 0xbc, 0x9a, 0x78, 0x56, 0x34, 0x12, 0xf8, 0x7f },
    },
};

fn scalarRoundTrip(comptime ScalarType: type, value: ScalarType) !void {
    const scalar_size = @sizeOf(runtime.wire.Bits(ScalarType));
    var bytes: [scalar_size + 1]u8 = @splat(0xa5);
    try buffer_access.writeScalar(ScalarType, &bytes, 1, value);
    const result = try buffer_access.readScalar(ScalarType, &bytes, 1);
    try testing.expectEqual(
        @as(runtime.wire.Bits(ScalarType), @bitCast(value)),
        @as(runtime.wire.Bits(ScalarType), @bitCast(result)),
    );
    try testing.expectEqual(@as(u8, 0xa5), bytes[0]);
    const before = bytes;
    try testing.expectError(
        error.OutOfBounds,
        buffer_access.writeScalar(ScalarType, &bytes, bytes.len, value),
    );
    try testing.expectEqualSlices(u8, &before, &bytes);
    try testing.expectError(
        error.OutOfBounds,
        buffer_access.readScalar(ScalarType, &bytes, std.math.maxInt(usize)),
    );
}

test "wire scalars preserve integer boundaries and floating point bits on unaligned input" {
    inline for (integer_scalar_types) |ScalarType| {
        try scalarRoundTrip(
            ScalarType,
            std.math.minInt(ScalarType),
        );
        try scalarRoundTrip(
            ScalarType,
            std.math.maxInt(ScalarType),
        );
    }
    inline for (.{ f32, f64 }) |ScalarType| {
        const WireType = runtime.wire.Bits(ScalarType);
        const negative_zero: ScalarType = @bitCast(
            @as(WireType, 1) << (@bitSizeOf(WireType) - 1),
        );
        try scalarRoundTrip(ScalarType, negative_zero);
        try scalarRoundTrip(ScalarType, std.math.inf(ScalarType));
        try scalarRoundTrip(
            ScalarType,
            @bitCast(@as(WireType, std.math.maxInt(WireType))),
        );
    }
    var bytes: [runtime.field_offset_size]u8 = undefined;
    try buffer_access.writeScalar(u32, &bytes, 0, 0x01020304);
    try testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1 }, &bytes);
    inline for (scalar_wire_cases) |fixture| {
        const ScalarType = fixture[0];
        const WireType = fixture[1];
        const expected_bits: WireType = fixture[2];
        const expected_bytes: [@sizeOf(WireType)]u8 = fixture[3];
        var encoded: [@sizeOf(WireType)]u8 = undefined;
        try buffer_access.writeScalar(ScalarType, &encoded, 0, @bitCast(expected_bits));
        try testing.expectEqualSlices(u8, &expected_bytes, &encoded);
        try testing.expectEqual(
            expected_bits,
            @as(
                WireType,
                @bitCast(try buffer_access.readScalar(ScalarType, &expected_bytes, 0)),
            ),
        );
    }
}

test "bool normalization and signed exhaustive and open enum tags" {
    const Closed = enum(i16) { negative = -2, positive = 7 };
    const Open = enum(i16) { negative = -2, _ };
    var bytes: [@sizeOf(i16)]u8 = undefined;
    try buffer_access.writeScalar(u8, &bytes, 0, 0xff);
    try testing.expect(try buffer_access.readScalar(bool, &bytes, 0));
    try buffer_access.writeScalar(bool, &bytes, 0, true);
    try testing.expectEqual(@as(u8, 1), bytes[0]);
    try buffer_access.writeScalar(bool, &bytes, 0, false);
    try testing.expectEqual(@as(u8, 0), bytes[0]);
    try buffer_access.writeScalar(Closed, &bytes, 0, .negative);
    try testing.expectEqual(
        Closed.negative,
        try buffer_access.readScalar(Closed, &bytes, 0),
    );
    try buffer_access.writeScalar(Open, &bytes, 0, @fromBackingInt(@intCast(-123)));
    try testing.expectEqual(
        @as(i16, -123),
        @backingInt(try buffer_access.readScalar(Open, &bytes, 0)),
    );
    try testing.expectError(
        error.InvalidBuffer,
        buffer_access.readScalar(Closed, &bytes, 0),
    );
}

// Wire fixtures are assembled independently of Builder. All positions derive
// from named format sizes, making headers and alignments explicit.
const root_start = 0;
const signed_table_start = runtime.root_offset_size;
const scalar_start = signed_table_start + runtime.table_header_size;
const trailing_vtable_start = scalar_start + @sizeOf(u32);
const single_vtable_size = runtime.vtable_header_size + runtime.vtable_entry_size;
const signed_fixture_size = trailing_vtable_start + single_vtable_size;

fn signedVtableFixture() [signed_fixture_size]u8 {
    var bytes: [signed_fixture_size]u8 = @splat(0);
    std.mem.writeInt(
        u32,
        bytes[root_start..][0..runtime.root_offset_size],
        signed_table_start,
        .little,
    );
    std.mem.writeInt(
        i32,
        bytes[signed_table_start..][0..runtime.table_header_size],
        -@as(i32, trailing_vtable_start - signed_table_start),
        .little,
    );
    std.mem.writeInt(
        u32,
        bytes[scalar_start..][0..@sizeOf(u32)],
        42,
        .little,
    );
    std.mem.writeInt(
        u16,
        bytes[trailing_vtable_start..][0..runtime.vtable_entry_size],
        single_vtable_size,
        .little,
    );
    std.mem.writeInt(
        u16,
        bytes[trailing_vtable_start + runtime.vtable_entry_size ..][0..runtime.vtable_entry_size],
        runtime.table_header_size + @sizeOf(u32),
        .little,
    );
    std.mem.writeInt(
        u16,
        bytes[trailing_vtable_start + runtime.vtable_header_size ..][0..runtime.vtable_entry_size],
        runtime.table_header_size,
        .little,
    );
    return bytes;
}

test "signed vtables and table at position do not require root discovery" {
    var bytes = signedVtableFixture();
    const table = try runtime.Table.from(&bytes, .root);
    const root_sources = [_]runtime.TableSource{ .root, .{ .options = .{} } };
    for (root_sources) |root_source| {
        const opened = try runtime.Table.from(&bytes, root_source);
        try testing.expectEqual(@as(u32, 42), try opened.readField(u32, 0, 0));
        try testing.expectEqual(@as(u32, 99), try opened.readField(u32, 1, 99));
        const writable = try runtime.MutableTable.from(&bytes, root_source);
        try testing.expectEqual(@as(u32, 42), try writable.readField(u32, 0, 0));
    }
    // Invalidating only the root offset does not invalidate this table's metadata.
    try buffer_access.writeScalar(u32, &bytes, root_start, 0);
    for (root_sources) |root_source| {
        try testing.expectError(error.InvalidBuffer, runtime.Table.from(&bytes, root_source));
        try testing.expectError(
            error.InvalidBuffer,
            runtime.MutableTable.from(&bytes, root_source),
        );
    }
    // This position was decoded at runtime, so the source cannot be comptime.
    const source: runtime.TableSource = .{ .position = table.layout.table_start };
    const independent = try runtime.Table.from(&bytes, source);
    try testing.expectEqual(@as(u32, 42), try independent.readField(u32, 0, 0));
    try testing.expectEqual(@as(u32, 42), try table.readField(u32, 0, 0));
    const mutable = try runtime.MutableTable.from(&bytes, source);
    try testing.expect(try mutable.mutateField(u32, 0, 43));
    try testing.expectEqual(@as(u32, 43), try independent.readField(u32, 0, 0));
    // Keep the position aligned so this exercises bounds, not alignment checks.
    const outside_start = std.mem.alignForward(
        usize,
        bytes.len,
        runtime.table_header_size,
    );
    try testing.expectError(
        error.OutOfBounds,
        runtime.Table.from(&bytes, .{ .position = outside_start }),
    );
    try testing.expectError(
        error.InvalidBuffer,
        runtime.Table.from(&bytes, .{ .position = 0 }),
    );
}

test "trimmed vtables absent slots and malformed field ranges" {
    var bytes = signedVtableFixture();
    try buffer_access.writeScalar(
        u16,
        &bytes,
        trailing_vtable_start,
        runtime.vtable_header_size,
    );
    try testing.expectEqual(
        @as(u32, 17),
        try (try runtime.Table.from(&bytes, .root)).readField(u32, 0, 17),
    );
    bytes = signedVtableFixture();
    const entry_start = trailing_vtable_start + runtime.vtable_header_size;
    try buffer_access.writeScalar(u16, &bytes, entry_start, 0);
    try testing.expectEqual(
        @as(u32, 17),
        try (try runtime.Table.from(&bytes, .root)).readField(u32, 0, 17),
    );
    try buffer_access.writeScalar(u16, &bytes, entry_start, runtime.table_header_size - 1);
    try testing.expectError(
        error.InvalidBuffer,
        (try runtime.Table.from(&bytes, .root)).readField(u32, 0, 17),
    );
    try buffer_access.writeScalar(u16, &bytes, entry_start, runtime.table_header_size + 1);
    try testing.expectError(
        error.OutOfBounds,
        (try runtime.Table.from(&bytes, .root)).readField(u32, 0, 17),
    );
    try buffer_access.writeScalar(u16, &bytes, entry_start, runtime.table_header_size + 1);
    try testing.expectError(
        error.InvalidBuffer,
        (try runtime.Table.from(&bytes, .root)).readField(u16, 0, 17),
    );
    bytes = signedVtableFixture();
    try buffer_access.writeScalar(
        u16,
        &bytes,
        trailing_vtable_start,
        runtime.vtable_header_size - 1,
    );
    try testing.expectError(
        error.InvalidBuffer,
        runtime.Table.from(&bytes, .root),
    );
    bytes = signedVtableFixture();
    try buffer_access.writeScalar(
        i32,
        &bytes,
        signed_table_start,
        std.math.minInt(i32),
    );
    try testing.expectError(error.OutOfBounds, runtime.Table.from(
        &bytes,
        .root,
    ));
}

test "scalar mutation uses cached lookup preserves presence and failure atomicity" {
    var storage: runtime.Storage(Reading.Schema, .{}, .{}) = .{};
    const bytes = try Reading.serialize(
        .{ .temperature = 0 },
        &storage.buffer,
        .{ .force_defaults = true },
    );
    const table = try runtime.MutableTable.from(bytes, .root);
    try testing.expect(
        try table.mutateField(u32, Reading.fields.sequence.wire_id, 100),
    );
    try testing.expectEqual(@as(u32, 100), (try Reading.read(bytes)).sequence);
    const before = storage.buffer;
    try testing.expectError(
        error.CannotClearField,
        Reading.update(table, .temperature, null),
    );
    try testing.expectEqualSlices(u8, &before, &storage.buffer);
    const absent = try Reading.serialize(.{}, &storage.buffer, .{});
    const absent_table = try runtime.MutableTable.from(absent, .root);
    try testing.expect(!try Reading.update(absent_table, .sequence, 0));
    try testing.expect(!try Reading.update(absent_table, .temperature, null));
}

test "recursive schema heterogeneous tables shared children and arbitrary byte vectors" {
    var storage: [fixtures.storage_capacity]u8 align(runtime.storage_alignment) = undefined;
    const bytes = try fixtures.build(&storage, .ordinary);
    try runtime.Verifier.verify(fixtures.Graph, bytes, .{});
    const graph = try fixtures.Graph.Schema.read(
        try runtime.Table.from(bytes, .root),
    );
    try testing.expectEqual(fixtures.revision, graph.revision);
    const parent = try fixtures.Node.Schema.read(graph.child.?);
    try testing.expectEqual(fixtures.parent_number, parent.number);
    try testing.expectEqualStrings("parent", parent.name.?);
    const leaf_table = parent.next.?;
    const leaf = try fixtures.Node.Schema.read(leaf_table);
    try testing.expectEqual(fixtures.leaf_number, leaf.number);
    try testing.expectEqualStrings("leaf", leaf.name.?);
    try testing.expect(leaf.next == null);
    const children = graph.children.?;
    try testing.expectEqual(@as(usize, 2), children.element_count);
    for (0..children.element_count) |element_index| {
        try testing.expectEqual(
            leaf_table.layout.table_start,
            (try children.get(element_index)).layout.table_start,
        );
    }
    for (fixtures.payload, 0..) |value, element_index| {
        try testing.expectEqual(value, try graph.payload.?.get(element_index));
    }
    // Mutating a nested child updates all aliases, without resolving the root again.
    const mutable_graph = try runtime.MutableTable.from(bytes, .root);
    const mutable_parent = (try mutable_graph.readTable(
        fixtures.Graph.fields.child.wire_id,
    )).?;
    const mutable_leaf = (try mutable_parent.readTable(
        fixtures.Node.fields.next.wire_id,
    )).?;
    try testing.expect(
        try mutable_leaf.mutateField(
            u64,
            fixtures.Node.fields.number.wire_id,
            77,
        ),
    );
    try testing.expectEqual(
        @as(u64, 77),
        try (try children.get(1)).readField(
            u64,
            fixtures.Node.fields.number.wire_id,
            0,
        ),
    );
    try runtime.Verifier.verify(fixtures.Graph, bytes, .{});
}

test "verification visits later vector elements whereas ordinary access stays lazy" {
    var storage: runtime.Storage(Reading.Schema, .{
        .tags = .{ .count = 2, .bytes = 6 },
    }, .{}) = .{};
    const bytes = try Reading.serialize(.{ .tags = &.{ "one", "two" } }, &storage.buffer, .{});
    const tags = (try Reading.read(bytes)).tags.?;
    try buffer_access.writeScalar(
        u32,
        bytes,
        tags.payload_start + runtime.field_offset_size,
        0,
    );
    const view = try Reading.read(bytes);
    try testing.expectEqualStrings("one", try view.tags.?.get(0));
    try testing.expectError(error.InvalidBuffer, view.tags.?.get(1));
    try testing.expectError(error.InvalidBuffer, Reading.verify(bytes, .{}));
}

test "verification enforces required fields and explicit resource limits" {
    var storage: [fixtures.storage_capacity]u8 align(runtime.storage_alignment) = undefined;
    const bytes = try fixtures.build(&storage, .ordinary);
    const table = try runtime.Table.from(bytes, .root);
    inline for (.{ bytes, table }) |source| {
        try testing.expectError(
            error.DepthLimit,
            runtime.Verifier.verify(fixtures.Graph, source, .{ .max_depth = 2 }),
        );
        try testing.expectError(
            error.DepthLimit,
            runtime.Verifier.verify(fixtures.Graph, source, .{ .max_depth = 0 }),
        );
        try testing.expectError(
            error.ObjectLimit,
            runtime.Verifier.verify(fixtures.Graph, source, .{ .max_objects = 1 }),
        );
        try testing.expectError(
            error.WorkLimit,
            runtime.Verifier.verify(fixtures.Graph, source, .{ .max_work = 1 }),
        );
    }
    var verifier = runtime.Verifier.init(bytes, .{});
    try verifier.verifyRoot(fixtures.Graph);
    try testing.expect(
        verifier.object_count > 5,
    ); // Repeated shared references consume visits.
    inline for (.{ bytes, table }) |source| {
        try runtime.Verifier.verify(fixtures.Graph, source, .{
            .max_depth = 3,
            .max_objects = verifier.object_count,
            .max_work = verifier.work_count,
        });
        try testing.expectError(
            error.WorkLimit,
            runtime.Verifier.verify(
                fixtures.Graph,
                source,
                .{ .max_work = verifier.work_count - 1 },
            ),
        );
    }
    var builder = runtime.Builder.init(&storage);
    var empty = try runtime.TableBuilder(0).init(&builder);
    const absent = try builder.finish(try empty.endTable(), .ordinary);
    inline for (.{ absent, try runtime.Table.from(absent, .root) }) |source| {
        try testing.expectError(
            error.MissingRequiredField,
            runtime.Verifier.verify(fixtures.Graph, source, .{}),
        );
    }
    // Ordinary access returns absence; only schema verification enforces required.
    try testing.expect(
        (try fixtures.Graph.Schema.read(
            try runtime.Table.from(absent, .root),
        )).child == null,
    );
}

test "older schema ignores unknown fields during verification" {
    const Older = struct {
        revision: u16 = 0,
        pub const Schema = runtime.Schema(
            @This(),
            .{ .revision = runtime.ScalarField(u16, 0, 0) },
        );
    };
    var storage: [fixtures.storage_capacity]u8 align(runtime.storage_alignment) = undefined;
    const bytes = try fixtures.build(&storage, .ordinary);
    const root = try runtime.Table.from(bytes, .root);
    const child_slot = (try root.fieldPosition(
        u32,
        fixtures.Graph.fields.child.wire_id,
    )).?;
    try buffer_access.writeScalar(u32, bytes, child_slot, 0);
    try runtime.Verifier.verify(Older, bytes, .{});
    try testing.expectError(
        error.InvalidBuffer,
        runtime.Verifier.verify(fixtures.Graph, bytes, .{}),
    );
}

test "table contexts compactly distinguish untouched omitted and present fields" {
    const Context = runtime.TableBuilder(16);
    try testing.expectEqual(@as(usize, 64), @sizeOf(@FieldType(Context, "field_offsets")));
    if (@sizeOf(usize) == 8)
        try testing.expectEqual(@as(usize, 88), @sizeOf(Context));

    var storage: [fixtures.storage_capacity]u8 align(runtime.storage_alignment) = @splat(0xa5);
    var builder = runtime.Builder.init(&storage);
    const empty = try builder.createString("");
    var context = try Context.init(&builder);
    try testing.expectError(error.MissingRequiredField, context.requireField(0));
    try context.addScalar(u32, 0, 0, 0);
    try context.addScalar(?u16, 1, null, null);
    try context.addOffset(2, null);
    try context.addStruct(reading.Location.Layout, 3, null);
    const before_storage = storage;
    const before_builder = builder;
    const before_fields = context.field_offsets;
    inline for (.{ 0, 1, 2, 3 }) |field_id| {
        try testing.expectError(error.MissingRequiredField, context.requireField(field_id));
        try testing.expectError(error.DuplicateField, context.addOffset(field_id, empty));
    }
    try testing.expectEqualSlices(u8, &before_storage, &storage);
    try testing.expectEqualDeep(before_builder, builder);
    try testing.expectEqualDeep(before_fields, context.field_offsets);
    try context.addScalar(u32, 4, 42, 0);
    try context.addOffset(5, empty);
    try context.requireField(4);
    try context.requireField(5);
    try testing.expectError(error.MissingRequiredField, context.requireField(6));
    const bytes = try builder.finish(try context.endTable(), .ordinary);
    const table = try runtime.Table.from(bytes, .root);
    inline for (.{ 0, 1, 2, 3, 6, 15 }) |field_id|
        try testing.expect(try table.fieldPosition(u32, field_id) == null);
    try testing.expectEqual(@as(u32, 42), try table.readField(u32, 4, 0));
    try testing.expectEqualStrings("", (try table.readString(5)).?);
}

test "builder state transitions stale contexts duplicate fields and invalid handles" {
    var storage: [fixtures.storage_capacity]u8 align(runtime.storage_alignment) = @splat(
        0,
    );
    var builder = runtime.Builder.init(&storage);
    try testing.expectError(
        error.InvalidState,
        builder.finish(@fromBackingInt(@intCast(1)), .ordinary),
    );
    var first = try runtime.TableBuilder(1).init(&builder);
    try testing.expectError(
        error.InvalidState,
        runtime.TableBuilder(2).init(&builder),
    );
    try testing.expectError(error.InvalidState, builder.createString("child"));
    const before = storage;
    try testing.expectError(
        error.InvalidOffset,
        first.addOffset(0, @fromBackingInt(@intCast(0))),
    );
    try testing.expectEqualSlices(u8, &before, &storage);
    try first.addScalar(u32, 0, 0, 0);
    try testing.expectError(
        error.DuplicateField,
        first.addScalar(u32, 0, 42, 0),
    );
    const first_handle = try first.endTable();
    var second = try runtime.TableBuilder(2).init(&builder);
    try testing.expectError(error.InvalidState, first.endTable());
    try second.addOffset(1, first_handle);
    _ = try second.endTable();
    // Finalization can select an earlier completed table, not only the last one.
    const bytes = try builder.finish(first_handle, .ordinary);
    try testing.expectEqual(
        @as(u32, 7),
        try (try runtime.Table.from(bytes, .root)).readField(u32, 0, 7),
    );
    try testing.expectError(error.InvalidState, builder.finish(
        first_handle,
        .ordinary,
    ));
    try testing.expectError(error.InvalidState, builder.createString("late"));
    builder.reset();
    _ = try runtime.TableBuilder(1).init(&builder);
    try testing.expectError(error.InvalidState, first.endTable());
}

test "capacity failures preserve active table and buffer" {
    var storage: [runtime.storage_alignment]u8 align(runtime.storage_alignment) = @splat(
        0,
    );
    var builder = runtime.Builder.init(&storage);
    var table = try runtime.TableBuilder(1).init(&builder);
    try table.addScalar(u64, 0, 1, 0);
    const before = storage;
    const cursor = builder.write_cursor;
    try testing.expectError(error.NoSpaceLeft, table.endTable());
    try testing.expectEqual(cursor, builder.write_cursor);
    try testing.expectEqualSlices(u8, &before, &storage);
    try testing.expectEqual(runtime.Builder.State.table, builder.state);
}

test "offset vector construction validates all handles before writing" {
    var storage: [fixtures.storage_capacity]u8 align(runtime.storage_alignment) = @splat(
        0,
    );
    var builder = runtime.Builder.init(&storage);
    var child = try runtime.TableBuilder(0).init(&builder);
    const child_handle = try child.endTable();
    const before = storage;
    const cursor = builder.write_cursor;
    try testing.expectError(
        error.InvalidOffset,
        builder.createReferenceVector(
            &[_]runtime.Builder.Offset{ child_handle, @fromBackingInt(@intCast(0)) },
            .{},
        ),
    );
    try testing.expectEqual(cursor, builder.write_cursor);
    try testing.expectEqualSlices(u8, &before, &storage);
}

test "reference vectors accept handle slices and native callbacks including empty input" {
    const CallbackOptions = struct {
        union_type: ?type = null,
        create: ?*const @TypeOf(runtime.Builder.createString) = null,
    };
    const labels = [_][]const u8{ "first", "second" };
    for ([_]usize{ 0, labels.len }) |count| {
        const values = labels[0..count];
        var expected_storage: [128]u8 align(runtime.storage_alignment) = undefined;
        var expected = runtime.Builder.init(&expected_storage);
        _ = try expected.createStringVector(values);
        const expected_bytes = expected.buffer[expected.write_cursor..];

        var storage: [128]u8 align(runtime.storage_alignment) = undefined;
        var builder = runtime.Builder.init(&storage);
        inline for (.{
            .{},
            .{ .union_type = null, .create = null },
            CallbackOptions{},
        }) |options| {
            builder.reset();
            var handles: [labels.len]runtime.Builder.Offset = undefined;
            for (values, handles[0..count]) |value, *handle| {
                handle.* = try builder.createString(value);
            }
            const explicit: runtime.Builder.Offset = try builder.createReferenceVector(
                handles[0..count],
                options,
            );
            try testing.expectEqual(@as(u32, @intCast(expected.used())), @backingInt(explicit));
            try testing.expectEqualSlices(
                u8,
                expected_bytes,
                builder.buffer[builder.write_cursor..],
            );
        }

        inline for (.{
            .{ .create = runtime.Builder.createString },
            .{ .create = &runtime.Builder.createString },
            CallbackOptions{ .create = &runtime.Builder.createString },
        }) |options| {
            builder.reset();
            const native: runtime.Builder.Offset = try builder.createReferenceVector(
                values,
                options,
            );
            try testing.expectEqual(@as(u32, @intCast(expected.used())), @backingInt(native));
            try testing.expectEqualSlices(
                u8,
                expected_bytes,
                builder.buffer[builder.write_cursor..],
            );
            try testing.expectEqual(@as(usize, 0), builder.scratch_cursor);
        }
    }
}

test "all truncations and bounded corruptions remain checked and failed mutations atomic" {
    var storage: [fixtures.storage_capacity]u8 align(runtime.storage_alignment) = undefined;
    const bytes = try fixtures.build(&storage, .ordinary);
    for (0..bytes.len) |byte_count| {
        // Padding can be truncated without invalidating data; either result is safe.
        runtime.Verifier.verify(
            fixtures.Graph,
            bytes[0..byte_count],
            .{},
        ) catch {};
    }
    const original = storage;
    for (0..bytes.len) |byte_index| {
        for ([_]u8{ 0, 0x7f, 0xff }) |replacement| {
            storage = original;
            bytes[byte_index] = replacement;
            runtime.Verifier.verify(
                fixtures.Graph,
                bytes,
                .{ .max_work = fixtures.storage_capacity * 16 },
            ) catch {};
            const before = storage;
            const mutable = runtime.MutableTable.from(
                bytes,
                .root,
            ) catch continue;
            _ = mutable.mutateField(
                u16,
                fixtures.Graph.fields.revision.wire_id,
                12,
            ) catch {
                try testing.expectEqualSlices(u8, &before, &storage);
                continue;
            };
        }
    }
}

test "schema descriptors preserve physical ID gaps independent of native order" {
    const Sparse = struct {
        later: f64 = 0,
        earlier: u16 = 0,
        pub const Schema = runtime.Schema(@This(), .{
            .earlier = runtime.ScalarField(u16, 2, 0),
            .later = runtime.ScalarField(f64, 7, 0),
        });
    };
    try testing.expectEqual(@as(usize, 8), Sparse.Schema.field_count);
    var storage: [fixtures.storage_capacity]u8 align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    const bytes = try builder.finish(try Sparse.Schema.create(
        &builder,
        .{
            .later = -1.5,
            .earlier = 123,
        },
        .{},
    ), .ordinary);
    try runtime.Verifier.verify(Sparse, bytes, .{});
    const table = try runtime.Table.from(bytes, .root);
    const values = try Sparse.Schema.read(table);
    try testing.expectEqual(@as(f64, -1.5), values.later);
    try testing.expectEqual(@as(u16, 123), values.earlier);
    try testing.expectEqual(@as(u32, 99), try table.readField(u32, 0, 99));
    try testing.expect(
        try Sparse.Schema.update(
            try runtime.MutableTable.from(bytes, .root),
            .later,
            2.5,
        ),
    );
    try testing.expectEqual(@as(f64, 2.5), try table.readField(f64, 7, 0));
}

test "sequence references cannot reinterpret enclosing table metadata" {
    var storage: [fixtures.storage_capacity]u8 align(runtime.storage_alignment) = @splat(
        0,
    );
    var builder = runtime.Builder.init(&storage);
    builder.force_defaults = true;
    const label = try builder.createString("");
    var context = try runtime.TableBuilder(2).init(&builder);
    try context.addScalar(u32, 0, 0, 0);
    try context.addOffset(1, label);
    const bytes = try builder.finish(try context.endTable(), .ordinary);
    const table = try runtime.Table.from(bytes, .root);
    const reference_start = (try table.fieldPosition(u32, 1)).?;
    try buffer_access.writeScalar(u32, bytes, reference_start, runtime.field_offset_size);
    const before = storage;
    try testing.expectError(error.InvalidBuffer, table.readString(1));
    try testing.expectError(
        error.InvalidBuffer,
        (try runtime.MutableTable.from(bytes, .root)).mutateString(1, ""),
    );
    try testing.expectEqualSlices(u8, &before, &storage);
}

test "scalar sequence encoding preserves overlapping native input" {
    const element_count = 4;
    const element_size = @sizeOf(u32);
    const values = [_]u32{ 0x01020304, 0x11223344, 0x55667788, 0xaabbccdd };
    // Native storage is deliberate here; the encoder must produce little-endian
    // output on both endian targets, even when moving the source in either direction.
    var native: [element_count + 1]u32 = undefined;
    @memcpy(native[0..element_count], &values);
    runtime.wire.encodeSlice(
        u32,
        std.mem.sliceAsBytes(native[1..]),
        native[0..element_count],
    );
    for (values, 0..) |value, element_index| {
        try testing.expectEqual(
            value,
            try buffer_access.readScalar(
                u32,
                std.mem.sliceAsBytes(&native),
                (element_index + 1) * element_size,
            ),
        );
    }
    @memcpy(native[1..], &values);
    runtime.wire.encodeSlice(
        u32,
        std.mem.sliceAsBytes(native[0..element_count]),
        native[1..],
    );
    for (values, 0..) |value, element_index| {
        try testing.expectEqual(
            value,
            try buffer_access.readScalar(
                u32,
                std.mem.sliceAsBytes(&native),
                element_index * element_size,
            ),
        );
    }
}
