const std = @import("std");
const runtime = @import("runtime");

const testing = std.testing;

const prefixed_wire_cases = .{
    .{ runtime.Builder.FinishOptions.size_prefixed, null, &prefixed_empty },
    .{
        runtime.Builder.FinishOptions{
            .size_prefixed_identifier = "READ".*,
        },
        "READ".*,
        &prefixed_identified_empty,
    },
};

test "identified empty roots match wire bytes including BFBS" {
    const storage_capacity = 32;
    var storage: [storage_capacity]u8 align(runtime.storage_alignment) = undefined;
    inline for ([_][runtime.file_identifier_size]u8{
        "READ".*, "BFBS".*,
    }) |identifier| {
        var builder = runtime.Builder.init(&storage);
        var context = try runtime.TableBuilder(0).init(&builder);
        const bytes = try builder.finish(
            try context.endTable(),
            .{ .identifier = identifier },
        );
        // Independent wire layout: root at 12, vtable at 8, empty table at 12.
        const expected = [_]u8{ 12, 0, 0, 0 } ++ identifier ++
            [_]u8{ 4, 0, 4, 0, 4, 0, 0, 0 };
        try testing.expectEqualSlices(u8, &expected, bytes);
        const table = try runtime.Table.from(
            bytes,
            .{ .options = .{ .identifier = identifier } },
        );
        try testing.expectEqual(@as(usize, 12), table.layout.table_start);
        _ = try runtime.Table.from(bytes, .root);
        // Also consume independently specified bytes, without the builder.
        // Expected identifiers may be loaded at runtime.
        const identifier_start = runtime.wire.file_identifier_start;
        const expected_identifier = bytes[identifier_start..][0..identifier.len].*;
        _ = try runtime.Table.from(
            &expected,
            .{ .options = .{ .identifier = expected_identifier } },
        );
    }
}

test "identifier checks reject mismatches truncations and absent markers" {
    const identified = [_]u8{
        12, 0, 0, 0, 'R', 'E', 'A', 'D', 4, 0, 4, 0, 4, 0, 0, 0,
    };
    try testing.expectError(
        error.IdentifierMismatch,
        runtime.Table.from(&identified, .{ .options = .{ .identifier = "BFBS".* } }),
    );
    for (0..runtime.wire.identified_header_size) |prefix_size| {
        try testing.expectError(
            error.OutOfBounds,
            runtime.Table.from(
                identified[0..prefix_size],
                .{ .options = .{ .identifier = "READ".* } },
            ),
        );
    }
    try testing.expectError(
        error.OutOfBounds,
        runtime.Table.from(
            identified[0..runtime.wire.identified_header_size],
            .{ .options = .{ .identifier = "READ".* } },
        ),
    );
    var storage: [16]u8 align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    var context = try runtime.TableBuilder(0).init(&builder);
    const ordinary = try builder.finish(try context.endTable(), .ordinary);
    const expected = [_]u8{ 8, 0, 0, 0, 4, 0, 4, 0, 4, 0, 0, 0 };
    try testing.expectEqualSlices(u8, &expected, ordinary);
    _ = try runtime.Table.from(ordinary, .root);
    try testing.expectError(
        error.IdentifierMismatch,
        runtime.Table.from(ordinary, .{ .options = .{ .identifier = "READ".* } }),
    );
}

test "identified roots cannot overlap the frame header" {
    const root_in_header = [_]u8{ 4, 0, 0, 0, 'R', 'E', 'A', 'D' };
    try testing.expectError(
        error.InvalidBuffer,
        runtime.Table.from(
            &root_in_header,
            .{ .options = .{ .identifier = "READ".* } },
        ),
    );
    // The marker also looks like a valid empty vtable. Matching bytes alone
    // must not allow that vtable to occupy the identifier's header region.
    const vtable_in_header = [_]u8{ 8, 0, 0, 0, 4, 0, 4, 0, 4, 0, 0, 0 };
    try testing.expectError(
        error.InvalidBuffer,
        runtime.Table.from(
            &vtable_in_header,
            .{ .options = .{ .identifier = .{ 4, 0, 4, 0 } } },
        ),
    );
}

