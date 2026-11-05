const runtime = @import("runtime");
comptime {
    const Definition = runtime.Schema(struct {}, .{});
    _ = @sizeOf(runtime.Storage(Definition, .{ .missing = 1 }, .{}));
}
