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
    try testing.expect(!(try Definition.readRoot(omitted)).enabled);
    try testing.expect(!try Definition.updateRoot(omitted, .enabled, true));
    try testing.expect((try Definition.readRoot(omitted)).optional == null);
    try testing.expect(try Definition.borrowMutable(
        try runtime.MutableTable.from(omitted, .root),
        .items,
    ) == null);
    const present = try Definition.serialize(
        .{ .optional = 0 },
        &storage.buffer,
        .{ .force_defaults = true },
    );
    try testing.expectEqual(@as(?u32, 0), (try Definition.readRoot(present)).optional);
    try testing.expect(try Definition.updateRoot(present, .enabled, true));
    try testing.expect((try Definition.readRoot(present)).enabled);
    try testing.expectError(
        error.CannotClearField,
        Definition.updateRoot(present, .optional, null),
    );
    try Definition.verifyRoot(present, .{});
    try testing.expectError(error.DepthLimit, Definition.verifyRoot(present, .{ .max_depth = 0 }));
    try testing.expectError(error.WorkLimit, Definition.verifyRoot(present, .{ .max_work = 0 }));
    try testing.expectError(error.OutOfBounds, Definition.readRoot(&.{}));
    var empty: [0]u8 = .{};
    try testing.expectError(error.OutOfBounds, Definition.updateRoot(&empty, .enabled, true));
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
    try Definition.verifyRoot(bytes, .{});
    const view = try Definition.readRoot(bytes);
    try testing.expectEqualStrings("sensor-01", view.label.?);
    try testing.expectEqual(@as(u64, 3), try view.numbers.?.get(2));
    try testing.expectEqual(@as(usize, 0), view.tags.?.element_count);
    try testing.expect(view.items == null);
    try testing.expectEqual(@as(?u32, 0), view.optional);
    try testing.expect(!view.enabled);
    try testing.expect(try Definition.updateRoot(bytes, .enabled, true));
    try testing.expect((try Definition.readRoot(bytes)).enabled);
    try Definition.verifyRoot(bytes, .{});
    var insufficient: [1]u8 align(runtime.storage_alignment) = undefined;
    try testing.expectError(error.NoSpaceLeft, Definition.serialize(value, &insufficient, .{}));
}

