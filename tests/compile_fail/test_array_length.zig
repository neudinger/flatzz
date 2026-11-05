const runtime = @import("runtime");

test "zero array length is not an FBS type" {
    _ = runtime.ArrayMember(.{ .scalar = u8 }, 0, 0);
}
