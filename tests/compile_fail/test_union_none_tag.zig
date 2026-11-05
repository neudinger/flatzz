const runtime = @import("runtime");
test "union NONE must be tag zero" {
    _ = runtime.Union(enum(u8) { none = 2, text = 3 }, .{
        .none = .none,
        .text = .string,
    });
}
