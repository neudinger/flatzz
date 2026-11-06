//! `zig build run` generates the `reading` module from reading.fbs.
//! The application uses that module and the Flatzz runtime; no schema is read here.
const std = @import("std");
const flatzz = @import("flatzz");
const reading = @import("reading");
const Reading = reading.Reading;

/// Build, verify, read, and mutate a generated Reading without heap allocation.
/// Strings and views borrow storage until this function returns. Errors propagate.
pub fn main(init: std.process.Init) !void {
    const location: reading.Location = .{
        .coordinates = .{ .latitude = 48.5, .longitude = 2.25 },
        .altitude = 35,
    };
    var storage: Reading.Storage(6, 3, .{ .count = 2, .bytes = 6 }, 1) = .{};
    const bytes = try Reading.write(&storage.buffer, .{
        .sequence = 41,
        .value = 1.5,
        .label = "sensor",
        .status = .ok,
        .temperature = 20,
        .samples = &.{ 1, 2, 3 },
        .tags = &.{ "lab", "new" },
        .location = location,
        .history = &.{location},
    }, .{ .force_defaults = true });
    try flatzz.Verifier.verify(Reading, bytes, .{});
    const before = try Reading.read(bytes);

    if (!try Reading.update(bytes, .sequence, 42)) return error.MissingField;
    if (!try Reading.update(bytes, .temperature, 22.5)) return error.MissingField;
    const mutable_location = try Reading.mutableLocation(bytes) orelse return error.MissingField;
    try mutable_location.update(.altitude, 40);
    try Reading.verify(bytes, .{});
    const after = try Reading.read(bytes);
    const updated_location = try (after.location orelse return error.MissingField).read();
    const samples = after.samples orelse return error.MissingField;

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
