const std = @import("std");
const runtime = @import("runtime");
const fixtures = @import("test_union_schema.zig");

const buffer_access = runtime.buffer_access;
const testing = std.testing;
const Storage = [fixtures.storage_capacity]u8;

const union_frames = .{
    .{ runtime.Builder.FinishOptions.ordinary, runtime.framing.Options{} },
    .{
        runtime.Builder.FinishOptions{ .identifier = "UNIO".* },
        runtime.framing.Options{ .identifier = "UNIO".* },
    },
    .{
        runtime.Builder.FinishOptions.size_prefixed,
        runtime.framing.Options{ .format = .size_prefixed },
    },
    .{
        runtime.Builder.FinishOptions{ .size_prefixed_identifier = "UNIO".* },
        runtime.framing.Options{ .format = .size_prefixed, .identifier = "UNIO".* },
    },
};

/// Check every union alternative, then mutate shared event and struct payloads in `bytes`.
/// The caller owns the frame; validation, mutation, and test assertion errors propagate.
pub fn checkFixture(bytes: []u8, frame: runtime.framing.Options) !void {
    try runtime.Verifier.verify(fixtures.Packet, bytes, .{ .frame = frame });
    const table = try runtime.Table.from(bytes, .{ .options = frame });
    const packet = try fixtures.Packet.Schema.read(table);
    try testing.expectEqual(@as(u32, 42), packet.marker);
    const event = try fixtures.Event.Schema.read(packet.current.event);
    try testing.expectEqual(fixtures.number, event.number);
    try testing.expectEqualStrings(fixtures.label, event.name.?);
    try testing.expectEqualDeep(
        fixtures.structs.envelope,
        try packet.required_value.envelope.read(),
    );
    const history = packet.history.?;
    try testing.expectEqual(@as(usize, 5), history.element_count);
    try testing.expectEqual(
        packet.current.event.layout.table_start,
        (try history.get(0)).event.layout.table_start,
    );
    try testing.expectEqual(
        fixtures.Payload.Tag.none,
        std.meta.activeTag(try history.get(1)),
    );
    try testing.expectEqualDeep(
        fixtures.structs.envelope,
        try (try history.get(2)).envelope.read(),
    );
    try testing.expectEqualStrings(fixtures.message, (try history.get(3)).text);
    try testing.expectEqual(
        packet.current.event.layout.table_start,
        (try history.get(4)).again.layout.table_start,
    );
    try testing.expectEqual(@as(usize, 0), packet.required_history.?.element_count);
    // Mutation is through the selected borrowed payload; tags are unchanged.
    const mutable = try runtime.MutableTable.from(bytes, .{ .options = frame });
    const current = try mutable.readUnion(fixtures.Payload, .{ .tag = 0, .value = 1 });
    try testing.expect(try current.event.mutateField(u64, 0, 99));
    try testing.expectEqual(
        @as(u64, 99),
        (try fixtures.Event.Schema.read((try history.get(4)).again)).number,
    );
    const vector = (try mutable.readUnionVector(fixtures.Payload, .{ .tag = 2, .value = 3 })).?;
    try (try vector.get(2)).envelope.update(.measure, 25.5);
    try testing.expectEqual(@as(f64, 25.5), try packet.required_value.envelope.get(.measure));
    try runtime.Verifier.verify(fixtures.Packet, bytes, .{ .frame = frame });
}

test "all union alternatives and paired vectors in every frame" {
    try testing.expectEqual(@as(usize, 9), fixtures.Packet.Schema.field_count);
    inline for (union_frames) |frame| {
        var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
        try checkFixture(try fixtures.build(&storage, frame[0]), frame[1]);
    }
}

const OptionalPacket = struct {
    current: fixtures.Payload.Value = .none,
    history: ?[]const fixtures.Payload.Value = null,

    pub const Schema = runtime.Schema(@This(), .{
        .current = runtime.UnionField(fixtures.Payload, .{ .tag = 0, .value = 1 }, .{}),
        .history = runtime.UnionVectorField(fixtures.Payload, .{ .tag = 2, .value = 3 }, .{}),
    });
};

