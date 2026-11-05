const runtime = @import("runtime");

test "native array lengths must match the schema" {
    const Layout = runtime.StructLayout(struct { values: [3]u32 }, .{
        .size = 8,
        .alignment = 4,
    }, .{ .values = runtime.ArrayMember(.{ .scalar = u32 }, 2, 0) });
    _ = Layout.wire_size;
}
