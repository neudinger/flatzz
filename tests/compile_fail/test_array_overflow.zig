const runtime = @import("runtime");

test "array lengths must fit schema metadata" {
    _ = runtime.ArrayMember(.{ .scalar = u8 }, 65536, 0);
}
