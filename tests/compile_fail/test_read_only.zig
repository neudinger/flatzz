const runtime = @import("runtime");
test "read-only views reject mutation" {
    const table: runtime.Table = undefined;
    _ = try table.mutateField(u32, 0, 1);
}
