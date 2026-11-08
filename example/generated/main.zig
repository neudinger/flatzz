//! `zig build run` generates the `reading` module from reading.fbs.
//! The application uses that module and the Flatzz runtime; no schema is read here.
//! Native values derive fixed buffer capacities at comptime.
const std = @import("std");
const flatzz = @import("flatzz");
const reading = @import("reading");

const Reading = reading.Reading;
const ReadingMessage = reading.ReadingMessage;
const Temperature = reading.Temperature;

/// Serialize Reading and union values with buffer capacities sized at comptime.
/// Views borrow local storage until this function returns.
pub fn main(init: std.process.Init) !void {
    const location: reading.Location = .{
        .coordinates = .{ .latitude = 48.5, .longitude = 2.25 },
        .altitude = 35,
    };
    const value: Reading = .{
        .sequence = 41,
        .value = 1.5,
        .label = "sensor",
        .status = .ok,
        .temperature = 20,
        .samples = &.{ 1, 2, 3 },
        .tags = &.{ "lab", "new" },
        .location = location,
        .history = &.{location},
    };
    const capacity = comptime flatzz.storage.capacityFor(Reading.Schema, value, .{});
    var storage: [capacity]u8 align(flatzz.storage_alignment) = undefined;
    const bytes = try value.serialize(&storage, .{ .force_defaults = true });
    try Reading.verify(bytes, .{});
    const before = try Reading.read(bytes);

    if (!try Reading.update(bytes, .sequence, 42)) return error.MissingField;
    if (!try Reading.update(bytes, .temperature, 22.5)) return error.MissingField;
    //  const table = try flatzz.MutableTable.from(bytes, .root);
    // A checked MutableTable also works: Reading.borrowMutable(table, .location).
    const mutable_location = try Reading.borrowMutable(bytes, .location) orelse
        return error.MissingField;
    try mutable_location.update(.altitude, 40);
    try Reading.verify(bytes, .{});
    const after = try Reading.read(bytes);
    const updated_location = try (after.location orelse return error.MissingField).read();
    const samples = after.samples orelse return error.MissingField;

    // Union inputs contain native table pointers, struct values, and strings.
    const temperature: Temperature = .{ .value = 25.5 };
    const message: ReadingMessage = .{
        .current = .{ .temperature = &temperature },
        .history = &.{ .{ .location = location }, .{ .text = "sensor online" }, .none },
    };
    const message_capacity = comptime flatzz.storage.capacityFor(
        ReadingMessage.Schema,
        message,
        .{},
    );
    var message_storage: [message_capacity]u8 align(flatzz.storage_alignment) = undefined;
    const message_bytes = try message.serialize(&message_storage, .{});

    // Uncomment to compare allocating serialization with the fixed buffer.
    // const allocated = try message.serializeAlloc(init.gpa, .{});
    // defer allocated.deinit(init.gpa);
    // if (!std.mem.eql(u8, message_bytes, allocated.bytes)) return error.UnexpectedValue;

    try ReadingMessage.verify(message_bytes, .{});
    const message_view = try ReadingMessage.read(message_bytes);
    if ((try Temperature.read(message_view.current.temperature)).value != temperature.value)
        return error.UnexpectedValue;

    var output_buffer: [512]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &output_buffer);
    try output.interface.print(
        "before: sequence={d}, temperature={?d}\n" ++
            "after: sequence={d}, temperature={?d}, altitude={d}\n" ++
            "reading: label={s}, status={s}, samples[2]={d}\n",
        .{
            before.sequence,           before.temperature,
            after.sequence,            after.temperature,
            updated_location.altitude, after.label orelse return error.MissingField,
            @tagName(after.status),    try samples.get(2),
        },
    );
    try output.interface.flush();
}
