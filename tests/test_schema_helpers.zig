//! Shared helpers are exercised independently of generated convenience methods.
const std = @import("std");
const runtime = @import("runtime");
const structs = @import("test_struct_schema.zig");
const unions = @import("test_union_schema.zig");
const graph = @import("test_schema.zig");

const testing = std.testing;

// This native type deliberately has no nested Schema declaration.
const Values = struct {
    label: ?[]const u8 = null,
    numbers: ?[]const u64 = null,
    tags: ?[]const []const u8 = null,
    items: ?[]const structs.Envelope = null,
    enabled: bool = false,
    optional: ?u32 = null,
};
const Definition = runtime.Schema(Values, .{
    .label = runtime.ReferenceField(2, .string, .{}),
    .numbers = runtime.ReferenceField(7, .{ .vector = runtime.ScalarCodec(u64) }, .{}),
    .tags = runtime.ReferenceField(10, .{ .vector = runtime.StringCodec }, .{}),
    .items = runtime.ReferenceField(
        13,
        .{ .vector = runtime.StructCodec(structs.Envelope.Layout) },
        .{},
    ),
    .enabled = runtime.ScalarField(bool, 18, false),
    .optional = runtime.ScalarField(?u32, 19, null),
});
const frames = .{
    .{ runtime.Builder.FinishOptions.ordinary, runtime.framing.Options{} },
    .{
        runtime.Builder.FinishOptions{ .identifier = "TEST".* },
        runtime.framing.Options{ .identifier = "TEST".* },
    },
    .{
        runtime.Builder.FinishOptions.size_prefixed,
        runtime.framing.Options{ .format = .size_prefixed },
    },
    .{
        runtime.Builder.FinishOptions{ .size_prefixed_identifier = "TEST".* },
        runtime.framing.Options{ .format = .size_prefixed, .identifier = "TEST".* },
    },
};

test "root helpers preserve defaults optional presence and verification limits" {
    var storage: runtime.Storage(Definition, .{}, .{}) = .{};
    const omitted = try Definition.serialize(.{}, &storage.buffer, .{});
    try testing.expect(!(try Definition.read(omitted)).enabled);
    try testing.expect(!try Definition.update(omitted, .enabled, true));
    try testing.expect((try Definition.read(omitted)).optional == null);
    try testing.expect(try Definition.borrowMutable(omitted, .items) == null);
    const present = try Definition.serialize(
        .{ .optional = 0 },
        &storage.buffer,
        .{ .force_defaults = true },
    );
    const immutable: []const u8 = present;
    try testing.expectEqual(@as(?u32, 0), (try Definition.read(immutable)).optional);
    const present_table = try runtime.MutableTable.from(present, .root);
    try testing.expect(try Definition.update(present_table, .enabled, true));
    const checked = try runtime.Table.from(present, .root);
    try testing.expect((try Definition.read(checked)).enabled);
    const before = storage.buffer;
    try testing.expectError(
        error.CannotClearField,
        Definition.update(present, .optional, null),
    );
    try testing.expectEqualSlices(u8, &before, &storage.buffer);
    var copied: [storage.buffer.len]u8 = @splat(0);
    @memcpy(copied[0..present.len], present);
    try testing.expect(try Definition.update(&copied, .enabled, false));
    try testing.expect(!(try Definition.read(&copied)).enabled);
    const frozen = copied;
    try testing.expect(!(try Definition.read(&frozen)).enabled);
    try Definition.verify(present, .{});
    try Definition.verify(&frozen, .{});
    // Checked tables retain the framing selected when opened.
    try Definition.verify(checked, .{ .frame = .{ .identifier = "NOPE".* } });
    try testing.expectError(error.DepthLimit, Definition.verify(present, .{ .max_depth = 0 }));
    try testing.expectError(error.WorkLimit, Definition.verify(present, .{ .max_work = 0 }));
    try testing.expectError(error.OutOfBounds, Definition.verify(&.{}, .{}));
    try testing.expectError(error.OutOfBounds, Definition.read(&.{}));
    var empty: [0]u8 = .{};
    try testing.expectError(error.OutOfBounds, Definition.update(&empty, .enabled, true));
    try testing.expectError(error.OutOfBounds, Definition.borrowMutable(&empty, .items));
}

