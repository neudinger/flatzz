const runtime = @import("runtime");

test "raw fixed arrays cannot be table fields" {
    const Member = runtime.ArrayMember(.{ .scalar = u32 }, 2, 0);
    _ = runtime.StructField(Member.kind.array, 0, .{});
}