test "NONE differs from an absent or empty union vector" {
    for ([_]bool{ false, true }) |force_defaults| {
        for ([_]?[]const fixtures.Payload.Value{ null, &.{}, &.{.none} }) |history| {
            var storage: Storage align(runtime.storage_alignment) = undefined;
            var builder = runtime.Builder.init(&storage);
            const bytes = try builder.finish(try OptionalPacket.Schema.create(
                &builder,
                .{ .history = history },
                .{ .force_defaults = force_defaults },
            ), .ordinary);
            try runtime.Verifier.verify(OptionalPacket, bytes, .{});
            const table = try runtime.Table.from(bytes, .root);
            const view = try OptionalPacket.Schema.read(table);
            try testing.expect(view.current == .none);
            try testing.expect((try table.fieldPosition(u8, 0) != null) == force_defaults);
            try testing.expect(try table.fieldPosition(u32, 1) == null);
            if (history) |present| {
                try testing.expectEqual(present.len, view.history.?.element_count);
                if (present.len != 0) try testing.expect(try view.history.?.get(0) == .none);
            } else try testing.expect(view.history == null);
        }
    }
}

test "required unions and union vectors reject absence before writes" {
    var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
    var builder = runtime.Builder.init(&storage);
    const text = try builder.createString("");
    const empty = try builder.createReferenceVector(&.{}, .{ .union_type = fixtures.Payload });
    for ([_]fixtures.Packet{
        .{ .required_history = &.{} },
        .{ .required_value = .{ .text = "" } },
    }) |value| {
        const before_storage = storage;
        const before_builder = builder;
        try testing.expectError(
            error.MissingRequiredField,
            fixtures.Packet.Schema.create(&builder, value, .{}),
        );
        try testing.expectEqualSlices(u8, &before_storage, &storage);
        try testing.expectEqualDeep(before_builder, builder);
    }
    var context = try fixtures.Packet.Schema.Context.init(&builder);
    const before_storage = storage;
    const before_builder = builder;
    try testing.expectError(error.MissingRequiredField, fixtures.Packet.Schema.endTable(&context));
    try testing.expectEqualSlices(u8, &before_storage, &storage);
    try testing.expectEqualDeep(before_builder, builder);
    try context.addUnion(fixtures.Payload, .{ .tag = 4, .value = 5 }, .{ .text = text });
    try testing.expectError(error.MissingRequiredField, fixtures.Packet.Schema.endTable(&context));
    try context.addUnionVector(.{ .tag = 6, .value = 7 }, empty);
    const bytes = try builder.finish(try fixtures.Packet.Schema.endTable(&context), .ordinary);
    try runtime.Verifier.verify(fixtures.Packet, bytes, .{});
    try testing.expectError(
        error.InvalidState,
        context.addUnion(fixtures.Payload, .{ .tag = 0, .value = 1 }, .none),
    );
}

test "incremental finalization checks raw discriminator and payload pairs" {
    for ([_]u8{ 0, 1, 250 }) |tag| {
        var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
        var builder = runtime.Builder.init(&storage);
        const text = try builder.createString("payload");
        var context = try OptionalPacket.Schema.Context.init(&builder);
        try context.addScalar(u8, 0, tag, 0);
        if (tag != 1) try context.addOffset(1, text);
        const before_storage = storage;
        const before_builder = builder;
        try testing.expectError(error.InvalidUnion, OptionalPacket.Schema.endTable(&context));
        try testing.expectEqualSlices(u8, &before_storage, &storage);
        try testing.expectEqualDeep(before_builder, builder);
        // Raw finalization deliberately bypasses schema construction checks.
        const bytes = try builder.finish(try context.endTable(), .ordinary);
        const expected = if (tag == 250) error.UnknownUnionTag else error.InvalidUnion;
        try testing.expectError(expected, runtime.Verifier.verify(OptionalPacket, bytes, .{}));
    }
}