test "schema storage bounds sparse fields wide vectors strings and all frames" {
    const tags = [_][]const u8{ "", "é", "abcd" };
    inline for (.{ 0, 1, 3, 17 }) |element_count| {
        const numbers: [element_count]u64 = @splat(0x0102030405060708);
        const items: [element_count]structs.Envelope = @splat(structs.envelope);
        inline for (.{ "", "a", "abcde" }) |label| {
            inline for (frames) |frame| {
                var storage: runtime.Storage(Definition, .{
                    .label = label.len,
                    .numbers = element_count,
                    .tags = .{ .count = tags.len, .bytes = 6 },
                    .items = element_count,
                }, .{ .finish = frame[0] }) = .{};
                var builder = runtime.Builder.init(&storage.buffer);
                const bytes = try builder.finish(try Definition.create(
                    &builder,
                    .{
                        .label = label,
                        .numbers = &numbers,
                        .tags = &tags,
                        .items = &items,
                        .optional = 0,
                    },
                    .{ .force_defaults = true },
                ), frame[0]);
                try Definition.verifyRoot(bytes, .{ .frame = frame[1] });
                const view = try Definition.read(
                    try runtime.Table.from(bytes, .{ .options = frame[1] }),
                );
                try testing.expectEqualStrings(label, view.label.?);
                try testing.expectEqual(element_count, view.numbers.?.element_count);
                try testing.expectEqual(element_count, view.items.?.element_count);
                for (tags, 0..) |tag, element_index|
                    try testing.expectEqualStrings(tag, try view.tags.?.get(element_index));
                const table = try runtime.MutableTable.from(bytes, .{ .options = frame[1] });
                const borrowed = (try Definition.borrowMutable(table, .items)).?;
                const scalar_vector = (try Definition.borrowMutable(table, .numbers)).?;
                if (element_count != 0) {
                    try testing.expectEqual(numbers[0], try scalar_vector.get(0));
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

test "zero budgets retain empty sequences and empty schemas" {
    var storage: runtime.Storage(Definition, .{}, .{}) = .{};
    const bytes = try Definition.serialize(.{
        .label = "",
        .numbers = &.{},
        .tags = &.{},
        .items = &.{},
    }, &storage.buffer, .{});
    try Definition.verifyRoot(bytes, .{});
    const view = try Definition.readRoot(bytes);
    try testing.expectEqualStrings("", view.label.?);
    try testing.expectEqual(@as(usize, 0), view.tags.?.element_count);
    const Empty = runtime.Schema(struct {}, .{});
    var empty_storage: runtime.Storage(Empty, .{}, .{}) = .{};
    try Empty.verifyRoot(try Empty.serialize(.{}, &empty_storage.buffer, .{}), .{});
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
        try unions.Packet.Schema.verifyRoot(bytes, .{ .frame = frame[1] });
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
    const view = try graph.Graph.Schema.readRoot(bytes);
    try testing.expectEqual(@as(u64, 123), (try graph.Node.Schema.read(view.child.?)).number);
    try graph.Graph.Schema.verifyRoot(bytes, .{});
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

test "native recursive vectors retain nested scratch and copy shared pointers" {
    const leaf: NativeNode = .{ .label = "leaf" };
    const parent: NativeNode = .{
        .children = &.{ &leaf, &leaf },
        .history = &.{
            .{ .child = &leaf }, .{ .text = "inner" }, .{ .envelope = structs.envelope },
        },
    };
    const root: NativeNode = .{
        .children = &.{ &parent, &parent },
        .payload = .{ .envelope = structs.envelope },
        .history = &.{ .none, .{ .text = "root" } },
    };
    inline for (frames) |frame| {
        var storage: [4096]u8 align(runtime.storage_alignment) = undefined;
        var builder = runtime.Builder.init(&storage);
        const handle = try NativeNode.Schema.create(&builder, root, .{});
        try testing.expectEqual(@as(usize, 0), builder.scratch_cursor);
        const bytes = try builder.finish(handle, frame[0]);
        try NativeNode.Schema.verifyRoot(bytes, .{ .frame = frame[1] });
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
        try testing.expectEqualStrings("leaf", (try NativeNode.Schema.read(union_leaf)).label.?);
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

test "native serialization bounds root depth work and cyclic inputs before writes" {
    const Empty = runtime.Schema(struct {}, .{});
    var storage: [512]u8 align(runtime.storage_alignment) = @splat(0xa5);
    const before = storage;
    try testing.expectError(error.DepthLimit, Empty.serialize(.{}, &storage, .{ .max_depth = 0 }));
    try testing.expectEqualSlices(u8, &before, &storage);
    try testing.expectError(error.WorkLimit, Empty.serialize(.{}, &storage, .{ .max_work = 0 }));
    try testing.expectEqualSlices(u8, &before, &storage);
    try Empty.verifyRoot(try Empty.serialize(.{}, &storage, .{
        .max_depth = 1,
        .max_work = 1,
    }), .{});
    const Scalar = runtime.Schema(struct { count: u32 = 0 }, .{
        .count = runtime.ScalarField(u32, 0, 0),
    });
    try testing.expectError(error.WorkLimit, Scalar.serialize(.{}, &storage, .{ .max_work = 1 }));
    const bytes = try Scalar.serialize(.{ .count = 42 }, &storage, .{ .max_work = 2 });
    try testing.expectEqual(@as(u32, 42), (try Scalar.readRoot(bytes)).count);
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
    try NativeNode.Schema.verifyRoot(bytes, .{});
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
                try NativeNode.Schema.verifyRoot(bytes, .{});
            }
        }
    }
}
