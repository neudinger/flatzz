const runtime = @import("runtime");

const Payload = runtime.Union(enum(u8) { none, text }, .{
    .none = .none,
    .text = .string,
});

const Packet = struct {
    payload: Payload.Value,
    marker: u8,
    const Schema = runtime.Schema(@This(), .{
        .payload = runtime.UnionField(Payload, .{ .tag = 0, .value = 1 }, .{}),
        .marker = runtime.ScalarField(u8, 0, 0),
    });
};
test "synthetic discriminator IDs cannot overlap another field" {
    _ = Packet.Schema.field_count;
}