test "serialize preserves exact error unions and aligned buffer coercions" {
    const value: Values = .{ .label = "sensor", .optional = 0 };
    const options: runtime.WriteOptions = .{ .force_defaults = true };
    var expected_storage: [512]u8 align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&expected_storage);
    builder.force_defaults = true;
    const label = try builder.createString("sensor");
    var context = try Definition.Context.init(&builder);
    try Definition.addFields(&context, .{ .label = label, .optional = 0 });
    const expected = try builder.finish(try Definition.endTable(&context), .ordinary);

    var buffer: [512]u8 align(runtime.storage_alignment) = undefined;
    const slice: []align(runtime.storage_alignment) u8 = &buffer;
    var extra_aligned: [512]u8 align(16) = undefined;
    var terminated: [512:0]u8 align(runtime.storage_alignment) = undefined;
    terminated[512] = 0;
    const terminated_slice: [:0]align(runtime.storage_alignment) u8 = &terminated;
    inline for (.{ &buffer, slice, &extra_aligned, &terminated, terminated_slice }) |target| {
        const result = Definition.serialize(value, target, options);
        try testing.expect(@TypeOf(result) == runtime.BuildError![]u8);
        const bytes = try result;
        try testing.expectEqualSlices(u8, expected, bytes);
        const supplied: []align(runtime.storage_alignment) u8 = target;
        try testing.expect(bytes.ptr == supplied[supplied.len - bytes.len ..].ptr);
        try Definition.verify(bytes, .{});
    }

    const result = Definition.serialize(value, testing.allocator, options);
    try testing.expect(
        @TypeOf(result) == (std.mem.Allocator.Error || runtime.BuildError)!runtime.Serialized,
    );
    const owned = try result;
    defer owned.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, expected, owned.bytes);
    try Definition.verify(owned.bytes, .{});
}

test "custom descriptor kinds retain checked reads and mutable borrowing" {
    const Descriptor = struct {
        pub const Value = ?structs.Sample;
        pub const View = ?runtime.StructView(structs.Sample.Layout, .read_only);
        pub const kind: union(enum) {
            scalar: type,
            structure: type,
            string,
            vector: type,
            table: type,
            union_value: type,
            union_vector: type,
        } = .{ .structure = structs.Sample.Layout };
        pub const wire_id = 0;
        pub const required = false;
    };
    const Custom = runtime.Schema(struct { sample: ?structs.Sample = null }, .{
        .sample = Descriptor,
    });
    var storage: [128]u8 align(runtime.storage_alignment) = undefined;
    const bytes = try Custom.serialize(.{ .sample = structs.sample }, &storage, .{});
    const view = try Custom.read(try runtime.Table.from(bytes, .root));
    try testing.expectEqual(structs.sample.number, try view.sample.?.get(.number));
    const sample = (try Custom.borrowMutable(
        try runtime.MutableTable.from(bytes, .root),
        .sample,
    )).?;
    try sample.update(.number, 42);
    try testing.expectEqual(@as(u64, 42), try view.sample.?.get(.number));
}

test "typed construction fields retain values and accept completed handles by name" {
    const fields: Definition.Fields = .{};
    try testing.expect(@TypeOf(fields.label) == ?runtime.Builder.Offset);
    try testing.expect(@TypeOf(fields.numbers) == ?runtime.Builder.Offset);
    try testing.expect(@TypeOf(fields.tags) == ?runtime.Builder.Offset);
    try testing.expect(@TypeOf(fields.items) == ?runtime.Builder.Offset);
    try testing.expect(fields.label == null and fields.numbers == null);
    try testing.expect(fields.tags == null and fields.items == null);
    try testing.expect(!fields.enabled and fields.optional == null);
    const references: graph.Graph.Schema.Fields = .{};
    try testing.expect(@TypeOf(references.child) == ?runtime.Builder.Offset);
    try testing.expect(@TypeOf(references.children) == ?runtime.Builder.Offset);
    const inline_fields: structs.Packet.Schema.Fields = .{ .envelope = structs.envelope };
    try testing.expectEqualDeep(structs.envelope, inline_fields.envelope.?);
    const union_fields: unions.Packet.Schema.Fields = .{};
    try testing.expect(@TypeOf(union_fields.current) == unions.Payload.Handle);
    try testing.expect(@TypeOf(union_fields.history) == ?runtime.Builder.UnionVector);
    try testing.expect(union_fields.current == .none and union_fields.history == null);
    const Defaults = struct {
        number: u32 = 23,
        point: ?structs.Sample = structs.sample,
        label: ?[]const u8 = "native",
        numbers: ?[]const u16 = &.{ 1, 2 },
        current: unions.Payload.Value = .{ .text = "native" },
        pub const Schema = runtime.Schema(@This(), .{
            .number = runtime.ScalarField(u32, 0, 23),
            .point = runtime.StructField(structs.Sample.Layout, 3, .{}),
            .label = runtime.ReferenceField(7, .string, .{}),
            .numbers = runtime.ReferenceField(10, .{ .vector = runtime.ScalarCodec(u16) }, .{}),
            .current = runtime.UnionField(unions.Payload, .{ .tag = 12, .value = 13 }, .{}),
        });
    };
    const defaults: Defaults.Schema.Fields = .{};
    try testing.expectEqual(@as(u32, 23), defaults.number);
    try testing.expectEqualDeep(structs.sample, defaults.point.?);
    try testing.expect(defaults.label == null and defaults.numbers == null);
    try testing.expect(defaults.current == .none);
}

