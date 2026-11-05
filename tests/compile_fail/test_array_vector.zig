const runtime = @import("runtime");

test "raw fixed arrays are not vector elements" {
    const Member = runtime.ArrayMember(.{ .scalar = u32 }, 2, 0);
    _ = runtime.StructCodec(Member.kind.array);
}
