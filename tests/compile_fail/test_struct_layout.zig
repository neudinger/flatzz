const runtime = @import("runtime");

test "struct size cannot substitute for alignment" {
    const Native = struct { first: u32, second: u32, third: u32 };
    const Layout = runtime.StructLayout(Native, .{
        .size = 12,
        .alignment = 12,
    }, .{
        .first = runtime.ScalarMember(u32, 0),
        .second = runtime.ScalarMember(u32, 4),
        .third = runtime.ScalarMember(u32, 8),
    });
    _ = Layout.wire_size;
}
