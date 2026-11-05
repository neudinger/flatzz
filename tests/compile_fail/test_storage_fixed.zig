const runtime = @import("runtime");
comptime {
    const Definition = runtime.Schema(struct { value: u32 }, .{
        .value = runtime.ScalarField(u32, 0, 0),
    });
    _ = @sizeOf(runtime.Storage(Definition, .{ .value = 1 }, .{}));
}