test "value serialization preserves root bytes borrowed storage and capacity errors" {
    const value: Values = .{
        .label = "sensor-01",
        .numbers = &.{ 1, 2, 3 },
        .tags = &.{},
        .optional = 0,
    };
    const Storage = runtime.Storage(Definition, .{ .label = 64, .numbers = 128 }, .{});
    var storage: Storage = .{};
    var original: Storage = .{};
    const bytes = try Definition.serialize(value, &storage.buffer, .{ .force_defaults = true });
    var builder = runtime.Builder.init(&original.buffer);
    builder.force_defaults = true;
    const label = try builder.createString(value.label.?);
    const numbers = try builder.createVector(u64, value.numbers.?);
    const tags = try builder.createStringVector(value.tags.?);
    var context = try Definition.Context.init(&builder);
    try Definition.addFields(&context, .{
        .label = label,
        .numbers = numbers,
        .tags = tags,
        .optional = 0,
    });
    const expected = try builder.finish(try Definition.endTable(&context), .ordinary);
    try testing.expectEqualSlices(u8, expected, bytes);
    try testing.expect(bytes.len < storage.buffer.len);
    try testing.expect(bytes.ptr == storage.buffer[storage.buffer.len - bytes.len ..].ptr);
    try Definition.verify(bytes, .{});
    const view = try Definition.read(bytes);
    try testing.expectEqualStrings("sensor-01", view.label.?);
    try testing.expectEqual(@as(u64, 3), try view.numbers.?.get(2));
    try testing.expectEqual(@as(usize, 0), view.tags.?.element_count);
    try testing.expect(view.items == null);
    try testing.expectEqual(@as(?u32, 0), view.optional);
    try testing.expect(!view.enabled);
    const table = try runtime.MutableTable.from(bytes, .root);
    try testing.expect(try Definition.update(table, .enabled, true));
    try testing.expect((try Definition.read(bytes)).enabled);
    try Definition.verify(bytes, .{});
    var insufficient: [1]u8 align(runtime.storage_alignment) = undefined;
    try testing.expectError(error.NoSpaceLeft, Definition.serialize(value, &insufficient, .{}));
}

test "value derived storage bounds sparse fields wide vectors strings and all frames" {
    inline for (.{ 0, 1, 3, 17 }) |element_count| {
        inline for (.{ "", "a", "abcde" }) |label| {
            const value: Values = comptime .{
                .label = label,
                .numbers = &@as([element_count]u64, @splat(0x0102030405060708)),
                .tags = &.{ "", "é", "abcd" },
                .items = &@as([element_count]structs.Envelope, @splat(structs.envelope)),
                .optional = 0,
            };
            inline for (frames) |frame| {
                const capacity = comptime runtime.storage.capacityFor(Definition, value, .{
                    .finish = frame[0],
                });
                try testing.expectEqual(capacity, try runtime.storage.measure(
                    Definition,
                    value,
                    .{ .finish = frame[0] },
                ));
                try testing.expect(capacity % runtime.storage_alignment == 0);
                var storage: [capacity]u8 align(runtime.storage_alignment) = undefined;
                var original: runtime.Storage(Definition, .{
                    .label = label.len,
                    .numbers = element_count,
                    .tags = .{ .count = 3, .bytes = 6 },
                    .items = element_count,
                }, .{ .finish = frame[0] }) = .{};
                for ([_]bool{ false, true }) |force_defaults| {
                    const options: runtime.WriteOptions = .{ .force_defaults = force_defaults };
                    var builder = runtime.Builder.init(&storage);
                    const bytes = try builder.finish(
                        try Definition.create(&builder, value, options),
                        frame[0],
                    );
                    var reference = runtime.Builder.init(&original.buffer);
                    const expected = try reference.finish(
                        try Definition.create(&reference, value, options),
                        frame[0],
                    );
                    try testing.expectEqualSlices(u8, expected, bytes);
                    try Definition.verify(bytes, .{ .frame = frame[1] });
                    const view = try Definition.read(
                        try runtime.Table.from(bytes, .{ .options = frame[1] }),
                    );
                    try testing.expectEqualStrings(label, view.label.?);
                    try testing.expectEqual(element_count, view.numbers.?.element_count);
                    try testing.expectEqual(element_count, view.items.?.element_count);
                    for (value.tags.?, 0..) |tag, element_index|
                        try testing.expectEqualStrings(tag, try view.tags.?.get(element_index));
                    const table = try runtime.MutableTable.from(bytes, .{ .options = frame[1] });
                    const borrowed = (try Definition.borrowMutable(table, .items)).?;
                    const scalar_vector = (try Definition.borrowMutable(table, .numbers)).?;
                    if (element_count != 0) {
                        try testing.expectEqual(value.numbers.?[0], try scalar_vector.get(0));
                        try (try borrowed.get(0)).update(.measure, 12.5);
                        try testing.expectEqual(
                            @as(f64, 12.5),
                            try (try view.items.?.get(0)).get(.measure),
                        );
                    }
                }
            }
        }
    }
}

test "zero budgets retain empty sequences and empty schemas" {
    var storage: runtime.Storage(Definition, .{}, .{}) = .{};
    const bytes = try Definition.serialize(.{
        .label = "",
        .numbers = &.{},
        .tags = &.{},
        .items = &.{},
    }, &storage.buffer, .{});
    try Definition.verify(bytes, .{});
    const view = try Definition.read(bytes);
    try testing.expectEqualStrings("", view.label.?);
    try testing.expectEqual(@as(usize, 0), view.tags.?.element_count);
    const Empty = runtime.Schema(struct {}, .{});
    var empty_storage: runtime.Storage(Empty, .{}, .{}) = .{};
    try Empty.verify(try Empty.serialize(.{}, &empty_storage.buffer, .{}), .{});
}

