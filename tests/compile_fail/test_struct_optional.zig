const runtime = @import("runtime");

test "struct members cannot be optional scalars" {
    const Layout = runtime.StructLayout(struct { number: ?u32 }, .{
        .size = 4,
        .alignment = 4,
    }, .{ .number = runtime.ScalarMember(?u32, 0) });
    _ = Layout.wire_size;
}
