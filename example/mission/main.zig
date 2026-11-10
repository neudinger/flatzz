//! Generate Mission and its included Position from two FBS files.
//! Run `zig build run` and `zig build test` from this directory.
//! Serialization uses an aligned local buffer sized at comptime.

const std = @import("std");
const flatzz = @import("flatzz");
const generated = @import("mission");

const Mission = generated.Mission;

/// Serialize into comptime-sized storage and read while it remains alive.
pub fn main(init: std.process.Init) !void {
    // Both types come from one generated module, including common.fbs.
    const position: generated.Position = .{ .east = 12.5, .north = -3.25, .altitude = 400 };
    const value: Mission = .{ .name = "Lunar survey", .position = position };
    // The complete native value determines a conservative buffer bound at comptime.
    const capacity = comptime flatzz.storage.capacityFor(Mission.Schema, value, .{});
    var storage: [capacity]u8 align(flatzz.storage_alignment) = undefined;
    const bytes = try value.serialize(&storage, .{});

    try Mission.verify(bytes, .{});
    // The name and position view borrow storage until it is reused or goes out of scope.
    const view = try Mission.read(bytes);
    const name = view.name orelse return error.MissingName;
    const received = try (view.position orelse return error.MissingPosition).read();

    var output: std.Io.Writer.Allocating = .init(init.gpa);
    defer output.deinit();
    try output.writer.print("Mission: name={s}, position=({d}, {d}, {d})\n", .{
        name, received.east, received.north, received.altitude,
    });
    try std.Io.File.stdout().writeStreamingAll(init.io, output.written());
}

test "Mission comptime-sized storage preserves the included Position" {
    const position: generated.Position = .{ .east = 12.5, .north = -3.25, .altitude = 400 };
    const value: Mission = .{ .name = "Lunar survey", .position = position };
    const capacity = comptime flatzz.storage.capacityFor(Mission.Schema, value, .{});
    var storage: [capacity]u8 align(flatzz.storage_alignment) = undefined;
    const bytes = try value.serialize(&storage, .{});

    try Mission.verify(bytes, .{});
    const view = try Mission.read(bytes);
    try std.testing.expectEqualStrings("Lunar survey", view.name.?);
    try std.testing.expectEqualDeep(position, try view.position.?.read());
}

test "Mission fixed-buffer reads borrow storage and preserve an absent position" {
    const value: Mission = .{ .name = "Coast" };
    const capacity = comptime flatzz.storage.capacityFor(Mission.Schema, value, .{});
    var storage: [capacity]u8 align(flatzz.storage_alignment) = undefined;
    const bytes = try value.serialize(&storage, .{});

    try Mission.verify(bytes, .{});
    const view = try Mission.read(bytes);
    try std.testing.expectEqualStrings("Coast", view.name.?);
    try std.testing.expect(view.position == null);

    const name_start = @intFromPtr(view.name.?.ptr);
    const frame_start = @intFromPtr(bytes.ptr);
    try std.testing.expect(name_start >= frame_start);
    try std.testing.expect(name_start + view.name.?.len <= frame_start + bytes.len);
}
