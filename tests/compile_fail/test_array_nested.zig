const runtime = @import("runtime");

test "direct nested arrays are not an FBS type" {
    const Member = runtime.ArrayMember(.{ .scalar = u32 }, 2, 0);
    _ = runtime.ArrayMember(Member.kind, 2, 0);
}
