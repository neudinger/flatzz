const std = @import("std");
const runtime = @import("runtime");
const Reading = @import("reading").Reading;

test "string vectors fit schema storage across lengths and alignments" {
    const tags = [_][]const u8{ "", "a", "bc", "def", "é", "a\x00b" };
    const samples = [_]f32{ -1.5, 0, 2.5 };
    const tag_bytes = comptime blk: {
        var total: usize = 0;
        for (tags) |tag| total += tag.len;
        break :blk total;
    };
    inline for (.{ "", "a", "ab", "abc", "abcd", "abcde" }) |label| {
        inline for (0..tags.len + 1) |count| {
            for ([_]bool{ false, true }) |force_defaults| {
                var storage: Reading.Storage(
                    label.len,
                    samples.len,
                    .{ .count = count, .bytes = tag_bytes },
                    0,
                ) = .{};
                const bytes = try Reading.write(&storage.buffer, .{
                    .sequence = 42,
                    .value = 1.5,
                    .label = label,
                    .samples = &samples,
                    .temperature = 0,
                    .tags = tags[0..count],
                }, .{ .force_defaults = force_defaults });
                const view = try Reading.read(bytes);
                try std.testing.expectEqual(@as(u32, 42), view.sequence);
                try std.testing.expectEqual(@as(f32, 1.5), view.value);
                try std.testing.expectEqualStrings(label, view.label.?);
                try std.testing.expectEqual(@as(?f32, 0), view.temperature);
                for (samples, 0..) |sample, index| try std.testing.expectEqual(
                    sample,
                    try view.samples.?.get(index),
                );
                try std.testing.expectEqual(count, view.tags.?.element_count);
                for (tags[0..count], 0..) |tag, index| try std.testing.expectEqualStrings(
                    tag,
                    try view.tags.?.get(index),
                );
                try std.testing.expectError(
                    error.OutOfBounds,
                    view.tags.?.get(count),
                );
                try std.testing.expectError(
                    error.OutOfBounds,
                    view.tags.?.get(std.math.maxInt(usize)),
                );
            }
        }
    }
}

test "absent, empty and older string vector fields remain distinct" {
    var storage: Reading.Storage(0, 0, .{}, 0) = .{};
    for ([_]bool{ false, true }) |force_defaults| {
        const absent = try Reading.write(
            &storage.buffer,
            .{},
            .{ .force_defaults = force_defaults },
        );
        try std.testing.expect((try Reading.read(absent)).tags == null);
        try std.testing.expect(!try Reading.update(absent, .tags, &.{}));
        const empty = try Reading.write(
            &storage.buffer,
            .{ .tags = &.{} },
            .{ .force_defaults = force_defaults },
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            (try Reading.read(empty)).tags.?.element_count,
        );
        try std.testing.expect(try Reading.update(empty, .tags, &.{}));
        try std.testing.expectError(
            error.CannotClearField,
            Reading.update(empty, .tags, null),
        );
    }
    var older = runtime.Builder.init(&storage.buffer);
    var older_table = try runtime.TableBuilder(0).init(&older);
    const bytes = try older.finish(try older_table.endTable(), .ordinary);
    try std.testing.expect((try Reading.read(bytes)).tags == null);
    try std.testing.expect(!try Reading.update(bytes, .tags, &.{"a"}));
}

test "string vector updates validate every replacement before writing" {
    var storage: Reading.Storage(0, 0, .{ .count = 4, .bytes = 9 }, 0) = .{};
    @memset(&storage.buffer, 0);
    const bytes = try Reading.write(
        &storage.buffer,
        .{ .tags = &.{ "red", "blue", "", "é" } },
        .{},
    );
    const view = (try Reading.read(bytes)).tags.?;
    const before = storage.buffer;
    try std.testing.expectError(
        error.LengthMismatch,
        Reading.update(bytes, .tags, &.{ "tan", "cyan", "", "abc" }),
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        Reading.update(bytes, .tags, &.{ "tan", "cyan", "", "\xff\xff" }),
    );
    try std.testing.expectError(
        error.LengthMismatch,
        Reading.update(bytes, .tags, &.{ "tan", "cyan" }),
    );
    try std.testing.expectError(
        error.CannotClearField,
        Reading.update(bytes, .tags, null),
    );
    const borrowed = [_][]const u8{ try view.get(0), "cyan", "", "à" };
    try std.testing.expectError(
        error.AliasedInput,
        Reading.update(bytes, .tags, &borrowed),
    );
    try std.testing.expectEqualSlices(u8, &before, &storage.buffer);
    const replacement = [_][]const u8{ "tan", "cyan", "", "à" };
    try std.testing.expect(try Reading.update(bytes, .tags, &replacement));
    for (replacement, 0..) |tag, index| try std.testing.expectEqualStrings(
        tag,
        try view.get(index),
    );
}

