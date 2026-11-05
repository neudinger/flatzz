const runtime = @import("runtime");
comptime {
    const Definition = runtime.Schema(struct { values: ?[]const u64 }, .{
        .values = runtime.ReferenceField(0, .{ .vector = runtime.ScalarCodec(u64) }, .{}),
    });
    _ = @sizeOf(runtime.Storage(Definition, .{ .values = runtime.Builder.max_buffer_size }, .{}));
}
