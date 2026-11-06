//! Runnable example of schema-driven construction and fixed-size mutation.
//! Run `zig build run` here, or `zig build run-builder` from Flatzz.
//! Prints before/after values, encoded bytes, and unions.

const std = @import("std");
const Reading = @import("reading").Reading;
const schema = @import("reading");
const runtime = @import("runtime");

/// Build, verify, and mutate caller-owned buffers, then print decoded results.
/// Construction, checked-access, verification, and stdout errors propagate.
pub fn main(init: std.process.Init) !void {
    const initial_label = "start";
    const initial_samples = [_]f32{ 1, 2, 3 };
    const initial_tags = [_][]const u8{ "lab", "new" };
    const initial_location: @import("reading").Location = .{
        .coordinates = .{ .latitude = 48.5, .longitude = 2.25 },
        .altitude = 35,
    };
    const initial_history = [_]@import("reading").Location{
        initial_location,
        .{ .coordinates = .{ .latitude = 50, .longitude = 4 }, .altitude = 100 },
    };
    var storage: Reading.Storage(initial_label.len, initial_samples.len, .{
        .count = initial_tags.len,
        .bytes = initial_tags[0].len + initial_tags[1].len,
    }, initial_history.len) = .{};
    // Keep default-valued scalar slots available for later mutation.
    // Optional temperature must be present: force_defaults never stores null.
    const bytes = try Reading.write(&storage.buffer, .{
        .label = initial_label,
        .samples = &initial_samples,
        .temperature = 0,
        .tags = &initial_tags,
        .location = initial_location,
        .history = &initial_history,
        .calibration = .{ .gains = .{ 1, 2, 3 }, .locations = initial_history },
    }, .{ .force_defaults = true });
    try Reading.verify(bytes, .{});
    const before = try Reading.read(bytes);
    // read() copies the native value; the borrowed view would observe updates.
    // const location_before = try before.location.?.read();
    const location_before = if (before.location) |location| try location.read() else @panic("No location available");
    if (!try Reading.update(bytes, .sequence, 42)) return error.MissingField;
    if (!try Reading.update(bytes, .value, 1.5)) return error.MissingField;
    if (!try Reading.update(bytes, .label, "ready")) return error.MissingField;
    if (!try Reading.update(bytes, .active, true)) return error.MissingField;
    if (!try Reading.update(bytes, .status, .ok)) return error.MissingField;
    if (!try Reading.update(
        bytes,
        .samples,
        &.{ 1.5, 2.5, 3.5 },
    )) return error.MissingField;
    if (!try Reading.update(
        bytes,
        .temperature,
        25.5,
    )) return error.MissingField;
    if (!try Reading.update(
        bytes,
        .tags,
        &.{ "out", "old" },
    )) return error.MissingField;
    // Whole inline struct replacement through the generated-style schema API.
    if (!try Reading.update(bytes, .location, .{
        .coordinates = .{ .latitude = 49, .longitude = 3 },
        .altitude = 40,
    })) return error.MissingField;
    // Borrow nested struct members without allocating or copying the buffer.
    const location_view = try Reading.mutableLocation(bytes) orelse
        return error.MissingField;
    const coordinates_view = try location_view.get(.coordinates);
    try coordinates_view.update(.latitude, 49.5);
    try location_view.update(.altitude, 42);
    // Struct vectors hold contiguous inline elements, without child offsets.
    const history = (try Reading.mutableHistory(bytes)).?;
    const history_item = try history.get(1);
    try history_item.update(.altitude, 125);
    // Array counts are fixed by the schema; get returns a scalar or struct view.
    const calibration = (try Reading.mutableCalibration(bytes)).?;
    const gains = try calibration.get(.gains);
    try gains.update(1, 2.5);
    const locations = try calibration.get(.locations);
    const calibrated_location = try locations.get(0);
    try calibrated_location.update(.altitude, 36);
    try Reading.verify(bytes, .{});
    const reading = try Reading.read(bytes);

    const output_capacity = 256;
    var output_buffer: [output_capacity]u8 = undefined;
    var stdout = std.Io.File.Writer.init(.stdout(), init.io, &output_buffer);
    const writer = &stdout.interface;
    // `before.label` borrows the mutated bytes, so use the original literal here.
    try writer.print(
        "before: sequence={d}, value={d}, label={s}, active={}, status={}, temperature={?d}\n",
        .{
            before.sequence,
            before.value,
            initial_label,
            before.active,
            before.status,
            before.temperature,
        },
    );
    try writer.print(
        "after: sequence={d}, value={d}, label={s}, active={}, status={}, temperature={?d}\n",
        .{
            reading.sequence,
            reading.value,
            reading.label.?,
            reading.active,
            reading.status,
            reading.temperature,
        },
    );
    const location_after = try reading.location.?.read();
    try writer.print(
        "location before: latitude={d}, longitude={d}, altitude={d}\n" ++
            "location after: latitude={d}, longitude={d}, altitude={d}\n",
        .{
            location_before.coordinates.latitude,
            location_before.coordinates.longitude,
            location_before.altitude,
            location_after.coordinates.latitude,
            location_after.coordinates.longitude,
            location_after.altitude,
        },
    );
    const samples = reading.samples.?;
    const calibration_after = try reading.calibration.?.read();
    try writer.print(
        "history[1].altitude={d}, gains={any}, calibrated altitude={d}\n",
        .{
            try (try reading.history.?.get(1)).get(.altitude),
            calibration_after.gains,
            calibration_after.locations[0].altitude,
        },
    );
    try writer.writeAll("samples:");
    for (0..samples.element_count) |index| try writer.print(
        " {d}",
        .{try samples.get(index)},
    );
    try writer.writeByte('\n');
    const tags = reading.tags.?;
    try writer.writeAll("tags:");
    for (0..tags.element_count) |index| try writer.print(
        " {s}",
        .{try tags.get(index)},
    );
    try writer.writeByte('\n');
    try writer.writeAll("bytes:");
    for (bytes) |byte| try writer.print(" {x:0>2}", .{byte});
    try writer.writeByte('\n');
    try showUnions(writer);
    try writer.flush();
}

