const std = @import("std");
const runtime = @import("runtime");
const fixtures = @import("test_schema.zig");

const testing = std.testing;
const Storage = [fixtures.storage_capacity]u8;

const required_fields = .{ .label, .samples, .tags };

const RequiredPayload = struct {
    marker: u32 = 0,
    label: ?[]const u8 = null,
    samples: ?[]const u16 = null,
    tags: ?[]const []const u8 = null,
    optional_label: ?[]const u8 = null,

    pub const Schema = runtime.Schema(@This(), .{
        .marker = runtime.ScalarField(u32, 0, 0),
        .label = runtime.ReferenceField(3, .string, .{ .required = true }),
        .samples = runtime.ReferenceField(
            7,
            .{ .vector = runtime.ScalarCodec(u16) },
            .{ .required = true },
        ),
        .tags = runtime.ReferenceField(
            1,
            .{ .vector = runtime.StringCodec },
            .{ .required = true },
        ),
        .optional_label = runtime.ReferenceField(8, .string, .{}),
    });
};

test "required native references fail before any payload construction" {
    inline for (required_fields) |field| {
        var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
        var builder = runtime.Builder.init(&storage);
        var values: RequiredPayload = .{
            .marker = 123,
            .label = "payload",
            .samples = &.{ 1, 2 },
            .tags = &.{"tag"},
            .optional_label = "optional",
        };
        @field(values, @tagName(field)) = null;
        const before_storage = storage;
        const before_builder = builder;
        try testing.expectError(
            error.MissingRequiredField,
            RequiredPayload.Schema.create(&builder, values, .{}),
        );
        try testing.expectEqualSlices(u8, &before_storage, &storage);
        try testing.expectEqualDeep(before_builder, builder);
    }
}

test "empty required sequences are present and optional references may be absent" {
    var storage: Storage align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    const bytes = try builder.finish(try RequiredPayload.Schema.create(
        &builder,
        .{ .label = "", .samples = &.{}, .tags = &.{} },
        .{},
    ), .ordinary);
    try runtime.Verifier.verify(RequiredPayload, bytes, .{});
    const values = try RequiredPayload.Schema.read(
        try runtime.Table.from(bytes, .root),
    );
    try testing.expectEqualStrings("", values.label.?);
    try testing.expectEqual(@as(usize, 0), values.samples.?.element_count);
    try testing.expectEqual(@as(usize, 0), values.tags.?.element_count);
    try testing.expect(values.optional_label == null);
}

test "required handle preflight leaves table fields and storage unchanged" {
    var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
    var builder = runtime.Builder.init(&storage);
    const fields: RequiredPayload.Schema.Fields = .{
        .marker = 123,
        .label = try builder.createString(""),
        .samples = try builder.createVector(u16, &.{}),
        .tags = try builder.createStringVector(&.{}),
    };
    var context = try RequiredPayload.Schema.Context.init(&builder);
    inline for (required_fields) |field| {
        var missing_fields = fields;
        @field(missing_fields, @tagName(field)) = null;
        const before_storage = storage;
        const before_builder = builder;
        const before_fields = context.field_offsets;
        try testing.expectError(
            error.MissingRequiredField,
            RequiredPayload.Schema.addFields(&context, missing_fields),
        );
        try testing.expectEqualSlices(u8, &before_storage, &storage);
        try testing.expectEqualDeep(before_builder, builder);
        try testing.expectEqualDeep(before_fields, context.field_offsets);
    }
    // Named completed handles determine required presence independently of wire IDs.
    try RequiredPayload.Schema.addFields(&context, fields);
    const bytes = try builder.finish(
        try RequiredPayload.Schema.endTable(&context),
        .ordinary,
    );
    try runtime.Verifier.verify(RequiredPayload, bytes, .{});
    try testing.expectEqual(
        @as(u32, 123),
        (try RequiredPayload.Schema.read(
            try runtime.Table.from(bytes, .root),
        )).marker,
    );
}

