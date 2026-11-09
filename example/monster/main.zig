//! Generate Monster from the schema shared with the flatbuf-zig consumer example.
//! Run `zig build run` and `zig build test` from this directory.
//! Serialization uses an aligned local buffer sized at comptime.

const std = @import("std");
const flatzz = @import("flatzz");
const generated = @import("monster");

const Monster = generated.Monster;

/// Serialize without an allocator, verify, and print fields borrowed from local storage.
pub fn main(init: std.process.Init) !void {
    const weapon: generated.Weapon = .{};
    const value: Monster = .{
        .name = "Orc",
        .pos = .{ .x = 1, .y = 2, .z = 3 },
        .hp = 80,
        .color = .green,
        .inventory = &.{ 1, 2, 3 },
        .@"test" = .{ .weapon = &weapon },
    };
    // The complete native value determines a conservative buffer bound at comptime.
    const capacity = comptime flatzz.storage.capacityFor(Monster.Schema, value, .{});
    var storage: [capacity]u8 align(flatzz.storage_alignment) = undefined;
    const bytes = try value.serialize(&storage, .{});

    try Monster.verify(bytes, .{});
    // Keep storage alive while reading its borrowed strings, vectors, and structs.
    const view = try Monster.read(bytes);
    const name = view.name orelse return error.MissingName;
    const position = try (view.pos orelse return error.MissingPosition).read();
    const inventory = view.inventory orelse return error.MissingInventory;

    var output_buffer: [256]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &output_buffer);
    try output.interface.print(
        "Monster: name={s}, hp={d}, mana={d}, color={s}, " ++
            "pos=({d}, {d}, {d}), inventory[2]={d}, test={s}\n",
        .{
            name,                 view.hp,              view.mana,
            @tagName(view.color), position.x,           position.y,
            position.z,           try inventory.get(2), @tagName(view.@"test"),
        },
    );
    try output.interface.flush();
}

test "Monster comptime-sized storage preserves fields and a Weapon union payload" {
    const weapon: generated.Weapon = .{};
    const value: Monster = .{
        .name = "Orc",
        .pos = .{ .x = 1, .y = 2, .z = 3 },
        .hp = 80,
        .color = .green,
        .inventory = &.{ 1, 2, 3 },
        .@"test" = .{ .weapon = &weapon },
    };
    const capacity = comptime flatzz.storage.capacityFor(Monster.Schema, value, .{});
    var storage: [capacity]u8 align(flatzz.storage_alignment) = undefined;
    const bytes = try value.serialize(&storage, .{});

    try Monster.verify(bytes, .{});
    const view = try Monster.read(bytes);
    try std.testing.expectEqualStrings("Orc", view.name.?);
    try std.testing.expectEqual(@as(i16, 80), view.hp);
    try std.testing.expectEqual(@as(i16, 150), view.mana);
    try std.testing.expectEqual(generated.Color.green, view.color);
    try std.testing.expectEqualDeep(value.pos.?, try view.pos.?.read());
    try std.testing.expectEqual(@as(usize, 3), view.inventory.?.element_count);
    try std.testing.expectEqual(@as(u8, 1), try view.inventory.?.get(0));
    try std.testing.expectEqual(@as(u8, 3), try view.inventory.?.get(2));
    switch (view.@"test") {
        .weapon => |table| _ = try generated.Weapon.read(table),
        else => return error.UnexpectedUnion,
    }
}

test "Monster fixed-buffer round trip preserves defaults and a nested Monster" {
    const child: Monster = .{ .name = "Goblin", .hp = 50 };
    const value: Monster = .{ .name = "Orc", .@"test" = .{ .monster = &child } };
    const capacity = comptime flatzz.storage.capacityFor(Monster.Schema, value, .{});
    var storage: [capacity]u8 align(flatzz.storage_alignment) = undefined;
    const bytes = try value.serialize(&storage, .{});

    try Monster.verify(bytes, .{});
    const view = try Monster.read(bytes);
    try std.testing.expectEqualStrings("Orc", view.name.?);
    try std.testing.expectEqual(@as(i16, 100), view.hp);
    try std.testing.expectEqual(@as(i16, 150), view.mana);
    try std.testing.expectEqual(generated.Color.blue, view.color);
    try std.testing.expect(view.pos == null);
    try std.testing.expect(view.inventory == null);
    switch (view.@"test") {
        .monster => |table| {
            const nested = try Monster.read(table);
            try std.testing.expectEqualStrings("Goblin", nested.name.?);
            try std.testing.expectEqual(@as(i16, 50), nested.hp);
        },
        else => return error.UnexpectedUnion,
    }
}
