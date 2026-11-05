const runtime = @import("runtime");

test "borrowed struct vector preserves read-only access" {
    const Layout = runtime.StructLayout(struct { number: u32 }, .{
        .size = 4,
        .alignment = 4,
    }, .{ .number = runtime.ScalarMember(u32, 0) });
    const vector: runtime.Vector(runtime.StructCodec(Layout)) = undefined;
    const value = try vector.get(0);
    try value.update(.number, 42);
}
