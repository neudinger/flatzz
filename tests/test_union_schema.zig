//! Union adapter. Construction uses explicit completed payload handles.
const runtime = @import("runtime");
pub const structs = @import("test_struct_schema.zig");

pub const Event = struct {
    number: u64 = 0,
    name: ?[]const u8 = null,

    pub const Schema = runtime.Schema(@This(), .{
        .number = runtime.ScalarField(u64, 0, 0),
        .name = runtime.ReferenceField(1, .string, .{ .required = true }),
    });
};

pub const Payload = runtime.Union(enum(u8) {
    none = 0,
    event = 1,
    envelope = 2,
    text = 3,
    again = 4,
}, .{
    .none = .none,
    .event = .{ .table = Event },
    .envelope = .{ .structure = structs.Envelope.Layout },
    .text = .string,
    .again = .{ .table = Event },
});

pub const Packet = struct {
    marker: u32 = 0,
    required_history: ?[]const Payload.Value = null,
    history: ?[]const Payload.Value = null,
    required_value: Payload.Value = .none,
    current: Payload.Value = .none,

    pub const Schema = runtime.Schema(@This(), .{
        .current = runtime.UnionField(Payload, .{ .tag = 0, .value = 1 }, .{}),
        .history = runtime.UnionVectorField(Payload, .{ .tag = 2, .value = 3 }, .{}),
        .required_value = runtime.UnionField(
            Payload,
            .{ .tag = 4, .value = 5 },
            .{ .required = true },
        ),
        .required_history = runtime.UnionVectorField(
            Payload,
            .{ .tag = 6, .value = 7 },
            .{ .required = true },
        ),
        .marker = runtime.ScalarField(u32, 8, 0),
    });
};

pub const storage_capacity = 1024;
pub const label = "union";
pub const message = "union é";
pub const number: u64 = 0x0102030405060708;

pub fn build(
    storage: []align(runtime.storage_alignment) u8,
    comptime options: runtime.Builder.FinishOptions,
) runtime.BuildError![]u8 {
    var builder = runtime.Builder.init(storage);
    const event = try Event.Schema.create(&builder, .{
        .number = number,
        .name = label,
    });
    const envelope = try builder.createStruct(structs.Envelope.Layout, structs.envelope);
    const text = try builder.createString(message);
    const root = try Packet.Schema.create(&builder, .{
        .marker = 42,
        .current = .{ .event = event },
        .history = &.{
            .{ .event = event }, .none,               .{ .envelope = envelope },
            .{ .text = text },   .{ .again = event },
        },
        .required_value = .{ .envelope = envelope },
        .required_history = &.{},
    });
    return builder.finish(root, options);
}
