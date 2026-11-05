const runtime = @import("runtime");

test "nested struct views preserve read-only access" {
    const Child = struct {
        number: u32,
        pub const Layout = runtime.StructLayout(@This(), .{
            .size = 4,
            .alignment = 4,
        }, .{ .number = runtime.ScalarMember(u32, 0) });
    };
    const Parent = runtime.StructLayout(struct { child: Child }, .{
        .size = 4,
        .alignment = 4,
    }, .{ .child = runtime.StructMember(Child.Layout, 0) });
    const view: runtime.StructView(Parent, .read_only) = undefined;
    const child = try view.get(.child);
    try child.update(.number, 42);
}
