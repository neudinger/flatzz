const runtime = @import("runtime");
test "union table borrowing preserves read-only capability" {
    const Child = struct {};
    const Payload = runtime.Union(enum(u8) { none, child }, .{
        .none = .none,
        .child = .{ .table = Child },
    });
    const table: runtime.Table = undefined;
    const value = try table.readUnion(Payload, .{ .tag = 0, .value = 1 });
    _ = try value.child.mutateField(u32, 0, 42);
}