test "paired fields reject partial and unequal union vectors" {
    for ([_]bool{ false, true }) |mismatched| {
        var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
        var builder = runtime.Builder.init(&storage);
        const tags = try builder.createVector(u8, &.{0});
        const values = try builder.createVector(u32, &.{});
        var context = try OptionalPacket.Schema.Context.init(&builder);
        try context.addOffset(2, tags);
        if (mismatched) try context.addOffset(3, values);
        const before_storage = storage;
        try testing.expectError(error.InvalidUnion, OptionalPacket.Schema.endTable(&context));
        try testing.expectEqualSlices(u8, &before_storage, &storage);
        const bytes = try builder.finish(try context.endTable(), .ordinary);
        const table = try runtime.Table.from(bytes, .root);
        try testing.expectError(
            error.InvalidUnion,
            table.readUnionVector(fixtures.Payload, .{ .tag = 2, .value = 3 }),
        );
        try testing.expectError(
            error.InvalidUnion,
            runtime.Verifier.verify(OptionalPacket, bytes, .{}),
        );
    }
}

test "schema addFields rejects invalid union handles before adding fields" {
    var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
    var builder = runtime.Builder.init(&storage);
    const empty = try builder.createReferenceVector(&.{}, .{ .union_type = fixtures.Payload });
    var context = try OptionalPacket.Schema.Context.init(&builder);
    const invalid: runtime.Builder.Offset = @fromBackingInt(@as(u32, 0));
    const before_storage = storage;
    const before_builder = builder;
    const before_fields = context.field_offsets;
    try testing.expectError(
        error.InvalidOffset,
        OptionalPacket.Schema.addFields(&context, .{
            .current = .{ .text = invalid },
            .history = empty,
        }),
    );
    try testing.expectEqualSlices(u8, &before_storage, &storage);
    try testing.expectEqualDeep(before_builder, builder);
    try testing.expectEqualDeep(before_fields, context.field_offsets);
    try OptionalPacket.Schema.addFields(&context, .{ .history = empty });
    const bytes = try builder.finish(try OptionalPacket.Schema.endTable(&context), .ordinary);
    try runtime.Verifier.verify(OptionalPacket, bytes, .{});
}

test "invalid union handles precede later missing required fields without writes" {
    const Required = runtime.Schema(struct {
        current: fixtures.Payload.Value = .none,
        label: ?[]const u8 = null,
    }, .{
        .current = runtime.UnionField(
            fixtures.Payload,
            .{ .tag = 0, .value = 1 },
            .{ .required = true },
        ),
        .label = runtime.ReferenceField(2, .string, .{ .required = true }),
    });
    var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
    var builder = runtime.Builder.init(&storage);
    const text = try builder.createString("");
    var context = try Required.Context.init(&builder);
    const invalid: runtime.Builder.Offset = @fromBackingInt(@as(u32, 0));
    const before_storage = storage;
    const before_builder = builder;
    const before_context = context;
    try testing.expectError(error.InvalidOffset, Required.addFields(&context, .{
        .current = .{ .text = invalid },
    }));
    try testing.expectEqualSlices(u8, &before_storage, &storage);
    try testing.expectEqualDeep(before_builder, builder);
    try testing.expectEqualDeep(before_context, context);
    try Required.addFields(&context, .{ .current = .{ .text = text }, .label = text });
    const bytes = try builder.finish(try Required.endTable(&context), .ordinary);
    try Required.verify(bytes, .{});
}