// Corrupt wire metadata independently of the runtime being tested.
fn putOffset(bytes: []u8, pos: usize, value: u32) void {
    std.mem.writeInt(
        u32,
        bytes[pos..][0..runtime.field_offset_size],
        value,
        .little,
    );
}

test "string vector elements reject malformed offsets, lengths and UTF-8" {
    var storage: Reading.Storage(0, 0, .{ .count = 3, .bytes = 9 }, 0) = .{};
    @memset(&storage.buffer, 0);
    const bytes = try Reading.write(
        &storage.buffer,
        .{ .tags = &.{ "abc", "def", "ghi" } },
        .{},
    );
    const view = (try Reading.read(bytes)).tags.?;
    const first = try view.get(0);
    const first_pos = @intFromPtr(first.ptr) - @intFromPtr(bytes.ptr);
    const valid = storage.buffer;
    for ([_]u32{ 0, 1 }) |offset| {
        putOffset(bytes, view.payload_start, offset);
        try std.testing.expectError(error.InvalidBuffer, view.get(0));
    }
    putOffset(bytes, view.payload_start, std.math.maxInt(u32));
    try std.testing.expectError(error.OutOfBounds, view.get(0));
    storage.buffer = valid;
    // A plausible empty string embedded in the offset array is still invalid.
    putOffset(bytes, view.payload_start, runtime.field_offset_size);
    putOffset(bytes, view.payload_start + runtime.field_offset_size, 0);
    putOffset(bytes, view.payload_start + runtime.field_offset_size * 2, 0);
    try std.testing.expectError(error.InvalidBuffer, view.get(0));
    storage.buffer = valid;
    putOffset(
        bytes,
        first_pos - runtime.sequence_length_size,
        std.math.maxInt(u32),
    );
    try std.testing.expectError(error.OutOfBounds, view.get(0));
    storage.buffer = valid;
    bytes[first_pos + first.len] = 1;
    try std.testing.expectError(error.InvalidBuffer, view.get(0));
    storage.buffer = valid;
    bytes[first_pos] = 0xff;
    try std.testing.expectError(error.InvalidBuffer, view.get(0));
    storage.buffer = valid;
    // Invalid later elements must not permit a partial update of earlier ones.
    putOffset(bytes, view.payload_start + runtime.field_offset_size, 0);
    const corrupt = storage.buffer;
    try std.testing.expectError(
        error.InvalidBuffer,
        Reading.update(bytes, .tags, &.{ "xyz", "uvw", "rst" }),
    );
    try std.testing.expectEqualSlices(u8, &corrupt, &storage.buffer);
    storage.buffer = valid;
    var truncated = view;
    truncated.bytes = bytes[0 .. bytes.len - runtime.string_terminator_size];
    try std.testing.expectError(error.OutOfBounds, truncated.get(0));
}

test "shared strings permit consistent updates and reject conflicting replacements" {
    var storage: Reading.Storage(0, 0, .{ .count = 2, .bytes = 6 }, 0) = .{};
    @memset(&storage.buffer, 0);
    const bytes = try Reading.write(
        &storage.buffer,
        .{ .tags = &.{ "one", "two" } },
        .{},
    );
    const view = (try Reading.read(bytes)).tags.?;
    const first = try view.get(0);
    const target = @intFromPtr(
        first.ptr,
    ) - @intFromPtr(bytes.ptr) - runtime.sequence_length_size;
    const second_slot = view.payload_start + runtime.field_offset_size;
    putOffset(bytes, second_slot, @intCast(target - second_slot));
    try std.testing.expectEqualStrings("one", try view.get(1));
    const before = storage.buffer;
    try std.testing.expectError(
        error.ConflictingAlias,
        Reading.update(bytes, .tags, &.{ "abc", "xyz" }),
    );
    try std.testing.expectEqualSlices(u8, &before, &storage.buffer);
    try std.testing.expect(
        try Reading.update(bytes, .tags, &.{ "new", "new" }),
    );
    try std.testing.expectEqualStrings("new", try view.get(0));
    try std.testing.expectEqualStrings("new", try view.get(1));
}