test "identified frames preserve wide scalar alignment access and mutation" {
    const Wide = struct {
        number: u64 = 0,
        value: f64 = 0,
        pub const Schema = runtime.Schema(@This(), .{
            .number = runtime.ScalarField(u64, 0, 0),
            .value = runtime.ScalarField(f64, 1, 0),
        });
    };
    const storage_capacity = 128;
    var storage: [storage_capacity]u8 align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    const number: u64 = 0x1122334455667788;
    const bytes = try builder.finish(
        try Wide.Schema.create(&builder, .{ .number = number, .value = -1.5 }, .{}),
        .{ .identifier = "READ".* },
    );
    try testing.expectEqual(
        @as(usize, 0),
        bytes.len % runtime.storage_alignment,
    );
    try testing.expectEqual(
        @as(usize, 0),
        @intFromPtr(bytes.ptr) % runtime.storage_alignment,
    );
    const table = try runtime.Table.from(
        bytes,
        .{ .options = .{ .identifier = "READ".* } },
    );
    inline for (.{ .{ u64, 0 }, .{ f64, 1 } }) |field| {
        const field_start = (try table.fieldPosition(field[0], field[1])).?;
        try testing.expectEqual(@as(usize, 0), field_start % @sizeOf(field[0]));
    }
    const values = try Wide.Schema.read(table);
    try testing.expectEqual(number, values.number);
    try testing.expectEqual(@as(f64, -1.5), values.value);
    try runtime.Verifier.verify(Wide, bytes, .{});
    const mutable = try runtime.MutableTable.from(
        bytes,
        .{ .options = .{ .identifier = "READ".* } },
    );
    try testing.expect(try mutable.mutateField(u64, 0, number + 1));
    try testing.expectEqual(number + 1, try table.readField(u64, 0, 0));
    try runtime.validation.checkIdentifier(bytes, "READ".*);
}

test "identifier capacity failure preserves storage and permits ordinary retry" {
    const storage_capacity = 24;
    var storage: [storage_capacity]u8 align(runtime.storage_alignment) = @splat(0);
    var builder = runtime.Builder.init(&storage);
    var context = try runtime.TableBuilder(1).init(&builder);
    try context.addScalar(u64, 0, 1, 0);
    const root_handle = try context.endTable();
    const before = storage;
    const cursor = builder.write_cursor;
    try testing.expectError(
        error.NoSpaceLeft,
        builder.finish(root_handle, .{ .identifier = "READ".* }),
    );
    try testing.expectEqualSlices(u8, &before, &storage);
    try testing.expectEqual(cursor, builder.write_cursor);
    try testing.expectEqual(runtime.Builder.State.ready, builder.state);
    const bytes = try builder.finish(root_handle, .ordinary);
    try testing.expectEqual(
        @as(u64, 1),
        try (try runtime.Table.from(bytes, .root)).readField(u64, 0, 0),
    );
    try testing.expectError(
        error.InvalidState,
        builder.finish(root_handle, .{ .identifier = "READ".* }),
    );
}

const prefixed_empty = [_]u8{
    12, 0, 0, 0, 8, 0, 0, 0, 4, 0, 4, 0, 4, 0, 0, 0,
};
const prefixed_identified_empty = [_]u8{
    16, 0, 0, 0, 12, 0, 0, 0, 'R', 'E', 'A', 'D',
    4,  0, 4, 0, 4,  0, 0, 0,
};

test "size-prefixed roots match independent wire layouts" {
    inline for (prefixed_wire_cases) |example| {
        var storage: [32]u8 align(runtime.storage_alignment) = undefined;
        var builder = runtime.Builder.init(&storage);
        var context = try runtime.TableBuilder(0).init(&builder);
        const bytes = try builder.finish(try context.endTable(), example[0]);
        try testing.expectEqualSlices(u8, example[2], bytes);
        const options: runtime.framing.Options = .{
            .format = .size_prefixed,
            .identifier = example[1],
        };
        _ = try runtime.Table.from(example[2], .{ .options = options });
        const table = try runtime.Table.from(
            bytes,
            .{ .options = options },
        );
        try testing.expectEqual(bytes.len, table.bytes.len);
        try testing.expectEqual(
            bytes.len - runtime.wire.size_prefix_size,
            try runtime.read(u32, bytes, 0),
        );
    }
}

