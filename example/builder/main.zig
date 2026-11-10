//! Runnable example of schema-driven construction and fixed-size mutation.
//! Run `zig build run` here, or `zig build run-builder` from Flatzz.
//! Prints before/after values, encoded bytes, and unions.

const std = @import("std");
const runtime = @import("runtime");
const reading = @import("reading");

// flatzz runtime module
const Builder = runtime.Builder;
const Table = runtime.Table;
const MutableTable = runtime.MutableTable;

// Reading schema module
const Reading = reading.Reading;
const Location = reading.Location;
const Calibration = reading.Calibration;
const Temperature = reading.Temperature;
const ReadingMessage = reading.ReadingMessage;
const ReadingPayload = reading.ReadingPayload;

/// Build, verify, and mutate caller-owned buffers, then print decoded results.
/// Construction, checked-access, verification, and stdout errors propagate.
pub fn main(init: std.process.Init) !void {
    const initial_label = "start";
    const initial_samples = [_]f32{ 1, 2, 3 };
    const initial_tags = [_][]const u8{ "lab", "new" };
    const initial_location: Location = .{
        .coordinates = .{ .latitude = 48.5, .longitude = 2.25 },
        .altitude = 35,
    };
    const initial_history = [_]Location{
        initial_location,
        .{ .coordinates = .{ .latitude = 50, .longitude = 4 }, .altitude = 100 },
    };
    // Keep default-valued scalar slots available for later mutation.
    // Optional temperature must be present: force_defaults never stores null.
    const value: Reading = .{
        .label = initial_label,
        .samples = &initial_samples,
        .temperature = 0,
        .tags = &initial_tags,
        .location = initial_location,
        .history = &initial_history,
        .calibration = .{ .gains = .{ 1, 2, 3 }, .locations = initial_history },
    };
    const capacity = comptime runtime.storage.capacityFor(Reading.Schema, value, .{});
    var storage: [capacity]u8 align(runtime.storage_alignment) = undefined;
    const bytes = try value.serialize(&storage, .{ .force_defaults = true });
    try Reading.verify(bytes, .{});
    const before = try Reading.read(bytes);
    // read() copies the native value; the borrowed view would observe updates.
    const location_before = try (before.location orelse @panic("No location available")).read();
    // Byte inputs open the root internally.
    if (!try Reading.update(bytes, .sequence, 42)) return error.MissingField;
    if (!try Reading.update(bytes, .value, 1.5)) return error.MissingField;
    if (!try Reading.update(bytes, .label, "ready")) return error.MissingField;
    if (!try Reading.update(bytes, .active, true)) return error.MissingField;
    // Reuse a checked table for the remaining updates and borrowed views.
    const table = try MutableTable.from(bytes, .root);
    if (!try Reading.update(table, .status, .ok)) return error.MissingField;
    if (!try Reading.update(table, .samples, &.{ 1.5, 2.5, 3.5 })) return error.MissingField;
    if (!try Reading.update(table, .temperature, 25.5)) return error.MissingField;
    if (!try Reading.update(table, .tags, &.{ "out", "old" })) return error.MissingField;
    // Whole inline struct replacement through the generated-style schema API.
    if (!try Reading.update(table, .location, .{
        .coordinates = .{ .latitude = 49, .longitude = 3 },
        .altitude = 40,
    })) return error.MissingField;
    // Borrow a nested struct directly from bytes without allocation or copying.
    // The vector and array borrows below reuse the checked table.
    const location_view = try Reading.borrowMutable(bytes, .location) orelse
        return error.MissingField;
    const coordinates_view = try location_view.get(.coordinates);
    try coordinates_view.update(.latitude, 49.5);
    try location_view.update(.altitude, 42);
    // Struct vectors hold contiguous inline elements, without child offsets.
    const history = (try Reading.borrowMutable(table, .history)).?;
    const history_item = try history.get(1);
    try history_item.update(.altitude, 125);
    // Array counts are fixed by the schema; get returns a scalar or struct view.
    const calibration = (try Reading.borrowMutable(table, .calibration)).?;
    const gains = try calibration.get(.gains);
    try gains.update(1, 2.5);
    const locations = try calibration.get(.locations);
    const calibrated_location = try locations.get(0);
    try calibrated_location.update(.altitude, 36);
    try Reading.verify(bytes, .{});
    const after = try Reading.read(bytes);

    var stdout: std.Io.Writer.Allocating = .init(init.gpa);
    defer stdout.deinit();
    const writer = &stdout.writer;
    // `before.label` borrows the mutated bytes, so use the original literal here.
    try writer.print(
        "before: sequence={d}, value={d}, label={s}, active={}, status={}, temperature={?d}\n",
        .{
            before.sequence, before.value,  initial_label,
            before.active,   before.status, before.temperature,
        },
    );
    try writer.print(
        "after: sequence={d}, value={d}, label={s}, active={}, status={}, temperature={?d}\n",
        .{
            after.sequence, after.value,  after.label.?,
            after.active,   after.status, after.temperature,
        },
    );
    const location_after = try after.location.?.read();
    try writer.print(
        "location before: latitude={d}, longitude={d}, altitude={d}\n" ++
            "location after: latitude={d}, longitude={d}, altitude={d}\n",
        .{
            location_before.coordinates.latitude, location_before.coordinates.longitude,
            location_before.altitude,             location_after.coordinates.latitude,
            location_after.coordinates.longitude, location_after.altitude,
        },
    );
    const samples = after.samples.?;
    const calibration_after: Calibration = try after.calibration.?.read();
    try writer.print(
        "history[1].altitude={d}, gains={any}, calibrated altitude={d}\n",
        .{
            try (try after.history.?.get(1)).get(.altitude),
            calibration_after.gains,
            calibration_after.locations[0].altitude,
        },
    );
    try writer.writeAll("samples:");
    for (0..samples.element_count) |index| try writer.print(" {d}", .{try samples.get(index)});
    try writer.writeByte('\n');
    const tags = after.tags.?;
    try writer.writeAll("tags:");
    for (0..tags.element_count) |index| try writer.print(" {s}", .{try tags.get(index)});
    try writer.writeByte('\n');
    try writer.writeAll("bytes:");
    for (bytes) |byte| try writer.print(" {x:0>2}", .{byte});
    try writer.writeByte('\n');
    try showUnions(writer);
    try std.Io.File.stdout().writeStreamingAll(init.io, stdout.written());
}