test "value derived storage preserves absent empty and zero field values" {
    inline for (.{ Values{}, Values{
        .label = "",
        .numbers = &.{},
        .tags = &.{},
        .items = &.{},
    } }) |value| {
        const capacity = comptime runtime.storage.capacityFor(Definition, value, .{});
        var storage: [capacity]u8 align(runtime.storage_alignment) = undefined;
        const bytes = try Definition.serialize(value, &storage, .{});
        try Definition.verify(bytes, .{});
        const view = try Definition.read(bytes);
        try testing.expectEqual(value.label == null, view.label == null);
        try testing.expectEqual(value.numbers == null, view.numbers == null);
        try testing.expectEqual(value.tags == null, view.tags == null);
        try testing.expectEqual(value.items == null, view.items == null);
        if (view.label) |label| try testing.expectEqualStrings("", label);
        if (view.numbers) |numbers| try testing.expectEqual(@as(usize, 0), numbers.element_count);
        if (view.tags) |tags| try testing.expectEqual(@as(usize, 0), tags.element_count);
        if (view.items) |items| try testing.expectEqual(@as(usize, 0), items.element_count);
    }
    inline for (.{ NativeNode{}, NativeNode{ .children = &.{}, .history = &.{} } }) |value| {
        const capacity = comptime runtime.storage.capacityFor(NativeNode.Schema, value, .{});
        var storage: [capacity]u8 align(runtime.storage_alignment) = undefined;
        const bytes = try NativeNode.Schema.serialize(value, &storage, .{});
        try NativeNode.Schema.verify(bytes, .{});
        const view = try NativeNode.Schema.read(bytes);
        try testing.expectEqual(value.children == null, view.children == null);
        try testing.expectEqual(value.history == null, view.history == null);
        if (view.children) |children|
            try testing.expectEqual(@as(usize, 0), children.element_count);
        if (view.history) |history| try testing.expectEqual(@as(usize, 0), history.element_count);
    }
    const inline_value: structs.Packet = .{ .envelope = structs.envelope, .extra = structs.sample };
    const inline_capacity = comptime runtime.storage.capacityFor(
        structs.Packet.Schema,
        inline_value,
        .{},
    );
    var inline_storage: [inline_capacity]u8 align(runtime.storage_alignment) = undefined;
    try structs.Packet.Schema.verify(
        try structs.Packet.Schema.serialize(inline_value, &inline_storage, .{}),
        .{},
    );
    const Empty = runtime.Schema(struct {}, .{});
    const capacity = comptime runtime.storage.capacityFor(Empty, .{}, .{
        .max_depth = 1,
        .max_work = 1,
    });
    var storage: [capacity]u8 align(runtime.storage_alignment) = undefined;
    try Empty.verify(try Empty.serialize(.{}, &storage, .{}), .{});
}

test "value derived storage recursively sizes native child tables" {
    const value: graph.Graph = comptime graph_value_blk: {
        const leaf: graph.Node = .{ .name = "leaf" };
        const parent: graph.Node = .{ .name = "parent", .next = &leaf };
        break :graph_value_blk .{
            .child = &parent,
            .children = &.{ &leaf, &parent },
            .payload = &graph.payload,
        };
    };
    const capacity = comptime runtime.storage.capacityFor(graph.Graph.Schema, value, .{});
    var storage: [capacity]u8 align(runtime.storage_alignment) = undefined;
    const bytes = try graph.Graph.Schema.serialize(value, &storage, .{ .force_defaults = true });
    try graph.Graph.Schema.verify(bytes, .{});
    const view = try graph.Graph.Schema.read(bytes);
    const parent = try graph.Node.Schema.read(view.child.?);
    try testing.expectEqualStrings("parent", parent.name.?);
    try testing.expectEqualStrings("leaf", (try graph.Node.Schema.read(parent.next.?)).name.?);
    try testing.expectEqual(@as(usize, 2), view.children.?.element_count);
    try testing.expectEqual(@as(u8, 0xff), try view.payload.?.get(1));
}

test "storage budgets include union pairs vectors and explicitly built children" {
    inline for (frames) |frame| {
        var storage: runtime.Storage(unions.Packet.Schema, .{
            .current = runtime.storage.capacity(
                unions.Event.Schema,
                .{ .name = unions.label.len },
                .{},
            ),
            .required_value = structs.Envelope.Layout.wire_size +
                structs.Envelope.Layout.wire_alignment - 1,
            .history = .{ .count = 5, .bytes = 4 + unions.message.len + 1 + 3 },
        }, .{ .finish = frame[0] }) = .{};
        const bytes = try unions.build(&storage.buffer, frame[0]);
        try unions.Packet.Schema.verify(bytes, .{ .frame = frame[1] });
        const table = try runtime.MutableTable.from(bytes, .{ .options = frame[1] });
        const current = try unions.Packet.Schema.borrowMutable(table, .current);
        try testing.expect(try current.event.mutateField(u64, 0, 99));
        const history = (try unions.Packet.Schema.borrowMutable(table, .history)).?;
        try (try history.get(2)).envelope.update(.measure, 25.5);
        const envelope = try unions.Packet.Schema.borrowMutable(table, .required_value);
        try testing.expectEqual(@as(f64, 25.5), try envelope.envelope.get(.measure));
        const view = try unions.Packet.Schema.read(
            try runtime.Table.from(bytes, .{ .options = frame[1] }),
        );
        try testing.expectEqual(
            @as(u64, 99),
            (try unions.Event.Schema.read((try view.history.?.get(4)).again)).number,
        );
    }
}

