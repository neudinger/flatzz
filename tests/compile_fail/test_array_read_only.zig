const runtime = @import("runtime");

test "borrowed array preserves read-only access" {
    const Layout = runtime.StructLayout(struct { values: [2]u32 }, .{
        .size = 8,
        .alignment = 4,
    }, .{ .values = runtime.ArrayMember(.{ .scalar = u32 }, 2, 0) });
    const view: runtime.StructView(Layout, .read_only) = undefined;
    const values = try view.get(.values);
    try values.update(0, 42);
}
