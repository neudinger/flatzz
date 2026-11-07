//! Native union adapter with an explicit shared-handle construction fixture.
const runtime = @import("runtime");
/// Independent padded struct fixtures reused as union alternatives.
pub const structs = @import("test_struct_schema.zig");

/// Table alternative shared by two discriminator values.
pub const Event = struct {
    /// Scalar payload whose shared mutations must be visible through every alias.
    number: u64 = 0,
    /// Required event string, packed before its parent table.
    name: ?[]const u8 = null,

    /// Explicit table field IDs and required-field rules.
    pub const Schema = runtime.Schema(@This(), .{
        .number = runtime.ScalarField(u64, 0, 0),
        .name = runtime.ReferenceField(1, .string, .{ .required = true }),
    });
};

/// Union with table, standalone struct, string, and repeated table alternatives.
pub const Payload = runtime.Union(enum(u8) {
    /// No payload; its paired wire offset must be zero.
    none = 0,
    /// First discriminator selecting the Event table schema.
    event = 1,
    /// Standalone padded struct referenced by a forward offset.
    envelope = 2,
    /// UTF-8 string payload referenced by a forward offset.
    text = 3,
    /// Second discriminator selecting the same Event table schema.
    again = 4,
}, .{
    .none = .none,
    .event = .{ .table = Event },
    .envelope = .{ .structure = structs.Envelope.Layout },
    .text = .string,
    .again = .{ .table = Event },
});

/// Root table combining required and optional unions and paired union vectors.
pub const Packet = struct {
    /// Independent root scalar following the paired physical fields.
    marker: u32 = 0,
    /// Required paired vector; an empty vector is present and valid.
    required_history: ?[]const Payload.Value = null,
    /// Optional paired vector; explicit construction can share its payloads.
    history: ?[]const Payload.Value = null,
    /// Required union; the none discriminator is rejected.
    required_value: Payload.Value = .none,
    /// Optional union defaulting to an absent payload.
    current: Payload.Value = .none,

    /// Explicit table field IDs and required-field rules.
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

/// Builder capacity in bytes for the fixed union fixture.
pub const storage_capacity = 1024;
/// Required Event string fixture.
pub const label = "union";
/// Union string fixture including a multibyte UTF-8 scalar.
pub const message = "union é";
/// Independent wide scalar fixture for shared Event objects.
pub const number: u64 = 0x0102030405060708;

/// Build every alternative and share Event/Envelope payloads across union fields.
/// The result borrows caller storage; construction errors may leave partial bytes.
pub fn build(
    storage: []align(runtime.storage_alignment) u8,
    comptime options: runtime.Builder.FinishOptions,
) runtime.BuildError![]u8 {
    var builder = runtime.Builder.init(storage);
    const event = try Event.Schema.create(
        &builder,
        .{
            .number = number,
            .name = label,
        },
        .{},
    );
    const envelope = try builder.createStruct(structs.Envelope.Layout, structs.envelope);
    const text = try builder.createString(message);
    const required_history = try builder.createReferenceVector(&.{}, .{ .union_type = Payload });
    const history = try builder.createReferenceVector(
        &[_]Payload.Handle{
            .{ .event = event }, .none,               .{ .envelope = envelope },
            .{ .text = text },   .{ .again = event },
        },
        .{ .union_type = Payload },
    );
    var context = try Packet.Schema.Context.init(&builder);
    try Packet.Schema.addFields(&context, .{
        .marker = 42,
        .current = .{ .event = event },
        .required_value = .{ .envelope = envelope },
        .history = history,
        .required_history = required_history,
    });
    const root = try Packet.Schema.endTable(&context);
    return builder.finish(root, options);
}
