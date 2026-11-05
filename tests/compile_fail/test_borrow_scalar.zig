const runtime = @import("runtime");
test "scalar fields have no mutable borrowed view" {
    const Definition = runtime.Schema(struct { value: u32 }, .{
        .value = runtime.ScalarField(u32, 0, 0),
    });
    const table: runtime.MutableTable = undefined;
    _ = try Definition.borrowMutable(table, .value);
}
