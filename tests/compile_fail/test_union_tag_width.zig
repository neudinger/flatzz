const runtime = @import("runtime");
test "union tags have the fixed wire width" {
    _ = runtime.Union(enum(u16) { none, text }, .{
        .none = .none,
        .text = .string,
    });
}
