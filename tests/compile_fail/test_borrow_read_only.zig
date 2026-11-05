const runtime = @import("runtime");
test "mutable borrowing requires a mutable table" {
    const Definition = runtime.Schema(struct { values: ?[]const u32 }, .{
        .values = runtime.ReferenceField(0, .{ .vector = runtime.ScalarCodec(u32) }, .{}),
    });
    const table: runtime.Table = undefined;
    _ = try Definition.borrowMutable(table, .values);
}