test "incremental required finalization can fail without writes and retry" {
    inline for (required_fields) |missing_field| {
        var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
        var builder = runtime.Builder.init(&storage);
        const fields: RequiredPayload.Schema.Fields = .{
            .label = try builder.createString(""),
            .samples = try builder.createVector(u16, &.{}),
            .tags = try builder.createStringVector(&.{}),
        };
        var context = try RequiredPayload.Schema.Context.init(&builder);
        try context.addScalar(u32, 0, 123, 0);
        inline for (required_fields) |field| {
            if (field != missing_field) {
                const field_id = RequiredPayload.Schema.Descriptor(field).wire_id;
                try context.addOffset(field_id, @field(fields, @tagName(field)));
            }
        }
        const before_storage = storage;
        const before_builder = builder;
        const before_fields = context.field_offsets;
        try testing.expectError(
            error.MissingRequiredField,
            RequiredPayload.Schema.endTable(&context),
        );
        try testing.expectEqualSlices(u8, &before_storage, &storage);
        try testing.expectEqualDeep(before_builder, builder);
        try testing.expectEqualDeep(before_fields, context.field_offsets);
        const missing_id = RequiredPayload.Schema.Descriptor(
            missing_field,
        ).wire_id;
        try context.addOffset(missing_id, @field(fields, @tagName(missing_field)));
        const bytes = try builder.finish(
            try RequiredPayload.Schema.endTable(&context),
            .ordinary,
        );
        try runtime.Verifier.verify(RequiredPayload, bytes, .{});
        try testing.expectError(
            error.InvalidState,
            RequiredPayload.Schema.endTable(&context),
        );
        builder.reset();
        _ = try RequiredPayload.Schema.Context.init(&builder);
        try testing.expectError(
            error.InvalidState,
            RequiredPayload.Schema.endTable(&context),
        );
    }
}

test "explicit omission of a required reference fails schema finalization" {
    var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
    var builder = runtime.Builder.init(&storage);
    var context = try fixtures.Node.Schema.Context.init(&builder);
    try context.addOffset(fixtures.Node.fields.name.wire_id, null);
    const before_storage = storage;
    const before_builder = builder;
    try testing.expectError(
        error.MissingRequiredField,
        fixtures.Node.Schema.endTable(&context),
    );
    try testing.expectEqualSlices(u8, &before_storage, &storage);
    try testing.expectEqualDeep(before_builder, builder);
    // Raw construction remains available for schema-agnostic buffers/fixtures.
    const bytes = try builder.finish(try context.endTable(), .ordinary);
    try testing.expectError(
        error.MissingRequiredField,
        runtime.Verifier.verify(fixtures.Node, bytes, .{}),
    );
}

test "required nested-table handles fail preflight and incremental finalization" {
    var storage: Storage align(runtime.storage_alignment) = @splat(0xa5);
    var builder = runtime.Builder.init(&storage);
    const child_name = try builder.createString("child");
    var child = try fixtures.Node.Schema.Context.init(&builder);
    try child.addOffset(fixtures.Node.fields.name.wire_id, child_name);
    const child_handle = try fixtures.Node.Schema.endTable(&child);
    var context = try fixtures.Graph.Schema.Context.init(&builder);
    const before_storage = storage;
    const before_builder = builder;
    const before_fields = context.field_offsets;
    try testing.expectError(
        error.MissingRequiredField,
        fixtures.Graph.Schema.addFields(&context, .{ .revision = 123 }),
    );
    try testing.expectError(
        error.MissingRequiredField,
        fixtures.Graph.Schema.endTable(&context),
    );
    try testing.expectEqualSlices(u8, &before_storage, &storage);
    try testing.expectEqualDeep(before_builder, builder);
    try testing.expectEqualDeep(before_fields, context.field_offsets);
    try context.addOffset(fixtures.Graph.fields.child.wire_id, child_handle);
    const bytes = try builder.finish(
        try fixtures.Graph.Schema.endTable(&context),
        .ordinary,
    );
    try runtime.Verifier.verify(fixtures.Graph, bytes, .{});
}