test "explicit recursive table budgets and descriptor selected table borrowing" {
    const leaf_budget = comptime runtime.storage.capacity(graph.Node.Schema, .{ .name = 4 }, .{});
    const parent_budget = comptime runtime.storage.capacity(graph.Node.Schema, .{ .name = 6 }, .{});
    var storage: runtime.Storage(graph.Graph.Schema, .{
        .child = parent_budget,
        .children = .{ .count = 2, .bytes = leaf_budget },
        .payload = graph.payload.len,
    }, .{}) = .{};
    const bytes = try graph.build(&storage.buffer, .ordinary);
    const table = try runtime.MutableTable.from(bytes, .root);
    const child = (try graph.Graph.Schema.borrowMutable(table, .child)).?;
    try testing.expect(try graph.Node.Schema.update(child, .number, 123));
    const borrowed_children = (try graph.Graph.Schema.borrowMutable(table, .children)).?;
    try testing.expectEqual(@as(usize, 2), borrowed_children.element_count);
    const view = try graph.Graph.Schema.read(bytes);
    try testing.expectEqual(@as(u64, 123), (try graph.Node.Schema.read(view.child.?)).number);
    try graph.Graph.Schema.verify(bytes, .{});
}

// One recursive schema exercises nested table-vector and union-vector scratch.
const NativeNode = struct {
    label: ?[]const u8 = null,
    children: ?[]const *const NativeNode = null,
    payload: Payload.Value = .none,
    history: ?[]const Payload.Value = null,

    const Payload = runtime.Union(enum(u8) { none, child, text, envelope }, .{
        .none = .none,
        .child = .{ .table = @This() },
        .text = .string,
        .envelope = .{ .structure = structs.Envelope.Layout },
    });
    pub const Schema = runtime.Schema(@This(), .{
        .label = runtime.ReferenceField(0, .string, .{}),
        .children = runtime.ReferenceField(1, .{ .vector = runtime.TableCodec(@This()) }, .{}),
        .payload = runtime.UnionField(Payload, .{ .tag = 2, .value = 3 }, .{}),
        .history = runtime.UnionVectorField(Payload, .{ .tag = 4, .value = 5 }, .{}),
    });
};

test "value derived recursive vectors retain nested scratch and copy shared pointers" {
    const root: NativeNode = comptime native_graph_blk: {
        const leaf: NativeNode = .{ .label = "leaf" };
        const parent: NativeNode = .{
            .children = &.{ &leaf, &leaf },
            .history = &.{
                .{ .child = &leaf }, .{ .text = "inner" }, .{ .envelope = structs.envelope },
            },
        };
        break :native_graph_blk .{
            .children = &.{ &parent, &parent },
            .payload = .{ .envelope = structs.envelope },
            .history = &.{ .none, .{ .text = "root" } },
        };
    };
    inline for (frames) |frame| {
        const capacity = comptime runtime.storage.capacityFor(NativeNode.Schema, root, .{
            .finish = frame[0],
        });
        var storage: [capacity]u8 align(runtime.storage_alignment) = undefined;
        var original: [4096]u8 align(runtime.storage_alignment) = undefined;
        for ([_]bool{ false, true }) |force_defaults| {
            const options: runtime.WriteOptions = .{ .force_defaults = force_defaults };
            var builder = runtime.Builder.init(&storage);
            const handle = try NativeNode.Schema.create(&builder, root, options);
            try testing.expectEqual(@as(usize, 0), builder.scratch_cursor);
            const bytes = try builder.finish(handle, frame[0]);
            var reference = runtime.Builder.init(&original);
            const expected = try reference.finish(
                try NativeNode.Schema.create(&reference, root, options),
                frame[0],
            );
            try testing.expectEqualSlices(u8, expected, bytes);
            try NativeNode.Schema.verify(bytes, .{ .frame = frame[1] });
            const view = try NativeNode.Schema.read(
                try runtime.Table.from(bytes, .{ .options = frame[1] }),
            );
            const first = try view.children.?.get(0);
            const second = try view.children.?.get(1);
            try testing.expect(first.layout.table_start != second.layout.table_start);
            const branch = try NativeNode.Schema.read(first);
            const first_leaf = try branch.children.?.get(0);
            const second_leaf = try branch.children.?.get(1);
            try testing.expect(first_leaf.layout.table_start != second_leaf.layout.table_start);
            const union_leaf = (try branch.history.?.get(0)).child;
            try testing.expect(union_leaf.layout.table_start != first_leaf.layout.table_start);
            try testing.expectEqualStrings(
                "leaf",
                (try NativeNode.Schema.read(union_leaf)).label.?,
            );
            try testing.expectEqualStrings("inner", (try branch.history.?.get(1)).text);
            try testing.expectEqualDeep(
                structs.envelope,
                try (try branch.history.?.get(2)).envelope.read(),
            );
            try testing.expectEqualDeep(structs.envelope, try view.payload.envelope.read());
            try testing.expect(try view.history.?.get(0) == .none);
            try testing.expectEqualStrings("root", (try view.history.?.get(1)).text);
        }
    }
}