test "prefixed parsing rejects truncations bad lengths and wrong identifiers" {
    const source: runtime.TableSource = .{ .options = .{
        .format = .size_prefixed,
    } };
    for (0..prefixed_empty.len) |byte_count| {
        try testing.expectError(
            error.OutOfBounds,
            runtime.Table.from(prefixed_empty[0..byte_count], source),
        );
    }
    var malformed = prefixed_empty;
    try runtime.write(u32, &malformed, 0, std.math.maxInt(u32));
    try testing.expectError(
        error.OutOfBounds,
        runtime.Table.from(&malformed, source),
    );
    try runtime.write(u32, &malformed, 0, 0);
    try testing.expectError(
        error.OutOfBounds,
        runtime.Table.from(&malformed, .{ .options = .{
            .format = .size_prefixed,
            .boundary = .first,
        } }),
    );
    try testing.expectError(
        error.IdentifierMismatch,
        runtime.Table.from(&prefixed_identified_empty, .{ .options = .{
            .format = .size_prefixed,
            .identifier = "BFBS".*,
        } }),
    );
}

test "prefixed streams consume one frame and reject references into the next" {
    const options: runtime.framing.Options = .{
        .format = .size_prefixed,
        .boundary = .first,
    };
    var messages = prefixed_empty ++ prefixed_identified_empty;
    try testing.expectError(
        error.InvalidBuffer,
        runtime.Table.from(&messages, .{ .options = .{
            .format = .size_prefixed,
        } }),
    );
    const first = try runtime.Table.from(
        &messages,
        .{ .options = options },
    );
    try testing.expectEqual(prefixed_empty.len, first.bytes.len);
    const remaining = messages[first.bytes.len..];
    const second = try runtime.Table.from(remaining, .{ .options = .{
        .format = .size_prefixed,
        .identifier = "READ".*,
    } });
    try testing.expectEqual(prefixed_identified_empty.len, second.bytes.len);
    // A valid empty table in the next message is outside the first frame.
    const root_offset_start = runtime.wire.size_prefix_size;
    const foreign_table = prefixed_empty.len + second.layout.table_start;
    try runtime.write(
        u32,
        &messages,
        root_offset_start,
        @intCast(foreign_table - root_offset_start),
    );
    try testing.expectError(
        error.OutOfBounds,
        runtime.Table.from(&messages, .{ .options = options }),
    );
}

