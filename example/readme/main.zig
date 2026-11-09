//! Generate Rocket from rocket.fbs, serialize it, and edit existing bytes.
//! Run with `zig build run-readme`; `zig build test` checks the copyable examples.

const std = @import("std");
const flatzz = @import("flatzz");
const generated = @import("rocket");

const Rocket = generated.Rocket;

/// Print a borrowed view while its backing storage is still alive.
fn printRocket(output: *std.Io.Writer, label: []const u8, view: Rocket.View) !void {
    const pilot = view.pilot orelse return error.MissingPilot;
    const payload = view.payload orelse return error.MissingPayload;
    try output.print("{s}: id={d}, fuel={d}, pilot={s}, payload[0]={d}\n", .{
        label, view.id, view.fuel, pilot, try payload.get(0),
    });
}

/// Create an owned frame, then receive and edit a separate caller-owned frame.
pub fn main(init: std.process.Init) !void {
    const rocket: Rocket = .{
        .id = 7,
        .fuel = 80,
        .pilot = "Ziguana",
        .payload = &.{ 1, 2, 3 },
    };
    var output_buffer: [512]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &output_buffer);

    const result = try rocket.serializeAlloc(init.gpa, .{});
    defer result.deinit(init.gpa);
    try Rocket.verify(result.bytes, .{});
    try printRocket(&output.interface, "allocated", try Rocket.read(result.bytes));

    var storage: [256]u8 align(flatzz.storage_alignment) = undefined;
    const bytes = try rocket.serialize(&storage, .{});
    try Rocket.verify(bytes, .{});
    try printRocket(&output.interface, "received", try Rocket.read(bytes));
    if (!try Rocket.update(bytes, .fuel, 79)) return error.MissingFuel;
    if (!try Rocket.update(bytes, .pilot, "Pilot01")) return error.MissingPilot;
    try Rocket.verify(bytes, .{});
    try printRocket(&output.interface, "edited", try Rocket.read(bytes));
    try output.interface.flush();
}

test "1. serialize and read back" {
    const allocator = std.testing.allocator;
    const rocket: Rocket = .{
        .id = 7,
        .fuel = 80,
        .pilot = "Ziguana",
        .payload = &.{ 1, 2, 3 },
    };
    const result = try rocket.serializeAlloc(allocator, .{});
    defer result.deinit(allocator);

    try Rocket.verify(result.bytes, .{});
    const view = try Rocket.read(result.bytes);
    try std.testing.expectEqual(@as(u32, 7), view.id);
    try std.testing.expectEqual(@as(f32, 80), view.fuel);
    try std.testing.expectEqualStrings("Ziguana", view.pilot.?);
    try std.testing.expectEqual(@as(u8, 1), try view.payload.?.get(0));
}

test "2. use caller-owned storage" {
    const rocket: Rocket = .{
        .id = 7,
        .fuel = 80,
        .pilot = "Ziguana",
        .payload = &.{ 1, 2, 3 },
    };
    var storage: [256]u8 align(flatzz.storage_alignment) = undefined;
    const bytes = try rocket.serialize(&storage, .{});

    try Rocket.verify(bytes, .{});
    const view = try Rocket.read(bytes);
    try std.testing.expectEqualStrings("Ziguana", view.pilot.?);
    try std.testing.expectEqual(@as(f32, 80), view.fuel);
    try std.testing.expectEqual(@as(u8, 3), try view.payload.?.get(2));

    const pilot_start = @intFromPtr(view.pilot.?.ptr);
    const frame_start = @intFromPtr(bytes.ptr);
    try std.testing.expect(pilot_start >= frame_start);
    try std.testing.expect(pilot_start + view.pilot.?.len <= frame_start + bytes.len);
}

test "4. read and edit existing bytes" {
    const rocket: Rocket = .{
        .id = 7,
        .fuel = 80,
        .pilot = "Ziguana",
        .payload = &.{ 1, 2, 3 },
    };
    var storage: [256]u8 align(flatzz.storage_alignment) = undefined;
    const bytes = try rocket.serialize(&storage, .{});
    try Rocket.verify(bytes, .{});
    const before = try Rocket.read(bytes);

    try std.testing.expect(try Rocket.update(bytes, .fuel, 79));
    try std.testing.expect(try Rocket.update(bytes, .pilot, "Pilot01"));
    try Rocket.verify(bytes, .{});
    const after = try Rocket.read(bytes);

    try std.testing.expectEqual(@as(f32, 80), before.fuel);
    try std.testing.expectEqual(@as(f32, 79), after.fuel);
    try std.testing.expectEqualStrings("Pilot01", after.pilot.?);
    try std.testing.expectEqualStrings("Pilot01", before.pilot.?);
    try std.testing.expectError(error.LengthMismatch, Rocket.update(bytes, .pilot, "short"));
    try std.testing.expectEqualStrings("Pilot01", (try Rocket.read(bytes)).pilot.?);
}