test "unknown union alternatives fail explicitly until metadata adds the tag" {
    const FuturePayload = runtime.Union(enum(u8) { none, text = 250 }, .{
        .none = .none,
        .text = .string,
    });
    const FuturePacket = struct {
        current: FuturePayload.Value,
        pub const Schema = runtime.Schema(@This(), .{
            .current = runtime.UnionField(FuturePayload, .{ .tag = 0, .value = 1 }, .{}),
        });
    };
    var storage: Storage align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    const bytes = try builder.finish(try FuturePacket.Schema.create(
        &builder,
        .{
            .current = .{ .text = "future" },
        },
        .{},
    ), .ordinary);
    try runtime.Verifier.verify(FuturePacket, bytes, .{});
    try testing.expectError(
        error.UnknownUnionTag,
        runtime.Verifier.verify(OptionalPacket, bytes, .{}),
    );
    try testing.expectError(
        error.UnknownUnionTag,
        OptionalPacket.Schema.read(try runtime.Table.from(bytes, .root)),
    );
}

test "union vector malformed tags nulls and bounds are checked locally" {
    for (std.meta.tags(enum { unknown, missing, unexpected })) |damage| {
        var storage: Storage align(runtime.storage_alignment) = undefined;
        const bytes = try fixtures.build(&storage, .ordinary);
        const table = try runtime.Table.from(bytes, .root);
        const vector = (try table.readUnionVector(fixtures.Payload, .{ .tag = 2, .value = 3 })).?;
        switch (damage) {
            .unknown => bytes[vector.tags_start] = 250,
            .missing => try buffer_access.writeScalar(u32, bytes, vector.values_start, 0),
            .unexpected => bytes[vector.tags_start] = 0,
        }
        const expected = if (damage == .unknown) error.UnknownUnionTag else error.InvalidUnion;
        try testing.expectError(expected, vector.get(0));
        try testing.expectError(expected, runtime.Verifier.verify(fixtures.Packet, bytes, .{}));
    }
    var storage: Storage align(runtime.storage_alignment) = undefined;
    const bytes = try fixtures.build(&storage, .ordinary);
    const table = try runtime.Table.from(bytes, .root);
    const vector = (try table.readUnionVector(fixtures.Payload, .{ .tag = 2, .value = 3 })).?;
    try testing.expectError(error.OutOfBounds, vector.get(vector.element_count));
    var forged = vector;
    forged.element_count = std.math.maxInt(usize);
    try testing.expectError(error.OutOfBounds, forged.get(0));
    forged = vector;
    forged.values_start = std.math.maxInt(usize) - 3;
    try testing.expectError(error.OutOfBounds, forged.get(0));
}

test "union vector payloads cannot overlap either metadata array" {
    var storage: Storage align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    // Build tag bytes later in the buffer, behind the offset array. A forged
    // string reference would otherwise interpret the tag-vector count as text.
    const tags = try builder.createVector(u8, &.{3});
    const values = try builder.createVector(u32, &.{1});
    var context = try OptionalPacket.Schema.Context.init(&builder);
    try context.addUnionVector(.{ .tag = 2, .value = 3 }, .{ .tag = tags, .value = values });
    const bytes = try builder.finish(try OptionalPacket.Schema.endTable(&context), .ordinary);
    const table = try runtime.Table.from(bytes, .root);
    const vector = (try table.readUnionVector(fixtures.Payload, .{ .tag = 2, .value = 3 })).?;
    try buffer_access.writeScalar(
        u32,
        bytes,
        vector.values_start,
        @intCast(vector.tags_start - runtime.wire.sequence_length_size - vector.values_start),
    );
    try testing.expectError(error.InvalidBuffer, vector.get(0));
    try testing.expectError(
        error.InvalidBuffer,
        runtime.Verifier.verify(OptionalPacket, bytes, .{}),
    );
    // The two vectors themselves must not overlap, except shared empty vectors.
    const value_slot = (try table.fieldPosition(u32, 3)).?;
    try buffer_access.writeScalar(
        u32,
        bytes,
        value_slot,
        @intCast(vector.tags_start - runtime.wire.sequence_length_size - value_slot),
    );
    try testing.expectError(
        error.InvalidUnion,
        table.readUnionVector(fixtures.Payload, .{ .tag = 2, .value = 3 }),
    );
}