fn showUnions(writer: *std.Io.Writer) !void {
    const storage_capacity = 512;
    var storage: [storage_capacity]u8 align(runtime.storage_alignment) = undefined;
    var builder = runtime.Builder.init(&storage);
    const temperature = try schema.Temperature.Schema.create(
        &builder,
        .{ .value = 25.5 },
    );
    // Union structs are separate referenced objects. Ordinary Location fields
    // and struct-vector elements continue to be encoded inline.
    const location = try builder.createStruct(schema.Location.Layout, .{
        .coordinates = .{ .latitude = 48.5, .longitude = 2.25 },
        .altitude = 35,
    });
    const text = try builder.createString("sensor online");
    const root = try schema.ReadingMessage.Schema.create(&builder, .{
        .current = .{ .temperature = temperature },
        .history = &.{
            .{ .temperature = temperature },
            .{ .location = location },
            .{ .text = text },
            .none,
            .{ .previous = location },
        },
    });
    const bytes = try builder.finish(root, .ordinary);
    try runtime.Verifier.verify(schema.ReadingMessage, bytes, .{});
    const message = try schema.ReadingMessage.Schema.read(
        try runtime.Table.from(bytes, .root),
    );
    // Mutate an existing payload; replacing the alternative requires rebuilding.
    const mutable = try runtime.MutableTable.from(bytes, .root);
    const current = try mutable.readUnion(
        schema.ReadingPayload,
        schema.ReadingMessage.Schema.fields.current.field_ids,
    );
    if (!try schema.Temperature.Schema.update(
        current.temperature,
        .value,
        26,
    )) return error.MissingField;
    try runtime.Verifier.verify(schema.ReadingMessage, bytes, .{});
    const history = message.history.?;
    for (0..history.element_count) |element_index| {
        const payload = try history.get(element_index);
        try writer.print("union[{d}] {s}: ", .{
            element_index, @tagName(payload),
        });
        switch (payload) {
            .none => try writer.writeAll("no value\n"),
            .temperature => |table| try writer.print("{d}\n", .{
                (try schema.Temperature.Schema.read(table)).value,
            }),
            .location, .previous => |structure| try writer.print(
                "altitude={d}\n",
                .{try structure.get(.altitude)},
            ),
            .text => |message_text| try writer.print("{s}\n", .{message_text}),
        }
    }
}