test "native work limits reject overflow without changing the counter" {
    var work: usize = 7;
    try runtime.schema.chargeNativeWork(&work, 15, 2, 4);
    try testing.expectEqual(@as(usize, 15), work);
    try testing.expectError(error.WorkLimit, runtime.schema.chargeNativeWork(&work, 15, 1, 1));
    try testing.expectEqual(@as(usize, 15), work);

    const maximum = std.math.maxInt(usize);
    work = 0;
    try testing.expectError(
        error.WorkLimit,
        runtime.schema.chargeNativeWork(&work, maximum, maximum, 2),
    );
    try testing.expectEqual(@as(usize, 0), work);
    work = maximum - 3;
    try testing.expectError(error.WorkLimit, runtime.schema.chargeNativeWork(&work, maximum, 2, 2));
    try testing.expectEqual(maximum - 3, work);
    try runtime.schema.chargeNativeWork(&work, maximum, 1, 3);
    try testing.expectEqual(maximum, work);
    try runtime.schema.chargeNativeWork(&work, maximum, 0, 2);
    try runtime.schema.chargeNativeWork(&work, maximum, maximum, 0);
    try testing.expectEqual(maximum, work);
}

test "native serialization bounds root depth work and cyclic inputs before writes" {
    const Empty = runtime.Schema(struct {}, .{});
    var storage: [512]u8 align(runtime.storage_alignment) = @splat(0xa5);
    const before = storage;
    try testing.expectError(error.DepthLimit, Empty.serialize(.{}, &storage, .{ .max_depth = 0 }));
    try testing.expectEqualSlices(u8, &before, &storage);
    try testing.expectError(error.WorkLimit, Empty.serialize(.{}, &storage, .{ .max_work = 0 }));
    try testing.expectEqualSlices(u8, &before, &storage);
    try Empty.verify(try Empty.serialize(.{}, &storage, .{
        .max_depth = 1,
        .max_work = 1,
    }), .{});
    const Scalar = runtime.Schema(struct { count: u32 = 0 }, .{
        .count = runtime.ScalarField(u32, 0, 0),
    });
    try testing.expectError(error.WorkLimit, Scalar.serialize(.{}, &storage, .{ .max_work = 1 }));
    const bytes = try Scalar.serialize(.{ .count = 42 }, &storage, .{ .max_work = 2 });
    try testing.expectEqual(@as(u32, 42), (try Scalar.read(bytes)).count);
    var cyclic: NativeNode = .{};
    cyclic.payload = .{ .child = &cyclic };
    const before_cycle = storage;
    try testing.expectError(error.DepthLimit, NativeNode.Schema.serialize(cyclic, &storage, .{}));
    try testing.expectEqualSlices(u8, &before_cycle, &storage);
    try testing.expectError(
        error.WorkLimit,
        NativeNode.Schema.serialize(cyclic, &storage, .{ .max_work = 5 }),
    );
    try testing.expectEqualSlices(u8, &before_cycle, &storage);
}

test "create applies native graph options and preserves failed preflight state" {
    const leaf: graph.Node = .{ .name = "leaf" };
    const root: graph.Node = .{ .name = "root", .next = &leaf };
    for ([_]bool{ false, true }) |force_defaults| {
        var storage: [512]u8 align(runtime.storage_alignment) = @splat(0xa5);
        var builder = runtime.Builder.init(&storage);
        builder.force_defaults = !force_defaults;
        const before_storage = storage;
        const before_builder = builder;
        try testing.expectError(error.DepthLimit, graph.Node.Schema.create(&builder, root, .{
            .force_defaults = force_defaults,
            .max_depth = 1,
        }));
        try testing.expectEqualSlices(u8, &before_storage, &storage);
        try testing.expectEqualDeep(before_builder, builder);
        try testing.expectError(error.WorkLimit, graph.Node.Schema.create(&builder, root, .{
            .force_defaults = force_defaults,
            .max_work = 0,
        }));
        try testing.expectEqualSlices(u8, &before_storage, &storage);
        try testing.expectEqualDeep(before_builder, builder);
        const options: runtime.WriteOptions = .{
            .force_defaults = force_defaults,
            .max_depth = 2,
            .max_work = 16,
        };
        const handle = try graph.Node.Schema.create(&builder, root, options);
        try testing.expectEqual(force_defaults, builder.force_defaults);
        const bytes = try builder.finish(handle, .ordinary);
        const table = try runtime.Table.from(bytes, .root);
        const child = (try graph.Node.Schema.read(table)).next.?;
        try testing.expect((try table.fieldPosition(u64, 0) != null) == force_defaults);
        try testing.expect((try child.fieldPosition(u64, 0) != null) == force_defaults);
        var expected_storage: [512]u8 align(runtime.storage_alignment) = undefined;
        const expected = try graph.Node.Schema.serialize(root, &expected_storage, options);
        try testing.expectEqualSlices(u8, expected, bytes);
        const finished_storage = storage;
        const finished_builder = builder;
        try testing.expectError(error.InvalidState, graph.Node.Schema.create(&builder, root, .{
            .force_defaults = !force_defaults,
        }));
        try testing.expectEqualSlices(u8, &finished_storage, &storage);
        try testing.expectEqualDeep(finished_builder, builder);
    }
}

