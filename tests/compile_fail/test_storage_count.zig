const runtime = @import("runtime");
comptime {
    const Definition = runtime.Schema(struct { values: ?[]const u8 }, .{
        .values = runtime.ReferenceField(0, .{ .vector = runtime.ScalarCodec(u8) }, .{}),
    });
    _ = @sizeOf(runtime.Storage(Definition, .{ .values = 0x1_0000_0000 }, .{}));
}
