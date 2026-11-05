const runtime = @import("runtime");
test "strings retain checked replacement semantics" {
    const Definition = runtime.Schema(struct { value: ?[]const u8 }, .{
        .value = runtime.ReferenceField(0, .string, .{}),
    });
    const table: runtime.MutableTable = undefined;
    _ = try Definition.borrowMutable(table, .value);
}
