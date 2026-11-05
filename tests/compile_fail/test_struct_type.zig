const runtime = @import("runtime");

test "struct native and wire member types must agree" {
    const Layout = runtime.StructLayout(struct { number: u32 }, .{
        .size = 8,
        .alignment = 8,
    }, .{ .number = runtime.ScalarMember(u64, 0) });
    _ = Layout.wire_size;
}