test "union vectors budget before element traversal and strings before UTF8" {
    var storage: Storage align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    const bytes = try builder.finish(try OptionalPacket.Schema.create(
        &builder,
        .{
            .history = &.{.{ .text = "valid" }},
        },
        .{},
    ), .ordinary);
    const table = try runtime.Table.from(bytes, .root);
    const vector = (try table.readUnionVector(fixtures.Payload, .{ .tag = 2, .value = 3 })).?;
    const string = (try vector.get(0)).text;
    bytes[@intFromPtr(string.ptr) - @intFromPtr(bytes.ptr)] = 0xff;
    const table_work = table.layout.table_size + table.layout.vtable_size +
        OptionalPacket.Schema.field_count;
    const vector_work = 2 * runtime.wire.sequence_length_size + runtime.wire.field_offset_size + 1;
    try testing.expectError(
        error.WorkLimit,
        runtime.Verifier.verify(OptionalPacket, bytes, .{ .max_work = table_work }),
    );
    try testing.expectError(
        error.WorkLimit,
        runtime.Verifier.verify(OptionalPacket, bytes, .{ .max_work = table_work + vector_work }),
    );
    try testing.expectError(
        error.ObjectLimit,
        runtime.Verifier.verify(OptionalPacket, bytes, .{ .max_objects = 3 }),
    );
    try testing.expectError(
        error.InvalidBuffer,
        runtime.Verifier.verify(OptionalPacket, bytes, .{}),
    );
}

test "recursive table unions specialize lazily and retain depth limits" {
    const Node = struct {
        next: Link.Value = .none,
        const Link = runtime.Union(enum(u8) { none, child }, .{
            .none = .none,
            .child = .{ .table = @This() },
        });
        pub const Schema = runtime.Schema(@This(), .{
            .next = runtime.UnionField(Link, .{ .tag = 0, .value = 1 }, .{}),
        });
    };
    var storage: Storage align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    const leaf: Node = .{};
    const middle: Node = .{ .next = .{ .child = &leaf } };
    const bytes = try builder.finish(try Node.Schema.create(
        &builder,
        .{
            .next = .{ .child = &middle },
        },
        .{},
    ), .ordinary);
    try runtime.Verifier.verify(Node, bytes, .{ .max_depth = 3 });
    try testing.expectError(
        error.DepthLimit,
        runtime.Verifier.verify(Node, bytes, .{ .max_depth = 2 }),
    );
    try testing.expectError(
        error.ObjectLimit,
        runtime.Verifier.verify(Node, bytes, .{ .max_objects = 2 }),
    );
}

test "union vector construction rejects capacity invalid handles and aliasing atomically" {
    for (std.meta.tags(enum { capacity, handle, alias })) |failure| {
        var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
        const usable_size = if (failure == .capacity) 8 else storage.len;
        var builder = runtime.Builder.init(storage[0..usable_size]);
        const aliased: *[1]fixtures.Payload.Handle = @ptrCast(@alignCast(&storage));
        aliased[0] = .none;
        const before_storage = storage;
        const before_builder = builder;
        const invalid: fixtures.Payload.Handle = .{ .text = @fromBackingInt(4) };
        const values: []const fixtures.Payload.Handle = switch (failure) {
            .capacity => &.{.none},
            .handle => &.{invalid},
            .alias => aliased,
        };
        const expected = switch (failure) {
            .capacity => error.NoSpaceLeft,
            .handle => error.InvalidOffset,
            .alias => error.AliasedInput,
        };
        try testing.expectError(
            expected,
            builder.createReferenceVector(values, .{ .union_type = fixtures.Payload }),
        );
        try testing.expectEqualSlices(u8, &before_storage, &storage);
        try testing.expectEqualDeep(before_builder, builder);
    }
}