test "prefixed child access preserves alignment bounds and headers" {
    const Child = struct {
        number: u64 = 0,
        value: f64 = 0,
        samples: ?[]const u64 = null,
        pub const Schema = runtime.Schema(@This(), .{
            .number = runtime.ScalarField(u64, 0, 0),
            .value = runtime.ScalarField(f64, 1, 0),
            .samples = runtime.ReferenceField(
                2,
                .{ .vector = runtime.ScalarCodec(u64) },
                .{},
            ),
        });
    };
    const Root = struct {
        child: ?*const Child = null,
        children: ?[]const *const Child = null,
        pub const Schema = runtime.Schema(@This(), .{
            .child = runtime.ReferenceField(0, .{ .table = Child }, .{}),
            .children = runtime.ReferenceField(
                1,
                .{ .vector = runtime.TableCodec(Child) },
                .{},
            ),
        });
    };
    // Looks like a valid empty vtable; child metadata must not reuse it.
    const identifier = [runtime.file_identifier_size]u8{ 4, 0, 4, 0 };
    var storage: [256]u8 align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    const child_handle = try Child.Schema.create(
        &builder,
        .{
            .number = 0x1122334455667788,
            .value = -1.5,
            .samples = &.{ 10, 20 },
        },
        .{},
    );
    const vector_handle = try builder.createReferenceVector(&.{child_handle}, .{});
    var context = try Root.Schema.Context.init(&builder);
    try Root.Schema.addFields(&context, .{ .child = child_handle, .children = vector_handle });
    const bytes = try builder.finish(
        try Root.Schema.endTable(&context),
        .{ .size_prefixed_identifier = identifier },
    );
    const options: runtime.framing.Options = .{
        .format = .size_prefixed,
        .identifier = identifier,
    };
    const table = try runtime.Table.from(
        bytes,
        .{ .options = options },
    );
    const child = (try table.readTable(0)).?;
    const children = (try table.readVector(runtime.TableCodec(Child), 1)).?;
    try testing.expectEqual(
        @as(usize, 0),
        bytes.len % runtime.storage_alignment,
    );
    try testing.expectEqual(
        @as(u64, 0x1122334455667788),
        try child.readField(u64, 0, 0),
    );
    try testing.expectEqual(@as(f64, -1.5), try child.readField(f64, 1, 0));
    const samples = (try child.readVector(runtime.ScalarCodec(u64), 2)).?;
    try testing.expectEqual(@as(u64, 20), try samples.get(1));
    try runtime.Verifier.verify(Root, bytes, .{ .frame = options });
    var stream_storage: [512]u8 = undefined;
    const stream = stream_storage[0 .. bytes.len * 2];
    @memcpy(stream[0..bytes.len], bytes);
    @memcpy(stream[bytes.len..], bytes);
    var stream_options = options;
    stream_options.boundary = .first;
    try runtime.Verifier.verify(Root, stream, .{ .frame = stream_options });
    const reference_start = (try child.fieldPosition(u32, 2)).?;
    // Point into an otherwise valid vector in the following frame.
    const foreign_sequence = bytes.len + samples.payload_start - runtime.sequence_length_size;
    try runtime.write(
        u32,
        stream,
        reference_start,
        @intCast(foreign_sequence - reference_start),
    );
    try testing.expectError(
        error.OutOfBounds,
        runtime.Verifier.verify(Root, stream, .{ .frame = stream_options }),
    );
    const mutable = try runtime.MutableTable.from(
        bytes,
        .{ .options = options },
    );
    const mutable_child = (try mutable.readTable(0)).?;
    try testing.expect(try mutable_child.mutateField(u64, 0, 42));
    try testing.expectEqual(
        @as(u64, 42),
        try (try children.get(0)).readField(u64, 0, 0),
    );
    try runtime.Verifier.verify(Root, bytes, .{ .frame = options });
    const marker_start = runtime.wire.size_prefix_size + runtime.wire.file_identifier_start;
    try runtime.write(
        i32,
        bytes,
        child.layout.table_start,
        @intCast(child.layout.table_start - marker_start),
    );
    try testing.expectError(error.InvalidBuffer, table.readTable(0));
    try testing.expectError(error.InvalidBuffer, children.get(0));
    try testing.expectError(
        error.InvalidBuffer,
        runtime.Verifier.verify(Root, bytes, .{ .frame = options }),
    );
}

test "prefixed finish capacity failure is atomic and permits ordinary retry" {
    var storage: [24]u8 align(runtime.storage_alignment) = @splat(0);
    var builder = runtime.Builder.init(&storage);
    var context = try runtime.TableBuilder(1).init(&builder);
    try context.addScalar(u64, 0, 1, 0);
    const root_handle = try context.endTable();
    const original = storage;
    const write_cursor = builder.write_cursor;
    try testing.expectError(
        error.NoSpaceLeft,
        builder.finish(root_handle, .size_prefixed),
    );
    try testing.expectEqualSlices(u8, &original, &storage);
    try testing.expectEqual(write_cursor, builder.write_cursor);
    try testing.expectEqual(runtime.Builder.State.ready, builder.state);
    _ = try builder.finish(root_handle, .ordinary);
}
