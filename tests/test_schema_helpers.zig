//! Shared helpers are exercised independently of generated convenience methods.
const standard_library = @import("std");
const runtime = @import("runtime");
const structs = @import("test_struct_schema.zig");
const unions = @import("test_union_schema.zig");
const graph = @import("test_schema.zig");
const testing = standard_library.testing;

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
    .items = runtime.ReferenceField(13, .{ .vector = runtime.StructCodec(structs.Envelope.Layout) }, .{}),
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
    const omitted = try Definition.writeRoot(&storage.buffer, .{}, .{});
    try testing.expect(!(try Definition.readRoot(omitted)).enabled);
    try testing.expect(!try Definition.updateRoot(omitted, .enabled, true));
    try testing.expect((try Definition.readRoot(omitted)).optional == null);
    try testing.expect(try Definition.borrowMutable(try runtime.MutableTable.from(omitted, .root), .items) == null);
    const present = try Definition.writeRoot(
        &storage.buffer,
        .{ .optional = 0 },
        .{ .force_defaults = true },
    );
    try testing.expectEqual(@as(?u32, 0), (try Definition.readRoot(present)).optional);
    try testing.expect(try Definition.updateRoot(present, .enabled, true));
    try testing.expect((try Definition.readRoot(present)).enabled);
    try testing.expectError(error.CannotClearField, Definition.updateRoot(present, .optional, null));
    try Definition.verifyRoot(present, .{});
    try testing.expectError(error.DepthLimit, Definition.verifyRoot(present, .{ .max_depth = 0 }));
    try testing.expectError(error.WorkLimit, Definition.verifyRoot(present, .{ .max_work = 0 }));
    try testing.expectError(error.OutOfBounds, Definition.readRoot(&.{}));
    var empty: [0]u8 = .{};
    try testing.expectError(error.OutOfBounds, Definition.updateRoot(&empty, .enabled, true));
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
                builder.force_defaults = true;
                const bytes = try builder.finish(try Definition.create(&builder, .{
                    .label = label,
                    .numbers = &numbers,
                    .tags = &tags,
                    .items = &items,
                    .optional = 0,
                }), frame[0]);
                try Definition.verifyRoot(bytes, .{ .frame = frame[1] });
                const view = try Definition.read(try runtime.Table.from(bytes, .{ .framed_root = frame[1] }));
                try testing.expectEqualStrings(label, view.label.?);
                try testing.expectEqual(element_count, view.numbers.?.element_count);
                try testing.expectEqual(element_count, view.items.?.element_count);
                for (tags, 0..) |tag, element_index|
                    try testing.expectEqualStrings(tag, try view.tags.?.get(element_index));
                const table = try runtime.MutableTable.from(bytes, .{ .framed_root = frame[1] });
                const borrowed = (try Definition.borrowMutable(table, .items)).?;
                const scalar_vector = (try Definition.borrowMutable(table, .numbers)).?;
                if (element_count != 0) {
                    try testing.expectEqual(numbers[0], try scalar_vector.get(0));
                    try (try borrowed.get(0)).update(.measure, 12.5);
                    try testing.expectEqual(@as(f64, 12.5), try (try view.items.?.get(0)).get(.measure));
                }
            }
        }
    }
}

test "zero budgets retain empty sequences and empty schemas" {
    var storage: runtime.Storage(Definition, .{}, .{}) = .{};
    const bytes = try Definition.writeRoot(&storage.buffer, .{
        .label = "",
        .numbers = &.{},
        .tags = &.{},
        .items = &.{},
    }, .{});
    try Definition.verifyRoot(bytes, .{});
    const view = try Definition.readRoot(bytes);
    try testing.expectEqualStrings("", view.label.?);
    try testing.expectEqual(@as(usize, 0), view.tags.?.element_count);
    const Empty = runtime.Schema(struct {}, .{});
    var empty_storage: runtime.Storage(Empty, .{}, .{}) = .{};
    try Empty.verifyRoot(try Empty.writeRoot(&empty_storage.buffer, .{}, .{}), .{});
}

test "storage budgets include union pairs vectors and explicitly built children" {
    inline for (frames) |frame| {
        var storage: runtime.Storage(unions.Packet.Schema, .{
            .current = runtime.storage.capacity(unions.Event.Schema, .{ .name = unions.label.len }, .{}),
            .required_value = structs.Envelope.Layout.wire_size + structs.Envelope.Layout.wire_alignment - 1,
            .history = .{ .count = 5, .bytes = 4 + unions.message.len + 1 + 3 },
        }, .{ .finish = frame[0] }) = .{};
        const bytes = try unions.build(&storage.buffer, frame[0]);
        try unions.Packet.Schema.verifyRoot(bytes, .{ .frame = frame[1] });
        const table = try runtime.MutableTable.from(bytes, .{ .framed_root = frame[1] });
        const current = try unions.Packet.Schema.borrowMutable(table, .current);
        try testing.expect(try current.event.mutateField(u64, 0, 99));
        const history = (try unions.Packet.Schema.borrowMutable(table, .history)).?;
        try (try history.get(2)).envelope.update(.measure, 25.5);
        const envelope = try unions.Packet.Schema.borrowMutable(table, .required_value);
        try testing.expectEqual(@as(f64, 25.5), try envelope.envelope.get(.measure));
        const view = try unions.Packet.Schema.read(try runtime.Table.from(bytes, .{ .framed_root = frame[1] }));
        try testing.expectEqual(@as(u64, 99), (try unions.Event.Schema.read((try view.history.?.get(4)).again)).number);
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
