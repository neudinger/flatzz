const runtime = @import("runtime");

test "overlapping struct members are rejected" {
    const Native = struct { first: u32, second: u32 };
    const Layout = runtime.StructLayout(Native, .{
        .size = 8,
        .alignment = 4,
    }, .{
        .first = runtime.ScalarMember(u32, 0),
        .second = runtime.ScalarMember(u32, 0),
    });
    _ = Layout.wire_size;
}