test "native reference callbacks preserve union tags and release reservations on failure" {
    const Callback = struct {
        fn pack(
            comptime UnionType: type,
            builder: *runtime.Builder,
            value: UnionType.Value,
        ) runtime.BuildError!UnionType.Handle {
            const text = switch (value) {
                .none => return .none,
                .text => |text| text,
                else => return error.InvalidUnion,
            };
            if (std.mem.eql(u8, text, "callback")) return error.InvalidUtf8;
            if (std.mem.eql(u8, text, "state")) {
                builder.state = .table;
                return .none;
            }
            if (std.mem.eql(u8, text, "tag")) return .none;
            return .{ .text = try builder.createString(text) };
        }
    };
    for (std.meta.tags(enum { valid, callback, state, tag })) |mode| {
        var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
        var builder = runtime.Builder.init(&storage);
        const values = [_]fixtures.Payload.Value{.{ .text = @tagName(mode) }};
        const result = builder.createReferenceVector(
            &values,
            .{ .union_type = fixtures.Payload, .create = Callback.pack },
        );
        if (mode == .valid) {
            const history: runtime.Builder.UnionVector = try result;
            var context = try OptionalPacket.Schema.Context.init(&builder);
            try OptionalPacket.Schema.addFields(&context, .{ .history = history });
            const bytes = try builder.finish(
                try OptionalPacket.Schema.endTable(&context),
                .ordinary,
            );
            try runtime.Verifier.verify(OptionalPacket, bytes, .{});
            const packet = try OptionalPacket.Schema.read(try runtime.Table.from(bytes, .root));
            try testing.expectEqualStrings("valid", (try packet.history.?.get(0)).text);
        } else {
            try testing.expectError(switch (mode) {
                .callback => error.InvalidUtf8,
                .state => error.InvalidState,
                .tag => error.InvalidUnion,
                .valid => unreachable,
            }, result);
        }
        try testing.expectEqual(@as(usize, 0), builder.scratch_cursor);
    }
}

test "paired union field additions preflight both slots and all required bytes" {
    for (std.meta.tags(enum { capacity, duplicate, handle })) |failure| {
        var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
        var builder = runtime.Builder.init(if (failure == .capacity) storage[0..16] else &storage);
        const text = try builder.createString("text");
        var context = try OptionalPacket.Schema.Context.init(&builder);
        if (failure == .duplicate) try context.addOffset(1, text);
        const value: fixtures.Payload.Handle = .{
            .text = if (failure == .handle) @fromBackingInt(0) else text,
        };
        const before_storage = storage;
        const before_builder = builder;
        const before_fields = context.field_offsets;
        const expected = switch (failure) {
            .capacity => error.NoSpaceLeft,
            .duplicate => error.DuplicateField,
            .handle => error.InvalidOffset,
        };
        try testing.expectError(
            expected,
            context.addUnion(fixtures.Payload, .{ .tag = 0, .value = 1 }, value),
        );
        try testing.expectEqualSlices(u8, &before_storage, &storage);
        try testing.expectEqualDeep(before_builder, builder);
        try testing.expectEqualDeep(before_fields, context.field_offsets);
        try testing.expectError(
            error.InvalidState,
            builder.createReferenceVector(&.{}, .{ .union_type = fixtures.Payload }),
        );
        try testing.expectError(
            error.InvalidState,
            builder.createStruct(fixtures.structs.Envelope.Layout, fixtures.structs.envelope),
        );
    }
}

