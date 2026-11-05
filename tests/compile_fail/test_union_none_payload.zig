const runtime = @import("runtime");
test "only NONE lacks a payload" {
    _ = runtime.Union(enum(u8) { none, text }, .{
        .none = .none,
        .text = .none,
    });
}