fn showUnions(writer: *std.Io.Writer) !void {
    const temperature_value: Temperature = .{ .value = 25.5 };
    const location_value: Location = .{
        .coordinates = .{ .latitude = 48.5, .longitude = 2.25 },
        .altitude = 35,
    };
    const text_value = "sensor online";
    // The equivalent native graph bounds construction even without sharing children.
    const value: ReadingMessage = .{
        .current = .{ .temperature = &temperature_value },
        .history = &.{
            .{ .temperature = &temperature_value },
            .{ .location = location_value },
            .{ .text = text_value },
            .none,
            .{ .previous = location_value },
        },
    };
    const capacity = comptime runtime.storage.capacityFor(ReadingMessage.Schema, value, .{});
    var storage: [capacity]u8 align(runtime.storage_alignment) = undefined;
    // Explicit handles preserve shared payloads across fields and vector entries.
    // Build every payload and the parent with this builder, then finish the root.
    var builder = Builder.init(&storage);
    const temperature = try Temperature.Schema.create(&builder, temperature_value, .{});
    // Union structs are separate referenced objects. Ordinary Location fields
    // and struct-vector elements continue to be encoded inline.
    const location = try builder.createStruct(Location.Layout, location_value);
    const text = try builder.createString(text_value);
    const history_handles = try builder.createReferenceVector(&[_]ReadingPayload.Handle{
        .{ .temperature = temperature },
        .{ .location = location },
        .{ .text = text },
        .none,
        .{ .previous = location },
    }, .{ .union_type = ReadingPayload });
    var context = try ReadingMessage.Schema.Context.init(&builder);
    try ReadingMessage.Schema.addFields(&context, .{
        .current = .{ .temperature = temperature },
        .history = history_handles,
    });
    const root = try ReadingMessage.Schema.endTable(&context);
    const bytes = try builder.finish(root, .ordinary);
    // Reuse checked root metadata for verification and reading.
    const message_table = try Table.from(bytes, .root);
    try ReadingMessage.verify(message_table, .{});
    const message = try ReadingMessage.read(message_table);
    // Mutate an existing payload; replacing the alternative requires rebuilding.
    const mutable = try MutableTable.from(bytes, .root);
    const current = try ReadingMessage.borrowMutable(mutable, .current);
    if (!try Temperature.update(current.temperature, .value, 26)) return error.MissingField;
    try ReadingMessage.verify(bytes, .{});
    const history = message.history.?;
    for (0..history.element_count) |element_index| {
        const payload = try history.get(element_index);
        try writer.print("union[{d}] {s}: ", .{ element_index, @tagName(payload) });
        switch (payload) {
            .none => try writer.writeAll("no value\n"),
            .temperature => |table| try writer.print("{d}\n", .{
                (try Temperature.read(table)).value,
            }),
            .location, .previous => |structure| try writer.print(
                "altitude={d}\n",
                .{try structure.get(.altitude)},
            ),
            .text => |message_text| try writer.print("{s}\n", .{message_text}),
        }
    }
}