test "standalone union structs decode members and charge work before scanning" {
    const Closed = struct {
        state: enum(u8) { idle, ready },
        pub const Layout = runtime.StructLayout(@This(), .{
            .size = 1,
            .alignment = 1,
        }, .{ .state = runtime.ScalarMember(@FieldType(@This(), "state"), 0) });
    };
    const Payload = runtime.Union(enum(u8) { none, closed }, .{
        .none = .none,
        .closed = .{ .structure = Closed.Layout },
    });
    const Packet = struct {
        current: Payload.Value,
        pub const Schema = runtime.Schema(@This(), .{
            .current = runtime.UnionField(Payload, .{ .tag = 0, .value = 1 }, .{}),
        });
    };
    var storage: Storage align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    const bytes = try builder.finish(try Packet.Schema.create(
        &builder,
        .{
            .current = .{ .closed = .{ .state = .ready } },
        },
        .{},
    ), .ordinary);
    try runtime.Verifier.verify(Packet, bytes, .{});
    const table = try runtime.Table.from(bytes, .root);
    const view = (try Packet.Schema.read(table)).current.closed;
    try testing.expectEqual(.ready, try view.get(.state));
    const reference = (try table.fieldPosition(u32, 1)).?;
    const target = reference + try buffer_access.readScalar(u32, bytes, reference);
    bytes[target] = 250;
    const table_work = table.layout.table_size + table.layout.vtable_size +
        Packet.Schema.field_count;
    try testing.expectError(error.WorkLimit, runtime.Verifier.verify(Packet, bytes, .{
        .max_work = table_work + Closed.Layout.wire_size,
    }));
    try testing.expectError(
        error.ObjectLimit,
        runtime.Verifier.verify(Packet, bytes, .{ .max_objects = 1 }),
    );
    try testing.expectError(error.InvalidBuffer, runtime.Verifier.verify(Packet, bytes, .{}));
    try testing.expectError(error.InvalidBuffer, view.read());
}

test "union vector slot additions preflight both fields before writing" {
    for (std.meta.tags(enum { capacity, duplicate, handle })) |failure| {
        var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
        var builder = runtime.Builder.init(if (failure == .capacity) storage[0..8] else &storage);
        var empty = try builder.createReferenceVector(&.{}, .{ .union_type = fixtures.Payload });
        var context = try OptionalPacket.Schema.Context.init(&builder);
        if (failure == .duplicate) try context.addOffset(2, empty.tag);
        if (failure == .handle) empty.tag = @fromBackingInt(0);
        const before_storage = storage;
        const before_builder = builder;
        const before_fields = context.field_offsets;
        const expected = switch (failure) {
            .capacity => error.NoSpaceLeft,
            .duplicate => error.DuplicateField,
            .handle => error.InvalidOffset,
        };
        try testing.expectError(expected, context.addUnionVector(.{ .tag = 2, .value = 3 }, empty));
        try testing.expectEqualSlices(u8, &before_storage, &storage);
        try testing.expectEqualDeep(before_builder, builder);
        try testing.expectEqualDeep(before_fields, context.field_offsets);
    }
}

test "a shared empty union vector is valid but missing required fields are not" {
    var storage: Storage align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    const empty = try builder.createVector(u32, &.{});
    var context = try fixtures.Packet.Schema.Context.init(&builder);
    try context.addUnionVector(.{ .tag = 2, .value = 3 }, .{ .tag = empty, .value = empty });
    const bytes = try builder.finish(try context.endTable(), .ordinary);
    try runtime.Verifier.verify(OptionalPacket, bytes, .{});
    const view = try OptionalPacket.Schema.read(
        try runtime.Table.from(bytes, .root),
    );
    try testing.expectEqual(@as(usize, 0), view.history.?.element_count);
    try testing.expectError(error.OutOfBounds, view.history.?.get(0));
    try testing.expectError(
        error.MissingRequiredField,
        runtime.Verifier.verify(fixtures.Packet, bytes, .{}),
    );
}

test "union verification tolerates bounded corruption without trapping" {
    var storage: Storage align(runtime.storage_alignment) = undefined;
    const bytes = try fixtures.build(&storage, .ordinary);
    for (0..bytes.len) |length| {
        runtime.Verifier.verify(fixtures.Packet, bytes[0..length], .{}) catch {};
    }
    for (0..bytes.len) |byte_index| {
        const original = bytes[byte_index];
        for ([_]u8{ 0, 1, 0x7f, 0xff }) |replacement| {
            bytes[byte_index] = replacement;
            runtime.Verifier.verify(fixtures.Packet, bytes, .{
                .max_depth = 8,
                .max_objects = 100,
                .max_work = 4096,
            }) catch {};
        }
        bytes[byte_index] = original;
    }
    try runtime.Verifier.verify(fixtures.Packet, bytes, .{});
}
