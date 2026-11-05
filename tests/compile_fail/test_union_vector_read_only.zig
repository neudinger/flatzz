const runtime = @import("runtime");
test "union vector struct borrowing preserves read-only capability" {
    const Layout = runtime.StructLayout(struct { number: u32 }, .{
        .size = 4,
        .alignment = 4,
    }, .{ .number = runtime.ScalarMember(u32, 0) });
    const Payload = runtime.Union(enum(u8) { none, child }, .{
        .none = .none,
        .child = .{ .structure = Layout },
    });
    const vector: runtime.UnionVectorView(Payload, .read_only) = undefined;
    const value = try vector.get(0);
    try value.child.update(.number, 42);
}