test "native preflight rejects deep source aliases before earlier children write" {
    const leaf: NativeNode = .{ .label = "first child" };
    for (std.meta.tags(enum { payload, descriptors })) |alias| {
        var storage: [512]u8 align(runtime.storage_alignment) = @splat(0xa5);
        var later: NativeNode = .{};
        switch (alias) {
            .payload => {
                const text = storage[storage.len - 4 ..];
                @memcpy(text, "late");
                later.label = text;
            },
            .descriptors => {
                const children: *[1]*const NativeNode = @ptrCast(@alignCast(
                    storage[storage.len - @sizeOf(*const NativeNode) ..].ptr,
                ));
                children[0] = &leaf;
                later.children = children;
            },
        }
        const root: NativeNode = .{
            .label = "earlier root text",
            .children = &.{ &leaf, &later },
        };
        const before = storage;
        try testing.expectError(
            error.AliasedInput,
            NativeNode.Schema.serialize(root, &storage, .{}),
        );
        try testing.expectEqualSlices(u8, &before, &storage);
    }
}

test "native vector capacity failures release scratch and permit builder reset" {
    const leaf: NativeNode = .{ .label = "insufficient storage" };
    const root: NativeNode = .{ .children = &.{ &leaf, &leaf } };
    var storage: [64]u8 align(runtime.storage_alignment) = undefined;
    try testing.expectError(error.NoSpaceLeft, NativeNode.Schema.serialize(root, &storage, .{}));
    var builder = runtime.Builder.init(&storage);
    builder.force_defaults = true;
    try testing.expectError(
        error.NoSpaceLeft,
        NativeNode.Schema.create(&builder, root, .{ .force_defaults = builder.force_defaults }),
    );
    try testing.expectEqual(@as(usize, 0), builder.scratch_cursor);
    try testing.expect(builder.force_defaults);
    builder.reset();
    const bytes = try builder.finish(try NativeNode.Schema.create(
        &builder,
        .{},
        .{ .force_defaults = builder.force_defaults },
    ), .ordinary);
    try testing.expect(builder.force_defaults);
    try NativeNode.Schema.verify(bytes, .{});
}

test "native vectors reuse final output capacity without an extra handle buffer" {
    const leaf: NativeNode = .{};
    inline for (.{ 0, 1, 2, 128 }) |count| {
        const children: [count]*const NativeNode = @splat(&leaf);
        const history: [count]NativeNode.Payload.Value = @splat(.none);
        for (std.meta.tags(enum { tables, unions })) |kind| {
            const value: NativeNode = switch (kind) {
                .tables => .{ .children = &children },
                .unions => .{ .history = &history },
            };
            for ([_]bool{ false, true }) |force_defaults| {
                var roomy: [8192]u8 align(runtime.storage_alignment) = undefined;
                const expected = try NativeNode.Schema.serialize(value, &roomy, .{
                    .force_defaults = force_defaults,
                });
                const capacity = std.mem.alignForward(
                    usize,
                    expected.len,
                    runtime.storage_alignment,
                );
                var exact: [8192]u8 align(runtime.storage_alignment) = undefined;
                const bytes = try NativeNode.Schema.serialize(value, exact[0..capacity], .{
                    .force_defaults = force_defaults,
                });
                try testing.expectEqualSlices(u8, expected, bytes);
                try NativeNode.Schema.verify(bytes, .{});
            }
        }
    }
}

