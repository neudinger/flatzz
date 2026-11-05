const runtime = @import("runtime");

const Payload = runtime.Union(enum(u8) { none, text }, .{
    .none = .none,
    .text = .string,
});

test "union physical IDs must be adjacent" {
    _ = runtime.UnionField(Payload, .{ .tag = 0, .value = 2 }, .{});
}