test "string vector construction failures leave the builder and storage unchanged" {
    var storage: Reading.Storage(0, 0, .{ .count = 2, .bytes = 6 }, 0) = .{};
    @memset(&storage.buffer, 0);
    var builder = runtime.Builder.init(&storage.buffer);
    const before = storage.buffer;
    const head = builder.write_cursor;
    try std.testing.expectError(
        error.InvalidUtf8,
        builder.createStringVector(&.{ "abc", "\xff" }),
    );
    try std.testing.expectError(
        error.AliasedInput,
        builder.createStringVector(&.{storage.buffer[0..3]}),
    );
    try std.testing.expectEqual(head, builder.write_cursor);
    try std.testing.expectEqualSlices(u8, &before, &storage.buffer);
    const descriptors: *[2][]const u8 = @ptrCast(&storage.buffer);
    descriptors.* = .{ "abc", "def" };
    const descriptor_bytes = storage.buffer;
    try std.testing.expectError(
        error.AliasedInput,
        builder.createStringVector(descriptors),
    );
    try std.testing.expectEqual(head, builder.write_cursor);
    try std.testing.expectEqualSlices(u8, &descriptor_bytes, &storage.buffer);
    // A string fits on its own, but the complete vector does not.
    var small: [runtime.storage_alignment]u8 align(runtime.storage_alignment) = @splat(
        0,
    );
    var limited = runtime.Builder.init(&small);
    const small_before = small;
    try std.testing.expectError(
        error.NoSpaceLeft,
        limited.createStringVector(&.{"abc"}),
    );
    try std.testing.expectEqual(small.len, limited.write_cursor);
    try std.testing.expectEqualSlices(u8, &small_before, &small);
    _ = try runtime.TableBuilder(1).init(&builder);
    try std.testing.expectError(
        error.InvalidState,
        builder.createStringVector(&.{}),
    );
}

test "partially overlapping string objects cannot be mutated" {
    const outer_length = 4 * runtime.sequence_length_size;
    const outer: [outer_length]u8 = @splat(0);
    var storage: Reading.Storage(
        0,
        0,
        .{ .count = 2, .bytes = outer_length },
        0,
    ) = .{};
    @memset(&storage.buffer, 0);
    const bytes = try Reading.write(
        &storage.buffer,
        .{ .tags = &.{ &outer, "" } },
        .{},
    );
    const view = (try Reading.read(bytes)).tags.?;
    const target = try view.get(0);
    const pos = @intFromPtr(target.ptr) - @intFromPtr(bytes.ptr);
    // Embed a valid string header/payload inside the first string's UTF-8 bytes.
    putOffset(bytes, pos, runtime.sequence_length_size);
    const second_slot = view.payload_start + runtime.field_offset_size;
    putOffset(bytes, second_slot, @intCast(pos - second_slot));
    try std.testing.expectEqual(
        @as(usize, runtime.sequence_length_size),
        (try view.get(1)).len,
    );
    const before = storage.buffer;
    const replacement: [outer_length]u8 = @splat('a');
    try std.testing.expectError(
        error.InvalidBuffer,
        Reading.update(bytes, .tags, &.{ &replacement, "abcd" }),
    );
    try std.testing.expectEqualSlices(u8, &before, &storage.buffer);
}

test "string vectors coexist with wide scalar vectors and optional fields" {
    const wide = [_]u64{ 0x0102030405060708, std.math.maxInt(u64) };
    var storage: Reading.Storage(
        0,
        wide.len * 2,
        .{ .count = 2, .bytes = 7 },
        0,
    ) = .{};
    var builder = runtime.Builder.init(&storage.buffer);
    const numbers = try builder.createVector(u64, &wide);
    const strings = try builder.createStringVector(&.{ "", "1234567" });
    var table = try runtime.TableBuilder(3).init(&builder);
    try table.addOffset(0, numbers);
    try table.addOffset(1, strings);
    try table.addScalar(?bool, 2, false, null);
    const bytes = try builder.finish(try table.endTable(), .ordinary);
    const table_view = try runtime.Table.from(bytes, .root);
    const vector = (try table_view.readVector(runtime.ScalarCodec(u64), 0)).?;
    for (wide, 0..) |value, index| try std.testing.expectEqual(
        value,
        try vector.get(index),
    );
    const tags = (try table_view.readVector(runtime.StringCodec, 1)).?;
    try std.testing.expectEqualStrings("", try tags.get(0));
    try std.testing.expectEqualStrings("1234567", try tags.get(1));
    try std.testing.expectEqual(
        @as(?bool, false),
        try table_view.readField(?bool, 2, null),
    );
}