test "allocating serialization owns one aligned buffer and preserves runtime vector bytes" {
    var label = "sensor".*;
    label[0] = 'S';
    const numbers = [_]u64{ 0, 0x0102030405060708, 9 };
    const items: [3]structs.Envelope = @splat(structs.envelope);
    for (0..numbers.len + 1) |count| {
        const tags = [_][]const u8{ label[0..count], "" };
        const value: Values = .{
            .label = label[0..count],
            .numbers = numbers[0..count],
            .tags = &tags,
            .items = items[0..count],
            .optional = 0,
        };
        for ([_]bool{ false, true }) |force_defaults| {
            var counted = testing.FailingAllocator.init(testing.allocator, .{});
            const allocator = counted.allocator();
            {
                const options: runtime.WriteOptions = .{ .force_defaults = force_defaults };
                const result: runtime.Serialized = try Definition.serialize(
                    value,
                    allocator,
                    options,
                );
                defer result.deinit(allocator);
                try testing.expectEqual(@as(usize, 1), counted.allocations);
                try testing.expectEqual(@as(usize, 0), counted.resize_index);
                try testing.expect(
                    @intFromPtr(result.storage.ptr) % runtime.storage_alignment == 0,
                );
                try testing.expect(result.storage.len % runtime.storage_alignment == 0);
                try testing.expect(result.bytes.len <= result.storage.len);
                const start = result.storage.len - result.bytes.len;
                try testing.expect(result.bytes.ptr == result.storage[start..].ptr);
                var storage: [1024]u8 align(runtime.storage_alignment) = undefined;
                const expected = try Definition.serialize(value, &storage, options);
                try testing.expectEqualSlices(u8, expected, result.bytes);
                try Definition.verify(result.bytes, .{});
                const view = try Definition.read(result.bytes);
                try testing.expectEqualStrings(label[0..count], view.label.?);
                try testing.expectEqual(count, view.numbers.?.element_count);
                try testing.expectEqual(count, view.items.?.element_count);
                try testing.expectEqualStrings("", try view.tags.?.get(1));
                try testing.expectEqual(@as(?u32, 0), view.optional);
            }
            try testing.expectEqual(@as(usize, 1), counted.deallocations);
            try testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
        }
    }
    const inline_value: structs.Packet = .{ .envelope = structs.envelope, .extra = structs.sample };
    const inline_result = try structs.Packet.Schema.serialize(
        inline_value,
        testing.allocator,
        .{},
    );
    defer inline_result.deinit(testing.allocator);
    try structs.Packet.Schema.verify(inline_result.bytes, .{});
}

fn serializeAllocatedGraph(allocator: std.mem.Allocator, label: []const u8) !void {
    const leaf: NativeNode = .{ .label = label };
    const parent: NativeNode = .{
        .children = &.{ &leaf, &leaf },
        .history = &.{ .{ .child = &leaf }, .{ .text = label }, .none },
    };
    const root: NativeNode = .{
        .label = label,
        .children = &.{ &parent, &parent },
        .payload = .{ .child = &leaf },
        .history = &.{ .{ .envelope = structs.envelope }, .{ .text = label }, .none },
    };
    const result = try NativeNode.Schema.serialize(root, allocator, .{});
    defer result.deinit(allocator);
    var storage: [4096]u8 align(runtime.storage_alignment) = undefined;
    const expected = try NativeNode.Schema.serialize(root, &storage, .{});
    try testing.expectEqualSlices(u8, expected, result.bytes);
    try NativeNode.Schema.verify(result.bytes, .{});
    const view = try NativeNode.Schema.read(result.bytes);
    const first = try view.children.?.get(0);
    const second = try view.children.?.get(1);
    try testing.expect(first.layout.table_start != second.layout.table_start);
    const branch = try NativeNode.Schema.read(first);
    const first_leaf = try branch.children.?.get(0);
    const second_leaf = try branch.children.?.get(1);
    try testing.expect(first_leaf.layout.table_start != second_leaf.layout.table_start);
    try testing.expectEqualStrings(label, (try NativeNode.Schema.read(view.payload.child)).label.?);
    try testing.expectEqualStrings(label, (try branch.history.?.get(1)).text);
    try testing.expectEqualDeep(structs.envelope, try (try view.history.?.get(0)).envelope.read());
    try testing.expect(try view.history.?.get(2) == .none);
}

test "allocating serialization packs recursive native graphs and handles allocation failure" {
    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    try serializeAllocatedGraph(counted.allocator(), "runtime graph");
    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(@as(usize, 1), counted.deallocations);
    try testing.expectEqual(@as(usize, 0), counted.resize_index);
    try testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
    try testing.checkAllAllocationFailures(testing.allocator, serializeAllocatedGraph, .{"graph"});
}

test "allocating serialization bounds preflight and frees storage on packing errors" {
    const Empty = runtime.Schema(struct {}, .{});
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    try testing.expectError(error.DepthLimit, Empty.serialize(.{}, allocator, .{
        .max_depth = 0,
    }));
    try testing.expectError(error.WorkLimit, Empty.serialize(.{}, allocator, .{
        .max_work = 0,
    }));
    try testing.expectError(
        error.MissingRequiredField,
        graph.Node.Schema.serialize(.{}, allocator, .{}),
    );
    var cyclic: NativeNode = .{};
    cyclic.payload = .{ .child = &cyclic };
    try testing.expectError(
        error.DepthLimit,
        NativeNode.Schema.serialize(cyclic, allocator, .{}),
    );
    try testing.expectError(error.WorkLimit, NativeNode.Schema.serialize(cyclic, allocator, .{
        .max_work = 5,
    }));
    try testing.expect(!failing.has_induced_failure);
    try testing.expectError(error.OutOfMemory, Empty.serialize(.{}, allocator, .{}));
    try testing.expect(failing.has_induced_failure);
    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    const invalid: NativeNode = .{
        .history = &.{ .{ .text = "earlier child" }, .{ .text = "\xff" } },
    };
    try testing.expectError(
        error.InvalidUtf8,
        NativeNode.Schema.serialize(invalid, counted.allocator(), .{}),
    );
    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(@as(usize, 1), counted.deallocations);
    try testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}
