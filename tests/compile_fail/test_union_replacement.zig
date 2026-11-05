const runtime = @import("runtime");

const Payload = runtime.Union(enum(u8) { none, text }, .{
    .none = .none,
    .text = .string,
});

const Packet = struct {
    payload: Payload.Value,
    const Schema = runtime.Schema(@This(), .{
        .payload = runtime.UnionField(Payload, .{ .tag = 0, .value = 1 }, .{}),
    });
};
test "union replacement is not a size-preserving field update" {
    const table: runtime.MutableTable = undefined;
    _ = try Packet.Schema.update(table, .payload, .none);
}
